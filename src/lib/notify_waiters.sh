#!/usr/bin/env bash
# notify_waiters.sh — populate notifications for sessions that were denied
# on a lock during the holder's hold window.
#
# Phase 2 "notification activation" is the moment Phase 1's dormant
# `notifications[<sid>][<path>]` consumer (in pre_tool_use_read.sh +
# pre_tool_use_any.sh) becomes coupled to a real producer. The producer
# is every release path: post_tool_use_write.sh, stop.sh, session_end.sh.
#
# Phase 1 chose strings as the per-file notification payload shape (see
# pre_tool_use_read.sh's atomic-supersede consumer). We preserve that
# shape — `notifications[<sid>][<path>]` is an array of strings, each
# rendered as `- <string>` in the delivered banner. (Plan §3.3 schema
# text shows a richer object shape; the divergence mirrors F-013 / F-014
# and is out of scope for T2.02.)
#
# Contract:
#   coord_notify_lock_release_waiters <holder_sid> <path> <acquired_at> <released_at>
#     Scans $COORD_DIR/events.jsonl for entries with
#       kind == "LOCK_DENIED" AND
#       file == <path>          AND
#       session != <holder_sid> AND
#       ts >= <acquired_at>     AND
#       ts <  <released_at>
#     Collects the unique set of denied-session IDs. For each, populates
#       notifications[<denied_sid>][<path>] += [
#         "lock_released: <path> released by <holder-prefix>... at <released_at>"
#       ]
#     in a single atomic_edit.
#
#     Best-effort: missing events.jsonl, malformed lines, atomic_edit
#     failures are logged to stderr and the function returns 0 anyway.
#     Callers should NOT condition on the exit code.
#
# Dependencies (must be sourced by caller before this is called):
#   - lib/atomic_write.sh    (coord_atomic_edit)
#   - lib/log_event.sh       (only for stderr formatting; not strictly required)
#   - jq, flock              (caller's deps gate already verified these)
#
# Environment:
#   COORD_DIR     — required; resolves events.jsonl + sessions.json.
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern).

# Internal: print integer seconds between two ISO-8601 timestamps, or
# empty string on parse failure. Bash 3.2 + portable date(1).
_coord_notify_seconds_between() {
  local from="$1" to="$2"
  [ -z "$from" ] || [ -z "$to" ] && return 0
  # Strip ms suffix (.123Z → Z) for portable parsing.
  local fb tb
  case "$from" in *.*Z) fb="${from%.*}Z" ;; *) fb="$from" ;; esac
  case "$to"   in *.*Z) tb="${to%.*}Z"   ;; *) tb="$to"   ;; esac
  local fs ts
  fs=$(date -u -d "$fb" +%s 2>/dev/null || \
       date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$fb" +%s 2>/dev/null || \
       printf '')
  ts=$(date -u -d "$tb" +%s 2>/dev/null || \
       date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$tb" +%s 2>/dev/null || \
       printf '')
  if [ -z "$fs" ] || [ -z "$ts" ]; then
    return 0
  fi
  local diff=$(( ts - fs ))
  [ "$diff" -lt 0 ] && diff=0
  printf '%d' "$diff"
}

coord_notify_lock_release_waiters() {
  local holder="$1"
  local path="$2"
  local acquired_at="$3"
  local released_at="$4"

  if [ -z "${COORD_DIR:-}" ] || [ ! -d "$COORD_DIR" ]; then
    return 0
  fi
  if [ -z "$holder" ] || [ -z "$path" ] || [ -z "$acquired_at" ]; then
    return 0
  fi
  local events="$COORD_DIR/events.jsonl"
  local state="$COORD_DIR/sessions.json"
  if [ ! -f "$events" ] || [ ! -f "$state" ]; then
    return 0
  fi

  # Collect unique denied-session IDs in the hold window. jq filter
  # walks each line; treats missing/empty fields safely. Output is
  # newline-separated session IDs, deduplicated.
  local waiters_json
  waiters_json=$(jq -sc \
      --arg path "$path" \
      --arg holder "$holder" \
      --arg acq "$acquired_at" \
      --arg rel "$released_at" '
    [ .[]
      | select((.kind // "") == "LOCK_DENIED")
      | select((.file // "") == $path)
      | select((.session // "") != $holder)
      | select((.ts // "")    >= $acq)
      | select((.ts // "")    <  $rel)
      | (.session // "")
      | select(length > 0)
    ] | unique
  ' "$events" 2>/dev/null || printf '[]')

  # Empty array → nothing to do.
  local n
  n=$(printf '%s' "$waiters_json" | jq -r 'length' 2>/dev/null || printf '0')
  if [ "${n:-0}" -lt 1 ]; then
    return 0
  fi

  local holder_short="${holder:0:8}"
  # Compute held-for duration in seconds (best-effort; falls back to "?"
  # on parse failure). Caller passes ISO-8601 timestamps; both GNU date
  # (-d) and BSD date (-j -f) are tried for portability per F-003-style
  # cross-platform discipline.
  local held_for
  held_for=$(_coord_notify_seconds_between "$acquired_at" "$released_at")
  local message
  if [ -n "$held_for" ]; then
    message="Lock released on ${path} (held by ${holder_short}... for ${held_for} sec). You may now retry your write or \`coord wait ${path}\` if you've moved on."
  else
    message="Lock released on ${path} (held by ${holder_short}...). You may now retry your write or \`coord wait ${path}\` if you've moved on."
  fi

  # One atomic_edit appends the message to every waiter's per-path bucket.
  # The filter walks the waiters array and accumulates updates onto the
  # state object using `reduce`. Existing entries (if any) are preserved
  # and the new message is appended.
  if ! coord_atomic_edit "$state" '
        reduce ($waiters[]) as $w (
          .;
          .notifications[$w]         //= {}
          | .notifications[$w][$path] //= []
          | .notifications[$w][$path] += [$msg]
        )
      ' \
      --argjson waiters "$waiters_json" \
      --arg path "$path" \
      --arg msg  "$message"; then
    printf 'coord notify_waiters: atomic_edit failed for %s\n' "$path" >&2
    return 0
  fi

  # Best-effort observability — one event per release-with-waiters,
  # not per waiter (a path can have many waiters).
  if command -v coord_log_event >/dev/null 2>&1; then
    local count
    count=$(printf '%s' "$waiters_json" | jq -r 'length' 2>/dev/null || printf '0')
    coord_log_event kind=NOTIFICATION_PRODUCED source=lock_release \
      file="$path" waiter_count="$count"
  fi
  return 0
}

# CLI shim for ad-hoc / bats use:
#   COORD_DIR=... SESSION_ID=... \
#     notify_waiters.sh <holder> <path> <acquired_at> <released_at>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$_SHIM_DIR/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$_SHIM_DIR/log_event.sh"
  coord_notify_lock_release_waiters "$@"
fi

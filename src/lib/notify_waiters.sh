#!/usr/bin/env bash
# notify_waiters.sh — populate notifications + wake_file content for
# sessions waiting on a lock during the holder's hold window.
#
# Phase evolution:
#   Phase 2: scanned events.jsonl for prior LOCK_DENIED entries to find
#            denied-but-not-queued waiters; appended a string banner
#            message to notifications[<sid>][<path>].
#   Phase 5 T5.03: added wait_queues[<path>] enumeration with a stub
#            wake_file producer ("modified by <holder>"); preserved the
#            Phase 2 events.jsonl scan as a complementary channel.
#   Phase 5 T5.04 (this file): deletes the Phase 2 events.jsonl scan
#            entirely (PR-PHASE5-02 pin-point c-2 — full pivot to
#            wait_queues authoritative source). Replaces the wake_file
#            stub with a 4-tier diff_summary computation:
#              1. validator/verdict/<ts>.json via
#                 locks[<file>].latest_validator_verdict_ts
#              2. validator cache hit on (file, prev_hash, current_hash)
#              3. validator pre-filter classification on snapshots
#                 (SAFE → "trivial change (whitespace/comment)")
#              4. fallback "modified by <session_id_8>"
#
#            Each tier is cheaper than the next; first-success wins.
#            events.jsonl remains as audit-trail-only (read-only).
#            notifications[<sid>][<path>] string append remains for
#            non-queue waiters who reach the consumer via Phase 1's
#            dormant `notifications` channel.
#
# Contract:
#   coord_notify_lock_release_waiters <holder_sid> <path> <acquired_at> <released_at>
#     - Computes diff_summary via the 4-tier chain above.
#     - For every waiter in wait_queues[<path>], writes
#       "<diff_summary>\n" to that waiter's wake_file (overwriting the
#       empty file produced at enqueue time).
#     - For every waiter still in notifications[<sid>][<path>] context
#       (Phase 1 dormant channel — sessions denied but later moved on),
#       appends a "lock_released:..." string to the bucket.
#     - Best-effort: missing files, malformed JSON, atomic_edit
#       failures all log to stderr and the function returns 0 anyway.
#       Callers must NOT condition on the exit code.
#
# Dependencies (must be sourced by caller before this is called):
#   - lib/atomic_write.sh        (coord_atomic_edit)
#   - lib/log_event.sh           (coord_log_event)
#   - lib/validator_cache.sh     (coord_validator_cache_lookup; tier 2)
#   - lib/validator_prefilter.sh (coord_validator_prefilter; tier 3)
#   - lib/read_snapshots.sh      (coord_read_snapshot_path; tier 3)
#   - lib/hash.sh                (coord_hash_file; tier 2/3 inputs)
#   - jq, flock                  (caller's deps gate already verified these)
#
# Environment:
#   COORD_DIR — required; resolves sessions.json + validator/verdict/ +
#               read_snapshots/.
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern).

# Internal: print integer seconds between two ISO-8601 timestamps, or
# empty string on parse failure. Bash 3.2 + portable date(1).
_coord_notify_seconds_between() {
  local from="$1" to="$2"
  [ -z "$from" ] || [ -z "$to" ] && return 0
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

# _coord_notify_compute_diff_summary <holder_sid> <path> <verdict_ts>
#   Implements PR-PHASE5-02 §5 4-tier priority chain. Prints
#   "<tier>\t<diff_summary>" TSV on stdout — caller awk-splits to
#   recover both. (Globals can't ride out of the $() subshell capture
#   that the caller uses, so the TSV protocol carries both pieces.)
#
#   Helpers (cache_lookup, prefilter) print classification text to
#   their own stdout under normal usage; we suppress with >/dev/null
#   to keep our TSV output clean — only the rc matters here.
_coord_notify_compute_diff_summary() {
  local holder="$1" path="$2" verdict_ts="$3"
  local state="$COORD_DIR/sessions.json"

  # Tier 1: verdict-file lookup via locks[<path>].latest_validator_verdict_ts.
  if [ -n "$verdict_ts" ]; then
    local vfile="$COORD_DIR/validator/verdict/${verdict_ts}.json"
    if [ -f "$vfile" ]; then
      local v_summary
      v_summary=$(jq -r '.diff_summary // ""' "$vfile" 2>/dev/null) || v_summary=""
      if [ -n "$v_summary" ] && [ "$v_summary" != "null" ]; then
        printf 'verdict_file\t%s' "$v_summary"
        return 0
      fi
    fi
    # File deleted by GC, or malformed — fall through.
  fi

  # Tier 2/3 require knowing the holder's most-recent read_set hash for
  # this file (prev_hash) and the on-disk current hash. If either is
  # unavailable, skip tiers 2+3 and go straight to tier 4 fallback.
  local prev_hash current_hash
  prev_hash=$(jq -r --arg sid "$holder" --arg p "$path" '
    (.read_sets[$sid].reads // [])
    | map(select(.path == $p and ((.is_latest // false) == true)))
    | (.[0].hash // "")
  ' "$state" 2>/dev/null) || prev_hash=""
  if [ -z "$prev_hash" ] || [ "$prev_hash" = "SKIPPED_LARGE" ]; then
    printf 'fallback\tmodified by %s' "${holder:0:8}"
    return 0
  fi
  if command -v coord_hash_file >/dev/null 2>&1 && [ -f "$path" ]; then
    current_hash=$(coord_hash_file "$path" 2>/dev/null) || current_hash=""
  else
    current_hash=""
  fi
  if [ -z "$current_hash" ] || [ "$current_hash" = "SKIPPED_LARGE" ]; then
    printf 'fallback\tmodified by %s' "${holder:0:8}"
    return 0
  fi

  # Tier 2: validator cache lookup. cache_lookup may print the cached
  # diff_summary on stdout — capture before suppression so we can use
  # it on MINOR hits.
  if command -v coord_validator_cache_lookup >/dev/null 2>&1; then
    local cache_hit cache_verdict cache_summary
    cache_hit=$(coord_validator_cache_lookup "$path" "$prev_hash" "$current_hash" 2>/dev/null) \
      || cache_hit=""
    if [ -n "$cache_hit" ]; then
      cache_verdict=$(printf '%s' "$cache_hit" | awk -F'\t' '{print $1}')
      cache_summary=$(printf '%s' "$cache_hit" | awk -F'\t' '{print $3}')
      case "$cache_verdict" in
        SAFE)
          printf 'cache_safe\ttrivial change (no semantic drift)'
          return 0
          ;;
        MINOR)
          if [ -n "$cache_summary" ] && [ "$cache_summary" != "null" ]; then
            printf 'cache_minor\t%s' "$cache_summary"
            return 0
          fi
          ;;
        # CRITICAL is never cached per PR-PHASE4-04; if we somehow see one,
        # fall through.
      esac
    fi
  fi

  # Tier 3: pre-filter classification on snapshots. Suppress stdout
  # AND stderr — only the rc matters here (rc=0 SAFE, rc=1 ESCALATE).
  if command -v coord_validator_prefilter >/dev/null 2>&1 \
     && command -v coord_read_snapshot_lookup >/dev/null 2>&1; then
    if coord_read_snapshot_lookup "$holder" "$prev_hash" >/dev/null 2>&1; then
      if coord_validator_prefilter "$holder" "$path" "$prev_hash" "$current_hash" >/dev/null 2>&1; then
        printf 'prefilter_safe\ttrivial change (whitespace/comment)'
        return 0
      fi
    fi
  fi

  # Tier 4: fallback.
  printf 'fallback\tmodified by %s' "${holder:0:8}"
  return 0
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
  local state="$COORD_DIR/sessions.json"
  if [ ! -f "$state" ]; then
    return 0
  fi

  # Read locks[$path].latest_validator_verdict_ts BEFORE the caller
  # deletes the lock (post_tool_use_write.sh deletes the lock and THEN
  # calls this function — but we read from the snapshot of state
  # taken at jq-time, which is after the deletion. So we accept that
  # tier 1 may not be available for graceful-exit paths; the caller
  # can pass verdict_ts via the optional 5th positional arg.). The
  # lock-release hook (post_tool_use_write.sh) is updated separately
  # in T5.04 to capture verdict_ts BEFORE delete.
  local verdict_ts="${5:-}"
  if [ -z "$verdict_ts" ]; then
    verdict_ts=$(jq -r --arg p "$path" \
      '.locks[$p].latest_validator_verdict_ts // ""' \
      "$state" 2>/dev/null) || verdict_ts=""
    [ "$verdict_ts" = "null" ] && verdict_ts=""
  fi

  # T5.04 / PR-PHASE5-02 §2: wait_queues[<path>] is the authoritative
  # waiter source. The legacy events.jsonl LOCK_DENIED scan is REMOVED
  # entirely (Phase 2 producer side superseded; events.jsonl is now
  # audit-trail-only / read-only).
  local waiters_queue_json
  waiters_queue_json=$(jq -c --arg p "$path" \
      '[ .wait_queues[$p][]? | {session: .session_id, wake_file: .wake_file} ]' \
      "$state" 2>/dev/null || printf '[]')

  local n_queue
  n_queue=$(printf '%s' "$waiters_queue_json" | jq -r 'length' 2>/dev/null || printf '0')

  # Compute diff_summary ONCE (per-release moment) and broadcast to
  # all queued waiters. Helper returns "<tier>\t<summary>" TSV; awk
  # split keeps both pieces.
  local diff_summary='' diff_tier='fallback'
  if [ "${n_queue:-0}" -gt 0 ]; then
    local _ds_tsv
    _ds_tsv=$(_coord_notify_compute_diff_summary "$holder" "$path" "$verdict_ts")
    diff_tier=$(printf '%s' "$_ds_tsv" | awk -F'\t' '{print $1}')
    diff_summary=$(printf '%s' "$_ds_tsv" | awk -F'\t' '{print $2}')
    [ -z "$diff_tier" ] && diff_tier='fallback'
  fi

  # Per-queued-waiter wake_file write.
  if [ "${n_queue:-0}" -gt 0 ]; then
    local wq_idx wq_wake
    wq_idx=0
    while [ "$wq_idx" -lt "$n_queue" ]; do
      wq_wake=$(printf '%s' "$waiters_queue_json" \
        | jq -r --argjson i "$wq_idx" '.[$i].wake_file // ""' 2>/dev/null)
      if [ -n "$wq_wake" ] && [ -e "$wq_wake" ]; then
        printf '%s\n' "$diff_summary" >"$wq_wake" 2>/dev/null || true
      fi
      wq_idx=$((wq_idx + 1))
    done
  fi

  # notifications[<sid>][<path>] string append for queued waiters
  # (durable record; the wake_file is ephemeral and consumed once).
  # Message format preserves the Phase 2 actionable-guidance wording
  # ("You may now retry your write or `coord wait <path>` ...") and
  # appends the T5.04 diff_summary for context.
  if [ "${n_queue:-0}" -gt 0 ]; then
    local holder_short="${holder:0:8}"
    local held_for prefix message
    held_for=$(_coord_notify_seconds_between "$acquired_at" "$released_at")
    if [ -n "$held_for" ]; then
      prefix="Lock released on ${path} (held by ${holder_short}... for ${held_for} sec)."
    else
      prefix="Lock released on ${path} (held by ${holder_short}...)."
    fi
    message="${prefix} diff_summary: ${diff_summary}. You may now retry your write or \`coord wait ${path}\` if you've moved on."
    local sids_json
    sids_json=$(printf '%s' "$waiters_queue_json" | jq -c '[.[].session]' 2>/dev/null || printf '[]')
    if ! coord_atomic_edit "$state" '
          reduce ($waiters[]) as $w (
            .;
            .notifications[$w]         //= {}
            | .notifications[$w][$path] //= []
            | .notifications[$w][$path] += [$msg]
          )
        ' \
        --argjson waiters "$sids_json" \
        --arg path "$path" \
        --arg msg  "$message"; then
      printf 'coord notify_waiters: atomic_edit failed for %s\n' "$path" >&2
    fi
  fi

  # Observability — one event per release-with-waiters (n_queue > 0),
  # with tier and diff_summary present-or-not flag. No event when the
  # release had zero queued waiters (cheap fast path; matches the
  # Phase 2 expectation that NOTIFICATION_PRODUCED gates on
  # waiter_count > 0).
  if [ "${n_queue:-0}" -gt 0 ] && command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=NOTIFICATION_PRODUCED source=lock_release \
      file="$path" waiter_count="$n_queue" \
      diff_summary_source="$diff_tier" \
      diff_summary_present=$([ -n "$diff_summary" ] && printf 1 || printf 0)
  fi
  return 0
}

# CLI shim for ad-hoc / bats use:
#   COORD_DIR=... SESSION_ID=... \
#     notify_waiters.sh <holder> <path> <acquired_at> <released_at> [<verdict_ts>]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$_SHIM_DIR/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$_SHIM_DIR/log_event.sh"
  # shellcheck disable=SC1091
  [ -f "$_SHIM_DIR/validator_cache.sh" ] && . "$_SHIM_DIR/validator_cache.sh"
  # shellcheck disable=SC1091
  [ -f "$_SHIM_DIR/validator_prefilter.sh" ] && . "$_SHIM_DIR/validator_prefilter.sh"
  # shellcheck disable=SC1091
  [ -f "$_SHIM_DIR/read_snapshots.sh" ] && . "$_SHIM_DIR/read_snapshots.sh"
  # shellcheck disable=SC1091
  [ -f "$_SHIM_DIR/hash.sh" ] && . "$_SHIM_DIR/hash.sh"
  coord_notify_lock_release_waiters "$@"
fi

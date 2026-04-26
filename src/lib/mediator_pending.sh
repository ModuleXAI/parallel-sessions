#!/usr/bin/env bash
# mediator_pending.sh — JSONL-based mediator pending queue.
#
# Phase 2 T2.04 introduces the FIRST non-corrupt-state Mediator producer
# kind: `flock_timeout`. Plan §3.7.6 + §5 Phase 2 ("mediator thread")
# describe the pending-flag handoff: a hook detects an anomaly that the
# session itself can't resolve (corrupt sessions.json, flock contention,
# fork-bomb suspicion, schema drift) and writes a pending entry; the
# next tool call's pre_tool_use_any.sh consumes the entry, surfaces a
# banner via additionalContext, and the Phase 3 Mediator agent hook
# eventually decides remediation.
#
# Storage choice (B) — JSONL append-only — chosen over (A) separate
# lock file because:
#   1. Matches the events.jsonl pattern already battle-tested under
#      flock since Phase 0 (the events-side flock acquisition is a
#      proven primitive).
#   2. Avoids "lock-to-log-a-lock-failure" recursion: producers may
#      be invoked from inside an atomic_edit that just timed out on
#      sessions.lock — using a separate lock (pending.lock) sidesteps
#      that, and JSONL append needs only the briefest critical section
#      (open + write + close).
#   3. The consumer can naturally batch multiple unconsumed entries
#      into one banner, useful when a flurry of timeouts fires in
#      a short window.
#
# Layout:
#   $COORD_DIR/mediator/
#     pending.jsonl       — append-only; one JSON object per line.
#     pending.consumed    — single integer = high-water-mark line count
#                           that has been delivered to additionalContext.
#                           Consumer advances this; producer never reads it.
#     pending.lock        — flock target. Producer holds briefly on
#                           append; consumer holds briefly across
#                           "read tail + advance high-water-mark".
#     pending.json        — LEGACY (Phase 1 corrupt_state producer +
#                           coord_consume_corrupt_state_flag consumer).
#                           Left as-is to preserve the Phase 1 corruption
#                           recovery contract; new kinds use pending.jsonl.
#
# Contract:
#   coord_mediator_emit_pending <kind> [<key>=<value> ...]
#     Append one JSON object to pending.jsonl. Reserved keys: ts, kind,
#     session, source. Other key=value pairs land under .payload.
#     Best-effort: returns 0 always, even on flock timeout / disk full /
#     malformed COORD_DIR. Loud stderr warning on failure path.
#
#   coord_mediator_consume_pending
#     Print a banner text covering all unconsumed entries on stdout,
#     advance pending.consumed to the new line count, return 0.
#     If no new entries → return 1 (silent). Caller composes the
#     stdout text into hookSpecificOutput.additionalContext.
#
# Environment:
#   COORD_DIR   — required for both producer and consumer.
#   SESSION_ID  — used by producer for the .session field; defaults to
#                 "unknown" if unset.
#
# Bash 3.2 compat. No `set -euo pipefail` (callers' shell options govern).
# This file is sourced, not executed directly (except via the CLI shim).

# ---------------------------------------------------------------------------
# Producer
# ---------------------------------------------------------------------------
coord_mediator_emit_pending() {
  local kind="${1:-}"; shift || true
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "$COORD_DIR" ]; then
    return 0
  fi
  if [ -z "$kind" ]; then
    printf 'coord mediator_pending: emit called with empty kind\n' >&2
    return 0
  fi
  local mdir="$COORD_DIR/mediator"
  mkdir -p "$mdir" 2>/dev/null || true

  local now session
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    now=$(coord_now_iso8601)
  else
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  session="${SESSION_ID:-unknown}"

  # Build payload object via jq from key=value args. Reserved keys
  # (ts/kind/session/source) land at the top level.
  local source_field=""
  local jq_payload_args=() jq_payload_builder='{}'
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    case "$key" in
      source) source_field="$val" ;;
      *)
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          jq_payload_args+=(--arg "p_$key" "$val")
          jq_payload_builder="$jq_payload_builder | .$key = \$p_$key"
        fi
        ;;
    esac
  done

  local line
  line=$(
    jq -nc \
      --arg ts      "$now" \
      --arg kind    "$kind" \
      --arg session "$session" \
      --arg source  "$source_field" \
      ${jq_payload_args[@]+"${jq_payload_args[@]}"} \
      '{
        ts: $ts,
        kind: $kind,
        session: $session
      }
      + (if $source != "" then {source: $source} else {} end)
      + {payload: ('"$jq_payload_builder"')}
      '
  ) 2>/dev/null || return 0
  [ -z "$line" ] && return 0

  local lockfile="$mdir/pending.lock"
  local jsonl="$mdir/pending.jsonl"
  : >>"$lockfile" 2>/dev/null || true
  (
    if ! flock -x -w 5 9; then
      printf 'coord mediator_pending: lock timeout on append\n' >&2
      exit 0
    fi
    printf '%s\n' "$line" >>"$jsonl" 2>/dev/null || \
      printf 'coord mediator_pending: append failed\n' >&2
  ) 9>"$lockfile"
  return 0
}

# ---------------------------------------------------------------------------
# Consumer
# ---------------------------------------------------------------------------
# Returns 0 if banner text was emitted on stdout; 1 if no new entries.
coord_mediator_consume_pending() {
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "$COORD_DIR" ]; then
    return 1
  fi
  local mdir="$COORD_DIR/mediator"
  local jsonl="$mdir/pending.jsonl"
  local hwm_file="$mdir/pending.consumed"
  local lockfile="$mdir/pending.lock"
  [ -f "$jsonl" ] || return 1

  : >>"$lockfile" 2>/dev/null || true

  # Read total count + prior HWM under flock; capture the new entries to
  # a temp file so we can release the lock before formatting.
  local total prior new_entries_tmp banner_rc=1
  new_entries_tmp=$(mktemp -t coord-pending-XXXX 2>/dev/null) || return 1

  (
    if ! flock -x -w 5 9; then
      exit 1
    fi
    if [ ! -f "$jsonl" ]; then
      exit 1
    fi
    total=$(wc -l <"$jsonl" 2>/dev/null | tr -d ' ' || printf '0')
    if [ -f "$hwm_file" ]; then
      prior=$(cat "$hwm_file" 2>/dev/null | tr -d ' \n' || printf '0')
    else
      prior=0
    fi
    case "$prior" in *[!0-9]*|'') prior=0 ;; esac
    case "$total" in *[!0-9]*|'') total=0 ;; esac
    if [ "$total" -le "$prior" ]; then
      exit 1
    fi
    # tail starting at line (prior+1)
    local skip=$(( prior ))
    tail -n +$(( skip + 1 )) "$jsonl" >"$new_entries_tmp" 2>/dev/null
    # Advance HWM atomically (temp + rename in same dir).
    printf '%s\n' "$total" >"$hwm_file.tmp.$$" 2>/dev/null || exit 1
    mv "$hwm_file.tmp.$$" "$hwm_file" 2>/dev/null || exit 1
  ) 9>"$lockfile"
  banner_rc=$?

  if [ "$banner_rc" -ne 0 ] || [ ! -s "$new_entries_tmp" ]; then
    rm -f "$new_entries_tmp" 2>/dev/null
    return 1
  fi

  # Format the banner — one bullet per entry.
  # We DELIBERATELY phrase this without apostrophes (F-014 lesson) so
  # bats tests that pipe output through `bash -c "echo '$output' | …"`
  # can scan the text safely.
  local n_new
  n_new=$(wc -l <"$new_entries_tmp" | tr -d ' ')
  local body
  body=$(jq -r '
    "  - kind=" + (.kind // "?")
    + (if .source then " source=" + .source else "" end)
    + (if (.payload // {}) | length > 0 then
         " payload="
         + ((.payload | to_entries | map(.key + "=" + (.value | tostring)) | join(", ")))
       else "" end)
  ' "$new_entries_tmp" 2>/dev/null)
  rm -f "$new_entries_tmp" 2>/dev/null

  printf 'Coord Mediator pending (%d new entr%s); the Phase 3 Mediator will diagnose. Recent entries:\n%s' \
    "$n_new" "$( [ "$n_new" -eq 1 ] && printf 'y' || printf 'ies' )" "$body"
  return 0
}

# ---------------------------------------------------------------------------
# CLI shim — primarily for ad-hoc + bats use.
#   mediator_pending.sh emit <kind> [k=v ...]
#   mediator_pending.sh consume
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$_SHIM_DIR/log_event.sh"
  case "${1:-}" in
    emit)    shift; coord_mediator_emit_pending "$@" ;;
    consume) coord_mediator_consume_pending && exit 0 || exit 1 ;;
    *) printf 'usage: mediator_pending.sh {emit <kind> [k=v ...] | consume}\n' >&2; exit 2 ;;
  esac
fi

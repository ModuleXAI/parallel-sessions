#!/usr/bin/env bash
# log_event.sh — append a structured event to $COORD_DIR/events.jsonl.
#
# Contract (plan §3.5, §4, §A.5 "Event logging is non-blocking"):
#   coord_log_event kind=<K> [tool=<T>] [file=<F>] [hash=<H>] [<key>=<value> ...]
#     appends one JSON object per line to events.jsonl; the append is
#     backgrounded (`&`) so hook callers don't pay for the IO.
#     The backgrounded subshell briefly holds flock on events.lock to keep
#     multi-session writes non-interleaving.
#
# Never fails the caller: on disk full / flock timeout / jq error, writes a
# note to stderr (swallowed by caller's redirect) and returns 0.
#
# Environment:
#   COORD_DIR   — base coord dir (usually "<repo>/.coord"). Required.
#   SESSION_ID  — current session UUID. Required.
#   CORE_SCHEMA_VERSION — defaults to "1.0".

set -euo pipefail

: "${CORE_SCHEMA_VERSION:=1.0}"

# coord_now_iso8601 — RFC-3339 UTC timestamp with ms precision where available.
# Uses perl (ships on macOS and Linux; see Decision 2.1 note in FINDINGS F-009).
# Falls back to second precision if perl is absent.
coord_now_iso8601() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=gettimeofday -e '
      my ($s,$us) = gettimeofday();
      my $ms = int($us/1000);
      my @t  = gmtime($s);
      printf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ\n",
        $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0],$ms;
    ' 2>/dev/null && return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# _coord_log_event_build_line <kv ...>
#   Internal: parse the same k=v args coord_log_event accepts and
#   build the JSON event line via jq -n. Stdout: JSON line on
#   success; rc=0 always (silent on jq failure → empty line).
#   Used by both coord_log_event (async) and coord_log_event_sync
#   (foreground; T7.06a per F-016 fix). Logic factored verbatim
#   from the pre-T7.06a coord_log_event implementation.
_coord_log_event_build_line() {
  local ts
  ts=$(coord_now_iso8601)
  local session="${SESSION_ID:-unknown}"

  local kind="" tool="" file="" hash=""
  local jq_payload_args=() jq_payload_builder='{}'
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    case "$key" in
      kind) kind="$val" ;;
      tool) tool="$val" ;;
      file) file="$val" ;;
      hash) hash="$val" ;;
      *)
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          jq_payload_args+=(--arg "p_$key" "$val")
          jq_payload_builder="$jq_payload_builder | .$key = \$p_$key"
        fi
        ;;
    esac
  done
  if [ -z "$kind" ]; then
    kind=INFO
  fi

  jq -nc \
    --arg ts      "$ts" \
    --arg session "$session" \
    --arg kind    "$kind" \
    --arg tool    "$tool" \
    --arg file    "$file" \
    --arg hash    "$hash" \
    ${jq_payload_args[@]+"${jq_payload_args[@]}"} \
    '{
      ts: $ts,
      session: $session,
      kind: $kind
    }
    + (if $tool != "" then {tool: $tool} else {} end)
    + (if $file != "" then {file: $file} else {} end)
    + (if $hash != "" then {hash: $hash} else {} end)
    + {payload: ('"$jq_payload_builder"')}
    ' 2>/dev/null || true
  return 0
}

coord_log_event() {
  local coord_dir="${COORD_DIR:-}"
  if [ -z "$coord_dir" ] || [ ! -d "$coord_dir" ]; then
    # No coord dir configured → nothing to log, silent no-op.
    return 0
  fi

  local line
  line=$(_coord_log_event_build_line "$@")
  if [ -z "$line" ]; then
    return 0  # jq failure → silent no-op
  fi

  # Background append under brief flock. Failures print to stderr only.
  {
    (
      flock -x -w 5 9 || { printf '%s\n' "coord: log_event flock timeout" >&2; exit 0; }
      printf '%s\n' "$line" >>"$coord_dir/events.jsonl" 2>/dev/null || \
        printf '%s\n' "coord: log_event append failed" >&2
    ) 9>"$coord_dir/events.lock"
  } &
  # Disown so the caller exits immediately even if the subshell is slow.
  disown >/dev/null 2>&1 || true
  return 0
}

# coord_log_event_sync <kv ...>
#   Phase 7 / T7.06a (F-016 fix). Same arg contract as
#   coord_log_event, but the flock+append runs in the FOREGROUND
#   subshell — the function returns only after events.jsonl write
#   has completed and flock has been released. Use this in any
#   "log-then-exit" path where the caller is about to exit before
#   the kernel could schedule a backgrounded subshell to flush.
#
#   Canonical caller: src/bin/coord cmd_wait::cleanup_interrupt
#   (SIGINT trap that emits WAIT_TIMEOUT(reason=interrupted) then
#   `exit 130`). Async variant raced exit-130 in bats, leaving the
#   audit-log entry missing intermittently (F-016 root cause).
#
#   Same fail-soft posture as the async variant: never raises rc=1
#   to caller — silent on jq failure, no-op on missing COORD_DIR.
coord_log_event_sync() {
  local coord_dir="${COORD_DIR:-}"
  if [ -z "$coord_dir" ] || [ ! -d "$coord_dir" ]; then
    return 0
  fi

  local line
  line=$(_coord_log_event_build_line "$@")
  if [ -z "$line" ]; then
    return 0
  fi

  # Foreground append under brief flock. Subshell runs to
  # completion before this function returns — guaranteed
  # events.jsonl flush before caller proceeds.
  (
    flock -x -w 5 9 || { printf '%s\n' "coord: log_event_sync flock timeout" >&2; exit 0; }
    printf '%s\n' "$line" >>"$coord_dir/events.jsonl" 2>/dev/null || \
      printf '%s\n' "coord: log_event_sync append failed" >&2
  ) 9>"$coord_dir/events.lock"
  return 0
}

# CLI shim for bats / ad-hoc:  log_event.sh kind=READ tool=Read file=/foo ...
#   Optional --sync flag dispatches to coord_log_event_sync.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "${1:-}" = "--sync" ]; then
    shift
    coord_log_event_sync "$@"
  else
    coord_log_event "$@"
  fi
fi

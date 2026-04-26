#!/usr/bin/env bash
# atomic_write.sh — the coordinator's single-source-of-truth mutator.
#
# Contract (plan §4 + Decision 2.3):
#   coord_atomic_edit <state_file> <jq_filter> [<jq_arg> ...]
#     1. flock -x on the sentinel file (<state_file>.lock) with -w 5 s.
#     2. Read current state; if missing or unparseable, reset to empty
#        template and flag Mediator (§B.9.1/§B.9.2).
#     3. Apply `jq <jq_filter>` (any extra args forwarded to jq, e.g.
#        `--arg`, `--argjson`).
#     4. Write to <state_file>.tmp.<pid> and `mv` over the target
#        (atomic rename on POSIX local fs — plan §4).
#     5. Release flock.
#
#   Exit codes (plan §4):
#     0  success
#    42  flock timeout (>5 s)              — caller decides fail-open/closed
#    43  jq non-zero during filter         — caller must escalate
#    44  write failure (temp + rename)     — caller must escalate
#
# Callers MUST NOT write sessions.json any other way.
# See FINDINGS F-003: the subshell + redirected-fd flock form is the
# portable contract; do not use `flock ... --`.
#
# Also provides:
#   coord_atomic_reset <state_file>        — reset to empty valid template,
#                                            archive old content if non-empty.
#   coord_state_empty_template             — prints the empty state JSON.

set -euo pipefail

# Mediator pending helper. Producer-side: when coord_atomic_edit hits a
# flock-acquisition timeout (rc=42), we want to emit a flock_timeout
# entry into the JSONL pending queue so the next pre_tool_use_any.sh
# surfaces it. Sourcing here so every caller of atomic_write picks it
# up (no per-caller wiring); mediator_pending.sh has no dependency on
# atomic_write.sh, avoiding a cycle.
_ATOMIC_WRITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_ATOMIC_WRITE_DIR/mediator_pending.sh" ]; then
  # shellcheck disable=SC1091
  . "$_ATOMIC_WRITE_DIR/mediator_pending.sh"
fi
# T3.07: critical_check.sh provides coord_critical_record_parse_failure
# (3x consecutive parse failures → lockdown directly per PR-PHASE3-01
# critical-bypass disposition). Lockdown helpers loaded lazily inside
# the helper itself to avoid sourcing cycles.
if [ -f "$_ATOMIC_WRITE_DIR/critical_check.sh" ]; then
  # shellcheck disable=SC1091
  . "$_ATOMIC_WRITE_DIR/critical_check.sh"
fi
if [ -f "$_ATOMIC_WRITE_DIR/lockdown.sh" ]; then
  # shellcheck disable=SC1091
  . "$_ATOMIC_WRITE_DIR/lockdown.sh"
fi

coord_state_empty_template() {
  # Emitted via jq to guarantee a canonical JSON object.
  jq -n '{
    schema_version: "1.0",
    sessions: {},
    locks: {},
    wait_queue: {},
    read_sets: {},
    notifications: {},
    self_tasks: {},
    anomaly_votes: {},
    task_graph: {}
  }'
}

coord_atomic_edit() {
  local state_file="$1"; shift
  local jq_filter="$1"; shift
  # Remaining positional args passed to jq (--arg/--argjson pairs).

  local lock_file="${state_file}.lock"
  local dir
  dir=$(dirname "$state_file")
  mkdir -p "$dir"
  if [ ! -e "$lock_file" ]; then
    : >"$lock_file"
  fi

  local rc=0
  # Subshell + redirected fd per F-003.
  (
    if ! flock -x -w 5 9; then
      exit 42
    fi

    local cur
    if [ -f "$state_file" ]; then
      cur=$(cat "$state_file" 2>/dev/null || printf '')
    else
      cur=""
    fi

    # Validate parse. Corrupt → archive + reset (fail-open per §B.9.2).
    if [ -z "$cur" ] || ! printf '%s' "$cur" | jq -e . >/dev/null 2>&1; then
      local ts
      ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
      if [ -n "$cur" ] && [ -f "$state_file" ]; then
        cp "$state_file" "${state_file}.corrupt.$ts.json" 2>/dev/null || true
      fi
      cur=$(coord_state_empty_template)
      # Write the reset state as the base before the filter runs.
      : >"${state_file}.tmp.$$"
      printf '%s' "$cur" >"${state_file}.tmp.$$"
      if ! mv "${state_file}.tmp.$$" "$state_file"; then
        rm -f "${state_file}.tmp.$$"
        exit 44
      fi
      # Emit a Mediator pending JSONL entry so downstream hooks surface
      # the reset (PR-PHASE3-03 / Decision 4: corrupt_state migrates to
      # pending.jsonl alongside flock_timeout + Phase 3 new kinds).
      # The producer is the existing T2.04 helper; this avoids the
      # legacy single-entry pending.json file entirely. install.sh
      # migrates any pre-Phase-3 pending.json into the JSONL queue at
      # install/repair time.
      if [ -n "${COORD_DIR:-}" ] && command -v coord_mediator_emit_pending >/dev/null 2>&1; then
        local archived_path=""
        if [ -f "${state_file}.corrupt.$ts.json" ]; then
          archived_path="${state_file}.corrupt.$ts.json"
        fi
        coord_mediator_emit_pending corrupt_state \
          source=atomic_write \
          file="$state_file" \
          archived_to="$archived_path" \
          detected_at="$ts" || true
      fi
      # T3.07 critical bypass: increment the parse-fail counter. After
      # 3 consecutive failures the helper triggers lockdown directly
      # (skipping Mediator, since its analysis would be unsafe on
      # repeatedly-corrupt state).
      if command -v coord_critical_record_parse_failure >/dev/null 2>&1; then
        coord_critical_record_parse_failure || true
      fi
    else
      # Successful parse — reset the parse-fail counter so a single
      # successful read clears any prior streak.
      if command -v coord_critical_reset_parse_counter >/dev/null 2>&1; then
        coord_critical_reset_parse_counter || true
      fi
    fi

    local new
    if ! new=$(printf '%s' "$cur" | jq "$@" "$jq_filter" 2>/dev/null); then
      exit 43
    fi
    if [ -z "$new" ]; then
      exit 43
    fi

    # Atomic write: temp then rename. mktemp in same dir for rename-atomicity.
    local tmp
    tmp="${state_file}.tmp.$$"
    printf '%s\n' "$new" >"$tmp" || { rm -f "$tmp"; exit 44; }
    if ! mv "$tmp" "$state_file"; then
      rm -f "$tmp"
      exit 44
    fi
  ) 9>"$lock_file" || rc=$?

  # Phase 2 T2.04: emit a Mediator flock_timeout pending entry so the
  # next pre_tool_use_any.sh consumer surfaces it. Best-effort; never
  # fails the caller. The producer uses its own pending.lock, NOT the
  # sessions.lock that just timed out, so there is no recursion risk.
  if [ "$rc" = "42" ] && command -v coord_mediator_emit_pending >/dev/null 2>&1; then
    coord_mediator_emit_pending flock_timeout \
      "source=atomic_write" \
      "file=$state_file" \
      "lock=$lock_file" \
      "timeout_sec=5" \
      "attempted_op=atomic_edit" || true
  fi

  return "$rc"
}

coord_atomic_reset() {
  local state_file="$1"
  local lock_file="${state_file}.lock"
  mkdir -p "$(dirname "$state_file")"
  : >"$lock_file"
  (
    if ! flock -x -w 5 9; then exit 42; fi
    local ts
    ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    if [ -s "$state_file" ]; then
      cp "$state_file" "${state_file}.reset.$ts.json" 2>/dev/null || true
    fi
    coord_state_empty_template >"${state_file}.tmp.$$"
    mv "${state_file}.tmp.$$" "$state_file" || { rm -f "${state_file}.tmp.$$"; exit 44; }
  ) 9>"$lock_file"
}

# coord_consume_corrupt_state_flag
#   Implements §B.9.2 step 4 in the JSONL world (PR-PHASE3-03 /
#   Decision 4): scans pending.jsonl for any unconsumed entries with
#   kind=corrupt_state. If at least one exists, prints the user-facing
#   banner text on stdout and returns 0. The HWM advance is owned by
#   coord_mediator_consume_pending (the unified consumer); this dedicated
#   consumer only emits the friendly-text banner. consume_pending's own
#   banner SKIPS corrupt_state entries to prevent double-display.
#
#   Returns 0 if a banner was emitted; 1 if no unconsumed corrupt_state
#   entry found / pending.jsonl absent / parse error.
#
#   This function does NOT format the JSON envelope — it just prints the
#   banner text. Callers wrap it with their own jq -nc shape.
coord_consume_corrupt_state_flag() {
  [ -z "${COORD_DIR:-}" ] && return 1
  local jsonl="${COORD_DIR}/mediator/pending.jsonl"
  local hwm_file="${COORD_DIR}/mediator/pending.consumed"
  [ -f "$jsonl" ] || return 1
  local hwm=0
  if [ -f "$hwm_file" ]; then
    hwm=$(cat "$hwm_file" 2>/dev/null | tr -d ' \n')
    case "$hwm" in *[!0-9]*|'') hwm=0 ;; esac
  fi
  local found
  found=$(tail -n +$((hwm + 1)) "$jsonl" 2>/dev/null \
    | jq -rs '[.[] | select(.kind == "corrupt_state")] | length' 2>/dev/null) || found=0
  case "$found" in *[!0-9]*|'') found=0 ;; esac
  if [ "$found" -eq 0 ]; then
    return 1
  fi
  printf 'Coord: coordination state was reset due to corruption. Mediator will diagnose; prior locks are lost. Retry your operation.'
  return 0
}

# coord_atomic_rewrite_jsonl <jsonl_file> <jq_filter>
#   Atomically rewrite a JSONL file by passing each line through
#   `jq -c <filter>` and keeping only entries that emit a non-null
#   object. Used by Mediator GC (PR-PHASE3-04) and any future
#   JSONL-rewrite use case.
#
#   <filter> is a jq expression evaluated per-entry (jq -c, not -cs).
#   Common patterns:
#     'select(.valid_until | fromdateiso8601 > $now)' — expire
#     'select(.kind != "corrupt_state")'              — filter
#     '. | .ts |= sub("Z"; "+00:00") | .'             — transform
#
#   Returns 0 on success; non-zero on flock timeout (42), jq error
#   (43), or rename failure (44). Caller decides escalation.
coord_atomic_rewrite_jsonl() {
  local jsonl="$1"
  local filter="$2"
  [ -z "$jsonl" ] && return 1
  [ -z "$filter" ] && return 1
  [ -f "$jsonl" ] || return 0   # nothing to rewrite
  local lock_file="${jsonl}.lock"
  [ -f "$lock_file" ] || : >"$lock_file"
  local tmp="${jsonl}.tmp.$$.$RANDOM"
  (
    flock -x -w 5 9 || exit 42
    jq -c "$filter" "$jsonl" >"$tmp" 2>/dev/null || { rm -f "$tmp"; exit 43; }
    mv -f "$tmp" "$jsonl" 2>/dev/null || { rm -f "$tmp"; exit 44; }
  ) 9>"$lock_file"
}

# CLI shim for tests and ad-hoc use:
#   atomic_write.sh edit  <state_file> <jq_filter> [<jq_args> ...]
#   atomic_write.sh reset <state_file>
#   atomic_write.sh template          (prints empty template)
#   atomic_write.sh consume-corrupt-banner  (prints + clears pending flag)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    edit)      shift; coord_atomic_edit "$@" ;;
    reset)     shift; coord_atomic_reset "$@" ;;
    template)  coord_state_empty_template ;;
    consume-corrupt-banner) coord_consume_corrupt_state_flag ;;
    *) printf 'usage: atomic_write.sh {edit|reset|template|consume-corrupt-banner} ...\n' >&2; exit 2 ;;
  esac
fi

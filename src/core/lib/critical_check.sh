#!/usr/bin/env bash
# critical_check.sh — Phase 3 / T3.07 critical-conditions bypass for the
# Mediator (PR-PHASE3-01 disposition for "critical conditions that
# bypass Mediator entirely").
#
# Some failure modes are so degraded that even Mediator analysis would
# be risky (Mediator's own context loading would inherit the corrupt
# state and produce a wrong verdict). For these, we skip Mediator
# spawn entirely and trigger lockdown directly with
# reason_source=critical_bypass.
#
# Bypass triggers (T3.07 implements the FIRST; others are documented
# in CLAUDE.md §B.10 as future-work):
#
#   1. sessions.json fails jq parse 3+ consecutive times.
#      Mediator can't read it; Mediator's own atomic_edit calls would
#      fail; lockdown is the safe response while a human inspects.
#
# Future triggers (Phase 4+ for hand-tuning):
#   - Two ACTIVE sessions sharing the same PID (impossible in valid
#     state).
#   - sessions.schema_version mismatch between disk and lib code.
#   - Locks count > 100 (suggests runaway / fork-bomb).
#
# Counter persistence: .coord/mediator/critical_counters.json with the
# field `sessions_jsonl_parse_fails`. Atomic counter via temp+rename.
# Caller increments on parse failure, decrements (or resets) on success.
#
# Public functions:
#   coord_critical_record_parse_failure
#       Increment the persistent parse-fail counter. If the counter
#       reaches the threshold (default 3), trigger lockdown directly +
#       emit CRITICAL_CONDITION_DETECTED event. Returns 0.
#   coord_critical_reset_parse_counter
#       Reset the counter to 0 (called on a successful parse).
#   coord_critical_check_thresholds
#       Read-only check against thresholds. Returns 0 if any threshold
#       is exceeded; 1 otherwise. Used by hooks that want to gate
#       behavior (e.g., refuse to spawn Mediator) without mutating the
#       counter state.
#
# Bash 3.2 compat. No `set -euo pipefail` (sourced; caller governs).

: "${COORD_CRITICAL_PARSE_FAIL_THRESHOLD:=3}"

_coord_critical_counter_file() {
  printf '%s/mediator/critical_counters.json' "${COORD_DIR:-}"
}

_coord_critical_counter_lock() {
  printf '%s/mediator/critical_counters.lock' "${COORD_DIR:-}"
}

# Read the current parse-fail count (0 if file missing or unreadable).
_coord_critical_read_parse_count() {
  local f
  f=$(_coord_critical_counter_file)
  [ -f "$f" ] || { printf '0'; return; }
  local val
  val=$(jq -r '.sessions_jsonl_parse_fails // 0' "$f" 2>/dev/null || printf '0')
  case "$val" in *[!0-9]*|'') val=0 ;; esac
  printf '%d' "$val"
}

# Atomic write of new counter value via temp+rename under flock.
_coord_critical_write_parse_count() {
  local new_val="$1"
  local f lockfile mdir
  f=$(_coord_critical_counter_file)
  lockfile=$(_coord_critical_counter_lock)
  mdir="${COORD_DIR}/mediator"
  [ -d "$mdir" ] || mkdir -p "$mdir" 2>/dev/null || return 1
  : >>"$lockfile" 2>/dev/null || true
  local tmp="${f}.tmp.$$.$RANDOM"
  (
    flock -x -w 5 9 || exit 42
    jq -nc --argjson n "$new_val" '{sessions_jsonl_parse_fails: $n}' >"$tmp" 2>/dev/null \
      || { rm -f "$tmp"; exit 43; }
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; exit 44; }
  ) 9>"$lockfile"
}

# coord_critical_record_parse_failure
#   Called by hooks/atomic_write when sessions.json parse fails. If
#   threshold reached, triggers lockdown directly and emits
#   CRITICAL_CONDITION_DETECTED.
coord_critical_record_parse_failure() {
  [ -z "${COORD_DIR:-}" ] && return 0
  local cur new
  cur=$(_coord_critical_read_parse_count)
  new=$(( cur + 1 ))
  _coord_critical_write_parse_count "$new" || return 0
  if [ "$new" -lt "$COORD_CRITICAL_PARSE_FAIL_THRESHOLD" ]; then
    return 0   # threshold not yet reached
  fi
  # Threshold reached: trigger lockdown directly (skipping Mediator)
  # IF we have access to lockdown helpers AND lockdown is not already
  # active.
  if command -v coord_lockdown_check >/dev/null 2>&1; then
    if coord_lockdown_check; then
      return 0   # already locked down — nothing more to do
    fi
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=CRITICAL_CONDITION_DETECTED \
      condition=repeated_jq_parse_failure \
      triggering_observation="sessions.json parse failed $new consecutive times" \
      threshold="$COORD_CRITICAL_PARSE_FAIL_THRESHOLD" 2>/dev/null || true
  fi
  if command -v coord_lockdown_activate >/dev/null 2>&1; then
    coord_lockdown_activate \
      "sessions.json parse failed $new consecutive times; Mediator analysis would be unsafe — operator inspection required" \
      "critical_bypass" 2>/dev/null || true
  fi
  return 0
}

# coord_critical_reset_parse_counter
#   Reset the counter to 0. Caller invokes on a successful parse to
#   avoid stale escalation from old failures.
coord_critical_reset_parse_counter() {
  [ -z "${COORD_DIR:-}" ] && return 0
  local cur
  cur=$(_coord_critical_read_parse_count)
  [ "$cur" = "0" ] && return 0
  _coord_critical_write_parse_count 0 || return 0
  return 0
}

# coord_critical_check_thresholds
#   Read-only check. Returns 0 if any critical threshold is exceeded
#   (i.e., a Mediator spawn should be refused), 1 otherwise.
coord_critical_check_thresholds() {
  [ -z "${COORD_DIR:-}" ] && return 1
  local cur
  cur=$(_coord_critical_read_parse_count)
  [ "$cur" -ge "$COORD_CRITICAL_PARSE_FAIL_THRESHOLD" ] && return 0
  return 1
}

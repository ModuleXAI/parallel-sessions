#!/usr/bin/env bash
# 03_corrupt_state_recovery/timeline.sh — critical bypass + operator
# --resume.

set -uo pipefail

scenario_run() {
  local hooks="$COORD_DIR/hooks"
  local sid_a="sid-a-corrupt-0001"

  # 1. Register Session A so .active marker exists.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/session_start.sh" >/dev/null

  # 2. Drive 3 consecutive parse failures via atomic_edit. Re-corrupt
  # before each call so the streak doesn't reset on the auto-archive.
  for i in 1 2 3; do
    printf 'corrupt {{{' >"$COORD_DIR/sessions.json"
    bash -c "
      export COORD_DIR='$COORD_DIR'
      . '$COORD_DIR/lib/log_event.sh'
      . '$COORD_DIR/lib/mediator_pending.sh'
      . '$COORD_DIR/lib/lockdown.sh'
      . '$COORD_DIR/lib/critical_check.sh'
      . '$COORD_DIR/lib/atomic_write.sh'
      coord_atomic_edit '$COORD_DIR/sessions.json' '.dummy = $i' --argjson i $i 2>/dev/null
    " >/dev/null 2>&1 || true
  done

  # Capture pre-resume state for assertions.
  PRE_RESUME_LOCKDOWN_EXISTS="0"
  PRE_RESUME_REASON_SOURCE=""
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    PRE_RESUME_LOCKDOWN_EXISTS="1"
    PRE_RESUME_REASON_SOURCE=$(jq -r '.reason_source // ""' "$COORD_DIR/mediator/lockdown.json")
  fi
  export PRE_RESUME_LOCKDOWN_EXISTS PRE_RESUME_REASON_SOURCE

  sleep 0.2

  # 3. Operator runs `coord mediate --resume`.
  local coord_bin="$COORD_DIR/bin/coord"
  COORD_DIR="$COORD_DIR" "$coord_bin" mediate --resume >/dev/null 2>&1 || true

  # 4. Reset the parse counter manually (the atomic_edit-success path
  # would do this on next successful edit; we trigger one here for
  # determinism).
  bash -c "
    export COORD_DIR='$COORD_DIR'
    . '$COORD_DIR/lib/log_event.sh'
    . '$COORD_DIR/lib/lockdown.sh'
    . '$COORD_DIR/lib/critical_check.sh'
    coord_critical_reset_parse_counter
  " >/dev/null

  sleep 0.2
}

scenario_assert() {
  local fail=0

  # C.1: lockdown was active with reason_source=critical_bypass before
  # --resume.
  if [ "${PRE_RESUME_LOCKDOWN_EXISTS:-0}" != "1" ]; then
    printf '  FAIL C.1: lockdown was not active after 3 consecutive parse failures\n' >&2; fail=1
  elif [ "$PRE_RESUME_REASON_SOURCE" != "critical_bypass" ]; then
    printf '  FAIL C.1: lockdown reason_source=%s (expected critical_bypass)\n' \
      "$PRE_RESUME_REASON_SOURCE" >&2; fail=1
  fi

  # C.2: CRITICAL_CONDITION_DETECTED event recorded.
  local cc_count
  cc_count=$(jq -rs '[.[] | select(.kind == "CRITICAL_CONDITION_DETECTED")] | length' \
    "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$cc_count" -lt 1 ]; then
    printf '  FAIL C.2: no CRITICAL_CONDITION_DETECTED event (count=%s)\n' "$cc_count" >&2; fail=1
  fi

  # C.3: lockdown.json is gone after --resume.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL C.3: lockdown still active after --resume\n' >&2; fail=1
  fi

  # C.4: archived to lockdown_archive/.
  local archive_count
  archive_count=$(ls -1 "$COORD_DIR/mediator/lockdown_archive/"*.cleared.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "$archive_count" -lt 1 ]; then
    printf '  FAIL C.4: no archived lockdown file\n' >&2; fail=1
  fi

  # C.5: sessions.json parses cleanly.
  if ! jq -e . "$COORD_DIR/sessions.json" >/dev/null 2>&1; then
    printf '  FAIL C.5: sessions.json still does not parse\n' >&2; fail=1
  fi

  return "$fail"
}

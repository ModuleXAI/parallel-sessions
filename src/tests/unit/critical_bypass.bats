#!/usr/bin/env bats
# Tests for lib/critical_check.sh — critical-conditions bypass
# (Phase 3 / T3.07 / PR-PHASE3-01 disposition).
#
# When sessions.json fails jq parse 3+ consecutive times, the next
# parse-failure record triggers lockdown directly with
# reason_source=critical_bypass, skipping Mediator (whose own analysis
# would inherit the corrupt state).
#
# Coverage:
#   - Counter increments on each parse failure
#   - Counter resets on successful parse
#   - 3rd consecutive failure activates lockdown
#   - Lockdown's reason_source = critical_bypass
#   - Mediator spawn refuses while critical condition is active

load "../helpers/common"

CC="$SRC_ROOT/core/lib/critical_check.sh"
LK="$SRC_ROOT/core/lib/lockdown.sh"
LE="$SRC_ROOT/core/lib/log_event.sh"
MS="$SRC_ROOT/core/lib/mediator_spawn.sh"

setup() {
  TMP="$(mktemp -d -t coord-cb-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
}

teardown() {
  unset COORD_DIR CLAUDE_CODE_MEDIATOR
  rm -rf "$TMP"
}

_call() {
  bash -c '. "'"$LE"'"; . "'"$LK"'"; . "'"$CC"'"; '"$*"
}

@test "counter: starts at 0 when counters file missing" {
  run _call '_coord_critical_read_parse_count'
  [ "$output" = "0" ]
}

@test "record_parse_failure: 1st call increments counter to 1, no lockdown" {
  _call 'coord_critical_record_parse_failure'
  run _call '_coord_critical_read_parse_count'
  [ "$output" = "1" ]
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
}

@test "record_parse_failure: 2nd call increments to 2, no lockdown" {
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  run _call '_coord_critical_read_parse_count'
  [ "$output" = "2" ]
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
}

@test "record_parse_failure: 3rd consecutive call activates lockdown with reason_source=critical_bypass" {
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  run jq -r '.reason_source' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "critical_bypass" ]
  run jq -r '.reason' "$COORD_DIR/mediator/lockdown.json"
  echo "$output" | grep -q "parse failed 3 consecutive times"
  # CRITICAL_CONDITION_DETECTED event emitted.
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "CRITICAL_CONDITION_DETECTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "reset_parse_counter: clears prior fails so next 3-streak starts fresh" {
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_reset_parse_counter'
  run _call '_coord_critical_read_parse_count'
  [ "$output" = "0" ]
  # Now a fresh 3-streak is needed to activate lockdown — proving the
  # reset broke the prior partial streak.
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
  _call 'coord_critical_record_parse_failure'
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
}

@test "check_thresholds: returns 0 (exceeded) once counter >= threshold; 1 below" {
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  run _call 'coord_critical_check_thresholds'
  [ "$status" -eq 1 ]
  _call 'coord_critical_record_parse_failure'
  run _call 'coord_critical_check_thresholds'
  [ "$status" -eq 0 ]
}

@test "mediator_spawn: refuses with reason=critical_bypass_active when threshold exceeded" {
  # Drive the counter to threshold + activate lockdown.
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  _call 'coord_critical_record_parse_failure'
  # Now try to spawn — must refuse without invoking claude.
  : >"$COORD_DIR/mediator/pending.jsonl"
  : >"$COORD_DIR/mediator/pending.lock"
  run bash -c "
    . '$LE'
    . '$LK'
    . '$CC'
    . '$SRC_ROOT/core/lib/mediator_pending.sh'
    . '$SRC_ROOT/core/lib/atomic_write.sh'
    . '$MS'
    coord_mediator_spawn synthetic-pending-id 1
  "
  [ "$status" -eq 1 ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_REFUSED" and .payload.reason == "critical_bypass_active")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "atomic_write integration: 3 consecutive corrupt parses → lockdown via atomic_edit producer" {
  # End-to-end: corrupt sessions.json + run atomic_edit 3 times.
  : >"$COORD_DIR/mediator/pending.jsonl"
  : >"$COORD_DIR/mediator/pending.lock"
  printf 'not json {{{' >"$COORD_DIR/sessions.json"
  for i in 1 2 3; do
    bash -c "
      export COORD_DIR='$COORD_DIR'
      . '$LE'
      . '$SRC_ROOT/core/lib/mediator_pending.sh'
      . '$LK'
      . '$CC'
      . '$SRC_ROOT/core/lib/atomic_write.sh'
      printf 'not json {{{' >'$COORD_DIR/sessions.json'  # re-corrupt before each call
      coord_atomic_edit '$COORD_DIR/sessions.json' '.dummy = 1'
    " >/dev/null 2>&1 || true
    # Re-corrupt for next iteration to maintain the streak.
    printf 'not json {{{' >"$COORD_DIR/sessions.json"
  done
  # After 3 streak, lockdown should be active.
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  run jq -r '.reason_source' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "critical_bypass" ]
}

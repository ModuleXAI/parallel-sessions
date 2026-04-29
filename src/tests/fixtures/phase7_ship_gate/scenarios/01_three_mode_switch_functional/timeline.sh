#!/usr/bin/env bash
# 01_three_mode_switch_functional — Plan §7 revised Done-when #1:
# "Three-mode COORD_TEST_MODE switch functional and switchable;
#  bats default mock mode passes; realistic-mode opt-in tag works."
#
# Verifies:
#   a. mock mode (default + explicit) → all 3 sites mock-routed
#   b. semi mode → Mediator + Task Processor real; Validator mock
#   c. realistic mode → all 3 sites real
#   d. invalid env-var → fail-closed to mock + WARNING + audit event
set -uo pipefail

scenario_run() {
  # Resolve mode in a sub-shell per mode value. Each invocation is
  # a fresh process — no cache contamination across mode switches.
  RESOLVED_UNSET=$(coord_fixture_p7_resolve_in_mode '' 2>&1) || RESOLVED_UNSET="(failed)"
  RESOLVED_MOCK=$(coord_fixture_p7_resolve_in_mode mock 2>&1) || RESOLVED_MOCK="(failed)"
  RESOLVED_SEMI=$(coord_fixture_p7_resolve_in_mode semi 2>&1) || RESOLVED_SEMI="(failed)"
  RESOLVED_REALISTIC=$(coord_fixture_p7_resolve_in_mode realistic 2>&1) || RESOLVED_REALISTIC="(failed)"
  RESOLVED_INVALID=$(coord_fixture_p7_resolve_in_mode 'garbage' 2>&1) || RESOLVED_INVALID="(failed)"
  export RESOLVED_UNSET RESOLVED_MOCK RESOLVED_SEMI RESOLVED_REALISTIC RESOLVED_INVALID

  # Routing matrix verification: per-mode × per-site rc check.
  # rc=0 means "real claude routed", rc=1 means "mock routed".
  ROUTING=""
  for mode in mock semi realistic; do
    for site in mediator validator task_processor; do
      rc=0
      coord_fixture_p7_should_use_real_in_mode "$mode" "$site" >/dev/null 2>&1 || rc=$?
      if [ "$rc" -eq 0 ]; then
        ROUTING="${ROUTING}${mode}:${site}=real "
      else
        ROUTING="${ROUTING}${mode}:${site}=mock "
      fi
    done
  done
  export ROUTING

  # Force a fresh hook invocation under semi to confirm
  # COORD_SPAWN_MODE_RESOLVED audit event lands with mode=semi.
  HOOK_OUT=$(bash -c '
    set -euo pipefail
    export COORD_TEST_MODE=semi
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="p7sg-01-test-sid"
    source "'"$COORD_DIR"'/lib/log_event.sh"
    source "'"$COORD_DIR"'/lib/spawn_helper.sh"
    coord_spawn_helper_resolve_mode >/dev/null
    coord_spawn_helper_should_use_real_claude mediator >/dev/null
  ' 2>&1) || true
  export HOOK_OUT

  sleep 0.3
}

scenario_assert() {
  local fail=0

  # 1. Default (unset) → mock.
  if ! printf '%s' "$RESOLVED_UNSET" | grep -q '^mock$'; then
    printf '  FAIL 1: COORD_TEST_MODE unset did not resolve to mock\n' >&2
    printf '         RESOLVED_UNSET=%s\n' "$RESOLVED_UNSET" >&2
    fail=1
  fi

  # 2. Explicit mock → mock.
  if ! printf '%s' "$RESOLVED_MOCK" | grep -q '^mock$'; then
    printf '  FAIL 2: COORD_TEST_MODE=mock did not resolve to mock\n' >&2
    fail=1
  fi

  # 3. Explicit semi → semi.
  if ! printf '%s' "$RESOLVED_SEMI" | grep -q '^semi$'; then
    printf '  FAIL 3: COORD_TEST_MODE=semi did not resolve to semi\n' >&2
    fail=1
  fi

  # 4. Explicit realistic → realistic.
  if ! printf '%s' "$RESOLVED_REALISTIC" | grep -q '^realistic$'; then
    printf '  FAIL 4: COORD_TEST_MODE=realistic did not resolve to realistic\n' >&2
    fail=1
  fi

  # 5. Invalid → mock + WARNING.
  if ! printf '%s' "$RESOLVED_INVALID" | grep -q "WARNING: COORD_TEST_MODE='garbage' invalid"; then
    printf '  FAIL 5: invalid env-var did not emit WARNING\n' >&2
    fail=1
  fi
  if ! printf '%s' "$RESOLVED_INVALID" | grep -q '^mock$'; then
    printf '  FAIL 5b: invalid env-var did not fail-closed to mock\n' >&2
    fail=1
  fi

  # 6. Routing matrix per OQ4 binding (PR-PHASE7-01 table):
  #    mock   × {m,v,tp}        → all mock
  #    semi   × m + tp           → real;  semi × v → mock
  #    realistic × {m,v,tp}     → all real
  for expected in \
    "mock:mediator=mock" "mock:validator=mock" "mock:task_processor=mock" \
    "semi:mediator=real" "semi:validator=mock" "semi:task_processor=real" \
    "realistic:mediator=real" "realistic:validator=real" "realistic:task_processor=real"; do
    if ! printf '%s' "$ROUTING" | grep -q "$expected"; then
      printf '  FAIL 6: routing matrix violation; expected %s\n' "$expected" >&2
      printf '         ROUTING=%s\n' "$ROUTING" >&2
      fail=1
    fi
  done

  # 7. COORD_SPAWN_MODE_RESOLVED audit event lands from hook
  #    invocation with mode=semi.
  local mode_resolved
  mode_resolved=$(jq -rs '
    [.[] | select(.kind=="COORD_SPAWN_MODE_RESOLVED" and .payload.mode=="semi")] | length
  ' "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$mode_resolved" -lt 1 ]; then
    printf '  FAIL 7: COORD_SPAWN_MODE_RESOLVED event with mode=semi not found\n' >&2
    fail=1
  fi

  # 8. COORD_TEST_MODE_INVALID audit event lands for the invalid
  #    sub-shell invocation. Each sub-shell is its own process so
  #    the invalid event fires once per invalid resolve.
  local invalid_count
  invalid_count=$(jq -rs '
    [.[] | select(.kind=="COORD_TEST_MODE_INVALID")] | length
  ' "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$invalid_count" -lt 1 ]; then
    printf '  FAIL 8: COORD_TEST_MODE_INVALID event not found\n' >&2
    fail=1
  fi

  # 9. Phase 7 invariant — no permissionDecision in any output.
  if printf '%s\n%s\n%s\n%s' \
       "$RESOLVED_INVALID" "$HOOK_OUT" "$ROUTING" "$RESOLVED_SEMI" \
       | grep -q '"permissionDecision"'; then
    printf '  FAIL 9: permissionDecision found in output (Phase 7 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

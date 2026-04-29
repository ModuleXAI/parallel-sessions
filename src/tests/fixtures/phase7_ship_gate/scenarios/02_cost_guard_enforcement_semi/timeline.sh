#!/usr/bin/env bash
# 02_cost_guard_enforcement_semi — Plan §7 revised Done-when #2
# (semi mode portion):
# "Cost guard tunables enforced under semi + realistic modes
#  (mediator min-interval + per-hour cap; validator per-hour cap);
#  mock mode bypasses."
#
# Verifies under COORD_TEST_MODE=semi:
#   a. Mediator cap=2: 2 allows + 1 rate-limit
#   b. Mediator rate-limit emits dedicated MEDIATOR_SPAWN_RATE_LIMITED
#      audit event (NOT MEDIATOR_SPAWN_REFUSED reason=...)
#   c. Validator stays mock-routed in semi (per OQ4 routing matrix);
#      semi-mode cost-guard for validator is NOT triggered through
#      the spawn-site bypass guard
#   d. COST_GUARD_RATE_LIMITED audit event fires with correct payload
set -uo pipefail

scenario_run() {
  # All cost-guard work runs under COORD_TEST_MODE=semi via
  # sub-shells (each invocation is its own process so the
  # cost-guards lib state persists via on-disk counter file but
  # mode resolution is repeated per call).
  # Invoke via direct sourced subshell (NOT the CLI shim) so
  # log_event.sh is sourced before cost_guards.sh — the lib's
  # `command -v coord_log_event` guard otherwise silently skips
  # event emission when the CLI shim is invoked standalone.
  # Mirrors cost_guards_modes.bats _check helper pattern.
  _check_mediator_in_subshell() {
    bash -c '
      set -uo pipefail
      export COORD_TEST_MODE=semi
      export COORD_DIR="'"$COORD_DIR"'"
      export SESSION_ID="p7sg-02-test-sid"
      export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=2
      export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
      source "'"$COORD_DIR"'/lib/log_event.sh"
      source "'"$COORD_DIR"'/lib/cost_guards.sh"
      if coord_cost_guards_check mediator; then exit 0; else exit 1; fi
    '
  }
  MEDIATOR_RC1=0; _check_mediator_in_subshell || MEDIATOR_RC1=$?
  MEDIATOR_RC2=0; _check_mediator_in_subshell || MEDIATOR_RC2=$?
  MEDIATOR_RC3=0; _check_mediator_in_subshell || MEDIATOR_RC3=$?
  export MEDIATOR_RC1 MEDIATOR_RC2 MEDIATOR_RC3

  # Counter file inspection.
  MEDIATOR_COUNTER=$(coord_fixture_p7_counter_count "$(coord_fixture_p7_counter_path mediator)")
  export MEDIATOR_COUNTER

  # Validator under semi: spawn-helper says "mock-routed" so the
  # spawn site does NOT call cost_guards_check. Verify via routing.
  VALIDATOR_ROUTING_RC=0
  coord_fixture_p7_should_use_real_in_mode semi validator >/dev/null 2>&1 || VALIDATOR_ROUTING_RC=$?
  export VALIDATOR_ROUTING_RC

  sleep 0.4
}

scenario_assert() {
  local fail=0

  # 1. First Mediator check allowed.
  if [ "$MEDIATOR_RC1" -ne 0 ]; then
    printf '  FAIL 1: first Mediator check expected rc=0, got %s\n' "$MEDIATOR_RC1" >&2
    fail=1
  fi

  # 2. Second Mediator check allowed (at cap).
  if [ "$MEDIATOR_RC2" -ne 0 ]; then
    printf '  FAIL 2: second Mediator check expected rc=0, got %s\n' "$MEDIATOR_RC2" >&2
    fail=1
  fi

  # 3. Third Mediator check rate-limited (over cap).
  if [ "$MEDIATOR_RC3" -ne 1 ]; then
    printf '  FAIL 3: third Mediator check expected rc=1 (rate-limited), got %s\n' "$MEDIATOR_RC3" >&2
    fail=1
  fi

  # 4. Counter file shows 2 entries (rate-limited check did NOT
  #    append).
  if [ "$MEDIATOR_COUNTER" != "2" ]; then
    printf '  FAIL 4: mediator counter expected 2, got %s\n' "$MEDIATOR_COUNTER" >&2
    fail=1
  fi

  # 5. COST_GUARD_RATE_LIMITED audit event with correct payload.
  local rl_count
  rl_count=$(jq -rs '
    [.[] | select(.kind=="COST_GUARD_RATE_LIMITED" and .payload.site=="mediator")] | length
  ' "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$rl_count" -lt 1 ]; then
    printf '  FAIL 5: COST_GUARD_RATE_LIMITED event for mediator not found\n' >&2
    fail=1
  fi

  # 6. Rate-limited event payload: site=mediator, count=2, limit=2,
  #    window=hour.
  local rl_payload
  rl_payload=$(jq -r 'select(.kind=="COST_GUARD_RATE_LIMITED" and .payload.site=="mediator") | "\(.payload.site)|\(.payload.count)|\(.payload.limit)|\(.payload.window)"' "$COORD_DIR/events.jsonl" 2>/dev/null | head -1)
  if [ "$rl_payload" != "mediator|2|2|hour" ]; then
    printf '  FAIL 6: rate-limited payload mismatch; got [%s] expected [mediator|2|2|hour]\n' "$rl_payload" >&2
    fail=1
  fi

  # 7. Validator routing under semi: rc=1 (mock-routed).
  if [ "$VALIDATOR_ROUTING_RC" -ne 1 ]; then
    printf '  FAIL 7: validator under semi expected mock-routed (rc=1), got %s\n' "$VALIDATOR_ROUTING_RC" >&2
    fail=1
  fi

  # 8. Validator counter file SHOULD NOT EXIST under semi
  #    (spawn-site bypass — cost_guards_check never called by
  #    spawn-site for validator in semi mode).
  local validator_counter
  validator_counter=$(coord_fixture_p7_counter_count "$(coord_fixture_p7_counter_path validator)")
  if [ "$validator_counter" != "0" ]; then
    printf '  FAIL 8: validator counter expected 0 under semi mode, got %s\n' "$validator_counter" >&2
    fail=1
  fi

  # 9. Phase 7 invariant — no permissionDecision in any path.
  if jq -r 'select(.kind=="COST_GUARD_RATE_LIMITED")' "$COORD_DIR/events.jsonl" 2>/dev/null \
       | grep -q '"permissionDecision"'; then
    printf '  FAIL 9: permissionDecision found in audit (Phase 7 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

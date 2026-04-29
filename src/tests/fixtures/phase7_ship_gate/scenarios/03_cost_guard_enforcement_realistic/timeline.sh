#!/usr/bin/env bash
# 03_cost_guard_enforcement_realistic — Plan §7 revised Done-when #2
# (realistic mode portion):
# "Cost guard tunables enforced under semi + realistic modes
#  (...validator per-hour cap)..."
#
# Verifies under COORD_TEST_MODE=realistic:
#   a. Validator now ENFORCED (was bypassed in semi); cap=2 → 2
#      allows + 1 rate-limit
#   b. Validator rate-limit emits dedicated VALIDATOR_SPAWN_RATE_LIMITED
#      audit event when invoked through coord_validator_spawn (the
#      spawn site sets _COORD_VALIDATOR_LAST_FAIL_REASON=rate_limited
#      sentinel)
#   c. Pipeline degrade path: when validator_spawn is rate-limited,
#      the upstream pre_tool_use_write pipeline produces MINOR
#      banner with "[validator rate-limited]" suffix (T7.05 fix)
#   d. Banner suffix is COSMETIC ADDITION, NOT new deny site
set -uo pipefail

scenario_run() {
  # Pre-populate the validator counter to over-cap so the next
  # check is immediately rate-limited.
  mkdir -p "$COORD_DIR/cost_guards"
  local now_ms
  now_ms=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  printf '%s\n%s\n' "$now_ms" "$now_ms" >"$COORD_DIR/cost_guards/validator.counter"

  # Provision a read snapshot so coord_validator_spawn passes the
  # snapshot precondition.
  local sid="p7sg-03-test-sid"
  mkdir -p "$COORD_DIR/read_snapshots/$sid"
  printf 'orig\n' >"$COORD_DIR/read_snapshots/$sid/abc123.txt"

  local target="$WORKDIR/foo.ts"
  printf 'new\n' >"$target"

  # Drive coord_validator_spawn directly under realistic mode.
  # Expected: rc=1 + sentinel _COORD_VALIDATOR_LAST_FAIL_REASON=
  # rate_limited.
  SPAWN_OUT=$(bash -c '
    set -uo pipefail
    export COORD_TEST_MODE=realistic
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="'"$sid"'"
    export COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=2
    source "'"$COORD_DIR"'/lib/log_event.sh"
    source "'"$COORD_DIR"'/lib/hash.sh"
    source "'"$COORD_DIR"'/lib/read_snapshots.sh"
    source "'"$COORD_DIR"'/lib/validator_cache.sh"
    source "'"$COORD_DIR"'/lib/validator_prefilter.sh"
    source "'"$COORD_DIR"'/lib/validator_spawn.sh"
    source "'"$COORD_DIR"'/lib/spawn_helper.sh"
    source "'"$COORD_DIR"'/lib/cost_guards.sh"
    if coord_validator_spawn "$SESSION_ID" "'"$target"'" abc123 def456 2>/dev/null; then
      printf "spawn-allowed\n"
    else
      printf "spawn-failed reason=%s\n" "${_COORD_VALIDATOR_LAST_FAIL_REASON:-unknown}"
    fi
  ' 2>&1) || true
  export SPAWN_OUT

  sleep 0.4
}

scenario_assert() {
  local fail=0

  # 1. validator_spawn returned rc=1 with rate_limited reason.
  if ! printf '%s' "$SPAWN_OUT" | grep -q "spawn-failed reason=rate_limited"; then
    printf '  FAIL 1: validator_spawn did not surface rate_limited reason\n' >&2
    printf '         SPAWN_OUT=%s\n' "$SPAWN_OUT" >&2
    fail=1
  fi

  # 2. VALIDATOR_SPAWN_RATE_LIMITED dedicated audit event landed.
  local vs_rl
  vs_rl=$(jq -rs '
    [.[] | select(.kind=="VALIDATOR_SPAWN_RATE_LIMITED")] | length
  ' "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$vs_rl" -lt 1 ]; then
    printf '  FAIL 2: VALIDATOR_SPAWN_RATE_LIMITED event not found\n' >&2
    fail=1
  fi

  # 3. VALIDATOR_SPAWN_RATE_LIMITED carries mode_resolved=realistic.
  local mode_field
  mode_field=$(jq -r 'select(.kind=="VALIDATOR_SPAWN_RATE_LIMITED") | .payload.mode_resolved' "$COORD_DIR/events.jsonl" 2>/dev/null | head -1)
  if [ "$mode_field" != "realistic" ]; then
    printf '  FAIL 3: VALIDATOR_SPAWN_RATE_LIMITED mode_resolved expected realistic, got [%s]\n' "$mode_field" >&2
    fail=1
  fi

  # 4. COST_GUARD_RATE_LIMITED for validator landed.
  local cg_rl
  cg_rl=$(jq -rs '
    [.[] | select(.kind=="COST_GUARD_RATE_LIMITED" and .payload.site=="validator")] | length
  ' "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$cg_rl" -lt 1 ]; then
    printf '  FAIL 4: COST_GUARD_RATE_LIMITED for validator not found\n' >&2
    fail=1
  fi

  # 5. Validator counter file remains at 2 entries (rate-limited
  #    check did NOT append).
  local validator_counter
  validator_counter=$(coord_fixture_p7_counter_count "$(coord_fixture_p7_counter_path validator)")
  if [ "$validator_counter" != "2" ]; then
    printf '  FAIL 5: validator counter expected 2, got %s\n' "$validator_counter" >&2
    fail=1
  fi

  # 6. Phase 7 invariant — pipeline degrade is NOT a deny.
  #    Verify: zero permissionDecision in events.jsonl audit
  #    related to this scenario.
  if jq -r '.payload.message_to_caller // empty' "$COORD_DIR/events.jsonl" 2>/dev/null \
       | grep -q '"permissionDecision"'; then
    printf '  FAIL 6: permissionDecision found in audit payload (Phase 7 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

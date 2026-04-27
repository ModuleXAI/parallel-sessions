#!/usr/bin/env bash
# 02_minor_drift_warned — pre-filter ESCALATE → validator MINOR
# (mock binary).
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-02-0001"
  local target="$WORKDIR/utils.ts"
  local other="$WORKDIR/other.ts"

  printf 'export function checkAuth(token) {\n  const parsed = parseToken(token);\n  if (!parsed) return false;\n  return parsed.expiresAt > Date.now();\n}\n' >"$target"
  printf 'export const initial = true;\n' >"$other"

  coord_fixture_register_session "$sid_a"
  coord_fixture_prime_read "$sid_a" "$target"

  # Real (non-trivial) mutation: rename parsed → decoded.
  printf 'export function checkAuth(token) {\n  const decoded = parseToken(token);\n  if (!decoded) return false;\n  return decoded.expiresAt > Date.now();\n}\n' >"$target"

  # Mock validator returns MINOR (init.sh's default fake claude
  # honors MOCK_VALIDATOR_VERDICT env).
  export MOCK_VALIDATOR_VERDICT=MINOR
  export MOCK_FILE="$target"
  export MOCK_CALLER_SID="$sid_a"

  HOOK_STDOUT_02=$(coord_fixture_invoke_write "$sid_a" "$other") || HOOK_STDOUT_02=""
  export HOOK_STDOUT_02

  unset MOCK_VALIDATOR_VERDICT MOCK_FILE MOCK_CALLER_SID
  sleep 0.3
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. VALIDATOR_PREFILTER_ESCALATED with non_trivial_diff.
  local n
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_PREFILTER_ESCALATED" and .payload.escalation_reason == "non_trivial_diff")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 1: no VALIDATOR_PREFILTER_ESCALATED/non_trivial_diff event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 2. VALIDATOR_SPAWN_STARTED.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_STARTED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 2: no VALIDATOR_SPAWN_STARTED event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 3. VALIDATOR_VERDICT_MINOR.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_VERDICT_MINOR")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 3: no VALIDATOR_VERDICT_MINOR event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 4. cache.json has MINOR entry with non-empty diff_summary.
  if [ -f "$COORD_DIR/validator/cache.json" ]; then
    local minor_summary
    minor_summary=$(jq -r '.entries[] | select(.verdict == "MINOR") | .diff_summary // ""' "$COORD_DIR/validator/cache.json" 2>/dev/null | head -1)
    if [ -z "$minor_summary" ] || [ "$minor_summary" = "null" ]; then
      printf '  FAIL 4: cache.json has no MINOR entry with diff_summary\n' >&2
      jq . "$COORD_DIR/validator/cache.json" >&2 || true
      fail=1
    fi
  else
    printf '  FAIL 4: cache.json missing\n' >&2; fail=1
  fi

  # 5. Hook stdout contains "Coord drift report".
  if ! printf '%s' "$HOOK_STDOUT_02" | grep -q 'Coord drift report'; then
    printf '  FAIL 5: hook stdout missing "Coord drift report"\n' >&2
    printf '    got: %s\n' "$HOOK_STDOUT_02" >&2; fail=1
  fi

  # 6. Hook stdout contains "MINOR".
  if ! printf '%s' "$HOOK_STDOUT_02" | grep -q 'MINOR'; then
    printf '  FAIL 6: hook stdout missing "MINOR" classification\n' >&2; fail=1
  fi

  # 7. Hook stdout contains "Variable rename".
  if ! printf '%s' "$HOOK_STDOUT_02" | grep -q 'Variable rename'; then
    printf '  FAIL 7: hook stdout missing "Variable rename" text from mock diff_summary\n' >&2; fail=1
  fi

  # 8. NO permissionDecision.
  if printf '%s' "$HOOK_STDOUT_02" | grep -q 'permissionDecision'; then
    printf '  FAIL 8: hook emitted permissionDecision (Phase 4 invariant violation)\n' >&2; fail=1
  fi

  # 9. No lockdown.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL 9: spurious lockdown active\n' >&2; fail=1
  fi

  return "$fail"
}

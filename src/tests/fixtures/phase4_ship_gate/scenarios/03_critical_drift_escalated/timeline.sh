#!/usr/bin/env bash
# 03_critical_drift_escalated — validator CRITICAL → Mediator inline
# surgical_fix → read-set cleared, caller proceeds.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-03-0001"
  local target="$WORKDIR/api.ts"
  local other="$WORKDIR/other.ts"

  printf 'export function fetchUser(id: string): Promise<User> {\n  return fetch(`/api/users/${id}`).then(r => r.json());\n}\n' >"$target"
  printf 'export const initial = true;\n' >"$other"

  coord_fixture_register_session "$sid_a"
  coord_fixture_prime_read "$sid_a" "$target"

  # CRITICAL signature change.
  printf 'export async function fetchUser(id: string, options: FetchOptions): Promise<User | null> {\n  const r = await fetch(`/api/users/${id}`, options);\n  if (!r.ok) return null;\n  return r.json();\n}\n' >"$target"

  export MOCK_VALIDATOR_VERDICT=CRITICAL
  export MOCK_MEDIATOR_ACTION=surgical_fix
  export MOCK_FILE="$target"
  export MOCK_CALLER_SID="$sid_a"

  HOOK_STDOUT_03=$(coord_fixture_invoke_write "$sid_a" "$other") || HOOK_STDOUT_03=""
  export HOOK_STDOUT_03 SID_A_03="$sid_a"

  unset MOCK_VALIDATOR_VERDICT MOCK_MEDIATOR_ACTION MOCK_FILE MOCK_CALLER_SID
  sleep 0.3
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. VALIDATOR_VERDICT_CRITICAL event.
  local n
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_VERDICT_CRITICAL")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 1: no VALIDATOR_VERDICT_CRITICAL event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 2. critical_drift pending entry.
  n=$(jq -rs '[.[] | select(.kind == "critical_drift")] | length' "$COORD_DIR/mediator/pending.jsonl" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 2: no critical_drift entry in pending.jsonl (count=%s)\n' "$n" >&2; fail=1
  fi

  # 3. VALIDATOR_VERDICT_CRITICAL_ESCALATED_TO_MEDIATOR.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_VERDICT_CRITICAL_ESCALATED_TO_MEDIATOR")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 3: no VALIDATOR_VERDICT_CRITICAL_ESCALATED_TO_MEDIATOR event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 4. Mediator verdict file with surgical_fix.
  local sf_count=0
  for vf in "$COORD_DIR/mediator/verdict"/*.json; do
    [ -f "$vf" ] || continue
    if [ "$(jq -r '.action_type // ""' "$vf" 2>/dev/null)" = "surgical_fix" ]; then
      sf_count=$((sf_count + 1))
    fi
  done
  if [ "$sf_count" -lt 1 ]; then
    printf '  FAIL 4: no surgical_fix verdict file in mediator/verdict/\n' >&2; fail=1
  fi

  # 5. MEDIATOR_INLINE_VERDICT_APPLIED.
  n=$(jq -rs '[.[] | select(.kind == "MEDIATOR_INLINE_VERDICT_APPLIED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 5: no MEDIATOR_INLINE_VERDICT_APPLIED event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 6. read_sets cleared for A.
  local reads_len
  reads_len=$(jq -r --arg sid "$SID_A_03" '(.read_sets[$sid].reads // []) | length' "$COORD_DIR/sessions.json" 2>/dev/null || printf 999)
  if [ "$reads_len" != "0" ]; then
    printf '  FAIL 6: A read_sets length=%s; expected 0 after surgical_fix clear_read_set\n' "$reads_len" >&2; fail=1
  fi

  # 7. cache.json does NOT contain CRITICAL entry.
  if [ -f "$COORD_DIR/validator/cache.json" ]; then
    local crit_count
    crit_count=$(jq -r '[.entries[] | select(.verdict == "CRITICAL")] | length' "$COORD_DIR/validator/cache.json" 2>/dev/null || printf 0)
    if [ "$crit_count" != "0" ]; then
      printf '  FAIL 7: cache.json contains CRITICAL entry (count=%s) — CRITICAL must NEVER be cached\n' "$crit_count" >&2; fail=1
    fi
  fi

  # 8. last_consumed_verdict pointer advanced for A.
  if [ ! -f "$COORD_DIR/sessions/${SID_A_03}.last_consumed_verdict" ]; then
    printf '  FAIL 8: pointer file missing for %s\n' "$SID_A_03" >&2; fail=1
  fi

  # 9. Banner contains "Critical drift".
  if ! printf '%s' "$HOOK_STDOUT_03" | grep -q 'Critical drift'; then
    printf '  FAIL 9: hook stdout missing "Critical drift" banner\n' >&2
    printf '    got: %s\n' "$HOOK_STDOUT_03" >&2; fail=1
  fi

  # 10. NO permissionDecision (Phase 4 invariant).
  if printf '%s' "$HOOK_STDOUT_03" | grep -q 'permissionDecision'; then
    printf '  FAIL 10: hook emitted permissionDecision (Phase 4 invariant violation)\n' >&2; fail=1
  fi

  # 11. No lockdown.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL 11: spurious lockdown active (Mediator chose surgical_fix, not lockdown)\n' >&2; fail=1
  fi

  return "$fail"
}

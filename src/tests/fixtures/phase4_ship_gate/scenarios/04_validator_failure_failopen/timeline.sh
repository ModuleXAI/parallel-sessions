#!/usr/bin/env bash
# 04_validator_failure_failopen — validator binary missing →
# pipeline fail-open → Phase 1 fallback banner → write succeeds
# without permissionDecision.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-04-0001"
  local target="$WORKDIR/complex.ts"
  local other="$WORKDIR/other.ts"

  printf 'export function compute(x) { return x * 2; }\n' >"$target"
  printf 'export const initial = true;\n' >"$other"

  coord_fixture_register_session "$sid_a"
  coord_fixture_prime_read "$sid_a" "$target"

  # Non-trivial mutation (escapes pre-filter SAFE heuristics).
  printf 'export function compute(x, y) { return x * 2 + y; }\n' >"$target"

  # Build a minimal PATH that EXCLUDES the fake claude binary so
  # coord_validator_spawn returns claude_binary_missing.
  local jq_bin flock_bin perl_bin shasum_bin
  jq_bin=$(command -v jq | xargs dirname 2>/dev/null)
  flock_bin=$(command -v flock | xargs dirname 2>/dev/null)
  perl_bin=$(command -v perl | xargs dirname 2>/dev/null)
  shasum_bin=$(command -v shasum | xargs dirname 2>/dev/null)
  local minimal_path="$jq_bin:$flock_bin:$perl_bin:$shasum_bin:/usr/bin:/bin"

  local hooks="$COORD_DIR/hooks"
  HOOK_STDOUT_04=$(
    printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$other"'"}}' \
      | env -i HOME="$HOME" \
            PATH="$minimal_path" \
            COORD_DIR="$COORD_DIR" \
            CLAUDE_COORD=1 \
            CLAUDE_PROJECT_DIR="$WORKDIR" \
            "$hooks/pre_tool_use_write.sh"
  ) || HOOK_STDOUT_04=""
  HOOK_RC_04=$?
  export HOOK_STDOUT_04 HOOK_RC_04
  sleep 0.3
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. VALIDATOR_PREFILTER_ESCALATED.
  local n
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_PREFILTER_ESCALATED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 1: no VALIDATOR_PREFILTER_ESCALATED event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 2. VALIDATOR_SPAWN_FAILED with claude_binary_missing.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED" and .payload.reason == "claude_binary_missing")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 2: no VALIDATOR_SPAWN_FAILED/claude_binary_missing event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 3. VALIDATOR_PIPELINE_FAILED.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_FAILED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 3: no VALIDATOR_PIPELINE_FAILED event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 4. Banner contains "Pipeline unavailable".
  if ! printf '%s' "$HOOK_STDOUT_04" | grep -q 'Pipeline unavailable'; then
    printf '  FAIL 4: hook stdout missing "Pipeline unavailable" Phase 1 fallback text\n' >&2
    printf '    got: %s\n' "$HOOK_STDOUT_04" >&2; fail=1
  fi

  # 5. NO permissionDecision (fail-open).
  if printf '%s' "$HOOK_STDOUT_04" | grep -q 'permissionDecision'; then
    printf '  FAIL 5: hook emitted permissionDecision on validator failure (fail-open violated)\n' >&2; fail=1
  fi

  # 6. Hook rc=0 (Write succeeds).
  if [ "${HOOK_RC_04:-1}" != "0" ]; then
    printf '  FAIL 6: hook rc=%s; expected 0 (fail-open)\n' "${HOOK_RC_04:-?}" >&2; fail=1
  fi

  # 7. No lockdown.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL 7: spurious lockdown active on validator failure\n' >&2; fail=1
  fi

  # 8. cache.json does NOT contain a SAFE/MINOR entry for this drift.
  if [ -f "$COORD_DIR/validator/cache.json" ]; then
    local entry_count
    entry_count=$(jq -r '.entries | length' "$COORD_DIR/validator/cache.json" 2>/dev/null || printf 0)
    if [ "$entry_count" -gt 0 ]; then
      # Allow non-failure cache entries (e.g., from another scenario's
      # pre-filter SAFE if scenarios share state — but they don't,
      # init.sh creates a fresh WORKDIR per scenario). For this scenario
      # specifically, entry_count must be 0.
      printf '  FAIL 8: cache.json has entries (%s) on pipeline failure; should be 0\n' "$entry_count" >&2; fail=1
    fi
  fi

  return "$fail"
}

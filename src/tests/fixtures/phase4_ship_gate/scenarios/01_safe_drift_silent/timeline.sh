#!/usr/bin/env bash
# 01_safe_drift_silent — pre-filter SAFE on whitespace-only drift.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-01-0001"
  local target="$WORKDIR/target.ts"
  local other="$WORKDIR/other.ts"

  printf 'function foo() {\n  return 1;\n}\n' >"$target"
  printf 'export const initial = true;\n' >"$other"

  coord_fixture_register_session "$sid_a"
  coord_fixture_prime_read "$sid_a" "$target"

  # Whitespace-only mutation: add a blank line at the end.
  printf 'function foo() {\n  return 1;\n}\n\n' >"$target"

  HOOK_STDOUT_01=$(coord_fixture_invoke_write "$sid_a" "$other") || HOOK_STDOUT_01=""
  export HOOK_STDOUT_01
  sleep 0.3
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. VALIDATOR_PIPELINE_STARTED present.
  local n
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_STARTED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 1: no VALIDATOR_PIPELINE_STARTED event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 2. VALIDATOR_PREFILTER_SAFE with whitespace_only OR blank_only.
  # `diff -w` ignores intra-line whitespace but a NEW empty line is
  # a line-add — diff -w reports it as different, then heuristic 2
  # (blank-line-only) catches it. Both reasons indicate trivial
  # drift fast-tracked to SAFE; either is acceptable here.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_PREFILTER_SAFE" and (.payload.prefilter_reason == "whitespace_only" or .payload.prefilter_reason == "blank_only"))] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 2: no VALIDATOR_PREFILTER_SAFE/whitespace_only|blank_only event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 3. VALIDATOR_PIPELINE_COMPLETED present.
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_COMPLETED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 3: no VALIDATOR_PIPELINE_COMPLETED event (count=%s)\n' "$n" >&2; fail=1
  fi

  # 4. NO VALIDATOR_SPAWN_STARTED (pre-filter short-circuited).
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_STARTED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -gt 0 ]; then
    printf '  FAIL 4: VALIDATOR_SPAWN_STARTED fired (count=%s); expected pre-filter to short-circuit\n' "$n" >&2; fail=1
  fi

  # 5. cache.json contains a SAFE/prefilter entry.
  if [ -f "$COORD_DIR/validator/cache.json" ]; then
    local entry
    entry=$(jq -r '.entries[] | select(.verdict == "SAFE" and .verdict_source == "prefilter") | .verdict' "$COORD_DIR/validator/cache.json" 2>/dev/null | head -1)
    if [ "$entry" != "SAFE" ]; then
      printf '  FAIL 5: no SAFE/prefilter entry in cache.json\n' >&2
      jq . "$COORD_DIR/validator/cache.json" >&2 || true
      fail=1
    fi
  else
    printf '  FAIL 5: cache.json missing\n' >&2; fail=1
  fi

  # 6. Hook stdout does NOT contain "Coord drift report" banner.
  if printf '%s' "$HOOK_STDOUT_01" | grep -q 'Coord drift report'; then
    printf '  FAIL 6: hook emitted Coord drift report banner; SAFE pipeline should be silent\n' >&2; fail=1
  fi

  # 7. NO permissionDecision.
  if printf '%s' "$HOOK_STDOUT_01" | grep -q 'permissionDecision'; then
    printf '  FAIL 7: hook emitted permissionDecision (Phase 4 invariant violation)\n' >&2; fail=1
  fi

  # 8. No lockdown.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL 8: spurious lockdown active\n' >&2; fail=1
  fi

  return "$fail"
}

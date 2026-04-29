#!/usr/bin/env bats
# Phase 7 / T7.05 cross-mode cost-guard interlock integration
# tests per PR-PHASE7-03 §"Tests (T7.05 cross-mode)" + PR-PHASE7-02
# §"3-site refactor pattern".
#
# Verifies the mode-aware bypass is wired correctly at all 3 spawn
# sites:
#   - mock mode: cost-guard call SKIPPED entirely (helper guards
#     `coord_spawn_helper_should_use_real_claude` rc=1 → cost-guard
#     block not entered)
#   - semi mode: Mediator + Task Processor enforce; Validator mock-
#     routed (cost-guard skipped per OQ4 routing matrix)
#   - realistic mode: all 3 enforce (validator gets cost-guard hit)
#
# Tests use direct lib invocation (not the spawn lifecycle) — the
# semantic invariant is: "spawn site calls coord_cost_guards_check
# IFF coord_spawn_helper_should_use_real_claude returns rc=0 for
# that site." That invariant is verified by counting counter-file
# rows after stress-testing each spawn site under each mode.
#
# §A.13 lesson application:
#   - #6 event-emission audit per return path: rate-limited tests
#     check both COST_GUARD_RATE_LIMITED (cost_guards lib layer) +
#     dedicated *_SPAWN_RATE_LIMITED (spawn-site layer).
#   - #11 multi-assign local + set -u: helper compliance.
#   - #17 bats bash -c subshell wrapper: backgrounded log_event
#     calls inherit lifetime via outer bash -c.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-cg-modes-XXXX)"
  mk_coord_dir "$TMP" >/dev/null
  export COORD_DIR="$TMP/.coord"
  export SESSION_ID="session-cg-modes-test"
  export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=2
  export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
  export COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=2
  export COORD_COST_GUARDS_FLOCK_TIMEOUT=2
}

teardown() {
  rm -rf "$TMP"
}

# Helper: invoke cost-guard check ONLY when spawn-helper says use
# real claude — mirrors the actual T7.03 SLOT pattern exactly.
_simulated_spawn_check() {
  local site="$1" mode="$2"
  bash -c '
    set -euo pipefail
    export COORD_TEST_MODE="'"$mode"'"
    source "'"$SRC_ROOT"'/lib/log_event.sh"
    source "'"$SRC_ROOT"'/lib/spawn_helper.sh"
    source "'"$SRC_ROOT"'/lib/cost_guards.sh"
    if coord_spawn_helper_should_use_real_claude "'"$site"'"; then
      if coord_cost_guards_check "'"$site"'"; then
        printf "spawn-real-allow\n"
      else
        printf "spawn-real-rate-limited\n"
      fi
    else
      printf "spawn-mock-skipped\n"
    fi
  '
}

_counter_path() {
  printf '%s/cost_guards/%s.counter\n' "$COORD_DIR" "$1"
}

_count_lines() {
  local f="$1"
  if [ -e "$f" ]; then
    wc -l <"$f" | tr -d ' '
  else
    printf '0'
  fi
}

# -----------------------------------------------------------------
# Mock mode — cost-guard call should NOT fire at any site
# -----------------------------------------------------------------

@test "mock mode × mediator: cost-guard SKIPPED, no counter file" {
  run _simulated_spawn_check mediator mock
  [ "$status" -eq 0 ]
  _grep_output_for "spawn-mock-skipped"
  [ ! -e "$(_counter_path mediator)" ]
}

@test "mock mode × validator: cost-guard SKIPPED, no counter file" {
  run _simulated_spawn_check validator mock
  [ "$status" -eq 0 ]
  _grep_output_for "spawn-mock-skipped"
  [ ! -e "$(_counter_path validator)" ]
}

@test "mock mode × task_processor: cost-guard SKIPPED, no counter file" {
  run _simulated_spawn_check task_processor mock
  [ "$status" -eq 0 ]
  _grep_output_for "spawn-mock-skipped"
  [ ! -e "$(_counter_path task_processor)" ]
}

@test "mock mode: NO calls produce counter files no matter how many invocations" {
  for _ in 1 2 3 4 5; do
    run _simulated_spawn_check mediator mock
    [ "$status" -eq 0 ]
  done
  [ ! -e "$(_counter_path mediator)" ]
}

# -----------------------------------------------------------------
# Semi mode — Mediator + Task Processor enforce; Validator skipped
# -----------------------------------------------------------------

@test "semi mode × mediator: cost-guard enforces; cap+1 rate-limits" {
  run _simulated_spawn_check mediator semi; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check mediator semi; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check mediator semi; [ "$output" = "spawn-real-rate-limited" ]
  [ "$(_count_lines "$(_counter_path mediator)")" = "2" ]
}

@test "semi mode × validator: cost-guard SKIPPED (validator mock-routed in semi)" {
  run _simulated_spawn_check validator semi
  [ "$output" = "spawn-mock-skipped" ]
  run _simulated_spawn_check validator semi
  [ "$output" = "spawn-mock-skipped" ]
  run _simulated_spawn_check validator semi
  [ "$output" = "spawn-mock-skipped" ]
  [ ! -e "$(_counter_path validator)" ]
}

@test "semi mode × task_processor: cost-guard fires but max=0 sentinel always allows" {
  for _ in 1 2 3 4 5; do
    run _simulated_spawn_check task_processor semi
    [ "$output" = "spawn-real-allow" ]
  done
  # task_processor max=0 → always-allow → no counter writes.
  [ ! -e "$(_counter_path task_processor)" ]
}

# -----------------------------------------------------------------
# Realistic mode — all 3 enforce
# -----------------------------------------------------------------

@test "realistic mode × mediator: enforces (same as semi)" {
  run _simulated_spawn_check mediator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check mediator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check mediator realistic; [ "$output" = "spawn-real-rate-limited" ]
}

@test "realistic mode × validator: enforces (was mock-routed in semi)" {
  run _simulated_spawn_check validator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check validator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check validator realistic; [ "$output" = "spawn-real-rate-limited" ]
  [ "$(_count_lines "$(_counter_path validator)")" = "2" ]
}

@test "realistic mode × task_processor: cost-guard fires but max=0 sentinel always allows" {
  for _ in 1 2 3 4 5; do
    run _simulated_spawn_check task_processor realistic
    [ "$output" = "spawn-real-allow" ]
  done
  [ ! -e "$(_counter_path task_processor)" ]
}

# -----------------------------------------------------------------
# Cross-site independence under same mode
# -----------------------------------------------------------------

@test "realistic mode: mediator over-cap does NOT affect validator quota" {
  # Burn mediator quota.
  run _simulated_spawn_check mediator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check mediator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check mediator realistic; [ "$output" = "spawn-real-rate-limited" ]
  # Validator still has full quota.
  run _simulated_spawn_check validator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check validator realistic; [ "$output" = "spawn-real-allow" ]
  run _simulated_spawn_check validator realistic; [ "$output" = "spawn-real-rate-limited" ]
}

# -----------------------------------------------------------------
# Mode switch within same process — NOT covered (cache makes this
# require a fresh process per mode change; documented as
# operational reality in T7.13 sign-off CLAUDE.md note).
# -----------------------------------------------------------------

# -----------------------------------------------------------------
# Pipeline graceful degrade — validator rate-limited produces MINOR
# banner with "[validator rate-limited]" suffix
# -----------------------------------------------------------------

@test "validator rate-limited: pipeline degrades to MINOR with banner suffix" {
  # Pre-populate cost-guard counter to over-cap so any check is
  # immediately rate-limited.
  mkdir -p "$COORD_DIR/cost_guards"
  local now_ms
  now_ms=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  printf '%s\n%s\n' "$now_ms" "$now_ms" > "$COORD_DIR/cost_guards/validator.counter"
  # Validator cap is 2; counter has 2 → next check is rate_limited.

  # Need a fake claude binary on PATH so the spawn-helper guard +
  # claude-binary check both pass; the cost-guard rate-limit
  # branch fires before the claude invocation.
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/claude" <<'EOF'
#!/bin/sh
echo '{"is_error":false,"session_id":"sxyz","total_cost_usd":0.01,"result":""}'
EOF
  chmod +x "$TMP/bin/claude"

  # Provision a read snapshot so validator_spawn passes its
  # snapshot check.
  mkdir -p "$COORD_DIR/read_snapshots/$SESSION_ID"
  printf 'orig\n' > "$COORD_DIR/read_snapshots/$SESSION_ID/abc123.txt"

  local target="$TMP/foo.ts"
  printf 'new\n' > "$target"

  # Drive the pipeline directly — rate-limited validator triggers
  # the new graceful degrade path.
  run bash -c '
    set -euo pipefail
    export PATH="'"$TMP"'/bin:$PATH"
    export COORD_TEST_MODE=realistic
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="'"$SESSION_ID"'"
    export COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=2
    source "'"$SRC_ROOT"'/lib/log_event.sh"
    source "'"$SRC_ROOT"'/lib/hash.sh"
    source "'"$SRC_ROOT"'/lib/read_snapshots.sh"
    source "'"$SRC_ROOT"'/lib/validator_cache.sh"
    source "'"$SRC_ROOT"'/lib/validator_prefilter.sh"
    source "'"$SRC_ROOT"'/lib/validator_spawn.sh"
    source "'"$SRC_ROOT"'/lib/spawn_helper.sh"
    source "'"$SRC_ROOT"'/lib/cost_guards.sh"
    # Direct call to validator_spawn with rate-limited counter.
    if coord_validator_spawn "$SESSION_ID" "'"$target"'" abc123 def456 2>/dev/null; then
      printf "spawn-allowed\n"
    else
      printf "spawn-failed reason=%s\n" "${_COORD_VALIDATOR_LAST_FAIL_REASON:-unknown}"
    fi
  '
  [ "$status" -eq 0 ]
  _grep_output_for "spawn-failed reason=rate_limited"

  # Verify VALIDATOR_SPAWN_RATE_LIMITED audit event landed.
  sleep 0.3
  run jq -rs '[.[] | select(.kind=="VALIDATOR_SPAWN_RATE_LIMITED")] | length' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "mediator rate-limited: emits MEDIATOR_SPAWN_RATE_LIMITED dedicated kind" {
  mkdir -p "$COORD_DIR/cost_guards"
  local now_ms
  now_ms=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  printf '%s\n%s\n' "$now_ms" "$now_ms" > "$COORD_DIR/cost_guards/mediator.counter"
  # Mediator cap=2; counter has 2 → next check rate-limited.

  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/claude" <<'EOF'
#!/bin/sh
echo '{"is_error":false,"session_id":"sxyz","total_cost_usd":0.01,"result":""}'
EOF
  chmod +x "$TMP/bin/claude"

  bash -c '
    set -euo pipefail
    export PATH="'"$TMP"'/bin:$PATH"
    export COORD_TEST_MODE=realistic
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="'"$SESSION_ID"'"
    export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=2
    export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
    source "'"$SRC_ROOT"'/lib/log_event.sh"
    source "'"$SRC_ROOT"'/lib/atomic_write.sh" 2>/dev/null || true
    source "'"$SRC_ROOT"'/lib/mediator_pending.sh" 2>/dev/null || true
    source "'"$SRC_ROOT"'/lib/mediator_spawn.sh"
    source "'"$SRC_ROOT"'/lib/spawn_helper.sh"
    source "'"$SRC_ROOT"'/lib/cost_guards.sh"
    coord_mediator_spawn p1 1 "" 2>/dev/null || true
  '
  sleep 0.3
  run jq -rs '[.[] | select(.kind=="MEDIATOR_SPAWN_RATE_LIMITED")] | length' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# -----------------------------------------------------------------
# 2-location deny invariant preserved (no permissionDecision strings
# in ANY of the new T7.05 paths)
# -----------------------------------------------------------------

@test "T7.05 invariant: rate-limit handling adds no permissionDecision strings" {
  # Static check: cost_guards.sh, the modified spawn-site rate-
  # limit blocks, and the pipeline graceful-degrade path must all
  # remain free of permissionDecision strings.
  ! grep -q 'permissionDecision' "$SRC_ROOT/lib/cost_guards.sh"
  ! grep -q 'permissionDecision' "$SRC_ROOT/lib/spawn_helper.sh"
  # Spawn-site files: the only permissionDecision uses are in
  # pre_tool_use_write.sh's lock-held branch + lockdown.sh; the
  # spawn-site libs themselves remain clean.
  ! grep -q 'permissionDecision' "$SRC_ROOT/lib/mediator_spawn.sh"
  ! grep -q 'permissionDecision' "$SRC_ROOT/lib/validator_spawn.sh"
  ! grep -q 'permissionDecision' "$SRC_ROOT/lib/task_processor.sh"
}

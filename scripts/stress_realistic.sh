#!/usr/bin/env bash
# stress_realistic.sh — Phase 7 / T7.08 manual stress test for
# COORD_TEST_MODE=realistic per PR-PHASE7-04 §"Manual stress
# test scripts" + the Phase 7 hazırlık konuşması T7.08 binding.
#
# Mode: realistic.
#   - Mediator + Validator + Task Processor → all real `claude
#     -p` per PR-PHASE7-01 routing matrix
#
# Scope:
#   1. Run all existing ship-gate driver suites in sequence
#      with COORD_TEST_MODE=realistic exported.
#   2. Append a focused cost-guard exercise that exercises the
#      validator rate-limit boundary (which would be skipped
#      in semi mode per routing matrix).
#
# Cost estimate: $0 in mock-binary path (default for fixture
# drivers); ~$1-3 if operator has a real `claude` binary on
# PATH AND extends a fixture to invoke real-Claude (Phase 7+1
# work). v1 stress_realistic.sh is intended for pre-release
# smoke; the cost-guard exercise validates the rate-limit
# enforcement path even without a real claude binary.
#
# Prerequisites (same as stress_semi.sh):
#   - jq, flock
#   - Optional `claude` binary on PATH
#   - Operator confirmation: this script clears any
#     pre-existing scripts/stress_realistic_out/ artifacts
#
# Exit codes (per user T7.08 prompt §"Exit semantics"):
#   0  all scenarios PASS, no unexpected rate-limit
#   1  scenario failure
#   2  unexpected rate-limit pattern
#   3  setup/teardown failure
#
# Output: scripts/stress_realistic_out/<ISO_ts>.log captures
# fixture-by-fixture results + cost-guard event excerpts.
#
# §A.13 lesson application: same as stress_semi.sh.
#   - #7 Bash 3.2 parser
#   - #11 multi-assign local + set -u
#   - #19 fixture set -e inheritance (rate-limit exercise
#     intentionally drives non-zero rc; uses `|| rc=$?` form)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/scripts/stress_realistic_out"
mkdir -p "$OUT_DIR"

ISO_TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
LOG_FILE="$OUT_DIR/${ISO_TS}.log"

MODE="realistic"

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

banner() {
  log ""
  log "=== $* ==="
}

# ---------------------------------------------------------------
# Setup
# ---------------------------------------------------------------

banner "stress_realistic.sh — Phase 7 / T7.08 manual stress test"
log "ISO timestamp: $ISO_TS"
log "Repo root:     $REPO_ROOT"
log "Log file:      $LOG_FILE"
log "Mode:          $MODE"
log "claude on PATH: $(command -v claude 2>/dev/null || printf '(absent)')"

export COORD_TEST_MODE="$MODE"

LIB_DIR="$REPO_ROOT/src/lib"
# shellcheck disable=SC1091
. "$LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/spawn_helper.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/cost_guards.sh"

resolved_mode=$(coord_spawn_helper_resolve_mode 2>/dev/null) || resolved_mode="(resolve failed)"
log "spawn_helper resolved mode: $resolved_mode"
if [ "$resolved_mode" != "$MODE" ]; then
  log "ERROR: expected mode=$MODE, got $resolved_mode"
  exit 3
fi

# ---------------------------------------------------------------
# Phase 1 — ship-gate driver suite under realistic mode
# ---------------------------------------------------------------

banner "Phase 1: ship-gate driver suites (mode=realistic)"

PASS_DRIVERS=0
FAIL_DRIVERS=0

run_driver() {
  local driver_path="$1"
  local label
  label="$(basename "$driver_path")"
  log "  -> $label"
  local rc=0
  bash "$driver_path" >>"$LOG_FILE" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "     PASS"
    PASS_DRIVERS=$((PASS_DRIVERS + 1))
  else
    log "     FAIL (rc=$rc)"
    FAIL_DRIVERS=$((FAIL_DRIVERS + 1))
  fi
  return 0
}

run_driver "$REPO_ROOT/src/tests/manual/two_session_warn.sh"
run_driver "$REPO_ROOT/src/tests/manual/phase3_ship_gate.sh"
run_driver "$REPO_ROOT/src/tests/manual/phase4_ship_gate.sh"
run_driver "$REPO_ROOT/src/tests/manual/phase5_ship_gate.sh"
run_driver "$REPO_ROOT/src/tests/manual/phase6_ship_gate.sh"

log ""
log "Phase 1 summary: $PASS_DRIVERS passed, $FAIL_DRIVERS failed"

# ---------------------------------------------------------------
# Phase 2 — cost-guard rate-limit exercise (all 3 sites under
# realistic mode; validator now enforced unlike semi)
# ---------------------------------------------------------------

banner "Phase 2: cost-guard rate-limit exercise (intentional)"

CG_TMP="$(mktemp -d -t stress-realistic-cg-XXXX)"
mkdir -p "$CG_TMP/.coord"
export COORD_DIR="$CG_TMP/.coord"
export SESSION_ID="stress-realistic-cg-test"
export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=2
export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
export COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=2

CG_PASS=0
CG_FAIL=0

cg_step() {
  local label="$1" expected_rc="$2"; shift 2
  local actual_rc=0
  log "  cost-guard step: $label (expected rc=$expected_rc)"
  bash "$LIB_DIR/cost_guards.sh" "$@" >>"$LOG_FILE" 2>&1 || actual_rc=$?
  if [ "$actual_rc" = "$expected_rc" ]; then
    log "     PASS (rc=$actual_rc)"
    CG_PASS=$((CG_PASS + 1))
  else
    log "     FAIL (got rc=$actual_rc, expected $expected_rc)"
    CG_FAIL=$((CG_FAIL + 1))
  fi
}

# All 3 sites enforced under realistic. validator gets equal
# treatment to mediator (vs semi where validator was mock-routed).
cg_step "mediator check 1 (under cap)"  "0" check mediator
cg_step "mediator check 2 (at cap)"     "0" check mediator
cg_step "mediator check 3 (over cap)"   "1" check mediator
cg_step "validator check 1 (under cap)" "0" check validator
cg_step "validator check 2 (at cap)"    "0" check validator
cg_step "validator check 3 (over cap)"  "1" check validator
cg_step "task_processor (reserved/always-allow x3)" "0" check task_processor
cg_step "task_processor (still allow)"  "0" check task_processor
cg_step "task_processor (still allow)"  "0" check task_processor
cg_step "mediator clear"                "0" clear mediator
cg_step "validator clear"               "0" clear validator
cg_step "mediator check post-clear"     "0" check mediator
cg_step "validator check post-clear"    "0" check validator

log ""
log "Phase 2 summary: $CG_PASS passed, $CG_FAIL failed"

# Audit-event evidence: must contain at least 2
# COST_GUARD_RATE_LIMITED entries (mediator + validator).
if [ -s "$COORD_DIR/events.jsonl" ]; then
  rl_count=$(jq -rs '[.[] | select(.kind=="COST_GUARD_RATE_LIMITED")] | length' "$COORD_DIR/events.jsonl" 2>/dev/null || printf '0')
  log "COST_GUARD_RATE_LIMITED events observed: $rl_count (expected >=2)"
  if [ "$rl_count" -lt 2 ]; then
    CG_FAIL=$((CG_FAIL + 1))
    log "  WARN: insufficient rate-limited events"
  fi
  mc_count=$(jq -rs '[.[] | select(.kind=="COST_GUARD_MANUAL_CLEAR")] | length' "$COORD_DIR/events.jsonl" 2>/dev/null || printf '0')
  log "COST_GUARD_MANUAL_CLEAR events observed: $mc_count (expected >=2)"
fi

rm -rf "$CG_TMP"
unset COORD_DIR SESSION_ID
unset COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR
unset COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS
unset COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR

# ---------------------------------------------------------------
# Aggregate + exit
# ---------------------------------------------------------------

banner "Aggregate"
log "Phase 1 (ship-gate drivers):  $PASS_DRIVERS passed, $FAIL_DRIVERS failed"
log "Phase 2 (cost-guard exercise): $CG_PASS passed, $CG_FAIL failed"

if [ "$FAIL_DRIVERS" -gt 0 ]; then
  log ""
  log "RESULT: FAILED (scenario failure — production bug or harness bug)"
  exit 1
fi
if [ "$CG_FAIL" -gt 0 ]; then
  log ""
  log "RESULT: FAILED (unexpected rate-limit pattern — cost-guard misconfiguration)"
  exit 2
fi

log ""
log "RESULT: PASS — all scenarios + cost-guard exercise green under mode=$MODE"
exit 0

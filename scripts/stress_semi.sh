#!/usr/bin/env bash
# stress_semi.sh — Phase 7 / T7.08 manual stress test for
# COORD_TEST_MODE=semi per PR-PHASE7-04 §"Manual stress test
# scripts" + the Phase 7 prep discussion T7.08 binding.
#
# Mode: semi.
#   - Mediator + Task Processor → real `claude -p` (per
#     PR-PHASE7-01 routing matrix)
#   - Validator → mock binary (mock-routed in semi)
#
# Scope:
#   1. Run all existing ship-gate driver suites in sequence
#      with COORD_TEST_MODE=semi exported. Drivers internally
#      use the hook-sim mock-binary path, but the mode-aware
#      spawn helper dispatch is exercised end-to-end via
#      audit-event payload.
#   2. Append a focused cost-guard exercise: drive the
#      mediator + validator rate-limit boundaries directly via
#      lib/cost_guards.sh CLI shim; verify rc=1 + audit
#      events + graceful counter behavior.
#
# Cost estimate: $0 in mock-binary path (default); ~$0.50-1.00
# if operator has a real `claude` binary on PATH AND a
# real-Claude scenario is added in the future. CI-safe by
# default.
#
# Prerequisites:
#   - jq, flock (verified by lib invocations)
#   - Optional: `claude` binary on PATH for spawn helper to
#     route to real (else spawn helper degrades to
#     claude_binary_missing per existing Phase 3-4 contract)
#   - .coord/ workspace (script clears + re-init's its own)
#
# Exit codes (per user T7.08 prompt §"Exit semantics"):
#   0  all scenarios PASS, no unexpected rate-limit
#   1  scenario failure (production bug or harness bug)
#   2  unexpected rate-limit pattern (cost-guard
#      misconfiguration)
#   3  setup/teardown failure
#
# Output: scripts/stress_semi_out/<ISO_ts>.log captures
# fixture-by-fixture results + cost-guard event excerpts.
#
# §A.13 lesson application:
#   - #7 Bash 3.2 parser: avoid out=$( ( cmd ) 9>"lock" )
#     (no flock subshells needed in this orchestrator).
#   - #11 multi-assign local + set -u: every `local` declares
#     one variable.
#   - #19 fixture set -e inheritance: ship-gate drivers use
#     `set -uo pipefail` (no `e`); rate-limit exercise
#     intentionally runs commands that exit non-zero — must
#     not propagate set -e abort. Use `|| rc=$?` form.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/scripts/stress_semi_out"
mkdir -p "$OUT_DIR"

ISO_TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
LOG_FILE="$OUT_DIR/${ISO_TS}.log"

MODE="semi"

# ---------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------

# Two-stream logger: tees to both console and the per-run log.
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

banner "stress_semi.sh — Phase 7 / T7.08 manual stress test"
log "ISO timestamp: $ISO_TS"
log "Repo root:     $REPO_ROOT"
log "Log file:      $LOG_FILE"
log "Mode:          $MODE"
log "claude on PATH: $(command -v claude 2>/dev/null || printf '(absent)')"

export COORD_TEST_MODE="$MODE"

# Verify spawn_helper resolves correctly under this mode. Source
# only what we need to call resolve_mode + cost_guards.
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
# Phase 1 — ship-gate driver suite under semi mode
# ---------------------------------------------------------------

banner "Phase 1: ship-gate driver suites (mode=semi)"

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
# Phase 2 — cost-guard rate-limit exercise (intentional)
# ---------------------------------------------------------------

banner "Phase 2: cost-guard rate-limit exercise (intentional)"

# Use a tmpdir-scoped COORD_DIR so we don't clobber any active
# coord state. Tight caps: 2 hourly per site for fast boundary
# verification.
CG_TMP="$(mktemp -d -t stress-semi-cg-XXXX)"
mkdir -p "$CG_TMP/.coord"
export COORD_DIR="$CG_TMP/.coord"
export SESSION_ID="stress-semi-cg-test"
export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=2
export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
export COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=2

# In semi mode the routing matrix says:
#   mediator       → real (cost-guard ENFORCED)
#   validator      → mock (cost-guard SKIPPED at spawn site)
#   task_processor → real (cost-guard reserved/always-allow)
#
# So this exercise focuses on Mediator. Validator + task_processor
# rate-limit semantics are still verified directly via the lib
# CLI here — the lib enforces regardless of mode (mode bypass
# is a SPAWN-SITE decision, not a lib decision).

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

cg_step "mediator check 1 (under cap)"  "0" check mediator
cg_step "mediator check 2 (at cap)"     "0" check mediator
cg_step "mediator check 3 (over cap)"   "1" check mediator
cg_step "validator check 1 (under cap)" "0" check validator
cg_step "validator check 2 (at cap)"    "0" check validator
cg_step "validator check 3 (over cap)"  "1" check validator
cg_step "mediator clear"                "0" clear mediator
cg_step "mediator check post-clear"     "0" check mediator

log ""
log "Phase 2 summary: $CG_PASS passed, $CG_FAIL failed"

# Audit-event evidence: must contain at least 2
# COST_GUARD_RATE_LIMITED entries (one per site).
if [ -s "$COORD_DIR/events.jsonl" ]; then
  rl_count=$(jq -rs '[.[] | select(.kind=="COST_GUARD_RATE_LIMITED")] | length' "$COORD_DIR/events.jsonl" 2>/dev/null || printf '0')
  log "COST_GUARD_RATE_LIMITED events observed: $rl_count (expected >=2)"
  if [ "$rl_count" -lt 2 ]; then
    CG_FAIL=$((CG_FAIL + 1))
    log "  WARN: insufficient rate-limited events"
  fi
fi

# Cleanup CG tmpdir.
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

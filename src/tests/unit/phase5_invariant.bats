#!/usr/bin/env bats
# Phase 5 ship-gate invariant: permissionDecision: "deny" appears in
# EXACTLY two architectural sources (UNCHANGED from Phase 3+4 — Phase 5
# adds NO new deny location per PR-PHASE5-05 + Decision 5):
#
#   1. pre_tool_use_write.sh lock-held-by-other branch (Phase 2 —
#      emit_deny call after the lock-state check).
#   2. lib/lockdown.sh coord_lockdown_emit_deny (Phase 3 — invoked by
#      every hook when coord_lockdown_check returns 0; Mediator
#      lockdown verdicts route through this gate).
#
# Phase 5 ADDS three bonus guards (#12, #13, #14) for the new lib/
# components introduced by T5.02 / T5.03 / T5.05. Plus Phase 5 NEW
# architectural guards (#7 + #8) confirm Mediator dispatch remains
# kind-agnostic (cycle_detected handled without code changes per
# PR-PHASE5-04 / Decision 4) and watchdog probe stays 3-signal
# conservative.
#
# Total: 8 architectural + 6 bonus = 14 guards.
#
# This file SUPERSEDES phase4_invariant.bats (Phase 4's 9 guards are
# carried forward verbatim or merged into the 14-guard structure
# below). phase4_invariant.bats is deleted as part of T5.07; mirrors
# the Phase 3 → Phase 4 transition (phase3_invariant.bats deleted at
# T4.06).

load "../helpers/common"

HOOKS_DIR="$SRC_ROOT/hooks"
LIB_DIR="$SRC_ROOT/lib"

# === Architectural guards (8) — carry-forward from Phase 4 + Phase 5 NEW ===

@test "phase5 invariant #1: permissionDecision occurrences in hooks/ are confined to pre_tool_use_write.sh" {
  for f in "$HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if [ "$base" = "pre_tool_use_write.sh" ]; then
      continue
    fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: $base emits permissionDecision in code (not just comments)." >&2
      echo "Allowed locations: pre_tool_use_write.sh lock-held branch + lib/lockdown.sh coord_lockdown_emit_deny." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'permissionDecision' >&2
      return 1
    fi
  done
}

@test "phase5 invariant #2: permissionDecision occurrences in lib/ are confined to lockdown.sh" {
  for f in "$LIB_DIR"/*.sh; do
    base=$(basename "$f")
    if [ "$base" = "lockdown.sh" ]; then
      continue
    fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: $base emits permissionDecision in code (not just comments)." >&2
      echo "Allowed locations: pre_tool_use_write.sh lock-held branch + lib/lockdown.sh coord_lockdown_emit_deny." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'permissionDecision' >&2
      return 1
    fi
  done
}

@test "phase5 invariant #3: pre_tool_use_write.sh emits permissionDecision in exactly one place" {
  count=$(grep -cE '^[[:space:]]*emit_deny[[:space:]]' "$HOOKS_DIR/pre_tool_use_write.sh" || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 emit_deny call site, got $count"; grep -nE 'emit_deny' "$HOOKS_DIR/pre_tool_use_write.sh"; return 1; }
}

@test "phase5 invariant #4: lib/lockdown.sh emits permissionDecision in exactly one place" {
  count=$(grep -v '^[[:space:]]*#' "$LIB_DIR/lockdown.sh" | grep -c '"deny"' || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 deny-emit site in lockdown.sh, got $count"; return 1; }
}

@test "phase5 invariant #5: every coord-owned hook sources lib/lockdown.sh and calls coord_lockdown_check + coord_lockdown_emit_deny" {
  for f in "$HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if ! grep -q 'lockdown\.sh' "$f"; then
      echo "VIOLATION: $base does not source lib/lockdown.sh" >&2
      return 1
    fi
    if ! grep -q 'coord_lockdown_check' "$f"; then
      echo "VIOLATION: $base does not call coord_lockdown_check" >&2
      return 1
    fi
    if ! grep -q 'coord_lockdown_emit_deny' "$f"; then
      echo "VIOLATION: $base does not call coord_lockdown_emit_deny" >&2
      return 1
    fi
  done
}

@test "phase5 invariant #6: every hook is exit-0 fail-open (no exit 1/2 in error paths)" {
  for f in "$HOOKS_DIR"/*.sh; do
    if grep -E '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >/dev/null; then
      base=$(basename "$f")
      echo "VIOLATION: $base has a non-zero shell exit; coord hooks must fail-open" >&2
      grep -nE '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >&2
      return 1
    fi
  done
}

# === Phase 5 NEW architectural guards (#7 + #8) ===

@test "phase5 invariant #7: Mediator dispatch is kind-agnostic (no kind-branching in mediator_spawn / mediator_pending / verdict_apply)" {
  # Decision 4 binding (PR-PHASE5-04): cycle_detected is handled by
  # the same kind-agnostic 3-action contract that Phase 3 established
  # and Phase 4 critical_drift extended. Future kinds (Phase 6+) MUST
  # also fit without code changes. No `case ... cycle_detected)` or
  # `if ... critical_drift` branches in production lib code.
  for kind in cycle_detected critical_drift; do
    for f in mediator_spawn.sh mediator_pending.sh verdict_apply.sh; do
      target="$LIB_DIR/$f"
      [ -f "$target" ] || continue
      # Strip pure-comment lines so kind enum docs don't trip the guard.
      if grep -v '^[[:space:]]*#' "$target" \
           | grep -E "(case|if).*${kind}" >/dev/null 2>&1; then
        echo "VIOLATION: $f branches on kind=${kind} (kind-agnostic dispatch broken)" >&2
        grep -nE "(case|if).*${kind}" "$target" >&2
        return 1
      fi
    done
  done
}

@test "phase5 invariant #8: watchdog probe enforces 3-signal conservative model (Signal 1 PID liveness mandatory)" {
  # PR-PHASE3-02 §A: alive verdict REQUIRES Signal 1 (PID liveness).
  # Activity / lock-context signals (Signal 2/3) cannot promote to
  # alive on their own. The watchdog must NEVER return alive without
  # ps -p success. Static check via grep for the canonical
  # ps_lstart probe + the alive-verdict gating logic.
  if [ -f "$LIB_DIR/watchdog.sh" ]; then
    grep -q 'ps -p' "$LIB_DIR/watchdog.sh" \
      || { echo "VIOLATION: watchdog.sh does not call 'ps -p' for Signal 1"; return 1; }
    grep -q '_coord_watchdog_ps_lstart\|coord_watchdog.*lstart' "$LIB_DIR/watchdog.sh" \
      || { echo "VIOLATION: watchdog.sh does not invoke lstart probe (Signal 1)"; return 1; }
  fi
  # Cross-reference: full 3-signal semantics covered by watchdog.bats
  # (existing Phase 3 test suite).
  [ -f "$SRC_ROOT/tests/unit/watchdog.bats" ] \
    || { echo "VIOLATION: watchdog.bats missing (3-signal verification)"; return 1; }
}

# === Bonus guards (6) — Phase 4+5 components zero permissionDecision ===

@test "phase5 invariant #9: lib/validator_spawn.sh contains zero permissionDecision strings (Phase 4 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_spawn.sh emits permissionDecision in code." >&2
    echo "Validator MUST NOT deny — CRITICAL routes through Mediator → lockdown gate." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase5 invariant #10: lib/validator_prefilter.sh contains zero permissionDecision strings (Phase 4 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_prefilter.sh emits permissionDecision in code." >&2
    echo "Pre-filter MUST NOT deny — only returns SAFE or ESCALATE_TO_AGENT." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase5 invariant #11: lib/validator_cache.sh contains zero permissionDecision strings (Phase 4 carry-forward bonus)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_cache.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_cache.sh emits permissionDecision in code." >&2
    return 1
  fi
}

@test "phase5 invariant #12: lib/wait_queue.sh contains zero permissionDecision strings (Phase 5 NEW)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/wait_queue.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/wait_queue.sh emits permissionDecision in code." >&2
    echo "Queue ops are advisory; lock-acquire denial is at the existing site." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/wait_queue.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase5 invariant #13: lib/cycle_detection.sh contains zero permissionDecision strings (Phase 5 NEW)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/cycle_detection.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/cycle_detection.sh emits permissionDecision in code." >&2
    echo "Cycle detection routes through Mediator → lockdown gate; no direct deny." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/cycle_detection.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase5 invariant #14: lib/wait_backend.sh contains zero permissionDecision strings (Phase 5 NEW from T5.03)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/wait_backend.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/wait_backend.sh emits permissionDecision in code." >&2
    echo "Backend abstraction is mechanical; deny is not a backend concern." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/wait_backend.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

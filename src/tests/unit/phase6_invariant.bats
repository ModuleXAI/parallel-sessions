#!/usr/bin/env bats
# Phase 6 ship-gate invariant: permissionDecision: "deny" appears
# in EXACTLY two architectural sources (UNCHANGED from Phase
# 3+4+5 — Phase 6 adds NO new deny location per PR-PHASE6-04 +
# Decision 6):
#
#   1. pre_tool_use_write.sh lock-held-by-other branch
#      (Phase 2 — emit_deny call after the lock-state check).
#   2. lib/lockdown.sh coord_lockdown_emit_deny (Phase 3 —
#      invoked by every hook when coord_lockdown_check returns
#      0; Mediator lockdown verdicts route through this gate).
#
# Phase 6 ADDS three bonus guards (#15, #16, #17) for the new
# lib/ + bin/ components introduced by T6.02 / T6.04 / T6.05 +
# the Phase 6 CLI subcommands at T6.03 / T6.04. The 14 Phase
# 4+5 guards (#1-#14) carry forward verbatim with Phase 6
# scope updates.
#
# Total: 8 architectural + 9 bonus = 17 guards.
#
# Decision 6 binding (PR-PHASE6-04): chain depth, task graph
# cycles, ambiguous anchor, and toggle-disabled rejections in
# `coord task-open` are CLI-level errors (exit 1 + stderr),
# NOT permissionDecision. Stop hook's `decision: "block"`
# (Decision 2.13 + T6.07) is Stop's permission grammar —
# distinct from permissionDecision: "deny" and explicitly
# allowed at stop.sh. Comment-only references in production
# code (e.g., `# never permissionDecision.`) MUST not trip
# the guards; pattern handled by `grep -v '^[[:space:]]*#'`
# comment-strip preprocessing (consistent with Phase 5
# discipline).
#
# This file SUPERSEDES phase5_invariant.bats (deleted at T6.08).
# Mirrors Phase 4→5 transition T5.07 (phase4_invariant.bats
# deleted; phase5_invariant.bats supersedes).

load "../helpers/common"

HOOKS_DIR="$SRC_ROOT/hooks"
LIB_DIR="$SRC_ROOT/lib"
BIN_DIR="$SRC_ROOT/bin"

# === Architectural guards (8) — Phase 3+4+5 carry-forward ===

@test "phase6 invariant #1: permissionDecision occurrences in hooks/ are confined to pre_tool_use_write.sh" {
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

@test "phase6 invariant #2: permissionDecision occurrences in lib/ are confined to lockdown.sh" {
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

@test "phase6 invariant #3: pre_tool_use_write.sh emits permissionDecision in exactly one place" {
  count=$(grep -cE '^[[:space:]]*emit_deny[[:space:]]' "$HOOKS_DIR/pre_tool_use_write.sh" || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 emit_deny call site, got $count"; grep -nE 'emit_deny' "$HOOKS_DIR/pre_tool_use_write.sh"; return 1; }
}

@test "phase6 invariant #4: lib/lockdown.sh emits permissionDecision in exactly one place" {
  count=$(grep -v '^[[:space:]]*#' "$LIB_DIR/lockdown.sh" | grep -c '"deny"' || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 deny-emit site in lockdown.sh, got $count"; return 1; }
}

@test "phase6 invariant #5: every coord-owned hook sources lib/lockdown.sh and calls coord_lockdown_check + coord_lockdown_emit_deny" {
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

@test "phase6 invariant #6: every hook is exit-0 fail-open (no exit 1/2 in error paths)" {
  for f in "$HOOKS_DIR"/*.sh; do
    if grep -E '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >/dev/null; then
      base=$(basename "$f")
      echo "VIOLATION: $base has a non-zero shell exit; coord hooks must fail-open" >&2
      grep -nE '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >&2
      return 1
    fi
  done
}

@test "phase6 invariant #7: Mediator dispatch is kind-agnostic (no kind-branching in mediator_spawn / mediator_pending / verdict_apply)" {
  # Decision 4 (PR-PHASE5-04) + Decision 6 (PR-PHASE6-04) binding:
  # cycle_detected + critical_drift handled by the same kind-
  # agnostic 3-action contract. Future kinds (Phase 6+) MUST also
  # fit without code changes. No `case ... cycle_detected)` or
  # `if ... critical_drift` branches in production lib code.
  # Phase 6 task-graph cycles route through CLI-level rejection
  # (NOT a Mediator pending kind), so no task_cycle_detected
  # branching is expected either.
  for kind in cycle_detected critical_drift task_cycle_detected; do
    for f in mediator_spawn.sh mediator_pending.sh verdict_apply.sh; do
      target="$LIB_DIR/$f"
      [ -f "$target" ] || continue
      # Strip pure-comment lines so kind enum docs don't trip.
      if grep -v '^[[:space:]]*#' "$target" \
           | grep -E "(case|if).*${kind}" >/dev/null 2>&1; then
        echo "VIOLATION: $f branches on kind=${kind} (kind-agnostic dispatch broken)" >&2
        grep -nE "(case|if).*${kind}" "$target" >&2
        return 1
      fi
    done
  done
}

@test "phase6 invariant #8: watchdog probe enforces 3-signal conservative model (Signal 1 PID liveness mandatory)" {
  # PR-PHASE3-02 §A: alive verdict REQUIRES Signal 1 (PID
  # liveness). Activity / lock-context signals (Signal 2/3) cannot
  # promote to alive on their own.
  if [ -f "$LIB_DIR/watchdog.sh" ]; then
    grep -q 'ps -p' "$LIB_DIR/watchdog.sh" \
      || { echo "VIOLATION: watchdog.sh does not call 'ps -p' for Signal 1"; return 1; }
    grep -q '_coord_watchdog_ps_lstart\|coord_watchdog.*lstart' "$LIB_DIR/watchdog.sh" \
      || { echo "VIOLATION: watchdog.sh does not invoke lstart probe (Signal 1)"; return 1; }
  fi
  # Cross-reference: full 3-signal semantics covered by
  # watchdog.bats (existing Phase 3 test suite).
  [ -f "$SRC_ROOT/tests/unit/watchdog.bats" ] \
    || { echo "VIOLATION: watchdog.bats missing (3-signal verification)"; return 1; }
}

# === Bonus guards (9) — Phase 4+5+6 components zero permissionDecision ===
# Note: guards #9-#16 are technically redundant with guard #2 (which covers
# all lib/*.sh files except lockdown.sh) but appear explicitly here for
# defense-in-depth + better failure error messages indicating which
# specific component regressed.

@test "phase6 invariant #9: lib/validator_spawn.sh contains zero permissionDecision strings (Phase 4 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_spawn.sh emits permissionDecision in code." >&2
    echo "Validator MUST NOT deny — CRITICAL routes through Mediator → lockdown gate." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase6 invariant #10: lib/validator_prefilter.sh contains zero permissionDecision strings (Phase 4 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_prefilter.sh emits permissionDecision in code." >&2
    echo "Pre-filter MUST NOT deny — only returns SAFE or ESCALATE_TO_AGENT." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase6 invariant #11: lib/validator_cache.sh contains zero permissionDecision strings (Phase 4 carry-forward bonus)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_cache.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_cache.sh emits permissionDecision in code." >&2
    return 1
  fi
}

@test "phase6 invariant #12: lib/wait_queue.sh contains zero permissionDecision strings (Phase 5 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/wait_queue.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/wait_queue.sh emits permissionDecision in code." >&2
    echo "Queue ops are advisory; lock-acquire denial is at the existing site." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/wait_queue.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase6 invariant #13: lib/cycle_detection.sh contains zero permissionDecision strings (Phase 5 + T6.02 extension)" {
  # Extended scope: T6.02 added coord_cycle_detect_task_graph
  # function in the same file. Both functions (Phase 5
  # coord_cycle_detect for wait queue + T6.02 task graph variant)
  # must remain deny-free; CLI-level rejection at coord task-open
  # surfaces depth/cycle violations, NOT permissionDecision.
  if grep -v '^[[:space:]]*#' "$LIB_DIR/cycle_detection.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/cycle_detection.sh emits permissionDecision in code." >&2
    echo "Wait-queue cycles route through Mediator → lockdown gate; task-graph cycles route through coord task-open CLI exit 1; no direct deny." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/cycle_detection.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase6 invariant #14: lib/wait_backend.sh contains zero permissionDecision strings (Phase 5 carry-forward from T5.03)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/wait_backend.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/wait_backend.sh emits permissionDecision in code." >&2
    echo "Backend abstraction is mechanical; deny is not a backend concern." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/wait_backend.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

# === Phase 6 NEW bonus guards (#15-#17) ===

@test "phase6 invariant #15: lib/task_processor.sh contains zero permissionDecision strings (Phase 6 NEW from T6.05)" {
  # T6.05 NEW lib for post_tool_use_write task processor.
  # Processor outcomes (COMPLETED/CONFLICT/SKIPPED) are TASK
  # OUTCOMES persisted to .notifications[<opener>][<file>] +
  # TASK_OUTCOME_PERSISTED events; never permissionDecision.
  # CONFLICT outcome (anchor overlap with holder edit) is a
  # task verdict, not a hook deny. Decision 6 binding.
  [ -f "$LIB_DIR/task_processor.sh" ] \
    || { echo "VIOLATION: lib/task_processor.sh missing (T6.05 deliverable)"; return 1; }
  if grep -v '^[[:space:]]*#' "$LIB_DIR/task_processor.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/task_processor.sh emits permissionDecision in code." >&2
    echo "Task outcomes are advisory notifications; CONFLICT is a task verdict, not a hook deny." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/task_processor.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase6 invariant #16: lib/self_tasks.sh contains zero permissionDecision strings (Phase 6 NEW from T6.04)" {
  # T6.04 NEW lib for self-task management. Open / list /
  # check_unlocked / archive / cleanup_session + T6.06 reminder
  # throttle helpers + T6.07 stop_block helper. Self-task
  # management is record-keeping; deny happens only at the
  # existing pre_tool_use_write.sh lock-held branch
  # (architectural guard #1). Stop hook's `decision: "block"`
  # (T6.07) is Stop's permission grammar, NOT
  # permissionDecision: "deny".
  [ -f "$LIB_DIR/self_tasks.sh" ] \
    || { echo "VIOLATION: lib/self_tasks.sh missing (T6.04 deliverable)"; return 1; }
  if grep -v '^[[:space:]]*#' "$LIB_DIR/self_tasks.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/self_tasks.sh emits permissionDecision in code." >&2
    echo "Self-task management is record-keeping; deny location is pre_tool_use_write.sh lock-held branch." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/self_tasks.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase6 invariant #17: src/bin/coord CLI dispatcher contains zero permissionDecision strings (Phase 6 NEW from T6.03 + T6.04)" {
  # CLI subcommands `coord task-open` (T6.03) + `coord
  # self-delegate` (T6.04) reject via exit 1 + stderr ONLY
  # (Decision 6 binding). Comment-only references like
  # `# never permissionDecision.` (line 401 carry-forward
  # from T6.03 design) MUST not trip the guard — comment-strip
  # via `grep -v '^[[:space:]]*#'` handles them.
  [ -f "$BIN_DIR/coord" ] \
    || { echo "VIOLATION: src/bin/coord missing"; return 1; }
  if grep -v '^[[:space:]]*#' "$BIN_DIR/coord" | grep -q 'permissionDecision'; then
    echo "VIOLATION: src/bin/coord emits permissionDecision in code (not just comments)." >&2
    echo "Decision 6 binding: chain depth / cycle / anchor uniqueness / toggle disabled are CLI-level errors (exit 1 + stderr), NOT permissionDecision. Hook layer (pre_tool_use_*.sh) does NOT participate in CLI-level enforcement." >&2
    grep -nv '^[[:space:]]*#' "$BIN_DIR/coord" | grep 'permissionDecision' >&2
    return 1
  fi
}

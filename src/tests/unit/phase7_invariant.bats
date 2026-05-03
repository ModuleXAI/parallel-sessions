#!/usr/bin/env bats
# Phase 7 ship-gate invariant: permissionDecision: "deny"
# appears in EXACTLY two architectural sources (UNCHANGED from
# Phase 3+4+5+6 — Phase 7 adds NO new deny location per
# PR-PHASE7-05 + OQ7 binding):
#
#   1. pre_tool_use_write.sh lock-held-by-other branch
#      (Phase 2 — emit_deny call after the lock-state check).
#   2. lib/lockdown.sh coord_lockdown_emit_deny (Phase 3 —
#      invoked by every hook when coord_lockdown_check returns
#      0; Mediator lockdown verdicts route through this gate).
#
# Guards #1-#4 together enforce TOTAL deny-site count = 2
# across the entire codebase (each file confined + exact-1 emit
# count). Any code path that introduces a third
# permissionDecision: "deny" string will trip at least one of
# these guards.
#
# Phase 7 ADDS two NEW bonus guards (#18, #19) for the new
# lib/ components introduced by T7.02 (lib/spawn_helper.sh)
# and T7.04 (lib/cost_guards.sh). The 17 Phase 4+5+6 guards
# (#1-#17) carry forward verbatim with Phase 7 scope updates.
#
# Total: 8 architectural + 11 bonus = 19 guards.
#
# OQ7 binding: cost-guard rate-limit handling uses rc=1 fail-
# open at spawn-site call (caller proceeds with Phase 1
# fallback wording per PR-PHASE7-03 §"Hard block vs graceful
# degrade"); NEVER permissionDecision. Mode switching is
# helper-internal; spawn helper returns rc=0 or rc=1 with no
# permission verbs. T7.05 added VALIDATOR_PIPELINE_DEGRADED
# event + "[validator rate-limited]" banner suffix — both are
# COSMETIC additions to existing banner construction, NOT new
# deny sites. T7.05 cost_guards_modes.bats test #14
# explicitly verifies zero permissionDecision additions across
# the rate-limit handling paths.
#
# Stop hook's `decision: "block"` (Decision 2.13 + T6.07)
# carries forward unchanged; Stop's permission grammar is
# distinct from permissionDecision: "deny" and explicitly
# allowed at stop.sh.
#
# This file SUPERSEDES phase6_invariant.bats (deleted at
# T7.10). Mirrors Phase 6→7 transition consistent with prior
# T6.08 (Phase 5→6) and T5.07 (Phase 4→5) supersessions.

load "../helpers/common"

HOOKS_DIR="$SRC_ROOT/adapters/claude-code/hooks"
LIB_DIR="$SRC_ROOT/core/lib"
ADAPTER_LIB_DIR="$SRC_ROOT/adapters/claude-code/lib"
BIN_DIR="$SRC_ROOT/core/bin"

# === Architectural guards (8) — Phase 3+4+5+6 carry-forward ===

@test "phase7 invariant #1: permissionDecision occurrences in hooks/ are confined to pre_tool_use_write.sh" {
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

@test "phase7 invariant #2: permissionDecision occurrences in lib/ are confined to lockdown.sh" {
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

@test "phase7 invariant #3: pre_tool_use_write.sh emits permissionDecision in exactly one place" {
  count=$(grep -cE '^[[:space:]]*emit_deny[[:space:]]' "$HOOKS_DIR/pre_tool_use_write.sh" || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 emit_deny call site, got $count"; grep -nE 'emit_deny' "$HOOKS_DIR/pre_tool_use_write.sh"; return 1; }
}

@test "phase7 invariant #4: lib/lockdown.sh emits permissionDecision in exactly one place" {
  count=$(grep -v '^[[:space:]]*#' "$LIB_DIR/lockdown.sh" | grep -c '"deny"' || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 deny-emit site in lockdown.sh, got $count"; return 1; }
}

@test "phase7 invariant #5: every coord-owned hook sources lib/lockdown.sh and calls coord_lockdown_check + coord_lockdown_emit_deny" {
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

@test "phase7 invariant #6: every hook is exit-0 fail-open (no exit 1/2 in error paths)" {
  for f in "$HOOKS_DIR"/*.sh; do
    if grep -E '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >/dev/null; then
      base=$(basename "$f")
      echo "VIOLATION: $base has a non-zero shell exit; coord hooks must fail-open" >&2
      grep -nE '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >&2
      return 1
    fi
  done
}

@test "phase7 invariant #7: Mediator dispatch is kind-agnostic (no kind-branching in mediator_spawn / mediator_pending / verdict_apply)" {
  # Decision 4 (PR-PHASE5-04) + Decision 6 (PR-PHASE6-04) +
  # OQ7 (PR-PHASE7-05) binding: cycle_detected + critical_drift
  # + future kinds handled by the same kind-agnostic 3-action
  # contract. No `case ... cycle_detected)` or `if ... critical_
  # drift` branches in production lib code. Phase 6 task-graph
  # cycles route via CLI-level rejection at coord task-open
  # (not a Mediator pending kind). Phase 7 adds NO new pending
  # kinds — rate-limit handling is at the spawn site, not
  # Mediator dispatch.
  for kind in cycle_detected critical_drift task_cycle_detected; do
    for f in mediator_spawn.sh mediator_pending.sh verdict_apply.sh; do
      target="$LIB_DIR/$f"
      [ -f "$target" ] || continue
      if grep -v '^[[:space:]]*#' "$target" \
           | grep -E "(case|if).*${kind}" >/dev/null 2>&1; then
        echo "VIOLATION: $f branches on kind=${kind} (kind-agnostic dispatch broken)" >&2
        grep -nE "(case|if).*${kind}" "$target" >&2
        return 1
      fi
    done
  done
}

@test "phase7 invariant #8: watchdog probe enforces 3-signal conservative model (Signal 1 PID liveness mandatory)" {
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

# === Bonus guards (11) — Phase 4+5+6+7 components zero permissionDecision ===
# Note: guards #9-#19 are technically redundant with guard #2 (which covers
# all lib/*.sh files except lockdown.sh) but appear explicitly here for
# defense-in-depth + better failure error messages indicating which
# specific component regressed.

@test "phase7 invariant #9: lib/validator_spawn.sh contains zero permissionDecision strings (Phase 4 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_spawn.sh emits permissionDecision in code." >&2
    echo "Validator MUST NOT deny — CRITICAL routes through Mediator → lockdown gate." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #10: lib/validator_prefilter.sh contains zero permissionDecision strings (Phase 4 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_prefilter.sh emits permissionDecision in code." >&2
    echo "Pre-filter MUST NOT deny — only returns SAFE or ESCALATE_TO_AGENT." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #11: lib/validator_cache.sh contains zero permissionDecision strings (Phase 4 carry-forward bonus)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_cache.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_cache.sh emits permissionDecision in code." >&2
    return 1
  fi
}

@test "phase7 invariant #12: lib/wait_queue.sh contains zero permissionDecision strings (Phase 5 carry-forward)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/wait_queue.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/wait_queue.sh emits permissionDecision in code." >&2
    echo "Queue ops are advisory; lock-acquire denial is at the existing site." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/wait_queue.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #13: lib/cycle_detection.sh contains zero permissionDecision strings (Phase 5 + T6.02 extension)" {
  # Both functions (Phase 5 coord_cycle_detect for wait queue +
  # T6.02 task graph variant) must remain deny-free; CLI-level
  # rejection at coord task-open surfaces depth/cycle
  # violations, NOT permissionDecision.
  if grep -v '^[[:space:]]*#' "$LIB_DIR/cycle_detection.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/cycle_detection.sh emits permissionDecision in code." >&2
    echo "Wait-queue cycles route through Mediator → lockdown gate; task-graph cycles route through coord task-open CLI exit 1; no direct deny." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/cycle_detection.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #14: lib/wait_backend.sh contains zero permissionDecision strings (Phase 5 carry-forward from T5.03)" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/wait_backend.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/wait_backend.sh emits permissionDecision in code." >&2
    echo "Backend abstraction is mechanical; deny is not a backend concern." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/wait_backend.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #15: lib/task_processor.sh contains zero permissionDecision strings (Phase 6 carry-forward from T6.05)" {
  # T6.05 lib for post_tool_use_write task processor.
  # Processor outcomes (COMPLETED/CONFLICT/SKIPPED) are TASK
  # OUTCOMES persisted to .notifications[<opener>][<file>] +
  # TASK_OUTCOME_PERSISTED events; never permissionDecision.
  # T7.03 added _coord_tp_real_claude_spawn helper (mode-aware
  # real-claude branch); T7.05 renamed REFUSED→RATE_LIMITED
  # event kind. Both extensions remain deny-free.
  [ -f "$LIB_DIR/task_processor.sh" ] \
    || { echo "VIOLATION: lib/task_processor.sh missing"; return 1; }
  if grep -v '^[[:space:]]*#' "$LIB_DIR/task_processor.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/task_processor.sh emits permissionDecision in code." >&2
    echo "Task outcomes are advisory notifications; CONFLICT is a task verdict, not a hook deny. Rate-limit fail-open at spawn site." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/task_processor.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #16: lib/self_tasks.sh contains zero permissionDecision strings (Phase 6 carry-forward from T6.04)" {
  # T6.04 lib for self-task management. Self-task management is
  # record-keeping; deny happens only at the existing
  # pre_tool_use_write.sh lock-held branch (architectural guard
  # #1). Stop hook's `decision: "block"` (T6.07) is Stop's
  # permission grammar, NOT permissionDecision: "deny".
  [ -f "$LIB_DIR/self_tasks.sh" ] \
    || { echo "VIOLATION: lib/self_tasks.sh missing"; return 1; }
  if grep -v '^[[:space:]]*#' "$LIB_DIR/self_tasks.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/self_tasks.sh emits permissionDecision in code." >&2
    echo "Self-task management is record-keeping; deny location is pre_tool_use_write.sh lock-held branch." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/self_tasks.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #17: src/core/bin/coord CLI dispatcher contains zero permissionDecision strings (Phase 6 carry-forward from T6.03 + T6.04)" {
  # CLI subcommands `coord task-open` (T6.03) + `coord
  # self-delegate` (T6.04) reject via exit 1 + stderr ONLY
  # (Decision 6 binding). Comment-only references like
  # `# never permissionDecision.` MUST not trip the guard —
  # comment-strip via `grep -v '^[[:space:]]*#'` handles them.
  # T7.06a added cleanup_interrupt sync log path (cmd_wait);
  # extension remains deny-free.
  [ -f "$BIN_DIR/coord" ] \
    || { echo "VIOLATION: src/core/bin/coord missing"; return 1; }
  if grep -v '^[[:space:]]*#' "$BIN_DIR/coord" | grep -q 'permissionDecision'; then
    echo "VIOLATION: src/core/bin/coord emits permissionDecision in code (not just comments)." >&2
    echo "Decision 6 binding: chain depth / cycle / anchor uniqueness / toggle disabled are CLI-level errors (exit 1 + stderr), NOT permissionDecision. Hook layer (pre_tool_use_*.sh) does NOT participate in CLI-level enforcement." >&2
    grep -nv '^[[:space:]]*#' "$BIN_DIR/coord" | grep 'permissionDecision' >&2
    return 1
  fi
}

# === Phase 7 NEW bonus guards (#18, #19) ===

@test "phase7 invariant #18: lib/spawn_helper.sh contains zero permissionDecision strings (Phase 7 NEW from T7.02)" {
  # T7.02 NEW lib for mode-aware claude binary routing.
  # coord_spawn_helper_resolve_mode + coord_spawn_helper_should_
  # use_real_claude are read-only routing helpers — no deny
  # decisions. Mode dispatch is helper-internal; the spawn site
  # consumes rc=0/rc=1 for routing only, NEVER permission verbs.
  # Per OQ7 binding (PR-PHASE7-05): "Mode switching is helper-
  # internal; spawn helper returns rc=0 or rc=1 with no
  # permission verbs."
  [ -f "$LIB_DIR/spawn_helper.sh" ] \
    || { echo "VIOLATION: lib/spawn_helper.sh missing (T7.02 deliverable)"; return 1; }
  if grep -v '^[[:space:]]*#' "$LIB_DIR/spawn_helper.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/spawn_helper.sh emits permissionDecision in code." >&2
    echo "Mode-aware spawn dispatch is read-only routing; deny is a hook-level concern, not a spawn-helper concern." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/spawn_helper.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase7 invariant #19: lib/cost_guards.sh contains zero permissionDecision strings (Phase 7 NEW from T7.04)" {
  # T7.04 NEW lib for sliding-window rate-limit counters.
  # coord_cost_guards_check returns rc=0 (allow) or rc=1
  # (rate_limited); rate-limit is fail-open at the spawn-site
  # call (caller proceeds with Phase 1 fallback per PR-PHASE7-03
  # §"Hard block vs graceful degrade"). NEVER permission deny.
  # T7.05 added VALIDATOR_PIPELINE_DEGRADED event +
  # "[validator rate-limited]" banner suffix at
  # pre_tool_use_write.sh — both COSMETIC additions to existing
  # banner construction, NOT new deny sites. T7.05's
  # cost_guards_modes.bats #14 cross-verifies this contract.
  [ -f "$LIB_DIR/cost_guards.sh" ] \
    || { echo "VIOLATION: lib/cost_guards.sh missing (T7.04 deliverable)"; return 1; }
  if grep -v '^[[:space:]]*#' "$LIB_DIR/cost_guards.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/cost_guards.sh emits permissionDecision in code." >&2
    echo "Cost guard is rate limit, not security gate. Rate-limit handling is rc=1 fail-open at spawn site, never a hook deny." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/cost_guards.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

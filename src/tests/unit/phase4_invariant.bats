#!/usr/bin/env bats
# Phase 4 ship-gate invariant: permissionDecision: "deny" appears in
# EXACTLY two architectural sources (UNCHANGED from Phase 3 — Phase 4
# adds NO new deny location per PR-PHASE4-02 + Concern B disposition):
#
#   1. pre_tool_use_write.sh lock-held-by-other branch (existing
#      Phase 2 — emit_deny call after the lock-state check).
#   2. lib/lockdown.sh coord_lockdown_emit_deny (existing Phase 3 —
#      invoked by every hook when coord_lockdown_check returns 0).
#
# Phase 4 ADDS two new architectural guards (#7 + #8 below) asserting
# the new validator libs do NOT emit permissionDecision in any code
# path. Total: 8 architectural guards.
#
# This file SUPERSEDES phase3_invariant.bats (Phase 3's 6 guards
# remain valid; Phase 4 strictly adds guards). phase3_invariant.bats
# is deleted as part of T4.06.

load "../helpers/common"

HOOKS_DIR="$SRC_ROOT/hooks"
LIB_DIR="$SRC_ROOT/lib"

# === Phase 3 carry-forward guards (6) ===

@test "phase4 invariant #1: permissionDecision occurrences in hooks/ are confined to pre_tool_use_write.sh" {
  # Strip pure-comment lines, then grep the remaining executable code.
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

@test "phase4 invariant #2: permissionDecision occurrences in lib/ are confined to lockdown.sh" {
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

@test "phase4 invariant #3: pre_tool_use_write.sh emits permissionDecision in exactly one place" {
  count=$(grep -cE '^[[:space:]]*emit_deny[[:space:]]' "$HOOKS_DIR/pre_tool_use_write.sh" || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 emit_deny call site, got $count"; grep -nE 'emit_deny' "$HOOKS_DIR/pre_tool_use_write.sh"; return 1; }
}

@test "phase4 invariant #4: lib/lockdown.sh emits permissionDecision in exactly one place" {
  count=$(grep -v '^[[:space:]]*#' "$LIB_DIR/lockdown.sh" | grep -c '"deny"' || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 deny-emit site in lockdown.sh, got $count"; return 1; }
}

@test "phase4 invariant #5: every coord-owned hook sources lib/lockdown.sh and calls coord_lockdown_check + coord_lockdown_emit_deny" {
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

@test "phase4 invariant #6: every non-write hook is exit-0 fail-open (no exit 1/2 in error paths)" {
  for f in "$HOOKS_DIR"/*.sh; do
    if grep -E '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >/dev/null; then
      base=$(basename "$f")
      echo "VIOLATION: $base has a non-zero shell exit; coord hooks must fail-open" >&2
      grep -nE '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >&2
      return 1
    fi
  done
}

# === Phase 4 NEW guards (2) ===

@test "phase4 invariant #7: lib/validator_spawn.sh contains zero permissionDecision strings" {
  # Validator does not deny. CRITICAL escalates via Mediator → which
  # routes deny through the existing lockdown gate (#2). Static guard
  # against future regressions.
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_spawn.sh emits permissionDecision in code." >&2
    echo "Validator MUST NOT deny — CRITICAL routes through Mediator → lockdown gate." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_spawn.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

@test "phase4 invariant #8: lib/validator_prefilter.sh contains zero permissionDecision strings" {
  # Pre-filter is a deterministic SAFE/ESCALATE classifier; it never
  # denies. Static guard against future regressions.
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_prefilter.sh emits permissionDecision in code." >&2
    echo "Pre-filter MUST NOT deny — only returns SAFE or ESCALATE_TO_AGENT." >&2
    grep -nv '^[[:space:]]*#' "$LIB_DIR/validator_prefilter.sh" | grep 'permissionDecision' >&2
    return 1
  fi
}

# Defensive: also assert validator_cache.sh doesn't deny (it's
# deterministic; would never need to). Bonus guard, not counted in
# the architectural 8.

@test "phase4 invariant bonus: lib/validator_cache.sh contains zero permissionDecision strings" {
  if grep -v '^[[:space:]]*#' "$LIB_DIR/validator_cache.sh" | grep -q 'permissionDecision'; then
    echo "VIOLATION: lib/validator_cache.sh emits permissionDecision in code." >&2
    return 1
  fi
}

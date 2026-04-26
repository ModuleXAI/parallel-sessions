#!/usr/bin/env bats
# Phase 3 ship-gate invariant: permissionDecision: "deny" appears in
# EXACTLY two architectural sources (renamed + expanded from
# phase2_invariant.bats per T3.03 / PR-PHASE3-01):
#
#   1. pre_tool_use_write.sh lock-held-by-other branch (existing
#      Phase 2 — emit_deny call after the lock-state check).
#   2. lib/lockdown.sh coord_lockdown_emit_deny (new Phase 3 — invoked
#      by every hook when coord_lockdown_check returns 0).
#
# Every other hook MUST delegate to coord_lockdown_emit_deny via the
# function call (no inlined permissionDecision JSON in any other hook
# file). This keeps the deny-source surface area to two architectural
# sites that the test enumerates.
#
# Phase 1's invariant ("no permissionDecision anywhere") inverted at
# Phase 2 to "exactly one site"; Phase 3 expands to "exactly two
# sites." Every other code path in every hook MUST remain
# allow / no-op / fail-open.

load "../helpers/common"

HOOKS_DIR="$SRC_ROOT/hooks"
LIB_DIR="$SRC_ROOT/lib"

@test "phase3 invariant: permissionDecision occurrences in hooks/ are confined to pre_tool_use_write.sh" {
  # Strip pure-comment lines (lines whose first non-whitespace char is
  # `#`), then grep the remaining executable code. Hooks MAY mention
  # the invariant in their docstrings — those are explanatory and
  # not runtime emissions.
  for f in "$HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if [ "$base" = "pre_tool_use_write.sh" ]; then
      continue   # this IS the lock-held deny site (allowed location 1)
    fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: $base emits permissionDecision in code (not just comments)." >&2
      echo "Allowed locations: pre_tool_use_write.sh lock-held branch + lib/lockdown.sh coord_lockdown_emit_deny." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'permissionDecision' >&2
      return 1
    fi
  done
}

@test "phase3 invariant: permissionDecision occurrences in lib/ are confined to lockdown.sh" {
  # The new architectural deny site is lib/lockdown.sh (the
  # coord_lockdown_emit_deny function). No other lib/ module may
  # emit permissionDecision in code.
  for f in "$LIB_DIR"/*.sh; do
    base=$(basename "$f")
    if [ "$base" = "lockdown.sh" ]; then
      continue   # this IS the lockdown deny site (allowed location 2)
    fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: $base emits permissionDecision in code (not just comments)." >&2
      echo "Allowed locations: pre_tool_use_write.sh lock-held branch + lib/lockdown.sh coord_lockdown_emit_deny." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'permissionDecision' >&2
      return 1
    fi
  done
}

@test "phase3 invariant: pre_tool_use_write.sh emits permissionDecision in exactly one place" {
  # The hook contains exactly one emit_deny call site (function
  # definition + one call from the locked-by-other branch). Defensive
  # count: the runtime emission must be ONE call.
  count=$(grep -cE '^[[:space:]]*emit_deny[[:space:]]' "$HOOKS_DIR/pre_tool_use_write.sh" || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 emit_deny call site in pre_tool_use_write.sh, got $count"; grep -nE 'emit_deny' "$HOOKS_DIR/pre_tool_use_write.sh"; return 1; }
}

@test "phase3 invariant: lib/lockdown.sh emits permissionDecision in exactly one place" {
  # coord_lockdown_emit_deny is the single deny-emit function; only
  # one occurrence of the literal `"deny"` string should appear in
  # lockdown.sh executable code (inside the jq -nc filter).
  count=$(grep -v '^[[:space:]]*#' "$LIB_DIR/lockdown.sh" | grep -c '"deny"' || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 deny-emit site in lib/lockdown.sh, got $count"; return 1; }
}

@test "phase3 invariant: every coord-owned hook sources lib/lockdown.sh and calls coord_lockdown_check + coord_lockdown_emit_deny" {
  # Architectural assertion: every hook on every tool call respects
  # the lockdown gate. We enumerate hooks/*.sh and confirm both
  # (a) the source line is present and (b) the gate is invoked.
  for f in "$HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if ! grep -q 'lockdown\.sh' "$f"; then
      echo "VIOLATION: $base does not source lib/lockdown.sh" >&2
      return 1
    fi
    if ! grep -q 'coord_lockdown_check' "$f"; then
      echo "VIOLATION: $base does not call coord_lockdown_check (lockdown gate missing)" >&2
      return 1
    fi
    if ! grep -q 'coord_lockdown_emit_deny' "$f"; then
      echo "VIOLATION: $base does not call coord_lockdown_emit_deny (lockdown deny path missing)" >&2
      return 1
    fi
  done
}

@test "phase3 invariant: every non-write hook is exit-0 fail-open (no exit 1/2 in error paths)" {
  # Belt + braces: confirm every coord-owned hook ends/exits with 0
  # in all reachable paths. This rules out a stray `exit 2` accidentally
  # creating Claude-Code-level blocking behavior.
  for f in "$HOOKS_DIR"/*.sh; do
    if grep -E '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >/dev/null; then
      base=$(basename "$f")
      echo "VIOLATION: $base has a non-zero shell exit; coord hooks must fail-open" >&2
      grep -nE '^[[:space:]]*exit[[:space:]]+[12][[:space:]]*$' "$f" >&2
      return 1
    fi
  done
}

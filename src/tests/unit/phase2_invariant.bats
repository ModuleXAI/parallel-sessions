#!/usr/bin/env bats
# Phase 2 ship-gate invariant: permissionDecision: "deny" appears ONLY in
# the lock-held-by-other branch of pre_tool_use_write.sh.
#
# Phase 1's invariant was "no permissionDecision anywhere."
# Phase 2's invariant inverts: exactly one location emits "deny", and
# the location is exactly the file/branch the plan §5 Phase 2 names.
# Every other code path in every other hook MUST remain allow / no-op.

load "../helpers/common"

HOOKS_DIR="$SRC_ROOT/hooks"

@test "phase2 invariant: permissionDecision occurrences are confined to pre_tool_use_write.sh" {
  # Across all production hooks, scan for the literal string
  # `permissionDecision` in NON-COMMENT lines. The token must appear in
  # executable code ONLY in pre_tool_use_write.sh (the deny path); every
  # other hook is required to remain allow / no-op / fail-open. Hooks
  # MAY mention the invariant in their docstring comments — those are
  # explanatory and not runtime emissions.
  for f in "$HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if [ "$base" = "pre_tool_use_write.sh" ]; then
      continue   # this IS the deny site
    fi
    # Strip lines whose first non-whitespace character is `#` (pure
    # comment lines), then grep what remains.
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: $base emits permissionDecision in code (not just comments); only pre_tool_use_write.sh may emit it." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'permissionDecision' >&2
      return 1
    fi
  done
}

@test "phase2 invariant: pre_tool_use_write.sh emits permissionDecision in exactly one place" {
  # The hook contains exactly one emit_deny call site (function definition
  # + one call from the locked-by-other branch). Defensive count: the
  # token `permissionDecision` should appear in the `emit_deny` jq filter
  # PLUS the docstring/comments — but the runtime emission must be ONE call.
  count=$(grep -cE '^[[:space:]]*emit_deny[[:space:]]' "$HOOKS_DIR/pre_tool_use_write.sh" || true)
  [ "$count" = "1" ] || { echo "expected exactly 1 emit_deny call site in pre_tool_use_write.sh, got $count"; grep -nE 'emit_deny' "$HOOKS_DIR/pre_tool_use_write.sh"; return 1; }
}

@test "phase2 invariant: every non-write hook is exit-0 fail-open (no exit 1/2 in error paths)" {
  # Belt + braces: confirm every coord-owned hook ends/exits with 0 in
  # all reachable paths. This rules out a stray `exit 2` accidentally
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

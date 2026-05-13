#!/usr/bin/env bats
# Cross-agent deadlock-cycle scenarios (PR F.2 — deeper).
#
# Two sessions of different agent types each hold a lock the other
# wants. Validates:
#   - Both sides receive deny banners (no progress for either).
#   - Cycle detection (cycle_detection.sh) recognizes the bipartite
#     wait graph as a cycle when both waiters enqueue.
#   - Neither lock leaks; .coord state remains consistent.
#
# Cycle resolution itself (Mediator forcibly evicting one side) is
# a deeper Phase F or Mediator-specific concern; these tests focus on
# DETECTION + state correctness, not resolution.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/cycle_detection.sh"
}
teardown() { xagent_teardown; }

@test "cycle: claude holds A + codex holds B → both deny (no progress)" {
  xagent_session_start claude_code "ch-cyc1"
  xagent_session_start codex       "cx-cyc1"
  printf 'old\n' >"$XAGENT_TMP/A.ts"
  printf 'old\n' >"$XAGENT_TMP/B.ts"
  xagent_pretooluse_write claude_code "ch-cyc1" "$XAGENT_TMP/A.ts"
  ! xagent_last_was_deny
  xagent_pretooluse_write codex "cx-cyc1" "$XAGENT_TMP/B.ts"
  ! xagent_last_was_deny
  # Cross attempts: both denied.
  xagent_pretooluse_write claude_code "ch-cyc1" "$XAGENT_TMP/B.ts"
  xagent_last_was_deny
  xagent_pretooluse_write codex "cx-cyc1" "$XAGENT_TMP/A.ts"
  xagent_last_was_deny
  # Locks intact: A still owned by claude, B by codex.
  run xagent_lock_holder "$XAGENT_TMP/A.ts"
  [ "$output" = "ch-cyc1" ]
  run xagent_lock_holder "$XAGENT_TMP/B.ts"
  [ "$output" = "cx-cyc1" ]
}

@test "cycle: bipartite waiter graph (claude waits B, codex waits A) is detected as a cycle" {
  xagent_session_start claude_code "ch-cyc2"
  xagent_session_start codex       "cx-cyc2"
  printf 'old\n' >"$XAGENT_TMP/A2.ts"
  printf 'old\n' >"$XAGENT_TMP/B2.ts"
  xagent_pretooluse_write claude_code "ch-cyc2" "$XAGENT_TMP/A2.ts"
  xagent_pretooluse_write codex "cx-cyc2" "$XAGENT_TMP/B2.ts"
  # Both agents try the OTHER's file → denied; both enqueue as waiters.
  xagent_pretooluse_write claude_code "ch-cyc2" "$XAGENT_TMP/B2.ts"
  xagent_wait_enqueue "ch-cyc2" "$XAGENT_TMP/B2.ts"
  xagent_pretooluse_write codex "cx-cyc2" "$XAGENT_TMP/A2.ts"
  xagent_wait_enqueue "cx-cyc2" "$XAGENT_TMP/A2.ts"
  # cycle_detection should report a cycle from either entry point.
  run coord_cycle_detect "ch-cyc2" "$XAGENT_TMP/B2.ts"
  [ "$status" -eq 0 ]
}

@test "cycle: neither agent's lock is leaked under cycle conditions" {
  # Even with deadlock, .locks remains exactly the two seeded entries
  # — D.4 / pre_tool_use_write don't half-acquire on deny paths.
  xagent_session_start claude_code "ch-cyc3"
  xagent_session_start codex       "cx-cyc3"
  printf 'old\n' >"$XAGENT_TMP/A3.ts"
  printf 'old\n' >"$XAGENT_TMP/B3.ts"
  xagent_pretooluse_write claude_code "ch-cyc3" "$XAGENT_TMP/A3.ts"
  xagent_pretooluse_write codex "cx-cyc3" "$XAGENT_TMP/B3.ts"
  xagent_pretooluse_write claude_code "ch-cyc3" "$XAGENT_TMP/B3.ts"  # denied
  xagent_pretooluse_write codex "cx-cyc3" "$XAGENT_TMP/A3.ts"        # denied
  run xagent_lock_count
  [ "$output" = "2" ]
}

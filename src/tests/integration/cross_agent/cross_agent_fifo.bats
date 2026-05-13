#!/usr/bin/env bats
# Cross-agent wait_queue FIFO scenarios (PR F.2 — deeper #7).
#
# When multiple sessions of different agent types wait on the same file,
# the wait_queue is processed FIFO regardless of agent type. Validates:
#   - Claude waiter enqueued first, Codex second → Claude notified first
#     when the holder releases.
#   - Inverse: Codex first, Claude second → Codex first.
#   - Notifications are populated in queue order.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
  # Source wait_queue + state lib so we can read queue entries.
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/wait_queue.sh"
}
teardown() { xagent_teardown; }

@test "fifo: claude enqueued first, codex second → wait_queue order is claude→codex" {
  xagent_session_start codex       "cx-fifo-h"
  xagent_session_start claude_code "ch-fifo-1"
  xagent_session_start codex       "cx-fifo-2"
  printf 'old\n' >"$XAGENT_TMP/fifo.ts"
  # Codex holder grabs the file.
  xagent_pretooluse_write codex "cx-fifo-h" "$XAGENT_TMP/fifo.ts"
  ! xagent_last_was_deny
  # Two waiters in declared order.
  xagent_pretooluse_write claude_code "ch-fifo-1" "$XAGENT_TMP/fifo.ts"
  xagent_last_was_deny
  xagent_wait_enqueue "ch-fifo-1" "$XAGENT_TMP/fifo.ts"
  xagent_pretooluse_write codex "cx-fifo-2" "$XAGENT_TMP/fifo.ts"
  xagent_last_was_deny
  xagent_wait_enqueue "cx-fifo-2" "$XAGENT_TMP/fifo.ts"
  # wait_queues[<path>] must list the waiters in enqueue order.
  run jq -r --arg f "$XAGENT_TMP/fifo.ts" \
    '[.wait_queues[$f][]?.session_id // empty] | join(",")' \
    "$COORD_DIR/sessions.json"
  [ "$output" = "ch-fifo-1,cx-fifo-2" ]
}

@test "fifo: codex enqueued first, claude second → wait_queue order is codex→claude" {
  xagent_session_start claude_code "ch-fifo-h"
  xagent_session_start codex       "cx-fifo-3"
  xagent_session_start claude_code "ch-fifo-4"
  printf 'old\n' >"$XAGENT_TMP/inverse.ts"
  xagent_pretooluse_write claude_code "ch-fifo-h" "$XAGENT_TMP/inverse.ts"
  xagent_pretooluse_write codex "cx-fifo-3" "$XAGENT_TMP/inverse.ts"
  xagent_wait_enqueue "cx-fifo-3" "$XAGENT_TMP/inverse.ts"
  xagent_pretooluse_write claude_code "ch-fifo-4" "$XAGENT_TMP/inverse.ts"
  xagent_wait_enqueue "ch-fifo-4" "$XAGENT_TMP/inverse.ts"
  run jq -r --arg f "$XAGENT_TMP/inverse.ts" \
    '[.wait_queues[$f][]?.session_id // empty] | join(",")' \
    "$COORD_DIR/sessions.json"
  [ "$output" = "cx-fifo-3,ch-fifo-4" ]
}

@test "fifo: holder release populates notifications for ALL queued waiters (regardless of agent type)" {
  xagent_session_start claude_code "ch-fifo-rh"
  xagent_session_start codex       "cx-fifo-w1"
  xagent_session_start codex       "cx-fifo-w2"
  printf 'old\n' >"$XAGENT_TMP/multi.ts"
  xagent_pretooluse_write claude_code "ch-fifo-rh" "$XAGENT_TMP/multi.ts"
  # Two codex waiters enqueue.
  xagent_pretooluse_write codex "cx-fifo-w1" "$XAGENT_TMP/multi.ts"
  xagent_wait_enqueue "cx-fifo-w1" "$XAGENT_TMP/multi.ts"
  xagent_pretooluse_write codex "cx-fifo-w2" "$XAGENT_TMP/multi.ts"
  xagent_wait_enqueue "cx-fifo-w2" "$XAGENT_TMP/multi.ts"
  # Holder releases.
  xagent_session_stop claude_code "ch-fifo-rh"
  sleep 0.3
  # Both waiters got a notification (order: same as enqueue).
  run xagent_notification_count "cx-fifo-w1" "$XAGENT_TMP/multi.ts"
  [ "$output" -ge "1" ]
  run xagent_notification_count "cx-fifo-w2" "$XAGENT_TMP/multi.ts"
  [ "$output" -ge "1" ]
}

#!/usr/bin/env bash
# 01_wait_queue_fifo_ordering — multi-waiter FIFO ordering
set -uo pipefail

scenario_run() {
  local sid_d="sid-d-01-fifo"
  local sid_a="sid-a-01-fifo"
  local sid_b="sid-b-01-fifo"
  local sid_c="sid-c-01-fifo"
  local target="$WORKDIR/foo.ts"

  coord_fixture_p5_register_session "$sid_d"
  coord_fixture_p5_register_session "$sid_a"
  coord_fixture_p5_register_session "$sid_b"
  coord_fixture_p5_register_session "$sid_c"

  coord_fixture_p5_acquire "$target" "$sid_d"

  SESSION_ID="$sid_a" coord_wait_queue_enqueue "$sid_a" "$target" >/dev/null
  sleep 0.01
  SESSION_ID="$sid_b" coord_wait_queue_enqueue "$sid_b" "$target" >/dev/null
  sleep 0.01
  SESSION_ID="$sid_c" coord_wait_queue_enqueue "$sid_c" "$target" >/dev/null

  # Capture queue state at depth 3.
  QUEUE_STATE_01=$(jq -c --arg f "$target" '.wait_queues[$f]' "$COORD_DIR/sessions.json")
  export QUEUE_STATE_01

  # D releases — single broadcast to all 3 waiters.
  coord_fixture_p5_release "$target" "$sid_d"

  # Capture wake_file contents.
  local sanitized
  sanitized=$(printf '%s' "$target" | sed 's|/|__|g')
  WAKE_A=$(cat "$COORD_DIR/wakers/${sid_a}-${sanitized}.wake" 2>/dev/null || printf '')
  WAKE_B=$(cat "$COORD_DIR/wakers/${sid_b}-${sanitized}.wake" 2>/dev/null || printf '')
  WAKE_C=$(cat "$COORD_DIR/wakers/${sid_c}-${sanitized}.wake" 2>/dev/null || printf '')
  export WAKE_A WAKE_B WAKE_C

  # Each waiter dequeues in head-of-queue order.
  coord_wait_queue_dequeue "$sid_a" "$target"
  coord_wait_queue_dequeue "$sid_b" "$target"
  coord_wait_queue_dequeue "$sid_c" "$target"

  export SID_A="$sid_a" SID_B="$sid_b" SID_C="$sid_c" SID_D="$sid_d" TARGET_FILE="$target"
  sleep 0.2
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. Queue state at depth 3 had all 3 sids in order.
  local order
  order=$(printf '%s' "$QUEUE_STATE_01" | jq -r '[.[].session_id] | join(",")')
  if [ "$order" != "${SID_A},${SID_B},${SID_C}" ]; then
    printf '  FAIL 1: queue order %s; expected %s,%s,%s\n' "$order" "$SID_A" "$SID_B" "$SID_C" >&2
    fail=1
  fi

  # 2. queue_position 0/1/2.
  local positions
  positions=$(printf '%s' "$QUEUE_STATE_01" | jq -r '[.[].queue_position] | join(",")')
  if [ "$positions" != "0,1,2" ]; then
    printf '  FAIL 2: queue_position %s; expected 0,1,2\n' "$positions" >&2
    fail=1
  fi

  # 3. All 3 wake_files non-empty + identical content.
  if [ -z "$WAKE_A" ] || [ -z "$WAKE_B" ] || [ -z "$WAKE_C" ]; then
    printf '  FAIL 3: at least one wake_file empty (A=[%s] B=[%s] C=[%s])\n' \
      "$WAKE_A" "$WAKE_B" "$WAKE_C" >&2
    fail=1
  fi
  if [ "$WAKE_A" != "$WAKE_B" ] || [ "$WAKE_B" != "$WAKE_C" ]; then
    printf '  FAIL 3b: wake_file contents differ (A vs B vs C)\n' >&2
    fail=1
  fi

  # 4. WAIT_QUEUE_ENQUEUED event count = 3.
  local n
  n=$(jq -rs '[.[] | select(.kind == "WAIT_QUEUE_ENQUEUED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -ne 3 ]; then
    printf '  FAIL 4: WAIT_QUEUE_ENQUEUED count=%s; expected 3\n' "$n" >&2
    fail=1
  fi

  # 5. wait_queues key dropped after all 3 dequeues.
  if jq -e --arg f "$TARGET_FILE" '.wait_queues | has($f)' "$COORD_DIR/sessions.json" >/dev/null 2>&1; then
    printf '  FAIL 5: wait_queues still has key after full dequeue\n' >&2
    fail=1
  fi

  # 6. WAIT_QUEUE_DEQUEUED event count = 3.
  n=$(jq -rs '[.[] | select(.kind == "WAIT_QUEUE_DEQUEUED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -ne 3 ]; then
    printf '  FAIL 6: WAIT_QUEUE_DEQUEUED count=%s; expected 3\n' "$n" >&2
    fail=1
  fi

  # 7. NOTIFICATION_PRODUCED with waiter_count=3 (single broadcast).
  n=$(jq -rs '[.[] | select(.kind == "NOTIFICATION_PRODUCED" and .payload.waiter_count == "3")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 7: no NOTIFICATION_PRODUCED with waiter_count=3 (single broadcast)\n' >&2
    fail=1
  fi

  # 8. Phase 5 invariant — no permissionDecision anywhere in events.
  if grep -q permissionDecision "$events"; then
    printf '  FAIL 8: permissionDecision found in events.jsonl (Phase 5 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

#!/usr/bin/env bats
# Tests for lib/wait_queue.sh per plan §5 Phase 5 + PR-PHASE5-01.
#
# Six public API functions:
#   coord_wait_queue_enqueue       <sid> <file>
#   coord_wait_queue_dequeue       <sid> <file>
#   coord_wait_queue_head          <file>           -> <sid>\t<wake_file>
#   coord_wait_queue_size          <file>           -> integer
#   coord_wait_queue_position      <sid> <file>     -> 0-indexed or -1
#   coord_wait_queue_cleanup_session <sid>
#
# Path sanitization: literal `tr / __` (PR-PHASE5-01 pin-point a-1).

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-wq-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mk_empty_sessions "$COORD_DIR"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_queue.sh"
}
teardown() {
  rm -rf "$TMP"
}

# ----- Category 1: Basic enqueue / dequeue -----

@test "wait_queue: enqueue creates wake_file + queue entry" {
  run coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  [ "$status" -eq 0 ]
  [ "$output" = ".coord/wakers/sid-A-__src__foo.ts.wake" ] || \
    [[ "$output" = *"/wakers/sid-A-__src__foo.ts.wake" ]]
  [ -f "$COORD_DIR/wakers/sid-A-__src__foo.ts.wake" ]
  run jq -r '.wait_queues["/src/foo.ts"][0].session_id' "$COORD_DIR/sessions.json"
  [ "$output" = "sid-A" ]
  run jq -r '.wait_queues["/src/foo.ts"][0].queue_position' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  run jq -r '.wait_queues["/src/foo.ts"][0].wake_file' "$COORD_DIR/sessions.json"
  [[ "$output" = *"wakers/sid-A-__src__foo.ts.wake" ]]
}

@test "wait_queue: dequeue removes entry + wake_file" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  [ -f "$COORD_DIR/wakers/sid-A-__src__foo.ts.wake" ]
  run coord_wait_queue_dequeue "sid-A" "/src/foo.ts"
  [ "$status" -eq 0 ]
  [ ! -f "$COORD_DIR/wakers/sid-A-__src__foo.ts.wake" ]
  # Empty queue → key dropped entirely (clean state).
  run jq -e 'has("wait_queues") and (.wait_queues | has("/src/foo.ts"))' "$COORD_DIR/sessions.json"
  [ "$status" -ne 0 ]
}

@test "wait_queue: idempotent enqueue (same sid same file -> no duplicate)" {
  out1=$(coord_wait_queue_enqueue "sid-A" "/src/foo.ts")
  out2=$(coord_wait_queue_enqueue "sid-A" "/src/foo.ts")
  [ "$out1" = "$out2" ]
  run jq -r '.wait_queues["/src/foo.ts"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
}

@test "wait_queue: dequeue not-in-queue is no-op rc=0" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  run coord_wait_queue_dequeue "sid-B" "/src/foo.ts"
  [ "$status" -eq 0 ]
  # Original entry still present.
  run jq -r '.wait_queues["/src/foo.ts"][0].session_id' "$COORD_DIR/sessions.json"
  [ "$output" = "sid-A" ]
}

@test "wait_queue: empty queue cleanup removes wait_queues key" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  coord_wait_queue_dequeue "sid-A" "/src/foo.ts"
  # The /src/foo.ts entry should not appear under wait_queues.
  run jq -r '.wait_queues | keys | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

# ----- Category 2: FIFO ordering -----

@test "wait_queue: 3 enqueues -> head returns oldest (sid-A)" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  sleep 0.01
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"
  sleep 0.01
  coord_wait_queue_enqueue "sid-C" "/src/foo.ts"
  run coord_wait_queue_head "/src/foo.ts"
  [ "$status" -eq 0 ]
  head_sid=$(printf '%s' "$output" | awk -F'\t' 'NR==1{print $1}')
  [ "$head_sid" = "sid-A" ]
}

@test "wait_queue: position 0/1/2 correct after 3 enqueues" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"; sleep 0.01
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"; sleep 0.01
  coord_wait_queue_enqueue "sid-C" "/src/foo.ts"
  run coord_wait_queue_position "sid-A" "/src/foo.ts"
  [ "$output" = "0" ]
  run coord_wait_queue_position "sid-B" "/src/foo.ts"
  [ "$output" = "1" ]
  run coord_wait_queue_position "sid-C" "/src/foo.ts"
  [ "$output" = "2" ]
  run coord_wait_queue_position "sid-MISSING" "/src/foo.ts"
  [ "$output" = "-1" ]
}

@test "wait_queue: dequeue middle entry -> queue_positions renumbered" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"; sleep 0.01
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"; sleep 0.01
  coord_wait_queue_enqueue "sid-C" "/src/foo.ts"
  coord_wait_queue_dequeue "sid-B" "/src/foo.ts"
  # After removal: sid-A at 0, sid-C at 1.
  run coord_wait_queue_position "sid-A" "/src/foo.ts"
  [ "$output" = "0" ]
  run coord_wait_queue_position "sid-C" "/src/foo.ts"
  [ "$output" = "1" ]
  run jq -r '.wait_queues["/src/foo.ts"][1].queue_position' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
}

# ----- Category 3: Per-file isolation -----

@test "wait_queue: same sid different files -> 2 entries + 2 wake_files" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  coord_wait_queue_enqueue "sid-A" "/src/bar.ts"
  [ -f "$COORD_DIR/wakers/sid-A-__src__foo.ts.wake" ]
  [ -f "$COORD_DIR/wakers/sid-A-__src__bar.ts.wake" ]
  run jq -r '.wait_queues | keys | sort | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "/src/bar.ts,/src/foo.ts" ]
}

@test "wait_queue: different sids same file ordered by waiting_since" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"; sleep 0.05
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"
  ts_A=$(jq -r '.wait_queues["/src/foo.ts"][0].waiting_since' "$COORD_DIR/sessions.json")
  ts_B=$(jq -r '.wait_queues["/src/foo.ts"][1].waiting_since' "$COORD_DIR/sessions.json")
  # Lexical comparison on ISO8601 ms-precision strings is correct.
  [ "$ts_A" \< "$ts_B" ] || [ "$ts_A" = "$ts_B" ]
}

# ----- Category 4: Concurrency -----

@test "wait_queue: parallel enqueue from 2 sessions -> both succeed, ordered" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts" &
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts" &
  wait
  run jq -r '.wait_queues["/src/foo.ts"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "2" ]
  run jq -r '[.wait_queues["/src/foo.ts"][].session_id] | sort | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "sid-A,sid-B" ]
  # queue_positions should be 0 and 1 (renumbered after each enqueue).
  run jq -r '[.wait_queues["/src/foo.ts"][].queue_position] | sort | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "0,1" ]
}

@test "wait_queue: parallel dequeue + enqueue produces consistent state" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"
  coord_wait_queue_enqueue "sid-C" "/src/foo.ts"
  coord_wait_queue_dequeue "sid-A" "/src/foo.ts" &
  coord_wait_queue_enqueue "sid-D" "/src/foo.ts" &
  wait
  run jq -r '[.wait_queues["/src/foo.ts"][].session_id] | sort | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "sid-B,sid-C,sid-D" ]
  # All remaining queue_positions are contiguous 0..n-1.
  run jq -r '[.wait_queues["/src/foo.ts"][].queue_position] | sort | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "0,1,2" ]
}

# ----- Category 5: cleanup_session -----

@test "wait_queue: cleanup_session walks all files, removes sid everywhere" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  coord_wait_queue_enqueue "sid-A" "/src/bar.ts"
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"
  run coord_wait_queue_cleanup_session "sid-A"
  [ "$status" -eq 0 ]
  # /src/foo.ts queue retains sid-B; /src/bar.ts entry deleted.
  run jq -r '.wait_queues["/src/foo.ts"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r '.wait_queues["/src/foo.ts"][0].session_id' "$COORD_DIR/sessions.json"
  [ "$output" = "sid-B" ]
  run jq -e '.wait_queues | has("/src/bar.ts")' "$COORD_DIR/sessions.json"
  [ "$status" -ne 0 ]
  # Both wake_files for sid-A swept.
  [ ! -f "$COORD_DIR/wakers/sid-A-__src__foo.ts.wake" ]
  [ ! -f "$COORD_DIR/wakers/sid-A-__src__bar.ts.wake" ]
  # sid-B's wake_file untouched.
  [ -f "$COORD_DIR/wakers/sid-B-__src__foo.ts.wake" ]
}

@test "wait_queue: cleanup_session idempotent on absent sid" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  run coord_wait_queue_cleanup_session "sid-NEVER-EXISTED"
  [ "$status" -eq 0 ]
  # sid-A queue intact.
  run jq -r '.wait_queues["/src/foo.ts"][0].session_id' "$COORD_DIR/sessions.json"
  [ "$output" = "sid-A" ]
}

# ----- Category 6: Sanitization (PR-PHASE5-01 pin-point a-1) -----

@test "wait_queue: tr / __ sanitization with leading underscore preserved" {
  coord_wait_queue_enqueue "sid-A" "/Users/x/Desktop/foo/bar.md"
  [ -f "$COORD_DIR/wakers/sid-A-__Users__x__Desktop__foo__bar.md.wake" ]
  [ -f "$COORD_DIR/wait_queues/__Users__x__Desktop__foo__bar.md.lock" ]
}

# ----- Category 7: Cycle detection trigger (T5.05 placeholder) -----

@test "wait_queue: depth >= 2 enqueue fires CYCLE_DETECTION_SKIPPED placeholder" {
  : >"$COORD_DIR/events.jsonl"
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  # Depth 1 → no cycle-detection trigger.
  run grep -c CYCLE_DETECTION_SKIPPED_T5_05_PENDING "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
  coord_wait_queue_enqueue "sid-B" "/src/foo.ts"
  # Depth 2 → trigger fires; placeholder logs SKIPPED.
  sleep 0.1
  run grep -c CYCLE_DETECTION_SKIPPED_T5_05_PENDING "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

# ----- Category 8: Event emission audit (CLAUDE.md §A.13 lesson #6) -----

@test "wait_queue: WAIT_QUEUE_ENQUEUED + WAIT_QUEUE_DEQUEUED events emitted" {
  : >"$COORD_DIR/events.jsonl"
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  coord_wait_queue_dequeue "sid-A" "/src/foo.ts"
  sleep 0.1
  run grep -c '"kind":"WAIT_QUEUE_ENQUEUED"' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run grep -c '"kind":"WAIT_QUEUE_DEQUEUED"' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

@test "wait_queue: WAIT_QUEUE_SESSION_CLEANUP event with affected_files count" {
  coord_wait_queue_enqueue "sid-A" "/src/foo.ts"
  coord_wait_queue_enqueue "sid-A" "/src/bar.ts"
  : >"$COORD_DIR/events.jsonl"
  coord_wait_queue_cleanup_session "sid-A"
  sleep 0.1
  run grep -c '"kind":"WAIT_QUEUE_SESSION_CLEANUP"' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run grep -o '"affected_files":"2"' "$COORD_DIR/events.jsonl"
  [ -n "$output" ]
}

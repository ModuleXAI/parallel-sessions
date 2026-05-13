#!/usr/bin/env bats
# Tests for stop.sh self-task block-once-then-allow + lib
# stop_block_count helper — Phase 6 T6.07 + PR-PHASE6-02 +
# Decision 2.13 second-half.
#
# Categories:
#   1. Lib helper (increment_stop_block)        (3 tests)
#   2. Hook no-block paths                       (2 tests)
#   3. Hook block-once first-Stop                (3 tests)
#   4. Hook second-Stop allow + archive SKIPPED  (2 tests)
#   5. End-to-end block-once-then-allow flow     (1 test)

load "../helpers/common"

H="$SRC_ROOT/adapters/claude-code/hooks/stop.sh"

setup() {
  TMP="$(mktemp -d -t coord-stop-st-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  : >"$COORD_DIR/events.jsonl"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/self_tasks.sh"

  SID="sid-stop-A"
  PEER="sid-stop-B"
  touch "$COORD_DIR/sessions/${SID}.active" \
        "$COORD_DIR/sessions/${PEER}.active"
  jq --arg s "$SID" --arg p "$PEER" '
    .sessions[$s] = {state:"ACTIVE",pid:1,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0"}
    | .sessions[$p] = {state:"ACTIVE",pid:2,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

_lock_held_by() {
  local file="$1" holder="$2"
  jq --arg f "$file" --arg h "$holder" '
    .locks[$f]={session:$h, acquired_at:"t", last_refresh_at:"t", tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

_run_stop() {
  local input
  input=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"Stop"
  }')
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H'"
}

# ----- Category 1: Lib helper -----

@test "increment_stop_block: 0 → 1 happy path + emits SELF_TASK_STOP_BLOCKED" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  run coord_self_task_increment_stop_block "$SID" "$PID"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run jq -r --arg s "$SID" --arg pid "$PID" \
    '.self_tasks[$s] | map(select(.prompt_id == $pid)) | .[0].stop_block_count' \
    "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_STOP_BLOCKED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "increment_stop_block: 1 → 2 idempotent on subsequent invocation" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  coord_self_task_increment_stop_block "$SID" "$PID" >/dev/null
  run coord_self_task_increment_stop_block "$SID" "$PID"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "increment_stop_block: prompt_id not found → rc 1" {
  coord_self_task_open "$SID" "/p/foo.ts" "fix" >/dev/null
  run coord_self_task_increment_stop_block "$SID" "ghost-prompt-id"
  [ "$status" -eq 1 ]
}

# ----- Category 2: Hook no-block paths -----

@test "stop hook: no self-tasks → no block, allow Stop normally (Phase 2 path)" {
  run _run_stop
  [ "$status" -eq 0 ]
  ! _grep_output_for "Stop blocked"
  ! _grep_output_for '"decision":"block"'
}

@test "stop hook: self-task with file held by peer → no block (peer-held = not unresolved)" {
  coord_self_task_open "$SID" "$TMP/foo.ts" "edit" >/dev/null
  _lock_held_by "$TMP/foo.ts" "$PEER"
  run _run_stop
  [ "$status" -eq 0 ]
  ! _grep_output_for "Stop blocked"
}

# ----- Category 3: Hook block-once first-Stop -----

@test "stop hook: unresolved self-task (count=0) → decision:block + reminder + count→1" {
  PID=$(coord_self_task_open "$SID" "$TMP/foo.ts" "rename")
  run _run_stop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -e '.reason | test("Stop blocked")'
  echo "$output" | jq -e '.reason | test("rename")'
  # Block count incremented.
  run jq -r --arg s "$SID" --arg pid "$PID" \
    '.self_tasks[$s] | map(select(.prompt_id == $pid)) | .[0].stop_block_count' \
    "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
}

@test "stop hook: multi-task unresolved → enumerated reminder + each count→1" {
  P1=$(coord_self_task_open "$SID" "$TMP/a.ts" "first")
  sleep 0.05
  P2=$(coord_self_task_open "$SID" "$TMP/b.ts" "second")
  run _run_stop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -e '.reason | test("first")'
  echo "$output" | jq -e '.reason | test("second")'
  echo "$output" | jq -e '.reason | test("2 unresolved")'
}

@test "stop hook: STOP_HOOK_INVOKED event with decision=block payload" {
  coord_self_task_open "$SID" "$TMP/foo.ts" "fix" >/dev/null
  run _run_stop
  [ "$status" -eq 0 ]
  sleep 0.1
  run grep -c '"kind":"STOP_HOOK_INVOKED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  grep '"kind":"STOP_HOOK_INVOKED"' "$COORD_DIR/events.jsonl" \
    | jq -e '.payload.decision == "block" and (.payload.blocked_count == "1" or .payload.blocked_count == 1)'
}

# ----- Category 4: Hook second-Stop allow + archive SKIPPED -----

@test "stop hook: second Stop (count=1) → allow + archive SKIPPED + SELF_TASK_ARCHIVED event" {
  PID=$(coord_self_task_open "$SID" "$TMP/foo.ts" "edit")
  # Simulate first Stop's effect: increment count to 1.
  coord_self_task_increment_stop_block "$SID" "$PID" >/dev/null
  : >"$COORD_DIR/events.jsonl"  # reset events for clean second-Stop tally
  # Second Stop: should allow + archive.
  run _run_stop
  [ "$status" -eq 0 ]
  ! _grep_output_for "Stop blocked"
  ! _grep_output_for '"decision":"block"'
  # Self-task removed from .self_tasks[<sid>].
  run jq -e --arg s "$SID" '.self_tasks[$s] | length == 0' \
      "$COORD_DIR/sessions.json"
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_ARCHIVED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  grep '"kind":"SELF_TASK_ARCHIVED"' "$COORD_DIR/events.jsonl" \
    | jq -e '.payload.reason == "stop_second_attempt"'
}

@test "stop hook: mixed (one count=0, one count=1) → block on count=0 task only, count=1 stays" {
  P1=$(coord_self_task_open "$SID" "$TMP/a.ts" "first")
  sleep 0.05
  P2=$(coord_self_task_open "$SID" "$TMP/b.ts" "second")
  # Only P1 already blocked once.
  coord_self_task_increment_stop_block "$SID" "$P1" >/dev/null
  : >"$COORD_DIR/events.jsonl"
  run _run_stop
  [ "$status" -eq 0 ]
  # Block fires for P2 (count=0). P1 archived this attempt.
  echo "$output" | jq -e '.decision == "block"'
  echo "$output" | jq -e '.reason | test("second")'
  # P1 archived (gone from self_tasks[]); P2 remains with count=1.
  run jq -e --arg s "$SID" --arg p1 "$P1" --arg p2 "$P2" '
    (.self_tasks[$s] // []) | length == 1
    and (.self_tasks[$s][0].prompt_id == $p2)
    and (.self_tasks[$s][0].stop_block_count == 1)
  ' "$COORD_DIR/sessions.json"
}

# ----- Category 5: End-to-end -----

@test "stop hook e2e: Stop1 blocks, Stop2 allows + archives all SKIPPED" {
  P1=$(coord_self_task_open "$SID" "$TMP/a.ts" "first")
  P2=$(coord_self_task_open "$SID" "$TMP/b.ts" "second")
  # Stop #1 — should block.
  run _run_stop
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
  # Both counts now == 1.
  run jq -e --arg s "$SID" '
    (.self_tasks[$s] | length) == 2
    and all(.self_tasks[$s][]; .stop_block_count == 1)
  ' "$COORD_DIR/sessions.json"
  # Stop #2 — should allow + archive both.
  run _run_stop
  [ "$status" -eq 0 ]
  ! _grep_output_for '"decision":"block"'
  run jq -e --arg s "$SID" '
    (.self_tasks[$s] // []) | length == 0
  ' "$COORD_DIR/sessions.json"
}

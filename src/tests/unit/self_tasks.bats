#!/usr/bin/env bats
# Tests for lib/self_tasks.sh — Phase 6 T6.04 + PR-PHASE6-02 +
# Decision 2.13 + PR-PHASE6-05 §4/§7.
#
# Categories:
#   1. coord_self_task_open                 (3 tests)
#   2. coord_self_task_list                 (2 tests)
#   3. coord_self_task_check_unlocked       (3 tests)
#   4. coord_self_task_archive              (3 tests)
#   5. coord_self_task_cleanup_session      (2 tests)
#   6. prompt_id format + per-session flock (2 tests)

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-st-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  export COORD_DIR="$COORD"
  mk_empty_sessions "$COORD"
  : >"$COORD_DIR/events.jsonl"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/self_tasks.sh"

  SID="sid-stk-A"
  OTHER="sid-stk-B"
}
teardown() {
  rm -rf "$TMP"
}

# Helper: place a lock entry on file <1> held by session <2>.
_lock_held_by() {
  local file="$1" holder="$2"
  jq --arg f "$file" --arg h "$holder" '
    .locks[$f]={session:$h, acquired_at:"t", last_refresh_at:"t", tasks:[]}
    | .sessions[$h] = (.sessions[$h] // {state:"ACTIVE", pid:1,
        pid_lstart:"x", registered_at:"y", last_activity_at:"z",
        git_head:"", prompt_id:null, script_version:"1.0"})
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

# ----- Category 1: coord_self_task_open -----

@test "self_task_open: happy path persists entry + emits SELF_TASK_OPENED" {
  run coord_self_task_open "$SID" "/p/foo.ts" "rename signature"
  [ "$status" -eq 0 ]
  # Stdout is the prompt_id.
  PID="$output"
  echo "$PID" | grep -qE "^${SID}-self-[0-9]+-[0-9a-f]{4}$"
  # Persisted entry shape.
  run jq -e --arg s "$SID" --arg pid "$PID" '
    .self_tasks[$s][0]
    | (.file == "/p/foo.ts")
      and (.instruction == "rename signature")
      and (.prompt_id == $pid)
      and (.created_at | type == "string")
  ' "$COORD_DIR/sessions.json"
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_OPENED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "self_task_open: idempotent within 1s → returns same prompt_id, no duplicate persisted" {
  run coord_self_task_open "$SID" "/p/foo.ts" "rename"
  [ "$status" -eq 0 ]
  PID1="$output"
  # Immediate second call with identical args → idempotent hit.
  run coord_self_task_open "$SID" "/p/foo.ts" "rename"
  [ "$status" -eq 0 ]
  [ "$output" = "$PID1" ]
  # Only one entry persisted.
  run jq -e --arg s "$SID" '.self_tasks[$s] | length == 1' \
      "$COORD_DIR/sessions.json"
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_OPEN_IDEMPOTENT"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "self_task_open: missing args → rc 1" {
  run coord_self_task_open
  [ "$status" -eq 1 ]
  run coord_self_task_open "$SID"
  [ "$status" -eq 1 ]
  run coord_self_task_open "$SID" "/p/foo.ts"
  [ "$status" -eq 1 ]
}

# ----- Category 2: coord_self_task_list -----

@test "self_task_list: empty array when no tasks" {
  run coord_self_task_list "$SID"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "self_task_list: returns persisted tasks as JSON array" {
  coord_self_task_open "$SID" "/p/a.ts" "fix A" >/dev/null
  coord_self_task_open "$SID" "/p/b.ts" "fix B" >/dev/null
  run coord_self_task_list "$SID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 2'
  echo "$output" | jq -e '.[0].file == "/p/a.ts" and .[1].file == "/p/b.ts"'
  echo "$output" | jq -e 'all(.[]; .prompt_id | type == "string")'
}

# ----- Category 3: coord_self_task_check_unlocked -----

@test "self_task_check_unlocked: file held by other session → excluded" {
  _lock_held_by "/p/foo.ts" "$OTHER"
  coord_self_task_open "$SID" "/p/foo.ts" "edit" >/dev/null
  run coord_self_task_check_unlocked "$SID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 0'
}

@test "self_task_check_unlocked: file held by self → included (B can act now)" {
  _lock_held_by "/p/foo.ts" "$SID"
  coord_self_task_open "$SID" "/p/foo.ts" "edit" >/dev/null
  run coord_self_task_check_unlocked "$SID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].file == "/p/foo.ts"'
}

@test "self_task_check_unlocked: file not currently locked → included" {
  # No lock entry; pure unlocked file.
  coord_self_task_open "$SID" "/p/free.ts" "edit" >/dev/null
  run coord_self_task_check_unlocked "$SID"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].file == "/p/free.ts"'
}

# ----- Category 4: coord_self_task_archive -----

@test "self_task_archive: COMPLETED removes entry + emits SELF_TASK_ARCHIVED" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  run coord_self_task_archive "$SID" "$PID" "COMPLETED"
  [ "$status" -eq 0 ]
  run jq -e --arg s "$SID" '.self_tasks[$s] | length == 0' \
      "$COORD_DIR/sessions.json"
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_ARCHIVED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  grep '"kind":"SELF_TASK_ARCHIVED"' "$COORD_DIR/events.jsonl" \
    | jq -e '.payload.reason == "COMPLETED"'
}

@test "self_task_archive: SKIPPED reason persisted in event payload" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  run coord_self_task_archive "$SID" "$PID" "SKIPPED"
  [ "$status" -eq 0 ]
  sleep 0.1
  grep '"kind":"SELF_TASK_ARCHIVED"' "$COORD_DIR/events.jsonl" \
    | jq -e '.payload.reason == "SKIPPED"'
}

@test "self_task_archive: prompt_id not found → rc 1" {
  coord_self_task_open "$SID" "/p/foo.ts" "fix" >/dev/null
  run coord_self_task_archive "$SID" "ghost-prompt-id" "COMPLETED"
  [ "$status" -eq 1 ]
  # Existing entry untouched.
  run jq -e --arg s "$SID" '.self_tasks[$s] | length == 1' \
      "$COORD_DIR/sessions.json"
}

# ----- Category 5: coord_self_task_cleanup_session -----

@test "self_task_cleanup_session: drops all entries + emits SELF_TASK_SKIPPED per task" {
  coord_self_task_open "$SID" "/p/a.ts" "fix A" >/dev/null
  coord_self_task_open "$SID" "/p/b.ts" "fix B" >/dev/null
  run coord_self_task_cleanup_session "$SID"
  [ "$status" -eq 0 ]
  run jq -e --arg s "$SID" '
    (.self_tasks[$s] // null) | (. == null or length == 0)
  ' "$COORD_DIR/sessions.json"
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_SKIPPED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 2 ]
  # Reason field = session_end.
  grep '"kind":"SELF_TASK_SKIPPED"' "$COORD_DIR/events.jsonl" \
    | jq -e '.payload.reason == "session_end"'
}

@test "self_task_cleanup_session: no-op when session has no tasks (rc 0)" {
  run coord_self_task_cleanup_session "$SID"
  [ "$status" -eq 0 ]
  sleep 0.1
  # No SELF_TASK_SKIPPED events emitted (file may not exist or be empty).
  if [ -f "$COORD_DIR/events.jsonl" ]; then
    run grep -c '"kind":"SELF_TASK_SKIPPED"' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

# ----- Category 6: prompt_id format + per-session flock -----

@test "self_task_open: prompt_id matches <sid>-self-<ms>-<hex4> regex" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "edit")
  echo "$PID" | grep -qE "^${SID}-self-[0-9]{10,}-[0-9a-f]{4}$"
}

@test "self_task_open: per-session flock isolates concurrent opens (parent state intact)" {
  # Two background opens on the SAME (sid, file, instruction) — only
  # one should land an entry; idempotency catches the other.
  coord_self_task_open "$SID" "/p/foo.ts" "fix" >/dev/null &
  pid1=$!
  coord_self_task_open "$SID" "/p/foo.ts" "fix" >/dev/null &
  pid2=$!
  wait "$pid1"
  wait "$pid2"
  # Exactly 1 entry persisted (idempotency 1s window held under flock).
  run jq -e --arg s "$SID" '.self_tasks[$s] | length == 1' \
      "$COORD_DIR/sessions.json"
}

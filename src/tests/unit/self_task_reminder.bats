#!/usr/bin/env bats
# Tests for pre_tool_use_any.sh self-task reminder injection +
# lib/self_tasks.sh reminder throttling helpers — Phase 6 T6.06.
#
# Categories:
#   1. Lib reminder throttle helpers           (4 tests)
#   2. Hook reminder injection (no reminders) (2 tests)
#   3. Hook reminder injection (with tasks)   (4 tests)

load "../helpers/common"

H="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_any.sh"

setup() {
  TMP="$(mktemp -d -t coord-stk-rem-XXXX)"
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

  SID="sid-rem-A"
  PEER="sid-rem-B"
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

# Run pre_tool_use_any.sh hook with given JSON input.
_run_hook() {
  local input="$1"
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H'"
}

# ----- Category 1: Lib reminder throttle helpers -----

@test "check_reminder_due: prompt_id not found → rc 2" {
  run coord_self_task_check_reminder_due "$SID" "ghost-prompt-id"
  [ "$status" -eq 2 ]
}

@test "check_reminder_due: null last_reminded_at → rc 0 (due)" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  run coord_self_task_check_reminder_due "$SID" "$PID"
  [ "$status" -eq 0 ]
}

@test "check_reminder_due: last_reminded_at within 5min → rc 1 (not due)" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  coord_self_task_record_reminder "$SID" "$PID"
  run coord_self_task_check_reminder_due "$SID" "$PID"
  [ "$status" -eq 1 ]
}

@test "check_reminder_due: last_reminded_at older than 5min → rc 0 (due)" {
  PID=$(coord_self_task_open "$SID" "/p/foo.ts" "fix")
  # Backdate last_reminded_at to 6 minutes ago via direct jq edit.
  OLD_ISO=$(perl -MTime::HiRes -e 'use POSIX qw(strftime); my $t=time-360; print strftime("%Y-%m-%dT%H:%M:%S",gmtime($t)),".000Z"')
  jq --arg s "$SID" --arg pid "$PID" --arg ts "$OLD_ISO" '
    .self_tasks[$s] |= map(
      if .prompt_id == $pid then .last_reminded_at = $ts else . end
    )
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  run coord_self_task_check_reminder_due "$SID" "$PID"
  [ "$status" -eq 0 ]
}

# ----- Category 2: Hook with no reminders -----

@test "hook reminder: no self-tasks → no reminder in additionalContext" {
  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/x.txt"}}'
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  ! _grep_output_for "self-task pending"
}

@test "hook reminder: self-task with file held by peer → no reminder (peer-held)" {
  coord_self_task_open "$SID" "$TMP/foo.ts" "fix" >/dev/null
  _lock_held_by "$TMP/foo.ts" "$PEER"
  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/x.txt"}}'
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  ! _grep_output_for "self-task pending"
}

# ----- Category 3: Hook with reminders -----

@test "hook reminder: unlocked self-task → reminder injected in additionalContext" {
  coord_self_task_open "$SID" "$TMP/foo.ts" "rename signature" >/dev/null
  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/x.txt"}}'
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  _grep_output_for "self-task pending"
  _grep_output_for "rename signature"
  _grep_output_for "is now free"
}

@test "hook reminder: multi-task chronological order (oldest first)" {
  coord_self_task_open "$SID" "$TMP/a.ts" "first" >/dev/null
  sleep 0.05
  coord_self_task_open "$SID" "$TMP/b.ts" "second" >/dev/null
  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/x.txt"}}'
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  # additionalContext is JSON; extract the field and check ordering.
  CTX=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')
  POS_FIRST=$(printf '%s' "$CTX" | grep -bo "first" | head -1 | cut -d: -f1)
  POS_SECOND=$(printf '%s' "$CTX" | grep -bo "second" | head -1 | cut -d: -f1)
  [ -n "$POS_FIRST" ]
  [ -n "$POS_SECOND" ]
  [ "$POS_FIRST" -lt "$POS_SECOND" ]
}

@test "hook reminder: throttle gate suppresses re-injection within 5min" {
  PID=$(coord_self_task_open "$SID" "$TMP/foo.ts" "edit")
  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/x.txt"}}'
  # First call → injects reminder.
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  _grep_output_for "self-task pending"
  # Second call (immediate; <5min) → suppressed by throttle.
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  ! _grep_output_for "self-task pending"
}

@test "hook reminder: SELF_TASK_REMINDER event emitted with prompt_id payload" {
  PID=$(coord_self_task_open "$SID" "$TMP/foo.ts" "fix")
  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP"'/x.txt"}}'
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_REMINDER"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  grep '"kind":"SELF_TASK_REMINDER"' "$COORD_DIR/events.jsonl" \
    | jq -e --arg pid "$PID" '.payload.prompt_id == $pid'
}

#!/usr/bin/env bats
# Tests for hooks/post_tool_use_write.sh (Phase 2 lock release).
# Companion to pre_tool_use_write.bats — pre acquires, post releases.
# This hook MUST NEVER set permissionDecision in any code path
# (the Phase 2 invariant tests assert this).

load "../helpers/common"

H="$SRC_ROOT/hooks/post_tool_use_write.sh"
HW="$SRC_ROOT/hooks/pre_tool_use_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-postw-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  SID="sid-postw-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET="$TMP/target.txt"
  printf 'target v1\n' >"$TARGET"

  WRITE_TARGET='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  POST_TARGET='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  POST_SUB='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"},"agent_type":"general-purpose"}'
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

# Acquire a lock on $TARGET via the pre-hook so post-hook has something to release.
_acquire_lock() {
  CLAUDE_COORD=1 bash -c "echo '$WRITE_TARGET' | '$HW'" >/dev/null
}

@test "post_tool_use_write: CLAUDE_COORD unset → exit 0, no output, no state change" {
  _acquire_lock
  run bash -c "echo '$POST_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # Lock still present (post-hook was a no-op).
  run jq -r --arg f "$TARGET" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "post_tool_use_write: subagent → SUBAGENT_ACTIVITY_SKIPPED, no release" {
  _acquire_lock
  CLAUDE_COORD=1 run bash -c "echo '$POST_SUB' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # Lock untouched.
  run jq -r --arg f "$TARGET" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
}

@test "post_tool_use_write: lock held by self → release + LOCK_RELEASED event" {
  _acquire_lock
  # Confirm lock present.
  run jq -r --arg f "$TARGET" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]

  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # No permissionDecision (post hook never denies).
  case "$output" in *permissionDecision*) echo "FAIL: $output"; return 1 ;; esac

  # Lock entry deleted.
  run jq -r --arg f "$TARGET" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  # LOCK_RELEASED event emitted.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs 'last(.[] | select(.kind == "LOCK_RELEASED")) | .file' "$COORD_DIR/events.jsonl"
  [ "$output" = "$TARGET" ]
}

@test "post_tool_use_write: lock held by another session → ERROR log + DO NOT release" {
  OTHER="sid-other-3333"
  jq --arg f "$TARGET" --arg sid "$OTHER" '
    .locks[$f] = {session:$sid, acquired_at:"t", last_refresh_at:"t", tasks:[]}
    | .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  touch "$COORD_DIR/sessions/${OTHER}.active"

  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # Lock STILL belongs to OTHER.
  run jq -r --arg f "$TARGET" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$OTHER" ]
  # An ERROR event with reason=lock_held_by_other was logged.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "ERROR" and .payload.reason == "lock_held_by_other")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "post_tool_use_write: no lock present → silent no-op" {
  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "post_tool_use_write: non-participant session → no-op" {
  local OTHER='{"session_id":"not-registered","cwd":"'"$TMP"'","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  _acquire_lock
  CLAUDE_COORD=1 run bash -c "echo '$OTHER' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # Original lock by SID untouched.
  run jq -r --arg f "$TARGET" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "post_tool_use_write (Phase 2 T2.02): notification populated for prior denied waiter" {
  # Acquire on $TARGET as $SID.
  _acquire_lock
  # Pre-seed a LOCK_DENIED event for OTHER on $TARGET, dated AFTER our
  # acquired_at. Mirrors what pre_tool_use_write would have written if
  # OTHER had attempted while SID held the lock.
  acq=$(jq -r --arg f "$TARGET" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json")
  OTHER="sid-postw-waiter"
  touch "$COORD_DIR/sessions/${OTHER}.active"
  jq --arg sid "$OTHER" '.sessions[$sid] = {state:"ACTIVE",pid:9,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  # Append a fake LOCK_DENIED event whose ts falls inside [acquired_at, now).
  # Reusing acquired_at exactly satisfies both bounds and is timezone-stable.
  printf '{"ts":"%s","session":"%s","kind":"LOCK_DENIED","tool":"Edit","file":"%s","payload":{"holder":"%s","acquired_at":"%s"}}\n' \
    "$acq" "$OTHER" "$TARGET" "$SID" "$acq" >>"$COORD_DIR/events.jsonl"

  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  sleep 0.3
  # notifications[OTHER][TARGET] populated with one entry.
  run jq -r --arg b "$OTHER" --arg f "$TARGET" '.notifications[$b][$f] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  # Action-hint format: "Lock released on <path> (held by <prefix>... for N sec).
  # You may now retry your write or `coord wait <path>` if you've moved on."
  run jq -r --arg b "$OTHER" --arg f "$TARGET" '.notifications[$b][$f][0]' "$COORD_DIR/sessions.json"
  echo "$output" | grep -q "Lock released on"
  echo "$output" | grep -qE "held by ${SID:0:8}\\.\\.\\."
  echo "$output" | grep -q "You may now retry your write"
  echo "$output" | grep -q "coord wait $TARGET"
  # NOTIFICATION_PRODUCED event emitted.
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_PRODUCED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

@test "post_tool_use_write (Phase 2 T2.02): no waiters during hold → no notifications populated" {
  _acquire_lock
  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -r '.notifications | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_PRODUCED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "post_tool_use_write: ship gate — never sets permissionDecision in any branch" {
  # Branch 1: own lock → release.
  _acquire_lock
  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac

  # Branch 2: no lock present → no-op.
  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac

  # Branch 3: lock held by other.
  OTHER="sid-other-4444"
  jq --arg f "$TARGET" --arg sid "$OTHER" '.locks[$f] = {session:$sid, acquired_at:"t", last_refresh_at:"t", tasks:[]}' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  touch "$COORD_DIR/sessions/${OTHER}.active"
  jq --arg sid "$OTHER" '.sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  CLAUDE_COORD=1 run bash -c "echo '$POST_TARGET' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  true
}

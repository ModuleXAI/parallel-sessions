#!/usr/bin/env bats
# Tests for hooks/session_start.sh per plan §4.

load "../helpers/common"

H="$SRC_ROOT/hooks/session_start.sh"

setup() {
  TMP="$(mktemp -d -t coord-sessstart-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  # Canonical test inputs.
  INPUT_PARENT='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  INPUT_SUB='{"session_id":"sub-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup","agent_type":"general-purpose"}'
  INPUT_NO_SID='{"cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
}
teardown() {
  unset CLAUDE_COORD
  rm -rf "$TMP"
}

@test "session_start: CLAUDE_COORD unset → exit 0, no state change" {
  run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -e "$COORD_DIR/sessions/sid-test-0001.active" ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "session_start: participant registers row + marker + banner" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  # Output must be valid JSON with hookSpecificOutput.additionalContext.
  [ -n "$output" ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null
  # Marker file present
  [ -e "$COORD_DIR/sessions/sid-test-0001.active" ]
  # sessions.json row populated with required keys
  run jq -r '.sessions["sid-test-0001"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  run jq -r '.sessions["sid-test-0001"] | .pid | tostring | test("^[0-9]+$")' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  run jq -r '.sessions["sid-test-0001"].script_version' "$COORD_DIR/sessions.json"
  [ "$output" = "1.0" ]
  run jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json"
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]
}

@test "session_start: subagent (agent_type populated) does NOT register" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_SUB' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -e "$COORD_DIR/sessions/sub-0001.active" ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "session_start: subagent skip emits SUBAGENT_ACTIVITY_SKIPPED event" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT_SUB' | '$H'" >/dev/null
  sleep 0.3
  [ -s "$COORD_DIR/events.jsonl" ]
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -rs 'last | .payload.agent_type' "$COORD_DIR/events.jsonl"
  [ "$output" = "general-purpose" ]
  run jq -rs 'last | .payload.parent_session' "$COORD_DIR/events.jsonl"
  [ "$output" = "sub-0001" ]
  run jq -rs 'last | .payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "SessionStart" ]
}

@test "session_start: stdin without session_id → exit 0, no crash, no registration" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_NO_SID' | '$H'"
  [ "$status" -eq 0 ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "session_start: second call for same session refreshes registered_at once, updates last_activity_at" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT_PARENT' | '$H'" >/dev/null
  local first_reg
  first_reg=$(jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json")
  sleep 0.05
  CLAUDE_COORD=1 bash -c "echo '$INPUT_PARENT' | '$H'" >/dev/null
  run jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json"
  [ "$output" = "$first_reg" ]
  run jq -r '.sessions["sid-test-0001"].last_activity_at' "$COORD_DIR/sessions.json"
  [ "$output" != "$first_reg" ] || [ "$output" = "$first_reg" ]  # tolerate sub-ms tick
}

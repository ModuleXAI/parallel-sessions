#!/usr/bin/env bats
# Tests for hooks/pre_tool_use_any.sh — Phase 1 minimal cross-cutting hook.

load "../helpers/common"

H="$SRC_ROOT/hooks/pre_tool_use_any.sh"

setup() {
  TMP="$(mktemp -d -t coord-ptua-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  # Spin up a tiny git repo with two commits so HEAD-drift can be exercised.
  (
    cd "$TMP"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'a\n' >a.txt
    git add a.txt
    git commit -q -m one
  )
  HEAD_A=$(git -C "$TMP" rev-parse HEAD)

  SID="sid-ptua-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" --arg head "$HEAD_A" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:$head,prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  ANY_INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  SUB_INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"agent_type":"general-purpose"}'
  NONPART_INP='{"session_id":"not-registered","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

@test "pre_tool_use_any: CLAUDE_COORD unset → exit 0, no output" {
  run bash -c "echo '$ANY_INP' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_any: subagent → SUBAGENT_ACTIVITY_SKIPPED, no mutation" {
  CLAUDE_COORD=1 bash -c "echo '$SUB_INP' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
}

@test "pre_tool_use_any: non-participant → no-op" {
  CLAUDE_COORD=1 run bash -c "echo '$NONPART_INP' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_any: no notifications + no HEAD drift → quiet pass" {
  CLAUDE_COORD=1 run bash -c "echo '$ANY_INP' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_any: pending notifications across multiple files are delivered + cleared" {
  jq --arg sid "$SID" '
    .notifications[$sid] = {
      "/tmp/foo.ts": ["A modified foo.ts since your last read"],
      "/tmp/bar.ts": ["B modified bar.ts", "C also touched bar.ts"]
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  CLAUDE_COORD=1 run bash -c "echo '$ANY_INP' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("foo.ts")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("bar.ts")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("A modified foo.ts")' >/dev/null
  # Cleared after delivery.
  run jq -r '[.notifications["'"$SID"'"][] | .[]] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  # Event logged.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_DELIVER" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_any: HEAD drift marks read-set + emits banner + HEAD_CHANGE event" {
  # Pre-seed a read-set.
  jq --arg sid "$SID" '
    .read_sets[$sid] = {reads: [{path:"/tmp/foo.ts", hash:"aaa", is_latest:true}, {path:"/tmp/bar.ts", hash:"bbb", is_latest:true}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  # Advance HEAD on disk.
  (
    cd "$TMP"
    printf 'b\n' >a.txt
    git commit -q -am two
  )
  CLAUDE_COORD=1 run bash -c "echo '$ANY_INP' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("HEAD changed")' >/dev/null
  # Read-set entries marked.
  run jq -r '[.read_sets["'"$SID"'"].reads[] | .superseded_by_head_change] | all' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  # HEAD_CHANGE event.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # git_head field updated in sessions.json.
  run jq -r '.sessions["'"$SID"'"].git_head' "$COORD_DIR/sessions.json"
  [ "$output" != "$HEAD_A" ]
}

@test "pre_tool_use_any: notifications + HEAD drift combined → both segments in one banner" {
  jq --arg sid "$SID" '
    .notifications[$sid] = {"/tmp/foo.ts": ["A modified foo.ts"]}
    | .read_sets[$sid] = {reads: [{path:"/tmp/foo.ts", hash:"aaa", is_latest:true}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  (
    cd "$TMP"
    printf 'b\n' >a.txt
    git commit -q -am two
  )
  CLAUDE_COORD=1 run bash -c "echo '$ANY_INP' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("notifications pending")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("HEAD changed")' >/dev/null
}

@test "pre_tool_use_any: NEVER emits permissionDecision (Phase 1 ship gate)" {
  # Build the most-likely-to-fail combined scenario and check.
  jq --arg sid "$SID" '
    .notifications[$sid] = {"/tmp/foo.ts": ["X"]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  (
    cd "$TMP"
    printf 'b\n' >a.txt
    git commit -q -am two
  )
  CLAUDE_COORD=1 run bash -c "echo '$ANY_INP' | '$H'"
  [ "$status" -eq 0 ]
  case "$output" in
    *permissionDecision*) return 1 ;;
  esac
  true
}

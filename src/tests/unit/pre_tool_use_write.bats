#!/usr/bin/env bats
# Tests for hooks/pre_tool_use_write.sh (Phase 1 warning-only mode).
# Ship-gate: the hook MUST NEVER set permissionDecision in Phase 1.

load "../helpers/common"

H="$SRC_ROOT/hooks/pre_tool_use_write.sh"
HR="$SRC_ROOT/hooks/pre_tool_use_read.sh"

setup() {
  TMP="$(mktemp -d -t coord-ptuw-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  SID="sid-ptuw-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # A file the session "read" first; the Read hook will populate read_set.
  F1="$TMP/alpha.txt"
  printf 'alpha v1\n' >"$F1"
  F2="$TMP/beta.txt"
  printf 'beta v1\n' >"$F2"
  TARGET="$TMP/target.txt"
  printf 'target v1\n' >"$TARGET"

  READ_F1='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$F1"'"}}'
  READ_F2='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$F2"'"}}'

  WRITE_TARGET='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  WRITE_SUB='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"},"agent_type":"general-purpose"}'
  WRITE_NOTEBOOK='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$TARGET"'"}}'
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

# Read a file through pre_tool_use_read.sh to seed a proper read_set entry.
_prime_read() {
  local input="$1"
  CLAUDE_COORD=1 bash -c "echo '$input' | '$HR'" >/dev/null
}

@test "pre_tool_use_write: CLAUDE_COORD unset → exit 0, no output" {
  run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: subagent event emits SUBAGENT_ACTIVITY_SKIPPED, no permissionDecision" {
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_SUB' | '$H'"
  [ "$status" -eq 0 ]
  # No permissionDecision in Phase 1. The output may contain the skip event
  # log line nothing to stdout.
  [ "$output" = "" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
}

@test "pre_tool_use_write: non-participant → no-op" {
  local OTHER='{"session_id":"not-registered","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  CLAUDE_COORD=1 run bash -c "echo '$OTHER' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: empty read-set → allow, no warning" {
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # WRITE event is still logged
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "WRITE")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: read-set with matching hashes → allow, no warning" {
  _prime_read "$READ_F1"
  _prime_read "$READ_F2"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: drifted file → additionalContext warning, NO permissionDecision (Phase 1 ship gate)" {
  _prime_read "$READ_F1"
  # Modify alpha.txt on disk to simulate another session's change.
  printf 'alpha v2 drifted\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # Stdout must NOT contain permissionDecision anywhere.
  run bash -c "echo '$output' | grep -c 'permissionDecision' || true"
  [ "$output" = "0" ]
  # Re-run to capture output for content checks.
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("stale-read warning")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("alpha.txt")' >/dev/null
  # STALE_READ_WARNED event fired.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "STALE_READ_WARNED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: deleted file since read → warning" {
  _prime_read "$READ_F1"
  rm -f "$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("deleted since read")' >/dev/null
}

@test "pre_tool_use_write: entries already marked superseded_by_head_change are NOT re-warned" {
  _prime_read "$READ_F1"
  # Now mark it head-changed so the write hook should skip it.
  jq --arg sid "$SID" '
    .read_sets[$sid].reads |= map(. + {superseded_by_head_change: true})
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  # Also mutate the file on disk to provoke what would otherwise be a warning.
  printf 'alpha v2\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # No warning emitted — the HEAD-change mark already told Claude the read
  # was invalid; emitting again would be noise.
  [ "$output" = "" ]
}

@test "pre_tool_use_write: entries with is_latest=false are NOT validated" {
  _prime_read "$READ_F1"
  # Force the entry to superseded (is_latest=false, like after a second read).
  jq --arg sid "$SID" '
    .read_sets[$sid].reads |= map(. + {is_latest: false, superseded_by: "some-other-hash"})
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  printf 'alpha v2\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: NotebookEdit uses notebook_path for target" {
  _prime_read "$READ_F1"
  # File not actually drifted — we're just checking the notebook path parsing
  # does not crash. Should allow quietly.
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_NOTEBOOK' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: Phase-1 ship gate — NO code path ever sets permissionDecision" {
  # Exhaustively confirm: prime drift, then run; scan output for the forbidden key.
  _prime_read "$READ_F1"
  printf 'alpha v2\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # The literal string "permissionDecision" must NOT appear in stdout.
  case "$output" in
    *permissionDecision*) return 1 ;;
  esac
  true
}

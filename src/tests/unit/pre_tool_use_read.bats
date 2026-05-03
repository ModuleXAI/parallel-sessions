#!/usr/bin/env bats
# Tests for hooks/pre_tool_use_read.sh per plan §4 + CLAUDE.md §B.1.

load "../helpers/common"

H="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_read.sh"

setup() {
  TMP="$(mktemp -d -t coord-ptur-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  SID="sid-ptur-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # Target file to be "read".
  F1="$TMP/alpha.txt"
  printf 'alpha contents v1\n' >"$F1"
  HASH_F1=$(shasum -a 256 "$F1" | awk '{print $1}')
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

_inp() {
  # _inp <session_id> <file_path> [agent_type]
  local sid="$1" path="$2" at="${3:-}"
  if [ -n "$at" ]; then
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"},"agent_type":"%s"}' "$sid" "$TMP" "$path" "$at"
  else
    printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"}}' "$sid" "$TMP" "$path"
  fi
}

@test "pre_tool_use_read: CLAUDE_COORD unset → exit 0, no state change" {
  run bash -c "echo '$(_inp "$SID" "$F1")' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run jq -r '[.read_sets["'"$SID"'"].reads[]?] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "pre_tool_use_read: subagent event emits SUBAGENT_ACTIVITY_SKIPPED + no read_set mutation" {
  CLAUDE_COORD=1 bash -c "echo '$(_inp "$SID" "$F1" "general-purpose")' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -r '[.read_sets["'"$SID"'"].reads[]?] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "pre_tool_use_read: non-participant → no-op" {
  local OTHER='{"session_id":"not-registered","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$F1"'"}}'
  CLAUDE_COORD=1 run bash -c "echo '$OTHER' | '$H'"
  [ "$status" -eq 0 ]
  run jq -r '[.read_sets["not-registered"].reads[]?] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "pre_tool_use_read: participant first read records the entry with sha256" {
  CLAUDE_COORD=1 run bash -c "echo '$(_inp "$SID" "$F1")' | '$H'"
  [ "$status" -eq 0 ]
  run jq -r '[.read_sets["'"$SID"'"].reads[]] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r '.read_sets["'"$SID"'"].reads[0].path' "$COORD_DIR/sessions.json"
  [ "$output" = "$F1" ]
  run jq -r '.read_sets["'"$SID"'"].reads[0].hash' "$COORD_DIR/sessions.json"
  [ "$output" = "$HASH_F1" ]
  run jq -r '.read_sets["'"$SID"'"].reads[0].is_latest' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
}

@test "pre_tool_use_read: second read of same path supersedes the first entry" {
  CLAUDE_COORD=1 bash -c "echo '$(_inp "$SID" "$F1")' | '$H'" >/dev/null
  # Mutate the file; compute new hash; read again.
  printf 'alpha contents v2 (different bytes)\n' >"$F1"
  local HASH_F1_V2
  HASH_F1_V2=$(shasum -a 256 "$F1" | awk '{print $1}')
  CLAUDE_COORD=1 bash -c "echo '$(_inp "$SID" "$F1")' | '$H'" >/dev/null
  # Two entries now: the old one superseded, the new one is_latest.
  run jq -r '[.read_sets["'"$SID"'"].reads[]] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "2" ]
  run jq -r '.read_sets["'"$SID"'"].reads[0].is_latest' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
  run jq -r '.read_sets["'"$SID"'"].reads[0].superseded_by' "$COORD_DIR/sessions.json"
  [ "$output" = "$HASH_F1_V2" ]
  run jq -r '.read_sets["'"$SID"'"].reads[1].is_latest' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
}

@test "pre_tool_use_read: reading different files keeps both entries is_latest" {
  local F2="$TMP/beta.txt"
  printf 'beta v1\n' >"$F2"
  CLAUDE_COORD=1 bash -c "echo '$(_inp "$SID" "$F1")' | '$H'" >/dev/null
  CLAUDE_COORD=1 bash -c "echo '$(_inp "$SID" "$F2")' | '$H'" >/dev/null
  run jq -r '[.read_sets["'"$SID"'"].reads[] | select(.is_latest == true)] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "2" ]
}

@test "pre_tool_use_read: missing file → log ERROR, allow (exit 0, no deny)" {
  local GHOST="$TMP/does-not-exist.txt"
  CLAUDE_COORD=1 run bash -c "echo '$(_inp "$SID" "$GHOST")' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]   # no permissionDecision; Phase 1 never denies
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "ERROR" and .payload.source == "pre_tool_use_read")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_read: large file records SKIPPED_LARGE as hash" {
  local BIG="$TMP/big.bin"
  # 1 byte over a small cap.
  dd if=/dev/zero of="$BIG" bs=1024 count=11 >/dev/null 2>&1
  COORD_HASH_SIZE_CAP_BYTES=10240 CLAUDE_COORD=1 \
    bash -c "export COORD_HASH_SIZE_CAP_BYTES=10240; echo '$(_inp "$SID" "$BIG")' | '$H'" >/dev/null
  run jq -r '.read_sets["'"$SID"'"].reads[0].hash' "$COORD_DIR/sessions.json"
  [ "$output" = "SKIPPED_LARGE" ]
}

@test "pre_tool_use_read: delivers pending notifications + clears them on read" {
  # Seed a notification for this session+file.
  jq --arg sid "$SID" --arg path "$F1" '
    .notifications[$sid] = ((.notifications[$sid] // {}) | .[$path] = ["File modified by sid-other since your last read"])
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  CLAUDE_COORD=1 run bash -c "echo '$(_inp "$SID" "$F1")' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("modified by sid-other")' >/dev/null
  # Notification consumed (array cleared).
  run jq -r '.notifications["'"$SID"'"]["'"$F1"'"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "pre_tool_use_read: READ event logged with file + hash fields" {
  CLAUDE_COORD=1 bash -c "echo '$(_inp "$SID" "$F1")' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs '[.[] | select(.kind == "READ")][0].file' "$COORD_DIR/events.jsonl"
  [ "$output" = "$F1" ]
  run jq -rs '[.[] | select(.kind == "READ")][0].hash' "$COORD_DIR/events.jsonl"
  [ "$output" = "$HASH_F1" ]
}

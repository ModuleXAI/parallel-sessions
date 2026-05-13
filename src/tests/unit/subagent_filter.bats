#!/usr/bin/env bats
# Tests for lib/subagent_filter.sh per plan §4 + Decision 2.17 +
# PR-PHASE0-01 G (SUBAGENT_ACTIVITY_SKIPPED observability commitment).

load "../helpers/common"

F="$SRC_ROOT/adapters/claude-code/lib/subagent_filter.sh"

setup() {
  TMP="$(mktemp -d -t coord-subfilter-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  export SESSION_ID="parent-sid-0001"
}

teardown() {
  unset COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# Helper: source the library inside a subshell so side effects don't leak.
_call() {
  # _call "<hook_name>" "<input_json>"
  bash -c "
    . '$SRC_ROOT/core/lib/log_event.sh'
    . '$F'
    coord_subagent_filter \"\$1\" \"\$2\"
  " _ "$1" "$2"
}

@test "subagent_filter: empty input_json → returns 1 (non-subagent)" {
  run _call "PreToolUse" ""
  [ "$status" -eq 1 ]
}

@test "subagent_filter: agent_type absent → returns 1 (non-subagent)" {
  run _call "PreToolUse" '{"session_id":"sid-a","tool_name":"Read"}'
  [ "$status" -eq 1 ]
}

@test "subagent_filter: agent_type empty string → returns 1 (non-subagent)" {
  run _call "PreToolUse" '{"session_id":"sid-a","agent_type":"","tool_name":"Read"}'
  [ "$status" -eq 1 ]
}

@test "subagent_filter: non-subagent path emits no event" {
  _call "PreToolUse" '{"session_id":"sid-a","tool_name":"Read"}' || true
  sleep 0.3
  # events.jsonl should be empty or absent.
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run grep -c SUBAGENT_ACTIVITY_SKIPPED "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "subagent_filter: agent_type populated → returns 0 (subagent)" {
  run _call "PreToolUse" '{"session_id":"sid-a","agent_type":"general-purpose","tool_name":"Read","tool_input":{"file_path":"/tmp/foo.ts"}}'
  [ "$status" -eq 0 ]
}

@test "subagent_filter: subagent emits SUBAGENT_ACTIVITY_SKIPPED with full payload" {
  _call "PreToolUse" '{"session_id":"parent-xyz","agent_type":"general-purpose","tool_name":"Read","tool_input":{"file_path":"/tmp/foo.ts"}}'
  sleep 0.3
  [ -s "$COORD_DIR/events.jsonl" ]
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -rs 'last | .payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "PreToolUse" ]
  run jq -rs 'last | .payload.agent_type' "$COORD_DIR/events.jsonl"
  [ "$output" = "general-purpose" ]
  run jq -rs 'last | .payload.parent_session' "$COORD_DIR/events.jsonl"
  [ "$output" = "parent-xyz" ]
  # `tool` and `file` are promoted to top-level per §3.5 events.jsonl schema
  # (log_event.sh reserves kind/tool/file/hash as event keys; other pairs
  # land under .payload).
  run jq -rs 'last | .tool' "$COORD_DIR/events.jsonl"
  [ "$output" = "Read" ]
  run jq -rs 'last | .file' "$COORD_DIR/events.jsonl"
  [ "$output" = "/tmp/foo.ts" ]
}

@test "subagent_filter: NotebookEdit uses tool_input.notebook_path for file field" {
  _call "PreToolUse" '{"session_id":"pnb","agent_type":"general-purpose","tool_name":"NotebookEdit","tool_input":{"notebook_path":"/tmp/foo.ipynb"}}'
  sleep 0.3
  run jq -rs 'last | .file' "$COORD_DIR/events.jsonl"
  [ "$output" = "/tmp/foo.ipynb" ]
}

@test "subagent_filter: subagent without tool/file still logs (core fields only)" {
  _call "SubagentStop" '{"session_id":"pkt","agent_type":"general-purpose"}'
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -rs 'last | .payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "SubagentStop" ]
  # With no tool or file values, those top-level keys must be absent.
  run jq -rs 'last | has("tool")' "$COORD_DIR/events.jsonl"
  [ "$output" = "false" ]
  run jq -rs 'last | has("file")' "$COORD_DIR/events.jsonl"
  [ "$output" = "false" ]
}

@test "subagent_filter: no COORD_DIR → still returns 0 (subagent) but skips log" {
  run bash -c "
    unset COORD_DIR SESSION_ID
    . '$SRC_ROOT/core/lib/log_event.sh'
    . '$F'
    coord_subagent_filter PreToolUse '{\"session_id\":\"sid\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Read\"}'
  "
  [ "$status" -eq 0 ]
  # events.jsonl must still be empty (no COORD_DIR means no log target).
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run grep -c SUBAGENT_ACTIVITY_SKIPPED "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "subagent_filter: coord_log_event not sourced → still returns 0, no crash" {
  run bash -c "
    . '$F'
    coord_subagent_filter PreToolUse '{\"session_id\":\"sid\",\"agent_type\":\"general-purpose\"}'
  "
  [ "$status" -eq 0 ]
}

@test "subagent_filter: CLI shim returns 0 for subagent input" {
  run bash -c "echo '{\"session_id\":\"sid\",\"agent_type\":\"general-purpose\",\"tool_name\":\"Read\"}' | '$F' PreToolUse"
  [ "$status" -eq 0 ]
}

@test "subagent_filter: CLI shim returns 1 for non-subagent input" {
  run bash -c "echo '{\"session_id\":\"sid\",\"tool_name\":\"Read\"}' | '$F' PreToolUse"
  [ "$status" -eq 1 ]
}

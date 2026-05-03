#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/pre_tool_use_bash.sh — PR D.4
# (plan v1.3).
#
# Bash is NOT a file-locking event. The hook does:
#   - Non-participant gate
#   - Lockdown gate (deny via permissionDecision)
#   - Log PRE_BASH event with truncated command
# It MUST NOT emit additionalContext (D-D4-02 / output_parser.rs:337-348
# rejects additionalContext on PreToolUse).

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/pre_tool_use_bash.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-pbash-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED
  : >"$COORD_DIR/events.jsonl"

  SID="cx-pbash-aaaa"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg s "$SID" '
    .sessions[$s] = {
      state: "ACTIVE", pid: 1, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z",
      last_activity_at: "2026-04-01T00:00:00Z",
      git_head: "", prompt_id: null, script_version: "1.0", agent: "codex"
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash",
    tool_input:{command:"ls -la /tmp"},
    tool_use_id:"tu-bash-1"
  }')
  INPUT_AGENT_TYPE=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", tool_input:{command:"echo hi"}, tool_use_id:"tu-2",
    agent_type:"general-purpose"
  }')
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

_activate_lockdown() {
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$1" --arg rs "$2" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

@test "codex pre_tool_use_bash: COORD_ENABLED unset → exit 0, no log" {
  run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "PRE_BASH")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "codex pre_tool_use_bash: input with agent_type DOES log (D-2: no subagent filter)" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT_AGENT_TYPE' | '$H'"
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "PRE_BASH")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # SUBAGENT_ACTIVITY_SKIPPED must NOT appear.
  run jq -rs '[.[] | select(.kind == "SUBAGENT_ACTIVITY_SKIPPED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "codex pre_tool_use_bash: non-participant → no-op" {
  local INP
  INP=$(jq -nc --arg s "not-registered" --arg cwd "$TMP" \
    '{session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Bash",
      tool_input:{command:"x"}, tool_use_id:"tu-x"}')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "codex pre_tool_use_bash: happy path → PRE_BASH event with truncated command" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "PRE_BASH" ]
  run jq -rs 'last | .payload.command' "$COORD_DIR/events.jsonl"
  [ "$output" = "ls -la /tmp" ]
}

@test "codex pre_tool_use_bash: long command is truncated to 256 chars + ellipsis" {
  local LONG_CMD
  LONG_CMD=$(printf 'a%.0s' $(seq 1 300))
  local LONG_INPUT
  LONG_INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" --arg c "$LONG_CMD" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", tool_input:{command:$c}, tool_use_id:"tu-long"
  }')
  COORD_ENABLED=1 run bash -c "echo '$LONG_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  sleep 0.3
  # Logged command ends in "..." marker
  run jq -rs 'last | .payload.command | endswith("...")' "$COORD_DIR/events.jsonl"
  [ "$output" = "true" ]
  # Logged command is exactly 256+3 chars
  run jq -rs 'last | .payload.command | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "259" ]
}

@test "codex pre_tool_use_bash: under active lockdown → emits permissionDecision deny" {
  _activate_lockdown "system pause" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
  # additionalContext MUST NOT be present (D-D4-02 invariant).
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
}

@test "codex pre_tool_use_bash: D-D4-02 invariant — never emits additionalContext on any branch" {
  # Branch 1: gate-disabled → empty (no JSON at all).
  run bash -c "echo '$INPUT' | '$H'"
  [ -z "$output" ] || echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Branch 2: happy allow → empty.
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ -z "$output" ] || echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Branch 3: lockdown deny → permissionDecision only, no additionalContext.
  _activate_lockdown "x" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
}

#!/usr/bin/env bats
# Tests for F-015 subagent `coord wait` soft-deprecation banner —
# Phase 6 T6.06 + PR-PHASE6-01 + Decision 1.
#
# Categories:
#   1. Non-subagent context → no banner       (1)
#   2. Subagent + non-Bash tool → no banner   (1)
#   3. Subagent + Bash + non-coord-wait → no banner (1)
#   4. Subagent + Bash + coord wait → banner injected + event (2)
#   5. Co-existence: parent reminder + subagent banner are
#      mutually exclusive (subagent_filter exits early)  (1)

load "../helpers/common"

H="$SRC_ROOT/hooks/pre_tool_use_any.sh"

setup() {
  TMP="$(mktemp -d -t coord-f015-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  : >"$COORD_DIR/events.jsonl"
  SID="sid-f015-A"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg s "$SID" '
    .sessions[$s] = {state:"ACTIVE",pid:1,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}
teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

_run_hook() {
  local input="$1"
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H'"
}

# ----- Category 1: Non-subagent context -----

@test "f015 banner: non-subagent (agent_type empty) coord wait → no banner emitted" {
  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash",
    tool_input:{command:"coord wait /p/foo --timeout 60"}
  }')
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  ! _grep_output_for "Subagent context detected"
}

# ----- Category 2: Subagent + non-Bash -----

@test "f015 banner: subagent context + Read tool → no banner (Bash gate)" {
  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Read", agent_type:"general-purpose",
    tool_input:{file_path:"/p/foo.ts"}
  }')
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  ! _grep_output_for "Subagent context detected"
}

# ----- Category 3: Subagent + Bash + non-coord-wait -----

@test "f015 banner: subagent + Bash + non-coord-wait command → no banner" {
  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", agent_type:"general-purpose",
    tool_input:{command:"ls -la"}
  }')
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  ! _grep_output_for "Subagent context detected"
}

# ----- Category 4: Subagent + Bash + coord wait -----

@test "f015 banner: subagent + Bash + 'coord wait' → banner injected" {
  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", agent_type:"general-purpose",
    tool_input:{command:"coord wait /p/foo --timeout 60"}
  }')
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  _grep_output_for "Subagent context detected"
  _grep_output_for "coord task-open"
  _grep_output_for "coord self-delegate"
  # NEVER deny — Decision 6 invariant.
  ! _grep_output_for "permissionDecision"
}

@test "f015 banner: SUBAGENT_COORD_WAIT_BANNER_EMITTED event with agent_type + parent_session" {
  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", agent_type:"general-purpose",
    tool_input:{command:"coord wait /p/foo"}
  }')
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  sleep 0.1
  run grep -c '"kind":"SUBAGENT_COORD_WAIT_BANNER_EMITTED"' \
      "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  grep '"kind":"SUBAGENT_COORD_WAIT_BANNER_EMITTED"' \
      "$COORD_DIR/events.jsonl" \
    | jq -e --arg s "$SID" '
        .payload.agent_type == "general-purpose"
        and .payload.parent_session == $s
      '
}

# ----- Category 5: Co-existence (mutual exclusion) -----

@test "f015 banner: subagent path exits early — parent self-task reminders NOT also injected" {
  # Pre-seed an unlocked self-task that WOULD trigger a reminder
  # in parent context. Subagent flow short-circuits before the
  # reminder block, so no reminder banner appears.
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/self_tasks.sh"
  coord_self_task_open "$SID" "$TMP/foo.ts" "edit" >/dev/null
  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", agent_type:"general-purpose",
    tool_input:{command:"coord wait /p/x"}
  }')
  run _run_hook "$INPUT"
  [ "$status" -eq 0 ]
  _grep_output_for "Subagent context detected"
  ! _grep_output_for "self-task pending"
}

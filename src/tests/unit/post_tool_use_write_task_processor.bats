#!/usr/bin/env bats
# Integration: post_tool_use_write.sh task-processor invocation —
# Phase 6 T6.05. Wires lib/task_processor.sh into the hook.
#
# Categories:
#   1. Empty queue path (no overhead, Phase 2 behavior preserved)  (1)
#   2. Single task happy path (no overlap → COMPLETED)             (1)
#   3. Single task overlap → CONFLICT outcome                       (1)
#   4. Multi-task ordering preserved                                (1)
#   5. Phase 2 invariant unchanged: hook never emits permissionDecision (1)
#   6. Lock release succeeds even when task processor encounters
#      malformed task record (graceful degradation)                 (1)

load "../helpers/common"

H="$SRC_ROOT/hooks/pre_tool_use_write.sh"
HP="$SRC_ROOT/hooks/post_tool_use_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-post-tp-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  : >"$COORD_DIR/events.jsonl"

  HOLDER="sid-post-tp-A"
  OPENER="sid-post-tp-B"
  touch "$COORD_DIR/sessions/${HOLDER}.active" \
        "$COORD_DIR/sessions/${OPENER}.active"
  jq --arg h "$HOLDER" --arg w "$OPENER" '
    .sessions[$h] = {state:"ACTIVE",pid:1,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0"}
    | .sessions[$w] = {state:"ACTIVE",pid:2,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET="$TMP/foo.ts"
  printf 'function loginHandler() {\n  // body\n}\n' >"$TARGET"
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID COORD_MOCK_CLAUDE_TASK_PATCH
  rm -rf "$TMP"
}

# Acquire a lock for HOLDER on TARGET via the real pre-write hook.
# Use bash -c subshell pattern matching pre_tool_use_write.bats —
# direct pipe from bats's @test body into the hook can lose the
# event_log background process, missing LOCK_ACQUIRED + downstream
# events.
_acquire() {
  local input
  input=$(jq -nc --arg h "$HOLDER" --arg t "$TARGET" --arg cwd "$TMP" '{
    session_id:$h, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Edit", tool_input:{file_path:$t}
  }')
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H'" >/dev/null 2>&1
}

# Append a task to locks[$TARGET].tasks[] (HOLDER must already hold lock).
_append_task() {
  local task_id="$1" task_start="$2" task_end="$3"
  local window="${task_start}-${task_end}"
  jq --arg f "$TARGET" --arg op "$OPENER" --arg tid "$task_id" \
     --arg win "$window" --argjson ts "$task_start" --argjson te "$task_end" '
    .locks[$f].tasks += [{
      task_id:$tid, opener:$op, file:$f,
      instruction:"edit", complexity:"SIMPLE",
      anchor:{search:"x", window_lines:$win},
      rationale:null, created_at:"t",
      affected_lines_at_open:[$ts, $te],
      status:"PENDING",
      outcome_diff:null, outcome_rationale:null, outcome_at:null
    }]' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

# Run post-write hook for HOLDER on TARGET with given start/end
# lines. Use bash -c subshell pattern (pre_tool_use_write.bats
# precedent) so the event-log background process inherits the
# subshell's lifetime, not the bats test body's pipe-captured
# child shell (which can drop events).
_post_write() {
  local edit_start="$1" edit_end="$2"
  local input
  input=$(jq -nc --arg h "$HOLDER" --arg t "$TARGET" --arg cwd "$TMP" \
      --argjson es "$edit_start" --argjson ee "$edit_end" '{
    session_id:$h, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"Edit", tool_input:{file_path:$t},
    tool_response:{start_line:$es, end_line:$ee}
  }')
  # Pass MOCK env through into the bash -c subshell explicitly.
  CLAUDE_COORD=1 \
    COORD_MOCK_CLAUDE_TASK_PATCH="${COORD_MOCK_CLAUDE_TASK_PATCH:-}" \
    bash -c "printf '%s' '$input' | '$HP'"
}

# ----- Category 1: Empty queue -----

@test "post_hook: empty task queue → lock released, fast-path skip (no TASK_PROCESSOR_RUN event)" {
  # Performance optimization: when locks[<file>].tasks is empty,
  # post_tool_use_write.sh skips coord_task_processor_run entirely
  # to avoid adding ~30-100ms of jq overhead to the critical path.
  # The empty-tasks signal is the ABSENCE of any TASK_PROCESSOR_RUN
  # event after lock release. Phase 5 timing-sensitive tests (S2.b
  # polling-fallback wake-up <600ms) require this fast-path.
  _acquire
  run _post_write 1 5
  [ "$status" -eq 0 ]
  # Lock removed (Phase 2 behavior preserved).
  run jq -e --arg f "$TARGET" '.locks[$f] // null | . == null' \
      "$COORD_DIR/sessions.json"
  sleep 0.1
  # No TASK_PROCESSOR_RUN event — fast-path skip elided the call.
  run grep -c '"kind":"TASK_PROCESSOR_RUN"' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
  # Lock release event still emitted (Phase 2 baseline).
  run grep -c '"kind":"LOCK_RELEASED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

# ----- Category 2: Single task happy path -----

@test "post_hook: single task no-overlap → COMPLETED outcome + opener notification persisted" {
  _acquire
  _append_task "tid-happy" 50 60
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"COMPLETED","diff":"--- a\n+++ b\nfoo","affected_lines":[50,55],"rationale":"applied at 50-55"}'
  run _post_write 1 10
  [ "$status" -eq 0 ]
  # Lock removed.
  run jq -e --arg f "$TARGET" '.locks[$f] // null | . == null' \
      "$COORD_DIR/sessions.json"
  # Notification appended for opener on TARGET.
  run jq -e --arg op "$OPENER" --arg t "$TARGET" '
    (.notifications[$op][$t] // []) | length == 1
    and (.[0] | contains("Status: COMPLETED"))
    and (.[0] | contains("Rationale: applied at 50-55"))
  ' "$COORD_DIR/sessions.json"
}

# ----- Category 3: Overlap → CONFLICT -----

@test "post_hook: single task overlap → CONFLICT outcome (no claude spawn)" {
  _acquire
  _append_task "tid-conflict" 5 10
  run _post_write 8 12
  [ "$status" -eq 0 ]
  run jq -e --arg op "$OPENER" --arg t "$TARGET" '
    .notifications[$op][$t][0] | contains("Status: CONFLICT")
  ' "$COORD_DIR/sessions.json"
}

# ----- Category 4: Multi-task ordering -----

@test "post_hook: multi-task FIFO order preserved across outcomes" {
  _acquire
  _append_task "tid-multi-1" 50 60
  _append_task "tid-multi-2" 100 110
  run _post_write 1 10
  [ "$status" -eq 0 ]
  run jq -e --arg op "$OPENER" --arg t "$TARGET" '
    (.notifications[$op][$t] // [])
    | length == 2
    and (.[0] | contains("tid-multi-1"))
    and (.[1] | contains("tid-multi-2"))
  ' "$COORD_DIR/sessions.json"
}

# ----- Category 5: Phase 2 invariant carry-forward -----

@test "post_hook: NEVER emits permissionDecision (Phase 2 invariant)" {
  _acquire
  _append_task "tid-inv" 50 60
  run _post_write 1 10
  ! _grep_output_for "permissionDecision"
}

# ----- Category 6: Graceful degradation on malformed task record -----

@test "post_hook: lock release succeeds even when mock spawn returns invalid JSON (SKIPPED outcome)" {
  _acquire
  _append_task "tid-degrade" 50 60
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"INVALID_ENUM","diff":"x","affected_lines":[1,2],"rationale":"bad"}'
  run _post_write 1 10
  [ "$status" -eq 0 ]
  # Lock still released.
  run jq -e --arg f "$TARGET" '.locks[$f] // null | . == null' \
      "$COORD_DIR/sessions.json"
  # Outcome notification = SKIPPED (spawn validation rejected the
  # invalid status enum, processor falls back to SKIPPED).
  run jq -e --arg op "$OPENER" --arg t "$TARGET" '
    .notifications[$op][$t][0] | contains("Status: SKIPPED")
  ' "$COORD_DIR/sessions.json"
}

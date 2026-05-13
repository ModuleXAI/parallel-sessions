#!/usr/bin/env bats
# Tests for lib/task_processor.sh — Phase 6 T6.05 + PR-PHASE6-05
# §3 (overlap algorithm) + §5 (mock claude contract) + §7 (task
# schema lifecycle) + §8 (TASK_OUTCOME notification payload).
#
# Categories:
#   1. coord_task_processor_check_affected   (5 tests)
#   2. coord_task_processor_spawn_claude     (3 tests)
#   3. coord_task_processor_write_outcome    (3 tests)
#   4. coord_task_processor_run               (5 tests)

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-tp-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  export COORD_DIR="$COORD"
  mk_empty_sessions "$COORD"
  : >"$COORD_DIR/events.jsonl"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/task_processor.sh"

  HOLDER="sid-tp-A"
  OPENER="sid-tp-B"
  TARGET="$TMP/foo.ts"
  printf 'foo\n' >"$TARGET"
  export SESSION_ID="$HOLDER"
}
teardown() {
  unset COORD_MOCK_CLAUDE_TASK_PATCH SESSION_ID COORD_DIR
  rm -rf "$TMP"
}

# Helper: create a lock entry held by HOLDER + populate with one
# task opened by OPENER (anchor at lines $1-$2).
_seed_lock_with_task() {
  local task_start="$1" task_end="$2" task_id="${3:-tid-001}"
  local window="${task_start}-${task_end}"
  jq --arg h "$HOLDER" --arg op "$OPENER" --arg f "$TARGET" \
     --arg tid "$task_id" --arg win "$window" \
     --argjson ts "$task_start" --argjson te "$task_end" '
    .sessions[$h] = (.sessions[$h] // {state:"ACTIVE", pid:1,
        pid_lstart:"x", registered_at:"y", last_activity_at:"z",
        git_head:"", prompt_id:null, script_version:"1.0"})
    | .sessions[$op] = (.sessions[$op] // {state:"ACTIVE", pid:2,
        pid_lstart:"x", registered_at:"y", last_activity_at:"z",
        git_head:"", prompt_id:null, script_version:"1.0"})
    | .locks[$f] = {session: $h, acquired_at: "t",
        last_refresh_at: "t", tasks: [{
          task_id: $tid, opener: $op, file: $f,
          instruction: "edit", complexity: "SIMPLE",
          anchor: {search: "x", window_lines: $win},
          rationale: null, created_at: "t",
          affected_lines_at_open: [$ts, $te],
          status: "PENDING",
          outcome_diff: null, outcome_rationale: null,
          outcome_at: null
        }]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

# ----- Category 1: check_affected -----

@test "check_affected: ranges fully apart → no_overlap rc 0" {
  run coord_task_processor_check_affected 10 20 30 40
  [ "$status" -eq 0 ]
  [ "$output" = "no_overlap" ]
}

@test "check_affected: ranges fully overlapping → overlap rc 1" {
  run coord_task_processor_check_affected 10 20 12 18
  [ "$status" -eq 1 ]
  [ "$output" = "overlap" ]
}

@test "check_affected: touching boundary (task_end == edit_start) → overlap rc 1" {
  run coord_task_processor_check_affected 10 20 20 30
  [ "$status" -eq 1 ]
}

@test "check_affected: edit ends one line before task starts → no_overlap rc 0" {
  run coord_task_processor_check_affected 20 30 10 19
  [ "$status" -eq 0 ]
}

@test "check_affected: non-integer arg → rc 2" {
  run coord_task_processor_check_affected 10 20 abc 40
  [ "$status" -eq 2 ]
}

# ----- Category 2: spawn_claude -----

@test "spawn_claude: no env-var override → deterministic default JSON" {
  run coord_task_processor_spawn_claude '{"task_id":"x"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .status == "COMPLETED"
    and (.affected_lines | length == 2)
    and .rationale == "mock default"
  '
}

@test "spawn_claude: env-var override returned verbatim + validated" {
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"CONFLICT","diff":"--- a\n+++ b\n","affected_lines":[5,7],"rationale":"holder edited X"}'
  run coord_task_processor_spawn_claude '{"task_id":"x"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .status == "CONFLICT"
    and .affected_lines == [5, 7]
    and .rationale == "holder edited X"
  '
}

@test "spawn_claude: invalid status enum → rc 1" {
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"INVALID","diff":"","affected_lines":[0,0],"rationale":"x"}'
  run coord_task_processor_spawn_claude '{"task_id":"x"}'
  [ "$status" -eq 1 ]
}

# ----- Category 3: write_outcome -----

@test "write_outcome: removes task from queue + appends notification + emits event" {
  _seed_lock_with_task 5 10 "tid-W"
  TASK_REC=$(jq -c --arg f "$TARGET" '.locks[$f].tasks[0]' "$COORD_DIR/sessions.json")
  OUTCOME='{"status":"COMPLETED","diff":"--- a\n+++ b\nfoo","affected_lines":[5,10],"rationale":"applied"}'
  run coord_task_processor_write_outcome \
    "$COORD_DIR/sessions.json" "$TARGET" "$TASK_REC" "$OUTCOME"
  [ "$status" -eq 0 ]
  # Task removed from queue.
  run jq -e --arg f "$TARGET" '.locks[$f].tasks | length == 0' "$COORD_DIR/sessions.json"
  # Notification appended to .notifications[<opener>][<file>].
  run jq -e --arg op "$OPENER" --arg f "$TARGET" '
    (.notifications[$op][$f] // []) | length == 1
    and (.[0] | startswith("Task tid-W on "))
    and (.[0] | contains("Status: COMPLETED"))
    and (.[0] | contains("Rationale: applied"))
  ' "$COORD_DIR/sessions.json"
  sleep 0.1
  run grep -c '"kind":"TASK_OUTCOME_PERSISTED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "write_outcome: banner uses <holder_session> placeholder (ambiguity C)" {
  _seed_lock_with_task 5 10 "tid-banner"
  TASK_REC=$(jq -c --arg f "$TARGET" '.locks[$f].tasks[0]' "$COORD_DIR/sessions.json")
  OUTCOME='{"status":"COMPLETED","diff":"","affected_lines":[5,10],"rationale":"ok"}'
  SESSION_ID="$HOLDER" coord_task_processor_write_outcome \
    "$COORD_DIR/sessions.json" "$TARGET" "$TASK_REC" "$OUTCOME"
  # Banner must include the holder session id (= $HOLDER).
  run jq -r --arg op "$OPENER" --arg f "$TARGET" \
    '.notifications[$op][$f][0]' "$COORD_DIR/sessions.json"
  echo "$output" | grep -q "by session $HOLDER"
}

@test "write_outcome: full diff persists in TASK_OUTCOME_PERSISTED event payload (no truncation in audit)" {
  _seed_lock_with_task 5 10 "tid-diff"
  TASK_REC=$(jq -c --arg f "$TARGET" '.locks[$f].tasks[0]' "$COORD_DIR/sessions.json")
  # Build a 5KB diff (above the 4KB notification cap).
  BIG_DIFF=$(printf 'x%.0s' $(seq 1 5120))
  OUTCOME=$(jq -nc --arg d "$BIG_DIFF" '{status:"COMPLETED",diff:$d,affected_lines:[5,10],rationale:"ok"}')
  coord_task_processor_write_outcome \
    "$COORD_DIR/sessions.json" "$TARGET" "$TASK_REC" "$OUTCOME"
  sleep 0.1
  # Event payload .diff_full must contain ALL 5120 chars.
  EVT=$(grep '"kind":"TASK_OUTCOME_PERSISTED"' "$COORD_DIR/events.jsonl" | head -1)
  EVT_DIFF_LEN=$(printf '%s' "$EVT" | jq -r '.payload.diff_full | length')
  [ "$EVT_DIFF_LEN" = "5120" ]
}

# ----- Category 4: coord_task_processor_run -----

@test "run: empty task queue → TASK_PROCESSOR_RUN with task_count=0" {
  jq --arg h "$HOLDER" --arg f "$TARGET" '
    .sessions[$h] = (.sessions[$h] // {state:"ACTIVE", pid:1,
        pid_lstart:"x", registered_at:"y", last_activity_at:"z",
        git_head:"", prompt_id:null, script_version:"1.0"})
    | .locks[$f] = {session: $h, acquired_at:"t",
        last_refresh_at:"t", tasks: []}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  run coord_task_processor_run "$TARGET" "$HOLDER" 5 10
  [ "$status" -eq 0 ]
  sleep 0.1
  EVT=$(grep '"kind":"TASK_PROCESSOR_RUN"' "$COORD_DIR/events.jsonl" | head -1)
  printf '%s' "$EVT" | jq -e '.payload.task_count == "0"'
}

@test "run: single task no-overlap → COMPLETED outcome via mock + queue cleared" {
  _seed_lock_with_task 50 60 "tid-run-1"
  # Holder edits lines 1-10 (no overlap with task anchor 50-60).
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"COMPLETED","diff":"applied","affected_lines":[50,55],"rationale":"applied at 50-55"}'
  run coord_task_processor_run "$TARGET" "$HOLDER" 1 10
  [ "$status" -eq 0 ]
  # Queue cleared.
  run jq -e --arg f "$TARGET" '.locks[$f].tasks | length == 0' "$COORD_DIR/sessions.json"
  # Notification appended.
  run jq -e --arg op "$OPENER" --arg f "$TARGET" '
    (.notifications[$op][$f] // []) | length == 1
    and (.[0] | contains("Status: COMPLETED"))
  ' "$COORD_DIR/sessions.json"
}

@test "run: single task overlap → CONFLICT outcome (no claude spawn)" {
  _seed_lock_with_task 5 10 "tid-conflict"
  # Holder edit 8-12 overlaps task 5-10.
  run coord_task_processor_run "$TARGET" "$HOLDER" 8 12
  [ "$status" -eq 0 ]
  run jq -e --arg op "$OPENER" --arg f "$TARGET" '
    .notifications[$op][$f][0] | contains("Status: CONFLICT")
  ' "$COORD_DIR/sessions.json"
  sleep 0.1
  EVT=$(grep '"kind":"TASK_PROCESSOR_RUN"' "$COORD_DIR/events.jsonl" | head -1)
  printf '%s' "$EVT" | jq -e '.payload.conflicts == "1"'
}

@test "run: multi-task FIFO ordering preserved across outcomes" {
  _seed_lock_with_task 50 60 "tid-multi-1"
  # Append second task targeting different non-overlapping range.
  jq --arg f "$TARGET" --arg op "$OPENER" '
    .locks[$f].tasks += [{
      task_id:"tid-multi-2", opener:$op, file:$f,
      instruction:"second", complexity:"COMPLEX",
      anchor:{search:"y", window_lines:"100-105"},
      rationale:null, created_at:"t",
      affected_lines_at_open:[100,105], status:"PENDING",
      outcome_diff:null, outcome_rationale:null, outcome_at:null
    }]' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  run coord_task_processor_run "$TARGET" "$HOLDER" 1 10
  [ "$status" -eq 0 ]
  run jq -e --arg f "$TARGET" '.locks[$f].tasks | length == 0' \
      "$COORD_DIR/sessions.json"
  run jq -e --arg op "$OPENER" --arg f "$TARGET" '
    (.notifications[$op][$f] // [])
    | length == 2
    and (.[0] | contains("tid-multi-1"))
    and (.[1] | contains("tid-multi-2"))
  ' "$COORD_DIR/sessions.json"
}

@test "run: holder edit lines 0/0 (whole-file replace) → all tasks CONFLICT (force_conflict=1)" {
  _seed_lock_with_task 5 10 "tid-whole-1"
  run coord_task_processor_run "$TARGET" "$HOLDER" 0 0
  [ "$status" -eq 0 ]
  run jq -e --arg op "$OPENER" --arg f "$TARGET" '
    .notifications[$op][$f][0] | contains("Status: CONFLICT")
    and contains("holder edit covered whole file")
  ' "$COORD_DIR/sessions.json"
}

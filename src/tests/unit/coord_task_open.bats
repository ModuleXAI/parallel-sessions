#!/usr/bin/env bats
# Tests for `coord task-open` CLI subcommand — Phase 6 T6.03 +
# PR-PHASE6-05 §1-§7 + ambiguity dispositions A (--rationale optional)
# and B (file-not-exists → "anchor not found").
#
# Categories:
#   1. Required-flag validation                (4 tests)
#   2. Complexity enum validation              (1 test)
#   3. Anchor format + uniqueness              (5 tests)
#   4. task_delegation toggle                  (1 test)
#   5. Cycle / depth surfacing (T6.02 lib)     (2 tests)
#   6. Persistence + task_id + ordering        (3 tests)
#   7. --rationale optional (ambiguity A)      (1 test)

load "../helpers/common"

CLI="$SRC_ROOT/core/bin/coord"

setup() {
  TMP="$(mktemp -d -t coord-task-open-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  : >"$COORD_DIR/events.jsonl"

  # Two sessions: HOLDER (locks files) + OPENER (delegates tasks).
  HOLDER="sid-tk-holder"
  OPENER="sid-tk-opener"
  touch "$COORD_DIR/sessions/${HOLDER}.active" "$COORD_DIR/sessions/${OPENER}.active"
  jq --arg h "$HOLDER" --arg w "$OPENER" '
    .sessions[$h]={state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
    | .sessions[$w]={state:"ACTIVE",pid:2,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # Default config.json with task_delegation=true.
  cat >"$COORD_DIR/config.json" <<'EOF'
{
  "schema_version": "1.0",
  "task_delegation": true,
  "lock_ttl_seconds": 900,
  "watchdog_suspicion_seconds": 1200,
  "watchdog_confirm_seconds": 1500,
  "read_set_cap_per_session": 200,
  "wait_poll_schedule_seconds": [30, 60, 120],
  "wait_max_seconds": 570,
  "max_task_chain_depth": 3,
  "max_tasks_per_lock": 5,
  "max_anchor_window_lines": 10,
  "validator_enabled": true,
  "mediator_enabled": true
}
EOF

  TARGET="$TMP/foo.ts"
  printf 'function loginHandler() {\n  // body\n}\n' >"$TARGET"

  ANCHOR_OK='{"search":"function loginHandler","window_lines":"1-3"}'
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# Helper: place a lock for HOLDER on the target file directly via jq.
_lock() {
  local file="$1"
  jq --arg h "$HOLDER" --arg f "$file" '
    .locks[$f]={session:$h, acquired_at:"t", last_refresh_at:"t", tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

# ----- Category 1: Required-flag validation -----

@test "task-open: missing --file → usage" {
  run env SESSION_ID="$OPENER" "$CLI" task-open --complexity SIMPLE \
      --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "usage:"
}

@test "task-open: missing --complexity → error" {
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "complexity is required"
}

@test "task-open: missing --anchor → error" {
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --instruction "fix it"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "anchor is required"
}

@test "task-open: missing --instruction → error" {
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "instruction is required"
}

# ----- Category 2: Complexity enum -----

@test "task-open: invalid --complexity rejected" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity INVALID --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Error: invalid complexity"
}

# ----- Category 3: Anchor format + uniqueness -----

@test "task-open: malformed --anchor JSON rejected" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor 'not-json' --instruction "fix it"
  [ "$status" -eq 1 ]
  # Either jq parse fail OR missing-key error — both are acceptable
  # signals that malformed JSON is rejected at this stage.
  echo "$output" | grep -qE "anchor.+(JSON|search)"
}

@test "task-open: --anchor missing search key rejected" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor '{"window_lines":"1-3"}' \
      --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'missing required key "search"'
}

@test "task-open: --anchor.window_lines start > end rejected" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE \
      --anchor '{"search":"function loginHandler","window_lines":"10-3"}' \
      --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "start.*must be <="
}

@test "task-open: file-not-exists → 'anchor not found' (ambiguity B)" {
  # No lock setup; file genuinely does not exist on disk.
  GHOST="$TMP/ghost.ts"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$GHOST" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Error: anchor not found in"
}

@test "task-open: anchor matches 0 / ≥2 / 1 — uniqueness paths" {
  _lock "$TARGET"
  # 0 matches.
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE \
      --anchor '{"search":"nonexistent_token","window_lines":"1-3"}' \
      --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "anchor not found"
  # ≥2 matches: write a file with two identical search hits.
  DUP="$TMP/dup.ts"
  printf 'foo\nfoo\n' >"$DUP"
  _lock "$DUP"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$DUP" \
      --complexity SIMPLE \
      --anchor '{"search":"foo","window_lines":"1-2"}' \
      --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "anchor matches 2 candidates"
  # 1 match → happy path proceeds to persistence.
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "task created"
}

# ----- Category 4: task_delegation toggle -----

@test "task-open: task_delegation=false in config.json → exit 1 with stderr" {
  _lock "$TARGET"
  jq '.task_delegation = false' "$COORD_DIR/config.json" \
    >"$COORD_DIR/config.json.new"
  mv "$COORD_DIR/config.json.new" "$COORD_DIR/config.json"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Error: task_delegation disabled per repo"
  # Ensure no task was persisted on rejection.
  run jq -r --arg f "$TARGET" '.locks[$f].tasks | length' \
      "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

# ----- Category 5: Cycle / depth surfacing (T6.02 lib) -----

@test "task-open: chain depth exceeded surfaces from lib (rc 1 + stderr)" {
  # Build chain B → A → C → D → E (depth 4 from B's perspective).
  _lock "$TARGET"   # holder: HOLDER (acts as A in the chain).
  for entry in \
      "/p/f2 sid-C $HOLDER" \
      "/p/f3 sid-D sid-C" \
      "/p/f4 sid-E sid-D"; do
    set -- $entry
    file="$1"; lockholder="$2"; opener="$3"
    jq --arg f "$file" --arg lh "$lockholder" --arg op "$opener" '
      .locks[$f]={session:$lh, acquired_at:"t", last_refresh_at:"t",
        tasks:[{
          task_id:("tid-"+$f), opener:$op, file:$f,
          instruction:"x", complexity:"SIMPLE",
          anchor:{search:"x", window_lines:"1-2"},
          rationale:null, created_at:"t",
          affected_lines_at_open:[1,2], status:"PENDING",
          outcome_diff:null, outcome_rationale:null, outcome_at:null
        }]}
      | .sessions[$lh]=(.sessions[$lh] // {state:"ACTIVE",pid:1,
          pid_lstart:"x",registered_at:"y",last_activity_at:"z",
          git_head:"",prompt_id:null,script_version:"1.0"})
      | .sessions[$op]=(.sessions[$op] // {state:"ACTIVE",pid:1,
          pid_lstart:"x",registered_at:"y",last_activity_at:"z",
          git_head:"",prompt_id:null,script_version:"1.0"})
    ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
    mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  done
  # OPENER opening on TARGET creates B → A; chain extends past depth 3.
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Chain depth exceeded"
}

@test "task-open: task cycle detected surfaces from lib (rc 1 + stderr)" {
  # Cycle: OPENER opens on TARGET (held by HOLDER); HOLDER has open
  # task on /p/f2 (held by OPENER) → 2-cycle.
  _lock "$TARGET"
  jq --arg op "$OPENER" --arg h "$HOLDER" '
    .locks["/p/f2"]={session:$op, acquired_at:"t", last_refresh_at:"t",
      tasks:[{
        task_id:"tid-back", opener:$h, file:"/p/f2",
        instruction:"x", complexity:"SIMPLE",
        anchor:{search:"x", window_lines:"1-2"},
        rationale:null, created_at:"t",
        affected_lines_at_open:[1,2], status:"PENDING",
        outcome_diff:null, outcome_rationale:null, outcome_at:null
      }]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Task cycle detected"
}

# ----- Category 6: Persistence + task_id + ordering -----

@test "task-open: happy path persists task with full schema" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity MODERATE --anchor "$ANCHOR_OK" \
      --instruction "rename signature" --rationale "API breakage"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "task created"
  # Validate persisted record.
  run jq -e --arg f "$TARGET" '
    .locks[$f].tasks[0]
    | (.task_id | startswith("'"$OPENER"'-task-"))
      and (.opener == "'"$OPENER"'")
      and (.complexity == "MODERATE")
      and (.anchor.search == "function loginHandler")
      and (.anchor.window_lines == "1-3")
      and (.rationale == "API breakage")
      and (.status == "PENDING")
      and (.affected_lines_at_open == [1, 3])
      and (.outcome_diff == null)
  ' "$COORD_DIR/sessions.json"
}

@test "task-open: error when target file is not currently locked" {
  # File exists, has matching anchor, but no .locks[] entry → reject.
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "is not currently locked"
}

@test "task-open: multi-task ordering preserves FIFO append" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "first"
  [ "$status" -eq 0 ]
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity COMPLEX --anchor "$ANCHOR_OK" --instruction "second"
  [ "$status" -eq 0 ]
  run jq -e --arg f "$TARGET" '
    (.locks[$f].tasks | length == 2)
    and (.locks[$f].tasks[0].instruction == "first")
    and (.locks[$f].tasks[1].instruction == "second")
    and (.locks[$f].tasks[0].complexity == "SIMPLE")
    and (.locks[$f].tasks[1].complexity == "COMPLEX")
  ' "$COORD_DIR/sessions.json"
}

# ----- Category 7: --rationale optional (ambiguity A) -----

@test "task-open: --rationale omitted → persisted as null" {
  _lock "$TARGET"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "fix it"
  [ "$status" -eq 0 ]
  run jq -e --arg f "$TARGET" '.locks[$f].tasks[0].rationale == null' \
      "$COORD_DIR/sessions.json"
}

#!/usr/bin/env bats
# Tests for `coord self-delegate` CLI subcommand — Phase 6 T6.04
# (CLI half of the lib+CLI bundle; lib half tested in
# self_tasks.bats).

load "../helpers/common"

CLI="$SRC_ROOT/core/bin/coord"

setup() {
  TMP="$(mktemp -d -t coord-sd-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  : >"$COORD_DIR/events.jsonl"
  SID="sid-sd-A"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg s "$SID" '
    .sessions[$s]={state:"ACTIVE",pid:1,pid_lstart:"x",
       registered_at:"y",last_activity_at:"z",git_head:"",
       prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  TARGET="$TMP/foo.ts"
  printf 'foo\n' >"$TARGET"
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# ----- Required-flag validation -----

@test "self-delegate: missing --file → usage" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --instruction "edit"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "usage:"
}

@test "self-delegate: missing --instruction → error" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "instruction is required"
}

@test "self-delegate: relative path rejected (absolute required)" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "rel/path.ts" \
      --instruction "edit"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "must be an absolute path"
}

# ----- Happy path persistence -----

@test "self-delegate: happy path persists self_task + emits banner" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET" \
      --instruction "rename signature"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "self-task created"
  echo "$output" | grep -q "prompt_id:"
  echo "$output" | grep -q "Reminder will inject when this file is unlocked"
  # Persisted self_tasks entry.
  run jq -e --arg s "$SID" '
    .self_tasks[$s][0]
    | (.file == "'"$TARGET"'")
      and (.instruction == "rename signature")
      and (.prompt_id | type == "string")
      and (.created_at | type == "string")
  ' "$COORD_DIR/sessions.json"
}

@test "self-delegate: prompt_id format <sid>-self-<ms>-<hex4>" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET" \
      --instruction "edit"
  [ "$status" -eq 0 ]
  # Extract prompt_id from output ("  prompt_id:   <pid>").
  PID=$(printf '%s\n' "$output" | awk '/prompt_id:/ {print $2}')
  echo "$PID" | grep -qE "^${SID}-self-[0-9]{10,}-[0-9a-f]{4}$"
}

# ----- task_delegation toggle does NOT gate self-delegate -----

@test "self-delegate: works even when config.json task_delegation=false" {
  cat >"$COORD_DIR/config.json" <<'EOF'
{"schema_version":"1.0","task_delegation":false}
EOF
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET" \
      --instruction "edit"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "self-task created"
  # Confirm persisted (unlike task-open which would refuse).
  run jq -e --arg s "$SID" '.self_tasks[$s] | length == 1' \
      "$COORD_DIR/sessions.json"
}

# ----- Multi-call ordering + idempotency -----

@test "self-delegate: two distinct (file, instruction) tuples → 2 entries" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET" \
      --instruction "first"
  [ "$status" -eq 0 ]
  TARGET2="$TMP/bar.ts"
  printf 'bar\n' >"$TARGET2"
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET2" \
      --instruction "second"
  [ "$status" -eq 0 ]
  run jq -e --arg s "$SID" '
    .self_tasks[$s] | length == 2
    and (.[0].instruction == "first")
    and (.[1].instruction == "second")
  ' "$COORD_DIR/sessions.json"
}

@test "self-delegate: SELF_TASK_OPENED event emitted via lib" {
  run env SESSION_ID="$SID" "$CLI" self-delegate --file "$TARGET" \
      --instruction "edit"
  [ "$status" -eq 0 ]
  sleep 0.1
  run grep -c '"kind":"SELF_TASK_OPENED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

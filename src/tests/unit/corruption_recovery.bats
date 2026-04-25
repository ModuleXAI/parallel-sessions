#!/usr/bin/env bats
# End-to-end corruption-recovery test per CLAUDE.md §B.9.2.
# Verifies the FULL chain: corrupt sessions.json → hook fires → atomic_edit
# detects + archives + resets + writes Mediator flag → next hook surfaces
# the §B.9.2 banner via additionalContext → flag is renamed to delivered
# so the banner doesn't repeat.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-corrupt-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  HSS="$SRC_ROOT/hooks/session_start.sh"
  HANY="$SRC_ROOT/hooks/pre_tool_use_any.sh"

  SID="sid-corrupt-0001"

  # Corrupt the state file.
  printf '{ this is not valid JSON {{{' >"$COORD_DIR/sessions.json"
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

@test "corruption: SessionStart against corrupt sessions.json triggers reset + archive + Mediator flag" {
  local INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  # sessions.json now parses with the canonical schema.
  run jq -e '.schema_version == "1.0"' "$COORD_DIR/sessions.json"
  [ "$status" -eq 0 ]
  # Corrupt original archived under sessions.json.corrupt.<ts>.json.
  run bash -c 'ls "'"$COORD_DIR"'/sessions.json.corrupt."*.json 2>/dev/null | wc -l | tr -d " "'
  [ "$output" = "1" ]
  # Banner consumed within this same hook → pending.json renamed to delivered.
  [ ! -f "$COORD_DIR/mediator/pending.json" ]
}

@test "corruption: pre_tool_use_any surfaces §B.9.2 banner when flag is present" {
  # Manually create the Mediator pending flag (simulating that a prior
  # atomic_edit detected corruption and reset the state).
  jq -n --arg ts "2026-04-25T00:00:00Z" --arg file "$COORD_DIR/sessions.json" \
    '{kind:"corrupt_state", ts:$ts, file:$file}' \
    >"$COORD_DIR/mediator/pending.json"
  # Re-write a clean sessions.json so atomic_edit doesn't trigger another
  # corruption.
  bash -c ". '$SRC_ROOT/lib/atomic_write.sh' && coord_state_empty_template" >"$COORD_DIR/sessions.json"
  # Register the session so the participant gate passes.
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  local INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  CLAUDE_COORD=1 run bash -c "echo '$INP' | '$HANY'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("coordination state was reset due to corruption")' >/dev/null

  # Flag is now renamed to pending.delivered.<ts>.json — running the same
  # hook again must NOT re-emit the banner.
  [ ! -f "$COORD_DIR/mediator/pending.json" ]
  run bash -c 'ls "'"$COORD_DIR"'/mediator/pending.delivered."*.json 2>/dev/null | wc -l | tr -d " "'
  [ "$output" = "1" ]
}

@test "corruption: banner is NOT repeated on a second hook firing" {
  # Same scenario as above; run the hook twice.
  jq -n --arg ts "2026-04-25T00:00:00Z" --arg file "$COORD_DIR/sessions.json" \
    '{kind:"corrupt_state", ts:$ts, file:$file}' \
    >"$COORD_DIR/mediator/pending.json"
  bash -c ". '$SRC_ROOT/lib/atomic_write.sh' && coord_state_empty_template" >"$COORD_DIR/sessions.json"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  local INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  CLAUDE_COORD=1 bash -c "echo '$INP' | '$HANY'" >/dev/null
  CLAUDE_COORD=1 run bash -c "echo '$INP' | '$HANY'"
  [ "$status" -eq 0 ]
  # Second run: NO additionalContext (no notifications, no HEAD drift, no
  # corruption banner left to emit).
  [ "$output" = "" ]
}

@test "corruption: full end-to-end — corrupt → hook reset → next hook surfaces banner" {
  # Step 1: SessionStart hook fires against corrupt sessions.json, recovers.
  local INP_START='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INP_START' | '$HSS'"
  [ "$status" -eq 0 ]
  # Banner emitted by THIS hook (it consumed the flag itself).
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("coordination state was reset")' >/dev/null

  # Step 2: subsequent pre_tool_use_any sees no pending banner (already
  # consumed by SessionStart), no spurious additionalContext.
  local INP_ANY='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  CLAUDE_COORD=1 run bash -c "echo '$INP_ANY' | '$HANY'"
  [ "$status" -eq 0 ]
  case "$output" in
    *"coordination state was reset"*) return 1 ;;  # must NOT re-emit
  esac
  true
}

@test "corruption: hook never returns non-zero on corruption (fail-open)" {
  # The point of §B.9.2 step 5 — corruption must never block the tool call.
  local INP_START='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INP_START' | '$HSS'"
  [ "$status" -eq 0 ]
}

@test "corruption: consume helper returns 1 and no output when no flag exists" {
  # Direct unit test of the helper: with no pending.json present, the
  # function must be a silent no-op returning 1 (no banner consumed).
  rm -f "$COORD_DIR/mediator/pending.json"
  run bash -c "
    export COORD_DIR='$COORD_DIR'
    . '$SRC_ROOT/lib/atomic_write.sh'
    coord_consume_corrupt_state_flag
  "
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "corruption: consume helper ignores pending.json with non-corrupt kind" {
  # Phase 3 will use pending.json for OTHER kinds (e.g., flock_timeout).
  # The helper must only consume corrupt_state, leaving others for Phase 3
  # Mediator to handle.
  jq -n '{kind:"flock_timeout", ts:"2026-04-25T00:00:00Z"}' >"$COORD_DIR/mediator/pending.json"
  run bash -c "
    export COORD_DIR='$COORD_DIR'
    . '$SRC_ROOT/lib/atomic_write.sh'
    coord_consume_corrupt_state_flag
  "
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  # pending.json untouched.
  [ -f "$COORD_DIR/mediator/pending.json" ]
}

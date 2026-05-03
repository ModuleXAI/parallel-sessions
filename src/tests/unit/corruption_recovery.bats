#!/usr/bin/env bats
# End-to-end corruption-recovery test per CLAUDE.md §B.9.2 — updated
# in T3.07 (PR-PHASE3-03 / Decision 4) for the unified pending.jsonl
# flow. corrupt_state is now an entry kind in pending.jsonl alongside
# flock_timeout (T2.04) and Phase 3 new kinds (stale_active /
# pid_recycled / manual). The legacy single-file pending.json is
# eliminated; install.sh migrates pre-Phase-3 pending.json forward.
#
# Verifies the FULL chain:
#   corrupt sessions.json → hook fires → atomic_edit detects + archives +
#   resets + appends pending.jsonl entry (kind=corrupt_state) →
#   coord_consume_corrupt_state_flag prints the §B.9.2 banner from
#   pending.jsonl tail → coord_mediator_consume_pending advances HWM,
#   so the same banner is not emitted twice.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-corrupt-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  HSS="$SRC_ROOT/adapters/claude-code/hooks/session_start.sh"
  HANY="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_any.sh"

  SID="sid-corrupt-0001"

  # Pre-create pending.jsonl + lock + HWM file so consumers find them.
  : >"$COORD/mediator/pending.jsonl"
  : >"$COORD/mediator/pending.lock"

  # Corrupt the state file.
  printf '{ this is not valid JSON {{{' >"$COORD_DIR/sessions.json"
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

# Helper: emit a corrupt_state pending.jsonl entry directly via the
# T2.04 producer. Used by tests that pre-seed the queue without going
# through the corruption-detection-in-atomic_edit path.
_emit_corrupt_state_entry() {
  bash -c '
    . "'"$SRC_ROOT/core/lib/log_event.sh"'"
    . "'"$SRC_ROOT/core/lib/mediator_pending.sh"'"
    coord_mediator_emit_pending corrupt_state \
      source=test \
      file="'"$COORD/sessions.json"'" \
      detected_at="2026-04-25T00:00:00Z"
  '
}

@test "corruption: SessionStart against corrupt sessions.json triggers reset + archive + pending.jsonl entry" {
  local INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  # sessions.json now parses with the canonical schema.
  run jq -e '.schema_version == "1.0"' "$COORD_DIR/sessions.json"
  [ "$status" -eq 0 ]
  # Corrupt original archived under sessions.json.corrupt.<ts>.json.
  run bash -c 'ls "'"$COORD_DIR"'/sessions.json.corrupt."*.json 2>/dev/null | wc -l | tr -d " "'
  [ "$output" = "1" ]
  # pending.jsonl now has at least one corrupt_state entry.
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "corrupt_state")] | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
}

@test "corruption: pre_tool_use_any surfaces §B.9.2 banner when corrupt_state is unconsumed" {
  # Pre-seed a corrupt_state entry into pending.jsonl.
  _emit_corrupt_state_entry
  # Re-write a clean sessions.json so atomic_edit doesn't trigger another
  # corruption.
  bash -c ". '$SRC_ROOT/core/lib/atomic_write.sh' && coord_state_empty_template" >"$COORD_DIR/sessions.json"
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

  # HWM advanced past the corrupt_state entry → second hook firing
  # produces no corruption banner.
  run cat "$COORD_DIR/mediator/pending.consumed"
  [ "$output" -ge 1 ]
}

@test "corruption: banner is NOT repeated on a second hook firing" {
  _emit_corrupt_state_entry
  bash -c ". '$SRC_ROOT/core/lib/atomic_write.sh' && coord_state_empty_template" >"$COORD_DIR/sessions.json"
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
  case "$output" in
    *"coordination state was reset"*) return 1 ;;
  esac
  true
}

@test "corruption: full end-to-end — corrupt → hook reset → SessionStart surfaces banner once" {
  # Step 1: SessionStart hook fires against corrupt sessions.json, recovers.
  local INP_START='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INP_START' | '$HSS'"
  [ "$status" -eq 0 ]
  # Banner emitted by THIS hook (it consumed the flag itself via the
  # composed banner pipeline: corrupt_state consumer + Coord-v1.0 banner).
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("coordination state was reset")' >/dev/null

  # Step 2: subsequent pre_tool_use_any sees no corruption banner
  # (HWM advanced; not re-emitted).
  local INP_ANY='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}'
  CLAUDE_COORD=1 run bash -c "echo '$INP_ANY' | '$HANY'"
  [ "$status" -eq 0 ]
  case "$output" in
    *"coordination state was reset"*) return 1 ;;
  esac
  true
}

@test "corruption: hook never returns non-zero on corruption (fail-open)" {
  local INP_START='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INP_START' | '$HSS'"
  [ "$status" -eq 0 ]
}

@test "corruption: consume helper returns 1 and no output when pending.jsonl is empty" {
  # No corrupt_state entries above HWM → helper returns 1.
  run bash -c "
    export COORD_DIR='$COORD_DIR'
    . '$SRC_ROOT/core/lib/atomic_write.sh'
    coord_consume_corrupt_state_flag
  "
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "corruption: consume helper ignores non-corrupt kinds in pending.jsonl" {
  # Phase 2 + 3 share pending.jsonl across multiple kinds. The
  # corrupt_state consumer must IGNORE non-matching kinds.
  bash -c '
    . "'"$SRC_ROOT/core/lib/log_event.sh"'"
    . "'"$SRC_ROOT/core/lib/mediator_pending.sh"'"
    coord_mediator_emit_pending flock_timeout source=test file=foo
  '
  run bash -c "
    export COORD_DIR='$COORD_DIR'
    . '$SRC_ROOT/core/lib/atomic_write.sh'
    coord_consume_corrupt_state_flag
  "
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
  # pending.jsonl untouched: flock_timeout entry still present.
  run jq -rs '[.[] | select(.kind == "flock_timeout")] | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
}

@test "corruption: consume helper finds corrupt_state in mixed-kind pending.jsonl" {
  # Mix of flock_timeout (irrelevant) + corrupt_state (relevant) — helper
  # must return 0 (banner emitted) when AT LEAST ONE corrupt_state is
  # present above HWM.
  bash -c '
    . "'"$SRC_ROOT/core/lib/log_event.sh"'"
    . "'"$SRC_ROOT/core/lib/mediator_pending.sh"'"
    coord_mediator_emit_pending flock_timeout source=test file=foo
    coord_mediator_emit_pending corrupt_state source=test file=bar
    coord_mediator_emit_pending flock_timeout source=test file=baz
  '
  run bash -c "
    export COORD_DIR='$COORD_DIR'
    . '$SRC_ROOT/core/lib/atomic_write.sh'
    coord_consume_corrupt_state_flag
  "
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "coordination state was reset due to corruption"
}

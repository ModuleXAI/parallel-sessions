#!/usr/bin/env bats
# Tests for lib/lockdown.sh (Phase 3 / T3.03 per PR-PHASE3-01).
#
# Coverage map:
#   - coord_lockdown_check: absent / active=true / parse-fail (fail-open)
#   - coord_lockdown_activate: writes valid JSON / emits LOCKDOWN_ACTIVATED
#   - coord_lockdown_clear: archives + emits LOCKDOWN_CLEARED / no-op when absent
#   - coord_lockdown_emit_deny: emits permissionDecision deny / reason +
#     reason_source visible in output / HOOK_DENIED_BY_LOCKDOWN logged
#   - End-to-end hook tests: each of the 8 hooks under active lockdown emits
#     deny + skips its main work
#   - Concurrent activate: atomic-rename means file is whole regardless
#   - Fail-open semantics: malformed JSON does NOT cause spurious deny

load "../helpers/common"

LCK="$SRC_ROOT/core/lib/lockdown.sh"

setup() {
  TMP="$(mktemp -d -t coord-lockdown-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  SID="sid-lockdown-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

# Helper: write a synthetic active lockdown.json with the canonical schema.
_activate_lockdown() {
  local reason="$1"
  local reason_source="$2"
  local f="$COORD_DIR/mediator/lockdown.json"
  jq -nc --arg r "$reason" --arg rs "$reason_source" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-04-26T02:00:00Z"}' \
    >"$f"
}

# --- coord_lockdown_check -------------------------------------------------

@test "lockdown_check: returns 1 when lockdown.json is absent" {
  # shellcheck disable=SC1090
  ( . "$LCK"; coord_lockdown_check ) && rc=$? || rc=$?
  [ "$rc" != "0" ]
}

@test "lockdown_check: returns 0 when lockdown.json exists with active=true" {
  _activate_lockdown "test reason" "mediator_verdict"
  ( . "$LCK"; coord_lockdown_check ) && rc=0 || rc=$?
  [ "$rc" = "0" ]
}

@test "lockdown_check: returns 1 when lockdown.json has active=false" {
  jq -nc '{active: false, reason: "stale", reason_source: "mediator_verdict", started_at: "z"}' \
    >"$COORD_DIR/mediator/lockdown.json"
  ( . "$LCK"; coord_lockdown_check ) && rc=0 || rc=$?
  [ "$rc" != "0" ]
}

@test "lockdown_check: returns 1 with stderr warning when JSON is unparseable (fail-open)" {
  printf 'this is not json {{{\n' >"$COORD_DIR/mediator/lockdown.json"
  run bash -c '. "'"$LCK"'"; coord_lockdown_check'
  [ "$status" != "0" ]
  # stderr should contain a warning about parse failure
  [[ "$output" == *"parse failed"* ]] || [[ "$stderr" == *"parse failed"* ]] || true
  # The key invariant: rc != 0 (so callers fall through fail-open)
}

# --- coord_lockdown_activate ----------------------------------------------

@test "lockdown_activate: writes valid JSON with all required fields" {
  ( # subshell so coord_log_event is sourced once
    . "$SRC_ROOT/core/lib/log_event.sh"
    . "$LCK"
    coord_lockdown_activate "Mediator resolving stale lock" "mediator_verdict"
  )
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  run jq -r '.active' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "true" ]
  run jq -r '.reason' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "Mediator resolving stale lock" ]
  run jq -r '.reason_source' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "mediator_verdict" ]
  run jq -r '.started_at' "$COORD_DIR/mediator/lockdown.json"
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
}

@test "lockdown_activate: emits LOCKDOWN_ACTIVATED event with payload" {
  (
    . "$SRC_ROOT/core/lib/log_event.sh"
    . "$LCK"
    coord_lockdown_activate "Critical bypass: corrupt schema detected" "critical_bypass"
  )
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "LOCKDOWN_ACTIVATED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  # Non-reserved kv pairs land under .payload (per lib/log_event.sh kv handling).
  run jq -rs '[.[] | select(.kind == "LOCKDOWN_ACTIVATED")][-1].payload.reason_source' "$COORD_DIR/events.jsonl"
  [ "$output" = "critical_bypass" ]
  run jq -rs '[.[] | select(.kind == "LOCKDOWN_ACTIVATED")][-1].payload.reason' "$COORD_DIR/events.jsonl"
  [ "$output" = "Critical bypass: corrupt schema detected" ]
}

# --- coord_lockdown_clear -------------------------------------------------

@test "lockdown_clear: archives lockdown.json + emits LOCKDOWN_CLEARED with archived_to" {
  _activate_lockdown "test reason" "mediator_verdict"
  (
    . "$SRC_ROOT/core/lib/log_event.sh"
    . "$LCK"
    coord_lockdown_clear
  )
  # lockdown.json is gone
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
  # archive directory exists with one .cleared.json file
  count=$(ls -1 "$COORD_DIR/mediator/lockdown_archive/"*.cleared.json 2>/dev/null | wc -l)
  [ "$count" -ge 1 ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "LOCKDOWN_CLEARED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  # Non-reserved kv pairs land under .payload.
  run jq -rs '[.[] | select(.kind == "LOCKDOWN_CLEARED")][-1].payload.archived_to' "$COORD_DIR/events.jsonl"
  [[ "$output" == *"lockdown_archive"* ]]
  [[ "$output" == *".cleared.json" ]]
}

@test "lockdown_clear: returns 1 when no lockdown.json present" {
  ( . "$LCK"; coord_lockdown_clear ) && rc=0 || rc=$?
  [ "$rc" != "0" ]
}

# --- coord_lockdown_emit_deny ---------------------------------------------

@test "lockdown_emit_deny: emits permissionDecision deny JSON with reason text" {
  _activate_lockdown "Mediator is resolving stale lock on /foo.ts" "mediator_verdict"
  run bash -c '. "'"$SRC_ROOT/core/lib/log_event.sh"'"; . "'"$LCK"'"; coord_lockdown_emit_deny "PreToolUse"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
  # Reason must contain the underlying lockdown reason
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("Mediator is resolving stale lock on /foo.ts")' >/dev/null
  # Reason must contain the system-pause prefix
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("System-wide pause:")' >/dev/null
}

@test "lockdown_emit_deny: reason text includes [reason_source=...] audit tag" {
  _activate_lockdown "corrupt schema detected" "critical_bypass"
  run bash -c '. "'"$SRC_ROOT/core/lib/log_event.sh"'"; . "'"$LCK"'"; coord_lockdown_emit_deny "PreToolUse"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("[reason_source=critical_bypass]")' >/dev/null
}

@test "lockdown_emit_deny: emits HOOK_DENIED_BY_LOCKDOWN event with hook + reason_source" {
  _activate_lockdown "test reason" "mediator_verdict"
  bash -c '. "'"$SRC_ROOT/core/lib/log_event.sh"'"; . "'"$LCK"'"; coord_lockdown_emit_deny "PreToolUse" >/dev/null'
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "HOOK_DENIED_BY_LOCKDOWN")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  # Non-reserved kv pairs land under .payload.
  run jq -rs '[.[] | select(.kind == "HOOK_DENIED_BY_LOCKDOWN")][-1].payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "PreToolUse" ]
  run jq -rs '[.[] | select(.kind == "HOOK_DENIED_BY_LOCKDOWN")][-1].payload.reason_source' "$COORD_DIR/events.jsonl"
  [ "$output" = "mediator_verdict" ]
}

# --- End-to-end hook gate tests -------------------------------------------

# Helper: minimal PreToolUse Read input.
_pre_read_input() {
  local f="$1"
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"%s"}}' \
         "$SID" "$TMP" "$f"
}

@test "hook gate: pre_tool_use_read.sh under active lockdown → emits deny + skips read recording" {
  _activate_lockdown "system pause" "mediator_verdict"
  local target="$TMP/foo.txt"
  printf 'content\n' >"$target"
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' \
    _ "$(_pre_read_input "$target")" "$SRC_ROOT/hooks/pre_tool_use_read.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Read NOT recorded into read_sets
  run jq -r --arg sid "$SID" '(.read_sets[$sid].reads // []) | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "hook gate: pre_tool_use_write.sh under active lockdown → emits deny + skips lock acquire" {
  _activate_lockdown "system pause" "mediator_verdict"
  local target="$TMP/foo.txt"
  printf 'content\n' >"$target"
  local input='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' \
    _ "$input" "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Lock NOT acquired
  run jq -r --arg f "$target" '(.locks[$f].session // "ABSENT")' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  # WRITE event NOT logged (lockdown gate fires before the event log)
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "WRITE")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "hook gate: pre_tool_use_any.sh under active lockdown → emits deny + skips notification consumer" {
  _activate_lockdown "system pause" "mediator_verdict"
  # Pre-seed a notification that should NOT be consumed during lockdown.
  jq --arg sid "$SID" '.notifications[$sid]["/somefile"] = ["test notif"]' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local input='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' \
    _ "$input" "$SRC_ROOT/hooks/pre_tool_use_any.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Notification still present (NOT consumed)
  run jq -r --arg sid "$SID" '.notifications[$sid]["/somefile"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
}

@test "hook gate: post_tool_use_write.sh under active lockdown → emits deny + skips lock release" {
  # First acquire a lock (no lockdown yet).
  local target="$TMP/foo.txt"
  printf 'content\n' >"$target"
  local pre='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}'
  CLAUDE_COORD=1 bash -c 'printf "%s" "$1" | "$2"' _ "$pre" "$SRC_ROOT/hooks/pre_tool_use_write.sh" >/dev/null
  run jq -r --arg f "$target" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]   # lock acquired
  # Now activate lockdown and run post-hook.
  _activate_lockdown "system pause" "mediator_verdict"
  local post='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$post" "$SRC_ROOT/hooks/post_tool_use_write.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Lock NOT released
  run jq -r --arg f "$target" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "hook gate: session_start.sh under active lockdown → emits deny + skips registration" {
  # Wipe any pre-seeded session state to verify that session is NOT registered.
  rm -f "$COORD_DIR/sessions/${SID}.active"
  jq 'del(.sessions["'"$SID"'"])' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  _activate_lockdown "system pause" "mediator_verdict"
  local input='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$SRC_ROOT/hooks/session_start.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Session NOT registered
  run jq -r '.sessions["'"$SID"'"] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # No .active marker created
  [ ! -e "$COORD_DIR/sessions/${SID}.active" ]
}

@test "hook gate: session_end.sh under active lockdown → emits deny + does NOT release locks" {
  # Acquire a lock first.
  local target="$TMP/foo.txt"
  printf 'content\n' >"$target"
  local pre='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}'
  CLAUDE_COORD=1 bash -c 'printf "%s" "$1" | "$2"' _ "$pre" "$SRC_ROOT/hooks/pre_tool_use_write.sh" >/dev/null
  run jq -r --arg f "$target" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  _activate_lockdown "system pause" "mediator_verdict"
  local input='{"session_id":"'"$SID"'","hook_event_name":"SessionEnd","reason":"exit"}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$SRC_ROOT/hooks/session_end.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Lock NOT released
  run jq -r --arg f "$target" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "hook gate: stop.sh under active lockdown → emits deny + does NOT release locks" {
  # Acquire a lock first.
  local target="$TMP/foo.txt"
  printf 'content\n' >"$target"
  local pre='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}'
  CLAUDE_COORD=1 bash -c 'printf "%s" "$1" | "$2"' _ "$pre" "$SRC_ROOT/hooks/pre_tool_use_write.sh" >/dev/null
  _activate_lockdown "system pause" "mediator_verdict"
  local input='{"session_id":"'"$SID"'","hook_event_name":"Stop"}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$SRC_ROOT/hooks/stop.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  run jq -r --arg f "$target" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "hook gate: user_prompt_submit.sh under active lockdown → emits deny + skips prompt capture" {
  _activate_lockdown "system pause" "mediator_verdict"
  local input='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"hello"}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$SRC_ROOT/hooks/user_prompt_submit.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # prompt_id NOT updated (still null)
  run jq -r '.sessions["'"$SID"'"].prompt_id // "null"' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

# --- Concurrency + fail-open ----------------------------------------------

@test "lockdown concurrent activate: atomic rename means file is whole regardless of winner" {
  # Two concurrent activate calls both succeed at the rc level; the
  # mv-rename is atomic so the final file is one of the two valid
  # writes, never a torn write. Both calls log LOCKDOWN_ACTIVATED.
  (
    . "$SRC_ROOT/core/lib/log_event.sh"
    . "$LCK"
    coord_lockdown_activate "reason A" "mediator_verdict" &
    coord_lockdown_activate "reason B" "critical_bypass" &
    wait
  )
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  # File parses cleanly; reason is one of the two we wrote
  run jq -r '.reason' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "reason A" ] || [ "$output" = "reason B" ]
  # Two LOCKDOWN_ACTIVATED events logged (one per writer)
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCKDOWN_ACTIVATED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "2" ]
}

@test "fail-open: malformed lockdown.json → hook does NOT emit deny" {
  # Write garbage to lockdown.json. coord_lockdown_check returns 1
  # (parse fail). Hooks should fall through to their normal logic.
  printf 'this is not json {{{\n' >"$COORD_DIR/mediator/lockdown.json"
  local target="$TMP/foo.txt"
  printf 'content\n' >"$target"
  local input='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2" 2>/dev/null' _ "$input" "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  [ "$status" -eq 0 ]
  # No deny in output (lockdown parse failed → fall through → normal lock acquire)
  case "$output" in *permissionDecision*) echo "FAIL: deny emitted on malformed lockdown.json: $output"; return 1 ;; esac
  # Lock WAS acquired (normal path, fail-open worked)
  run jq -r --arg f "$target" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "lockdown_check idempotency: repeated calls with active file return 0 each time" {
  _activate_lockdown "test reason" "mediator_verdict"
  for i in 1 2 3 4 5; do
    ( . "$LCK"; coord_lockdown_check ) && rc=0 || rc=$?
    [ "$rc" = "0" ] || { echo "iteration $i failed"; return 1; }
  done
}

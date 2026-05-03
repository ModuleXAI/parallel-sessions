#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/session_start.sh — PR D.1.
#
# Mirror coverage of src/tests/unit/session_start.bats (the Claude variant)
# adapted for Codex semantics:
#   - COORD_ENABLED=1 is the participation gate (vs CLAUDE_COORD).
#   - Codex source enum is {startup, resume, clear}; no `compact` per D-11.
#     Unknown sources fall through to startup (forward-tolerance).
#   - Rows are written with agent="codex" (vs "claude_code").
#   - No subagent filter per D-2: an `agent_type` field on the input does NOT
#     suppress registration (Codex registers every session as its own coord
#     session).
#   - Lockdown gate identical to Claude (deny envelope + skip registration).

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/session_start.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-sessstart-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED
  (
    cd "$TMP"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'a\n' >a.txt
    git add a.txt
    git commit -q -m one
  )
  HEAD_A=$(git -C "$TMP" rev-parse HEAD)
  # Canonical Codex SessionStart inputs (shape per
  # codex-rs/hooks/schema/generated/session-start.command.input.schema.json,
  # trimmed to the fields the hook actually reads).
  INPUT_PARENT='{"session_id":"cx-sid-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  # Even with an `agent_type` field (which Codex would never emit), the hook
  # MUST register — D-2: Codex has no subagent concept; the translator's
  # extract_subagent is permanently rc=1.
  INPUT_AGENT_TYPE='{"session_id":"cx-sub-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup","agent_type":"general-purpose"}'
  INPUT_NO_SID='{"cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED
  rm -rf "$TMP"
}

# Helper: write a synthetic active lockdown.json (mirrors lockdown.bats).
_activate_lockdown() {
  local reason="$1" reason_source="$2"
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$reason" --arg rs "$reason_source" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

@test "codex session_start: COORD_ENABLED unset → exit 0, no state change" {
  run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -e "$COORD_DIR/sessions/cx-sid-0001.active" ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "codex session_start: participant registers row + marker + banner + agent=codex" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  # Output must be valid JSON with hookSpecificOutput.additionalContext.
  [ -n "$output" ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null
  # Marker file present
  [ -e "$COORD_DIR/sessions/cx-sid-0001.active" ]
  # sessions.json row populated with required keys, agent=codex
  run jq -r '.sessions["cx-sid-0001"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  run jq -r '.sessions["cx-sid-0001"].agent' "$COORD_DIR/sessions.json"
  [ "$output" = "codex" ]
  run jq -r '.sessions["cx-sid-0001"] | .pid | tostring | test("^[0-9]+$")' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  run jq -r '.sessions["cx-sid-0001"].script_version' "$COORD_DIR/sessions.json"
  [ "$output" = "1.0" ]
  run jq -r '.sessions["cx-sid-0001"].registered_at' "$COORD_DIR/sessions.json"
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]
}

@test "codex session_start: input with agent_type DOES register (D-2: no subagent filter)" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT_AGENT_TYPE' | '$H'"
  [ "$status" -eq 0 ]
  # Row IS created (Codex has no subagent concept; agent_type is an unknown
  # field that the translator ignores).
  [ -e "$COORD_DIR/sessions/cx-sub-0001.active" ]
  run jq -r '.sessions["cx-sub-0001"].agent' "$COORD_DIR/sessions.json"
  [ "$output" = "codex" ]
  # SUBAGENT_ACTIVITY_SKIPPED MUST NOT appear in the event log.
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "SUBAGENT_ACTIVITY_SKIPPED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "codex session_start: stdin without session_id → exit 0, no crash, no registration" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT_NO_SID' | '$H'"
  [ "$status" -eq 0 ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "codex session_start: second call refreshes registered_at once, updates last_activity_at" {
  COORD_ENABLED=1 bash -c "echo '$INPUT_PARENT' | '$H'" >/dev/null
  local first_reg
  first_reg=$(jq -r '.sessions["cx-sid-0001"].registered_at' "$COORD_DIR/sessions.json")
  sleep 0.05
  COORD_ENABLED=1 bash -c "echo '$INPUT_PARENT' | '$H'" >/dev/null
  run jq -r '.sessions["cx-sid-0001"].registered_at' "$COORD_DIR/sessions.json"
  [ "$output" = "$first_reg" ]
}

# -------- Source matrix (Codex: startup|resume|clear; D-11: no compact) --------

@test "codex session_start source=resume: refreshes existing row, preserves registered_at + read_set" {
  jq --arg sid cx-sid-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "Thu Jan  1 00:00:00 2026",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0", agent: "codex"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa", at: "2026-04-01T00:00:00Z", is_latest: true}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_RESUME='{"session_id":"cx-sid-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  COORD_ENABLED=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  # registered_at unchanged
  run jq -r '.sessions["cx-sid-0001"].registered_at' "$COORD_DIR/sessions.json"
  [ "$output" = "2026-04-01T00:00:00Z" ]
  # pid refreshed
  run jq -r '.sessions["cx-sid-0001"].pid' "$COORD_DIR/sessions.json"
  [ "$output" != "11111" ]
  # Read-set intact, NOT marked superseded_by_head_change
  run jq -r '.read_sets["cx-sid-0001"].reads | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r '.read_sets["cx-sid-0001"].reads[0].superseded_by_head_change // false' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
}

@test "codex session_start source=resume: HEAD drift marks read_set superseded_by_head_change + HEAD_CHANGE event" {
  jq --arg sid cx-sid-0001 --arg head "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0", agent: "codex"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa"}, {path: "/tmp/bar.ts", hash: "bbb"}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_RESUME='{"session_id":"cx-sid-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  COORD_ENABLED=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  run jq -r '[.read_sets["cx-sid-0001"].reads[] | .superseded_by_head_change] | all' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "codex session_start source=resume with no prior row: SESSION_REGISTER reason=resume_without_prior_row" {
  local INPUT_RESUME='{"session_id":"cx-new-resume","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  COORD_ENABLED=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  # New row materialized with agent=codex
  run jq -r '.sessions["cx-new-resume"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  run jq -r '.sessions["cx-new-resume"].agent' "$COORD_DIR/sessions.json"
  [ "$output" = "codex" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SESSION_REGISTER" ]
  run jq -rs 'last | .payload.reason' "$COORD_DIR/events.jsonl"
  [ "$output" = "resume_without_prior_row" ]
}

@test "codex session_start source=resume: orphan lock → RESUME_ORPHAN_LOCK_DETECTED event (lock retained)" {
  jq --arg sid cx-sid-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 99999, pid_lstart: "Stale Process Lstart",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0", agent: "codex"
    }
    | .locks["/tmp/orphan.ts"] = {session: $sid, pid: 99999, pid_lstart: "Stale Process Lstart", acquired_at: "2026-04-01T00:00:00Z", last_refresh_at: "2026-04-01T00:00:00Z", tasks: []}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_RESUME='{"session_id":"cx-sid-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  COORD_ENABLED=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "RESUME_ORPHAN_LOCK_DETECTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run jq -rs '[.[] | select(.kind == "RESUME_ORPHAN_LOCK_DETECTED")][0].file' "$COORD_DIR/events.jsonl"
  [ "$output" = "/tmp/orphan.ts" ]
  run jq -rs '[.[] | select(.kind == "RESUME_ORPHAN_LOCK_DETECTED")][0].payload.old_pid' "$COORD_DIR/events.jsonl"
  [ "$output" = "99999" ]
  # Lock NOT released (Phase 3 watchdog evicts).
  run jq -r '.locks["/tmp/orphan.ts"] | type' "$COORD_DIR/sessions.json"
  [ "$output" = "object" ]
}

@test "codex session_start source=clear: marks read_set entries superseded_by=new_prompt + resets prompt_id" {
  jq --arg sid cx-sid-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: "old-prompt-hash", script_version: "1.0", agent: "codex"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa"}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_CLEAR='{"session_id":"cx-sid-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"clear"}'
  COORD_ENABLED=1 bash -c "echo '$INPUT_CLEAR' | '$H'" >/dev/null
  run jq -r '.read_sets["cx-sid-0001"].reads[0].superseded_by' "$COORD_DIR/sessions.json"
  [ "$output" = "new_prompt" ]
  run jq -r '.sessions["cx-sid-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "SESSION_CLEAR")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "codex session_start source=compact (D-11: not in spec): warns, treats as startup, registers" {
  # D-11: Codex spec excludes the `compact` source (Claude-only). For
  # forward-tolerance the hook treats any unknown source as startup —
  # the row IS created, the warning is on stderr, and NO Claude-style
  # SESSION_COMPACTED event is emitted.
  local INPUT_COMPACT='{"session_id":"cx-sid-compact","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"compact"}'
  COORD_ENABLED=1 run bash -c "echo '$INPUT_COMPACT' | '$H'"
  [ "$status" -eq 0 ]
  # Row materialized as a startup
  run jq -r '.sessions["cx-sid-compact"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  run jq -r '.sessions["cx-sid-compact"].agent' "$COORD_DIR/sessions.json"
  [ "$output" = "codex" ]
  # Last event is SESSION_REGISTER (startup branch), NOT SESSION_COMPACTED.
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SESSION_REGISTER" ]
  run jq -rs '[.[] | select(.kind == "SESSION_COMPACTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "codex session_start: under active lockdown → emits deny + skips registration" {
  _activate_lockdown "system pause" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  # Session NOT registered
  run jq -r '.sessions["cx-sid-0001"] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # No .active marker
  [ ! -e "$COORD_DIR/sessions/cx-sid-0001.active" ]
}

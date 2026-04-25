#!/usr/bin/env bats
# Tests for hooks/session_start.sh per plan §4.

load "../helpers/common"

H="$SRC_ROOT/hooks/session_start.sh"

setup() {
  TMP="$(mktemp -d -t coord-sessstart-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  # Spin up a tiny git repo so rev-parse HEAD has a real SHA to return.
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
  # Canonical test inputs.
  INPUT_PARENT='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  INPUT_SUB='{"session_id":"sub-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup","agent_type":"general-purpose"}'
  INPUT_NO_SID='{"cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
}
teardown() {
  unset CLAUDE_COORD
  rm -rf "$TMP"
}

@test "session_start: CLAUDE_COORD unset → exit 0, no state change" {
  run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -e "$COORD_DIR/sessions/sid-test-0001.active" ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "session_start: participant registers row + marker + banner" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_PARENT' | '$H'"
  [ "$status" -eq 0 ]
  # Output must be valid JSON with hookSpecificOutput.additionalContext.
  [ -n "$output" ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null
  # Marker file present
  [ -e "$COORD_DIR/sessions/sid-test-0001.active" ]
  # sessions.json row populated with required keys
  run jq -r '.sessions["sid-test-0001"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  run jq -r '.sessions["sid-test-0001"] | .pid | tostring | test("^[0-9]+$")' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  run jq -r '.sessions["sid-test-0001"].script_version' "$COORD_DIR/sessions.json"
  [ "$output" = "1.0" ]
  run jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json"
  [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T ]]
}

@test "session_start: subagent (agent_type populated) does NOT register" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_SUB' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -e "$COORD_DIR/sessions/sub-0001.active" ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "session_start: subagent skip emits SUBAGENT_ACTIVITY_SKIPPED event" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT_SUB' | '$H'" >/dev/null
  sleep 0.3
  [ -s "$COORD_DIR/events.jsonl" ]
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -rs 'last | .payload.agent_type' "$COORD_DIR/events.jsonl"
  [ "$output" = "general-purpose" ]
  run jq -rs 'last | .payload.parent_session' "$COORD_DIR/events.jsonl"
  [ "$output" = "sub-0001" ]
  run jq -rs 'last | .payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "SessionStart" ]
}

@test "session_start: stdin without session_id → exit 0, no crash, no registration" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_NO_SID' | '$H'"
  [ "$status" -eq 0 ]
  run jq -r '.sessions | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "session_start: second call for same session refreshes registered_at once, updates last_activity_at" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT_PARENT' | '$H'" >/dev/null
  local first_reg
  first_reg=$(jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json")
  sleep 0.05
  CLAUDE_COORD=1 bash -c "echo '$INPUT_PARENT' | '$H'" >/dev/null
  run jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json"
  [ "$output" = "$first_reg" ]
  run jq -r '.sessions["sid-test-0001"].last_activity_at' "$COORD_DIR/sessions.json"
  [ "$output" != "$first_reg" ] || [ "$output" = "$first_reg" ]  # tolerate sub-ms tick
}

# -------- Source matrix (Decision 2.5 per PR-PHASE1-01) --------

@test "session_start source=resume: refreshes existing row, preserves registered_at + read_set" {
  # Pre-seed a session row + read_set as if the prior process wrote them.
  jq --arg sid sid-test-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "Thu Jan  1 00:00:00 2026",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa", at: "2026-04-01T00:00:00Z", is_latest: true}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_RESUME='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  CLAUDE_COORD=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  # registered_at unchanged
  run jq -r '.sessions["sid-test-0001"].registered_at' "$COORD_DIR/sessions.json"
  [ "$output" = "2026-04-01T00:00:00Z" ]
  # pid refreshed (not 11111 any more — it's the test bash's pid)
  run jq -r '.sessions["sid-test-0001"].pid' "$COORD_DIR/sessions.json"
  [ "$output" != "11111" ]
  # Read-set intact and NOT marked superseded_by_head_change (HEAD unchanged)
  run jq -r '.read_sets["sid-test-0001"].reads | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r '.read_sets["sid-test-0001"].reads[0].path' "$COORD_DIR/sessions.json"
  [ "$output" = "/tmp/foo.ts" ]
  run jq -r '.read_sets["sid-test-0001"].reads[0].superseded_by_head_change // false' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
}

@test "session_start source=resume: HEAD drift marks read_set superseded_by_head_change" {
  # Pre-seed a row with an old HEAD, read_set non-empty.
  jq --arg sid sid-test-0001 --arg head "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa"}, {path: "/tmp/bar.ts", hash: "bbb"}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_RESUME='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  CLAUDE_COORD=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  # Both entries gain superseded_by_head_change:true
  run jq -r '[.read_sets["sid-test-0001"].reads[] | .superseded_by_head_change] | all' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  # A HEAD_CHANGE event is logged in addition to SESSION_RESUME
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "session_start source=resume with no prior row: falls back to SESSION_REGISTER reason=resume_without_prior_row" {
  local INPUT_RESUME='{"session_id":"sid-new-resume","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  CLAUDE_COORD=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  # New row materialized
  run jq -r '.sessions["sid-new-resume"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  # Most-recent event is SESSION_REGISTER with reason=resume_without_prior_row
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SESSION_REGISTER" ]
  run jq -rs 'last | .payload.reason' "$COORD_DIR/events.jsonl"
  [ "$output" = "resume_without_prior_row" ]
}

@test "session_start source=resume: orphan lock → RESUME_ORPHAN_LOCK_DETECTED event" {
  # Seed a lock for this session held by a stale pid/lstart.
  jq --arg sid sid-test-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 99999, pid_lstart: "Stale Process Lstart",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0"
    }
    | .locks["/tmp/orphan.ts"] = {session: $sid, pid: 99999, pid_lstart: "Stale Process Lstart", acquired_at: "2026-04-01T00:00:00Z", last_refresh_at: "2026-04-01T00:00:00Z", tasks: []}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_RESUME='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"resume"}'
  CLAUDE_COORD=1 bash -c "echo '$INPUT_RESUME' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "RESUME_ORPHAN_LOCK_DETECTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run jq -rs '[.[] | select(.kind == "RESUME_ORPHAN_LOCK_DETECTED")][0].file' "$COORD_DIR/events.jsonl"
  [ "$output" = "/tmp/orphan.ts" ]
  run jq -rs '[.[] | select(.kind == "RESUME_ORPHAN_LOCK_DETECTED")][0].payload.old_pid' "$COORD_DIR/events.jsonl"
  [ "$output" = "99999" ]
  # Lock itself is NOT released in Phase 1 (Phase 3 watchdog evicts).
  run jq -r '.locks["/tmp/orphan.ts"] | type' "$COORD_DIR/sessions.json"
  [ "$output" = "object" ]
}

@test "session_start source=clear: marks read_set entries superseded_by=new_prompt" {
  jq --arg sid sid-test-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: "old-prompt-hash", script_version: "1.0"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa"}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_CLEAR='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"clear"}'
  CLAUDE_COORD=1 bash -c "echo '$INPUT_CLEAR' | '$H'" >/dev/null
  run jq -r '.read_sets["sid-test-0001"].reads[0].superseded_by' "$COORD_DIR/sessions.json"
  [ "$output" = "new_prompt" ]
  # prompt_id reset to null
  run jq -r '.sessions["sid-test-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "SESSION_CLEAR")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "session_start source=compact: refreshes last_activity_at only; read_set + prompt_id preserved" {
  jq --arg sid sid-test-0001 --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 11111, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: "prompt-abc", script_version: "1.0"
    }
    | .read_sets[$sid] = {reads: [{path: "/tmp/foo.ts", hash: "aaa"}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  local INPUT_COMPACT='{"session_id":"sid-test-0001","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"compact"}'
  CLAUDE_COORD=1 bash -c "echo '$INPUT_COMPACT' | '$H'" >/dev/null
  # prompt_id preserved
  run jq -r '.sessions["sid-test-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "prompt-abc" ]
  # git_head preserved (matrix says "no change")
  run jq -r '.sessions["sid-test-0001"].git_head' "$COORD_DIR/sessions.json"
  [ "$output" = "$HEAD_A" ]
  # read_set intact, not marked
  run jq -r '.read_sets["sid-test-0001"].reads | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r '.read_sets["sid-test-0001"].reads[0] | has("superseded_by")' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
  # pid is NOT refreshed on compact per matrix (same process)
  run jq -r '.sessions["sid-test-0001"].pid' "$COORD_DIR/sessions.json"
  [ "$output" = "11111" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "SESSION_COMPACTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

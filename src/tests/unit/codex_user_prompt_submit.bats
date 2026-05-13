#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/user_prompt_submit.sh — PR D.3.
#
# Mirror of src/tests/unit/user_prompt_submit.bats adapted for Codex:
#   - COORD_ENABLED=1 is the participation gate.
#   - No subagent filter per D-2: an `agent_type` field on the input does NOT
#     suppress prompt capture (Codex has no subagent concept).
#   - Lockdown gate identical to Claude (deny envelope + skip capture).
#   - Banner envelope is hookSpecificOutput.additionalContext (same shape as
#     Claude — Codex respects it).

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/user_prompt_submit.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-ups-XXXX)"
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

  SID="cx-ups-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 1234, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0", agent: "codex"
    }
    | .read_sets[$sid] = {reads: [
        {path: "/tmp/foo.ts", hash: "aaa", is_latest: true},
        {path: "/tmp/bar.ts", hash: "bbb", is_latest: true}
      ]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"hello world this is a prompt"}'
  INPUT_AGENT_TYPE='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"x","agent_type":"general-purpose"}'
  INPUT_NONPART='{"session_id":"not-a-participant","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"x"}'
}

teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

_activate_lockdown() {
  local reason="$1" reason_source="$2"
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$reason" --arg rs "$reason_source" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

# === Gate / no-op paths ===

@test "codex user_prompt_submit: COORD_ENABLED unset → exit 0, no state change" {
  run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run jq -r --arg s "$SID" '.sessions[$s].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

@test "codex user_prompt_submit: input with agent_type DOES capture (D-2: no subagent filter)" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT_AGENT_TYPE' | '$H'"
  [ "$status" -eq 0 ]
  # prompt_id IS populated despite agent_type field present.
  run jq -r --arg s "$SID" '.sessions[$s].prompt_id' "$COORD_DIR/sessions.json"
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
  # SUBAGENT_ACTIVITY_SKIPPED MUST NOT appear in events.
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "SUBAGENT_ACTIVITY_SKIPPED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "codex user_prompt_submit: non-participant (no marker) → no-op" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT_NONPART' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run jq -r '.sessions["not-a-participant"] // "absent"' "$COORD_DIR/sessions.json"
  [ "$output" = "absent" ]
}

# === Happy path ===

@test "codex user_prompt_submit: participant records prompt_id + invalidates read-set + caches env + PROMPT_SUBMIT event" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # prompt_id is a 64-hex sha256.
  run jq -r --arg s "$SID" '.sessions[$s].prompt_id' "$COORD_DIR/sessions.json"
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
  # Both read-set entries marked superseded_by="new_prompt".
  run jq -r --arg s "$SID" '[.read_sets[$s].reads[] | .superseded_by] | unique' "$COORD_DIR/sessions.json"
  [ "$output" = '[
  "new_prompt"
]' ]
  # No HEAD-drift mark (HEAD did not drift).
  run jq -r --arg s "$SID" '[.read_sets[$s].reads[] | has("superseded_by_head_change")] | any' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
  # last_activity_at advanced past seeded value.
  run jq -r --arg s "$SID" '.sessions[$s].last_activity_at' "$COORD_DIR/sessions.json"
  [ "$output" != "2026-04-01T00:00:00Z" ]
  # Env file written with COORD_PROMPT_ID.
  [ -f "$COORD_DIR/sessions/${SID}.env" ]
  run grep -c '^COORD_PROMPT_ID=' "$COORD_DIR/sessions/${SID}.env"
  [ "$output" = "1" ]
  # PROMPT_SUBMIT event logged.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "PROMPT_SUBMIT")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

# === HEAD drift handling ===

@test "codex user_prompt_submit: HEAD drift → superseded_by_head_change + HEAD_CHANGE event + additionalContext" {
  (
    cd "$TMP"
    printf 'b\n' >a.txt
    git commit -q -am two
  )
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # additionalContext envelope mentions HEAD change.
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("HEAD changed")' >/dev/null
  # Read-set entries also marked superseded_by_head_change.
  run jq -r --arg s "$SID" '[.read_sets[$s].reads[] | .superseded_by_head_change] | all' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  # HEAD_CHANGE event logged with source=user_prompt_submit.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE" and .payload.source == "user_prompt_submit")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "codex user_prompt_submit: no HEAD drift → no HEAD-change additionalContext" {
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # Stdout is either empty OR an additionalContext that does NOT mention HEAD.
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | test("HEAD changed") | not' >/dev/null
  fi
}

# === Lockdown gate ===

@test "codex user_prompt_submit: under active lockdown → emits deny + no prompt_id update" {
  _activate_lockdown "system pause" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null
  # prompt_id stays null — capture was skipped.
  run jq -r --arg s "$SID" '.sessions[$s].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # Read-set entries NOT marked superseded.
  run jq -r --arg s "$SID" '[.read_sets[$s].reads[] | has("superseded_by")] | any' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
}

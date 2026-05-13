#!/usr/bin/env bats
# Tests for hooks/user_prompt_submit.sh per plan §4 + CLAUDE.md §B.9.6.

load "../helpers/common"

H="$SRC_ROOT/adapters/claude-code/hooks/user_prompt_submit.sh"

setup() {
  TMP="$(mktemp -d -t coord-ups-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  # Register a primary session + .active marker + initial row with a HEAD.
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

  SID="sid-ups-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" --arg head "$HEAD_A" '
    .sessions[$sid] = {
      state: "ACTIVE", pid: 1234, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z", last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0"
    }
    | .read_sets[$sid] = {reads: [
        {path: "/tmp/foo.ts", hash: "aaa", is_latest: true},
        {path: "/tmp/bar.ts", hash: "bbb", is_latest: true}
      ]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"hello world this is a prompt"}'
  INPUT_SUB='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"x","agent_type":"general-purpose"}'
  INPUT_NONPART='{"session_id":"not-a-participant","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":"x"}'
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

@test "user_prompt_submit: CLAUDE_COORD unset → exit 0, no state change" {
  run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run jq -r '.sessions["sid-ups-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

@test "user_prompt_submit: subagent event emits SUBAGENT_ACTIVITY_SKIPPED + does not mutate" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT_SUB' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -r '.sessions["sid-ups-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

@test "user_prompt_submit: non-participant → no-op" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT_NONPART' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # No prompt_id on a session that was never registered.
  run jq -r '.sessions["not-a-participant"] // "absent"' "$COORD_DIR/sessions.json"
  [ "$output" = "absent" ]
}

@test "user_prompt_submit: participant records prompt_id + invalidates read-set" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # prompt_id populated with a 64-hex sha256 digest
  run jq -r '.sessions["sid-ups-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [[ "$output" =~ ^[a-f0-9]{64}$ ]]
  # Both read-set entries now have superseded_by="new_prompt"
  run jq -r '[.read_sets["sid-ups-0001"].reads[] | .superseded_by] | unique' "$COORD_DIR/sessions.json"
  [ "$output" = '[
  "new_prompt"
]' ]
  # No superseded_by_head_change (HEAD did not drift)
  run jq -r '[.read_sets["sid-ups-0001"].reads[] | has("superseded_by_head_change")] | any' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
}

@test "user_prompt_submit: PROMPT_SUBMIT event logged" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT' | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "PROMPT_SUBMIT")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "user_prompt_submit: prompt digest cached to .coord/sessions/<id>.env" {
  CLAUDE_COORD=1 bash -c "echo '$INPUT' | '$H'" >/dev/null
  [ -f "$COORD_DIR/sessions/sid-ups-0001.env" ]
  run grep -c '^COORD_PROMPT_ID=' "$COORD_DIR/sessions/sid-ups-0001.env"
  [ "$output" = "1" ]
}

@test "user_prompt_submit: HEAD drift → superseded_by_head_change + HEAD_CHANGE event + additionalContext" {
  # Advance HEAD so current != stored.
  (
    cd "$TMP"
    printf 'b\n' >a.txt
    git commit -q -am two
  )
  CLAUDE_COORD=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # additionalContext mentions HEAD change
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("HEAD changed")' >/dev/null
  # read-set entries marked
  run jq -r '[.read_sets["sid-ups-0001"].reads[] | .superseded_by_head_change] | all' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  # HEAD_CHANGE event logged
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE" and .payload.source == "user_prompt_submit")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "user_prompt_submit: no HEAD drift → no additionalContext emitted" {
  CLAUDE_COORD=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # Stdout either empty or does NOT contain a HEAD-changed additionalContext.
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | test("HEAD changed") | not' >/dev/null
  fi
}

@test "user_prompt_submit: empty prompt still captures + refreshes HEAD" {
  local EMPTY_INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"UserPromptSubmit","prompt":""}'
  CLAUDE_COORD=1 bash -c "echo '$EMPTY_INPUT' | '$H'" >/dev/null
  # prompt_id stays empty (no hash of empty input) but row was touched
  run jq -r '.sessions["sid-ups-0001"].prompt_id' "$COORD_DIR/sessions.json"
  [ "$output" = "" ]
  # last_activity_at advanced past the seeded "2026-04-01T00:00:00Z"
  run jq -r '.sessions["sid-ups-0001"].last_activity_at' "$COORD_DIR/sessions.json"
  [ "$output" != "2026-04-01T00:00:00Z" ]
}

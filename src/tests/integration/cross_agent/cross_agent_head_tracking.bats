#!/usr/bin/env bats
# Cross-agent HEAD tracking scenarios (PR F.2 — reviewer scenario #6).
#
# Each session tracks its own git_head independently in the shared
# sessions.json. When the repo HEAD advances mid-session, the next
# pre_tool_use_any.sh invocation MUST detect the drift and update the
# stored value. Validates that:
#   - Claude session's any hook updates its own git_head on drift.
#   - Codex session's any hook updates its own git_head on drift.
#   - Updates are independent: one agent's update does not perturb the
#     other agent's stored HEAD.
#   - HEAD_CHANGE event is emitted with source=pre_tool_use_any in both
#     agent paths.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
  # Make a real commit so the repo has a HEAD; capture HEAD_A.
  ( cd "$XAGENT_TMP" && \
       printf 'a\n' >a.txt && git add a.txt && git commit -q -m one )
  HEAD_A=$(git -C "$XAGENT_TMP" rev-parse HEAD)
}
teardown() { xagent_teardown; }

# Helper: register session at HEAD_A by directly seeding the row, since
# session_start would set git_head = whatever git rev-parse returns NOW
# (which we want to be HEAD_A — already true, but seeding makes intent
# explicit).
_seed_session_at_head() {
  local sid="$1" agent="$2" head="$3"
  jq --arg s "$sid" --arg a "$agent" --arg h "$head" '
    .sessions[$s] = {
      state: "ACTIVE", pid: 1, pid_lstart: "x",
      registered_at: "y", last_activity_at: "z",
      git_head: $h, prompt_id: null, script_version: "1.0", agent: $a
    }
  ' "$COORD_DIR/sessions.json" > "$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  touch "$COORD_DIR/sessions/${sid}.active"
}

@test "head_tracking: claude any hook updates stored HEAD on drift" {
  _seed_session_at_head "ch-head1" "claude_code" "$HEAD_A"
  # Advance HEAD.
  ( cd "$XAGENT_TMP" && printf 'b\n' >a.txt && git commit -q -am two )
  local HEAD_B
  HEAD_B=$(git -C "$XAGENT_TMP" rev-parse HEAD)
  [ "$HEAD_A" != "$HEAD_B" ]
  # Trigger any hook.
  xagent_pretooluse_any claude_code "ch-head1"
  sleep 0.3
  # Stored HEAD now matches HEAD_B.
  run jq -r '.sessions["ch-head1"].git_head' "$COORD_DIR/sessions.json"
  [ "$output" = "$HEAD_B" ]
  # HEAD_CHANGE event logged from pre_tool_use_any.
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE" and .session == "ch-head1" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "head_tracking: codex any hook updates stored HEAD on drift (no banner per D-D4-02)" {
  _seed_session_at_head "cx-head1" "codex" "$HEAD_A"
  ( cd "$XAGENT_TMP" && printf 'b\n' >a.txt && git commit -q -am two )
  local HEAD_B
  HEAD_B=$(git -C "$XAGENT_TMP" rev-parse HEAD)
  xagent_pretooluse_any codex "cx-head1"
  sleep 0.3
  # Stored HEAD updated.
  run jq -r '.sessions["cx-head1"].git_head' "$COORD_DIR/sessions.json"
  [ "$output" = "$HEAD_B" ]
  # HEAD_CHANGE event logged.
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE" and .session == "cx-head1" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # D-D4-02 invariant: NO additionalContext on stdout (codex any hook
  # is bookkeeping-only).
  if [ -n "$XAGENT_LAST_OUTPUT" ]; then
    echo "$XAGENT_LAST_OUTPUT" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
}

@test "head_tracking: cross-agent independence — updating claude's HEAD does NOT alter codex's stored HEAD" {
  _seed_session_at_head "ch-iso1" "claude_code" "$HEAD_A"
  _seed_session_at_head "cx-iso1" "codex"       "$HEAD_A"
  ( cd "$XAGENT_TMP" && printf 'b\n' >a.txt && git commit -q -am two )
  local HEAD_B
  HEAD_B=$(git -C "$XAGENT_TMP" rev-parse HEAD)
  # Trigger ONLY claude's any hook.
  xagent_pretooluse_any claude_code "ch-iso1"
  sleep 0.2
  # Claude updated.
  run jq -r '.sessions["ch-iso1"].git_head' "$COORD_DIR/sessions.json"
  [ "$output" = "$HEAD_B" ]
  # Codex's stored HEAD is still HEAD_A — no cross-agent leak.
  run jq -r '.sessions["cx-iso1"].git_head' "$COORD_DIR/sessions.json"
  [ "$output" = "$HEAD_A" ]
}

@test "head_tracking: read_set superseded_by_head_change marks per-session only" {
  _seed_session_at_head "ch-rs1" "claude_code" "$HEAD_A"
  _seed_session_at_head "cx-rs1" "codex"       "$HEAD_A"
  # Pre-seed read_sets for BOTH sessions.
  jq --arg ch "ch-rs1" --arg cx "cx-rs1" '
    .read_sets[$ch] = {reads: [{path:"/tmp/x.ts", hash:"a", is_latest:true}]}
    | .read_sets[$cx] = {reads: [{path:"/tmp/y.ts", hash:"b", is_latest:true}]}
  ' "$COORD_DIR/sessions.json" > "$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  ( cd "$XAGENT_TMP" && printf 'c\n' >a.txt && git commit -q -am three )
  # Trigger claude any hook only.
  xagent_pretooluse_any claude_code "ch-rs1"
  sleep 0.2
  # Claude's read_set marked.
  run jq -r '.read_sets["ch-rs1"].reads[0].superseded_by_head_change // false' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  # Codex's read_set untouched.
  run jq -r '.read_sets["cx-rs1"].reads[0] | has("superseded_by_head_change")' "$COORD_DIR/sessions.json"
  [ "$output" = "false" ]
}

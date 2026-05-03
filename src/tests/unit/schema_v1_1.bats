#!/usr/bin/env bats
# Tests for schema 1.0 → 1.1 bump (PR B.1).
# Verifies:
#   - Empty template emits schema_version "1.1".
#   - SessionStart writes agent="claude_code" on the new session row.
#   - Legacy 1.0 sessions.json (rows without `agent`) still reads cleanly;
#     readers default missing `agent` to "claude_code".
#   - `coord status` displays the agent column.
#   - install.sh writes 1.1 in both schema_version file and config.json.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-schema-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  export COORD_DIR="$COORD"
  HSS="$SRC_ROOT/adapters/claude-code/hooks/session_start.sh"
  C="$SRC_ROOT/core/bin/coord"
}
teardown() {
  unset COORD_DIR CLAUDE_COORD CLAUDE_PROJECT_DIR SESSION_ID
  rm -rf "$TMP"
}

@test "schema 1.1: coord_state_empty_template writes schema_version=1.1" {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  run bash -c '. "'"$SRC_ROOT"'/core/lib/atomic_write.sh"; coord_state_empty_template | jq -r .schema_version'
  [ "$status" -eq 0 ]
  [ "$output" = "1.1" ]
}

@test "schema 1.1: SessionStart writes agent=claude_code on the new row" {
  mk_empty_sessions "$COORD"
  local SID="schema-test-$RANDOM"
  CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$TMP" run bash -c "
    echo '{\"session_id\":\"$SID\",\"cwd\":\"$TMP\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' | '$HSS'
  "
  [ "$status" -eq 0 ]
  run jq -r --arg sid "$SID" '.sessions[$sid].agent' "$COORD/sessions.json"
  [ "$output" = "claude_code" ]
}

@test "schema 1.1: legacy 1.0 row (no agent) reads as 'claude_code' via fallback" {
  mk_empty_sessions "$COORD"
  # Hand-craft a 1.0-shaped row WITHOUT agent field.
  jq '
    .sessions["legacy-sid-aaaa"] = {
      state: "ACTIVE", pid: 1, pid_lstart: "x",
      registered_at: "y", last_activity_at: "z",
      git_head: "", prompt_id: null, script_version: "1.0"
    }
  ' "$COORD/sessions.json" > "$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  # `coord status` reads sessions and applies // "claude_code" fallback.
  run "$C" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'agent=claude_code'
}

@test "schema 1.1: coord status shows agent column for new-shape rows too" {
  mk_empty_sessions "$COORD"
  jq '
    .sessions["new-sid-bbbb"] = {
      state: "ACTIVE", pid: 2, pid_lstart: "x",
      registered_at: "y", last_activity_at: "z",
      git_head: "", prompt_id: null, script_version: "1.0",
      agent: "claude_code"
    }
  ' "$COORD/sessions.json" > "$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run "$C" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'agent=claude_code'
}

@test "schema 1.1: install.sh writes 1.1 to schema_version file + config.json" {
  cd "$TMP"
  run bash "$SRC_ROOT/install.sh" --yes
  [ "$status" -eq 0 ] || { echo "install failed: $output"; return 1; }
  run cat "$TMP/.coord/schema_version"
  [ "$output" = "1.1" ]
  run jq -r .schema_version "$TMP/.coord/config.json"
  [ "$output" = "1.1" ]
}

@test "schema 1.1: forward-tolerance — future schema field on a row is preserved by atomic_edit" {
  # Forward compatibility: if a future schema (1.2+) adds another field
  # to .sessions[<sid>], a 1.1 writer doing a partial update (e.g.,
  # session_resume's idempotent refresh that only sets state/pid/last_*)
  # MUST NOT drop the unknown field. This guards against the obvious
  # 1.0→1.1 regression at the next bump too.
  mk_empty_sessions "$COORD"
  jq '
    .sessions["forward-sid-cccc"] = {
      state: "ACTIVE", pid: 3, pid_lstart: "x",
      registered_at: "y", last_activity_at: "z",
      git_head: "", prompt_id: null, script_version: "1.0",
      agent: "claude_code",
      future_field: "should_persist"
    }
  ' "$COORD/sessions.json" > "$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  # Drive a SessionStart resume on the existing row — uses the
  # idempotent-refresh FILTER which mutates specific fields only.
  CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$TMP" run bash -c "
    echo '{\"session_id\":\"forward-sid-cccc\",\"cwd\":\"$TMP\",\"hook_event_name\":\"SessionStart\",\"source\":\"resume\"}' | '$HSS'
  "
  [ "$status" -eq 0 ]
  run jq -r '.sessions["forward-sid-cccc"].future_field' "$COORD/sessions.json"
  [ "$output" = "should_persist" ]
}

#!/usr/bin/env bats
# Tests for the COORD_ENABLED participation gate + CLAUDE_COORD legacy alias.
# PR B.2.
#
# Verifies:
#   - COORD_ENABLED=1 alone enables coord (canonical).
#   - CLAUDE_COORD=1 alone still enables coord (legacy alias preserved).
#   - Both unset → hook exits 0 silently (non-participant).
#   - COORD_ENABLED takes precedence when both are set with conflicting values.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-ce-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED CLAUDE_PROJECT_DIR
  HSS="$SRC_ROOT/adapters/claude-code/hooks/session_start.sh"
  SID="ce-test-$RANDOM"
  INP='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
}
teardown() {
  unset COORD_DIR CLAUDE_COORD COORD_ENABLED SESSION_ID
  rm -rf "$TMP"
}

@test "gate: COORD_ENABLED=1 alone registers the session" {
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  run jq -r --arg sid "$SID" '.sessions[$sid].state // ""' "$COORD/sessions.json"
  [ "$output" = "ACTIVE" ]
}

@test "gate: CLAUDE_COORD=1 (legacy alias) alone still registers the session" {
  CLAUDE_COORD=1 run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  run jq -r --arg sid "$SID" '.sessions[$sid].state // ""' "$COORD/sessions.json"
  [ "$output" = "ACTIVE" ]
}

@test "gate: neither var set → hook exits 0 silently, no session registered" {
  run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  run jq -r --arg sid "$SID" '.sessions[$sid].state // "NOT_REGISTERED"' "$COORD/sessions.json"
  [ "$output" = "NOT_REGISTERED" ]
}

@test "gate: COORD_ENABLED=0 explicitly disables even with CLAUDE_COORD=1" {
  # COORD_ENABLED takes precedence (it's first in the parameter expansion
  # ${COORD_ENABLED:-${CLAUDE_COORD:-}}). Setting it to "0" forces the
  # gate to compare "0" != "1" → exit 0 silently.
  COORD_ENABLED=0 CLAUDE_COORD=1 run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  run jq -r --arg sid "$SID" '.sessions[$sid].state // "NOT_REGISTERED"' "$COORD/sessions.json"
  [ "$output" = "NOT_REGISTERED" ]
}

@test "gate: COORD_ENABLED=1 wins when CLAUDE_COORD=0" {
  COORD_ENABLED=1 CLAUDE_COORD=0 run bash -c "echo '$INP' | '$HSS'"
  [ "$status" -eq 0 ]
  run jq -r --arg sid "$SID" '.sessions[$sid].state // ""' "$COORD/sessions.json"
  [ "$output" = "ACTIVE" ]
}

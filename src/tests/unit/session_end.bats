#!/usr/bin/env bats
# Tests for hooks/session_end.sh per plan §4.

load "../helpers/common"

H_START="$SRC_ROOT/hooks/session_start.sh"
H_END="$SRC_ROOT/hooks/session_end.sh"
A="$SRC_ROOT/lib/atomic_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-sessend-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  SID="sid-end-0001"
  # Pre-register with the start hook.
  CLAUDE_COORD=1 bash -c "echo '{\"session_id\":\"$SID\",\"cwd\":\"$TMP\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' | '$H_START'" >/dev/null
}
teardown() { unset CLAUDE_COORD; rm -rf "$TMP"; }

@test "session_end: CLAUDE_COORD unset → exit 0, no state change" {
  run bash -c "echo '{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}' | '$H_END'"
  [ "$status" -eq 0 ]
  [ -e "$COORD_DIR/sessions/$SID.active" ]
  run jq -r '.sessions[$sid].state' --arg sid "$SID" "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
}

@test "session_end: IDLE_CLOSED + marker removal on graceful end" {
  CLAUDE_COORD=1 run bash -c "echo '{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}' | '$H_END'"
  [ "$status" -eq 0 ]
  [ ! -e "$COORD_DIR/sessions/$SID.active" ]
  run jq -r '.sessions[$sid].state' --arg sid "$SID" "$COORD_DIR/sessions.json"
  [ "$output" = "IDLE_CLOSED" ]
}

@test "session_end: releases locks held by this session only" {
  # Pre-set two locks: one by this session, one by another.
  "$A" edit "$COORD_DIR/sessions.json" '
    .locks = {
      "/f/mine.ts":  {session:$mine,  acquired_at:"t", last_refresh_at:"t", tasks:[]},
      "/f/other.ts": {session:$other, acquired_at:"t", last_refresh_at:"t", tasks:[]}
    }' --arg mine "$SID" --arg other "other-session"
  CLAUDE_COORD=1 bash -c "echo '{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}' | '$H_END'"
  run jq -r '.locks | keys | sort | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "/f/other.ts" ]
}

@test "session_end: subagent event does not mutate state but logs SUBAGENT_ACTIVITY_SKIPPED" {
  CLAUDE_COORD=1 run bash -c "echo '{\"session_id\":\"$SID\",\"agent_type\":\"general-purpose\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"other\"}' | '$H_END'"
  [ "$status" -eq 0 ]
  [ -e "$COORD_DIR/sessions/$SID.active" ]
  run jq -r '.sessions[$sid].state' --arg sid "$SID" "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -rs 'last | .payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "SessionEnd" ]
}

@test "session_end: logs SESSION_END event with reason payload" {
  CLAUDE_COORD=1 bash -c "echo '{\"session_id\":\"$SID\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"logout\"}' | '$H_END'"
  sleep 0.3
  [ -s "$COORD_DIR/events.jsonl" ]
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SESSION_END" ]
  run jq -rs 'last | .payload.reason' "$COORD_DIR/events.jsonl"
  [ "$output" = "logout" ]
}

#!/usr/bin/env bats
# Tests for hooks/stop.sh (Phase 2 — graceful lock release on Stop event).
# Stop fires when a Claude turn ends; in graceful exit it precedes
# SessionEnd. This hook releases any locks the session still holds and
# populates notifications for sessions that were denied during the hold.
# Subagent (Stop with agent_type) MUST be a no-op — subagents do not
# hold locks; only the parent does.

load "../helpers/common"

H="$SRC_ROOT/hooks/stop.sh"
HW="$SRC_ROOT/hooks/pre_tool_use_write.sh"
H_END="$SRC_ROOT/hooks/session_end.sh"
A="$SRC_ROOT/core/lib/atomic_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-stop-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  SID="sid-stop-aaaa"
  OTHER="sid-stop-bbbb"
  touch "$COORD_DIR/sessions/${SID}.active" "$COORD_DIR/sessions/${OTHER}.active"
  jq --arg a "$SID" --arg b "$OTHER" '
    .sessions[$a]={state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
    | .sessions[$b]={state:"ACTIVE",pid:2,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET1="$TMP/foo.ts"; TARGET2="$TMP/bar.ts"
  printf 'foo\n' >"$TARGET1"; printf 'bar\n' >"$TARGET2"

  STOP_INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"Stop"}'
  STOP_SUB='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"Stop","agent_type":"general-purpose"}'
  END_INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"SessionEnd","reason":"exit"}'
}

teardown() { unset CLAUDE_COORD COORD_DIR; rm -rf "$TMP"; }

# Helper: have $SID acquire a lock on $1 via the real pre-write hook.
_acquire() {
  local file="$1"
  local input='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$file"'"}}'
  CLAUDE_COORD=1 bash -c "echo '$input' | '$HW'" >/dev/null
}

# Helper: have $OTHER attempt a write on $1 (will be denied if SID holds it).
_other_attempt() {
  local file="$1"
  local input='{"session_id":"'"$OTHER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$file"'"}}'
  CLAUDE_COORD=1 bash -c "echo '$input' | '$HW'" >/dev/null 2>&1
}

@test "stop: CLAUDE_COORD unset → exit 0, lock untouched" {
  _acquire "$TARGET1"
  run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run jq -r --arg f "$TARGET1" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "stop: SubagentStop (agent_type populated) → no release, SUBAGENT_ACTIVITY_SKIPPED" {
  _acquire "$TARGET1"
  CLAUDE_COORD=1 run bash -c "echo '$STOP_SUB' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # Parent's lock untouched.
  run jq -r --arg f "$TARGET1" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
  run jq -rs 'last | .payload.hook' "$COORD_DIR/events.jsonl"
  [ "$output" = "Stop" ]
}

@test "stop: non-participant session → no-op" {
  local INPUT='{"session_id":"not-registered","hook_event_name":"Stop"}'
  CLAUDE_COORD=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "stop: no locks held → silent no-op (idempotency basis for Stop+SessionEnd dual-fire)" {
  CLAUDE_COORD=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # No LOCK_RELEASED event emitted. The "silent" path emits no events at
  # all, so events.jsonl may not exist yet — that itself proves the
  # invariant. If it does exist, count must be 0.
  sleep 0.3
  if [ -f "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "LOCK_RELEASED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "stop: single-lock release → LOCK_RELEASED event + lock entry deleted" {
  _acquire "$TARGET1"
  CLAUDE_COORD=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Lock gone.
  run jq -r --arg f "$TARGET1" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  # LOCK_RELEASED event emitted with source=stop.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "stop")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

@test "stop: multi-lock release → one LOCK_RELEASED per file" {
  _acquire "$TARGET1"
  _acquire "$TARGET2"
  CLAUDE_COORD=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # Both locks gone.
  run jq -r '.locks | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  # Two LOCK_RELEASED events, both source=stop.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "stop")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "2" ]
  # Files covered are exactly TARGET1 + TARGET2.
  run jq -rs --arg f1 "$TARGET1" --arg f2 "$TARGET2" '
    [.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "stop") | .file] | sort
    == ([$f1, $f2] | sort)
  ' "$COORD_DIR/events.jsonl"
  [ "$output" = "true" ]
}

@test "stop: notification populated for queued waiter on released path (Phase 5 T5.04)" {
  _acquire "$TARGET1"
  # OTHER tries to write → denied + LOCK_DENIED logged + (Phase 5)
  # OTHER would normally enqueue itself via `coord wait`, but the
  # _other_attempt fixture predates Phase 5. Pre-seed the queue
  # entry directly via the public API.
  _other_attempt "$TARGET1"
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_DENIED" and .session == $b)] | length' --arg b "$OTHER" "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  mkdir -p "$COORD_DIR/wakers" "$COORD_DIR/wait_queues"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/wait_queue.sh"
  COORD_DIR="$COORD_DIR" coord_wait_queue_enqueue "$OTHER" "$TARGET1" >/dev/null
  # Now SID stops → release should populate notifications[OTHER][TARGET1].
  CLAUDE_COORD=1 bash -c "echo '$STOP_INPUT' | '$H'" >/dev/null
  sleep 0.3
  run jq -r --arg b "$OTHER" --arg f "$TARGET1" '
    .notifications[$b][$f] | length
  ' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r --arg b "$OTHER" --arg f "$TARGET1" '
    .notifications[$b][$f][0]
  ' "$COORD_DIR/sessions.json"
  # Action-hint format preserves Phase 2 wording with T5.04
  # diff_summary appended.
  echo "$output" | grep -q "Lock released on"
  echo "$output" | grep -qE "held by ${SID:0:8}\\.\\.\\."
  echo "$output" | grep -qE "for [0-9]+ sec"
  echo "$output" | grep -q "diff_summary:"
  echo "$output" | grep -q "You may now retry your write"
  echo "$output" | grep -q "coord wait $TARGET1"
  # NOTIFICATION_PRODUCED event emitted, waiter_count=1.
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_PRODUCED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run jq -rs 'last(.[] | select(.kind == "NOTIFICATION_PRODUCED")) | .payload.waiter_count' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

@test "stop: no waiters during hold → no notifications populated" {
  _acquire "$TARGET1"
  # No denials happened.
  CLAUDE_COORD=1 bash -c "echo '$STOP_INPUT' | '$H'" >/dev/null
  sleep 0.3
  run jq -r '.notifications | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  # No NOTIFICATION_PRODUCED event.
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_PRODUCED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "stop+session_end dual-fire: idempotent (Stop releases; SessionEnd finds no locks)" {
  _acquire "$TARGET1"
  CLAUDE_COORD=1 bash -c "echo '$STOP_INPUT' | '$H'" >/dev/null
  CLAUDE_COORD=1 bash -c "echo '$END_INPUT' | '$H_END'" >/dev/null
  sleep 0.3
  # Exactly ONE LOCK_RELEASED event for TARGET1 (Stop emitted; SessionEnd
  # found no locks → silent path; no duplicate).
  run jq -rs --arg f "$TARGET1" '[.[] | select(.kind == "LOCK_RELEASED" and .file == $f)] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  # SessionEnd still ran its own bookkeeping: state→IDLE_CLOSED, marker gone.
  run jq -r --arg sid "$SID" '.sessions[$sid].state' "$COORD_DIR/sessions.json"
  [ "$output" = "IDLE_CLOSED" ]
  [ ! -e "$COORD_DIR/sessions/${SID}.active" ]
}

@test "stop: ship gate — never sets permissionDecision in any branch" {
  # Branch 1: with locks held → release path.
  _acquire "$TARGET1"; _acquire "$TARGET2"
  CLAUDE_COORD=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Branch 2: no locks → silent path.
  CLAUDE_COORD=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Branch 3: subagent skip path.
  CLAUDE_COORD=1 run bash -c "echo '$STOP_SUB' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  true
}

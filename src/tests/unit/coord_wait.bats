#!/usr/bin/env bats
# Tests for `coord wait <path> [--timeout N]` — Phase 2 T2.03.
# Passive blocking wait until a lock on <path> is released, or timeout.

load "../helpers/common"

CLI="$SRC_ROOT/bin/coord"
HW="$SRC_ROOT/hooks/pre_tool_use_write.sh"
HP="$SRC_ROOT/hooks/post_tool_use_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-wait-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  HOLDER="sid-wait-holder"
  WAITER="sid-wait-waiter"
  touch "$COORD_DIR/sessions/${HOLDER}.active" "$COORD_DIR/sessions/${WAITER}.active"
  jq --arg h "$HOLDER" --arg w "$WAITER" '
    .sessions[$h]={state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
    | .sessions[$w]={state:"ACTIVE",pid:2,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET="$TMP/foo.ts"; printf 'foo\n' >"$TARGET"
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# Helper: have HOLDER acquire a lock on $1 via the real pre-write hook.
_acquire() {
  local file="$1"
  local input='{"session_id":"'"$HOLDER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$file"'"}}'
  CLAUDE_COORD=1 bash -c "echo '$input' | '$HW'" >/dev/null
}

# Helper: HOLDER releases via the real post-write hook.
_release() {
  local file="$1"
  local input='{"session_id":"'"$HOLDER"'","cwd":"'"$TMP"'","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$file"'"}}'
  CLAUDE_COORD=1 bash -c "echo '$input' | '$HP'" >/dev/null
}

@test "coord wait: usage error when no path given" {
  run bash -c "'$CLI' wait"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "usage: coord wait"
}

@test "coord wait: --timeout non-integer rejected" {
  run bash -c "'$CLI' wait '$TARGET' --timeout abc"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "must be a non-negative integer"
}

@test "coord wait: instant exit 0 when lock is free" {
  run bash -c "'$CLI' wait '$TARGET' --timeout 30"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "lock free"
  # No WAIT_RELEASED, WAIT_TIMEOUT, or WAIT_CLAMPED events.
  if [ -f "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind | test("^WAIT_"))] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "coord wait: instant exit 0 when lock held by self" {
  _acquire "$TARGET"
  SESSION_ID="$HOLDER" run bash -c "SESSION_ID='$HOLDER' '$CLI' wait '$TARGET' --timeout 30"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "held by you"
}

@test "coord wait: --timeout 10 (below floor) clamps to 30 + WAIT_CLAMPED event" {
  run bash -c "'$CLI' wait '$TARGET' --timeout 10"
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "WAIT_CLAMPED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run jq -rs 'last(.[] | select(.kind == "WAIT_CLAMPED")) | [.payload.requested, .payload.applied] | @tsv' "$COORD_DIR/events.jsonl"
  [ "$output" = "10	30" ]
}

@test "coord wait: --timeout 700 (above ceiling) clamps to 570 + WAIT_CLAMPED event" {
  run bash -c "'$CLI' wait '$TARGET' --timeout 700"
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -rs 'last(.[] | select(.kind == "WAIT_CLAMPED")) | [.payload.requested, .payload.applied] | @tsv' "$COORD_DIR/events.jsonl"
  [ "$output" = "700	570" ]
}

@test "coord wait: --timeout 30 (in-bounds) does NOT emit WAIT_CLAMPED" {
  run bash -c "'$CLI' wait '$TARGET' --timeout 30"
  [ "$status" -eq 0 ]
  sleep 0.3
  if [ -f "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "WAIT_CLAMPED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "coord wait: lock release detected within ~250ms; WAIT_RELEASED event with waited_for" {
  _acquire "$TARGET"
  # Spawn coord wait in background; release after ~1s; expect detection within ~1.25s.
  ( SESSION_ID="$WAITER" "$CLI" wait "$TARGET" --timeout 30 >"$TMP/wait.out" 2>&1 ) &
  WAIT_PID=$!
  sleep 1
  _release "$TARGET"

  # Bound the wait so a regression doesn't hang the test indefinitely.
  local elapsed=0
  while kill -0 "$WAIT_PID" 2>/dev/null; do
    sleep 0.1
    elapsed=$(( elapsed + 1 ))
    [ "$elapsed" -gt 50 ] && { kill "$WAIT_PID" 2>/dev/null; break; }
  done
  wait "$WAIT_PID"
  rc=$?
  [ "$rc" -eq 0 ]
  grep -q "released after" "$TMP/wait.out"

  sleep 0.3
  run jq -rs '[.[] | select(.kind == "WAIT_RELEASED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  # waited_for ≤ 2 sec (we released after 1s; detection within 250ms; +slop).
  run jq -rs 'last(.[] | select(.kind == "WAIT_RELEASED")) | .payload.waited_for | tonumber' "$COORD_DIR/events.jsonl"
  [ "$output" -le "2" ]
}

@test "coord wait: timeout fires correctly and emits WAIT_TIMEOUT (--timeout 30)" {
  # Inline acquire to dodge bats's set -eE behavior on _acquire pipe.
  local acq_input='{"session_id":"'"$HOLDER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$TARGET"'"}}'
  CLAUDE_COORD=1 run bash -c "echo '$acq_input' | '$HW'"
  [ "$status" -eq 0 ]
  # Spawn the wait; do not release. Bound the test at ~32s to allow the
  # 30s timeout + a small slop window for log flush.
  run bash -c "SESSION_ID='$WAITER' '$CLI' wait '$TARGET' --timeout 30"
  rc=$status
  [ "$rc" -eq 1 ]
  echo "$output" | grep -q "timeout after 30s"
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "WAIT_TIMEOUT")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run jq -rs 'last(.[] | select(.kind == "WAIT_TIMEOUT")) | [.payload.requested, .payload.applied, .payload.reason] | @tsv' "$COORD_DIR/events.jsonl"
  [ "$output" = "30	30	deadline" ]
}

@test "coord wait: SIGINT trap is registered in source (static check)" {
  # Runtime SIGINT delivery in a bats subprocess is fragile (job-control
  # interactions, output buffering before exit 130, signal-vs-pgid
  # delivery quirks across platforms). The TRAP itself is what we
  # control in source — that the cleanup handler is defined and bound
  # to INT and TERM, that on fire it logs WAIT_TIMEOUT(reason=interrupted),
  # writes an "interrupted" message, and exits 130. Verify those source-
  # level invariants here; production-runtime behavior is exercised
  # implicitly through Phase 7's full integration harness.
  grep -q "trap cleanup_interrupt INT TERM" "$CLI"
  grep -q "reason=interrupted" "$CLI"
  grep -qE 'exit 130' "$CLI"
  grep -q "coord wait: interrupted" "$CLI"
}

@test "coord wait: subagent policy (A) — coord wait runs without parent/subagent gate" {
  # Per F-015 OPEN/DEFERRED to Phase 6: T2.03 ships policy (A) — `coord
  # wait` works for any caller. There is no env-based subagent rejection
  # in the CLI. The lock-free path returns immediately regardless of
  # who invoked it; even setting a synthetic agent_type-like env var
  # does not change behavior.
  COORD_AGENT_TYPE="general-purpose" run bash -c "'$CLI' wait '$TARGET' --timeout 30"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "lock free"
}

@test "coord wait: ship gate — never sets permissionDecision (it's a CLI, not a hook)" {
  _acquire "$TARGET"
  ( "$CLI" wait "$TARGET" --timeout 30 >"$TMP/wait.out" 2>&1 ) &
  WAIT_PID=$!
  sleep 0.5
  _release "$TARGET"
  wait "$WAIT_PID" || true
  case "$(cat "$TMP/wait.out")" in
    *permissionDecision*) return 1 ;;
  esac
  true
}

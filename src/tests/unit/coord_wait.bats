#!/usr/bin/env bats
# Tests for `coord wait <path> [--timeout N]` — Phase 2 T2.03.
# Passive blocking wait until a lock on <path> is released, or timeout.

load "../helpers/common"

CLI="$SRC_ROOT/core/bin/coord"
HW="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_write.sh"
HP="$SRC_ROOT/adapters/claude-code/hooks/post_tool_use_write.sh"

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
  # Source-level invariants: trap binding + cleanup-handler
  # contract. Runtime behavior is verified by the Phase 7 / T7.06a
  # SIGINT runtime test below.
  grep -q "trap cleanup_interrupt INT TERM" "$CLI"
  grep -q "reason=interrupted" "$CLI"
  grep -qE 'exit 130' "$CLI"
  grep -q "coord wait: interrupted" "$CLI"
  # Phase 7 / T7.06a: cleanup_interrupt MUST use sync log variant.
  grep -q "coord_log_event_sync kind=WAIT_TIMEOUT" "$CLI"
}

@test "coord wait: SIGTERM runtime — emits WAIT_TIMEOUT(interrupted) + dequeue (T7.06a F-016 fix)" {
  # Phase 7 / T7.06a re-enables runtime signal-delivery testing
  # after the F-016 root cause was identified (backgrounded
  # coord_log_event flush race on exit-130) and fixed via
  # coord_log_event_sync. Pre-T7.06a this test was a static-grep
  # placeholder.
  #
  # Signal choice: SIGTERM (not SIGINT). Under bats with job
  # control disabled, backgrounded async commands inherit SIG_IGN
  # for SIGINT per bash(1) — the kernel never delivers SIGINT to
  # the bg coord wait. SIGTERM IS delivered, and cleanup_interrupt
  # is bound to BOTH INT and TERM, so the trap fires identically.
  # Production users hitting Ctrl-C in a foreground terminal use
  # the SIGINT path; this test exercises the equivalent SIGTERM
  # path that goes through the SAME cleanup_interrupt handler.
  # Both paths use coord_log_event_sync — the F-016 fix.
  _acquire "$TARGET"

  local out_file="$TMP/coord_wait.out"
  local err_file="$TMP/coord_wait.err"

  # Background coord wait directly as a child of the bats test
  # shell so `kill -INT $!` and `wait $!` operate on it. A
  # bash -c "...; echo $!" wrapper would put the PID in a sub-
  # shell that exits immediately; the backgrounded process would
  # reparent to PID 1 and `wait` would fail rc=127.
  SESSION_ID="$WAITER" "$CLI" wait "$TARGET" --timeout 60 \
    >"$out_file" 2>"$err_file" &
  local wait_pid=$!
  # Allow enqueue + trap registration + backend startup to complete
  # before SIGINT (>100 ms covers lib sourcing per F-017 ~50 ms).
  sleep 0.5

  # Use SIGTERM (not SIGINT) for the kill: under bats with job
  # control disabled (set -m off), backgrounded subshells inherit
  # SIG_IGN for SIGINT per bash(1) "asynchronous commands ignore
  # SIGINT and SIGQUIT" — the kernel never delivers SIGINT to the
  # backgrounded coord wait. SIGTERM IS delivered normally and
  # cleanup_interrupt is bound to BOTH INT and TERM, so the
  # trap fires either way. Production users running `coord wait`
  # in a foreground terminal hit the SIGINT path; the bats test
  # exercises the equivalent SIGTERM path. Both reach
  # cleanup_interrupt.
  kill -TERM "$wait_pid" 2>/dev/null || true

  # bats's ERR trap fires on non-zero rc even under `set +e`. Use
  # the `|| rc=$?` form to capture wait's exit code without
  # tripping the trap.
  local rc=0
  wait "$wait_pid" 2>/dev/null || rc=$?

  # rc=130 expected: cleanup_interrupt exits with 130 regardless
  # of whether the trap fired on INT or TERM. (Bash signal-exit
  # convention is 128+signum, but our trap explicitly exits 130
  # to match the SIGINT user-experience of Ctrl-C even when fired
  # by SIGTERM — single audit-log signature for both paths.)
  [ "$rc" -eq 130 ]

  # Stdout should contain "coord wait: interrupted" message.
  grep -q "coord wait: interrupted" "$out_file"

  # events.jsonl MUST contain WAIT_TIMEOUT reason=interrupted —
  # the F-016 fix guarantees the sync write completes before
  # exit 130, so NO post-wait sleep is required here.
  [ -s "$COORD_DIR/events.jsonl" ]
  local count
  count=$(jq -rs '[.[] | select(.kind=="WAIT_TIMEOUT" and .payload.reason=="interrupted")] | length' \
    "$COORD_DIR/events.jsonl")
  [ "$count" -ge 1 ]

  # Wait queue dequeue: WAITER must be removed from wait_queues[$TARGET].
  local in_queue
  in_queue=$(jq --arg t "$TARGET" --arg w "$WAITER" \
    '(.wait_queues[$t] // []) | map(.session_id) | index($w) // -1' \
    "$COORD_DIR/sessions.json")
  [ "$in_queue" = "-1" ]
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

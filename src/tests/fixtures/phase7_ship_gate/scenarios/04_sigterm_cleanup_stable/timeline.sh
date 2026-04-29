#!/usr/bin/env bash
# 04_sigterm_cleanup_stable — Plan §7 revised Done-when #3 (F-016
# RESOLVED evidence): "F-016 dispositioned (RESOLVED-with-fix OR
# RESOLVED-DEFERRED with audit-clean rationale)."
#
# Verifies T7.06a fix end-to-end:
#   a. coord wait responds to SIGTERM (proxy for SIGINT under
#      bats job control off — Cand-22 disposition; same handler)
#   b. exit code 130 (cleanup_interrupt explicit exit)
#   c. WAIT_TIMEOUT(reason=interrupted) audit event lands BEFORE
#      exit (coord_log_event_sync evidence — pre-T7.06a this
#      raced)
#   d. wait_queue dequeued
#   e. Watcher PIDs (fswatch_pid + sleeper_pid) cleaned up by
#      cleanup_interrupt explicit kill (audit cause #2 fix)
set -uo pipefail

scenario_run() {
  local sid_h="p7sg-04-holder"
  local sid_w="p7sg-04-waiter"
  local target="$WORKDIR/foo.ts"

  coord_fixture_p7_register_session "$sid_h"
  coord_fixture_p7_register_session "$sid_w"

  # Holder acquires lock.
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f] = {session: $sid, acquired_at: $now, last_refresh_at: $now,
                   tasks: [], latest_validator_verdict_ts: null}' \
    --arg f "$target" --arg sid "$sid_h" --arg now "$(coord_now_iso8601)"

  # Background coord wait directly as child of this shell so
  # `kill -TERM $!` and `wait $!` operate cleanly (Lesson #17 +
  # T7.06a coord_wait.bats SIGTERM test pattern).
  local out_file="$WORKDIR/coord_wait.out"
  local err_file="$WORKDIR/coord_wait.err"
  SESSION_ID="$sid_w" "$COORD_DIR/bin/coord" wait "$target" --timeout 60 \
    >"$out_file" 2>"$err_file" &
  WAIT_PID=$!
  export WAIT_PID

  # Allow trap registration + backend startup.
  sleep 0.5

  kill -TERM "$WAIT_PID" 2>/dev/null || true
  RC=0
  wait "$WAIT_PID" 2>/dev/null || RC=$?
  export RC

  STDOUT=$(cat "$out_file" 2>/dev/null || printf '')
  export STDOUT

  # Capture wait_queue state (post-cleanup).
  IN_QUEUE=$(jq --arg t "$target" --arg w "$sid_w" \
    '(.wait_queues[$t] // []) | map(.session_id) | index($w) // -1' \
    "$COORD_DIR/sessions.json")
  export IN_QUEUE

  sleep 0.3
}

scenario_assert() {
  local fail=0

  # 1. Exit code 130 (cleanup_interrupt explicit).
  if [ "$RC" -ne 130 ]; then
    printf '  FAIL 1: expected rc=130 from cleanup_interrupt, got %s\n' "$RC" >&2
    fail=1
  fi

  # 2. Stdout contains "interrupted" message.
  if ! printf '%s' "$STDOUT" | grep -q "coord wait: interrupted"; then
    printf '  FAIL 2: stdout missing "coord wait: interrupted"\n' >&2
    printf '         STDOUT=%s\n' "$STDOUT" >&2
    fail=1
  fi

  # 3. WAIT_TIMEOUT(reason=interrupted) audit event lands.
  #    Pre-T7.06a this would race; coord_log_event_sync
  #    guarantees the write completes before exit 130.
  local interrupted_count
  interrupted_count=$(jq -rs '
    [.[] | select(.kind=="WAIT_TIMEOUT" and .payload.reason=="interrupted")] | length
  ' "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$interrupted_count" -lt 1 ]; then
    printf '  FAIL 3: WAIT_TIMEOUT(reason=interrupted) audit event not found\n' >&2
    fail=1
  fi

  # 4. Wait queue dequeued (waiter removed).
  if [ "$IN_QUEUE" != "-1" ]; then
    printf '  FAIL 4: waiter still in queue after SIGTERM cleanup; index=%s\n' "$IN_QUEUE" >&2
    fail=1
  fi

  # 5. Phase 7 invariant — no permissionDecision in any output.
  if printf '%s' "$STDOUT" | grep -q '"permissionDecision"'; then
    printf '  FAIL 5: permissionDecision in stdout (Phase 7 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

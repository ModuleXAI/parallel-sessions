#!/usr/bin/env bash
# 02_wake_file_event_driven — polling backend wake-up latency budget.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-02-wake"
  local sid_b="sid-b-02-wake"
  local target="$WORKDIR/bar.ts"

  coord_fixture_p5_register_session "$sid_a"
  coord_fixture_p5_register_session "$sid_b"

  coord_fixture_p5_acquire "$target" "$sid_a"

  # B enqueues + captures wake_file.
  WAKE_B=$(SESSION_ID="$sid_b" coord_wait_queue_enqueue "$sid_b" "$target")

  # Background producer: sleep 200ms then release.
  ( sleep 0.2; coord_fixture_p5_release "$target" "$sid_a" ) &
  PRODUCER_PID=$!

  # B polls for wake-up, capturing elapsed.
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  if coord_wait_for_release_polling "$WAKE_B" 5; then
    POLL_RC=0
  else
    POLL_RC=$?
  fi
  t1=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  ELAPSED_MS=$(( t1 - t0 ))

  wait "$PRODUCER_PID" 2>/dev/null || true

  # Read wake content (50ms grace + fallback per consumer protocol).
  WAKE_CONTENT=$(coord_wait_read_content "$WAKE_B" "${sid_a:0:8}")

  # Emit WAIT_BACKEND event for the assertion (first-use emit
  # bookkeeping is in-process; we trigger it explicitly here to give
  # the fixture an observable signal).
  coord_wait_emit_first_use_event "polling"

  export POLL_RC ELAPSED_MS WAKE_CONTENT WAKE_B SID_A="$sid_a" SID_B="$sid_b"
  sleep 0.1
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. Polling returned rc=0 (wake-up detected, not timeout).
  if [ "$POLL_RC" -ne 0 ]; then
    printf '  FAIL 1: coord_wait_for_release_polling rc=%s; expected 0 (wake)\n' "$POLL_RC" >&2
    fail=1
  fi

  # 2. wake_file content non-empty.
  if [ -z "$WAKE_CONTENT" ]; then
    printf '  FAIL 2: wake_file content empty after release\n' >&2
    fail=1
  fi

  # 3. Latency budget: 200ms hold + ≤600ms polling cadence + grace =
  # ≤1500ms with safety margin for CI variance.
  if [ "$ELAPSED_MS" -gt 1500 ]; then
    printf '  FAIL 3: elapsed_ms=%s exceeded 1500ms budget (200ms hold + polling cadence)\n' "$ELAPSED_MS" >&2
    fail=1
  fi
  printf '  info: wake-up elapsed_ms=%s\n' "$ELAPSED_MS"

  # 4. WAIT_BACKEND event present with backend=polling.
  local n
  n=$(jq -rs '[.[] | select(.kind == "WAIT_BACKEND" and .payload.backend == "polling")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 4: no WAIT_BACKEND event with backend=polling\n' >&2
    fail=1
  fi

  # 5. Phase 5 invariant.
  if grep -q permissionDecision "$events"; then
    printf '  FAIL 5: permissionDecision found in events.jsonl\n' >&2
    fail=1
  fi

  return "$fail"
}

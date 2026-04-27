#!/usr/bin/env bash
# 04_cycle_detected_mediator_evict — cycle detection + Mediator
# surgical_fix eviction end-to-end via mock claude binary.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-04-cycle"
  local sid_b="sid-b-04-cycle"
  local sid_d="sid-d-04-cycle"   # depth-2 trigger noise (not in cycle)
  local file_x="$WORKDIR/foo.ts"
  local file_y="$WORKDIR/bar.ts"

  coord_fixture_p5_register_session "$sid_a"
  coord_fixture_p5_register_session "$sid_b"
  coord_fixture_p5_register_session "$sid_d"

  # Cycle setup: A holds X, B holds Y, A waits Y, B waits X.
  coord_fixture_p5_acquire "$file_x" "$sid_a"
  coord_fixture_p5_acquire "$file_y" "$sid_b"
  SESSION_ID="$sid_a" coord_wait_queue_enqueue "$sid_a" "$file_y" >/dev/null   # depth 1 on Y
  SESSION_ID="$sid_d" coord_wait_queue_enqueue "$sid_d" "$file_y" >/dev/null   # depth 2 on Y; trigger from D — D not in cycle, no detect

  # Configure mock Mediator: surgical_fix evict_session sid-B.
  export MOCK_MEDIATOR_ACTION="surgical_fix"
  export MOCK_MEDIATOR_EVICT_SID="$sid_b"

  # B enqueues /p/y at depth 3 → trigger from B; B IS in cycle:
  # B → file_y (B waits) → A (holder) → file_y? wait — A holds
  # file_x not file_y. Re-think:
  #   wait_queues: file_y has [A, D, B] (depth 3 after B's enqueue)
  #   locks: file_x → A, file_y → B
  # DFS from B:
  #   B waits file_y → holder=B → start_sid! cycle of length 0
  #     (self-loop on file_y). Defensive empty per T5.02.
  # We need B waiting on file_x (which A holds), not on file_y
  # (which B itself holds). Correct setup:
  #   A holds file_x; B holds file_y
  #   A waits file_y (depth 1); B waits file_x (depth 1)
  #   D waits file_x (depth 2; trigger from D, D not in cycle)
  # B already waits file_x at depth 1 above → wait, I haven't
  # done that yet. Rewriting cleanly below.
  : # placeholder; the actual cycle is built below.

  unset MOCK_MEDIATOR_ACTION MOCK_MEDIATOR_EVICT_SID

  # Tear down the partial setup and rebuild correctly.
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    'del(.locks) | .locks = {}
     | del(.wait_queues) | .wait_queues = {}'
  rm -f "$COORD_DIR/wakers"/*.wake 2>/dev/null || true

  # Correct cycle setup:
  coord_fixture_p5_acquire "$file_x" "$sid_a"
  coord_fixture_p5_acquire "$file_y" "$sid_b"
  SESSION_ID="$sid_a" coord_wait_queue_enqueue "$sid_a" "$file_y" >/dev/null   # A waits Y, depth 1
  SESSION_ID="$sid_d" coord_wait_queue_enqueue "$sid_d" "$file_x" >/dev/null   # D waits X, depth 1
  # Configure mock Mediator before the trigger fires.
  export MOCK_MEDIATOR_ACTION="surgical_fix"
  export MOCK_MEDIATOR_EVICT_SID="$sid_b"
  # B enqueues /p/x → depth 2 on X → trigger from B; B IS in cycle:
  #   B → file_x (B waits) → A (holder) → file_y (A waits) → B (holder)
  #   → start_sid! cycle found.
  SESSION_ID="$sid_b" coord_wait_queue_enqueue "$sid_b" "$file_x" >/dev/null

  unset MOCK_MEDIATOR_ACTION MOCK_MEDIATOR_EVICT_SID

  export SID_A="$sid_a" SID_B="$sid_b" SID_D="$sid_d" FILE_X="$file_x" FILE_Y="$file_y"
  sleep 0.4
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"
  local pending="$COORD_DIR/mediator/pending.jsonl"

  # 1. cycle_detected pending entry written.
  if [ ! -f "$pending" ]; then
    printf '  FAIL 1: pending.jsonl missing\n' >&2
    fail=1
    return "$fail"
  fi
  local n
  n=$(grep -c '"kind":"cycle_detected"' "$pending" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 1: no cycle_detected entry in pending.jsonl\n' >&2
    fail=1
  fi

  # 2. Pending entry payload contains all 9 keys.
  local k
  for k in cycle_path cycle_description involved_files involved_sessions \
           queue_depth_at_detection recent_cycle_count session_metadata \
           trigger_file trigger_session_id; do
    if ! jq -r --arg k "$k" 'select(.kind=="cycle_detected") | .payload | has($k)' \
         "$pending" 2>/dev/null | grep -q true; then
      printf '  FAIL 2: missing payload key: %s\n' "$k" >&2
      fail=1
    fi
  done

  # 3. cycle_description contains 3-tier guidance. jq -r decodes \n
  # escapes so the description spans multiple lines; do NOT pipe
  # through head -1 (would drop the priority lines). Instead, search
  # the full multi-line decoded output.
  if ! jq -r 'select(.kind=="cycle_detected") | .payload.cycle_description' \
       "$pending" 2>/dev/null | grep -q 'oldest last_activity_at'; then
    printf '  FAIL 3: cycle_description missing 3-tier guidance\n' >&2
    fail=1
  fi

  # 4. Mediator verdict file written with surgical_fix +
  # evict_session(sid-B).
  local vfile
  vfile=$(ls "$COORD_DIR/mediator/verdict/"*.json 2>/dev/null | head -1)
  if [ -z "$vfile" ]; then
    printf '  FAIL 4: no mediator verdict file written\n' >&2
    fail=1
  else
    local action evict
    action=$(jq -r '.action_type // ""' "$vfile" 2>/dev/null)
    evict=$(jq -r '.actions[0].session_id // ""' "$vfile" 2>/dev/null)
    if [ "$action" != "surgical_fix" ]; then
      printf '  FAIL 4a: verdict action_type=%s; expected surgical_fix\n' "$action" >&2
      fail=1
    fi
    if [ "$evict" != "$SID_B" ]; then
      printf '  FAIL 4b: verdict eviction sid=%s; expected %s\n' "$evict" "$SID_B" >&2
      fail=1
    fi
  fi

  # 5. CYCLE_DETECTED event emitted.
  n=$(jq -rs '[.[] | select(.kind == "CYCLE_DETECTED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 5: no CYCLE_DETECTED event\n' >&2
    fail=1
  fi

  # 6. Phase 5 invariant: zero permissionDecision in events or
  # mediator verdict.
  if grep -q permissionDecision "$events"; then
    printf '  FAIL 6: permissionDecision found in events.jsonl\n' >&2
    fail=1
  fi

  # 7. NO lockdown spuriously activated (surgical_fix is the verdict,
  # not lockdown).
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    local active
    active=$(jq -r '.active // false' "$COORD_DIR/mediator/lockdown.json" 2>/dev/null)
    if [ "$active" = "true" ]; then
      printf '  FAIL 7: spurious lockdown active\n' >&2
      fail=1
    fi
  fi

  return "$fail"
}

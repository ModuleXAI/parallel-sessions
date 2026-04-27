#!/usr/bin/env bash
# 03_diff_summary_on_release — Tier 1 verdict_file integration.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-03-diff"
  local sid_b="sid-b-03-diff"
  local sid_c="sid-c-03-diff"
  local sid_d="sid-d-03-diff"
  local target="$WORKDIR/baz.ts"
  local vts="2026-04-27T12-00-00-000Z"
  local diff_summary_text="Variable rename inside function. No caller impact."

  coord_fixture_p5_register_session "$sid_a"
  coord_fixture_p5_register_session "$sid_b"
  coord_fixture_p5_register_session "$sid_c"
  coord_fixture_p5_register_session "$sid_d"

  # Pre-write validator verdict file (simulates Phase 4 pipeline
  # having run during A's pre_tool_use_write hook turn).
  jq -n --arg ts "$vts" --arg ds "$diff_summary_text" \
        --arg sid "$sid_a" --arg file "$target" \
    '{verdict_id:"v-03", ts:$ts, for_pending_entry:null,
      validator_session_id:"placeholder",
      file:$file, session:$sid, verdict:"MINOR",
      reasoning:"Mock validator MINOR for fixture test.",
      diff_summary:$ds,
      spawn_metadata:{duration_ms:0,model:"haiku",spawn_mode:"no_bare"}}' \
    >"$COORD_DIR/validator/verdict/${vts}.json"

  # A acquires lock WITH the verdict_ts populated.
  coord_fixture_p5_acquire "$target" "$sid_a" "$vts"

  SESSION_ID="$sid_b" coord_wait_queue_enqueue "$sid_b" "$target" >/dev/null
  SESSION_ID="$sid_c" coord_wait_queue_enqueue "$sid_c" "$target" >/dev/null
  SESSION_ID="$sid_d" coord_wait_queue_enqueue "$sid_d" "$target" >/dev/null

  # A releases — notify_waiters resolves Tier 1 verdict_file lookup.
  coord_fixture_p5_release "$target" "$sid_a"

  local sanitized
  sanitized=$(printf '%s' "$target" | sed 's|/|__|g')
  WAKE_B=$(cat "$COORD_DIR/wakers/${sid_b}-${sanitized}.wake" 2>/dev/null || printf '')
  WAKE_C=$(cat "$COORD_DIR/wakers/${sid_c}-${sanitized}.wake" 2>/dev/null || printf '')
  WAKE_D=$(cat "$COORD_DIR/wakers/${sid_d}-${sanitized}.wake" 2>/dev/null || printf '')

  export WAKE_B WAKE_C WAKE_D
  export EXPECTED_DIFF_SUMMARY="$diff_summary_text"
  export VERDICT_TS="$vts"
  sleep 0.2
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. All 3 wake_files contain the EXACT diff_summary text.
  for w_var in WAKE_B WAKE_C WAKE_D; do
    local content="${!w_var}"
    # Strip trailing newline (printf "%s\n" adds it; cat reads it back).
    content="${content%$'\n'}"
    if [ "$content" != "$EXPECTED_DIFF_SUMMARY" ]; then
      printf '  FAIL 1[%s]: wake content [%s]; expected [%s]\n' \
        "$w_var" "$content" "$EXPECTED_DIFF_SUMMARY" >&2
      fail=1
    fi
  done

  # 2. NOTIFICATION_PRODUCED event with diff_summary_source=verdict_file
  # AND waiter_count=3.
  local n
  n=$(jq -rs '[.[] | select(.kind == "NOTIFICATION_PRODUCED"
                             and .payload.diff_summary_source == "verdict_file"
                             and .payload.waiter_count == "3")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 2: no NOTIFICATION_PRODUCED with diff_summary_source=verdict_file + waiter_count=3\n' >&2
    fail=1
  fi

  # 3. NO fresh VALIDATOR_SPAWN_STARTED during release (Tier 1 short-
  # circuits before any spawn).
  n=$(jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_STARTED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -gt 0 ]; then
    printf '  FAIL 3: VALIDATOR_SPAWN_STARTED fired during release (Tier 1 should short-circuit)\n' >&2
    fail=1
  fi

  # 4. Phase 5 invariant.
  if grep -q permissionDecision "$events"; then
    printf '  FAIL 4: permissionDecision found in events.jsonl\n' >&2
    fail=1
  fi

  return "$fail"
}

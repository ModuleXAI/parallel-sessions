#!/usr/bin/env bash
# 02_20min_no_evict/timeline.sh — false-positive prevention.

set -uo pipefail

scenario_run() {
  local hooks="$COORD_DIR/hooks"
  local sid_a="sid-a-thinking-0001"
  local sid_b="sid-b-thinking-0001"

  # 1. Register both sessions.
  for sid in "$sid_a" "$sid_b"; do
    printf '%s' '{"session_id":"'"$sid"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
      | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
          "$hooks/session_start.sh" >/dev/null
  done

  # 2. Session A acquires lock on foo.ts.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_write.sh" >/dev/null

  # 3. Set A's pid/lstart to match this bash process (alive) and
  # last_activity to 5 minutes ago — within the 10-min threshold per
  # PR-PHASE3-02 disposition (a 20-min session with occasional tool
  # calls keeps last_activity refreshed). Signal 2 (>10 min stale)
  # does NOT fire; Signal 1 (PID liveness) confirms alive.
  local our_pid="$$"
  local our_lstart
  our_lstart=$(ps -p "$our_pid" -o lstart= 2>/dev/null \
               | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  local recent_ts
  recent_ts=$(date -u -r $(($(date -u +%s) - 300)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -d "@$(($(date -u +%s) - 300))" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg sid "$sid_a" --arg pid "$our_pid" --arg lstart "$our_lstart" --arg ts "$recent_ts" '
    .sessions[$sid].pid = ($pid | tonumber)
    | .sessions[$sid].pid_lstart = $lstart
    | .sessions[$sid].last_activity_at = $ts
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # 4 + 5. Run watchdog probe synchronously. PID matches → alive.
  bash -c "
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$sid_b'
    . '$COORD_DIR/lib/log_event.sh'
    . '$COORD_DIR/lib/mediator_pending.sh'
    . '$COORD_DIR/lib/watchdog_cache.sh'
    . '$COORD_DIR/lib/watchdog.sh'
    coord_watchdog_probe '$sid_a'
  " >/dev/null
  sleep 0.3
}

scenario_assert() {
  local fail=0

  # B.1: A's session row STILL present.
  local a_state
  a_state=$(jq -r '.sessions["sid-a-thinking-0001"].state // "ABSENT"' "$COORD_DIR/sessions.json")
  if [ "$a_state" != "ACTIVE" ]; then
    printf '  FAIL B.1: A session row missing or not ACTIVE (state=%s)\n' "$a_state" >&2; fail=1
  fi

  # B.2: A's lock STILL held.
  local foo_holder
  foo_holder=$(jq -r '.locks["'"$WORKDIR"'/foo.ts"].session // "ABSENT"' "$COORD_DIR/sessions.json")
  if [ "$foo_holder" != "sid-a-thinking-0001" ]; then
    printf '  FAIL B.2: foo.ts lock not held by A (holder=%s)\n' "$foo_holder" >&2; fail=1
  fi

  # B.3: alive verdict cached.
  local alive_verdict
  alive_verdict=$(jq -rs '[.[] | select(.target == "sid-a-thinking-0001" and .verdict == "alive")] | length' \
    "$COORD_DIR/watchdog/recent_checks.jsonl" 2>/dev/null || printf 0)
  if [ "$alive_verdict" -lt 1 ]; then
    printf '  FAIL B.3: no alive verdict cached for A (count=%s)\n' "$alive_verdict" >&2; fail=1
  fi

  # B.4: No MEDIATOR_VERDICT events.
  local mv_count
  mv_count=$(jq -rs '[.[] | select(.kind == "MEDIATOR_VERDICT")] | length' \
    "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$mv_count" -gt 0 ]; then
    printf '  FAIL B.4: spurious MEDIATOR_VERDICT events (count=%s)\n' "$mv_count" >&2; fail=1
  fi

  # B.5: No stale_active pending entries.
  local stale_count
  stale_count=$(jq -rs '[.[] | select(.kind == "stale_active" and .source == "watchdog")] | length' \
    "$COORD_DIR/mediator/pending.jsonl" 2>/dev/null || printf 0)
  if [ "$stale_count" -gt 0 ]; then
    printf '  FAIL B.5: spurious stale_active pending (count=%s)\n' "$stale_count" >&2; fail=1
  fi

  # B.6: No lockdown.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL B.6: spurious lockdown active\n' >&2; fail=1
  fi

  return "$fail"
}

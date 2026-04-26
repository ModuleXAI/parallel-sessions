#!/usr/bin/env bash
# 01_sigkill_cleanup/timeline.sh — sourceable scenario.
# Required env from driver: WORKDIR, COORD_DIR, SRC_ROOT.

set -uo pipefail

scenario_run() {
  local hooks="$COORD_DIR/hooks"
  local sid_a="sid-a-sigkill-0001"
  local sid_b="sid-b-sigkill-0001"

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

  # 3. Simulate SIGKILL: A's PID becomes provably absent + activity stale.
  local stale_ts
  stale_ts=$(date -u -r $(($(date -u +%s) - 700)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -d "@$(($(date -u +%s) - 700))" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg sid "$sid_a" --arg ts "$stale_ts" '
    .sessions[$sid].pid = 99999
    | .sessions[$sid].pid_lstart = "ghost-lstart"
    | .sessions[$sid].last_activity_at = $ts
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # 4 + 5. Run watchdog probe synchronously for determinism (the fire-
  # and-forget background path is exercised in unit tests; here we want
  # to assert end-to-end state without timing flake).
  bash -c "
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$sid_b'
    . '$COORD_DIR/lib/log_event.sh'
    . '$COORD_DIR/lib/mediator_pending.sh'
    . '$COORD_DIR/lib/watchdog_cache.sh'
    . '$COORD_DIR/lib/watchdog.sh'
    coord_watchdog_probe '$sid_a'
  " >/dev/null

  # 6. Mediator spawn (mocked): write the verdict file directly. The
  # real spawn would invoke claude -p which writes a verdict; for the
  # fixture we synthesize the same shape.
  local verdict_ts
  verdict_ts="$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
  jq -nc --arg ts "$verdict_ts" --arg target "$sid_a" --arg foo "$WORKDIR/foo.ts" \
    '{verdict_id:"fixture-01-uuid",
      ts:$ts,
      for_pending_entry:"fixture-pending",
      mediator_session_id:"fixture-spawn",
      depth:1,
      action_type:"surgical_fix",
      severity:"brief",
      confidence:"auto_apply",
      reasoning:"PID 99999 confirmed absent; release lock + evict session.",
      actions:[
        {op:"release_lock", target:$foo, session:$target},
        {op:"evict_session", session:$target}
      ],
      message_to_caller:"Session sid-a evicted; lock on foo.ts released. Retry your write.",
      message_to_others:null}' \
    >"$COORD_DIR/mediator/verdict/${verdict_ts}.json"
  # Synthesize the MEDIATOR_VERDICT event for assertion.
  bash -c "
    . '$COORD_DIR/lib/log_event.sh'
    export COORD_DIR='$COORD_DIR' SESSION_ID='$sid_b'
    coord_log_event kind=MEDIATOR_VERDICT \
      verdict_path='$COORD_DIR/mediator/verdict/${verdict_ts}.json' \
      action_type=surgical_fix confidence=auto_apply depth=1 \
      duration_ms=18432 total_cost_usd=0 spawn_session_id=fixture-spawn
  "

  # 7. Session B consumes the verdict via pre_tool_use_any.sh.
  printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_any.sh" >/dev/null

  # 8. Session B attempts the Write on foo.ts (should now succeed).
  STDOUT_OF_B_WRITE=$(printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_write.sh" 2>/dev/null) || true
  export STDOUT_OF_B_WRITE
  sleep 0.3
}

scenario_assert() {
  local fail=0

  # A.1: A's session row removed.
  local a_row
  a_row=$(jq -r '.sessions["sid-a-sigkill-0001"] // "ABSENT"' "$COORD_DIR/sessions.json")
  if [ "$a_row" != "ABSENT" ]; then
    printf '  FAIL A.1: A session row still present\n' >&2; fail=1
  fi

  # A.2: Lock on foo.ts removed (or held by B from step 8).
  local foo_holder
  foo_holder=$(jq -r '.locks["'"$WORKDIR"'/foo.ts"].session // "ABSENT"' "$COORD_DIR/sessions.json")
  if [ "$foo_holder" = "sid-a-sigkill-0001" ]; then
    printf '  FAIL A.2: foo.ts lock still held by A\n' >&2; fail=1
  fi

  # A.3: pending.jsonl has stale_active from watchdog.
  local stale_count
  stale_count=$(jq -rs '[.[] | select(.kind == "stale_active" and .source == "watchdog")] | length' \
    "$COORD_DIR/mediator/pending.jsonl" 2>/dev/null || printf 0)
  if [ "$stale_count" -lt 1 ]; then
    printf '  FAIL A.3: no stale_active pending entry from watchdog (count=%s)\n' "$stale_count" >&2; fail=1
  fi

  # A.4: MEDIATOR_VERDICT event recorded.
  local verdict_count
  verdict_count=$(jq -rs '[.[] | select(.kind == "MEDIATOR_VERDICT")] | length' \
    "$COORD_DIR/events.jsonl" 2>/dev/null || printf 0)
  if [ "$verdict_count" -lt 1 ]; then
    printf '  FAIL A.4: no MEDIATOR_VERDICT event recorded\n' >&2; fail=1
  fi

  # A.5: B's Write didn't get a deny (no permissionDecision in stdout).
  case "${STDOUT_OF_B_WRITE:-}" in
    *permissionDecision*deny*)
      printf '  FAIL A.5: B Write got deny: %s\n' "$STDOUT_OF_B_WRITE" >&2; fail=1
      ;;
  esac

  # A.6: No lockdown active.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL A.6: spurious lockdown active\n' >&2; fail=1
  fi

  return "$fail"
}

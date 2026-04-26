#!/usr/bin/env bash
# 04_healthy_no_anomalies/timeline.sh — manual escalation on clean
# system → advice verdict, no mutation.

set -uo pipefail

scenario_run() {
  local hooks="$COORD_DIR/hooks"
  local sid_a="sid-a-healthy-0001"
  local sid_b="sid-b-healthy-0001"

  # 1. Register both sessions cleanly.
  for sid in "$sid_a" "$sid_b"; do
    printf '%s' '{"session_id":"'"$sid"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
      | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
          "$hooks/session_start.sh" >/dev/null
  done

  # Capture initial sessions count for D.4.
  PRE_COUNT=$(jq '.sessions | length' "$COORD_DIR/sessions.json")
  export PRE_COUNT

  # 2. Operator manual escalation.
  local coord_bin="$COORD_DIR/bin/coord"
  COORD_DIR="$COORD_DIR" "$coord_bin" mediate --reason "fixture test escalation" >/dev/null

  # 3. Mediator spawn (mocked): synthesize an advice verdict
  # directly. The default fake claude binary in init.sh produces
  # an advice verdict, but we write deterministically here.
  local verdict_ts
  verdict_ts="$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
  jq -nc --arg ts "$verdict_ts" \
    '{verdict_id:"fixture-04-uuid",
      ts:$ts,
      for_pending_entry:"manual-pending",
      mediator_session_id:"fixture-spawn",
      depth:1,
      action_type:"advice",
      severity:null,
      confidence:"auto_apply",
      reasoning:"System state is clean. No anomalies detected.",
      actions:[],
      message_to_caller:"No anomalies detected. System healthy.",
      message_to_others:null}' \
    >"$COORD_DIR/mediator/verdict/${verdict_ts}.json"

  # 4. Run pre_tool_use_any.sh from caller (sid_a) to consume
  # verdict (apply pipeline runs but with empty actions[]).
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"true"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_any.sh" >/dev/null

  sleep 0.3
}

scenario_assert() {
  local fail=0

  # D.1: manual pending entry present.
  local manual_count
  manual_count=$(jq -rs '[.[] | select(.kind == "manual" and .source == "user_invocation")] | length' \
    "$COORD_DIR/mediator/pending.jsonl" 2>/dev/null || printf 0)
  if [ "$manual_count" -lt 1 ]; then
    printf '  FAIL D.1: no manual pending entry (count=%s)\n' "$manual_count" >&2; fail=1
  fi

  # D.2: verdict file with action_type=advice present.
  local advice_count=0
  for vf in "$COORD_DIR/mediator/verdict"/*.json; do
    [ -f "$vf" ] || continue
    if [ "$(jq -r '.action_type // ""' "$vf" 2>/dev/null)" = "advice" ]; then
      advice_count=$((advice_count + 1))
    fi
  done
  if [ "$advice_count" -lt 1 ]; then
    printf '  FAIL D.2: no advice-action verdict file (count=%s)\n' "$advice_count" >&2; fail=1
  fi

  # D.3: no locks materialized.
  local lock_count
  lock_count=$(jq -r '.locks | length' "$COORD_DIR/sessions.json")
  if [ "$lock_count" != "0" ]; then
    printf '  FAIL D.3: locks materialized (count=%s)\n' "$lock_count" >&2; fail=1
  fi

  # D.4: sessions count unchanged (no eviction).
  local post_count
  post_count=$(jq '.sessions | length' "$COORD_DIR/sessions.json")
  if [ "$post_count" != "${PRE_COUNT:-0}" ]; then
    printf '  FAIL D.4: sessions count changed (pre=%s post=%s)\n' \
      "$PRE_COUNT" "$post_count" >&2; fail=1
  fi

  # D.5: no lockdown.
  if [ -f "$COORD_DIR/mediator/lockdown.json" ]; then
    printf '  FAIL D.5: spurious lockdown active\n' >&2; fail=1
  fi

  return "$fail"
}

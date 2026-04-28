#!/usr/bin/env bash
# 01_task_open_simple_happy_path — Plan §5 Phase 6 Done-when #1:
# "Happy path: A locks foo.ts, B opens a SIMPLE task, A processes
#  task at release; B receives COMPLETED notification with diff."
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-01-happy"
  local sid_b="sid-b-01-happy"
  local target="$WORKDIR/api.ts"

  coord_fixture_p6_register_session "$sid_a"
  coord_fixture_p6_register_session "$sid_b"

  # A acquires lock on api.ts.
  coord_fixture_p6_acquire "$target" "$sid_a"

  # B opens a SIMPLE task targeting "function getUser" (anchor
  # window 50-60 — non-overlapping with A's intended edit at 1-5).
  TASK_OPEN_OUT=$(coord_fixture_p6_task_open "$sid_b" "$target" \
    SIMPLE \
    '{"search":"function getUser","window_lines":"50-60"}' \
    "rename to fetchUser" 2>&1) || true
  export TASK_OPEN_OUT

  # Confirm task persisted.
  TASK_RECORD=$(jq -c --arg t "$target" '.locks[$t].tasks[0]' \
    "$COORD_DIR/sessions.json")
  export TASK_RECORD

  # A's edit completes (lines 1-5 — no overlap with anchor 50-60).
  # Mock claude returns COMPLETED outcome with diff.
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"COMPLETED","diff":"--- a/api.ts\n+++ b/api.ts\n@@ -50,1 +50,1 @@\n-function getUser() { return null; }\n+function fetchUser() { return null; }","affected_lines":[50,50],"rationale":"Renamed signature; no caller analysis needed for this fixture scenario."}'
  POST_OUT=$(coord_fixture_p6_post_write "$sid_a" "$target" 1 5 2>&1) || true
  export POST_OUT

  # Snapshot notifications state BEFORE pre_any delivery (pre_any
  # clears notifications[<sid>] arrays after surfacing them in
  # additionalContext per existing Phase 1+2 mechanism).
  NOTIF_PRE_ANY=$(jq -c --arg op "$sid_b" --arg t "$target" \
    '.notifications[$op][$t] // []' "$COORD_DIR/sessions.json")
  export NOTIF_PRE_ANY

  # B's next PreToolUse should surface the TASK_OUTCOME notification
  # in additionalContext (and clear the array as part of delivery).
  PRE_ANY_OUT=$(coord_fixture_p6_pre_any "$sid_b" "Read" "$WORKDIR/bar.ts" 2>&1) || true
  export PRE_ANY_OUT

  export SID_A="$sid_a" SID_B="$sid_b" TARGET_FILE="$target"
  sleep 0.2
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. coord task-open succeeded ("task created" stdout).
  if ! printf '%s' "$TASK_OPEN_OUT" | grep -q "task created"; then
    printf '  FAIL 1: coord task-open did not emit "task created"\n' >&2
    printf '         OUT=%s\n' "$TASK_OPEN_OUT" >&2
    fail=1
  fi

  # 2. Task record persisted with full schema fields.
  if ! printf '%s' "$TASK_RECORD" | jq -e '
    (.opener == "'"$SID_B"'")
    and (.complexity == "SIMPLE")
    and (.anchor.search == "function getUser")
    and (.anchor.window_lines == "50-60")
    and (.affected_lines_at_open == [50, 60])
    and (.status == "PENDING")
  ' >/dev/null; then
    printf '  FAIL 2: task record schema mismatch: %s\n' "$TASK_RECORD" >&2
    fail=1
  fi

  # 3. After post_tool_use_write: lock removed.
  if jq -e --arg t "$TARGET_FILE" '.locks[$t]' "$COORD_DIR/sessions.json" >/dev/null 2>&1; then
    printf '  FAIL 3: lock not released after post_tool_use_write\n' >&2
    fail=1
  fi

  # 4. TASK_OUTCOME_PERSISTED event emitted with COMPLETED status +
  #    full diff in audit payload.
  local n
  n=$(jq -rs '[.[] | select(.kind == "TASK_OUTCOME_PERSISTED")] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 4: no TASK_OUTCOME_PERSISTED event emitted\n' >&2
    fail=1
  fi
  if ! jq -rs '[.[] | select(.kind == "TASK_OUTCOME_PERSISTED" and .payload.status == "COMPLETED")] | length' \
       "$events" 2>/dev/null | grep -q '^[1-9]'; then
    printf '  FAIL 4b: no COMPLETED status in TASK_OUTCOME_PERSISTED event\n' >&2
    fail=1
  fi

  # 5. Notification was queued at .notifications[<sid_b>][<target>]
  #    by the task processor (NOTIF_PRE_ANY snapshot taken BEFORE
  #    pre_tool_use_any.sh ran — the hook clears the array after
  #    surfacing in additionalContext).
  if ! printf '%s' "$NOTIF_PRE_ANY" | jq -e '
    length == 1
    and (.[0] | contains("Status: COMPLETED"))
    and (.[0] | test("[Rr]enamed"))
  ' >/dev/null; then
    printf '  FAIL 5: TASK_OUTCOME notification not queued for opener (pre-delivery snapshot empty)\n' >&2
    printf '         NOTIF_PRE_ANY=%s\n' "$NOTIF_PRE_ANY" >&2
    fail=1
  fi

  # 5b. pre_tool_use_any.sh delivered the notification in
  #     additionalContext.
  if ! printf '%s' "$PRE_ANY_OUT" | jq -e \
       '.hookSpecificOutput.additionalContext | test("Status: COMPLETED")' \
       >/dev/null 2>&1; then
    printf '  FAIL 5b: pre_tool_use_any did not deliver TASK_OUTCOME in additionalContext\n' >&2
    printf '         OUT=%s\n' "$PRE_ANY_OUT" >&2
    fail=1
  fi

  # 6. Phase 6 invariant — no permissionDecision in any output path.
  if printf '%s\n%s\n%s' "$TASK_OPEN_OUT" "$POST_OUT" "$PRE_ANY_OUT" \
       | grep -q '"permissionDecision"'; then
    printf '  FAIL 6: permissionDecision found in output (Phase 6 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

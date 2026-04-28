#!/usr/bin/env bash
# 04_self_delegation_defer_continue_return — Plan §5 Phase 6
# Done-when #4: "Self-delegation: B defers, continues, later
# sees reminder, returns." Phase 6 binding (PR-PHASE6-02 +
# Decision 2): "unresolved" semantic is file-unlock-based;
# reminder fires when file becomes unlocked.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-04-defer"
  local sid_b="sid-b-04-defer"
  local target="$WORKDIR/foo.ts"
  printf 'function defer_target() { return 0; }\n' >"$target"

  coord_fixture_p6_register_session "$sid_a"
  coord_fixture_p6_register_session "$sid_b"

  # A holds lock on foo.ts. B sees a deny banner if it tries to
  # write — fixture skips that exposition; goes straight to the
  # self-delegate flow.
  coord_fixture_p6_acquire "$target" "$sid_a"

  # B coord self-delegate: defers work for later.
  SELF_DELEGATE_OUT=$(coord_fixture_p6_self_delegate "$sid_b" \
    "$target" "update signature" 2>&1)
  SELF_DELEGATE_RC=$?
  export SELF_DELEGATE_OUT SELF_DELEGATE_RC

  # Confirm self_tasks[$sid_b] populated.
  SELF_TASKS_AFTER_OPEN=$(jq -c --arg s "$sid_b" \
    '.self_tasks[$s] // []' "$COORD_DIR/sessions.json")
  export SELF_TASKS_AFTER_OPEN

  # B continues other work — runs PreToolUse on a different file.
  # File is still locked → no reminder yet.
  PRE_BEFORE_RELEASE=$(coord_fixture_p6_pre_any "$sid_b" "Read" \
    "$WORKDIR/bar.ts" 2>&1)
  export PRE_BEFORE_RELEASE

  # A releases the lock.
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    'del(.locks[$f]) | .sessions[$sid].last_activity_at = $now' \
    --arg f "$target" --arg sid "$sid_a" \
    --arg now "$(coord_now_iso8601)"

  # B's NEXT PreToolUse — reminder should fire.
  PRE_AFTER_RELEASE=$(coord_fixture_p6_pre_any "$sid_b" "Read" \
    "$WORKDIR/bar.ts" 2>&1)
  export PRE_AFTER_RELEASE

  # Snapshot state for assertions.
  LAST_REMINDED=$(jq -r --arg s "$sid_b" \
    '.self_tasks[$s][0].last_reminded_at' "$COORD_DIR/sessions.json")
  export LAST_REMINDED

  export SID_A="$sid_a" SID_B="$sid_b" TARGET_FILE="$target"
  sleep 0.2
}

scenario_assert() {
  local fail=0
  local events="$COORD_DIR/events.jsonl"

  # 1. coord self-delegate succeeded (rc 0 + banner).
  if [ "$SELF_DELEGATE_RC" != "0" ]; then
    printf '  FAIL 1: coord self-delegate rc=%s; expected 0\n' \
      "$SELF_DELEGATE_RC" >&2
    fail=1
  fi
  if ! printf '%s' "$SELF_DELEGATE_OUT" | grep -q "self-task created"; then
    printf '  FAIL 1b: stdout missing "self-task created"\n' >&2
    fail=1
  fi

  # 2. self_tasks[$sid_b] has the entry with required fields.
  if ! printf '%s' "$SELF_TASKS_AFTER_OPEN" | jq -e '
    length == 1
    and (.[0].file == "'"$TARGET_FILE"'")
    and (.[0].instruction == "update signature")
    and (.[0].prompt_id | type == "string")
    and (.[0].last_reminded_at == null)
  ' >/dev/null; then
    printf '  FAIL 2: self_tasks entry mismatch: %s\n' \
      "$SELF_TASKS_AFTER_OPEN" >&2
    fail=1
  fi

  # 3. SELF_TASK_OPENED event emitted.
  local n
  n=$(jq -rs '[.[] | select(.kind == "SELF_TASK_OPENED")] | length' \
       "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 3: SELF_TASK_OPENED event missing\n' >&2
    fail=1
  fi

  # 4. Pre-release PreToolUse: NO reminder injected (file still
  #    held by A).
  if printf '%s' "$PRE_BEFORE_RELEASE" | grep -q "self-task pending"; then
    printf '  FAIL 4: reminder injected while file still locked\n' >&2
    fail=1
  fi

  # 5. Post-release PreToolUse: reminder injected.
  if ! printf '%s' "$PRE_AFTER_RELEASE" | jq -e \
       '.hookSpecificOutput.additionalContext | test("self-task pending")' \
       >/dev/null 2>&1; then
    printf '  FAIL 5: reminder NOT injected after release\n' >&2
    printf '         OUT=%s\n' "$PRE_AFTER_RELEASE" >&2
    fail=1
  fi
  if ! printf '%s' "$PRE_AFTER_RELEASE" | jq -e \
       '.hookSpecificOutput.additionalContext | test("update signature")' \
       >/dev/null 2>&1; then
    printf '  FAIL 5b: reminder missing instruction text\n' >&2
    fail=1
  fi
  if ! printf '%s' "$PRE_AFTER_RELEASE" | jq -e \
       '.hookSpecificOutput.additionalContext | test("is now free")' \
       >/dev/null 2>&1; then
    printf '  FAIL 5c: reminder missing "is now free" phrase\n' >&2
    fail=1
  fi

  # 6. last_reminded_at populated post-reminder (no longer null).
  if [ "$LAST_REMINDED" = "null" ] || [ -z "$LAST_REMINDED" ]; then
    printf '  FAIL 6: last_reminded_at not set after reminder injection (got: %s)\n' \
      "$LAST_REMINDED" >&2
    fail=1
  fi

  # 7. SELF_TASK_REMINDER event emitted.
  n=$(jq -rs '[.[] | select(.kind == "SELF_TASK_REMINDER")] | length' \
       "$events" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf '  FAIL 7: SELF_TASK_REMINDER event missing\n' >&2
    fail=1
  fi

  # 8. Phase 6 invariant — no permissionDecision in any output.
  if printf '%s\n%s\n%s' "$SELF_DELEGATE_OUT" "$PRE_BEFORE_RELEASE" \
       "$PRE_AFTER_RELEASE" | grep -q '"permissionDecision"'; then
    printf '  FAIL 8: permissionDecision in output (Phase 6 invariant)\n' >&2
    fail=1
  fi

  return "$fail"
}

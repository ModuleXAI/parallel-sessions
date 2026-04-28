#!/usr/bin/env bash
# 02_anchor_ambiguous_conflict — Plan §5 Phase 6 Done-when #2:
# "Ambiguous anchor → CONFLICT before application." Phase 6
# binding: ambiguous anchor is rejected at CLI level (Decision 6
# — exit 1 + stderr; NOT permissionDecision; NOT a task outcome).
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-02-ambig"
  local sid_b="sid-b-02-ambig"
  local target="$WORKDIR/dup.ts"

  coord_fixture_p6_register_session "$sid_a"
  coord_fixture_p6_register_session "$sid_b"

  # Seed file with the same anchor string appearing 3 times.
  printf 'function helper() { return 1; }\nfunction helper() { return 2; }\nfunction helper() { return 3; }\n' \
    >"$target"

  # A acquires lock so the file is contended.
  coord_fixture_p6_acquire "$target" "$sid_a"

  # B attempts coord task-open with an ambiguous anchor.
  set +e
  TASK_OPEN_OUT=$(coord_fixture_p6_task_open "$sid_b" "$target" \
    SIMPLE \
    '{"search":"function helper","window_lines":"1-3"}' \
    "rename" 2>&1)
  TASK_OPEN_RC=$?
  set -e
  export TASK_OPEN_OUT TASK_OPEN_RC

  # Snapshot post-rejection task queue (should be empty).
  TASKS_JSON=$(jq -c --arg t "$target" '.locks[$t].tasks // []' \
    "$COORD_DIR/sessions.json")
  export TASKS_JSON

  export SID_A="$sid_a" SID_B="$sid_b" TARGET_FILE="$target"
  sleep 0.1
}

scenario_assert() {
  local fail=0

  # 1. CLI exited with rc 1 (ambiguous anchor rejection per
  #    Decision 6).
  if [ "$TASK_OPEN_RC" != "1" ]; then
    printf '  FAIL 1: coord task-open rc=%s; expected 1 (ambiguous anchor)\n' \
      "$TASK_OPEN_RC" >&2
    fail=1
  fi

  # 2. stderr contains "anchor matches 3 candidates (expected 1)".
  if ! printf '%s' "$TASK_OPEN_OUT" | grep -q "anchor matches 3 candidates"; then
    printf '  FAIL 2: stderr missing "anchor matches 3 candidates"\n' >&2
    printf '         OUT=%s\n' "$TASK_OPEN_OUT" >&2
    fail=1
  fi

  # 3. NO persistence to locks[<file>].tasks[].
  local len
  len=$(printf '%s' "$TASKS_JSON" | jq -r 'length')
  if [ "$len" != "0" ]; then
    printf '  FAIL 3: tasks persisted despite rejection (len=%s)\n' "$len" >&2
    fail=1
  fi

  # 4. Phase 6 invariant — no permissionDecision in CLI output.
  if printf '%s' "$TASK_OPEN_OUT" | grep -q '"permissionDecision"'; then
    printf '  FAIL 4: permissionDecision found in CLI output (Phase 6 invariant)\n' >&2
    fail=1
  fi

  # 5. Lock entry on $TARGET_FILE remains (rejection does not
  #    affect existing lock state).
  if ! jq -e --arg t "$TARGET_FILE" --arg s "$SID_A" \
       '.locks[$t].session == $s' \
       "$COORD_DIR/sessions.json" >/dev/null; then
    printf '  FAIL 5: lock state mutated by rejection\n' >&2
    fail=1
  fi

  return "$fail"
}

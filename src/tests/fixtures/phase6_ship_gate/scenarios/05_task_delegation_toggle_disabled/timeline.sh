#!/usr/bin/env bash
# 05_task_delegation_toggle_disabled — Plan §5 Phase 6 Done-when
# #5: "task_delegation: false → deny message omits option (a),
# offers only self-delegate / passive-wait." Phase 6 binding
# (Decision 6 + Cand-14): toggle read via jq has() pattern;
# false literal vs absent key correctly distinguished.
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-05-toggle"
  local sid_b="sid-b-05-toggle"
  local target="$WORKDIR/foo.ts"
  printf 'function gated() { return 0; }\n' >"$target"

  coord_fixture_p6_register_session "$sid_a"
  coord_fixture_p6_register_session "$sid_b"

  # Disable task delegation.
  coord_fixture_p6_set_task_delegation false

  # A acquires lock on target.
  coord_fixture_p6_acquire "$target" "$sid_a"

  # B attempts pre_tool_use_write on target → deny banner with
  # toggle-FALSE wording.
  set +e
  PRE_WRITE_OUT=$(coord_fixture_p6_pre_write "$sid_b" "$target" 2>&1)
  PRE_WRITE_RC=$?
  set -e
  export PRE_WRITE_OUT PRE_WRITE_RC

  # B attempts coord task-open despite toggle false → CLI rejection.
  set +e
  TASK_OPEN_OUT=$(coord_fixture_p6_task_open "$sid_b" "$target" \
    SIMPLE \
    '{"search":"function gated","window_lines":"1-1"}' \
    "edit" 2>&1)
  TASK_OPEN_RC=$?
  set -e
  export TASK_OPEN_OUT TASK_OPEN_RC

  # B coord self-delegate STILL works (option (b) always available
  # per Decision 6).
  set +e
  SELF_DELEGATE_OUT=$(coord_fixture_p6_self_delegate "$sid_b" \
    "$target" "edit later" 2>&1)
  SELF_DELEGATE_RC=$?
  set -e
  export SELF_DELEGATE_OUT SELF_DELEGATE_RC

  export SID_A="$sid_a" SID_B="$sid_b" TARGET_FILE="$target"
  sleep 0.2
}

scenario_assert() {
  local fail=0

  # 1. pre_tool_use_write emitted permissionDecision: deny.
  if ! printf '%s' "$PRE_WRITE_OUT" | jq -e \
       '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf '  FAIL 1: pre_tool_use_write did not emit deny\n' >&2
    printf '         OUT=%s\n' "$PRE_WRITE_OUT" >&2
    fail=1
  fi

  # 2. Banner shows toggle-FALSE wording — mentions "task delegation
  #    is disabled in this repo".
  if ! printf '%s' "$PRE_WRITE_OUT" | jq -e \
       '.hookSpecificOutput.permissionDecisionReason
        | test("task delegation is disabled in this repo")' \
       >/dev/null 2>&1; then
    printf '  FAIL 2: deny banner missing toggle-FALSE wording\n' >&2
    fail=1
  fi

  # 3. Banner OMITS option (a) — Decision 6 binding.
  if printf '%s' "$PRE_WRITE_OUT" | jq -e \
       '.hookSpecificOutput.permissionDecisionReason
        | test("\\(a\\) Delegate")' >/dev/null 2>&1; then
    printf '  FAIL 3: deny banner shows option (a) despite toggle FALSE\n' >&2
    fail=1
  fi

  # 4. Banner SHOWS option (b) self-delegate + (c) coord wait.
  if ! printf '%s' "$PRE_WRITE_OUT" | jq -e \
       '.hookSpecificOutput.permissionDecisionReason
        | test("\\(b\\) Self-delegate")' >/dev/null 2>&1; then
    printf '  FAIL 4: deny banner missing option (b)\n' >&2
    fail=1
  fi
  if ! printf '%s' "$PRE_WRITE_OUT" | jq -e \
       '.hookSpecificOutput.permissionDecisionReason
        | test("\\(c\\) Passively wait")' >/dev/null 2>&1; then
    printf '  FAIL 4b: deny banner missing option (c)\n' >&2
    fail=1
  fi

  # 5. coord task-open exit 1 with disabled-per-repo error.
  if [ "$TASK_OPEN_RC" != "1" ]; then
    printf '  FAIL 5: coord task-open rc=%s; expected 1 (toggle disabled)\n' \
      "$TASK_OPEN_RC" >&2
    fail=1
  fi
  if ! printf '%s' "$TASK_OPEN_OUT" | grep -q \
       "task_delegation disabled per repo"; then
    printf '  FAIL 5b: stderr missing "task_delegation disabled per repo"\n' >&2
    printf '         OUT=%s\n' "$TASK_OPEN_OUT" >&2
    fail=1
  fi

  # 6. coord self-delegate STILL works under toggle FALSE
  #    (option (b) always available per Decision 6).
  if [ "$SELF_DELEGATE_RC" != "0" ]; then
    printf '  FAIL 6: coord self-delegate rc=%s; expected 0 under toggle FALSE\n' \
      "$SELF_DELEGATE_RC" >&2
    fail=1
  fi
  if ! printf '%s' "$SELF_DELEGATE_OUT" | grep -q "self-task created"; then
    printf '  FAIL 6b: self-delegate did not emit "self-task created"\n' >&2
    fail=1
  fi
  # Confirm persisted.
  if ! jq -e --arg s "$SID_B" '.self_tasks[$s] | length == 1' \
       "$COORD_DIR/sessions.json" >/dev/null; then
    printf '  FAIL 6c: self-delegate did not persist self_tasks entry\n' >&2
    fail=1
  fi

  # 7. Cand-14 verification: jq has() pattern correctly read FALSE
  #    literal (the deny banner showed toggle-FALSE wording, which
  #    only happens if has() correctly distinguished present-and-
  #    false from absent-key).
  if printf '%s' "$PRE_WRITE_OUT" | jq -e \
       '.hookSpecificOutput.permissionDecisionReason
        | test("\\(a\\) Delegate")' >/dev/null 2>&1; then
    printf '  FAIL 7: jq // false-trigger regression — toggle FALSE silently bypassed\n' >&2
    fail=1
  fi

  return "$fail"
}

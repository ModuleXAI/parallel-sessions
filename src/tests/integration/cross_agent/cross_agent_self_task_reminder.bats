#!/usr/bin/env bats
# Cross-agent self-task reminder scenarios (PR F.2 — reviewer #8).
#
# Validates the F-D4-03 deferral: codex sessions DO get the
# SELF_TASK_REMINDER event in the audit log (bookkeeping intact) but
# NEVER see the reminder banner because Codex's PreToolUse parser
# rejects additionalContext (D-D4-02 / output_parser.rs:337-348). The
# tests confirm both halves so a future Phase F follow-up that routes
# reminders through user_prompt_submit.sh has concrete user-impact
# evidence to justify the work.
#
# Companion: tests verify Claude's self-task reminder mechanism is
# intact under the mixed-mode install — the F-D4-03 degradation is
# Codex-specific.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
  # Source self_tasks lib with COORD_DIR set so coord_self_task_open
  # writes into the test sessions.json.
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/self_tasks.sh"
}
teardown() { xagent_teardown; }

@test "self-task reminder: codex any hook logs SELF_TASK_REMINDER but emits NO banner (F-D4-03 confirmed)" {
  xagent_session_start codex "cx-st1"
  printf 'old\n' >"$XAGENT_TMP/self_task_target.ts"
  # Open a self-task for the codex session on a file currently free
  # (no peer holds it).
  PID=$(coord_self_task_open "cx-st1" "$XAGENT_TMP/self_task_target.ts" "fix the bug")
  : >"$COORD_DIR/events.jsonl"
  # Trigger codex any hook — should run the self-task reminder
  # bookkeeping path (per pre_tool_use_any.sh § "Self-task reminder
  # bookkeeping (no banner)").
  xagent_pretooluse_any codex "cx-st1"
  sleep 0.3
  # Audit: SELF_TASK_REMINDER event logged with source=pre_tool_use_any.
  run jq -rs '[.[] | select(.kind == "SELF_TASK_REMINDER" and .session == "cx-st1" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # F-D4-03 confirmation: NO banner reaches the model. The codex any
  # hook outputs empty stdout OR no additionalContext.
  if [ -n "$XAGENT_LAST_OUTPUT" ]; then
    echo "$XAGENT_LAST_OUTPUT" \
      | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
}

@test "self-task reminder: codex user_prompt_submit also does NOT deliver the reminder (deferral scope)" {
  # Verifies that the F-D4-03 degradation is end-to-end on Codex —
  # neither pre_tool_use_any.sh NOR user_prompt_submit.sh surfaces the
  # reminder. A future Phase F follow-up could extend D.3's hook to
  # close the gap; this test is the baseline against which that future
  # PR's success is measured.
  xagent_session_start codex "cx-st2"
  printf 'old\n' >"$XAGENT_TMP/st2_target.ts"
  PID=$(coord_self_task_open "cx-st2" "$XAGENT_TMP/st2_target.ts" "rename")
  : >"$COORD_DIR/events.jsonl"
  # Trigger UserPromptSubmit for the codex session.
  local input
  input=$(jq -nc --arg s "cx-st2" --arg cwd "$XAGENT_TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"UserPromptSubmit",
    prompt:"do the task"
  }')
  _xagent_run_hook "COORD_ENABLED=1" "$COORD_DIR/hooks/codex/user_prompt_submit.sh" "$input"
  # The codex user_prompt_submit hook DOES emit additionalContext for
  # HEAD drift, but does NOT mention self-tasks. Confirm the latter.
  if [ -n "$XAGENT_LAST_OUTPUT" ]; then
    case "$(printf '%s' "$XAGENT_LAST_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // ""')" in
      *self-task*|*'self_task'*|*reminder*|*"$XAGENT_TMP/st2_target.ts"*)
        return 1   # F-D4-03 would NO LONGER hold; test should fail
                   # so the next reviewer knows to update the deferral.
        ;;
    esac
  fi
}

@test "self-task reminder: claude path retains in-turn banner (mechanism intact for claude)" {
  xagent_session_start claude_code "ch-st3"
  printf 'old\n' >"$XAGENT_TMP/st3_target.ts"
  PID=$(coord_self_task_open "ch-st3" "$XAGENT_TMP/st3_target.ts" "edit")
  xagent_pretooluse_any claude_code "ch-st3"
  # Claude any hook DOES emit additionalContext containing the reminder.
  [ -n "$XAGENT_LAST_OUTPUT" ]
  echo "$XAGENT_LAST_OUTPUT" \
    | jq -e '.hookSpecificOutput.additionalContext | contains("reminder")' >/dev/null
}

@test "self-task reminder: cross-agent independence — codex's self-task is invisible to claude any hook" {
  # A self-task opened by a codex session is keyed by sid; the claude
  # any hook for a DIFFERENT session must not pick it up. This is a
  # baseline isolation check, not specific to F-D4-03 — but reinforces
  # that the per-session scoping is honored across agents.
  xagent_session_start codex       "cx-st4"
  xagent_session_start claude_code "ch-st4"
  printf 'old\n' >"$XAGENT_TMP/st4_target.ts"
  coord_self_task_open "cx-st4" "$XAGENT_TMP/st4_target.ts" "codex-task" >/dev/null
  : >"$COORD_DIR/events.jsonl"
  # Claude any hook for a DIFFERENT session.
  xagent_pretooluse_any claude_code "ch-st4"
  sleep 0.3
  # No SELF_TASK_REMINDER for ch-st4 — it has no self-tasks.
  run jq -rs '[.[] | select(.kind == "SELF_TASK_REMINDER" and .session == "ch-st4")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

#!/usr/bin/env bats
# Cross-agent notification fan-out scenarios (PR F.2 — reviewer #7).
#
# When agent A holds a lock and agent B (the OTHER agent type) is
# denied during the hold window, A's release MUST populate a
# notification entry for B. Validates:
#   - Codex release notifies a denied Claude session.
#   - Claude release notifies a denied Codex session.
#   - The 4-tier diff_summary chain (T5.04) operates regardless of
#     which agent type held the lock.
#   - Codex's any hook atomically clears notifications (bookkeeping
#     intact per F-D4-04) but does NOT emit a banner — confirming the
#     F-D4-03 deferral is a real degradation worth a Phase F follow-up.

load "../../helpers/common"
load "helpers"

setup()    { xagent_setup; }
teardown() { xagent_teardown; }

@test "notification: codex release populates a notification for the denied Claude session" {
  xagent_session_start codex       "cx-relA"
  xagent_session_start claude_code "ch-waitA"
  printf 'old\n' >"$XAGENT_TMP/foo.ts"
  # Codex holds.
  xagent_pretooluse_write codex "cx-relA" "$XAGENT_TMP/foo.ts"
  ! xagent_last_was_deny
  # Claude denied during hold.
  xagent_pretooluse_write claude_code "ch-waitA" "$XAGENT_TMP/foo.ts"
  xagent_last_was_deny
  # In production the denied session would call `coord wait` to enqueue
  # itself; helpers don't simulate the CLI, so seed the queue directly
  # via the lib API. notify_waiters scans wait_queues, not LOCK_DENIED.
  xagent_wait_enqueue "ch-waitA" "$XAGENT_TMP/foo.ts"
  # Codex releases via Stop (D-10: stop is graceful release).
  xagent_session_stop codex "cx-relA"
  sleep 0.3
  # Notification populated for claude.
  run xagent_notification_count "ch-waitA" "$XAGENT_TMP/foo.ts"
  [ "$output" -ge "1" ]
}

@test "notification: claude release populates a notification for the denied Codex session" {
  xagent_session_start claude_code "ch-relB"
  xagent_session_start codex       "cx-waitB"
  printf 'old\n' >"$XAGENT_TMP/bar.ts"
  xagent_pretooluse_write claude_code "ch-relB" "$XAGENT_TMP/bar.ts"
  ! xagent_last_was_deny
  xagent_pretooluse_write codex "cx-waitB" "$XAGENT_TMP/bar.ts"
  xagent_last_was_deny
  xagent_wait_enqueue "cx-waitB" "$XAGENT_TMP/bar.ts"
  xagent_session_stop claude_code "ch-relB"
  sleep 0.3
  run xagent_notification_count "cx-waitB" "$XAGENT_TMP/bar.ts"
  [ "$output" -ge "1" ]
}

@test "notification: codex any hook atomically clears notifications (F-D4-04: bookkeeping)" {
  xagent_session_start claude_code "ch-relC"
  xagent_session_start codex       "cx-waitC"
  printf 'old\n' >"$XAGENT_TMP/baz.ts"
  xagent_pretooluse_write claude_code "ch-relC" "$XAGENT_TMP/baz.ts"
  xagent_pretooluse_write codex "cx-waitC" "$XAGENT_TMP/baz.ts"
  xagent_wait_enqueue "cx-waitC" "$XAGENT_TMP/baz.ts"
  xagent_session_stop claude_code "ch-relC"
  sleep 0.3
  # Pre-condition: codex has a notification queued.
  run xagent_notification_count "cx-waitC" "$XAGENT_TMP/baz.ts"
  [ "$output" -ge "1" ]
  # Codex any hook fires → bookkeeping clears notifications.
  xagent_pretooluse_any codex "cx-waitC"
  sleep 0.3
  run xagent_notification_count "cx-waitC" "$XAGENT_TMP/baz.ts"
  [ "$output" = "0" ]
  # NOTIFICATION_DELIVER event logged with source=pre_tool_use_any.
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_DELIVER" and .session == "cx-waitC" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "notification: codex any hook does NOT emit banner (D-D4-02 invariant + F-D4-03 deferral)" {
  # Same setup as above; verify that despite the bookkeeping clear,
  # the codex agent receives NO model-visible banner. This confirms
  # F-D4-03 is a real degradation justifying the Phase F follow-up
  # candidate (route reminders/notifications through user_prompt_submit.sh
  # for codex).
  xagent_session_start claude_code "ch-relD"
  xagent_session_start codex       "cx-waitD"
  printf 'old\n' >"$XAGENT_TMP/qux.ts"
  xagent_pretooluse_write claude_code "ch-relD" "$XAGENT_TMP/qux.ts"
  xagent_pretooluse_write codex "cx-waitD" "$XAGENT_TMP/qux.ts"
  xagent_wait_enqueue "cx-waitD" "$XAGENT_TMP/qux.ts"
  xagent_session_stop claude_code "ch-relD"
  sleep 0.3
  xagent_pretooluse_any codex "cx-waitD"
  # Codex any hook output: empty OR no additionalContext.
  if [ -n "$XAGENT_LAST_OUTPUT" ]; then
    echo "$XAGENT_LAST_OUTPUT" \
      | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
  # Bookkeeping ran (notification cleared).
  run xagent_notification_count "cx-waitD" "$XAGENT_TMP/qux.ts"
  [ "$output" = "0" ]
}

@test "notification: claude any hook DOES deliver banner (mechanism intact for claude path)" {
  # Symmetric proof that claude's path retains banner delivery — the
  # cross-agent fan-out works correctly when the WAITER is claude.
  xagent_session_start codex       "cx-relE"
  xagent_session_start claude_code "ch-waitE"
  printf 'old\n' >"$XAGENT_TMP/quux.ts"
  xagent_pretooluse_write codex "cx-relE" "$XAGENT_TMP/quux.ts"
  xagent_pretooluse_write claude_code "ch-waitE" "$XAGENT_TMP/quux.ts"
  xagent_wait_enqueue "ch-waitE" "$XAGENT_TMP/quux.ts"
  xagent_session_stop codex "cx-relE"
  sleep 0.3
  run xagent_notification_count "ch-waitE" "$XAGENT_TMP/quux.ts"
  [ "$output" -ge "1" ]
  xagent_pretooluse_any claude_code "ch-waitE"
  # Claude's any hook DOES emit additionalContext when notifications
  # were pending — that's the production behavior.
  [ -n "$XAGENT_LAST_OUTPUT" ]
  echo "$XAGENT_LAST_OUTPUT" \
    | jq -e '.hookSpecificOutput.additionalContext | contains("notifications pending") or contains("Lock released")' >/dev/null
  # Notifications cleared.
  run xagent_notification_count "ch-waitE" "$XAGENT_TMP/quux.ts"
  [ "$output" = "0" ]
}

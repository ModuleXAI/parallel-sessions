#!/usr/bin/env bats
# Smoke test for cross-agent helpers (PR F.1).
#
# Validates that the helpers under src/tests/integration/cross_agent/
# helpers.bash actually work end-to-end. F.2's scenario tests build on
# this surface; this file proves the surface is sound.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
}
teardown() {
  xagent_teardown
}

# === Session lifecycle ===

@test "xagent: setup installs both adapters into shared .coord/" {
  [ -d "$COORD_DIR" ]
  # Claude hooks flat at .coord/hooks/.
  [ -x "$COORD_DIR/hooks/session_start.sh" ]
  [ -x "$COORD_DIR/hooks/pre_tool_use_write.sh" ]
  # Codex hooks under .coord/hooks/codex/.
  [ -x "$COORD_DIR/hooks/codex/session_start.sh" ]
  [ -x "$COORD_DIR/hooks/codex/pre_tool_use_apply_patch.sh" ]
  # Both registration files exist.
  [ -f "$XAGENT_TMP/.claude/settings.local.json" ]
  [ -f "$XAGENT_TMP/.codex/hooks.json" ]
}

@test "xagent: claude session_start registers row with agent=claude_code" {
  local SID="x-claude-1"
  xagent_session_start claude_code "$SID"
  [ -e "$COORD_DIR/sessions/${SID}.active" ]
  run xagent_session_agent "$SID"
  [ "$output" = "claude_code" ]
  run xagent_session_state "$SID"
  [ "$output" = "ACTIVE" ]
}

@test "xagent: codex session_start registers row with agent=codex" {
  local SID="x-codex-1"
  xagent_session_start codex "$SID"
  [ -e "$COORD_DIR/sessions/${SID}.active" ]
  run xagent_session_agent "$SID"
  [ "$output" = "codex" ]
  run xagent_session_state "$SID"
  [ "$output" = "ACTIVE" ]
}

@test "xagent: schema 1.1 mixed rows — claude + codex sessions coexist" {
  xagent_session_start claude_code "x-claude-mixed"
  xagent_session_start codex       "x-codex-mixed"
  run xagent_session_count
  [ "$output" = "2" ]
  run xagent_session_agent "x-claude-mixed"
  [ "$output" = "claude_code" ]
  run xagent_session_agent "x-codex-mixed"
  [ "$output" = "codex" ]
}

# === Write operations ===

@test "xagent: claude pre-write on free file → lock acquired" {
  xagent_session_start claude_code "x-claude-w"
  printf 'old\n' >"$XAGENT_TMP/foo.ts"
  xagent_pretooluse_write claude_code "x-claude-w" "$XAGENT_TMP/foo.ts"
  ! xagent_last_was_deny
  run xagent_lock_holder "$XAGENT_TMP/foo.ts"
  [ "$output" = "x-claude-w" ]
}

@test "xagent: codex apply_patch on free file → lock acquired" {
  xagent_session_start codex "x-codex-w"
  xagent_pretooluse_write codex "x-codex-w" "$XAGENT_TMP/bar.ts"
  ! xagent_last_was_deny
  run xagent_lock_holder "$XAGENT_TMP/bar.ts"
  [ "$output" = "x-codex-w" ]
}

# === Cross-agent contention (the headline F.1 sanity check) ===

@test "xagent: claude holds lock → codex apply_patch is denied" {
  xagent_session_start claude_code "x-claude-holder"
  xagent_session_start codex       "x-codex-attempt"
  printf 'old\n' >"$XAGENT_TMP/contended.ts"
  xagent_pretooluse_write claude_code "x-claude-holder" "$XAGENT_TMP/contended.ts"
  ! xagent_last_was_deny
  # Now codex tries to write the same file.
  xagent_pretooluse_write codex "x-codex-attempt" "$XAGENT_TMP/contended.ts"
  xagent_last_was_deny
  # Deny reason mentions the holder's session id (8-char prefix).
  run xagent_last_deny_reason
  echo "$output" | grep -q "x-claude"
  # Lock still owned by Claude.
  run xagent_lock_holder "$XAGENT_TMP/contended.ts"
  [ "$output" = "x-claude-holder" ]
}

@test "xagent: codex holds lock → claude write is denied (inverse contention)" {
  xagent_session_start codex       "x-codex-holder"
  xagent_session_start claude_code "x-claude-attempt"
  xagent_pretooluse_write codex "x-codex-holder" "$XAGENT_TMP/inverse.ts"
  ! xagent_last_was_deny
  xagent_pretooluse_write claude_code "x-claude-attempt" "$XAGENT_TMP/inverse.ts"
  xagent_last_was_deny
  # Claude's deny banner truncates the holder to 8 chars (HOLDER_SHORT in
  # build_deny_reason). "x-codex-holder"[:8] = "x-codex-".
  run xagent_last_deny_reason
  echo "$output" | grep -q "x-codex-"
  run xagent_lock_holder "$XAGENT_TMP/inverse.ts"
  [ "$output" = "x-codex-holder" ]
}

# === Release + post hook ===

@test "xagent: claude post-write releases the lock" {
  xagent_session_start claude_code "x-claude-rel"
  printf 'old\n' >"$XAGENT_TMP/release.ts"
  xagent_pretooluse_write claude_code "x-claude-rel" "$XAGENT_TMP/release.ts"
  run xagent_lock_holder "$XAGENT_TMP/release.ts"
  [ "$output" = "x-claude-rel" ]
  xagent_posttooluse_write claude_code "x-claude-rel" "$XAGENT_TMP/release.ts"
  run xagent_lock_holder "$XAGENT_TMP/release.ts"
  [ "$output" = "" ]
}

@test "xagent: codex post-apply_patch releases the lock" {
  xagent_session_start codex "x-codex-rel"
  xagent_pretooluse_write codex "x-codex-rel" "$XAGENT_TMP/codex_release.ts"
  run xagent_lock_holder "$XAGENT_TMP/codex_release.ts"
  [ "$output" = "x-codex-rel" ]
  xagent_posttooluse_write codex "x-codex-rel" "$XAGENT_TMP/codex_release.ts"
  run xagent_lock_holder "$XAGENT_TMP/codex_release.ts"
  [ "$output" = "" ]
}

# === Stop hook (graceful) ===

@test "xagent: claude stop releases held locks" {
  xagent_session_start claude_code "x-claude-stop"
  printf 'old\n' >"$XAGENT_TMP/stop_test.ts"
  xagent_pretooluse_write claude_code "x-claude-stop" "$XAGENT_TMP/stop_test.ts"
  xagent_session_stop claude_code "x-claude-stop"
  run xagent_lock_holder "$XAGENT_TMP/stop_test.ts"
  [ "$output" = "" ]
}

@test "xagent: codex stop releases held locks (D-10: stop is the graceful release)" {
  xagent_session_start codex "x-codex-stop"
  xagent_pretooluse_write codex "x-codex-stop" "$XAGENT_TMP/cx_stop_test.ts"
  xagent_session_stop codex "x-codex-stop"
  run xagent_lock_holder "$XAGENT_TMP/cx_stop_test.ts"
  [ "$output" = "" ]
}

# === Event log inspection ===

@test "xagent: event_count_for counts events emitted by a given session" {
  xagent_session_start claude_code "x-claude-evt"
  printf 'old\n' >"$XAGENT_TMP/evt.ts"
  xagent_pretooluse_write claude_code "x-claude-evt" "$XAGENT_TMP/evt.ts"
  sleep 0.3
  run xagent_event_count_for LOCK_ACQUIRED "x-claude-evt"
  [ "$output" -ge "1" ]
  run xagent_event_count LOCK_ACQUIRED
  [ "$output" -ge "1" ]
}

# === Kill / abrupt termination ===

@test "xagent: kill drops marker without invoking stop (locks remain — watchdog territory)" {
  xagent_session_start codex "x-codex-kill"
  xagent_pretooluse_write codex "x-codex-kill" "$XAGENT_TMP/kill_test.ts"
  [ -e "$COORD_DIR/sessions/x-codex-kill.active" ]
  xagent_session_kill "x-codex-kill"
  [ ! -e "$COORD_DIR/sessions/x-codex-kill.active" ]
  # Lock still present — watchdog must observe and evict.
  run xagent_lock_holder "$XAGENT_TMP/kill_test.ts"
  [ "$output" = "x-codex-kill" ]
}

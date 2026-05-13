#!/usr/bin/env bats
# Cross-agent multi-file lock contention scenarios (PR F.2).
#
# Reviewer scenario: "multi-file apply_patch denied because one of N
# files held by other agent type". Exercises D.4's all-or-deny atomicity
# (D-12) where the blocking holder is a Claude session.

load "../../helpers/common"
load "helpers"

setup()    { xagent_setup; }
teardown() { xagent_teardown; }

@test "multi-file apply_patch denied when ONE of N files held by Claude" {
  xagent_session_start claude_code "ch-mfa1"
  xagent_session_start codex       "cx-mfa1"
  printf 'old\n' >"$XAGENT_TMP/free1.ts"
  printf 'old\n' >"$XAGENT_TMP/blocked.ts"
  printf 'old\n' >"$XAGENT_TMP/free2.ts"
  # Claude takes the middle file.
  xagent_pretooluse_write claude_code "ch-mfa1" "$XAGENT_TMP/blocked.ts"
  ! xagent_last_was_deny
  # Codex tries a 3-file patch including the blocked one → deny ALL.
  xagent_pretooluse_apply_patch_multifile "cx-mfa1" \
    "$XAGENT_TMP/free1.ts" "$XAGENT_TMP/blocked.ts" "$XAGENT_TMP/free2.ts"
  xagent_last_was_deny
  # The deny banner mentions the blocked path.
  run xagent_last_deny_reason
  echo "$output" | grep -q 'blocked.ts'
  # The two FREE files were NOT acquired (all-or-deny atomicity).
  run xagent_lock_holder "$XAGENT_TMP/free1.ts"
  [ "$output" = "" ]
  run xagent_lock_holder "$XAGENT_TMP/free2.ts"
  [ "$output" = "" ]
  # Claude's lock untouched.
  run xagent_lock_holder "$XAGENT_TMP/blocked.ts"
  [ "$output" = "ch-mfa1" ]
}

@test "multi-file apply_patch ALL free across both agent types → all locks land" {
  xagent_session_start codex "cx-mfa2"
  printf 'old\n' >"$XAGENT_TMP/a.ts"
  printf 'old\n' >"$XAGENT_TMP/b.ts"
  printf 'old\n' >"$XAGENT_TMP/c.ts"
  xagent_pretooluse_apply_patch_multifile "cx-mfa2" \
    "$XAGENT_TMP/a.ts" "$XAGENT_TMP/b.ts" "$XAGENT_TMP/c.ts"
  ! xagent_last_was_deny
  run xagent_lock_count
  [ "$output" = "3" ]
  for f in a b c; do
    run xagent_lock_holder "$XAGENT_TMP/${f}.ts"
    [ "$output" = "cx-mfa2" ]
  done
}

@test "multi-file apply_patch denied when claude holds one + codex holds another" {
  # Setup: Claude session holds a.ts; another Codex session holds b.ts;
  # the test's Codex session tries to apply_patch all of a/b/c. Both
  # blocked files appear in the deny banner; c.ts (free) NOT acquired.
  xagent_session_start claude_code "ch-mfa3"
  xagent_session_start codex       "cx-mfa3-other"
  xagent_session_start codex       "cx-mfa3-test"
  printf 'old\n' >"$XAGENT_TMP/a.ts"
  printf 'old\n' >"$XAGENT_TMP/b.ts"
  printf 'old\n' >"$XAGENT_TMP/c.ts"
  xagent_pretooluse_write claude_code "ch-mfa3" "$XAGENT_TMP/a.ts"
  xagent_pretooluse_write codex "cx-mfa3-other" "$XAGENT_TMP/b.ts"
  # Test session: 3-file apply_patch.
  xagent_pretooluse_apply_patch_multifile "cx-mfa3-test" \
    "$XAGENT_TMP/a.ts" "$XAGENT_TMP/b.ts" "$XAGENT_TMP/c.ts"
  xagent_last_was_deny
  # Banner enumerates BOTH blocked files (multi-file template).
  run xagent_last_deny_reason
  echo "$output" | grep -q 'a.ts'
  echo "$output" | grep -q 'b.ts'
  # c.ts NOT acquired by test session.
  run xagent_lock_holder "$XAGENT_TMP/c.ts"
  [ "$output" = "" ]
}

@test "claude write denied by codex apply_patch's lock (D-12 enforcement is symmetric)" {
  xagent_session_start codex       "cx-mfa4"
  xagent_session_start claude_code "ch-mfa4"
  printf 'old\n' >"$XAGENT_TMP/symmetric.ts"
  # Codex grabs the file via apply_patch.
  xagent_pretooluse_write codex "cx-mfa4" "$XAGENT_TMP/symmetric.ts"
  ! xagent_last_was_deny
  # Claude tries to Edit it.
  xagent_pretooluse_write claude_code "ch-mfa4" "$XAGENT_TMP/symmetric.ts"
  xagent_last_was_deny
  run xagent_lock_holder "$XAGENT_TMP/symmetric.ts"
  [ "$output" = "cx-mfa4" ]
}

#!/usr/bin/env bats
#
# bats_meta.bats — meta-tests guarding the test harness itself.
#
# F-014 root fix (T3.01): the legacy
#   `run bash -c "echo '$output' | grep -c '<pattern>' || true"`
# scaffold is apostrophe-fragile (an ASCII `'` in $output or in <pattern>
# silently terminates the inner single-quoted shell fragment, breaking the
# pipeline and producing a confusing assertion mismatch). The helper
# `_grep_output_for` in src/tests/helpers/common.bash replaces it.
#
# These tests assert:
#   1. The legacy pattern does not reappear in any .bats file under src/tests/.
#   2. The helper itself handles apostrophes in $output and <pattern> robustly.
#   3. The helper does not rebind bats's $output / $status (unlike the legacy
#      `run bash -c "..."` form, which clobbered them).

load "../helpers/common"

@test "F-014 meta: legacy 'bash -c \"echo \$output | grep\"' pattern is not present in any .bats file" {
  # The pattern is built from bracket-class chunks ([$], [|]) so this file
  # itself does not contain the literal legacy substring and cannot self-match.
  # Pure-comment lines are stripped before the check (precedent:
  # phase2_invariant.bats §"permissionDecision" guard) so that docstrings
  # referencing the legacy pattern for explanatory purposes do not trip the
  # architectural guard.
  local pattern='bash -c "echo .[$]output. [|] grep'
  local hits=""
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if grep -v '^[[:space:]]*#' "$f" | grep -qE "$pattern"; then
      hits="$hits$f"$'\n'
    fi
  done < <(find "$SRC_ROOT/tests" -type f \( -name '*.bats' -o -name 'common.bash' \))
  if [ -n "$hits" ]; then
    printf 'Legacy F-014 pattern reappeared in non-comment lines of:\n%s' "$hits" >&2
    printf 'Use _grep_output_for from src/tests/helpers/common.bash instead.\n' >&2
    return 1
  fi
}

@test "_grep_output_for: positive match on substring containing an apostrophe" {
  output="Phase 4's validator agent flagged a discrepancy"
  _grep_output_for "Phase 4's validator"
  _grep_output_for "discrepancy"
}

@test "_grep_output_for: negative match returns non-zero (suitable for ! prefix)" {
  output="harmless content here"
  ! _grep_output_for "this substring is not present"
}

@test "_grep_output_for: pattern itself may contain an apostrophe" {
  output="don't match the wrong pattern"
  _grep_output_for "don't match"
  ! _grep_output_for "this is absent"
}

@test "_grep_output_for: empty output never matches a non-empty pattern" {
  output=""
  ! _grep_output_for "anything"
}

@test "_grep_output_for: multi-line \$output matches a line-anchored substring" {
  output=$'line one\nline two with apostrophe '\''here'\''\nline three'
  _grep_output_for "line two with apostrophe"
  _grep_output_for "line three"
  ! _grep_output_for "line four"
}

@test "_grep_output_for: leaves bats's \$output and \$status from prior 'run' untouched" {
  run printf 'captured stdout\n'
  local saved_output="$output"
  local saved_status="$status"
  _grep_output_for "captured stdout"
  [ "$output" = "$saved_output" ]
  [ "$status" = "$saved_status" ]
  ! _grep_output_for "absent"
  [ "$output" = "$saved_output" ]
  [ "$status" = "$saved_status" ]
}

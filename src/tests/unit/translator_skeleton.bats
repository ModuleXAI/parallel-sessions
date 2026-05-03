#!/usr/bin/env bats
# Tests for src/adapters/codex/lib/translator.sh — PR C.1 skeleton.
# Verifies every function defined by the C.1 contract exists, is a
# callable shell function, and returns rc=1 silently as the skeleton
# stub. C.3 will replace these stubs and tighten the assertions.

load "../helpers/common"

setup() {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/adapters/codex/lib/translator.sh"
}

# Helper: assert <fn> is a shell function (not a builtin / command).
_is_function() {
  declare -F -- "$1" >/dev/null
}

@test "translator skeleton: every contract function is defined" {
  for fn in \
      coord_cx_translate_event \
      coord_cx_extract_session_id \
      coord_cx_extract_cwd \
      coord_cx_extract_source \
      coord_cx_extract_prompt \
      coord_cx_extract_tool_name \
      coord_cx_extract_tool_input \
      coord_cx_extract_tool_use_id \
      coord_cx_extract_turn_id \
      coord_cx_extract_permission_mode \
      coord_cx_extract_subagent \
      coord_cx_emit_deny \
      coord_cx_emit_additional_context \
      coord_cx_emit_permission_request_decision; do
    _is_function "$fn" \
      || { echo "missing function: $fn"; return 1; }
  done
}

@test "translator skeleton: stubs return rc=1 with no stdout" {
  for fn in \
      coord_cx_translate_event \
      coord_cx_extract_session_id \
      coord_cx_extract_cwd \
      coord_cx_extract_source \
      coord_cx_extract_prompt \
      coord_cx_extract_tool_name \
      coord_cx_extract_tool_input \
      coord_cx_extract_tool_use_id \
      coord_cx_extract_turn_id \
      coord_cx_extract_permission_mode \
      coord_cx_emit_deny \
      coord_cx_emit_additional_context \
      coord_cx_emit_permission_request_decision; do
    run "$fn"
    [ "$status" -eq 1 ] \
      || { echo "$fn returned $status, expected 1"; return 1; }
    [ -z "$output" ] \
      || { echo "$fn produced stdout '$output' but skeleton stub must be silent"; return 1; }
  done
}

@test "translator skeleton: extract_subagent is a permanent rc=1 (D-2: Codex has no subagent)" {
  # Distinct test from generic stub check because this function will
  # NOT be filled in by C.3 — it stays rc=1 forever. C.3+ should leave
  # this test green.
  run coord_cx_extract_subagent '{"any":"input"}'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "translator skeleton: file passes bash -n syntax check" {
  run bash -n "$SRC_ROOT/adapters/codex/lib/translator.sh"
  [ "$status" -eq 0 ]
}

@test "translator skeleton: stub marker is present (so a C.3 audit can find unfilled stubs)" {
  # The _coord_cx_stub helper carries the marker `PR-C.1 skeleton stub`.
  # Real implementations in C.3 won't call _coord_cx_stub; a grep that
  # finds zero matches across the file by then is the C.3 done-when
  # signal. For C.1, we just assert the marker exists.
  grep -q 'PR-C.1 skeleton stub' "$SRC_ROOT/adapters/codex/lib/translator.sh"
}

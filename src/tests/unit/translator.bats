#!/usr/bin/env bats
# Tests for src/adapters/codex/lib/translator.sh — PR C.3 (full
# implementations; superseded the C.1 skeleton tests previously hosted
# at src/tests/unit/translator_skeleton.bats; file was renamed via
# `git mv` so history follows).
#
# Coverage:
#   - event-translation matrix per (hook_event_name, tool_name)
#   - field extractors over canned Codex stdin JSON fixtures
#   - apply_patch path extraction (translator → parser delegation)
#   - response emitters (deny / additional_context / permission_request)
#   - permanent rc=1 contract for extract_subagent (D-2)
#   - C.3 done-when: zero `PR-C.1 skeleton stub` markers remain

load "../helpers/common"

setup() {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/adapters/codex/lib/translator.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/adapters/codex/lib/apply_patch_parser.sh"
}

# Helper: assert <fn> is a shell function (not a builtin / command).
_is_function() { declare -F -- "$1" >/dev/null; }

# === Sanity / contract carry-forward from C.1 ===

@test "translator: every contract function is defined" {
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
      coord_cx_extract_file_paths \
      coord_cx_emit_deny \
      coord_cx_emit_additional_context \
      coord_cx_emit_permission_request_decision; do
    _is_function "$fn" \
      || { echo "missing function: $fn"; return 1; }
  done
}

@test "translator: file passes bash -n syntax check" {
  run bash -n "$SRC_ROOT/adapters/codex/lib/translator.sh"
  [ "$status" -eq 0 ]
}

@test "translator: extract_subagent is permanently rc=1 (D-2: Codex has no subagent)" {
  run coord_cx_extract_subagent '{"any":"input"}'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "translator C.3 done-when: zero PR-C.1 skeleton stub markers remain in translator.sh" {
  # Inverts the C.1 done-when assertion. C.3 fills every stub; the marker
  # `PR-C.1 skeleton stub` should be absent from the file.
  ! grep -q 'PR-C.1 skeleton stub' "$SRC_ROOT/adapters/codex/lib/translator.sh"
}

# === Event translation matrix ===

@test "translate_event: SessionStart → SESSION_START" {
  run coord_cx_translate_event SessionStart ""
  [ "$status" -eq 0 ]
  [ "$output" = "SESSION_START" ]
}
@test "translate_event: Stop → STOP" {
  run coord_cx_translate_event Stop ""
  [ "$status" -eq 0 ]
  [ "$output" = "STOP" ]
}
@test "translate_event: UserPromptSubmit → PROMPT_SUBMIT" {
  run coord_cx_translate_event UserPromptSubmit ""
  [ "$status" -eq 0 ]
  [ "$output" = "PROMPT_SUBMIT" ]
}
@test "translate_event: PermissionRequest → PERMISSION_REQUEST" {
  run coord_cx_translate_event PermissionRequest "apply_patch"
  [ "$status" -eq 0 ]
  [ "$output" = "PERMISSION_REQUEST" ]
}
@test "translate_event: PreToolUse + apply_patch → PRE_FILE_WRITE" {
  run coord_cx_translate_event PreToolUse apply_patch
  [ "$status" -eq 0 ]
  [ "$output" = "PRE_FILE_WRITE" ]
}
@test "translate_event: PreToolUse + Bash → PRE_BASH" {
  run coord_cx_translate_event PreToolUse Bash
  [ "$status" -eq 0 ]
  [ "$output" = "PRE_BASH" ]
}
@test "translate_event: PreToolUse + matcher * → PRE_TOOL_ANY" {
  run coord_cx_translate_event PreToolUse "*"
  [ "$status" -eq 0 ]
  [ "$output" = "PRE_TOOL_ANY" ]
}
@test "translate_event: PreToolUse + unknown tool → PRE_TOOL_ANY (cross-cutting)" {
  run coord_cx_translate_event PreToolUse some_unknown_tool
  [ "$status" -eq 0 ]
  [ "$output" = "PRE_TOOL_ANY" ]
}
@test "translate_event: PostToolUse + apply_patch → POST_FILE_WRITE" {
  run coord_cx_translate_event PostToolUse apply_patch
  [ "$status" -eq 0 ]
  [ "$output" = "POST_FILE_WRITE" ]
}
@test "translate_event: PostToolUse + Bash → POST_BASH" {
  run coord_cx_translate_event PostToolUse Bash
  [ "$status" -eq 0 ]
  [ "$output" = "POST_BASH" ]
}
@test "translate_event: unknown event → rc=1" {
  run coord_cx_translate_event NotAnEvent something
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# === Field extractors ===

@test "extractors: session_id from canned PreToolUse JSON" {
  local INP='{"session_id":"sid-abc","cwd":"/repo","turn_id":"t1","tool_name":"Bash","tool_input":{},"tool_use_id":"tu-1","permission_mode":"interactive"}'
  run coord_cx_extract_session_id "$INP"
  [ "$status" -eq 0 ]
  [ "$output" = "sid-abc" ]
}
@test "extractors: cwd from PreToolUse JSON" {
  local INP='{"session_id":"sid","cwd":"/path/to/repo"}'
  run coord_cx_extract_cwd "$INP"
  [ "$output" = "/path/to/repo" ]
}
@test "extractors: source from SessionStart JSON" {
  local INP='{"session_id":"sid","source":"resume"}'
  run coord_cx_extract_source "$INP"
  [ "$output" = "resume" ]
}
@test "extractors: prompt from UserPromptSubmit JSON" {
  local INP='{"session_id":"sid","prompt":"hello world"}'
  run coord_cx_extract_prompt "$INP"
  [ "$output" = "hello world" ]
}
@test "extractors: tool_name from PreToolUse JSON" {
  local INP='{"session_id":"sid","tool_name":"apply_patch"}'
  run coord_cx_extract_tool_name "$INP"
  [ "$output" = "apply_patch" ]
}
@test "extractors: tool_use_id from PreToolUse JSON" {
  local INP='{"session_id":"sid","tool_use_id":"tu-42"}'
  run coord_cx_extract_tool_use_id "$INP"
  [ "$output" = "tu-42" ]
}
@test "extractors: turn_id from PreToolUse JSON" {
  local INP='{"session_id":"sid","turn_id":"turn-7"}'
  run coord_cx_extract_turn_id "$INP"
  [ "$output" = "turn-7" ]
}
@test "extractors: permission_mode from any JSON" {
  local INP='{"session_id":"sid","permission_mode":"plan"}'
  run coord_cx_extract_permission_mode "$INP"
  [ "$output" = "plan" ]
}
@test "extractors: tool_input emitted as compact JSON" {
  local INP='{"session_id":"sid","tool_input":{"command":["ls","-la"]}}'
  run coord_cx_extract_tool_input "$INP"
  [ "$status" -eq 0 ]
  [ "$output" = '{"command":["ls","-la"]}' ]
}
@test "extractors: missing field → empty stdout, rc 0" {
  local INP='{"session_id":"sid"}'
  run coord_cx_extract_prompt "$INP"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
@test "extractors: empty input → rc 1" {
  run coord_cx_extract_session_id ""
  [ "$status" -eq 1 ]
}
@test "extractors: invalid JSON → rc 1" {
  run coord_cx_extract_session_id 'not-json{'
  [ "$status" -eq 1 ]
}

# === apply_patch path extraction (translator → parser delegation) ===

@test "extract_file_paths: apply_patch with .input field → paths from parser" {
  local PATCH='*** Begin Patch
*** Add File: foo.txt
+content
*** End Patch'
  local INP
  INP=$(jq -nc --arg p "$PATCH" '{
    session_id: "sid",
    tool_name: "apply_patch",
    tool_input: { input: $p }
  }')
  run coord_cx_extract_file_paths "$INP"
  [ "$status" -eq 0 ]
  [ "$output" = "foo.txt" ]
}

@test "extract_file_paths: apply_patch with .command[-1] (legacy local_shell) → paths" {
  local PATCH='*** Begin Patch
*** Update File: bar.txt
@@
-old
+new
*** End Patch'
  local INP
  INP=$(jq -nc --arg p "$PATCH" '{
    session_id: "sid",
    tool_name: "apply_patch",
    tool_input: { command: ["apply_patch", $p] }
  }')
  run coord_cx_extract_file_paths "$INP"
  [ "$status" -eq 0 ]
  [ "$output" = "bar.txt" ]
}

@test "extract_file_paths: non-apply_patch tool → empty stdout, rc 0" {
  local INP='{"session_id":"sid","tool_name":"Bash","tool_input":{"command":"ls"}}'
  run coord_cx_extract_file_paths "$INP"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "extract_file_paths: multi-file patch returns all paths in encounter order" {
  local PATCH='*** Begin Patch
*** Add File: zeta.txt
+a
*** Update File: alpha.txt
@@
-old
+new
*** Delete File: middle.txt
*** End Patch'
  local INP
  INP=$(jq -nc --arg p "$PATCH" '{
    session_id: "sid",
    tool_name: "apply_patch",
    tool_input: { input: $p }
  }')
  run coord_cx_extract_file_paths "$INP"
  [ "$status" -eq 0 ]
  # Encounter order: zeta, alpha, middle. Hook layer (D.4) sorts.
  [ "$(echo "$output" | tr '\n' ',')" = "zeta.txt,alpha.txt,middle.txt," ]
}

# === Response emitters ===

@test "emit_deny: produces hookSpecificOutput.permissionDecision=deny" {
  run coord_cx_emit_deny "file locked by sid-other" "PreToolUse"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason == "file locked by sid-other"'
}

@test "emit_deny: missing reason → rc 1" {
  run coord_cx_emit_deny "" "PreToolUse"
  [ "$status" -eq 1 ]
}

@test "emit_additional_context: produces hookSpecificOutput.additionalContext" {
  run coord_cx_emit_additional_context "Coord active. Session sid-abc." "SessionStart"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"'
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == "Coord active. Session sid-abc."'
}

@test "emit_additional_context: missing text → rc 1" {
  run coord_cx_emit_additional_context "" "SessionStart"
  [ "$status" -eq 1 ]
}

@test "emit_permission_request_decision: allow with no message" {
  run coord_cx_emit_permission_request_decision allow
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PermissionRequest"'
  echo "$output" | jq -e '.hookSpecificOutput.decision.behavior == "allow"'
  echo "$output" | jq -e '(.hookSpecificOutput.decision | has("message")) | not'
}

@test "emit_permission_request_decision: deny with message" {
  run coord_cx_emit_permission_request_decision deny "denied because tests are running"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.decision.behavior == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.decision.message == "denied because tests are running"'
}

@test "emit_permission_request_decision: invalid behavior → rc 1" {
  run coord_cx_emit_permission_request_decision "ask"
  [ "$status" -eq 1 ]
}

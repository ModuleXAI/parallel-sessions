#!/usr/bin/env bash
# translator.sh — Codex CLI adapter contract for the coord core.
#
# Phase C PR C.3 (skeleton landed in C.1). Every function is now filled
# in. The internal _coord_cx_stub helper that carried the C.1 done-when
# marker has been removed; the test at translator.bats verifies its
# absence.
#
# This file is the symmetric counterpart to whatever Claude-Code uses
# inline today. Every adapter exposes the same set of `coord_<agent>_*`
# functions; coord-core stays agent-agnostic by calling them through
# the normalized event vocabulary in src/core/lib/normalized_events.sh.
#
# Naming: every function is prefixed `coord_cx_` (cx = Codex).
# Style: bash 3.2 compatible, jq-friendly. No `set -euo pipefail`
# (sourced; caller governs).
#
# Codex stdin JSON shape per hook event (verified against
# codex-ref-repo/codex/codex-rs/hooks/schema/generated/*.schema.json):
#   common to all:    session_id, cwd, transcript_path, model, permission_mode, hook_event_name
#   all but SessionStart: turn_id
#   SessionStart only:    source ∈ {startup, resume, clear}
#   PreToolUse/PostToolUse: tool_name, tool_input, tool_use_id (Pre/Post)
#   PostToolUse only:     tool_response
#   PermissionRequest:    tool_name, tool_input, run_id_suffix
#   UserPromptSubmit:     prompt
#   Stop:                 stop_hook_active, last_assistant_message
#
# Codex stdout response envelope (Pre/Post/PermissionRequest):
#   { "hookSpecificOutput": { "hookEventName": "<event>", ... } }
# Specific shapes per emitter function; see below.

# Source normalized_events.sh so COORD_EVENT_* constants are in scope.
# Resolve relative to this file's location, not LIB_DIR (which the calling
# hook owns and may have a different home).
_CX_TRANSLATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source normalized_events from the core lib. Dual-fallback mirrors the
# hook LIB_DIR pattern (per A.5 D-A1-02): in source tree, normalized_events
# lives at ../../../core/lib; in installed flat layout at ../../lib.
if [ -f "$_CX_TRANSLATOR_DIR/../../../core/lib/normalized_events.sh" ]; then
  # shellcheck disable=SC1091
  . "$_CX_TRANSLATOR_DIR/../../../core/lib/normalized_events.sh"
elif [ -f "$_CX_TRANSLATOR_DIR/../../lib/normalized_events.sh" ]; then
  # shellcheck disable=SC1091
  . "$_CX_TRANSLATOR_DIR/../../lib/normalized_events.sh"
fi
# Defensive defaults for tests that skip sourcing the constants file.
: "${COORD_EVENT_SESSION_START:=SESSION_START}"
: "${COORD_EVENT_SESSION_END:=SESSION_END}"
: "${COORD_EVENT_STOP:=STOP}"
: "${COORD_EVENT_PROMPT_SUBMIT:=PROMPT_SUBMIT}"
: "${COORD_EVENT_PRE_TOOL_ANY:=PRE_TOOL_ANY}"
: "${COORD_EVENT_PRE_FILE_READ:=PRE_FILE_READ}"
: "${COORD_EVENT_PRE_FILE_WRITE:=PRE_FILE_WRITE}"
: "${COORD_EVENT_POST_FILE_WRITE:=POST_FILE_WRITE}"
: "${COORD_EVENT_PRE_BASH:=PRE_BASH}"
: "${COORD_EVENT_POST_BASH:=POST_BASH}"
: "${COORD_EVENT_PERMISSION_REQUEST:=PERMISSION_REQUEST}"
: "${COORD_EVENT_UNKNOWN:=UNKNOWN}"

# === Event translation ===

# coord_cx_translate_event <hook_event_name> <tool_name>
# Map a Codex hook event + tool pair to a COORD_EVENT_* constant.
# Returns 0 with constant on stdout for known mappings, 1 for unknown.
coord_cx_translate_event() {
  local event="${1:-}" tool="${2:-}"
  case "$event" in
    SessionStart)      printf '%s\n' "$COORD_EVENT_SESSION_START"; return 0 ;;
    Stop)              printf '%s\n' "$COORD_EVENT_STOP"; return 0 ;;
    UserPromptSubmit)  printf '%s\n' "$COORD_EVENT_PROMPT_SUBMIT"; return 0 ;;
    PermissionRequest) printf '%s\n' "$COORD_EVENT_PERMISSION_REQUEST"; return 0 ;;
    PreToolUse)
      case "$tool" in
        apply_patch)   printf '%s\n' "$COORD_EVENT_PRE_FILE_WRITE"; return 0 ;;
        Bash|bash)     printf '%s\n' "$COORD_EVENT_PRE_BASH"; return 0 ;;
        ""|"*")        printf '%s\n' "$COORD_EVENT_PRE_TOOL_ANY"; return 0 ;;
        *)             printf '%s\n' "$COORD_EVENT_PRE_TOOL_ANY"; return 0 ;;
      esac
      ;;
    PostToolUse)
      case "$tool" in
        apply_patch)   printf '%s\n' "$COORD_EVENT_POST_FILE_WRITE"; return 0 ;;
        Bash|bash)     printf '%s\n' "$COORD_EVENT_POST_BASH"; return 0 ;;
        *)             printf '%s\n' "$COORD_EVENT_UNKNOWN"; return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# === Field extractors (Codex stdin JSON) ===

# Each helper validates the input parses as JSON, then runs a jq filter.
# Returns 0 + extracted value on stdout, 1 on JSON parse error / unset
# COORD-side prerequisites. Empty value is reported as empty stdout (rc 0).

_coord_cx_jq_field() {
  local input="${1:-}" filter="$2"
  if [ -z "$input" ]; then return 1; fi
  printf '%s' "$input" | jq -r "$filter" 2>/dev/null || return 1
}

coord_cx_extract_session_id()    { _coord_cx_jq_field "${1:-}" '.session_id // ""'; }
coord_cx_extract_cwd()           { _coord_cx_jq_field "${1:-}" '.cwd // ""'; }
coord_cx_extract_source()        { _coord_cx_jq_field "${1:-}" '.source // ""'; }
coord_cx_extract_prompt()        { _coord_cx_jq_field "${1:-}" '.prompt // ""'; }
coord_cx_extract_tool_name()     { _coord_cx_jq_field "${1:-}" '.tool_name // ""'; }

# tool_input is a structured value, not a string — emit compact JSON.
coord_cx_extract_tool_input() {
  local input="${1:-}"
  if [ -z "$input" ]; then return 1; fi
  printf '%s' "$input" | jq -c '.tool_input // null' 2>/dev/null || return 1
}

coord_cx_extract_tool_use_id()   { _coord_cx_jq_field "${1:-}" '.tool_use_id // ""'; }
coord_cx_extract_turn_id()       { _coord_cx_jq_field "${1:-}" '.turn_id // ""'; }
coord_cx_extract_permission_mode() { _coord_cx_jq_field "${1:-}" '.permission_mode // ""'; }

# Per D-2: Codex has no subagent concept. PERMANENT rc=1; this stub is
# deliberately not implemented and never will be. Hooks that try to filter
# subagent calls should source subagent_filter.sh under the Claude adapter
# instead, or simply not call this function from Codex hooks.
coord_cx_extract_subagent() {
  return 1
}

# === apply_patch path extraction ===

# coord_cx_extract_file_paths <input_json>
# For PreToolUse/PostToolUse with tool_name="apply_patch", parse the patch
# text out of tool_input.command (or tool_input.input) and return the file
# paths via the parser. For other tools, return empty (rc 0).
#
# tool_input.command shape (from Codex apply_patch invocations):
#   ["apply_patch", "<patch text>"]  OR  ["bash","-lc","apply_patch <<EOF\n...\nEOF"]
# Codex's lenient parser handles both via _coord_cx_strip_heredoc; we just
# need the patch text itself.
coord_cx_extract_file_paths() {
  local input="${1:-}"
  if [ -z "$input" ]; then return 1; fi
  local tool patch
  tool=$(coord_cx_extract_tool_name "$input") || return 1
  if [ "$tool" != "apply_patch" ]; then
    # Non-apply_patch tool — no file paths to extract.
    return 0
  fi
  # tool_input.input is the canonical field for apply_patch
  # (Codex Responses API). Fall back to .command[1] for the
  # legacy local_shell shape, then .command[-1] (last array element)
  # in case of bash -lc wrapping.
  patch=$(printf '%s' "$input" | jq -r '
    .tool_input
    | (.input // .command[-1] // "")
  ' 2>/dev/null) || return 1
  if [ -z "$patch" ]; then return 0; fi
  # Source parser if not already loaded (lazy — translator doesn't
  # auto-source; hooks would, but the test surface may call us
  # standalone).
  if ! command -v coord_cx_apply_patch_paths >/dev/null 2>&1; then
    if [ -f "$_CX_TRANSLATOR_DIR/apply_patch_parser.sh" ]; then
      # shellcheck disable=SC1091
      . "$_CX_TRANSLATOR_DIR/apply_patch_parser.sh"
    fi
  fi
  coord_cx_apply_patch_paths "$patch"
}

# === Response emitters (build JSON for Codex stdout) ===

# coord_cx_emit_deny <reason> <hook_event_name>
# Build the PreToolUse / PermissionRequest deny envelope. Stdout: JSON
# document expected by Codex on the hook's stdout.
coord_cx_emit_deny() {
  local reason="${1:-}" event="${2:-PreToolUse}"
  if [ -z "$reason" ]; then return 1; fi
  jq -nc \
    --arg ev "$event" \
    --arg r "$reason" \
    '{
      hookSpecificOutput: {
        hookEventName: $ev,
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
}

# coord_cx_emit_additional_context <text> <hook_event_name>
# Build the SessionStart / UserPromptSubmit / Pre/PostToolUse banner
# envelope. Codex appends the additionalContext text to the model's
# next-turn context window, NOT to user-visible stdout.
coord_cx_emit_additional_context() {
  local text="${1:-}" event="${2:-SessionStart}"
  if [ -z "$text" ]; then return 1; fi
  jq -nc \
    --arg ev "$event" \
    --arg t "$text" \
    '{
      hookSpecificOutput: {
        hookEventName: $ev,
        additionalContext: $t
      }
    }'
}

# coord_cx_emit_permission_request_decision <allow|deny> [<message>]
# Build the PermissionRequest decision envelope. Codex routes this to
# the hook subscribed to PermissionRequest events for non-auto-approved
# tool calls. Behavior MUST be one of "allow" or "deny" per
# PermissionRequestBehaviorWire.
coord_cx_emit_permission_request_decision() {
  local behavior="${1:-}" message="${2:-}"
  case "$behavior" in
    allow|deny) ;;
    *) return 1 ;;
  esac
  if [ -z "$message" ]; then
    jq -nc \
      --arg b "$behavior" \
      '{
        hookSpecificOutput: {
          hookEventName: "PermissionRequest",
          decision: { behavior: $b }
        }
      }'
  else
    jq -nc \
      --arg b "$behavior" \
      --arg m "$message" \
      '{
        hookSpecificOutput: {
          hookEventName: "PermissionRequest",
          decision: { behavior: $b, message: $m }
        }
      }'
  fi
}

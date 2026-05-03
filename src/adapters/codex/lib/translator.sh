#!/usr/bin/env bash
# translator.sh — Codex CLI adapter contract for the coord core.
#
# Phase C PR C.1: SKELETON ONLY. Every function below is stubbed —
# either returns rc=1 silently, or returns a placeholder. C.3 fills in
# the real logic; C.2 supplies the apply_patch_parser.sh that several
# of these functions will call into.
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
# Forward declarations (filled in C.3 unless noted):
#
#   coord_cx_translate_event <hook_event_name> <tool_name>
#       Map a Codex hook event + tool pair to a COORD_EVENT_* constant
#       from normalized_events.sh. Stdout: the constant value
#       (e.g., "PRE_FILE_WRITE"). Returns 0 on known mappings, 1 on
#       unknown. C.3 fills mappings; C.1 returns 1.
#
#   coord_cx_extract_session_id <input_json>
#   coord_cx_extract_cwd <input_json>
#   coord_cx_extract_source <input_json>
#   coord_cx_extract_prompt <input_json>
#   coord_cx_extract_tool_name <input_json>
#   coord_cx_extract_tool_input <input_json>
#   coord_cx_extract_tool_use_id <input_json>
#   coord_cx_extract_turn_id <input_json>
#   coord_cx_extract_permission_mode <input_json>
#       Pull a single field out of Codex's hook stdin JSON. Each
#       returns the field value on stdout (empty string when absent),
#       and exit code 0 when the input parses as JSON, 1 otherwise.
#       C.3 fills jq filters; C.1 returns rc=1 with empty stdout.
#
#   coord_cx_extract_subagent <input_json>
#       Per D-2: Codex has no subagent concept. This function ALWAYS
#       returns rc=1 — no implementation will ever change that. The
#       subagent_filter pattern is Claude-Code-specific and lives at
#       src/adapters/claude-code/lib/subagent_filter.sh; Codex hooks
#       simply skip the call.
#
#   coord_cx_emit_deny <reason> <hook_event_name>
#   coord_cx_emit_additional_context <text> <hook_event_name>
#   coord_cx_emit_permission_request_decision <allow|deny> [<message>]
#       Build the JSON response shape Codex expects on stdout for the
#       given hook event. Per D-9, deny + additional_context use
#       `hookSpecificOutput.permissionDecision` / `additionalContext`
#       (same envelope as Claude); permission_request uses
#       `hookSpecificOutput.decision.behavior` (Codex-specific).
#       C.3 fills jq templates; C.1 returns rc=1.
#
# Future-callers see a coherent contract even though every function
# currently no-ops. The skeleton is what lets PR-D hooks compile-check
# their call sites without waiting for C.3.

# --- Stub helper used by every skeleton function ---
# Returns rc=1 with no stdout. Marker comment so grep can find every
# stub when C.3 fills them in.
_coord_cx_stub() {
  return 1   # PR-C.1 skeleton stub
}

# === Event translation ===

coord_cx_translate_event() {
  _coord_cx_stub
}

# === Field extractors (Codex stdin JSON) ===

coord_cx_extract_session_id() {
  _coord_cx_stub
}

coord_cx_extract_cwd() {
  _coord_cx_stub
}

coord_cx_extract_source() {
  _coord_cx_stub
}

coord_cx_extract_prompt() {
  _coord_cx_stub
}

coord_cx_extract_tool_name() {
  _coord_cx_stub
}

coord_cx_extract_tool_input() {
  _coord_cx_stub
}

coord_cx_extract_tool_use_id() {
  _coord_cx_stub
}

coord_cx_extract_turn_id() {
  _coord_cx_stub
}

coord_cx_extract_permission_mode() {
  _coord_cx_stub
}

# Per D-2: Codex has no subagent concept. This stub will REMAIN a
# permanent rc=1; no later PR replaces it. Documented here so future
# readers don't think the skeleton was forgotten.
coord_cx_extract_subagent() {
  return 1   # PERMANENT — no subagent in Codex (D-2)
}

# === Response emitters (build JSON for Codex stdout) ===

coord_cx_emit_deny() {
  _coord_cx_stub
}

coord_cx_emit_additional_context() {
  _coord_cx_stub
}

coord_cx_emit_permission_request_decision() {
  _coord_cx_stub
}

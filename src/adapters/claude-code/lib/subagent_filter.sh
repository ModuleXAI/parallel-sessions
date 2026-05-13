#!/usr/bin/env bash
# subagent_filter.sh — shared helper for detecting subagent tool-call hooks
# and emitting the SUBAGENT_ACTIVITY_SKIPPED observability event.
#
# Per Phase 0 Experiment #5 (FINDINGS F-006), subagents spawned via the Task
# tool share the parent's `session_id` and do NOT fire their own SessionStart.
# The `agent_type` field appears on `PreToolUse`, `PostToolUse`, and
# `SubagentStop` inputs (empty string or absent in parent-session context).
# Decision 2.17 (rewritten by PR-PHASE0-01) places the subagent filter at
# the tool-call hook layer: when `agent_type` is non-empty, the hook exits
# 0 without mutating state, but MUST emit a single
# SUBAGENT_ACTIVITY_SKIPPED event for observability.
#
# Contract:
#   coord_subagent_filter <hook_event_name> <stdin_json>
#     Returns 0 if `input.agent_type` is a non-empty string (caller should
#     `exit 0` after this function returns — do NOT mutate sessions.json
#     or other coord state). Before returning 0, attempts to emit a single
#       { kind: "SUBAGENT_ACTIVITY_SKIPPED",
#         hook: <event name>,
#         agent_type: <value>,
#         parent_session: <session_id>,
#         tool: <tool_name if present>,
#         file: <tool_input.file_path or notebook_path if present> }
#     event via coord_log_event. Logging is best-effort: it requires
#     $COORD_DIR pointing at a valid coord root AND coord_log_event already
#     sourced; otherwise the log is silently skipped (detection still
#     returns 0 — the safety behavior is decoupled from observability).
#
#     Returns 1 if `agent_type` is empty/absent (i.e., this is NOT a
#     subagent invocation) — the caller continues normal hook processing.
#
# Dependencies: jq. Callers should also source lib/log_event.sh if they
# want the observability event emitted.
#
# Bash 3.2 compat; designed to be SOURCED, not executed directly.
# Does not call `set -euo pipefail` — the caller's shell options govern.
# Does not call `exit` — uses `return` so callers retain control flow.

coord_subagent_filter() {
  local hook_name="${1:-unknown}"
  local input_json="${2:-}"

  if [ -z "$input_json" ]; then
    return 1
  fi

  local agent_type
  agent_type=$(printf '%s' "$input_json" | jq -r '.agent_type // ""' 2>/dev/null || printf '')
  if [ -z "$agent_type" ]; then
    return 1
  fi

  # Subagent detected. Attempt best-effort observability event.
  local session_id tool file_path
  session_id=$(printf '%s' "$input_json" | jq -r '.session_id // ""' 2>/dev/null || printf '')
  tool=$(printf '%s' "$input_json" | jq -r '.tool_name // ""' 2>/dev/null || printf '')
  file_path=$(printf '%s' "$input_json" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null || printf '')

  if command -v coord_log_event >/dev/null 2>&1 \
     && [ -n "${COORD_DIR:-}" ] && [ -d "${COORD_DIR:-}" ]; then
    # Ensure SESSION_ID is visible to coord_log_event.
    if [ -z "${SESSION_ID:-}" ] && [ -n "$session_id" ]; then
      export SESSION_ID="$session_id"
    fi

    # Indexed array (Bash 3.2 safe — associative arrays are the only
    # forbidden form per CLAUDE.md §A.5).
    local log_args
    log_args=(
      kind=SUBAGENT_ACTIVITY_SKIPPED
      "hook=$hook_name"
      "agent_type=$agent_type"
      "parent_session=${session_id:-unknown}"
    )
    if [ -n "$tool" ]; then
      log_args+=("tool=$tool")
    fi
    if [ -n "$file_path" ]; then
      log_args+=("file=$file_path")
    fi
    coord_log_event "${log_args[@]}"
  fi

  return 0
}

# CLI shim for bats / ad-hoc probes: reads JSON on stdin, echoes hook-name
# from $1, returns the function's exit status.
#   printf '%s' "$JSON" | subagent_filter.sh PreToolUse ; echo $?
# Requires sourcing log_event.sh first; minimal sourcing happens here for
# the shim only. Skip-to-log still needs COORD_DIR exported.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  _SHIM_HOOK="${1:-unknown}"
  _SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # log_event.sh lives in core/lib/ at source-tree depth, but in the
  # flat .coord/lib/ when installed. Dual-fallback locates it in
  # either layout (mirrors hook LIB_DIR resolution post-A.2).
  _SHIM_LOG_EVENT="$(cd "$_SHIM_DIR/../../../core/lib" 2>/dev/null && pwd)/log_event.sh"
  [ -f "$_SHIM_LOG_EVENT" ] || _SHIM_LOG_EVENT="$_SHIM_DIR/log_event.sh"
  # shellcheck disable=SC1091
  . "$_SHIM_LOG_EVENT"
  _SHIM_JSON="$(cat)"
  if coord_subagent_filter "$_SHIM_HOOK" "$_SHIM_JSON"; then
    exit 0   # subagent → caller should skip
  else
    exit 1   # non-subagent → caller continues
  fi
fi

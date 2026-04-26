#!/usr/bin/env bash
# post_tool_use_write.sh — Claude Code PostToolUse hook for Write / Edit /
# NotebookEdit tools.
#
# PHASE 2 SCOPE. Per plan §5 Phase 2:
#   "Lock release in post_tool_use_write.sh."
#
# Behavior in Phase 2:
#   1. Non-participant gate (CLAUDE_COORD unset → exit 0).
#   2. Subagent filter (agent_type populated → SUBAGENT_ACTIVITY_SKIPPED,
#      exit 0; PR-PHASE0-01 binding).
#   3. If `locks[<target>]` is held by THIS session → release atomically:
#        delete locks[<target>]
#      Log LOCK_RELEASED. Emit nothing (PostToolUse hooks rarely emit
#      additionalContext; they may but Phase 2 has no producer text).
#      Phase 6 will add the `tasks[]` processing here (see PHASE-6 marker).
#   4. If `locks[<target>]` is held by ANOTHER session → log ERROR + allow.
#      This should not happen in normal flow (the pre-hook would have denied),
#      but defensively we never delete another session's lock.
#   5. If `locks[<target>]` is unheld → silent no-op (e.g., the pre-hook
#      failed atomic acquire and fell open). Allow.
#   6. Exit 0 in every branch.
#
# This hook NEVER sets permissionDecision — Phase 2's invariant test
# asserts permissionDecision: "deny" appears ONLY in pre_tool_use_write.sh.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/subagent_filter.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/notify_waiters.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/lockdown.sh"

coord_resolve_root() {
  if [ -n "${COORD_DIR:-}" ] && [ -d "$COORD_DIR" ]; then
    printf '%s\n' "$COORD_DIR"; return 0
  fi
  local base="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$base" ]; then
    base=$(git rev-parse --show-toplevel 2>/dev/null || printf '')
  fi
  if [ -z "$base" ]; then return 1; fi
  if [ -d "$base/.coord" ]; then printf '%s/.coord\n' "$base"; return 0; fi
  return 1
}

warn_stderr() { printf 'coord post_tool_use_write: %s\n' "$*" >&2; }

# --- main ---
[ "${CLAUDE_COORD:-}" != "1" ] && exit 0

INPUT="$(cat)"

if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "PostToolUse" "$INPUT"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || printf '')
TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null || printf '')

[ -z "$SESSION_ID" ] && exit 0

if ! COORD_DIR=$(coord_resolve_root); then
  exit 0
fi
export COORD_DIR SESSION_ID

if ! coord_is_participant "$SESSION_ID"; then
  exit 0
fi

for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    warn_stderr "dependency $dep missing; skipping lock release"
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0
[ -z "$TARGET" ] && exit 0

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): under active
# lockdown, do NOT release the lock — Mediator's fix flow may
# require the lock state to remain as-is for analysis. Emit deny +
# exit. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "PostToolUse"; then
  exit 0
fi

# Identify the lock holder + acquired_at for $TARGET, if any. Capture
# acquired_at BEFORE deletion so the notification scan window is correct.
LOCK_TSV=$(jq -r --arg f "$TARGET" '
  (.locks[$f] // {}) as $L
  | [($L.session // ""), ($L.acquired_at // "")]
  | @tsv
' "$STATE" 2>/dev/null || printf '')
LOCK_HOLDER=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $1}')
LOCK_ACQUIRED=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $2}')

if [ -z "$LOCK_HOLDER" ]; then
  # No lock to release — pre-hook may have failed atomic acquire; silent allow.
  exit 0
fi

if [ "$LOCK_HOLDER" != "$SESSION_ID" ]; then
  # Defensive: never delete another session's lock. This implies a
  # protocol violation (pre-hook should have denied this write) but we
  # MUST NOT corrupt their state. Log + allow.
  coord_log_event kind=ERROR source=post_tool_use_write tool="$TOOL_NAME" file="$TARGET" \
    reason=lock_held_by_other holder="$LOCK_HOLDER"
  exit 0
fi

# PHASE-6 UPGRADE POINT:
#   Before deleting the lock, process locks[$TARGET].tasks[] in order:
#     for each task: inject additionalContext describing it; capture
#     Claude's Edit; record outcome (status / diff / affected_lines);
#     archive into sessions_history. See plan §3.7.2 + §5 Phase 6.
#   Phase 2's release path is task-less: locks[$TARGET].tasks is always [].

NOW=$(coord_now_iso8601)
if ! coord_atomic_edit "$STATE" \
      'del(.locks[$f])
       | .sessions[$sid].last_activity_at = $now' \
      --arg f "$TARGET" --arg sid "$SESSION_ID" --arg now "$NOW"; then
  warn_stderr "atomic_edit failed during lock release; lock may persist"
  coord_log_event kind=ERROR source=post_tool_use_write tool="$TOOL_NAME" file="$TARGET" \
    reason=lock_release_failed
  exit 0
fi

coord_log_event kind=LOCK_RELEASED source=post_tool_use_write \
  tool="$TOOL_NAME" file="$TARGET" \
  released_at="$NOW" acquired_at="$LOCK_ACQUIRED"

# Notification activation — Phase 1's dormant per-file notification
# consumer (in pre_tool_use_read.sh + pre_tool_use_any.sh) is now wired
# to a real producer. Any session that was denied on $TARGET during the
# hold window will see a "lock_released: ..." entry on its next read or
# any tool call.
coord_notify_lock_release_waiters "$SESSION_ID" "$TARGET" "$LOCK_ACQUIRED" "$NOW"

# Phase 5 will replace this best-effort scan with an explicit wait_queue
# FIFO + diff-summary content; Phase 2's notification has no diff yet.

exit 0

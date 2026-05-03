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
# A.2: hook libs split between core (most) and adapter (subagent_filter).
# Source-tree: HOOK_DIR/../../../core/lib (3 levels up from
# src/adapters/claude-code/hooks/) and HOOK_DIR/../lib for adapter libs.
# Installed:   .coord/hooks/../lib (flat) — both vars resolve there.
CORE_LIB_DIR="$(cd "$HOOK_DIR/../../../core/lib" 2>/dev/null && pwd)" \
  || CORE_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/subagent_filter.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/notify_waiters.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/task_processor.sh" ] && . "$CORE_LIB_DIR/task_processor.sh"
# Phase 7 / T7.05 — mode-aware spawn dispatch + cost-guard
# interlock activation for the task processor. Optional sources
# (graceful degrade if absent).
[ -f "$CORE_LIB_DIR/spawn_helper.sh" ] && . "$CORE_LIB_DIR/spawn_helper.sh"
[ -f "$CORE_LIB_DIR/cost_guards.sh" ] && . "$CORE_LIB_DIR/cost_guards.sh"
# T5.04 / PR-PHASE5-02 §5: notify_waiters' 4-tier diff_summary chain
# uses validator_cache (tier 2), validator_prefilter + read_snapshots
# (tier 3), and hash (tier 2/3 inputs). Source defensively — present
# in Phase 4+ installs.
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/hash.sh" ] && . "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_cache.sh" ] && . "$CORE_LIB_DIR/validator_cache.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_prefilter.sh" ] && . "$CORE_LIB_DIR/validator_prefilter.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/read_snapshots.sh" ] && . "$CORE_LIB_DIR/read_snapshots.sh"

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

# Identify the lock holder + acquired_at + verdict_ts for $TARGET, if
# any. Capture all BEFORE deletion so notify_waiters can pass the
# verdict_ts into its 4-tier diff_summary chain (T5.04 / PR-PHASE5-02
# §5).
LOCK_TSV=$(jq -r --arg f "$TARGET" '
  (.locks[$f] // {}) as $L
  | [
      ($L.session // ""),
      ($L.acquired_at // ""),
      ($L.latest_validator_verdict_ts // ""),
      (($L.tasks // []) | length)
    ]
  | @tsv
' "$STATE" 2>/dev/null || printf '')
LOCK_HOLDER=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $1}')
LOCK_ACQUIRED=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $2}')
LOCK_VERDICT_TS=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $3}')
LOCK_TASK_COUNT=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $4}')
case "$LOCK_TASK_COUNT" in
  ''|*[!0-9]*) LOCK_TASK_COUNT=0 ;;
esac

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

# Phase 6 T6.05 task-processor invocation: process
# locks[$TARGET].tasks[] BEFORE the lock-deletion atomic_edit so we
# can read each task's anchor + opener while the lock entry still
# exists. The processor removes processed tasks from .tasks[] in
# its own atomic edits + appends per-task TASK_OUTCOME notifications
# to .notifications[<opener>][$TARGET]. Errors inside the processor
# are logged via TASK_PROCESSOR_RUN events; never block the post-
# hook critical path. When task_processor.sh isn't sourced (minimal
# install pre-T6.05), the function call below is skipped via the
# command -v guard — preserves Phase 2 behavior intact.
#
# Performance: task_count was captured in LOCK_TSV's 4th column
# above. When tasks[] is empty (the dominant case in normal flow),
# skip the processor invocation entirely — saves 2 jq calls
# (EDIT_START/END parse + processor's internal queue read) on the
# post-hook critical path. Phase 5 timing-sensitive tests (e.g.,
# T5.08 S2.b polling-fallback wake-up <600ms) flake under added
# latency; the empty-queue fast-path eliminates the regression.
if [ "$LOCK_TASK_COUNT" != "0" ] \
   && command -v coord_task_processor_run >/dev/null 2>&1; then
  EDIT_START=$(printf '%s' "$INPUT" | jq -r '
    .tool_response.start_line
    // .tool_input.start_line
    // 0
  ' 2>/dev/null || printf '0')
  EDIT_END=$(printf '%s' "$INPUT" | jq -r '
    .tool_response.end_line
    // .tool_input.end_line
    // 0
  ' 2>/dev/null || printf '0')
  case "$EDIT_START" in ''|*[!0-9]*) EDIT_START=0 ;; esac
  case "$EDIT_END"   in ''|*[!0-9]*) EDIT_END=0   ;; esac
  coord_task_processor_run "$TARGET" "$SESSION_ID" \
    "$EDIT_START" "$EDIT_END" 2>/dev/null || true
fi

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
coord_notify_lock_release_waiters "$SESSION_ID" "$TARGET" "$LOCK_ACQUIRED" "$NOW" "$LOCK_VERDICT_TS"

# Phase 5 will replace this best-effort scan with an explicit wait_queues
# FIFO + diff-summary content; Phase 2's notification has no diff yet.

exit 0

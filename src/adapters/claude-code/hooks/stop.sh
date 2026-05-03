#!/usr/bin/env bash
# stop.sh — Claude Code Stop hook for coord.
#
# PHASE 2 SCOPE. Per plan §5 Phase 2: "Lock release on Stop + SessionEnd
# (graceful)." Stop fires when a Claude turn ends gracefully — typically
# right before SessionEnd in the same shutdown sequence (Phase 0
# Experiment #6: graceful exit fires SessionStart→Stop→SessionEnd).
#
# Behavior:
#   1. Non-participant gate (CLAUDE_COORD unset → exit 0).
#   2. Subagent filter — Stop receives SubagentStop too; subagents do NOT
#      hold locks (the parent's lock covers the parent's turn per
#      Decision 2.17 / PR-PHASE0-01), so SubagentStop must never trigger
#      release. The shared filter handles both: agent_type populated
#      → SUBAGENT_ACTIVITY_SKIPPED + exit 0.
#   3. Iterate every lock held by this session. For each:
#        a. Capture acquired_at BEFORE deletion (needed for the
#           notification scan window).
#        b. Atomically delete locks[<file>].
#        c. Emit LOCK_RELEASED.
#        d. Populate notifications for any sessions denied on this path
#           during the hold window.
#   4. If the session held NO locks → silent no-op. This is the common
#      case for read-only sessions and the basis for Stop+SessionEnd
#      idempotence: whichever runs first releases; the other finds an
#      empty held-lock set.
#   5. Exit 0 in every branch. NEVER sets permissionDecision (Phase 2
#      invariant — only pre_tool_use_write.sh emits deny).
#
# Phase 6 will add a `stop_hook_active` block-once-then-allow path for
# unresolved self_tasks here. Phase 2 has no self_tasks producer.

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
[ -f "$CORE_LIB_DIR/self_tasks.sh" ] && . "$CORE_LIB_DIR/self_tasks.sh"
# T5.04 / PR-PHASE5-02 §5: notify_waiters' 4-tier diff_summary chain.
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/hash.sh" ] && . "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_cache.sh" ] && . "$CORE_LIB_DIR/validator_cache.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_prefilter.sh" ] && . "$CORE_LIB_DIR/validator_prefilter.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/read_snapshots.sh" ] && . "$CORE_LIB_DIR/read_snapshots.sh"

warn_stderr() { printf 'coord stop: %s\n' "$*" >&2; }

# --- main ---
[ "${CLAUDE_COORD:-}" != "1" ] && exit 0

INPUT="$(cat)"

if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
# Filter SubagentStop / Stop-with-agent_type via the shared helper.
# A subagent's Stop must NEVER touch parent locks.
if coord_subagent_filter "Stop" "$INPUT"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
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
    warn_stderr "dependency $dep missing; skipping graceful release"
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): under lockdown,
# do NOT release this session's locks — same rationale as session_end
# (Mediator's fix flow may require locks to persist for analysis).
# A subsequent Stop after clear will proceed normally. Fail-open on
# parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "Stop"; then
  exit 0
fi

# Phase 6 T6.07 self-task block-once-then-allow per PR-PHASE6-02 +
# Decision 2.13. Decision contract:
#   "On `Stop`, unresolved self-tasks trigger `decision: 'block'`
#    once with a reminder; second `Stop` lets the session end and
#    archives the self-task as SKIPPED."
# "Unresolved" semantic per PR-PHASE6-02 = file currently NOT held
# by any peer (file is unlocked OR self-held; B could acquire now).
# coord_self_task_check_unlocked returns the unresolved subset.
#
# Per-task stop_block_count discriminates first-Stop (block) vs
# second-Stop (allow + archive SKIPPED). Tasks within the same Stop
# attempt that haven't been blocked before (count==0) trigger the
# block; tasks whose count >= 1 from a prior Stop are archived
# SKIPPED on this attempt.
#
# CRITICAL: this branch emits `decision: "block"` (Stop hook's
# permission grammar — distinct from `permissionDecision: "deny"`
# which the Phase 3+4+5+6 invariant restricts to two architectural
# locations). Decision 2.13 explicitly authorizes `decision: "block"`
# at stop.sh; the 2-location deny invariant remains unchanged.
ST_TO_BLOCK=""    # newline-separated "<file>\t<instr>\t<pid>" for Stop #1
ST_TO_ARCHIVE="" # newline-separated "<pid>" for Stop #2
ST_BLOCK_COUNT=0
ST_ARCHIVE_COUNT=0
if command -v coord_self_task_check_unlocked >/dev/null 2>&1; then
  ST_UNLOCKED=$(coord_self_task_check_unlocked "$SESSION_ID" 2>/dev/null || printf '[]')
  ST_LEN=$(printf '%s' "$ST_UNLOCKED" | jq -r 'length' 2>/dev/null || printf '0')
  case "$ST_LEN" in ''|*[!0-9]*) ST_LEN=0 ;; esac
  ST_IDX=0
  while [ "$ST_IDX" -lt "$ST_LEN" ]; do
    ST_TASK=$(printf '%s' "$ST_UNLOCKED" | jq -c --argjson i "$ST_IDX" '.[$i]' 2>/dev/null)
    ST_PID=$(printf '%s' "$ST_TASK" | jq -r '.prompt_id' 2>/dev/null)
    ST_FILE=$(printf '%s' "$ST_TASK" | jq -r '.file' 2>/dev/null)
    ST_INSTR=$(printf '%s' "$ST_TASK" | jq -r '.instruction' 2>/dev/null)
    ST_BC=$(printf '%s' "$ST_TASK" | jq -r '.stop_block_count // 0' 2>/dev/null)
    case "$ST_BC" in ''|*[!0-9]*) ST_BC=0 ;; esac
    if [ "$ST_BC" = "0" ]; then
      ST_TO_BLOCK="${ST_TO_BLOCK:+$ST_TO_BLOCK$'\n'}${ST_FILE}"$'\t'"${ST_INSTR}"$'\t'"${ST_PID}"
      ST_BLOCK_COUNT=$((ST_BLOCK_COUNT + 1))
    else
      ST_TO_ARCHIVE="${ST_TO_ARCHIVE:+$ST_TO_ARCHIVE$'\n'}${ST_PID}"
      ST_ARCHIVE_COUNT=$((ST_ARCHIVE_COUNT + 1))
    fi
    ST_IDX=$((ST_IDX + 1))
  done
fi

# Stop #1 path: at least one task with stop_block_count==0 → block
# the Stop with a reminder enumerating the unresolved tasks. Increment
# stop_block_count for each blocking task so the next Stop attempt
# falls into the archive branch.
if [ "$ST_BLOCK_COUNT" -gt 0 ]; then
  # Build the reminder text.
  ST_LIST=""
  ST_OLD_IFS="$IFS"
  IFS='
'
  set -- $ST_TO_BLOCK
  IFS="$ST_OLD_IFS"
  for entry in "$@"; do
    [ -z "$entry" ] && continue
    f=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
    inst=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
    pid=$(printf '%s' "$entry" | awk -F'\t' '{print $3}')
    ST_LIST="${ST_LIST:+$ST_LIST$'\n'}  - ${f} :: ${inst}"
    coord_self_task_increment_stop_block "$SESSION_ID" "$pid" >/dev/null 2>&1 || true
  done
  ST_REASON=$(printf 'Stop blocked: %s unresolved self-task(s) with file(s) now free for action.\n%s\nIssue Stop again to skip these tasks (will archive as SKIPPED), or `coord self-delegate` next iteration after addressing them.' \
    "$ST_BLOCK_COUNT" "$ST_LIST")
  jq -nc --arg reason "$ST_REASON" '{decision: "block", reason: $reason}'
  coord_log_event kind=STOP_HOOK_INVOKED source=stop \
    blocked_count="$ST_BLOCK_COUNT" archived_count=0 \
    decision=block 2>/dev/null || true
  exit 0
fi

# Stop #2 path (or no unresolved tasks at all): if any tasks were
# previously blocked (count >= 1) and remain unresolved at this
# Stop attempt, archive them as SKIPPED. Then proceed to lock
# release as the existing Phase 2 path expects.
if [ "$ST_ARCHIVE_COUNT" -gt 0 ]; then
  ST_OLD_IFS="$IFS"
  IFS='
'
  set -- $ST_TO_ARCHIVE
  IFS="$ST_OLD_IFS"
  for pid in "$@"; do
    [ -z "$pid" ] && continue
    coord_self_task_archive "$SESSION_ID" "$pid" "stop_second_attempt" \
      >/dev/null 2>&1 || true
  done
fi

if [ "$ST_BLOCK_COUNT" -gt 0 ] || [ "$ST_ARCHIVE_COUNT" -gt 0 ]; then
  coord_log_event kind=STOP_HOOK_INVOKED source=stop \
    blocked_count="$ST_BLOCK_COUNT" archived_count="$ST_ARCHIVE_COUNT" \
    decision=allow 2>/dev/null || true
fi

# Collect all locks held by this session, with acquired_at + verdict_ts,
# BEFORE deletion (T5.04: notify_waiters' tier-1 verdict-file lookup
# needs the verdict_ts captured pre-delete). TSV:
# "<path>\t<acquired_at>\t<verdict_ts>".
HELD_TSV=$(jq -r --arg sid "$SESSION_ID" '
  .locks
  | to_entries[]
  | select(.value.session == $sid)
  | [.key, (.value.acquired_at // ""), (.value.latest_validator_verdict_ts // "")]
  | @tsv
' "$STATE" 2>/dev/null || printf '')

if [ -z "$HELD_TSV" ]; then
  # Idempotency: no locks to release. Stop+SessionEnd dual-fire lands
  # here when SessionEnd already cleaned up (or in the read-only case).
  exit 0
fi

NOW=$(coord_now_iso8601)

# Iterate held locks; release each individually so per-file
# LOCK_RELEASED + notification population is observable in events.jsonl.
OLD_IFS="$IFS"
IFS='
'
set -- $HELD_TSV
IFS="$OLD_IFS"
for entry in "$@"; do
  path=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
  acquired_at=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
  verdict_ts=$(printf '%s' "$entry" | awk -F'\t' '{print $3}')
  [ -z "$path" ] && continue

  if ! coord_atomic_edit "$STATE" \
        'del(.locks[$f])
         | .sessions[$sid].last_activity_at = $now' \
        --arg f "$path" --arg sid "$SESSION_ID" --arg now "$NOW"; then
    warn_stderr "atomic_edit failed during stop release of $path"
    coord_log_event kind=ERROR source=stop file="$path" reason=lock_release_failed
    continue
  fi

  coord_log_event kind=LOCK_RELEASED source=stop tool="" file="$path" \
    released_at="$NOW" acquired_at="$acquired_at"

  # Populate notifications for any sessions denied during the hold.
  # T5.04: pass verdict_ts captured before deletion so notify_waiters'
  # 4-tier chain can resolve the diff_summary via the validator
  # verdict file when stage 3 produced one this turn.
  coord_notify_lock_release_waiters "$SESSION_ID" "$path" "$acquired_at" "$NOW" "$verdict_ts"
done

exit 0

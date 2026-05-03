#!/usr/bin/env bash
# stop.sh — Codex Stop hook for coord (PR D.2).
#
# Mirrors src/adapters/claude-code/hooks/stop.sh with Codex adaptations:
#   - stdin extraction via the C.3 translator (coord_cx_extract_session_id).
#   - Does NOT call coord_subagent_filter — D-2: Codex has no subagent
#     concept; subagent_filter.sh is intentionally not sourced.
#   - Participation gate: COORD_ENABLED=1 (canonical, B.2), with CLAUDE_COORD
#     as legacy fallback for symmetry. parallels-codex sets COORD_ENABLED=1.
#
# Per D-10: Codex has no SessionEnd event. Lock release happens via Stop +
# Watchdog only. Stop fires at end-of-turn (mirror of Claude Stop semantics);
# the watchdog handles dead-session cleanup (IDLE_CLOSED, marker removal,
# read_snapshot cleanup) since Codex never delivers a graceful SessionEnd.
# This hook does NOT do those cleanups — it does the same per-turn release
# that Claude's stop.sh does.
#
# Behavior:
#   1. Non-participant gate (COORD_ENABLED unset → exit 0).
#   2. Extract session_id via translator; empty → exit 0.
#   3. Resolve .coord/ root; check marker file (coord_is_participant).
#   4. Lockdown gate: under active lockdown, emit deny + skip release.
#   5. Self-task block-once-then-allow (Decision 2.13). Codex Stop input
#      carries `stop_hook_active` per Codex source events/stop.rs:30; the
#      per-task stop_block_count discriminates first-Stop (block) vs
#      second-Stop (allow + archive SKIPPED). Same logic as Claude.
#   6. Iterate locks held by this session; for each:
#        a. Capture acquired_at + verdict_ts BEFORE deletion.
#        b. Atomically delete locks[<file>] + refresh last_activity_at.
#        c. Emit LOCK_RELEASED.
#        d. Populate notifications via coord_notify_lock_release_waiters.
#   7. No locks held → silent no-op (idempotency basis).
#   8. NEVER sets `permissionDecision` (Phase 2 invariant; only
#      pre_tool_use_*.sh emits deny). The self-task block-once path emits
#      `decision: "block"` per Decision 2.13 — distinct grammar, NOT
#      `permissionDecision`.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_LIB_DIR="$(cd "$HOOK_DIR/../../../core/lib" 2>/dev/null && pwd)" \
  || CORE_LIB_DIR="$(cd "$HOOK_DIR/../../lib" 2>/dev/null && pwd)" \
  || CORE_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
# ADAPTER libs: source layout has them at HOOK_DIR/../lib
# (src/adapters/codex/lib/); installed layout has them at
# HOOK_DIR/../../lib/codex/ (.coord/lib/codex/).
ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../lib" 2>/dev/null && pwd)" \
  || ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../../lib/codex" && pwd)"

# shellcheck disable=SC1091
. "$CORE_LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/notify_waiters.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/self_tasks.sh" ] && . "$CORE_LIB_DIR/self_tasks.sh"
# notify_waiters' 4-tier diff_summary chain (T5.04 / PR-PHASE5-02 §5).
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/hash.sh" ]                && . "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_cache.sh" ]     && . "$CORE_LIB_DIR/validator_cache.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_prefilter.sh" ] && . "$CORE_LIB_DIR/validator_prefilter.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/read_snapshots.sh" ]      && . "$CORE_LIB_DIR/read_snapshots.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"

warn_stderr() { printf 'coord codex stop: %s\n' "$*" >&2; }

# --- main ---
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

# Per D-2: NO subagent filter. Codex has no subagents.

SESSION_ID=$(coord_cx_extract_session_id "$INPUT" 2>/dev/null || printf '')
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

# Lockdown gate: under lockdown, do NOT release this session's locks
# (Mediator's fix flow may require lock state to persist for analysis).
# A subsequent Stop after clear will proceed normally. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "Stop"; then
  exit 0
fi

# Self-task block-once-then-allow per Decision 2.13. "Unresolved" =
# file currently NOT held by any peer (file is unlocked OR self-held).
# Per-task stop_block_count discriminates first-Stop (block) vs second-Stop
# (allow + archive SKIPPED).
ST_TO_BLOCK=""
ST_TO_ARCHIVE=""
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

# Stop #1 path: at least one task with stop_block_count==0 → block the
# Stop with a reminder. Increment stop_block_count for each blocking task.
if [ "$ST_BLOCK_COUNT" -gt 0 ]; then
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

# Stop #2 path: archive previously-blocked tasks (count >= 1) as SKIPPED.
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

# Collect all locks held by this session, capturing acquired_at + verdict_ts
# BEFORE deletion so notify_waiters' tier-1 verdict-file lookup can resolve
# the diff_summary.
HELD_TSV=$(jq -r --arg sid "$SESSION_ID" '
  .locks
  | to_entries[]
  | select(.value.session == $sid)
  | [.key, (.value.acquired_at // ""), (.value.latest_validator_verdict_ts // "")]
  | @tsv
' "$STATE" 2>/dev/null || printf '')

if [ -z "$HELD_TSV" ]; then
  exit 0
fi

NOW=$(coord_now_iso8601)

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

  coord_notify_lock_release_waiters "$SESSION_ID" "$path" "$acquired_at" "$NOW" "$verdict_ts"
done

exit 0

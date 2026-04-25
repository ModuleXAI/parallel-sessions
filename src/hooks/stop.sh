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

# Collect all locks held by this session, with their acquired_at, before
# touching state. TSV: "<path>\t<acquired_at>".
HELD_TSV=$(jq -r --arg sid "$SESSION_ID" '
  .locks
  | to_entries[]
  | select(.value.session == $sid)
  | [.key, (.value.acquired_at // "")]
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
  coord_notify_lock_release_waiters "$SESSION_ID" "$path" "$acquired_at" "$NOW"
done

exit 0

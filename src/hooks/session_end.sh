#!/usr/bin/env bash
# session_end.sh — Claude Code SessionEnd hook for coord.
#
# Behavior (plan §4):
#   1. If CLAUDE_COORD != "1" → exit 0 silently.
#   2. Mark the session state as IDLE_CLOSED.
#   3. Release any locks still held by this session (move to history; wake
#      anyone in that file's wait_queue — Phase 2+ actions are no-ops here).
#   4. Remove the `.coord/sessions/<id>.active` marker.
#   5. Log SESSION_END event with the `reason` field (when present).
#   6. No stdout output required; exit 0.
#
# SIGKILL does NOT invoke this hook (Experiment #6 / plan Decision 2.19) —
# the peer watchdog handles dead-session cleanup; SessionEnd is best-effort
# only.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/subagent_filter.sh"

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

warn_stderr() { printf 'coord session_end: %s\n' "$*" >&2; }

[ "${CLAUDE_COORD:-}" != "1" ] && exit 0

INPUT="$(cat)"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
REASON=$(printf '%s' "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null || printf 'unknown')

# Defensive: SessionEnd should not fire for subagents (per F-006); if it
# does, the shared helper emits SUBAGENT_ACTIVITY_SKIPPED per Decision 2.17
# / PR-PHASE0-01 G, then we exit without mutating state.
# Pre-resolve COORD_DIR so the helper's best-effort logging can reach
# events.jsonl when agent_type is populated.
if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "SessionEnd" "$INPUT"; then
  exit 0
fi
[ -z "$SESSION_ID" ] && exit 0

if ! COORD_DIR=$(coord_resolve_root); then exit 0; fi
export COORD_DIR SESSION_ID

# Participant check: only act if we registered this session.
if [ ! -e "$COORD_DIR/sessions/${SESSION_ID}.active" ]; then
  exit 0
fi

STATE="$COORD_DIR/sessions.json"
NOW=$(coord_now_iso8601)

# Atomic transition: state → IDLE_CLOSED; drop locks held by this session;
# (wait_queue waking is Phase 2+ and is a no-op here.)
coord_atomic_edit "$STATE" '
  .sessions[$sid].state            = "IDLE_CLOSED"
  | .sessions[$sid].last_activity_at = $now
  | .locks
      |= with_entries(
           select(.value.session != $sid)
         )
' --arg sid "$SESSION_ID" --arg now "$NOW" || true

# Remove the marker; ignore failures.
rm -f "$COORD_DIR/sessions/${SESSION_ID}.active" 2>/dev/null || true

coord_log_event kind=SESSION_END reason="$REASON"
exit 0

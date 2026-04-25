#!/usr/bin/env bash
# pre_tool_use_any.sh — Claude Code PreToolUse hook (matcher .*).
#
# Cross-cutting context-injection hook. Runs before tool-specific
# PreToolUse hooks (pre_tool_use_read.sh, pre_tool_use_write.sh) and
# carries the responsibility for signals that aren't tied to a single
# tool: pending notifications anywhere in the session's scope, and
# git-HEAD drift detected mid-session.
#
# PHASE 1 SCOPE — minimal per plan §5:
#   - Deliver any pending notifications across the whole session
#     (notifications[$sid][*] arrays), then clear them. Single atomic_edit.
#   - HEAD-change recheck per CLAUDE.md §B.9.6: if current git HEAD
#     differs from sessions[$sid].git_head, mark every read_set entry
#     with superseded_by_head_change:true and update the stored HEAD,
#     then emit additionalContext + HEAD_CHANGE event.
#
# OUT OF PHASE 1 (deferred):
#   - Self-task reminders (Phase 6 — needs `self_tasks` table).
#   - Mediator-pending notices (Phase 3 — needs `.coord/mediator/pending.json`
#     consumer wired in).
#   See PHASE-3 / PHASE-6 upgrade points at the bottom of this file.
#
# Phase 1 ship gate: NEVER sets permissionDecision. All paths exit 0.

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
. "$LIB_DIR/head_tracking.sh"

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

emit_additional_context() {
  local text="$1"
  jq -nc --arg t "$text" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $t}}'
}

warn_stderr() { printf 'coord pre_tool_use_any: %s\n' "$*" >&2; }

# --- main ---
[ "${CLAUDE_COORD:-}" != "1" ] && exit 0

INPUT="$(cat)"

if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "PreToolUse" "$INPUT"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || printf '')

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

if ! COORD_DIR=$(coord_resolve_root); then
  exit 0
fi
export COORD_DIR SESSION_ID

if ! coord_is_participant "$SESSION_ID"; then
  exit 0
fi

for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0

# --- 1. Notification scan + atomic clear ---------------------------------
# Capture pending notifications first (read-only), then clear them in a
# single atomic_edit. The captured text is what we emit, which matches the
# state AFTER the clear (no double-delivery if pre_tool_use_read runs
# concurrently — its own delivery becomes a no-op once cleared).
NOTIFS_TEXT=$(jq -r --arg sid "$SESSION_ID" '
  (.notifications[$sid] // {})
  | to_entries
  | map(select((.value // []) | length > 0))
  | map(
      "  • " + .key + ":\n"
      + ((.value | map("      - " + .)) | join("\n"))
    )
  | join("\n")
' "$STATE" 2>/dev/null || printf '')

# --- 2. HEAD recheck (Decision 2.22 / §B.9.6) ---------------------------
CURRENT_HEAD=$(coord_current_head "${CWD:-.}")
HEAD_DRIFTED=0
PRIOR_HEAD=""
if [ -n "$CURRENT_HEAD" ] && coord_head_drifted "$SESSION_ID" "$CURRENT_HEAD"; then
  HEAD_DRIFTED=1
  PRIOR_HEAD=$(coord_stored_head "$SESSION_ID")
fi

# --- 3. Atomic edit: clear notifications + (on drift) mark + update head -
if [ -n "$NOTIFS_TEXT" ] || [ "$HEAD_DRIFTED" = "1" ]; then
  if ! coord_atomic_edit "$STATE" '
      (if ((.notifications[$sid] // {}) | length) > 0 then
         .notifications[$sid] = (.notifications[$sid]
           | with_entries(.value |= []))
       else . end)
    | (if $drifted == "1" then
         .read_sets[$sid].reads |= ((. // []) | map(. + {superseded_by_head_change: true}))
         | .sessions[$sid].git_head = $head
       else . end)
    ' \
    --arg sid     "$SESSION_ID" \
    --arg head    "$CURRENT_HEAD" \
    --arg drifted "$HEAD_DRIFTED"
  then
    warn_stderr 'atomic_edit failed during cross-cutting checks; allow continues'
    # Fail-open. Don't exit early — still emit any captured notification text.
  fi
fi

# --- 4. Compose + emit additionalContext ---------------------------------
BANNER=""
# Corruption-recovery banner per §B.9.2 step 4 (consumed once per flag).
CORRUPT_BANNER=$(coord_consume_corrupt_state_flag || printf '')
if [ -n "$CORRUPT_BANNER" ]; then
  BANNER="$CORRUPT_BANNER"
fi
if [ -n "$NOTIFS_TEXT" ]; then
  if [ -n "$BANNER" ]; then BANNER="$BANNER"$'\n\n'; fi
  BANNER="${BANNER}Coord notifications pending:"$'\n'"$NOTIFS_TEXT"
  coord_log_event kind=NOTIFICATION_DELIVER source=pre_tool_use_any
fi
if [ "$HEAD_DRIFTED" = "1" ]; then
  HEAD_NOTE="Coord: git HEAD changed since your last activity (was $PRIOR_HEAD, now $CURRENT_HEAD). Your read-set is invalidated; re-read any files you depend on."
  if [ -n "$BANNER" ]; then
    BANNER="$BANNER"$'\n\n'"$HEAD_NOTE"
  else
    BANNER="$HEAD_NOTE"
  fi
  coord_log_event kind=HEAD_CHANGE source=pre_tool_use_any old_head="$PRIOR_HEAD" new_head="$CURRENT_HEAD"
fi

if [ -n "$BANNER" ]; then
  emit_additional_context "$BANNER"
fi

exit 0

# PHASE-3 UPGRADE POINT:
#   When the Mediator command-hook + agent hook land, this hook adds:
#     - A check for `.coord/mediator/pending.json`. If present, inject
#       a one-line banner ("Coord Mediator pending: <kind>; running on
#       this tool call") so Claude knows why the agent hook is firing.
#     - A check for `.coord/mediator/verdict/<latest>.json` to surface
#       Mediator outcomes that were not delivered to a previous turn
#       (e.g., escalate_to_user verdicts).
#   See IMPLEMENTATION_PLAN.md §4 mediator_agent.md component spec and
#   §5 Phase 3 "Done when" criteria.
#
# PHASE-6 UPGRADE POINT:
#   When self-delegation lands, this hook iterates self_tasks[$sid][] for
#   entries with status:"PENDING" whose target file is now unlocked, and
#   injects the reminder text per CLAUDE.md §B.7. The reminder is
#   accumulated into the SAME additionalContext banner already used here
#   for notifications + HEAD-change.
#   See IMPLEMENTATION_PLAN.md §5 Phase 6 "Done when" + §B.7 runtime rule.

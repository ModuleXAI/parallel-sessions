#!/usr/bin/env bash
# session_end.sh — Claude Code SessionEnd hook for coord.
#
# Behavior (plan §4 + Phase 2 update):
#   1. If CLAUDE_COORD != "1" → exit 0 silently.
#   2. Subagent filter (defensive — SessionEnd should not fire for
#      subagents, but if it does, exit 0 with SUBAGENT_ACTIVITY_SKIPPED).
#   3. Iterate every lock held by this session (in case Stop did not
#      run, e.g., Claude Code launched without the Stop hook
#      registered, or the Stop hook crashed). For each:
#        a. Capture acquired_at BEFORE deletion.
#        b. Atomically delete locks[<file>].
#        c. Emit LOCK_RELEASED.
#        d. Populate notifications for sessions denied during the hold.
#   4. If the session held no locks (the common case after Stop already
#      ran) → no LOCK_RELEASED events, no notification scanning,
#      idempotent silent path.
#   5. Mark sessions[<sid>].state = IDLE_CLOSED, refresh last_activity.
#   6. Remove the `.coord/sessions/<id>.active` marker.
#   7. Log SESSION_END with the `reason` field.
#   8. exit 0; never sets permissionDecision.
#
# SIGKILL does NOT invoke this hook (Experiment #6 / plan Decision 2.19) —
# the peer watchdog (Phase 3) handles dead-session cleanup.

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
. "$CORE_LIB_DIR/notify_waiters.sh"
# T5.04 / PR-PHASE5-02 §5: notify_waiters' 4-tier diff_summary chain.
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/hash.sh" ] && . "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_cache.sh" ] && . "$CORE_LIB_DIR/validator_cache.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_prefilter.sh" ] && . "$CORE_LIB_DIR/validator_prefilter.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/read_snapshots.sh" ] && . "$CORE_LIB_DIR/read_snapshots.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/read_snapshots.sh"

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

# Defensive subagent filter (SessionEnd should not fire for subagents).
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

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): under lockdown,
# do NOT release this session's locks — Mediator's fix flow may
# require lock state to persist for analysis (e.g., a critical-bypass
# lockdown was triggered specifically because a session looked dead).
# Marker is left in place; a subsequent SessionEnd after clear will
# proceed normally. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "SessionEnd"; then
  exit 0
fi

STATE="$COORD_DIR/sessions.json"
NOW=$(coord_now_iso8601)

# --- Multi-lock release with notification population ----------------------
# Capture held locks BEFORE the IDLE_CLOSED transition. This is the
# defensive fallback for the case where Stop did not run.
HELD_TSV=$(jq -r --arg sid "$SESSION_ID" '
  .locks
  | to_entries[]
  | select(.value.session == $sid)
  | [.key, (.value.acquired_at // ""), (.value.latest_validator_verdict_ts // "")]
  | @tsv
' "$STATE" 2>/dev/null || printf '')

if [ -n "$HELD_TSV" ]; then
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
      warn_stderr "atomic_edit failed during session_end release of $path"
      coord_log_event kind=ERROR source=session_end file="$path" reason=lock_release_failed
      continue
    fi
    coord_log_event kind=LOCK_RELEASED source=session_end tool="" file="$path" \
      released_at="$NOW" acquired_at="$acquired_at"
    coord_notify_lock_release_waiters "$SESSION_ID" "$path" "$acquired_at" "$NOW" "$verdict_ts"
  done
fi

# --- IDLE_CLOSED transition + activity refresh ----------------------------
# This is the only state transition session_end has always done. The
# `.locks |= …` filter from Phase 1 was a sweeping del-where-session-
# matches; with Phase 2's per-lock release loop above, this filter would
# now be a redundant no-op (the locks are already deleted) but we keep
# it defensively in case a lock was added between our HELD_TSV snapshot
# and now (extremely unlikely under normal flow but cheap to guard).
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

# Phase 4 / PR-PHASE4-05 — clean up read snapshots for this session.
# Idempotent: if directory absent, no-op. The watchdog/Mediator
# evict_session path also calls this helper (verdict_apply.sh
# extension per PR-PHASE4-05 §F) for sessions that crashed before
# session_end.sh fired.
coord_read_snapshot_cleanup_session "$SESSION_ID" || true

coord_log_event kind=SESSION_END reason="$REASON"
exit 0

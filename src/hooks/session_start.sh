#!/usr/bin/env bash
# session_start.sh — Claude Code SessionStart hook for coord.
#
# Behavior (plan §4 + Decision 2.5 source-matrix per PR-PHASE1-01):
#   1. If CLAUDE_COORD != "1" → exit 0 silently (non-participant).
#   2. Subagent defensive filter via lib/subagent_filter.sh — exit 0 silently
#      with SUBAGENT_ACTIVITY_SKIPPED event if agent_type is populated.
#   3. Branch on input.source ∈ {startup|resume|clear|compact}:
#      - startup: insert new row (or idempotent refresh if prior row exists
#                 — logged as anomaly). Event: SESSION_REGISTER.
#      - resume:  idempotent refresh (preserve registered_at, prompt_id,
#                 read_sets). If git_head drifted since the prior row, mark
#                 read_sets[$sid].reads entries with superseded_by_head_change
#                 inside the same atomic_edit (single-pass atomicity).
#                 If the row is missing, fall back to startup and emit
#                 SESSION_REGISTER with reason:"resume_without_prior_row".
#                 Emit RESUME_ORPHAN_LOCK_DETECTED per lock whose prior
#                 pid/lstart don't match the new process. Event on refresh:
#                 SESSION_RESUME (plus HEAD_CHANGE if drifted).
#      - clear:   refresh row + mark read_sets[$sid].reads entries with
#                 superseded_by:"new_prompt". Event: SESSION_CLEAR.
#      - compact: update last_activity_at only. Read-set preserved.
#                 Event: SESSION_COMPACTED.
#   4. Create the `.coord/sessions/<id>.active` marker file.
#   5. Emit "Coord v1.0 active" banner via additionalContext.
#   6. Fail open: any unexpected error → warn to stderr and exit 0.
#
# Invocation: stdin = SessionStart event JSON; stdout = hookSpecificOutput.

set -euo pipefail

# --- resolve dependencies (support both dev layout src/ and install layout .coord/) ---
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/subagent_filter.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/head_tracking.sh"

# --- locate coord root (written by installer) ---
coord_resolve_root() {
  if [ -n "${COORD_DIR:-}" ] && [ -d "$COORD_DIR" ]; then
    printf '%s\n' "$COORD_DIR"
    return 0
  fi
  local base="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$base" ]; then
    base=$(git rev-parse --show-toplevel 2>/dev/null || printf '')
  fi
  if [ -z "$base" ]; then return 1; fi
  if [ -d "$base/.coord" ]; then
    printf '%s/.coord\n' "$base"
    return 0
  fi
  return 1
}

emit_additional_context() {
  local text="$1"
  jq -nc --arg t "$text" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
}

warn_stderr() {
  printf 'coord session_start: %s\n' "$*" >&2
}

# --- main ---
if [ "${CLAUDE_COORD:-}" != "1" ]; then
  exit 0
fi

INPUT="$(cat)"

# Subagent defensive filter (SessionStart does not actually fire for
# subagents per F-006; this is a safety net against runtime changes).
if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "SessionStart" "$INPUT"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || printf 'startup')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || printf '')

if [ -z "$SESSION_ID" ]; then
  warn_stderr 'missing session_id in stdin; skipping registration'
  exit 0
fi

if ! COORD_DIR=$(coord_resolve_root); then
  warn_stderr 'no .coord/ directory found; run coord install; skipping'
  exit 0
fi
export COORD_DIR SESSION_ID

for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    warn_stderr "dependency $dep missing; coordination disabled this session"
    emit_additional_context "Coord: dependency $dep missing. Install it and re-register with 'coord install --repair'. Operating uncoordinated this session."
    exit 0
  fi
done

# Collect post-state values (new pid / pid_lstart / git_head / now).
PID="$PPID"
PID_LSTART=$(ps -p "$PID" -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' || printf '')
GIT_HEAD=$(coord_current_head "${CWD:-.}")
NOW=$(coord_now_iso8601)
SCRIPT_VERSION="1.0"
STATE="$COORD_DIR/sessions.json"

# --- Pre-atomic read phase: capture prior row state so post-mutation logging
# has accurate before-values (HEAD_CHANGE old_head; RESUME_ORPHAN_LOCK_DETECTED
# file list). These reads are lock-free per plan §4 lib/state_query — writes
# are atomic via temp+rename so a torn-read cannot happen.
PRIOR_ROW_EXISTS=0
PRIOR_HEAD=""
ORPHAN_LOCKS_JSON="[]"
if [ -f "$STATE" ]; then
  PRIOR_ROW_EXISTS=$(jq --arg sid "$SESSION_ID" \
    'if (.sessions[$sid] // null) == null then 0 else 1 end' \
    "$STATE" 2>/dev/null || printf 0)
  if [ "$PRIOR_ROW_EXISTS" = "1" ]; then
    PRIOR_HEAD=$(coord_stored_head "$SESSION_ID")
  fi
  if [ "$SOURCE" = "resume" ] && [ "$PRIOR_ROW_EXISTS" = "1" ]; then
    ORPHAN_LOCKS_JSON=$(jq -c --arg sid "$SESSION_ID" --arg pid "$PID" --arg lstart "$PID_LSTART" \
      '[.locks // {} | to_entries[] | select(.value.session == $sid and (.value.pid != ($pid|tonumber) or .value.pid_lstart != $lstart))]' \
      "$STATE" 2>/dev/null || printf '[]')
  fi
fi

# --- Source-matrix dispatch (Decision 2.5 per PR-PHASE1-01).
EVENT_KIND=""
RESUME_REASON=""
FILTER=""
case "$SOURCE" in
  startup)
    if [ "$PRIOR_ROW_EXISTS" = "1" ]; then
      # Anomaly: startup-with-existing-row. Fail-open: treat as idempotent
      # refresh rather than reject (plan §5 Phase 1 "never worse than no coord").
      warn_stderr "startup for already-registered session_id $SESSION_ID (anomaly; idempotent refresh)"
    fi
    FILTER='.sessions[$sid] = {
      state:            "ACTIVE",
      pid:              ($pid|tonumber),
      pid_lstart:       $lstart,
      registered_at:    (.sessions[$sid].registered_at // $now),
      last_activity_at: $now,
      git_head:         $head,
      prompt_id:        null,
      script_version:   $sv
    }'
    EVENT_KIND="SESSION_REGISTER"
    ;;
  resume)
    if [ "$PRIOR_ROW_EXISTS" != "1" ]; then
      # Resume without prior row: fall back to startup semantics per matrix.
      FILTER='.sessions[$sid] = {
        state:            "ACTIVE",
        pid:              ($pid|tonumber),
        pid_lstart:       $lstart,
        registered_at:    $now,
        last_activity_at: $now,
        git_head:         $head,
        prompt_id:        null,
        script_version:   $sv
      }'
      EVENT_KIND="SESSION_REGISTER"
      RESUME_REASON="resume_without_prior_row"
    else
      # Idempotent refresh: preserve registered_at / prompt_id / script_version
      # and the entire read_set. HEAD-drift mark is composed INTO this filter
      # for single-pass atomicity.
      FILTER='
        .sessions[$sid].state            = "ACTIVE"
      | .sessions[$sid].pid              = ($pid|tonumber)
      | .sessions[$sid].pid_lstart       = $lstart
      | .sessions[$sid].last_activity_at = $now
      | (
          if (.sessions[$sid].git_head // "") != "" and (.sessions[$sid].git_head // "") != $head then
            .read_sets[$sid].reads |= ((. // []) | map(. + {superseded_by_head_change: true}))
          else . end
        )
      | .sessions[$sid].git_head         = $head
      '
      EVENT_KIND="SESSION_RESUME"
    fi
    ;;
  clear)
    FILTER='
      .sessions[$sid].state            = "ACTIVE"
    | .sessions[$sid].last_activity_at = $now
    | .sessions[$sid].git_head         = $head
    | .sessions[$sid].prompt_id        = null
    | .read_sets[$sid].reads |= ((. // []) | map(. + {superseded_by: "new_prompt"}))
    '
    EVENT_KIND="SESSION_CLEAR"
    ;;
  compact)
    # Compact preserves read-set and git_head per matrix; only refresh
    # last_activity_at.
    FILTER='.sessions[$sid].last_activity_at = $now'
    EVENT_KIND="SESSION_COMPACTED"
    ;;
  *)
    warn_stderr "unknown SessionStart source '$SOURCE'; treating as startup"
    FILTER='.sessions[$sid] = {
      state:            "ACTIVE",
      pid:              ($pid|tonumber),
      pid_lstart:       $lstart,
      registered_at:    (.sessions[$sid].registered_at // $now),
      last_activity_at: $now,
      git_head:         $head,
      prompt_id:        null,
      script_version:   $sv
    }'
    EVENT_KIND="SESSION_REGISTER"
    SOURCE="startup"
    ;;
esac

if ! coord_atomic_edit "$STATE" "$FILTER" \
  --arg sid    "$SESSION_ID" \
  --arg pid    "$PID" \
  --arg lstart "$PID_LSTART" \
  --arg now    "$NOW" \
  --arg head   "$GIT_HEAD" \
  --arg sv     "$SCRIPT_VERSION"
then
  warn_stderr 'atomic_edit failed during registration; session state unchanged'
  emit_additional_context "Coord: could not update session registry. Operating uncoordinated this turn."
  exit 0
fi

# Touch .active marker.
mkdir -p "$COORD_DIR/sessions"
: >"$COORD_DIR/sessions/${SESSION_ID}.active"

# --- Banner ---
ACTIVE_COUNT=$(jq -r '[.sessions[] | select(.state == "ACTIVE")] | length' "$STATE" 2>/dev/null || printf '?')
OTHER_COUNT=$((ACTIVE_COUNT - 1))
if [ "$OTHER_COUNT" -lt 0 ]; then OTHER_COUNT=0; fi
BANNER="Coord v1.0 active. Your coordination session ID is $SESSION_ID. "
BANNER="$BANNER""There are currently $OTHER_COUNT other coordinated session(s) in this repository. "
BANNER="$BANNER""See 'coord status' for live state."
# Compose any pending corruption-recovery banner per §B.9.2 step 4.
CORRUPT_BANNER=$(coord_consume_corrupt_state_flag || printf '')
if [ -n "$CORRUPT_BANNER" ]; then
  BANNER="$CORRUPT_BANNER"$'\n\n'"$BANNER"
fi
# Phase 2 T2.04: surface any pending Mediator JSONL entries (e.g.
# flock_timeout from a prior turn). Parallel to pre_tool_use_any.sh.
PENDING_BANNER=$(coord_mediator_consume_pending || printf '')
if [ -n "$PENDING_BANNER" ]; then
  BANNER="$BANNER"$'\n\n'"$PENDING_BANNER"
  coord_log_event kind=MEDIATOR_PENDING_DELIVERED source=session_start
fi
emit_additional_context "$BANNER"

# --- Event log per source ---
if [ -n "$RESUME_REASON" ]; then
  coord_log_event kind="$EVENT_KIND" source="$SOURCE" reason="$RESUME_REASON" pid="$PID" git_head="$GIT_HEAD"
else
  coord_log_event kind="$EVENT_KIND" source="$SOURCE" pid="$PID" git_head="$GIT_HEAD"
fi

# HEAD drift on resume → additional HEAD_CHANGE event (companion to the
# superseded_by_head_change mark that was applied inside the atomic_edit).
if [ "$SOURCE" = "resume" ] \
   && [ "$PRIOR_ROW_EXISTS" = "1" ] \
   && [ -n "$PRIOR_HEAD" ] \
   && [ "$PRIOR_HEAD" != "$GIT_HEAD" ]; then
  coord_log_event kind=HEAD_CHANGE source=resume old_head="$PRIOR_HEAD" new_head="$GIT_HEAD"
fi

# Orphan-lock flags on resume (Phase 1 flags only; Phase 3 watchdog evicts).
if [ "$SOURCE" = "resume" ] && [ "$ORPHAN_LOCKS_JSON" != "[]" ] && [ -n "$ORPHAN_LOCKS_JSON" ]; then
  ORPHAN_COUNT=$(printf '%s' "$ORPHAN_LOCKS_JSON" | jq 'length' 2>/dev/null || printf 0)
  I=0
  while [ "$I" -lt "$ORPHAN_COUNT" ]; do
    ORPHAN_FILE=$(printf '%s' "$ORPHAN_LOCKS_JSON" | jq -r --argjson i "$I" '.[$i].key' 2>/dev/null || printf '')
    ORPHAN_OLD_PID=$(printf '%s' "$ORPHAN_LOCKS_JSON" | jq -r --argjson i "$I" '(.[$i].value.pid // 0) | tostring' 2>/dev/null || printf '')
    ORPHAN_OLD_LSTART=$(printf '%s' "$ORPHAN_LOCKS_JSON" | jq -r --argjson i "$I" '.[$i].value.pid_lstart // ""' 2>/dev/null || printf '')
    coord_log_event kind=RESUME_ORPHAN_LOCK_DETECTED \
      file="$ORPHAN_FILE" \
      old_pid="$ORPHAN_OLD_PID" \
      old_pid_lstart="$ORPHAN_OLD_LSTART" \
      new_pid="$PID" \
      new_pid_lstart="$PID_LSTART"
    I=$((I + 1))
  done
fi

exit 0

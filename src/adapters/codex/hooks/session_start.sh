#!/usr/bin/env bash
# session_start.sh — Codex SessionStart hook for coord (PR D.1).
#
# Mirrors src/adapters/claude-code/hooks/session_start.sh. Differences:
#   - Reads stdin via the Codex translator (coord_cx_extract_*) instead of
#     inline jq — keeps every adapter's stdin-shape dependency in one file.
#   - Source enum is {startup, resume, clear} per Codex spec
#     (codex-rs/hooks/schema/generated/session-start.command.input.schema.json).
#     There is no `compact` source (D-11). Unknown source → warn, treat as
#     startup (fail-open + forward-tolerance).
#   - Writes agent="codex" on registered rows (schema 1.1 / PR B.1).
#   - Does NOT call subagent_filter — D-2: Codex has no subagent concept; the
#     translator's coord_cx_extract_subagent is permanently rc=1 and the
#     filter library is intentionally not sourced from Codex hooks.
#   - Participation gate: COORD_ENABLED=1 (PR B.2 canonical), with
#     CLAUDE_COORD as legacy fallback for symmetry with the Claude mirror
#     (the parallels-codex launcher always sets COORD_ENABLED=1).
#
# Behavior matrix (matches Claude per Decision 2.5 / PR-PHASE1-01):
#   startup: insert new row (or idempotent refresh on prior row anomaly).
#            Event: SESSION_REGISTER.
#   resume:  idempotent refresh; preserve registered_at + read_set; mark
#            read_set entries with superseded_by_head_change if HEAD drifted.
#            Missing prior row → fall back to startup with reason=
#            resume_without_prior_row. Orphan locks → RESUME_ORPHAN_LOCK_DETECTED
#            per file (lock NOT released; watchdog evicts in Phase 3).
#            Event: SESSION_RESUME.
#   clear:   refresh row + mark read_set entries with superseded_by="new_prompt";
#            reset prompt_id. Event: SESSION_CLEAR.
#   unknown: warn, treat as startup.
#
# Failure mode: any unexpected error → warn to stderr and exit 0
# (fail-open / never-worse-than-no-coord per plan §5).
#
# Invocation: stdin = SessionStart event JSON; stdout = hookSpecificOutput.

set -euo pipefail

# --- resolve dependencies (support both source layout src/adapters/codex/hooks/
# and installed flat layout .coord/hooks/codex/ — same dual-fallback pattern as
# the Claude adapter; see translator.sh for the same dance) ---
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
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/head_tracking.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"

emit_additional_context() {
  local text="$1"
  coord_cx_emit_additional_context "$text" "SessionStart"
}

warn_stderr() {
  printf 'coord codex session_start: %s\n' "$*" >&2
}

# --- main ---
if [ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ]; then
  exit 0
fi

INPUT="$(cat)"

# Per D-2: NO subagent filter for Codex.

SESSION_ID=$(coord_cx_extract_session_id "$INPUT" 2>/dev/null || printf '')
SOURCE=$(coord_cx_extract_source "$INPUT" 2>/dev/null || printf '')
[ -z "$SOURCE" ] && SOURCE="startup"
CWD=$(coord_cx_extract_cwd "$INPUT" 2>/dev/null || printf '')

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

# Lockdown gate (Phase 3 / T3.03). Same envelope shape works for Codex —
# permissionDecision JSON is the cross-agent deny shape (translator.sh's
# coord_cx_emit_deny emits an identical structure).
if coord_lockdown_check && coord_lockdown_emit_deny "SessionStart"; then
  exit 0
fi

# Collect post-state values (new pid / pid_lstart / git_head / now).
PID="$PPID"
PID_LSTART=$(ps -p "$PID" -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' || printf '')
GIT_HEAD=$(coord_current_head "${CWD:-.}")
NOW=$(coord_now_iso8601)
SCRIPT_VERSION="1.0"
STATE="$COORD_DIR/sessions.json"

# --- Pre-atomic read phase: capture prior row state so post-mutation logging
# has accurate before-values (HEAD_CHANGE old_head; RESUME_ORPHAN_LOCK_DETECTED
# file list). Reads are lock-free per plan §4 lib/state_query — writes are
# atomic via temp+rename so a torn-read cannot happen.
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

# --- Source-matrix dispatch (Codex: startup|resume|clear; D-11: no compact). ---
EVENT_KIND=""
RESUME_REASON=""
FILTER=""
case "$SOURCE" in
  startup)
    if [ "$PRIOR_ROW_EXISTS" = "1" ]; then
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
      script_version:   $sv,
      agent:            $agent
    }'
    EVENT_KIND="SESSION_REGISTER"
    ;;
  resume)
    if [ "$PRIOR_ROW_EXISTS" != "1" ]; then
      FILTER='.sessions[$sid] = {
        state:            "ACTIVE",
        pid:              ($pid|tonumber),
        pid_lstart:       $lstart,
        registered_at:    $now,
        last_activity_at: $now,
        git_head:         $head,
        prompt_id:        null,
        script_version:   $sv,
        agent:            $agent
      }'
      EVENT_KIND="SESSION_REGISTER"
      RESUME_REASON="resume_without_prior_row"
    else
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
  *)
    # Codex spec lists only startup|resume|clear. Forward-tolerance: any
    # future / unknown value falls into this branch. Per D-11 there is
    # explicitly no `compact` source for Codex.
    warn_stderr "unknown SessionStart source '$SOURCE'; treating as startup"
    FILTER='.sessions[$sid] = {
      state:            "ACTIVE",
      pid:              ($pid|tonumber),
      pid_lstart:       $lstart,
      registered_at:    (.sessions[$sid].registered_at // $now),
      last_activity_at: $now,
      git_head:         $head,
      prompt_id:        null,
      script_version:   $sv,
      agent:            $agent
    }'
    EVENT_KIND="SESSION_REGISTER"
    SOURCE="startup"
    ;;
esac

# Schema 1.1 (PR B.1): every session row written by this hook is tagged
# agent="codex" so cross-agent state can be distinguished.
if ! coord_atomic_edit "$STATE" "$FILTER" \
  --arg sid    "$SESSION_ID" \
  --arg pid    "$PID" \
  --arg lstart "$PID_LSTART" \
  --arg now    "$NOW" \
  --arg head   "$GIT_HEAD" \
  --arg sv     "$SCRIPT_VERSION" \
  --arg agent  "codex"
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
CORRUPT_BANNER=$(coord_consume_corrupt_state_flag || printf '')
if [ -n "$CORRUPT_BANNER" ]; then
  BANNER="$CORRUPT_BANNER"$'\n\n'"$BANNER"
fi
PENDING_BANNER=$(coord_mediator_consume_pending || printf '')
if [ -n "$PENDING_BANNER" ]; then
  BANNER="$BANNER"$'\n\n'"$PENDING_BANNER"
  coord_log_event kind=MEDIATOR_PENDING_DELIVERED source=session_start
fi

if [ -f "$COORD_DIR/config.json" ]; then
  WAIT_BACKEND_CFG=$(jq -r '.wait_backend // "auto"' "$COORD_DIR/config.json" 2>/dev/null || printf 'auto')
  if [ "$WAIT_BACKEND_CFG" = "polling" ]; then
    BANNER="$BANNER"$'\n\n'"[Coord] Wake-up using 250 ms polling fallback. Install fswatch (macOS: brew install fswatch) or inotify-tools (Linux: apt install inotify-tools) for sub-100 ms wake-up latency."
  fi
fi

emit_additional_context "$BANNER"

# --- Event log per source ---
if [ -n "$RESUME_REASON" ]; then
  coord_log_event kind="$EVENT_KIND" source="$SOURCE" reason="$RESUME_REASON" pid="$PID" git_head="$GIT_HEAD"
else
  coord_log_event kind="$EVENT_KIND" source="$SOURCE" pid="$PID" git_head="$GIT_HEAD"
fi

# HEAD drift on resume → additional HEAD_CHANGE event (companion to the
# superseded_by_head_change mark applied inside the atomic_edit).
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

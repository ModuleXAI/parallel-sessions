#!/usr/bin/env bash
# session_start.sh — Claude Code SessionStart hook for coord.
#
# Behavior (plan §4 + runtime rules §B.0):
#   1. If CLAUDE_COORD != "1" → exit 0 silently (non-participant).
#   2. If input.agent_type is a non-empty string → exit 0 silently (subagent;
#      per F-006, SessionStart doesn't actually fire for subagents on this
#      runtime, but we keep the filter defensively for future Claude-Code
#      changes).
#   3. Register or refresh the session in sessions.json: pid, pid_lstart,
#      git_head, registered_at, last_activity_at, source, script_version.
#   4. Create the `.coord/sessions/<id>.active` marker file.
#   5. Emit a "Coord v1.0 active" banner via hookSpecificOutput.additionalContext.
#   6. Log SESSION_REGISTER event (non-blocking).
#   7. Fail open: any unexpected error → warn to stderr and exit 0.
#
# Invocation: Claude Code runs this script with the SessionStart event JSON
# on stdin. stdout is the hookSpecificOutput JSON; exit 0 = allow.

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

# --- locate coord root (written by installer) ---
# Env wins; otherwise resolve from $CLAUDE_PROJECT_DIR or git rev-parse.
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
  # Never shell-concat JSON — use jq -n (§A.5).
  jq -nc --arg t "$text" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
}

warn_stderr() {
  printf 'coord session_start: %s\n' "$*" >&2
}

# --- main ---
# Non-participant gate: no CLAUDE_COORD set → be silent.
if [ "${CLAUDE_COORD:-}" != "1" ]; then
  exit 0
fi

# Read stdin once and keep it for jq.
INPUT="$(cat)"

# Subagent defensive filter per F-006 / Decision 2.17 / PR-PHASE0-01 G.
# SessionStart is not actually fired for subagents on Claude Code v2.1.119
# (Phase 0 Experiment #5), so this branch is never expected to run in
# practice — it is a safety net against runtime changes. If it does fire, the
# shared helper emits SUBAGENT_ACTIVITY_SKIPPED for observability.
# Resolve COORD_DIR first so the helper's logging can reach events.jsonl.
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

# Resolve coord dir.
if ! COORD_DIR=$(coord_resolve_root); then
  warn_stderr 'no .coord/ directory found; run coord install; skipping'
  exit 0
fi
export COORD_DIR SESSION_ID

# Dependency check: jq + flock must exist. hash/shasum too for downstream hooks,
# but SessionStart doesn't need them.
for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    warn_stderr "dependency $dep missing; coordination disabled this session"
    emit_additional_context "Coord: dependency $dep missing. Install it and re-register with 'coord install --repair'. Operating uncoordinated this session."
    exit 0
  fi
done

# Collect pid / pid_lstart / git_head.
PID="$PPID"  # Parent of this hook process == claude process (F-005).
PID_LSTART=$(ps -p "$PID" -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' || printf '')
GIT_HEAD=""
if git -C "${CWD:-.}" rev-parse --verify HEAD >/dev/null 2>&1; then
  GIT_HEAD=$(git -C "${CWD:-.}" rev-parse HEAD 2>/dev/null || printf '')
fi
NOW=$(coord_now_iso8601)
SCRIPT_VERSION="1.0"

# Atomically register (or refresh) the session row.
STATE="$COORD_DIR/sessions.json"
if ! coord_atomic_edit "$STATE" '
  .sessions[$sid] = {
    state:            "ACTIVE",
    pid:              ($pid|tonumber),
    pid_lstart:       $lstart,
    registered_at:    (.sessions[$sid].registered_at // $now),
    last_activity_at: $now,
    git_head:         $head,
    prompt_id:        null,
    script_version:   $sv
  }' \
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

# Touch .active marker (participant gate for other hooks).
mkdir -p "$COORD_DIR/sessions"
: >"$COORD_DIR/sessions/${SESSION_ID}.active"

# Count active sessions for banner.
ACTIVE_COUNT=$(jq -r '[.sessions[] | select(.state == "ACTIVE")] | length' "$STATE" 2>/dev/null || printf '?')
OTHER_COUNT=$((ACTIVE_COUNT - 1))
if [ "$OTHER_COUNT" -lt 0 ]; then OTHER_COUNT=0; fi

BANNER="Coord v1.0 active. Your coordination session ID is $SESSION_ID. "
BANNER="$BANNER""There are currently $OTHER_COUNT other coordinated session(s) in this repository. "
BANNER="$BANNER""See 'coord status' for live state."

# Emit banner AND log event (non-blocking).
emit_additional_context "$BANNER"
coord_log_event kind=SESSION_REGISTER source="$SOURCE" pid="$PID" git_head="$GIT_HEAD"

exit 0

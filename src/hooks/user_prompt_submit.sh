#!/usr/bin/env bash
# user_prompt_submit.sh — Claude Code UserPromptSubmit hook for coord.
#
# Behavior (plan §4 + runtime rules §B.9.6):
#   1. If CLAUDE_COORD != "1" → exit 0 silently.
#   2. Subagent defensive filter via lib/subagent_filter.sh — exit 0 silently.
#   3. If the session is not a registered participant (.active marker
#      missing) → exit 0 silently (no-op per plan §4 failure modes).
#   4. Hash the prompt → prompt_id; refresh last_activity_at + git_head.
#   5. Mark every entry in read_sets[$sid].reads with superseded_by:"new_prompt".
#      If git_head drifted since the last prompt, ALSO set
#      superseded_by_head_change: true on those entries. All performed in a
#      single atomic_edit so the compare-and-mark is atomic.
#   6. Cache prompt digest to `.coord/sessions/<id>.env` (shell-safe KV).
#   7. Log PROMPT_SUBMIT event; if HEAD drifted, ALSO log HEAD_CHANGE and
#      emit additionalContext per §B.9.6.
#   8. Fail open on any unexpected error.
#
# Stdin: UserPromptSubmit event JSON (session_id, prompt).
# Stdout: hookSpecificOutput JSON (empty most of the time; HEAD-change
#         message when applicable).

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
. "$LIB_DIR/head_tracking.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/hash.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/lockdown.sh"

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
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $t}}'
}

warn_stderr() { printf 'coord user_prompt_submit: %s\n' "$*" >&2; }

# Pre-participant gate.
[ "${CLAUDE_COORD:-}" != "1" ] && exit 0

INPUT="$(cat)"

# Resolve COORD_DIR so the subagent filter's best-effort logging can reach
# events.jsonl if this fires for a subagent.
if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "UserPromptSubmit" "$INPUT"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
PROMPT_TEXT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || printf '')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || printf '')

if [ -z "$SESSION_ID" ]; then
  exit 0   # fail-open; no warning output to avoid leaking noise to Claude
fi

if ! COORD_DIR=$(coord_resolve_root); then
  exit 0
fi
export COORD_DIR SESSION_ID

# Participant check: only act if we registered this session (marker present).
if ! coord_is_participant "$SESSION_ID"; then
  exit 0
fi

for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    warn_stderr "dependency $dep missing; skipping prompt capture"
    exit 0
  fi
done

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): emit stop signal
# and skip prompt capture under lockdown. The session's prompt_id +
# read-set invalidation will happen on the next UserPromptSubmit
# after lockdown clears. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "UserPromptSubmit"; then
  exit 0
fi

STATE="$COORD_DIR/sessions.json"
NOW=$(coord_now_iso8601)
CURRENT_HEAD=$(coord_current_head "${CWD:-.}")

# Hash the prompt text (safe under Bash 3.2 — portable shasum wrapper).
# We hash an in-memory string, not a file, so hash.sh's file-oriented API
# doesn't fit directly; compute inline with the same shasum command.
PROMPT_ID=""
if [ -n "$PROMPT_TEXT" ]; then
  if command -v shasum >/dev/null 2>&1; then
    PROMPT_ID=$(printf '%s' "$PROMPT_TEXT" | shasum -a 256 2>/dev/null | awk '{print $1}' || printf '')
  elif command -v sha256sum >/dev/null 2>&1; then
    PROMPT_ID=$(printf '%s' "$PROMPT_TEXT" | sha256sum 2>/dev/null | awk '{print $1}' || printf '')
  fi
fi

# Check HEAD drift BEFORE we overwrite the stored git_head.
HEAD_DRIFTED=0
PRIOR_HEAD=""
if [ -n "$CURRENT_HEAD" ] && coord_head_drifted "$SESSION_ID" "$CURRENT_HEAD"; then
  HEAD_DRIFTED=1
  PRIOR_HEAD=$(coord_stored_head "$SESSION_ID")
fi

# Atomic edit: set prompt_id, refresh last_activity_at + git_head, mark
# every read_set entry with superseded_by:"new_prompt" and (conditionally)
# superseded_by_head_change:true. Single-pass atomicity.
if ! coord_atomic_edit "$STATE" '
    .sessions[$sid].prompt_id        = $pid
  | .sessions[$sid].last_activity_at = $now
  | .sessions[$sid].git_head         = $head
  | .read_sets[$sid].reads |= ((. // []) | map(
      . + {superseded_by: "new_prompt"}
      + (if $drifted == "1" then {superseded_by_head_change: true} else {} end)
    ))
  ' \
  --arg sid     "$SESSION_ID" \
  --arg pid     "$PROMPT_ID" \
  --arg now     "$NOW" \
  --arg head    "$CURRENT_HEAD" \
  --arg drifted "$HEAD_DRIFTED"
then
  warn_stderr 'atomic_edit failed during prompt capture; state may be stale'
  # Continue to fail-open (no output).
  exit 0
fi

# Cache prompt digest to .coord/sessions/<id>.env — shell-safe KV (single
# variable only). Atomic via temp+rename.
ENV_FILE="$COORD_DIR/sessions/${SESSION_ID}.env"
ENV_TMP="${ENV_FILE}.tmp.$$"
printf 'COORD_PROMPT_ID=%s\n' "$PROMPT_ID" >"$ENV_TMP" 2>/dev/null || true
mv -f "$ENV_TMP" "$ENV_FILE" 2>/dev/null || rm -f "$ENV_TMP" 2>/dev/null || true

# Log PROMPT_SUBMIT + (on drift) HEAD_CHANGE.
coord_log_event kind=PROMPT_SUBMIT prompt_id="$PROMPT_ID" git_head="$CURRENT_HEAD"

if [ "$HEAD_DRIFTED" = "1" ]; then
  coord_log_event kind=HEAD_CHANGE source=user_prompt_submit \
    old_head="$PRIOR_HEAD" new_head="$CURRENT_HEAD"
  emit_additional_context "Coord: git HEAD changed since your last activity. Your read-set is invalidated; re-read any files you depend on."
fi

exit 0

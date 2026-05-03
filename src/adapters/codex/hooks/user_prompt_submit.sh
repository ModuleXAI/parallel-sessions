#!/usr/bin/env bash
# user_prompt_submit.sh — Codex UserPromptSubmit hook for coord (PR D.3).
#
# Mirrors src/adapters/claude-code/hooks/user_prompt_submit.sh with Codex
# adaptations:
#   - stdin extraction via the C.3 translator (coord_cx_extract_session_id /
#     coord_cx_extract_prompt / coord_cx_extract_cwd).
#   - Banner emitted via translator's coord_cx_emit_additional_context (same
#     hookSpecificOutput.additionalContext envelope as Claude).
#   - Does NOT call coord_subagent_filter — D-2: Codex has no subagent
#     concept; subagent_filter.sh is intentionally not sourced.
#   - Participation gate: COORD_ENABLED=1 (canonical, B.2), with CLAUDE_COORD
#     as legacy fallback. parallels-codex sets COORD_ENABLED=1.
#
# Codex UserPromptSubmit shape (per Codex schema): same `.prompt` field as
# Claude, plus session_id / cwd / hook_event_name / model / permission_mode /
# transcript_path / turn_id. The hook only reads session_id, prompt, cwd.
#
# Behavior (matches Claude per plan §4 + runtime rules §B.9.6):
#   1. Non-participant gate (COORD_ENABLED unset → exit 0).
#   2. Resolve .coord/ + check marker file (coord_is_participant).
#   3. Lockdown gate: under active lockdown, emit deny + skip capture.
#   4. Hash the prompt → prompt_id; refresh last_activity_at + git_head.
#   5. Mark every read_sets[$sid].reads entry with superseded_by:"new_prompt"
#      and (on HEAD drift) superseded_by_head_change:true. Single atomic_edit.
#   6. Cache prompt digest to .coord/sessions/<id>.env.
#   7. Log PROMPT_SUBMIT; on drift, log HEAD_CHANGE + emit additionalContext.
#   8. Fail-open on any error.

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
. "$CORE_LIB_DIR/head_tracking.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"

emit_additional_context() {
  local text="$1"
  coord_cx_emit_additional_context "$text" "UserPromptSubmit"
}

warn_stderr() { printf 'coord codex user_prompt_submit: %s\n' "$*" >&2; }

# Pre-participant gate.
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

# Per D-2: NO subagent filter for Codex.

SESSION_ID=$(coord_cx_extract_session_id "$INPUT" 2>/dev/null || printf '')
PROMPT_TEXT=$(coord_cx_extract_prompt "$INPUT" 2>/dev/null || printf '')
CWD=$(coord_cx_extract_cwd "$INPUT" 2>/dev/null || printf '')

if [ -z "$SESSION_ID" ]; then
  exit 0   # fail-open silently
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

# Lockdown gate (Phase 3 / T3.03): emit stop signal + skip prompt capture.
# The session's prompt_id + read-set invalidation will happen on the next
# UserPromptSubmit after lockdown clears. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "UserPromptSubmit"; then
  exit 0
fi

STATE="$COORD_DIR/sessions.json"
NOW=$(coord_now_iso8601)
CURRENT_HEAD=$(coord_current_head "${CWD:-.}")

# Hash the prompt text. shasum (BSD) preferred for parity with macOS dev
# environment; sha256sum (GNU) is the fallback.
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

# Atomic edit: prompt_id + last_activity + git_head + read-set invalidation
# in a single pass.
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
  exit 0
fi

# Cache prompt digest to .coord/sessions/<id>.env (atomic via temp+rename).
ENV_FILE="$COORD_DIR/sessions/${SESSION_ID}.env"
ENV_TMP="${ENV_FILE}.tmp.$$"
printf 'COORD_PROMPT_ID=%s\n' "$PROMPT_ID" >"$ENV_TMP" 2>/dev/null || true
mv -f "$ENV_TMP" "$ENV_FILE" 2>/dev/null || rm -f "$ENV_TMP" 2>/dev/null || true

coord_log_event kind=PROMPT_SUBMIT prompt_id="$PROMPT_ID" git_head="$CURRENT_HEAD"

if [ "$HEAD_DRIFTED" = "1" ]; then
  coord_log_event kind=HEAD_CHANGE source=user_prompt_submit \
    old_head="$PRIOR_HEAD" new_head="$CURRENT_HEAD"
  emit_additional_context "Coord: git HEAD changed since your last activity. Your read-set is invalidated; re-read any files you depend on."
fi

exit 0

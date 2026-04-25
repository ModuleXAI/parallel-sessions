#!/usr/bin/env bash
# pre_tool_use_write.sh — Claude Code PreToolUse hook for Write / Edit /
# NotebookEdit tools.
#
# PHASE 1 SCOPE — WARNING-ONLY. Per plan §5 Phase 1:
#   "pre_tool_use_write.sh: validate read_set; if any file changed, emit
#    additionalContext warning (no deny yet)."
# and the ship gate:
#   "Phase 1 is never worse than no coordination: the hook cannot block
#    a tool call in any code path."
#
# Accordingly, this hook's ONLY behaviors in Phase 1 are:
#   1. Non-participant gate.
#   2. Subagent filter.
#   3. Walk read_sets[$sid].reads[] for entries with is_latest:true and
#      superseded_by_head_change:!true; recompute sha256 for each; compare
#      to stored hash.
#   4. If any mismatch (or a read-set entry's file is missing / SKIPPED_LARGE),
#      emit `additionalContext` listing the stale files. No permissionDecision
#      is ever set.
#   5. Log events: WRITE (intent) + STALE_READ_WARNED (when warnings fire).
#   6. Exit 0 (allow) on every path.
#
# Phase-2 and Phase-4 upgrade sites are marked with "# PHASE-2" and
# "# PHASE-4" comments so the delta is obvious when those phases land:
#   - Phase 2 replaces the warning-only behavior with lock acquisition and
#     permissionDecision:"deny" when locked-by-other / stale-read-detected.
#   - Phase 4 adds a .coord/validation/<session>.json flag file so the
#     validator agent hook can reclassify MINOR / SAFE / CRITICAL.

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
. "$LIB_DIR/hash.sh"

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

warn_stderr() { printf 'coord pre_tool_use_write: %s\n' "$*" >&2; }

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
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || printf '')
# Write/Edit use file_path; NotebookEdit uses notebook_path.
TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null || printf '')

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
    warn_stderr "dependency $dep missing; allowing write uncoordinated"
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0   # nothing to validate

# --- Read is_latest entries with unsuperseded head-state -------------------
# Emit TSV lines: "<path>\t<stored_hash>" — we keep it out-of-band of JSON
# so we can iterate in pure bash without relying on Bash 4 arrays.
ENTRIES_TSV=$(jq -r --arg sid "$SESSION_ID" '
  (.read_sets[$sid].reads // [])
  | map(select((.is_latest // false) == true and ((.superseded_by_head_change // false) == false)))
  | .[]
  | [.path, .hash] | @tsv
' "$STATE" 2>/dev/null || printf '')

# Log the intent-to-write regardless of outcome.
coord_log_event kind=WRITE tool="$TOOL_NAME" file="$TARGET" source=pre_tool_use_write

if [ -z "$ENTRIES_TSV" ]; then
  exit 0   # no read-set to validate → nothing to warn about
fi

# --- Walk entries, compute current hash, accumulate stale list ------------
STALE_LINES=""
STALE_COUNT=0
# Use IFS + while-read loop; portable on Bash 3.2. No process substitution
# into the outer shell, which means we read from a here-string for safety.
OLD_IFS="$IFS"
IFS='
'
set -- $ENTRIES_TSV
IFS="$OLD_IFS"
for entry in "$@"; do
  # entry is "<path>\t<stored_hash>"
  path=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
  stored=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
  [ -z "$path" ] && continue

  current=""
  reason=""
  if [ ! -e "$path" ]; then
    reason="file deleted since read"
  elif [ "$stored" = "SKIPPED_LARGE" ]; then
    # Conservative per plan §4: large-file reads are treated as always
    # potentially stale.
    reason="large-file read — treated as stale (SKIPPED_LARGE)"
  else
    current=$(coord_hash_file "$path" 2>/dev/null || printf '')
    if [ -z "$current" ]; then
      reason="hash failed (unreadable?)"
    elif [ "$current" != "$stored" ]; then
      reason="modified since read"
    fi
  fi

  if [ -n "$reason" ]; then
    STALE_LINES="$STALE_LINES- $path ($reason)"$'\n'
    STALE_COUNT=$((STALE_COUNT + 1))
  fi
done

if [ "$STALE_COUNT" -gt 0 ]; then
  BANNER="Coord stale-read warning: $STALE_COUNT file(s) you previously read have changed:"$'\n'"${STALE_LINES%$'\n'}"$'\n'"This write ($TOOL_NAME on $TARGET) is being allowed, but your earlier plan may be based on outdated content. Consider re-reading before proceeding. Phase 1 is warning-only; Phase 2 will deny such writes."
  emit_additional_context "$BANNER"
  coord_log_event kind=STALE_READ_WARNED tool="$TOOL_NAME" file="$TARGET" stale_count="$STALE_COUNT"
fi

# PHASE-2: When Phase 2 lands, replace the warning-only block above with:
#   - acquire lock (coord_atomic_edit on .locks[$target]) when read-set OK
#   - emit permissionDecision:"deny" when locked-by-other or stale-read-detected
# PHASE-4: When Phase 4 lands, add:
#   - write .coord/validation/<sid>.json on stale-read-detected so the
#     validator agent can classify SAFE/MINOR/CRITICAL.

exit 0

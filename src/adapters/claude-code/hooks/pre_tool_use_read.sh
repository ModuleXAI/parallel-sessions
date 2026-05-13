#!/usr/bin/env bash
# pre_tool_use_read.sh — Claude Code PreToolUse hook for the Read tool.
#
# Behavior (plan §4 + runtime rule §B.1):
#   1. If CLAUDE_COORD != "1" → exit 0 silently (non-participant).
#   2. Subagent defensive filter via lib/subagent_filter.sh — exit 0
#      silently with SUBAGENT_ACTIVITY_SKIPPED event when agent_type set.
#   3. If the session is not a registered participant (.active marker
#      missing) → exit 0 silently (plan §4 non-participant failure mode).
#   4. Compute sha256 of tool_input.file_path via lib/hash.sh.
#      - File missing → log ERROR, exit 0 (Read itself will surface the
#        missing-file error; we never deny the Read).
#      - File > cap → hash is "SKIPPED_LARGE"; recorded as-is.
#   5. Under atomic_edit:
#      a. Supersede any prior entry in read_sets[$sid].reads with the same
#         path and is_latest == true (set is_latest:false, superseded_by:
#         <new_hash>).
#      b. Append new entry {path, hash, at: now, is_latest: true}.
#   6. Consume any pending notifications for this session + file:
#      notifications[$sid][$path] is an array of strings. If non-empty,
#      emit them as additionalContext, then clear the array inside the
#      same atomic edit (single round-trip).
#   7. Log READ event (non-blocking).
#   8. Exit 0 (allow). Phase 1 NEVER denies a Read — the hook is
#      observational only per ship-gate "never worse than no coord."
#
# Stdin: PreToolUse event JSON for tool_name=Read.
# Stdout: empty (allow) or hookSpecificOutput with additionalContext.

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
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/read_snapshots.sh"

emit_additional_context() {
  local text="$1"
  jq -nc --arg t "$text" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $t}}'
}

warn_stderr() { printf 'coord pre_tool_use_read: %s\n' "$*" >&2; }

# --- main ---
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "PreToolUse" "$INPUT"; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || printf '')

if [ -z "$SESSION_ID" ] || [ -z "$FILE_PATH" ]; then
  exit 0
fi

if ! COORD_DIR=$(coord_resolve_root); then
  exit 0
fi
export COORD_DIR SESSION_ID

if ! coord_is_participant "$SESSION_ID"; then
  exit 0
fi

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): if Mediator has
# activated lockdown, every hook emits a stop signal and skips its
# main work. Fail-open on parse error (coord_lockdown_check returns 1
# on parse fail with a stderr warning + ERROR event).
if coord_lockdown_check && coord_lockdown_emit_deny "PreToolUse"; then
  exit 0
fi

# Compute the hash (or log ERROR on missing file and allow).
HASH=""
if [ -e "$FILE_PATH" ]; then
  if HASH=$(coord_hash_file "$FILE_PATH" 2>/dev/null); then
    :
  else
    HASH=""
    warn_stderr "hash failed for $FILE_PATH; recording no entry"
  fi
fi
if [ -z "$HASH" ]; then
  coord_log_event kind=ERROR source=pre_tool_use_read file="$FILE_PATH" \
    reason=file_missing_or_unhashable
  exit 0
fi

NOW=$(coord_now_iso8601)
STATE="$COORD_DIR/sessions.json"

# --- Atomic supersede + append + notifications-consume ----------------
# All three actions in one jq filter so the hook makes exactly one atomic
# write regardless of how many read-set entries it updates.
#
# Filter semantics:
#   1. For every existing entry in read_sets[sid].reads[] where path == $path
#      and is_latest is true, set is_latest:false, superseded_by:$hash.
#   2. Append the new entry {path, hash, at, is_latest: true}.
#   3. Save notifications[sid][path] (if any) to a temporary .delivered slot
#      on the new entry and clear the array so future reads won't re-emit.
#
# The saved-to-temp-slot is a Phase-1 trick: we want to emit the
# notifications as additionalContext, but we've already committed the
# atomic write. So we read notifications[sid][path] BEFORE the atomic
# write (immediately below), then clear them INSIDE the atomic write.

PENDING_NOTIFS=""
PRIOR_HASH=""
if [ -f "$STATE" ]; then
  PENDING_NOTIFS=$(jq -r --arg sid "$SESSION_ID" --arg path "$FILE_PATH" '
    (.notifications[$sid][$path] // []) | if length == 0 then "" else (map("- " + .) | join("\n")) end
  ' "$STATE" 2>/dev/null || printf '')
  # Capture prior is_latest hash for this path so we can supersede the
  # snapshot file after atomic_edit flips is_latest:false (PR-PHASE4-05).
  PRIOR_HASH=$(jq -r --arg sid "$SESSION_ID" --arg path "$FILE_PATH" '
    (.read_sets[$sid].reads // [])
    | map(select(.path == $path and ((.is_latest // true) == true)))
    | if length == 0 then "" else .[0].hash end
  ' "$STATE" 2>/dev/null || printf '')
fi

if ! coord_atomic_edit "$STATE" '
    .read_sets[$sid].reads |= (
      ((. // []) | map(
        if .path == $path and ((.is_latest // true) == true) then
          . + {is_latest: false, superseded_by: $hash}
        else . end
      ))
      + [{path: $path, hash: $hash, at: $now, is_latest: true}]
    )
  | (if (.notifications[$sid][$path] // []) | length > 0 then
       .notifications[$sid][$path] = []
     else . end)
  ' \
  --arg sid  "$SESSION_ID" \
  --arg path "$FILE_PATH" \
  --arg hash "$HASH" \
  --arg now  "$NOW"
then
  warn_stderr "atomic_edit failed recording read of $FILE_PATH"
  # Fail-open: still allow the Read. Log and exit.
  coord_log_event kind=ERROR source=pre_tool_use_read file="$FILE_PATH" \
    reason=atomic_edit_failed
  exit 0
fi

# Phase 4 / PR-PHASE4-05 — read-snapshot capture. Write content to
# .coord/read_snapshots/<sid>/<hash>.txt for validator pipeline
# consumption. Idempotent (re-Read of unchanged file → no-op).
# SKIPPED_LARGE skips silently (logged separately by helper). Prior
# snapshot superseded if a different hash existed for this file.
if [ -n "$PRIOR_HASH" ] && [ "$PRIOR_HASH" != "$HASH" ]; then
  coord_read_snapshot_supersede "$SESSION_ID" "$PRIOR_HASH" || true
fi
coord_read_snapshot_write "$SESSION_ID" "$HASH" "$FILE_PATH" || true

# Log READ event (non-blocking).
coord_log_event kind=READ tool=Read file="$FILE_PATH" hash="$HASH"

# Deliver any pending notifications we captured BEFORE the clear.
if [ -n "$PENDING_NOTIFS" ]; then
  BANNER="Coord notifications for $FILE_PATH:"$'\n'"$PENDING_NOTIFS"
  emit_additional_context "$BANNER"
  coord_log_event kind=NOTIFICATION_DELIVER file="$FILE_PATH"
fi

exit 0

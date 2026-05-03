#!/usr/bin/env bash
# post_tool_use_apply_patch.sh — Codex PostToolUse hook for apply_patch.
#
# Phase D PR D.5 (plan v1.3). Per-file lock release + task processor
# trigger + waiter notification.
#
# CONTRACT (per F-D4-02(b) simplification — codex-rs/core/src/tools/registry.rs:414-421):
#   PostToolUse hooks fire ONLY when the tool succeeds. If apply_patch
#   errors mid-execution, this hook does NOT run; lock release on the
#   error path is solely Stop's responsibility (D.2 contract). This
#   simplifies the hook — no tool_response.error inspection needed.
#   D-10's "Lock release via Stop + Watchdog only" is the literal cleanup
#   contract; PostToolUse handles the success path.
#
# RELEASE-LOOP IS FAILURE-TOLERANT (preview §5.4): if release fails for
# one file mid-iteration, the loop continues for the remaining files. A
# partial release leaves fewer locks held; the watchdog can recover. An
# aborted loop on first failure would leave MORE locks held than necessary.
# Contrast with D.4's acquisition: there the all-or-nothing atomic_edit is
# semantically required; here per-file best-effort is correct.
#
# F-D5-01: edit_range = 0/0 is the documented coarsening — every queued
# self-task on a released file gets a notification, even those anchored
# to unrelated regions. The Codex grammar's @@ headers don't carry line
# numbers (parser.rs `coord_cx_apply_patch_edit_range` returns 0\t0 by
# design). Future refinement could parse hunk locations from the file
# snapshot at release time; out of scope for D.5.
#
# Q5 FALLBACK: if PostToolUse parser fails on tool_input (rare; would
# imply Codex mutated the input between Pre and Post — its protocol
# guarantees they match), release ALL session locks. Safe and avoids a
# wedge state where a parse error leaves locks held indefinitely.
#
# D-2: NO subagent filter — Codex has no subagent concept.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_LIB_DIR="$(cd "$HOOK_DIR/../../../core/lib" 2>/dev/null && pwd)" \
  || CORE_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"

# shellcheck disable=SC1091
. "$CORE_LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/notify_waiters.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/task_processor.sh" ] && . "$CORE_LIB_DIR/task_processor.sh"
# notify_waiters' 4-tier diff_summary chain.
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/hash.sh" ]                && . "$CORE_LIB_DIR/hash.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_cache.sh" ]     && . "$CORE_LIB_DIR/validator_cache.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/validator_prefilter.sh" ] && . "$CORE_LIB_DIR/validator_prefilter.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/read_snapshots.sh" ]      && . "$CORE_LIB_DIR/read_snapshots.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/apply_patch_parser.sh"

warn_stderr() { printf 'coord codex post_tool_use_apply_patch: %s\n' "$*" >&2; }

# --- main ---
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

# Per D-2: NO subagent filter for Codex.

SESSION_ID=$(coord_cx_extract_session_id "$INPUT" 2>/dev/null || printf '')
[ -z "$SESSION_ID" ] && exit 0

if ! COORD_DIR=$(coord_resolve_root); then
  exit 0
fi
export COORD_DIR SESSION_ID

if ! coord_is_participant "$SESSION_ID"; then
  exit 0
fi

for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    warn_stderr "dependency $dep missing; skipping lock release"
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0

# Lockdown gate: under active lockdown do NOT release the locks (Mediator
# may need lock state preserved for analysis). Same envelope shape Claude
# uses — Codex's PostToolUseOutput has block_reason; the lockdown helper
# emits permissionDecision JSON which is at worst ignored by Codex's
# PostToolUse parser (no model-visible deny on PostToolUse, but the
# bookkeeping skip is what matters here).
if coord_lockdown_check && coord_lockdown_emit_deny "PostToolUse"; then
  exit 0
fi

TOOL_NAME=$(coord_cx_extract_tool_name "$INPUT" 2>/dev/null || printf '')
if [ "$TOOL_NAME" != "apply_patch" ]; then
  # Defensive: this hook should only fire for ^apply_patch$ matcher.
  exit 0
fi

# Extract patch text from tool_input.input or .command[-1] (same shape as
# the pre-hook captures). Codex's hook contract guarantees Pre/Post receive
# identical tool_input.
PATCH_TEXT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input
  | (.input // .command[-1] // "")
' 2>/dev/null || printf '')

# Path collection.
PATHS_RAW=""
if [ -n "$PATCH_TEXT" ]; then
  PATHS_RAW=$(coord_cx_apply_patch_paths "$PATCH_TEXT" 2>/dev/null || printf '')
fi

# Q5 fallback: parser produced no paths → release ALL session locks. Safer
# than wedging. The typical post-hook flow holds at most one apply_patch's
# worth of locks at a time, so the over-release is bounded.
if [ -z "$PATHS_RAW" ]; then
  warn_stderr 'apply_patch parser returned no paths; falling back to release-all-session-locks (Q5)'
  PATHS_RAW=$(jq -r --arg sid "$SESSION_ID" '
    .locks | to_entries[] | select(.value.session == $sid) | .key
  ' "$STATE" 2>/dev/null || printf '')
fi

if [ -z "$PATHS_RAW" ]; then
  # Nothing to release. Pre-hook may have failed atomic acquire and fallen
  # open; release-all sweep also empty. Silent no-op.
  exit 0
fi

PATHS_SORTED=$(printf '%s\n' "$PATHS_RAW" | LC_ALL=C sort -u)
NOW=$(coord_now_iso8601)

# Per-file release loop. Alphabetical order (deterministic for tests +
# observability per preview §5.2). Failure-tolerant per preview §5.4.
OLD_IFS="$IFS"
IFS='
'
set -- $PATHS_SORTED
IFS="$OLD_IFS"
for path in "$@"; do
  [ -z "$path" ] && continue

  # Capture lock metadata BEFORE deletion. notify_waiters needs the
  # acquired_at + verdict_ts pre-capture for its 4-tier diff_summary chain.
  LOCK_TSV=$(jq -r --arg f "$path" '
    (.locks[$f] // {}) as $L
    | [
        ($L.session // ""),
        ($L.acquired_at // ""),
        ($L.latest_validator_verdict_ts // ""),
        (($L.tasks // []) | length)
      ]
    | @tsv
  ' "$STATE" 2>/dev/null || printf '\t\t\t0')

  HOLDER=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $1}')
  ACQ=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $2}')
  VTS=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $3}')
  TASK_COUNT=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $4}')
  case "$TASK_COUNT" in ''|*[!0-9]*) TASK_COUNT=0 ;; esac

  if [ -z "$HOLDER" ]; then
    # No lock for this path. Pre-hook may have failed atomic acquire +
    # fallen open. Silent skip.
    continue
  fi

  if [ "$HOLDER" != "$SESSION_ID" ]; then
    # Defensive: never delete another session's lock. This implies a
    # protocol violation (pre-hook should have denied) but we MUST NOT
    # corrupt their state. Log + skip.
    coord_log_event kind=ERROR source=post_tool_use_apply_patch \
      tool=apply_patch file="$path" \
      reason=lock_held_by_other holder="$HOLDER"
    continue
  fi

  # Per-file task processor invocation. Runs BEFORE the lock-deletion
  # atomic_edit so locks[<path>].tasks[] is still readable. F-D5-01:
  # edit_range = 0/0 means "match all" — every queued self-task on this
  # file gets a TASK_OUTCOME notification regardless of which hunk(s)
  # the apply_patch touched. The Codex grammar's @@ headers don't carry
  # line numbers (parser's coord_cx_apply_patch_edit_range returns 0\t0).
  # TODO: when over-notification becomes a measurable problem, parse hunk
  # locations from a file snapshot at release time and pass real line
  # ranges instead of 0/0.
  if [ "$TASK_COUNT" != "0" ] \
     && command -v coord_task_processor_run >/dev/null 2>&1; then
    coord_task_processor_run "$path" "$SESSION_ID" 0 0 2>/dev/null || true
  fi

  # Atomic release. Loop tolerates failures — one file failing must NOT
  # abort release for the rest.
  if ! coord_atomic_edit "$STATE" \
        'del(.locks[$f])
         | .sessions[$sid].last_activity_at = $now' \
        --arg f "$path" --arg sid "$SESSION_ID" --arg now "$NOW"; then
    warn_stderr "atomic_edit failed during release of $path; lock may persist"
    coord_log_event kind=ERROR source=post_tool_use_apply_patch \
      tool=apply_patch file="$path" \
      reason=lock_release_failed
    continue
  fi

  coord_log_event kind=LOCK_RELEASED source=post_tool_use_apply_patch \
    tool=apply_patch file="$path" \
    released_at="$NOW" acquired_at="$ACQ"

  # Notify waiters (best-effort; failures don't abort).
  coord_notify_lock_release_waiters "$SESSION_ID" "$path" "$ACQ" "$NOW" "$VTS" \
    2>/dev/null || true
done

exit 0

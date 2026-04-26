#!/usr/bin/env bash
# pre_tool_use_write.sh — Claude Code PreToolUse hook for Write / Edit /
# NotebookEdit tools.
#
# PHASE 2 SCOPE (this file). Per plan §5 Phase 2:
#   "Lock acquisition in pre_tool_use_write.sh (flock-protected).
#    permissionDecision: deny when another session holds the lock;
#    permissionDecisionReason details the lock-holder + duration +
#    three options text (delegate / self-delegate / passive wait)."
#
# Behavior in Phase 2 (in order):
#   1. Non-participant gate (CLAUDE_COORD unset → exit 0).
#   2. Subagent filter (agent_type populated → SUBAGENT_ACTIVITY_SKIPPED,
#      exit 0; PR-PHASE0-01 binding).
#   3. Stale-read warning walk (Phase 1 behavior preserved): emit
#      additionalContext for any drift; never deny on stale reads in
#      Phase 2 — Phase 4's validator agent reclassifies SAFE/MINOR/
#      CRITICAL and may escalate to deny then.
#   4. Lock check (the Phase 2 delta):
#        a. If `locks[<target>]` is held by ANOTHER session → emit
#           hookSpecificOutput.permissionDecision: "deny" with the
#           CLAUDE.md §B.2 three-options reason text. Log LOCK_DENIED.
#        b. If `locks[<target>]` is held by THIS session → refresh
#           last_refresh_at; emit nothing; log LOCK_REFRESH; allow.
#        c. If `locks[<target>]` is unheld → acquire atomically:
#             locks[target] = {session, acquired_at, last_refresh_at, tasks: []}
#           Log LOCK_ACQUIRED. Emit nothing. Allow.
#   5. Always log a WRITE event for the intent regardless of branch.
#   6. Exit 0 in every branch (the deny is signaled via JSON output, not
#      via shell exit code).
#
# The Phase 2 invariant (asserted by bats): permissionDecision: "deny"
# appears ONLY in branch 4(a) — the lock-held-by-other path. Every
# other code path (non-participant, subagent, stale-read-only,
# self-refresh, fresh-acquire, missing-target, missing-deps, atomic-
# edit failure) remains allow-with-or-without-context, never deny.
#
# Phase-4 upgrade site is marked with "# PHASE-4 UPGRADE POINT".
#
# Cross-references:
#   CLAUDE.md §B.2 — runtime three-options text (verbatim source).
#   IMPLEMENTATION_PLAN.md §5 Phase 2 "Done when" + §3.7.2/§3.7.3
#     sequence diagrams (uncontested + contested write).

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
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $t}}'
}

# Emit `permissionDecision: "deny"` with the CLAUDE.md §B.2 three-options
# reason text. The reason is a multi-line string; jq's --arg + JSON
# encoding preserves \n through to Claude (Phase 2 carry-forward #3).
emit_deny() {
  local reason="$1"
  jq -nc --arg r "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                            permissionDecision: "deny",
                            permissionDecisionReason: $r}}'
}

warn_stderr() { printf 'coord pre_tool_use_write: %s\n' "$*" >&2; }

# Render a humane "N min ago" / "N sec ago" string from an ISO-8601
# timestamp. Falls back to the raw timestamp on parse failure. Bash 3.2
# safe (no Bash 4 features); uses portable date / awk arithmetic.
coord_human_age() {
  local iso="$1"
  [ -z "$iso" ] && { printf 'unknown'; return; }
  # Strip ms suffix if present (.123Z) for portable date -d / date -j.
  local base="${iso%.*Z}"
  case "$iso" in
    *.*Z) base="${base}Z" ;;
    *)    base="$iso" ;;
  esac
  local then now diff
  # GNU date first; fallback to BSD date -j -f.
  then=$(date -u -d "$base" +%s 2>/dev/null || \
         date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$base" +%s 2>/dev/null || \
         printf '')
  [ -z "$then" ] && { printf '%s' "$iso"; return; }
  now=$(date -u +%s 2>/dev/null || printf '0')
  diff=$(( now - then ))
  [ "$diff" -lt 0 ] && diff=0
  if [ "$diff" -lt 60 ]; then
    printf '%d sec ago' "$diff"
  elif [ "$diff" -lt 3600 ]; then
    printf '%d min ago' "$(( diff / 60 ))"
  else
    printf '%dh %dm ago' "$(( diff / 3600 ))" "$(( (diff % 3600) / 60 ))"
  fi
}

# Build the §B.2 three-options deny reason. Inputs:
#   $1 holder_short  — first 8 chars of holder session_id
#   $2 acquired_age  — humane "X min ago" string
#   $3 refresh_age   — humane "X sec ago" string
#   $4 target        — the path being denied
build_deny_reason() {
  local holder_short="$1"
  local acquired_age="$2"
  local refresh_age="$3"
  local target="$4"
  # The (a)/(b) CLI references are abstract — they name the subcommand
  # without freezing its full argument shape, since Phase 6 has not yet
  # finalized its contract. Running the disabled stubs prints the
  # current syntax (when Phase 6 enables them) along with a pointer at
  # option (c). Option (c) is verbatim because `coord wait` is the
  # active Phase 2 deliverable with stable syntax.
  printf 'File `%s` is locked by session `%s...` (acquired %s, last activity %s). Options:\n(a) Delegate a SIMPLE/MODERATE task: `coord task-open` (Phase 6 — currently disabled; running it now points you at option (c) and shows current syntax when enabled).\n(b) Self-delegate (do other work, return later): `coord self-delegate` (Phase 6 — currently disabled; running it now points you at option (c) and shows current syntax when enabled).\n(c) Passively wait: `Bash: coord wait %s --timeout 570` (blocks your Bash call until unlocked or timeout; 570 s is the max — it sits just below Claude Code'"'"'s 600 s Bash-tool ceiling).\nPick (a) for small, self-contained edits; (b) if you have other productive work; (c) only if the change is too complex to delegate AND you have no other work. Phase 2 only enables option (c); options (a)+(b) become available in Phase 6.' \
    "$target" "$holder_short" "$acquired_age" "$refresh_age" "$target"
}

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

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): emit deny + skip
# stale-read scan / lock check / acquire when lockdown is active. The
# lockdown deny supersedes the lock-held deny — the Mediator's pause
# is the priority signal. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "PreToolUse"; then
  exit 0
fi

# Always log the intent-to-write before any branching.
coord_log_event kind=WRITE tool="$TOOL_NAME" file="$TARGET" source=pre_tool_use_write

# --- (3) Stale-read warning walk (Phase 1 behavior preserved) -------------
ENTRIES_TSV=$(jq -r --arg sid "$SESSION_ID" '
  (.read_sets[$sid].reads // [])
  | map(select((.is_latest // false) == true and ((.superseded_by_head_change // false) == false)))
  | .[]
  | [.path, .hash] | @tsv
' "$STATE" 2>/dev/null || printf '')

STALE_BANNER=""
if [ -n "$ENTRIES_TSV" ]; then
  STALE_LINES=""
  STALE_COUNT=0
  OLD_IFS="$IFS"
  IFS='
'
  set -- $ENTRIES_TSV
  IFS="$OLD_IFS"
  for entry in "$@"; do
    path=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
    stored=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
    [ -z "$path" ] && continue

    reason=""
    if [ ! -e "$path" ]; then
      reason="file deleted since read"
    elif [ "$stored" = "SKIPPED_LARGE" ]; then
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
    STALE_BANNER="Coord stale-read warning: $STALE_COUNT file(s) you previously read have changed:"$'\n'"${STALE_LINES%$'\n'}"$'\n'"This write ($TOOL_NAME on $TARGET) is being allowed, but your earlier plan may be based on outdated content. Consider re-reading before proceeding. Phase 2 still warns rather than denies for stale reads; the Phase 4 validator agent will classify diffs."
    coord_log_event kind=STALE_READ_WARNED tool="$TOOL_NAME" file="$TARGET" stale_count="$STALE_COUNT"
  fi
fi

# --- (4) Lock check on $TARGET --------------------------------------------
# No target → emit any pending stale banner and exit (Notebook with no path,
# malformed input, etc.).
if [ -z "$TARGET" ]; then
  [ -n "$STALE_BANNER" ] && emit_additional_context "$STALE_BANNER"
  exit 0
fi

# Pull current lock holder + timestamps in a single jq call.
LOCK_TSV=$(jq -r --arg f "$TARGET" '
  (.locks[$f] // {}) as $L
  | [($L.session // ""), ($L.acquired_at // ""), ($L.last_refresh_at // "")]
  | @tsv
' "$STATE" 2>/dev/null || printf '')
LOCK_HOLDER=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $1}')
LOCK_ACQUIRED=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $2}')
LOCK_REFRESHED=$(printf '%s' "$LOCK_TSV" | awk -F'\t' '{print $3}')

NOW=$(coord_now_iso8601)

if [ -n "$LOCK_HOLDER" ] && [ "$LOCK_HOLDER" != "$SESSION_ID" ]; then
  # 4(a) Locked by another session — DENY with §B.2 three-options reason.
  HOLDER_SHORT="${LOCK_HOLDER:0:8}"
  ACQUIRED_AGE=$(coord_human_age "$LOCK_ACQUIRED")
  REFRESH_AGE=$(coord_human_age "$LOCK_REFRESHED")
  REASON=$(build_deny_reason "$HOLDER_SHORT" "$ACQUIRED_AGE" "$REFRESH_AGE" "$TARGET")
  coord_log_event kind=LOCK_DENIED tool="$TOOL_NAME" file="$TARGET" \
    holder="$LOCK_HOLDER" acquired_at="$LOCK_ACQUIRED"
  # Note: the deny output supersedes the stale banner — Claude needs the
  # actionable lock message first. Stale notes can resurface on retry.
  emit_deny "$REASON"
  exit 0
fi

if [ "$LOCK_HOLDER" = "$SESSION_ID" ]; then
  # 4(b) Self-write — refresh last_refresh_at.
  if ! coord_atomic_edit "$STATE" \
        '.locks[$f].last_refresh_at = $now
         | .sessions[$sid].last_activity_at = $now' \
        --arg f "$TARGET" --arg sid "$SESSION_ID" --arg now "$NOW"; then
    warn_stderr "atomic_edit failed during self-refresh; allowing write"
  else
    coord_log_event kind=LOCK_REFRESH tool="$TOOL_NAME" file="$TARGET"
  fi
  [ -n "$STALE_BANNER" ] && emit_additional_context "$STALE_BANNER"
  exit 0
fi

# 4(c) Unheld — acquire atomically.
if ! coord_atomic_edit "$STATE" \
      '.locks[$f] = {session: $sid, acquired_at: $now, last_refresh_at: $now, tasks: []}
       | .sessions[$sid].last_activity_at = $now' \
      --arg f "$TARGET" --arg sid "$SESSION_ID" --arg now "$NOW"; then
  # Atomic edit failed — fail-open per CLAUDE.md §A.5 / §B.9.3. Log + allow.
  warn_stderr "atomic_edit failed during lock acquire; allowing write uncoordinated"
  [ -n "$STALE_BANNER" ] && emit_additional_context "$STALE_BANNER"
  exit 0
fi
coord_log_event kind=LOCK_ACQUIRED tool="$TOOL_NAME" file="$TARGET" acquired_at="$NOW"
[ -n "$STALE_BANNER" ] && emit_additional_context "$STALE_BANNER"

# PHASE-4 UPGRADE POINT:
#   When the validation subagent lands, on stale-read-detected:
#     (a) write .coord/validation/<session_id>.json with payload
#         {tool, file, old_hash, current_hash, prompt_text} so the
#         validator agent hook can classify the diff as SAFE / MINOR /
#         CRITICAL on the next PreToolUse(Write|Edit) cycle.
#     (b) read back the verdict (written by validator_agent.md) and
#         escalate to deny only when verdict == CRITICAL.
#   See IMPLEMENTATION_PLAN.md §2 Decision 2.16 + §5 Phase 4.

exit 0

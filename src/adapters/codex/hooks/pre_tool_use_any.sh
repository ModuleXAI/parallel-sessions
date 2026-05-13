#!/usr/bin/env bash
# pre_tool_use_any.sh — Codex PreToolUse hook (matcher *).
#
# Phase D PR D.4 (plan v1.3 / A-D4-02). Cross-cutting BOOKKEEPING-ONLY
# consumer. Mirror of src/adapters/claude-code/hooks/pre_tool_use_any.sh
# with the banner-emission paths REMOVED.
#
# OUTPUT CHANNEL CONSTRAINT (D-D4-02 / plan v1.3):
#   Codex's PreToolUse output parser REJECTS additionalContext on this event
#   (codex-rs/hooks/src/engine/output_parser.rs:16-20 — PreToolUseOutput
#   has NO additional_context field, in contrast to SessionStartOutput,
#   PostToolUseOutput, UserPromptSubmitOutput which all do; :337-348 —
#   unsupported_pre_tool_use_hook_specific_output explicitly returns
#   "PreToolUse hook returned unsupported additionalContext" when the field
#   is non-empty, marking the hook HookRunStatus::Failed). This hook MUST
#   NOT emit additionalContext under any branch — the only valid output
#   channel is permissionDecision (deny via lockdown helper) or empty stdout.
#
# BOOKKEEPING SIDE EFFECTS (preserved from Claude mirror):
#   1. Notification scan + atomic clear. Notifications stay queued for
#      delivery via coord_status / coord wait CLI; their in-turn banner
#      surface that Claude provides on PreToolUse is dropped on Codex.
#   2. HEAD-recheck per CLAUDE.md §B.9.6: if current git HEAD differs
#      from sessions[$sid].git_head, mark every read_set entry with
#      superseded_by_head_change:true and update stored HEAD.
#   3. Corruption-recovery flag consume (atomic clear; no banner).
#   4. Mediator-pending JSONL consume (atomic; no banner — flock_timeout
#      and friends are still recorded in events.jsonl as
#      MEDIATOR_PENDING_DELIVERED).
#   5. Self-task reminder check + record (no banner; SELF_TASK_REMINDER
#      event still logged so audit + future re-routing has telemetry).
#   6. Watchdog ambient suspicion scan + fire-and-forget probes.
#   7. Mediator verdict consumer: apply actions[] from verdict files past
#      the per-session pointer, advance pointer. message_to_caller is
#      NOT surfaced (no banner channel on Codex PreToolUse).
#
# F-D4-03 follow-up: a future PR may reroute the dropped banners through
# user_prompt_submit.sh (per-prompt delivery instead of per-tool-call).
# Logged as a Phase F follow-up candidate; out of scope for D.4.
#
# Per D-2: NO subagent filter (Codex has no subagent concept). The Claude
# variant's F-015 educational banner for `coord wait` from a subagent
# context is NOT mirrored — Codex never enters that branch.

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
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/head_tracking.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/watchdog_cache.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/mediator_pending.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/watchdog.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/critical_check.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/verdict_apply.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/mediator_spawn.sh"
# shellcheck disable=SC1091
[ -f "$CORE_LIB_DIR/self_tasks.sh" ] && . "$CORE_LIB_DIR/self_tasks.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"

warn_stderr() { printf 'coord codex pre_tool_use_any: %s\n' "$*" >&2; }

# --- main ---
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

# Per D-2: NO subagent filter for Codex.

SESSION_ID=$(coord_cx_extract_session_id "$INPUT" 2>/dev/null || printf '')
CWD=$(coord_cx_extract_cwd "$INPUT" 2>/dev/null || printf '')

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
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0

# Lockdown gate. permissionDecision deny is the ONLY model-visible output
# this hook can produce on Codex (additionalContext is rejected).
if coord_lockdown_check && coord_lockdown_emit_deny "PreToolUse"; then
  exit 0
fi

# --- 1. Notification scan + atomic clear ---------------------------------
# Even though we cannot deliver the banner to the model on Codex
# PreToolUse, we still atomically clear delivered notifications so the
# CLI (`coord status`) reflects the cleared state and the queue does not
# grow without bound. The `NOTIFS_TEXT` is built only to drive the event
# log (NOTIFICATION_DELIVER), NOT to emit a banner.
NOTIFS_TEXT=$(jq -r --arg sid "$SESSION_ID" '
  (.notifications[$sid] // {})
  | to_entries
  | map(select((.value // []) | length > 0))
  | length
' "$STATE" 2>/dev/null || printf '0')
case "$NOTIFS_TEXT" in ''|*[!0-9]*) NOTIFS_TEXT=0 ;; esac

# --- 2. HEAD recheck (Decision 2.22 / §B.9.6) ----------------------------
CURRENT_HEAD=$(coord_current_head "${CWD:-.}")
HEAD_DRIFTED=0
PRIOR_HEAD=""
if [ -n "$CURRENT_HEAD" ] && coord_head_drifted "$SESSION_ID" "$CURRENT_HEAD"; then
  HEAD_DRIFTED=1
  PRIOR_HEAD=$(coord_stored_head "$SESSION_ID")
fi

# --- 3. Atomic edit: clear notifications + (on drift) mark + update head -
if [ "$NOTIFS_TEXT" != "0" ] || [ "$HEAD_DRIFTED" = "1" ]; then
  if ! coord_atomic_edit "$STATE" '
      (if ((.notifications[$sid] // {}) | length) > 0 then
         .notifications[$sid] = (.notifications[$sid]
           | with_entries(.value |= []))
       else . end)
    | (if $drifted == "1" then
         .read_sets[$sid].reads |= ((. // []) | map(. + {superseded_by_head_change: true}))
         | .sessions[$sid].git_head = $head
       else . end)
    ' \
    --arg sid     "$SESSION_ID" \
    --arg head    "$CURRENT_HEAD" \
    --arg drifted "$HEAD_DRIFTED"
  then
    warn_stderr 'atomic_edit failed during cross-cutting checks; continuing'
    # Fail-open. No exit; bookkeeping for the remaining steps still runs.
  fi
fi

# --- 4. Side-effect-only consumers (no banner) ---------------------------
# Each consumer runs for its bookkeeping; the banner-text returns are
# discarded (Codex would reject them on PreToolUse).
coord_consume_corrupt_state_flag >/dev/null 2>&1 || true
PENDING_CONSUMED=$(coord_mediator_consume_pending 2>/dev/null || printf '')
if [ -n "$PENDING_CONSUMED" ]; then
  coord_log_event kind=MEDIATOR_PENDING_DELIVERED source=pre_tool_use_any || true
fi
if [ "$NOTIFS_TEXT" != "0" ]; then
  coord_log_event kind=NOTIFICATION_DELIVER source=pre_tool_use_any || true
fi
if [ "$HEAD_DRIFTED" = "1" ]; then
  coord_log_event kind=HEAD_CHANGE source=pre_tool_use_any \
    old_head="$PRIOR_HEAD" new_head="$CURRENT_HEAD" || true
fi

# --- 5. Self-task reminder bookkeeping (no banner) -----------------------
# Mirrors Claude's reminder throttle: record_reminder updates
# last_reminded_at so the 5-min window is respected when delivery
# eventually reroutes (F-D4-03). SELF_TASK_REMINDER event is logged
# so audit/metrics + a future user_prompt_submit.sh consumer have a
# trail of "what reminders were due."
if command -v coord_self_task_check_unlocked >/dev/null 2>&1; then
  UNLOCKED_JSON=$(coord_self_task_check_unlocked "$SESSION_ID" 2>/dev/null || printf '[]')
  UNLOCKED_COUNT=$(printf '%s' "$UNLOCKED_JSON" | jq -r 'length' 2>/dev/null || printf '0')
  case "$UNLOCKED_COUNT" in ''|*[!0-9]*) UNLOCKED_COUNT=0 ;; esac
  SR_IDX=0
  while [ "$SR_IDX" -lt "$UNLOCKED_COUNT" ]; do
    SR_TASK=$(printf '%s' "$UNLOCKED_JSON" | jq -c --argjson i "$SR_IDX" '.[$i]' 2>/dev/null)
    SR_PID=$(printf '%s' "$SR_TASK" | jq -r '.prompt_id' 2>/dev/null)
    SR_FILE=$(printf '%s' "$SR_TASK" | jq -r '.file' 2>/dev/null)
    if coord_self_task_check_reminder_due "$SESSION_ID" "$SR_PID" 2>/dev/null; then
      coord_self_task_record_reminder "$SESSION_ID" "$SR_PID" 2>/dev/null || true
      coord_log_event kind=SELF_TASK_REMINDER \
        session="$SESSION_ID" prompt_id="$SR_PID" \
        file="$SR_FILE" source=pre_tool_use_any \
        2>/dev/null || true
    fi
    SR_IDX=$((SR_IDX + 1))
  done
fi

# --- 6. Ambient-suspicion watchdog probes (Phase 3 / T3.05) -------------
SUSPECT_TARGETS=$(coord_watchdog_check_ambient_suspicion 2>/dev/null || printf '')
if [ -n "$SUSPECT_TARGETS" ]; then
  OLD_IFS="$IFS"
  IFS='
'
  set -- $SUSPECT_TARGETS
  IFS="$OLD_IFS"
  for suspect in "$@"; do
    [ -z "$suspect" ] && continue
    ( coord_watchdog_probe "$suspect" >/dev/null 2>&1 ) &
    disown >/dev/null 2>&1 || true
  done
fi

# --- 7. Mediator verdict consumer (Phase 3 / T3.07) -----------------------
# Apply each new verdict's actions[] in sorted order; advance pointer.
# message_to_caller is NOT surfaced (Codex rejects additionalContext on
# PreToolUse). The audit trail of MEDIATOR_INLINE_VERDICT_APPLIED /
# MEDIATOR_PEER_AGREED / MEDIATOR_PEER_DISAGREED events is preserved.
VERDICT_DIR="$COORD_DIR/mediator/verdict"
POINTER_FILE="$COORD_DIR/sessions/${SESSION_ID}.last_consumed_verdict"
LAST_CONSUMED=""
if [ -f "$POINTER_FILE" ]; then
  LAST_CONSUMED=$(cat "$POINTER_FILE" 2>/dev/null | tr -d ' \n')
fi
if [ -d "$VERDICT_DIR" ]; then
  NEW_POINTER="$LAST_CONSUMED"
  for vfile in $(ls -1 "$VERDICT_DIR"/*.json 2>/dev/null | sort); do
    [ -f "$vfile" ] || continue
    vname=$(basename "$vfile" .json)
    if [ -n "$LAST_CONSUMED" ] && [ "$vname" \< "$LAST_CONSUMED" ] || [ "$vname" = "$LAST_CONSUMED" ]; then
      continue
    fi
    verdict_action=$(jq -r '.action_type // ""' "$vfile" 2>/dev/null) || verdict_action=""
    [ -z "$verdict_action" ] && continue
    verdict_confidence=$(jq -r '.confidence // "auto_apply"' "$vfile" 2>/dev/null)
    verdict_depth=$(jq -r '.depth // 1' "$vfile" 2>/dev/null)
    verdict_actions=$(jq -c '.actions // []' "$vfile" 2>/dev/null)

    apply_this="1"
    if [ "$verdict_confidence" = "needs_review" ] && [ "$verdict_depth" = "1" ]; then
      pending_id=$(jq -r '.for_pending_entry // ""' "$vfile" 2>/dev/null)
      peer_path=$(coord_mediator_spawn "$pending_id" 2 "$vfile" 2>/dev/null || printf '')
      if [ -n "$peer_path" ] && [ -f "$peer_path" ]; then
        peer_action=$(jq -r '.action_type // ""' "$peer_path" 2>/dev/null)
        if [ -n "$peer_action" ] && [ "$peer_action" = "$verdict_action" ]; then
          peer_severity=$(jq -r '.severity // ""' "$peer_path" 2>/dev/null)
          primary_severity=$(jq -r '.severity // ""' "$vfile" 2>/dev/null)
          if [ "$peer_severity" = "extended" ] || [ "$primary_severity" = "extended" ]; then
            chosen_severity="extended"
          else
            chosen_severity="$primary_severity"
          fi
          coord_log_event kind=MEDIATOR_PEER_AGREED \
            primary_verdict_path="$vfile" peer_verdict_path="$peer_path" \
            agreed_action="$verdict_action" applied_severity="$chosen_severity" 2>/dev/null || true
          apply_this="1"
        else
          coord_log_event kind=MEDIATOR_PEER_DISAGREED \
            primary_verdict_path="$vfile" peer_verdict_path="$peer_path" \
            primary_action="$verdict_action" peer_action="$peer_action" 2>/dev/null || true
          apply_this=""
        fi
      else
        coord_log_event kind=MEDIATOR_ESCALATED_TO_USER \
          reason=peer_spawn_failed primary_verdict_path="$vfile" 2>/dev/null || true
        apply_this=""
      fi
    fi
    if [ -n "$apply_this" ] && [ -n "$verdict_actions" ] && [ "$verdict_actions" != "null" ] && [ "$verdict_actions" != "[]" ]; then
      coord_verdict_apply_actions "$verdict_actions" 2>/dev/null || true
    fi
    NEW_POINTER="$vname"
  done
  if [ -n "$NEW_POINTER" ] && [ "$NEW_POINTER" != "$LAST_CONSUMED" ]; then
    mkdir -p "$(dirname "$POINTER_FILE")" 2>/dev/null
    printf '%s' "$NEW_POINTER" >"${POINTER_FILE}.tmp.$$" 2>/dev/null \
      && mv -f "${POINTER_FILE}.tmp.$$" "$POINTER_FILE" 2>/dev/null \
      || rm -f "${POINTER_FILE}.tmp.$$" 2>/dev/null
  fi
fi

# Allow path: empty stdout. NEVER emit additionalContext (Codex rejects).
exit 0

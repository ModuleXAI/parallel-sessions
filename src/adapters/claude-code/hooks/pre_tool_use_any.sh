#!/usr/bin/env bash
# pre_tool_use_any.sh — Claude Code PreToolUse hook (matcher .*).
#
# Cross-cutting context-injection hook. Runs before tool-specific
# PreToolUse hooks (pre_tool_use_read.sh, pre_tool_use_write.sh) and
# carries the responsibility for signals that aren't tied to a single
# tool: pending notifications anywhere in the session's scope, and
# git-HEAD drift detected mid-session.
#
# PHASE 1 SCOPE — minimal per plan §5:
#   - Deliver any pending notifications across the whole session
#     (notifications[$sid][*] arrays), then clear them. Single atomic_edit.
#   - HEAD-change recheck per CLAUDE.md §B.9.6: if current git HEAD
#     differs from sessions[$sid].git_head, mark every read_set entry
#     with superseded_by_head_change:true and update the stored HEAD,
#     then emit additionalContext + HEAD_CHANGE event.
#
# OUT OF PHASE 1 (deferred):
#   - Self-task reminders (Phase 6 — needs `self_tasks` table).
#   - Mediator-pending notices (Phase 3 — needs `.coord/mediator/pending.json`
#     consumer wired in).
#   See PHASE-3 / PHASE-6 upgrade points at the bottom of this file.
#
# Phase 1 ship gate: NEVER sets permissionDecision. All paths exit 0.

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
. "$CORE_LIB_DIR/head_tracking.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
. "$CORE_LIB_DIR/folder_resolver.sh"
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

emit_additional_context() {
  local text="$1"
  jq -nc --arg t "$text" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $t}}'
}

warn_stderr() { printf 'coord pre_tool_use_any: %s\n' "$*" >&2; }

# --- main ---
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

if COORD_DIR=$(coord_resolve_root 2>/dev/null); then
  export COORD_DIR
fi
if coord_subagent_filter "PreToolUse" "$INPUT"; then
  # Phase 6 T6.06 F-015 disposition (PR-PHASE6-01 + Decision 1):
  # In subagent context, normally exit 0 silently per Decision
  # 2.17. The narrow F-015 case is a `Bash: coord wait …`
  # invocation issued from within a spawned subagent — we
  # surface a soft-deprecation educational banner pointing the
  # subagent at parent-session task delegation primitives, then
  # exit 0. Banner is informational; NO third deny location is
  # introduced (Decision 6 invariant preserved).
  F015_TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || printf '')
  if [ "$F015_TOOL" = "Bash" ]; then
    F015_CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || printf '')
    # Strip leading whitespace and check for "coord wait" prefix
    # (case-sensitive). Match either "coord wait" alone or
    # "coord wait <args>".
    F015_CMD_TRIM="${F015_CMD#"${F015_CMD%%[! 	]*}"}"
    case "$F015_CMD_TRIM" in
      "coord wait"|"coord wait "*)
        emit_additional_context $'Subagent context detected; `coord wait` is allowed but Phase 6 task delegation primitives via parent session are recommended for tracked workflow. See `coord task-open` and `coord self-delegate` for the parent-session equivalents.'
        # Read session_id + agent_type directly from INPUT —
        # SESSION_ID env var has not been populated yet at this
        # point in the hook flow (the parse happens after the
        # subagent_filter branch).
        F015_PARENT=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
        F015_AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null || printf '')
        coord_log_event kind=SUBAGENT_COORD_WAIT_BANNER_EMITTED \
          agent_type="$F015_AGENT" parent_session="$F015_PARENT" \
          source=pre_tool_use_any 2>/dev/null || true
        ;;
    esac
  fi
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || printf '')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || printf '')

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

# Lockdown gate (Phase 3 / T3.03 per PR-PHASE3-01): emit deny + skip
# all cross-cutting consumers (notifications / mediator-pending /
# corruption banners) when lockdown is active. Fail-open on parse fail.
if coord_lockdown_check && coord_lockdown_emit_deny "PreToolUse"; then
  exit 0
fi

# --- 1. Notification scan + atomic clear ---------------------------------
# Capture pending notifications first (read-only), then clear them in a
# single atomic_edit. The captured text is what we emit, which matches the
# state AFTER the clear (no double-delivery if pre_tool_use_read runs
# concurrently — its own delivery becomes a no-op once cleared).
NOTIFS_TEXT=$(jq -r --arg sid "$SESSION_ID" '
  (.notifications[$sid] // {})
  | to_entries
  | map(select((.value // []) | length > 0))
  | map(
      "  • " + .key + ":\n"
      + ((.value | map("      - " + .)) | join("\n"))
    )
  | join("\n")
' "$STATE" 2>/dev/null || printf '')

# --- 2. HEAD recheck (Decision 2.22 / §B.9.6) ---------------------------
CURRENT_HEAD=$(coord_current_head "${CWD:-.}")
HEAD_DRIFTED=0
PRIOR_HEAD=""
if [ -n "$CURRENT_HEAD" ] && coord_head_drifted "$SESSION_ID" "$CURRENT_HEAD"; then
  HEAD_DRIFTED=1
  PRIOR_HEAD=$(coord_stored_head "$SESSION_ID")
fi

# --- 3. Atomic edit: clear notifications + (on drift) mark + update head -
if [ -n "$NOTIFS_TEXT" ] || [ "$HEAD_DRIFTED" = "1" ]; then
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
    warn_stderr 'atomic_edit failed during cross-cutting checks; allow continues'
    # Fail-open. Don't exit early — still emit any captured notification text.
  fi
fi

# --- 4. Compose + emit additionalContext ---------------------------------
BANNER=""
# Corruption-recovery banner per §B.9.2 step 4 (consumed once per flag).
CORRUPT_BANNER=$(coord_consume_corrupt_state_flag || printf '')
if [ -n "$CORRUPT_BANNER" ]; then
  BANNER="$CORRUPT_BANNER"
fi
# Phase 2 T2.04: Mediator pending JSONL consumer (flock_timeout +
# any future Phase-3+ kinds). Compose alongside corruption banner.
PENDING_BANNER=$(coord_mediator_consume_pending || printf '')
if [ -n "$PENDING_BANNER" ]; then
  if [ -n "$BANNER" ]; then BANNER="$BANNER"$'\n\n'; fi
  BANNER="${BANNER}${PENDING_BANNER}"
  coord_log_event kind=MEDIATOR_PENDING_DELIVERED source=pre_tool_use_any
fi
if [ -n "$NOTIFS_TEXT" ]; then
  if [ -n "$BANNER" ]; then BANNER="$BANNER"$'\n\n'; fi
  BANNER="${BANNER}Coord notifications pending:"$'\n'"$NOTIFS_TEXT"
  coord_log_event kind=NOTIFICATION_DELIVER source=pre_tool_use_any
fi
if [ "$HEAD_DRIFTED" = "1" ]; then
  HEAD_NOTE="Coord: git HEAD changed since your last activity (was $PRIOR_HEAD, now $CURRENT_HEAD). Your read-set is invalidated; re-read any files you depend on."
  if [ -n "$BANNER" ]; then
    BANNER="$BANNER"$'\n\n'"$HEAD_NOTE"
  else
    BANNER="$HEAD_NOTE"
  fi
  coord_log_event kind=HEAD_CHANGE source=pre_tool_use_any old_head="$PRIOR_HEAD" new_head="$CURRENT_HEAD"
fi

# --- Phase 6 T6.06 self-task reminder injection -------------------------
# PR-PHASE6-02 + Decision 2.13: for each unlocked self-task (file
# currently unheld OR held by self), emit a reminder banner. Throttled
# per-task by last_reminded_at field with 5min window to avoid
# reminder spam on rapid-fire PreToolUse calls. Tasks listed in
# chronological order (oldest first) for predictability — Decision
# 2.13 silent on order; chronological is the natural FIFO of the
# self_tasks[<sid>] array.
SELF_REMINDER_BANNER=""
if command -v coord_self_task_check_unlocked >/dev/null 2>&1; then
  UNLOCKED_JSON=$(coord_self_task_check_unlocked "$SESSION_ID" 2>/dev/null || printf '[]')
  UNLOCKED_COUNT=$(printf '%s' "$UNLOCKED_JSON" | jq -r 'length' 2>/dev/null || printf '0')
  case "$UNLOCKED_COUNT" in
    ''|*[!0-9]*) UNLOCKED_COUNT=0 ;;
  esac
  if [ "$UNLOCKED_COUNT" != "0" ]; then
    SR_IDX=0
    while [ "$SR_IDX" -lt "$UNLOCKED_COUNT" ]; do
      SR_TASK=$(printf '%s' "$UNLOCKED_JSON" | jq -c --argjson i "$SR_IDX" '.[$i]' 2>/dev/null)
      SR_PID=$(printf '%s' "$SR_TASK" | jq -r '.prompt_id' 2>/dev/null)
      SR_FILE=$(printf '%s' "$SR_TASK" | jq -r '.file' 2>/dev/null)
      SR_INSTR=$(printf '%s' "$SR_TASK" | jq -r '.instruction' 2>/dev/null)
      if coord_self_task_check_reminder_due "$SESSION_ID" "$SR_PID" 2>/dev/null; then
        SR_LINE="reminder: ${SR_FILE} is now free, your self-task pending: '${SR_INSTR}'"
        if [ -z "$SELF_REMINDER_BANNER" ]; then
          SELF_REMINDER_BANNER="$SR_LINE"
        else
          SELF_REMINDER_BANNER="${SELF_REMINDER_BANNER}"$'\n'"${SR_LINE}"
        fi
        coord_self_task_record_reminder "$SESSION_ID" "$SR_PID" 2>/dev/null || true
        coord_log_event kind=SELF_TASK_REMINDER \
          session="$SESSION_ID" prompt_id="$SR_PID" \
          file="$SR_FILE" source=pre_tool_use_any \
          2>/dev/null || true
      fi
      SR_IDX=$((SR_IDX + 1))
    done
  fi
fi

if [ -n "$SELF_REMINDER_BANNER" ]; then
  if [ -n "$BANNER" ]; then
    BANNER="$BANNER"$'\n\n'"$SELF_REMINDER_BANNER"
  else
    BANNER="$SELF_REMINDER_BANNER"
  fi
fi

if [ -n "$BANNER" ]; then
  emit_additional_context "$BANNER"
fi

# --- 5. Ambient-suspicion watchdog probes (Phase 3 / T3.05) -----------
# Scan sessions.json for OTHER-session anomalies. For each suspect,
# fire-and-forget a watchdog probe. Caller (this hook) does NOT block
# on probe execution — the probe runs in the background and writes its
# verdict to recent_checks.jsonl + (on dead/uncertain) emits a Mediator
# pending entry that a future pre_tool_use_any.sh consumer-pass surfaces.
#
# The dedupe lock (.coord/watchdog/checking/<target>.lock) guarantees
# only ONE probe per target runs even if 5+ sessions notice the same
# anomaly simultaneously. The recent_checks cache (TTL alive=60s,
# uncertain=30s, dead=until-session_start) suppresses redundant probes.
#
# Per PR-PHASE3-02 §F (latency budget): suspicion check is a single jq
# filter over the already-loaded sessions.json snapshot + per-PID `ps`
# checks bounded by ACTIVE-non-self session count. Probe invocation
# is backgrounded so its execution time does NOT count against the
# hook latency.
SUSPECT_TARGETS=$(coord_watchdog_check_ambient_suspicion 2>/dev/null || printf '')
if [ -n "$SUSPECT_TARGETS" ]; then
  OLD_IFS="$IFS"
  IFS='
'
  set -- $SUSPECT_TARGETS
  IFS="$OLD_IFS"
  for suspect in "$@"; do
    [ -z "$suspect" ] && continue
    # Fire-and-forget: probe runs in background, hook returns immediately.
    # The disown after backgrounding ensures Claude Code is not blocked
    # on the subshell's lifetime.
    ( coord_watchdog_probe "$suspect" >/dev/null 2>&1 ) &
    disown >/dev/null 2>&1 || true
  done
fi

# --- 6. Mediator verdict consumer (Phase 3 / T3.07) -----------------------
# Read verdict files written by Mediator subagents since this session's
# last_consumed_verdict pointer. Apply each verdict's actions[] in
# sorted order (lockdown → release_lock → evict_session → clear_read_set
# per PR-PHASE3-04 Note B), inject message_to_caller into
# additionalContext, and advance the pointer.
#
# The pointer lives at .coord/sessions/<sid>.last_consumed_verdict
# (single line: timestamp ISO of the most-recent consumed verdict file).
# Verdict files are named <ts>.json (with colons → dashes for
# filesystem safety); lex order = chronological order.
VERDICT_DIR="$COORD_DIR/mediator/verdict"
POINTER_FILE="$COORD_DIR/sessions/${SESSION_ID}.last_consumed_verdict"
LAST_CONSUMED=""
if [ -f "$POINTER_FILE" ]; then
  LAST_CONSUMED=$(cat "$POINTER_FILE" 2>/dev/null | tr -d ' \n')
fi
if [ -d "$VERDICT_DIR" ]; then
  VERDICT_BANNERS=""
  NEW_POINTER="$LAST_CONSUMED"
  # Iterate verdict files in chronological order.
  for vfile in $(ls -1 "$VERDICT_DIR"/*.json 2>/dev/null | sort); do
    [ -f "$vfile" ] || continue
    vname=$(basename "$vfile" .json)
    # Skip if this verdict is at-or-before our pointer.
    if [ -n "$LAST_CONSUMED" ] && [ "$vname" \< "$LAST_CONSUMED" ] || [ "$vname" = "$LAST_CONSUMED" ]; then
      continue
    fi
    # Read verdict JSON. Skip on parse failure (fail-open).
    verdict_action=$(jq -r '.action_type // ""' "$vfile" 2>/dev/null) || verdict_action=""
    [ -z "$verdict_action" ] && continue
    verdict_confidence=$(jq -r '.confidence // "auto_apply"' "$vfile" 2>/dev/null)
    verdict_depth=$(jq -r '.depth // 1' "$vfile" 2>/dev/null)
    verdict_msg=$(jq -r '.message_to_caller // ""' "$vfile" 2>/dev/null)
    verdict_actions=$(jq -c '.actions // []' "$vfile" 2>/dev/null)
    # Peer-review path (PR-PHASE3-01 escalation hierarchy): if the
    # primary verdict is needs_review AND we're at depth=1, spawn a
    # peer Mediator at depth=2 with the primary verdict in context.
    # Compare action_types; same → apply primary (more conservative
    # severity); different → emit user-escalation banner.
    apply_this="1"
    user_escalation_banner=""
    if [ "$verdict_confidence" = "needs_review" ] && [ "$verdict_depth" = "1" ]; then
      pending_id=$(jq -r '.for_pending_entry // ""' "$vfile" 2>/dev/null)
      peer_path=$(coord_mediator_spawn "$pending_id" 2 "$vfile" 2>/dev/null || printf '')
      if [ -n "$peer_path" ] && [ -f "$peer_path" ]; then
        peer_action=$(jq -r '.action_type // ""' "$peer_path" 2>/dev/null)
        if [ -n "$peer_action" ] && [ "$peer_action" = "$verdict_action" ]; then
          # Agreement on action_type — apply primary with the more
          # conservative severity (extended > brief).
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
          # Disagreement → user escalation; do NOT apply.
          coord_log_event kind=MEDIATOR_PEER_DISAGREED \
            primary_verdict_path="$vfile" peer_verdict_path="$peer_path" \
            primary_action="$verdict_action" peer_action="$peer_action" 2>/dev/null || true
          user_escalation_banner="Mediator peer-review disagreed (primary=$verdict_action peer=$peer_action). Please inspect verdict files: $vfile and $peer_path. Run \`coord mediate --approve <path>\` to choose, or \`coord mediate --escalate\` to overrule."
          apply_this=""
        fi
      else
        # Peer spawn failed — escalate to user rather than apply
        # unverified needs_review verdict.
        coord_log_event kind=MEDIATOR_ESCALATED_TO_USER \
          reason=peer_spawn_failed primary_verdict_path="$vfile" 2>/dev/null || true
        user_escalation_banner="Mediator verdict at $vfile is needs_review but peer-review spawn failed. Please inspect manually."
        apply_this=""
      fi
    fi
    # Apply actions (verdict_apply.sh handles ordering + idempotency
    # internally; the simple iteration here is enough since actions
    # array is already small + per-verdict).
    if [ -n "$apply_this" ] && [ -n "$verdict_actions" ] && [ "$verdict_actions" != "null" ] && [ "$verdict_actions" != "[]" ]; then
      coord_verdict_apply_actions "$verdict_actions" 2>/dev/null || true
    fi
    if [ -n "$verdict_msg" ]; then
      if [ -n "$VERDICT_BANNERS" ]; then
        VERDICT_BANNERS="$VERDICT_BANNERS"$'\n\n'
      fi
      VERDICT_BANNERS="${VERDICT_BANNERS}Coord Mediator verdict: ${verdict_msg}"
    fi
    if [ -n "$user_escalation_banner" ]; then
      if [ -n "$VERDICT_BANNERS" ]; then
        VERDICT_BANNERS="$VERDICT_BANNERS"$'\n\n'
      fi
      VERDICT_BANNERS="${VERDICT_BANNERS}${user_escalation_banner}"
    fi
    NEW_POINTER="$vname"
  done
  # Persist new pointer (atomic temp+rename).
  if [ -n "$NEW_POINTER" ] && [ "$NEW_POINTER" != "$LAST_CONSUMED" ]; then
    mkdir -p "$(dirname "$POINTER_FILE")" 2>/dev/null
    printf '%s' "$NEW_POINTER" >"${POINTER_FILE}.tmp.$$" 2>/dev/null \
      && mv -f "${POINTER_FILE}.tmp.$$" "$POINTER_FILE" 2>/dev/null \
      || rm -f "${POINTER_FILE}.tmp.$$" 2>/dev/null
  fi
  # Compose verdict banners into the hook output. The lockdown gate
  # already fired earlier (line 100ish); if it didn't deny us, the
  # verdict banner is safe to emit. We append to the BANNER variable
  # if it exists, otherwise emit standalone additionalContext.
  if [ -n "$VERDICT_BANNERS" ]; then
    if [ -n "${BANNER:-}" ]; then
      BANNER="$BANNER"$'\n\n'"$VERDICT_BANNERS"
      # Re-emit additionalContext with the augmented BANNER. The
      # earlier emit already happened above so we'd double-emit;
      # cleaner to emit verdict banners as a separate
      # additionalContext block.
    fi
    emit_additional_context "$VERDICT_BANNERS"
  fi
fi

exit 0

# PHASE-3 UPGRADE POINT (partially retired in T2.04):
#   T2.04 added the JSONL pending-queue consumer (coord_mediator_consume_pending
#   above) covering kind=flock_timeout. Phase 3 will EXTEND with:
#     - Mediator agent-hook firing on consume (instead of just surfacing
#       a banner, the agent hook investigates + remediates).
#     - Verdict surfacing: a check for `.coord/mediator/verdict/<latest>.json`
#       to deliver verdicts that Claude did not see at the time of issuance
#       (e.g., escalate_to_user verdicts written between turns).
#     - Additional pending kinds: stale_active, pid_recycled, schema_mismatch,
#       manual (via `coord mediate`).
#   See IMPLEMENTATION_PLAN.md §4 mediator_agent.md component spec and
#   §5 Phase 3 "Done when" criteria.
#
# PHASE-6 UPGRADE POINT:
#   When self-delegation lands, this hook iterates self_tasks[$sid][] for
#   entries with status:"PENDING" whose target file is now unlocked, and
#   injects the reminder text per CLAUDE.md §B.7. The reminder is
#   accumulated into the SAME additionalContext banner already used here
#   for notifications + HEAD-change.
#   See IMPLEMENTATION_PLAN.md §5 Phase 6 "Done when" + §B.7 runtime rule.

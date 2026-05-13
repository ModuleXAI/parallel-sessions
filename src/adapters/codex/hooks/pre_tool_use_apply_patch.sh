#!/usr/bin/env bash
# pre_tool_use_apply_patch.sh — Codex PreToolUse hook for apply_patch tool.
#
# Phase D PR D.4 (plan v1.3 / A-D4-02 + A-D4-01). Multi-file
# lock-acquire-all-or-deny atomicity (D-12) plus structural pre_image-
# search drift gate (D-D4-01). Single source of multi-file write
# coordination on Codex.
#
# OUTPUT CHANNEL CONSTRAINT (D-D4-02 — plan v1.3):
#   Codex's PreToolUse output parser REJECTS additionalContext on this
#   event (`codex-rs/hooks/src/engine/output_parser.rs:16-20` —
#   PreToolUseOutput has NO additional_context field; `:337-348` —
#   `unsupported_pre_tool_use_hook_specific_output` returns
#   "PreToolUse hook returned unsupported additionalContext" when the
#   field is non-empty, marking the hook HookRunStatus::Failed). This
#   hook outputs ONLY:
#     - permissionDecision deny (lock conflict / drift / lockdown / race-loss)
#     - empty stdout (allow)
#   NEVER emit additionalContext under any branch.
#
# DRIFT GATE (D-D4-01 — plan v1.2):
#   Structural pre_image-search, NOT validator-pipeline integration.
#   For each Update operation's hunks: read file at lock time, search for
#   hunk.pre_image as exact substring; unique match (or @@ context label
#   disambiguated) → drift-clean. Pure-addition hunks (empty pre_image)
#   skipped. Add File requires file absent; Delete File requires file
#   present. Move ops: source has Update semantics, destination has Add.
#   Files >= 1 MB skip drift check (soft-allow + acquire) — symmetric
#   with `validator_prefilter.sh`'s SKIPPED_LARGE.
#
# LOCK ACQUISITION (D-12 + F-D4-01 consolidated filter):
#   Single atomic_edit with VALIDATE-OR-ABORT filter. The filter:
#     - acquires unheld paths (full lock entry)
#     - refreshes self-held paths (last_refresh_at only)
#     - jq error("race_loser:") aborts on peer-held seen mid-flight
#   Atomic transaction; either all locks land or none do.

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
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/apply_patch_parser.sh"

# === Output emitters (NO additionalContext per D-D4-02) =====================

emit_deny() {
  local reason="$1"
  jq -nc --arg r "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                            permissionDecision: "deny",
                            permissionDecisionReason: $r}}'
}

warn_stderr() { printf 'coord codex pre_tool_use_apply_patch: %s\n' "$*" >&2; }

# === Humane-age helper (mirror of Claude's coord_human_age) =================
# Inline to keep this hook self-contained per design Q3 default.

coord_cx_human_age() {
  local iso="$1"
  [ -z "$iso" ] && { printf 'unknown'; return; }
  local base="${iso%.*Z}"
  case "$iso" in
    *.*Z) base="${base}Z" ;;
    *)    base="$iso" ;;
  esac
  local then now diff
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

# === Task-delegation toggle (mirror of Claude pre_tool_use_write helper) ===

_coord_cx_task_delegation_enabled() {
  local cfg
  if [ -n "${COORD_DIR:-}" ]; then
    cfg="$COORD_DIR/config.json"
  else
    cfg=""
  fi
  if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
    printf 'true'
    return 0
  fi
  local val
  val=$(jq -r 'if has("task_delegation") then .task_delegation else true end' \
        "$cfg" 2>/dev/null) || val="true"
  printf '%s' "$val"
}

# === Deny-banner builders ===================================================
# Single-file template: mirrors Claude's §B.2 three-options text adapted for
# apply_patch context. Multi-file template enumerates all blocked files.

build_single_file_deny() {
  local holder_short="$1"
  local acquired_age="$2"
  local refresh_age="$3"
  local target="$4"
  local toggle
  toggle=$(_coord_cx_task_delegation_enabled)
  if [ "$toggle" = "true" ]; then
    printf 'apply_patch was DENIED — file `%s` is locked by session `%s...` since %s (~%s). Every file in a multi-file patch must be free. Options:\n(a) Delegate via `coord task-open --file %s --complexity SIMPLE --instruction '"'"'\xE2\x80\xA6'"'"'`.\n(b) Self-delegate: `coord self-delegate --file %s --instruction '"'"'\xE2\x80\xA6'"'"'`.\n(c) Wait: `coord wait %s --timeout 570`.' \
      "$target" "$holder_short" "$acquired_age" "$refresh_age" \
      "$target" "$target" "$target"
  else
    printf 'apply_patch was DENIED — file `%s` is locked by session `%s...` since %s (~%s). Options (task delegation disabled in this repo):\n(b) Self-delegate: `coord self-delegate --file %s --instruction '"'"'\xE2\x80\xA6'"'"'`.\n(c) Wait: `coord wait %s --timeout 570`.' \
      "$target" "$holder_short" "$acquired_age" "$refresh_age" \
      "$target" "$target"
  fi
}

# build_multi_file_deny <total_paths> <blocked_count> <blocked_lines>
# blocked_lines is a printf-ready string, one line per blocked file.
build_multi_file_deny() {
  local total="$1"
  local count="$2"
  local lines="$3"
  printf 'apply_patch was DENIED — %s of %s files in the patch are locked:\n%s\nAll files must be free before the patch can apply. Options:\n(a) Delegate the patch via `coord task-open` (one task per blocked file) to one of the holders.\n(b) Wait via `coord wait` (passes multiple files since Phase 5 T5.06).\n(c) Self-delegate the patch and resume after the holders release.' \
    "$count" "$total" "$lines"
}

# build_drift_deny <drift_lines>
build_drift_deny() {
  local lines="$1"
  printf 'apply_patch was DENIED — drift detected:\n%s\nDrift means one or more files changed since you composed the patch (or the patch references a file that does not exist in the expected state). Re-read the affected files via the Read tool, then submit a fresh patch.' \
    "$lines"
}

# === Drift-check helpers ====================================================

# Returns 0 if file is "small enough" for drift check, 1 if it should be skipped.
_coord_cx_file_under_drift_threshold() {
  local path="$1"
  [ ! -f "$path" ] && return 0  # missing file: handled separately by op type
  local size
  size=$(wc -c <"$path" 2>/dev/null | tr -d ' ' || printf '0')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  # 1 MB threshold (1048576) per preview §4.3 / D-D4-01.
  [ "$size" -lt 1048576 ]
}

# _coord_cx_count_substring <full_text> <substring>
# Echoes the count of occurrences of <substring> in <full_text>. Bash
# pattern matching is multi-line safe (unlike `grep -F` which is
# line-oriented). The loop trims the matched prefix on each iteration
# and re-tests; under the 1 MB drift cap this is bounded.
#
# F-D4-08 (DO NOT "simplify" back to grep -cF): grep -cF counts matching
# LINES, not substring occurrences. A multi-line pre_image (common — hunks
# frequently span 3-5 lines) would be split on newlines by grep -cF,
# missing legitimate matches. Bash-native scanning is the correct primitive
# for the structural drift gate.
_coord_cx_count_substring() {
  local hay="$1" needle="$2"
  if [ -z "$needle" ]; then printf '0'; return; fi
  local count=0
  local rest="$hay"
  while [[ "$rest" == *"$needle"* ]]; do
    count=$((count + 1))
    rest="${rest#*"$needle"}"
    # Defensive cap: refuse runaway loops; 100 occurrences is well past
    # any sane apply_patch hunk shape.
    if [ "$count" -ge 100 ]; then break; fi
  done
  printf '%d' "$count"
}

# _coord_cx_substring_after_label <full_text> <label> <needle>
# Returns 0 (with count of needle on stdout) when the label is found
# AND needle appears at least once in the substring after the label.
# Returns 1 when label is not present or needle is absent after it.
_coord_cx_count_substring_after_label() {
  local hay="$1" label="$2" needle="$3"
  if [ -z "$label" ] || [ -z "$needle" ]; then printf '0'; return; fi
  case "$hay" in
    *"$label"*) ;;
    *) printf '0'; return ;;
  esac
  local trail="${hay#*"$label"}"
  _coord_cx_count_substring "$trail" "$needle"
}

# _coord_cx_drift_check_update <patch> <path>
# Returns 0 if no drift, 1 if drift detected. Sets _CX_DRIFT_REASON
# with a one-line description on drift.
_coord_cx_drift_check_update() {
  local patch="$1" path="$2"
  _CX_DRIFT_REASON=""
  if [ ! -f "$path" ]; then
    _CX_DRIFT_REASON="file missing (Update target absent)"
    return 1
  fi
  if ! _coord_cx_file_under_drift_threshold "$path"; then
    warn_stderr "drift check skipped for $path (size >= 1 MB) — apply_patch will catch any structural mismatch at apply time"
    return 0
  fi
  local hunks_json
  hunks_json=$(coord_cx_apply_patch_hunks "$patch" "$path" 2>/dev/null) || hunks_json="[]"
  local file_content
  file_content=$(cat "$path" 2>/dev/null || printf '')
  local len
  len=$(printf '%s' "$hunks_json" | jq -r 'length' 2>/dev/null || printf '0')
  case "$len" in ''|*[!0-9]*) len=0 ;; esac
  local i=0
  while [ "$i" -lt "$len" ]; do
    local hunk pre_image header_label
    hunk=$(printf '%s' "$hunks_json" | jq -c --argjson i "$i" '.[$i]' 2>/dev/null)
    pre_image=$(printf '%s' "$hunk" | jq -r '.pre_image // ""' 2>/dev/null)
    header_label=$(printf '%s' "$hunk" | jq -r '.header // ""' 2>/dev/null)
    if [ -z "$pre_image" ]; then
      # Pure-addition hunk: drift-clean by definition.
      i=$((i + 1))
      continue
    fi
    # Bash-native multi-line substring count (grep -F is line-oriented and
    # would split a multi-line pre_image into separate patterns).
    local match_count
    match_count=$(_coord_cx_count_substring "$file_content" "$pre_image")
    case "$match_count" in ''|*[!0-9]*) match_count=0 ;; esac
    if [ "$match_count" = "0" ]; then
      _CX_DRIFT_REASON="hunk $((i + 1)) — pre-image not found in current file"
      return 1
    fi
    if [ "$match_count" = "1" ]; then
      i=$((i + 1))
      continue
    fi
    # Multiple matches: try to disambiguate via header label. If the label
    # appears in the file AND the pre_image appears at least once after it,
    # treat as anchored to that label (apply_patch's behavior).
    if [ -n "$header_label" ]; then
      local trail_count
      trail_count=$(_coord_cx_count_substring_after_label "$file_content" "$header_label" "$pre_image")
      case "$trail_count" in ''|*[!0-9]*) trail_count=0 ;; esac
      if [ "$trail_count" -ge "1" ]; then
        i=$((i + 1))
        continue
      fi
    fi
    _CX_DRIFT_REASON="hunk $((i + 1)) — pre-image matches ambiguously ($match_count occurrences, no disambiguating header label)"
    return 1
  done
  return 0
}

# === main ===================================================================

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
    warn_stderr "dependency $dep missing; allowing apply_patch uncoordinated"
    exit 0
  fi
done

STATE="$COORD_DIR/sessions.json"
[ ! -f "$STATE" ] && exit 0

# Lockdown gate. lockdown.sh's emit_deny produces the same
# permissionDecision JSON shape Codex respects on PreToolUse.
if coord_lockdown_check && coord_lockdown_emit_deny "PreToolUse"; then
  exit 0
fi

# === Parse: extract patch text from tool_input.input or .command[-1] =======

TOOL_NAME=$(coord_cx_extract_tool_name "$INPUT" 2>/dev/null || printf '')
if [ "$TOOL_NAME" != "apply_patch" ]; then
  # Defensive: this hook should only fire for ^apply_patch$ matcher.
  exit 0
fi

PATCH_TEXT=$(printf '%s' "$INPUT" | jq -r '
  .tool_input
  | (.input // .command[-1] // "")
' 2>/dev/null || printf '')

if [ -z "$PATCH_TEXT" ]; then
  warn_stderr 'apply_patch tool_input missing patch text; allowing uncoordinated'
  exit 0
fi

# Path collection — encounter order, then deterministic sort/unique.
PATHS_RAW=$(coord_cx_apply_patch_paths "$PATCH_TEXT" 2>/dev/null || printf '')
if [ -z "$PATHS_RAW" ]; then
  warn_stderr 'apply_patch parser returned no paths; allowing uncoordinated'
  exit 0
fi
PATHS_SORTED=$(printf '%s\n' "$PATHS_RAW" | LC_ALL=C sort -u)

# Operations TSV: op\tpath\tmove_to per record.
OPS_TSV=$(coord_cx_apply_patch_operations "$PATCH_TEXT" 2>/dev/null || printf '')

# Build paths_json for the consolidated jq filter.
PATHS_JSON=$(printf '%s' "$PATHS_SORTED" | jq -Rsc 'split("\n") | map(select(length > 0))')
TOTAL_PATHS=$(printf '%s' "$PATHS_JSON" | jq 'length' 2>/dev/null || printf '0')

# WRITE event for audit (records intent regardless of branch).
PATHS_COMMA=$(printf '%s' "$PATHS_SORTED" | tr '\n' ',' | sed 's/,$//')
coord_log_event kind=WRITE tool=apply_patch file="$PATHS_COMMA" \
  source=pre_tool_use_apply_patch || true

NOW=$(coord_now_iso8601)

# === Phase A: read-only lock classification ================================

BLOCKED_TSV=""    # "<path>\t<holder>\t<acquired>\t<refreshed>"
SELF_HELD=""      # newline-separated paths
NEW_ACQUIRE=""    # newline-separated paths

OLD_IFS="$IFS"
IFS='
'
set -- $PATHS_SORTED
IFS="$OLD_IFS"
for p in "$@"; do
  [ -z "$p" ] && continue
  ROW=$(jq -r --arg f "$p" '
    (.locks[$f] // {}) as $L
    | [($L.session // ""), ($L.acquired_at // ""), ($L.last_refresh_at // "")]
    | @tsv
  ' "$STATE" 2>/dev/null || printf '\t\t')
  HOLDER=$(printf '%s' "$ROW" | awk -F'\t' '{print $1}')
  ACQ=$(printf '%s' "$ROW" | awk -F'\t' '{print $2}')
  REF=$(printf '%s' "$ROW" | awk -F'\t' '{print $3}')
  if [ -z "$HOLDER" ]; then
    NEW_ACQUIRE="${NEW_ACQUIRE:+$NEW_ACQUIRE$'\n'}$p"
  elif [ "$HOLDER" = "$SESSION_ID" ]; then
    SELF_HELD="${SELF_HELD:+$SELF_HELD$'\n'}$p"
  else
    BLOCKED_TSV="${BLOCKED_TSV:+$BLOCKED_TSV$'\n'}${p}"$'\t'"${HOLDER}"$'\t'"${ACQ}"$'\t'"${REF}"
  fi
done

# === Phase A decision: any peer-held → deny ALL ============================

if [ -n "$BLOCKED_TSV" ]; then
  BLOCKED_COUNT=$(printf '%s' "$BLOCKED_TSV" | grep -c '' 2>/dev/null || printf '0')
  case "$BLOCKED_COUNT" in ''|*[!0-9]*) BLOCKED_COUNT=0 ;; esac

  if [ "$BLOCKED_COUNT" = "1" ]; then
    BPATH=$(printf '%s' "$BLOCKED_TSV" | head -n 1 | awk -F'\t' '{print $1}')
    BHOLDER=$(printf '%s' "$BLOCKED_TSV" | head -n 1 | awk -F'\t' '{print $2}')
    BACQ=$(printf '%s' "$BLOCKED_TSV" | head -n 1 | awk -F'\t' '{print $3}')
    BREF=$(printf '%s' "$BLOCKED_TSV" | head -n 1 | awk -F'\t' '{print $4}')
    HOLDER_SHORT="${BHOLDER:0:8}"
    ACQ_AGE=$(coord_cx_human_age "$BACQ")
    REF_AGE=$(coord_cx_human_age "$BREF")
    REASON=$(build_single_file_deny "$HOLDER_SHORT" "$ACQ_AGE" "$REF_AGE" "$BPATH")
    coord_log_event kind=LOCK_DENIED tool=apply_patch file="$BPATH" \
      reason_kind=peer_held holder="$BHOLDER" acquired_at="$BACQ" || true
    emit_deny "$REASON"
    exit 0
  fi

  # Multi-file deny banner: enumerate all blocked.
  LINES=""
  IFS='
'
  set -- $BLOCKED_TSV
  IFS="$OLD_IFS"
  for entry in "$@"; do
    [ -z "$entry" ] && continue
    BPATH=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
    BHOLDER=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
    BACQ=$(printf '%s' "$entry" | awk -F'\t' '{print $3}')
    BREF=$(printf '%s' "$entry" | awk -F'\t' '{print $4}')
    HOLDER_SHORT="${BHOLDER:0:8}"
    ACQ_AGE=$(coord_cx_human_age "$BACQ")
    REF_AGE=$(coord_cx_human_age "$BREF")
    LINES="${LINES:+$LINES$'\n'}  - ${BPATH} by session ${HOLDER_SHORT}... since ${ACQ_AGE} (~${REF_AGE})"
    coord_log_event kind=LOCK_DENIED tool=apply_patch file="$BPATH" \
      reason_kind=peer_held holder="$BHOLDER" acquired_at="$BACQ" || true
  done
  REASON=$(build_multi_file_deny "$TOTAL_PATHS" "$BLOCKED_COUNT" "$LINES")
  emit_deny "$REASON"
  exit 0
fi

# === Phase B: drift gate (per-file pre_image search) =======================

DRIFT_LINES=""
DRIFT_COUNT=0

# Build per-path operation map from OPS_TSV.
# Lines have format: op\tpath\tmove_to.  We iterate to classify per path.
IFS='
'
set -- $OPS_TSV
IFS="$OLD_IFS"
for entry in "$@"; do
  [ -z "$entry" ] && continue
  OP=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
  OP_PATH=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
  MOVE_TO=$(printf '%s' "$entry" | awk -F'\t' '{print $3}')
  case "$OP" in
    add)
      if [ -e "$OP_PATH" ]; then
        DRIFT_LINES="${DRIFT_LINES:+$DRIFT_LINES$'\n'}  - ${OP_PATH}: Add File target already exists"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        coord_log_event kind=DRIFT_DETECTED tool=apply_patch file="$OP_PATH" \
          drift_kind=add_target_exists || true
      fi
      ;;
    delete)
      if [ ! -e "$OP_PATH" ]; then
        DRIFT_LINES="${DRIFT_LINES:+$DRIFT_LINES$'\n'}  - ${OP_PATH}: Delete File target does not exist"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        coord_log_event kind=DRIFT_DETECTED tool=apply_patch file="$OP_PATH" \
          drift_kind=delete_target_missing || true
      fi
      ;;
    update)
      if ! _coord_cx_drift_check_update "$PATCH_TEXT" "$OP_PATH"; then
        DRIFT_LINES="${DRIFT_LINES:+$DRIFT_LINES$'\n'}  - ${OP_PATH}: ${_CX_DRIFT_REASON}"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        coord_log_event kind=DRIFT_DETECTED tool=apply_patch file="$OP_PATH" \
          drift_kind=update_pre_image_mismatch reason="$_CX_DRIFT_REASON" || true
      fi
      # Move op also requires destination NOT to exist (Add semantics).
      if [ -n "$MOVE_TO" ] && [ -e "$MOVE_TO" ]; then
        DRIFT_LINES="${DRIFT_LINES:+$DRIFT_LINES$'\n'}  - ${MOVE_TO}: Move destination already exists"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        coord_log_event kind=DRIFT_DETECTED tool=apply_patch file="$MOVE_TO" \
          drift_kind=move_destination_exists || true
      fi
      ;;
  esac
done

if [ "$DRIFT_COUNT" -gt 0 ]; then
  REASON=$(build_drift_deny "$DRIFT_LINES")
  emit_deny "$REASON"
  exit 0
fi

# === Phase C: consolidated validate-or-abort filter (F-D4-01) ==============
# Single atomic_edit acquires unheld + refreshes self-held + aborts on
# peer-held seen mid-flight (race). The filter is one transaction.

if ! coord_atomic_edit "$STATE" '
  reduce ($paths_json[]) as $p (.;
    if (.locks[$p].session // "") == "" then
      .locks[$p] = {
        session:                       $sid,
        acquired_at:                   $now,
        last_refresh_at:               $now,
        tasks:                         [],
        latest_validator_verdict_ts:   null
      }
    elif (.locks[$p].session // "") == $sid then
      .locks[$p].last_refresh_at = $now
    else
      error("race_loser:" + $p)
    end
  )
  | .sessions[$sid].last_activity_at = $now
  ' \
  --argjson paths_json "$PATHS_JSON" \
  --arg sid "$SESSION_ID" \
  --arg now "$NOW"
then
  # Filter aborted — re-read state, identify the race-winner, emit deny.
  RACE_LINES=""
  RACE_COUNT=0
  IFS='
'
  set -- $PATHS_SORTED
  IFS="$OLD_IFS"
  for p in "$@"; do
    [ -z "$p" ] && continue
    ROW=$(jq -r --arg f "$p" '
      (.locks[$f] // {}) as $L
      | [($L.session // ""), ($L.acquired_at // ""), ($L.last_refresh_at // "")]
      | @tsv
    ' "$STATE" 2>/dev/null || printf '\t\t')
    HOLDER=$(printf '%s' "$ROW" | awk -F'\t' '{print $1}')
    ACQ=$(printf '%s' "$ROW" | awk -F'\t' '{print $2}')
    REF=$(printf '%s' "$ROW" | awk -F'\t' '{print $3}')
    if [ -n "$HOLDER" ] && [ "$HOLDER" != "$SESSION_ID" ]; then
      HOLDER_SHORT="${HOLDER:0:8}"
      ACQ_AGE=$(coord_cx_human_age "$ACQ")
      REF_AGE=$(coord_cx_human_age "$REF")
      RACE_LINES="${RACE_LINES:+$RACE_LINES$'\n'}  - ${p} by session ${HOLDER_SHORT}... since ${ACQ_AGE} (~${REF_AGE})"
      RACE_COUNT=$((RACE_COUNT + 1))
      coord_log_event kind=LOCK_DENIED tool=apply_patch file="$p" \
        reason_kind=race_loss holder="$HOLDER" acquired_at="$ACQ" || true
    fi
  done
  if [ "$RACE_COUNT" -gt 0 ]; then
    REASON=$(build_multi_file_deny "$TOTAL_PATHS" "$RACE_COUNT" "$RACE_LINES")
    REASON="${REASON}"$'\n'"(race-acquired by holder(s) moments ago — retry should now succeed.)"
    emit_deny "$REASON"
  else
    # atomic_edit failed for non-race reasons (jq syntax bug, flock timeout).
    # Fail open per CLAUDE.md §A.5/§B.9.3 — log + allow uncoordinated.
    warn_stderr 'atomic_edit failed during apply_patch acquire; allowing uncoordinated'
    coord_log_event kind=ERROR source=pre_tool_use_apply_patch \
      reason=mass_acquire_failed || true
  fi
  exit 0
fi

# === Allow path: per-file LOCK_ACQUIRED / LOCK_REFRESH events ==============

if [ -n "$NEW_ACQUIRE" ]; then
  IFS='
'
  set -- $NEW_ACQUIRE
  IFS="$OLD_IFS"
  for p in "$@"; do
    [ -z "$p" ] && continue
    coord_log_event kind=LOCK_ACQUIRED tool=apply_patch file="$p" \
      acquired_at="$NOW" source=pre_tool_use_apply_patch || true
  done
fi
if [ -n "$SELF_HELD" ]; then
  IFS='
'
  set -- $SELF_HELD
  IFS="$OLD_IFS"
  for p in "$@"; do
    [ -z "$p" ] && continue
    coord_log_event kind=LOCK_REFRESH tool=apply_patch file="$p" \
      refreshed_at="$NOW" source=pre_tool_use_apply_patch || true
  done
fi

# Allow path: empty stdout. NEVER emit additionalContext (Codex rejects).
exit 0

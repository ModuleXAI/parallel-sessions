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
# Phase 4 / T4.06 pipeline libs.
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/read_snapshots.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/validator_cache.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/validator_prefilter.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/validator_spawn.sh"
# Phase 7 / T7.05 — mode-aware spawn dispatch + cost-guard
# interlock activation. Optional sources (graceful degrade if
# absent) per CLAUDE.md §A.5 fail-open posture.
[ -f "$CORE_LIB_DIR/spawn_helper.sh" ] && . "$CORE_LIB_DIR/spawn_helper.sh"
[ -f "$CORE_LIB_DIR/cost_guards.sh" ] && . "$CORE_LIB_DIR/cost_guards.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/mediator_pending.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/mediator_spawn.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/verdict_apply.sh"

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

# ---------------------------------------------------------------------------
# Phase 4 / T4.06 — 3-stage validator pipeline helpers
# ---------------------------------------------------------------------------
# Per PR-PHASE4-01..05 + Concern B disposition: when stale-read is
# detected on a file, run the pipeline cache → pre-filter → validator
# agent → (CRITICAL only) inline Mediator. Each stage is fail-soft;
# any unexpected failure falls back to the Phase 1 warning (emit
# banner + proceed). Pipefail-safe: every $() and piped jq has an
# explicit `|| <fallback>` to avoid set -e/pipefail aborts mid-flow
# (CLAUDE.md §A.13 lesson #2).

# _coord_phase4_critical_emit_pending <file> <rhash> <chash> <verdict_file>
#   Writes a kind=critical_drift entry to pending.jsonl with payload
#   per PR-PHASE4-03. Returns the entry's ts on stdout (rc=0) or
#   empty + rc=1 on failure. Generates ts locally so caller can pass
#   it to coord_mediator_spawn (Mediator's prompt filters by ts).
_coord_phase4_critical_emit_pending() {
  local file="$1" rhash="$2" chash="$3" verdict_file="$4"
  [ -z "${COORD_DIR:-}" ] && return 1
  local v_reasoning v_summary v_session
  v_reasoning=$(jq -r '.reasoning // ""' "$verdict_file" 2>/dev/null) || v_reasoning=""
  v_summary=$(jq -r '.diff_summary // ""' "$verdict_file" 2>/dev/null) || v_summary=""
  v_session=$(jq -r '.validator_session_id // ""' "$verdict_file" 2>/dev/null) || v_session=""

  local ts
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    ts=$(coord_now_iso8601)
  else
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  local entry
  entry=$(jq -nc \
    --arg ts "$ts" --arg sid "${SESSION_ID:-unknown}" --arg file "$file" \
    --arg vr "$v_reasoning" --arg vs "$v_summary" \
    --arg yh "$rhash" --arg ch "$chash" --arg vsid "$v_session" \
    '{
      ts: $ts,
      kind: "critical_drift",
      session: $sid,
      source: "validator",
      payload: {
        file: $file,
        validator_verdict: "CRITICAL",
        validator_reasoning: $vr,
        your_read_hash: $yh,
        current_hash: $ch,
        diff_summary: $vs,
        validator_session_id: $vsid
      }
    }' 2>/dev/null) || return 1
  [ -z "$entry" ] && return 1

  local mdir="$COORD_DIR/mediator"
  local jsonl="$mdir/pending.jsonl"
  local lockfile="$mdir/pending.lock"
  mkdir -p "$mdir" 2>/dev/null
  : >>"$lockfile" 2>/dev/null || true
  local rc=0
  (
    flock -x -w 5 9 || exit 1
    printf '%s\n' "$entry" >>"$jsonl" 2>/dev/null || exit 1
  ) 9>"$lockfile" || rc=$?
  if [ "$rc" -ne 0 ]; then return 1; fi
  printf '%s\n' "$ts"
  return 0
}

# _coord_phase4_advance_verdict_pointer <verdict_path>
#   Advances the per-session POINTER_FILE so pre_tool_use_any.sh's
#   verdict consumer skips this verdict on the next tool call
#   (we already applied + banner-emitted it inline). Idempotent.
_coord_phase4_advance_verdict_pointer() {
  local vpath="$1"
  [ -z "$vpath" ] && return 0
  [ -z "${COORD_DIR:-}" ] && return 0
  [ -z "${SESSION_ID:-}" ] && return 0
  local vname
  vname=$(basename "$vpath" .json)
  local pointer_file="$COORD_DIR/sessions/${SESSION_ID}.last_consumed_verdict"
  printf '%s\n' "$vname" >"$pointer_file" 2>/dev/null || true
  return 0
}

# _coord_phase4_handle_critical <file> <rhash> <chash> <verdict_file>
#   On Validator CRITICAL: writes critical_drift pending entry,
#   spawns Mediator inline (synchronous per PR-PHASE4-02), applies
#   verdict's actions[], advances pointer, returns banner text on
#   stdout. Returns rc=0 on success (banner printed), rc=1 on failure
#   (caller falls back to Phase 1 warning).
_coord_phase4_handle_critical() {
  local file="$1" rhash="$2" chash="$3" verdict_file="$4"
  local diff_summary
  diff_summary=$(jq -r '.diff_summary // ""' "$verdict_file" 2>/dev/null) || diff_summary=""

  coord_log_event kind=VALIDATOR_VERDICT_CRITICAL \
    file="$file" verdict_path="$verdict_file" diff_summary="$diff_summary" || true

  local pending_ts
  pending_ts=$(_coord_phase4_critical_emit_pending "$file" "$rhash" "$chash" "$verdict_file") \
    || pending_ts=""
  if [ -z "$pending_ts" ]; then
    coord_log_event kind=VALIDATOR_PIPELINE_FAILED file="$file" \
      reason=pending_emit_failed || true
    return 1
  fi

  coord_log_event kind=VALIDATOR_VERDICT_CRITICAL_ESCALATED_TO_MEDIATOR \
    file="$file" pending_ts="$pending_ts" || true

  local mediator_verdict
  mediator_verdict=$(coord_mediator_spawn "$pending_ts" 1 2>/dev/null) || mediator_verdict=""

  if [ -z "$mediator_verdict" ] || [ ! -f "$mediator_verdict" ]; then
    coord_log_event kind=VALIDATOR_PIPELINE_FAILED file="$file" \
      reason=mediator_spawn_failed pending_ts="$pending_ts" || true
    return 1
  fi

  # Apply Mediator verdict's actions (idempotent via verdict_apply.sh).
  local actions_json
  actions_json=$(jq -c '.actions // []' "$mediator_verdict" 2>/dev/null) || actions_json="[]"
  if [ "$actions_json" != "[]" ] && [ "$actions_json" != "null" ] \
     && command -v coord_verdict_apply_actions >/dev/null 2>&1; then
    coord_verdict_apply_actions "$actions_json" 2>/dev/null || true
  fi

  # Advance per-session pointer so this verdict is not re-banner-ed.
  _coord_phase4_advance_verdict_pointer "$mediator_verdict"

  coord_log_event kind=MEDIATOR_INLINE_VERDICT_APPLIED \
    file="$file" verdict_path="$mediator_verdict" pending_ts="$pending_ts" || true

  local mediator_msg mediator_action
  mediator_msg=$(jq -r '.message_to_caller // ""' "$mediator_verdict" 2>/dev/null) || mediator_msg=""
  mediator_action=$(jq -r '.action_type // "?"' "$mediator_verdict" 2>/dev/null) || mediator_action="?"

  # Compose banner: "Critical drift on FILE -> Mediator: ACTION; <message_to_caller>".
  printf 'Critical drift on %s -> Mediator: %s; %s' \
    "$file" "$mediator_action" "$mediator_msg"
  return 0
}

# _coord_phase4_run_pipeline <file> <stored_hash> <current_hash>
#   Returns banner text on stdout (may be empty for SAFE) and rc=0
#   on pipeline success; rc=1 on pipeline failure (caller falls back
#   to Phase 1 warning text).
_coord_phase4_run_pipeline() {
  local file="$1" rhash="$2" chash="$3"

  # T5.04 / PR-PHASE5-02 §5: per-call output for verdict_ts so the
  # caller can populate locks[<file>].latest_validator_verdict_ts.
  # Reset to empty at every entry; only stage-3 (validator agent
  # spawn) and the CRITICAL inline path produce a fresh verdict
  # file — stages 1 (cache hit) + 2 (pre-filter SAFE) leave it empty.
  _COORD_PHASE4_LAST_VERDICT_TS=""

  coord_log_event kind=VALIDATOR_PIPELINE_STARTED \
    file="$file" read_hash="$rhash" current_hash="$chash" || true

  # Stage 1: cache lookup.
  local cache_hit
  cache_hit=$(coord_validator_cache_lookup "$file" "$rhash" "$chash" 2>/dev/null) \
    || cache_hit=""
  if [ -n "$cache_hit" ]; then
    local cached_verdict cached_summary
    cached_verdict=$(printf '%s' "$cache_hit" | awk -F'\t' '{print $1}')
    cached_summary=$(printf '%s' "$cache_hit" | awk -F'\t' '{print $3}')
    case "$cached_verdict" in
      SAFE)
        # Silent — no banner contribution.
        return 0
        ;;
      MINOR)
        printf 'Drift on %s: %s. Validator classified as MINOR. Proceeding.' \
          "$file" "$cached_summary"
        return 0
        ;;
      *)
        # Defensive: cache should never store CRITICAL. Treat as MISS.
        ;;
    esac
  fi

  # Stage 2: pre-filter.
  local prefilter_out
  prefilter_out=$(coord_validator_prefilter "${SESSION_ID:-unknown}" "$file" "$rhash" "$chash" 2>/dev/null) \
    || prefilter_out=""
  case "$prefilter_out" in
    safe:*)
      # Cache the SAFE verdict + return silent.
      coord_validator_cache_write "$file" "$rhash" "$chash" "SAFE" "prefilter" 2>/dev/null || true
      return 0
      ;;
    escalate:*|"")
      # Fall through to validator agent spawn.
      ;;
  esac

  # Stage 3: validator agent spawn.
  local verdict_path
  verdict_path=$(coord_validator_spawn "${SESSION_ID:-unknown}" "$file" "$rhash" "$chash" 2>/dev/null) \
    || verdict_path=""
  if [ -z "$verdict_path" ] || [ ! -f "$verdict_path" ]; then
    # Phase 7 / T7.05: graceful degrade on cost-guard rate-limit.
    # The validator_spawn helper sets _COORD_VALIDATOR_LAST_FAIL_REASON
    # to "rate_limited" only on the cost-guard rate-limit path;
    # any other failure leaves the sentinel empty.  Rate-limited
    # → conservative MINOR classification with banner suffix
    # (PR-PHASE7-03 §"Hard block vs graceful degrade"); other
    # failures fall through to Phase 1 fallback (existing
    # contract).
    if [ "${_COORD_VALIDATOR_LAST_FAIL_REASON:-}" = "rate_limited" ]; then
      coord_log_event kind=VALIDATOR_PIPELINE_DEGRADED file="$file" \
        reason=rate_limited classified_as=MINOR || true
      printf 'Drift on %s: classified as MINOR. Proceeding. [validator rate-limited]' \
        "$file"
      return 0
    fi
    coord_log_event kind=VALIDATOR_PIPELINE_FAILED file="$file" \
      reason=validator_spawn_failed || true
    return 1
  fi
  # T5.04: capture verdict_ts for caller to bake into the lock record.
  _COORD_PHASE4_LAST_VERDICT_TS=$(basename "$verdict_path" .json 2>/dev/null) \
    || _COORD_PHASE4_LAST_VERDICT_TS=""

  local agent_verdict agent_summary
  agent_verdict=$(jq -r '.verdict // ""' "$verdict_path" 2>/dev/null) || agent_verdict=""
  agent_summary=$(jq -r '.diff_summary // ""' "$verdict_path" 2>/dev/null) || agent_summary=""

  case "$agent_verdict" in
    SAFE)
      coord_validator_cache_write "$file" "$rhash" "$chash" "SAFE" "validator_agent" 2>/dev/null || true
      coord_log_event kind=VALIDATOR_VERDICT_SAFE file="$file" verdict_path="$verdict_path" || true
      return 0
      ;;
    MINOR)
      coord_validator_cache_write "$file" "$rhash" "$chash" "MINOR" "validator_agent" "$agent_summary" 2>/dev/null || true
      coord_log_event kind=VALIDATOR_VERDICT_MINOR file="$file" verdict_path="$verdict_path" \
        diff_summary="$agent_summary" || true
      printf 'Drift on %s: %s. Validator classified as MINOR. Proceeding.' \
        "$file" "$agent_summary"
      return 0
      ;;
    CRITICAL)
      # Synchronous Mediator inline path. CRITICAL is NEVER cached.
      _coord_phase4_handle_critical "$file" "$rhash" "$chash" "$verdict_path"
      return $?
      ;;
    *)
      coord_log_event kind=VALIDATOR_PIPELINE_FAILED file="$file" \
        reason=unknown_verdict verdict="$agent_verdict" || true
      return 1
      ;;
  esac
}

# _coord_phase4_phase1_fallback <file> <reason>
#   Phase 1 warning text for a single drifted file (used when pipeline
#   fails or for non-classifiable drifts e.g. file deleted).
_coord_phase4_phase1_fallback() {
  local file="$1" reason="$2"
  printf 'Drift on %s (%s). Pipeline unavailable; consider re-reading before proceeding.' \
    "$file" "$reason"
}

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

# Read task_delegation toggle from .coord/config.json. Default true
# when config is missing or field absent. Cand-14 awareness: jq's
# `// alt` triggers on null OR false (jq spec), so a literal `false`
# value would silently bypass the check via `// true`. Use explicit
# `if has("task_delegation") then .task_delegation else true end`
# pattern to distinguish absent-key from present-and-false (mirrors
# coord task-open T6.03 toggle handling at src/core/bin/coord).
_coord_pwh_task_delegation_enabled() {
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

# Build the §B.2 three-options deny reason — Phase 6 T6.09 production
# wording per PR-PHASE6-05 §6 (toggle TRUE + toggle FALSE variants).
# Inputs:
#   $1 holder_short  — first 8 chars of holder session_id
#   $2 acquired_age  — humane "X min ago" string
#   $3 refresh_age   — humane "X sec ago" string
#   $4 target        — the path being denied
#
# Toggle TRUE banner: enumerates options (a) coord task-open + (b)
# coord self-delegate + (c) coord wait (full production CLI syntax
# from T6.03 + T6.04 + T5.x deliverables).
# Toggle FALSE banner (config.json task_delegation: false): omits
# option (a) entirely; states "task delegation is disabled in this
# repo" + offers only (b) + (c).
#
# Decision 6 binding: option (a) is the gated capability; option (b)
# coord self-delegate + option (c) coord wait remain available
# regardless of toggle (verified by T6.04 Category 4 toggle-false-
# still-works test).
build_deny_reason() {
  local holder_short="$1"
  local acquired_age="$2"
  local refresh_age="$3"
  local target="$4"
  local toggle
  toggle=$(_coord_pwh_task_delegation_enabled)

  if [ "$toggle" = "true" ]; then
    # Toggle TRUE — three-options banner.
    printf 'File `%s` is locked by session `%s...` since %s (~%s). Options:\n(a) Delegate a SIMPLE/MODERATE task: `Bash: coord task-open --file %s --complexity SIMPLE --anchor '"'"'{"search":"\xE2\x80\xA6","window_lines":"\xE2\x80\xA6"}'"'"' --instruction '"'"'\xE2\x80\xA6'"'"' [--rationale '"'"'\xE2\x80\xA6'"'"']`.\n(b) Self-delegate (do other work, return later): `Bash: coord self-delegate --file %s --instruction '"'"'\xE2\x80\xA6'"'"'`.\n(c) Passively wait: `Bash: coord wait %s --timeout 570` (blocks until unlocked or timeout).\nPick (a) for small self-contained edits; (b) if you have other productive work; (c) only if the change is too complex to delegate AND you have no other work.' \
      "$target" "$holder_short" "$acquired_age" "$refresh_age" \
      "$target" "$target" "$target"
  else
    # Toggle FALSE — option (a) hidden; (b)+(c) only.
    printf 'File `%s` is locked by session `%s...` since %s (~%s). Options (note: task delegation is disabled in this repo):\n(b) Self-delegate (do other work, return later): `Bash: coord self-delegate --file %s --instruction '"'"'\xE2\x80\xA6'"'"'`.\n(c) Passively wait: `Bash: coord wait %s --timeout 570` (blocks until unlocked or timeout).\nPick (b) if you have other productive work; (c) only if the change is too complex AND you have no other work.' \
      "$target" "$holder_short" "$acquired_age" "$refresh_age" \
      "$target" "$target"
  fi
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

# --- (3) Stale-read pipeline (Phase 4 / T4.06) ----------------------------
# For each drifted file: cache → pre-filter → validator agent →
# (CRITICAL only) inline Mediator. Banner accumulates per-file outcomes.
# Non-classifiable drifts (file deleted, hash failed, SKIPPED_LARGE)
# fall back to a Phase 1 warning line. Pipeline failures
# (validator/mediator spawn fail) emit Phase 1 warning lines and
# proceed — fail-open per CLAUDE.md §A.5/§A.6.
#
# Phase 4 invariant: this block emits NO permissionDecision: deny.
# CRITICAL → Mediator → lockdown (when scope is system-wide) routes
# through the existing lockdown gate at line 188. Phase 3 two-location
# deny invariant preserved.
ENTRIES_TSV=$(jq -r --arg sid "$SESSION_ID" '
  (.read_sets[$sid].reads // [])
  | map(select((.is_latest // false) == true and ((.superseded_by_head_change // false) == false)))
  | .[]
  | [.path, .hash] | @tsv
' "$STATE" 2>/dev/null || printf '')

STALE_BANNER=""
BANNER_LINES=""
# T5.04 / PR-PHASE5-02 §5: capture verdict_ts produced by the
# pipeline IF $TARGET drifted and stage 3 ran. Empty when $TARGET
# was unchanged or short-circuited at cache/pre-filter; populated
# into locks[$TARGET].latest_validator_verdict_ts at lock-acquire.
TARGET_VERDICT_TS=""
if [ -n "$ENTRIES_TSV" ]; then
  OLD_IFS="$IFS"
  IFS='
'
  set -- $ENTRIES_TSV
  IFS="$OLD_IFS"
  for entry in "$@"; do
    path=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
    stored=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
    [ -z "$path" ] && continue

    # Compute current state + classify drift kind.
    drift_kind=""           # one of: deleted | skipped_large | hash_failed | modified | unchanged
    current=""
    if [ ! -e "$path" ]; then
      drift_kind="deleted"
    elif [ "$stored" = "SKIPPED_LARGE" ]; then
      drift_kind="skipped_large"
    else
      current=$(coord_hash_file "$path" 2>/dev/null || printf '')
      if [ -z "$current" ]; then
        drift_kind="hash_failed"
      elif [ "$current" != "$stored" ]; then
        drift_kind="modified"
      else
        drift_kind="unchanged"
      fi
    fi

    case "$drift_kind" in
      unchanged|"")
        # No drift; nothing to classify.
        continue
        ;;
      modified)
        # Real drift — run the pipeline. Use `if` to capture rc
        # reliably under set -e (the `var=$(...) || alt; rc=$?`
        # pattern always reads rc=0 from the `||` branch in
        # bash 3.2; CLAUDE.md §A.13 lesson #2).
        line=""
        pipeline_ok=1
        if line=$(_coord_phase4_run_pipeline "$path" "$stored" "$current"); then
          :
        else
          pipeline_ok=0
          line=$(_coord_phase4_phase1_fallback "$path" "modified since read; pipeline failed")
        fi
        # T5.04: capture verdict_ts when this iteration was for
        # $TARGET and stage 3 produced a fresh verdict.
        if [ "$path" = "$TARGET" ] && [ -n "${_COORD_PHASE4_LAST_VERDICT_TS:-}" ]; then
          TARGET_VERDICT_TS="$_COORD_PHASE4_LAST_VERDICT_TS"
        fi
        # One COMPLETED event per pipeline invocation regardless of
        # outcome (SAFE silent / MINOR banner / CRITICAL handled /
        # failure fallback). Carries the per-file disposition.
        coord_log_event kind=VALIDATOR_PIPELINE_COMPLETED \
          tool="$TOOL_NAME" file="$path" \
          pipeline_ok="$pipeline_ok" had_banner=$([ -n "$line" ] && printf 1 || printf 0) || true
        if [ -n "$line" ]; then
          BANNER_LINES="$BANNER_LINES- $line"$'\n'
        fi
        ;;
      deleted)
        line=$(_coord_phase4_phase1_fallback "$path" "file deleted since read")
        BANNER_LINES="$BANNER_LINES- $line"$'\n'
        coord_log_event kind=STALE_READ_WARNED tool="$TOOL_NAME" \
          file="$path" stale_kind=deleted || true
        ;;
      skipped_large)
        line=$(_coord_phase4_phase1_fallback "$path" "large-file read; pre-filter ESCALATEs unconditionally and validator has no snapshot")
        BANNER_LINES="$BANNER_LINES- $line"$'\n'
        coord_log_event kind=STALE_READ_WARNED tool="$TOOL_NAME" \
          file="$path" stale_kind=skipped_large || true
        ;;
      hash_failed)
        line=$(_coord_phase4_phase1_fallback "$path" "hash failed; file unreadable")
        BANNER_LINES="$BANNER_LINES- $line"$'\n'
        coord_log_event kind=STALE_READ_WARNED tool="$TOOL_NAME" \
          file="$path" stale_kind=hash_failed || true
        ;;
    esac
  done

  if [ -n "$BANNER_LINES" ]; then
    STALE_BANNER="Coord drift report ($TOOL_NAME on $TARGET):"$'\n'"${BANNER_LINES%$'\n'}"
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
# T5.04 / PR-PHASE5-02 §5: bake latest_validator_verdict_ts into the
# lock record when this hook turn produced a fresh verdict for the
# target file. JSON null when stages 1+2 short-circuited or no drift
# was detected (the common case).
if ! coord_atomic_edit "$STATE" \
      '.locks[$f] = {
          session: $sid,
          acquired_at: $now,
          last_refresh_at: $now,
          tasks: [],
          latest_validator_verdict_ts: ($vts | select(. != "") // null)
        }
       | .sessions[$sid].last_activity_at = $now' \
      --arg f "$TARGET" --arg sid "$SESSION_ID" --arg now "$NOW" \
      --arg vts "$TARGET_VERDICT_TS"; then
  # Atomic edit failed — fail-open per CLAUDE.md §A.5 / §B.9.3. Log + allow.
  warn_stderr "atomic_edit failed during lock acquire; allowing write uncoordinated"
  [ -n "$STALE_BANNER" ] && emit_additional_context "$STALE_BANNER"
  exit 0
fi
coord_log_event kind=LOCK_ACQUIRED tool="$TOOL_NAME" file="$TARGET" acquired_at="$NOW"
[ -n "$STALE_BANNER" ] && emit_additional_context "$STALE_BANNER"

# Phase 4 / T4.06: pipeline integration is ABOVE this point (in the
# stale-read walk at lines 195-241 area). The historical PHASE-4
# UPGRADE POINT comment at this site has been removed because the
# integration is no longer post-acquire — it is per-file inside the
# stale-read walk per PR-PHASE4-01 ambiguity disposition #1.

exit 0

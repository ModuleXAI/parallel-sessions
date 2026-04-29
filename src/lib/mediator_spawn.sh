#!/usr/bin/env bash
# mediator_spawn.sh — Phase 3 / T3.07 Mediator agent spawn helper
# (PR-PHASE3-01 implementation per T3.06 POC findings + user-resolved
# Mediator prompt design checkpoint).
#
# Spawns a `claude -p` subprocess that acts as the Mediator. Builds
# the 3-section prompt (Identity / System Constraints / Incident
# Context), packages a context bundle (pending entry + sessions
# snapshot + events tail + verdict history), invokes claude with the
# subscription-mode flag set (no-bare + CLAUDE_COORD=0 spawn env per
# T3.07 user direction — user does NOT have ANTHROPIC_API_KEY), and
# captures stdout JSON.
#
# Per T3.06 POC:
#   - claude -p exits 0 on completion regardless of is_error; ALWAYS
#     parse JSON for actual outcome, never rely on shell exit code.
#   - Spawned process gets a NEW session_id (NOT shared with parent).
#   - --bare path is documented in MEDIATOR_REFERENCE.md as future
#     enhancement; T3.07 implements ONLY no-bare (subscription mode).
#   - Wall-clock budget: 120s default (Mediator typically 15-30s
#     analysis + 11s claude startup; bound at 120s for slow-API days).
#
# Public API:
#   coord_mediator_spawn <pending_entry_id> [<depth>] [<prior_verdict_path>]
#       Returns 0 on completion (verdict written), 1 on failure or
#       refusal (recursion guard, critical bypass, dependencies
#       missing). Stdout: path to verdict file on success; empty on
#       failure.
#
# Environment passed to claude -p:
#   CLAUDE_COORD=0                — disable coord hooks for spawned process
#   CLAUDE_CODE_MEDIATOR=<depth>  — recursion guard marker
#   COORD_DIR                     — inherited so Mediator can read state
#   PATH                          — inherited
#
# Recursion guard: if CLAUDE_CODE_MEDIATOR is already set in the
# CALLER's env, the spawn helper checks the existing depth value:
#   - depth=1 caller invoking spawn → depth=2 (peer review)
#   - depth=2 caller invoking spawn → REFUSE (max depth reached;
#     user-escalation territory)

# Tunables (env-overridable; install.sh / coord health surface formal
# config.json entries when T3.10 / signoff CLAUDE.md updates land).
: "${COORD_MEDIATOR_MODEL:=claude-haiku-4-5-20251001}"
: "${COORD_MEDIATOR_BUDGET_USD:=0.50}"
: "${COORD_MEDIATOR_TIMEOUT_SEC:=120}"
: "${COORD_MEDIATOR_EVENTS_TAIL_LINES:=50}"
: "${COORD_MEDIATOR_VERDICT_HISTORY_LINES:=10}"

# Internal helpers ---------------------------------------------------------

_coord_mediator_warn() {
  printf 'coord mediator_spawn: %s\n' "$*" >&2
}

_coord_mediator_now_iso8601() {
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    coord_now_iso8601
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# _coord_mediator_build_identity_section
#   Section 1 of the prompt — fixed text per user-resolved checkpoint.
_coord_mediator_build_identity_section() {
  cat <<'EOF'
# Section 1: Identity

You are a Mediator agent in a Claude Code coordination system. Your
role is to resolve anomalies that individual sessions cannot resolve
themselves. You have authority to: (1) advise the caller, (2) make
surgical fixes to coord state, (3) trigger system-wide lockdown. You
exercise this authority carefully — wrong decisions cause harm. You
are not a debugger or a general-purpose agent; you act on specific
incidents and write a structured verdict.
EOF
}

# _coord_mediator_build_constraints_section <reference_path>
#   Section 2 — short list (5 rules) + reference file pointer.
_coord_mediator_build_constraints_section() {
  local ref_path="$1"
  cat <<EOF
# Section 2: System Constraints

1. Deny tool calls only via lockdown — write
   .coord/mediator/lockdown.json. No other deny mechanism exists.

2. Use Bash and Read tools only. State mutations go through
   .coord/lib/atomic_write.sh helpers. NEVER use Edit, Write, or
   NotebookEdit.

3. You are not a tracked session. You do not acquire locks. You
   operate as a temporary observer/actor.

4. Write your verdict to .coord/mediator/verdict/<ts>.json.

5. If CLAUDE_CODE_MEDIATOR=2 in env, you are a peer reviewer. Do NOT
   spawn another Mediator.

For detailed mechanics (verdict schema, lockdown.json fields,
atomic_write helper signatures, archive paths, apply ordering rules),
read $ref_path when needed.
EOF
}

# _coord_mediator_build_context_section <pending_id> <prior_verdict_path>
#   Section 3 — embedded snapshot + live read allowed.
_coord_mediator_build_context_section() {
  local pending_id="$1"
  local prior_verdict_path="$2"

  local sessions_snapshot events_tail verdict_history pending_entry
  local state="$COORD_DIR/sessions.json"
  local events="$COORD_DIR/events.jsonl"
  local pending_jsonl="$COORD_DIR/mediator/pending.jsonl"
  local verdict_dir="$COORD_DIR/mediator/verdict"

  if [ -f "$state" ]; then
    sessions_snapshot=$(jq -c . "$state" 2>/dev/null || printf '{}')
  else
    sessions_snapshot="{}"
  fi

  if [ -f "$events" ]; then
    events_tail=$(tail -n "$COORD_MEDIATOR_EVENTS_TAIL_LINES" "$events" 2>/dev/null || printf '')
  else
    events_tail=""
  fi

  if [ -d "$verdict_dir" ]; then
    verdict_history=$(ls -1t "$verdict_dir"/*.json 2>/dev/null \
      | head -n "$COORD_MEDIATOR_VERDICT_HISTORY_LINES" \
      | while IFS= read -r vfile; do
          jq -c . "$vfile" 2>/dev/null
        done)
  else
    verdict_history=""
  fi

  if [ -f "$pending_jsonl" ] && [ -n "$pending_id" ]; then
    pending_entry=$(jq -c --arg ts "$pending_id" 'select(.ts == $ts)' "$pending_jsonl" 2>/dev/null \
      | head -1)
  fi

  local prior_verdict_block=""
  if [ -n "$prior_verdict_path" ] && [ -f "$prior_verdict_path" ]; then
    prior_verdict_block=$(printf '\n## Prior Mediator Verdict (you are reviewing this)\n```json\n%s\n```\n' \
      "$(jq -c . "$prior_verdict_path" 2>/dev/null)")
  fi

  cat <<EOF
# Section 3: Incident Context

## Pending entry that triggered this invocation
\`\`\`json
${pending_entry:-{}}
\`\`\`

## sessions.json snapshot at invocation time
\`\`\`json
${sessions_snapshot}
\`\`\`

## Last ${COORD_MEDIATOR_EVENTS_TAIL_LINES} events.jsonl entries
\`\`\`
${events_tail}
\`\`\`

## Last ${COORD_MEDIATOR_VERDICT_HISTORY_LINES} verdict files (most-recent first)
\`\`\`
${verdict_history}
\`\`\`
${prior_verdict_block}
## Action contract

Based on the above, choose:
- action_type ∈ {advice, surgical_fix, lockdown}
- severity ∈ {brief, extended} (only when action_type=surgical_fix)
- confidence ∈ {auto_apply, needs_review}

Provide reasoning. Specify actions list (release_lock / evict_session /
clear_read_set), message_to_caller, and message_to_others (lockdown
only). Then write the verdict JSON to
.coord/mediator/verdict/<ts>.json via your Bash tool.

The snapshot above is your initial context. You may use Bash to
verify against fresh state files (cat / jq) before deciding.
EOF
}

# _coord_mediator_assemble_prompt <pending_id> <depth> <prior_verdict_path>
_coord_mediator_assemble_prompt() {
  local pending_id="$1"
  local depth="$2"
  local prior_verdict_path="$3"
  local ref_path=".coord/mediator/MEDIATOR_REFERENCE.md"
  printf '%s\n\n%s\n\n%s\n\n' \
    "$(_coord_mediator_build_identity_section)" \
    "$(_coord_mediator_build_constraints_section "$ref_path")" \
    "$(_coord_mediator_build_context_section "$pending_id" "$prior_verdict_path")"
  printf '## Spawn metadata\n\nYour spawn parameters:\n- depth=%s\n- model=%s\n- spawn_mode=no_bare (subscription mode)\n\nProceed with verdict.\n' \
    "$depth" "$COORD_MEDIATOR_MODEL"
}

# coord_mediator_spawn <pending_entry_id> [<depth>] [<prior_verdict_path>]
#   Returns 0 on completion (verdict written, path on stdout).
#   Returns 1 on refusal (recursion guard, critical bypass) or failure
#   (claude binary missing, spawn timeout, JSON parse error).
coord_mediator_spawn() {
  local pending_id="$1"
  local depth="${2:-1}"
  local prior_verdict_path="${3:-}"

  if [ -z "${COORD_DIR:-}" ] || [ ! -d "$COORD_DIR" ]; then
    _coord_mediator_warn "COORD_DIR unset or missing"
    return 1
  fi

  # Recursion guard: refuse if caller is already inside a Mediator
  # context (CLAUDE_CODE_MEDIATOR set in caller env). Per
  # PR-PHASE3-01 max-depth-2 hard ceiling.
  local caller_depth="${CLAUDE_CODE_MEDIATOR:-0}"
  case "$caller_depth" in *[!0-9]*|'') caller_depth=0 ;; esac
  if [ "$caller_depth" -ge 2 ]; then
    _coord_mediator_warn "recursion guard: caller depth=$caller_depth, refusing spawn"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=MEDIATOR_SPAWN_REFUSED \
        reason=recursion_guard caller_depth="$caller_depth" 2>/dev/null || true
    fi
    return 1
  fi
  # If caller is depth=1, we are spawning peer review at depth=2.
  if [ "$caller_depth" -eq 1 ] && [ "$depth" -lt 2 ]; then
    depth=2
  fi

  # Critical-bypass guard: refuse if a critical condition is active
  # (e.g., 3x parse failures). Caller should have already triggered
  # lockdown directly.
  if command -v coord_critical_check_thresholds >/dev/null 2>&1; then
    if coord_critical_check_thresholds; then
      _coord_mediator_warn "critical-condition active; refusing Mediator spawn"
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=MEDIATOR_SPAWN_REFUSED \
          reason=critical_bypass_active 2>/dev/null || true
      fi
      return 1
    fi
  fi

  # claude binary check.
  if ! command -v claude >/dev/null 2>&1; then
    _coord_mediator_warn "claude binary missing on PATH; cannot spawn"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=MEDIATOR_SPAWN_REFUSED \
        reason=claude_binary_missing 2>/dev/null || true
    fi
    return 1
  fi

  # Phase 7 / T7.03 mode resolution + cost-guard interlock slot
  # (PR-PHASE7-02 §"3-site refactor pattern"). Mode-aware audit;
  # cost-guard hook deferred until T7.05 implements lib/cost_guards.sh.
  local _spawn_mode_resolved=mock
  local _spawn_real_claude=0
  if command -v coord_spawn_helper_resolve_mode >/dev/null 2>&1; then
    _spawn_mode_resolved=$(coord_spawn_helper_resolve_mode 2>/dev/null) \
      || _spawn_mode_resolved=mock
    if coord_spawn_helper_should_use_real_claude mediator 2>/dev/null; then
      _spawn_real_claude=1
      # T7.05 cost-guard interlock slot: when coord_cost_guards_check
      # is implemented, call it here. Rate-limited → REFUSED return 1
      # via Phase 1 fallback contract (caller fail-open).
      if command -v coord_cost_guards_check >/dev/null 2>&1; then
        if ! coord_cost_guards_check mediator 2>/dev/null; then
          _coord_mediator_warn "cost-guard rate-limited mediator spawn"
          if command -v coord_log_event >/dev/null 2>&1; then
            coord_log_event kind=MEDIATOR_SPAWN_REFUSED \
              reason=rate_limited 2>/dev/null || true
          fi
          return 1
        fi
      fi
    fi
  fi

  local verdict_dir="$COORD_DIR/mediator/verdict"
  [ -d "$verdict_dir" ] || mkdir -p "$verdict_dir" 2>/dev/null

  local prompt
  prompt=$(_coord_mediator_assemble_prompt "$pending_id" "$depth" "$prior_verdict_path")

  local t_start
  t_start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || date +%s)

  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=MEDIATOR_SPAWN_STARTED \
      pending_entry_id="$pending_id" depth="$depth" \
      model="$COORD_MEDIATOR_MODEL" spawn_mode=no_bare \
      mode_resolved="$_spawn_mode_resolved" \
      real_claude="$_spawn_real_claude" \
      budget_usd="$COORD_MEDIATOR_BUDGET_USD" \
      timeout_sec="$COORD_MEDIATOR_TIMEOUT_SEC" 2>/dev/null || true
  fi

  # Spawn claude -p with subscription-mode flags. CLAUDE_COORD=0 in
  # spawn env per T3.07 user direction; --bare deferred to future
  # enhancement.
  local raw_output spawn_rc
  raw_output=$(
    env CLAUDE_COORD=0 CLAUDE_CODE_MEDIATOR="$depth" \
        COORD_DIR="$COORD_DIR" \
        claude -p "$prompt" \
          --output-format json \
          --model "$COORD_MEDIATOR_MODEL" \
          --max-budget-usd "$COORD_MEDIATOR_BUDGET_USD" \
          --allowedTools Bash Read \
          --disallowedTools Write Edit NotebookEdit Task \
          2>/dev/null
  )
  spawn_rc=$?

  local t_end duration_ms
  t_end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || date +%s)
  duration_ms=$(( t_end - t_start ))

  # Parse JSON output (T3.06 POC: claude -p ALWAYS exits 0 regardless
  # of is_error; the truth is in the JSON payload).
  if [ -z "$raw_output" ]; then
    _coord_mediator_warn "spawn produced empty output (rc=$spawn_rc, duration_ms=$duration_ms)"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=MEDIATOR_SPAWN_FAILED \
        reason=empty_output spawn_rc="$spawn_rc" duration_ms="$duration_ms" 2>/dev/null || true
    fi
    return 1
  fi

  local is_error claude_session_id total_cost result_text errors
  is_error=$(printf '%s' "$raw_output" | jq -r '.is_error // false' 2>/dev/null) || is_error=true
  claude_session_id=$(printf '%s' "$raw_output" | jq -r '.session_id // ""' 2>/dev/null)
  total_cost=$(printf '%s' "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
  result_text=$(printf '%s' "$raw_output" | jq -r '.result // ""' 2>/dev/null)
  errors=$(printf '%s' "$raw_output" | jq -rc '.errors // []' 2>/dev/null)

  if [ "$is_error" = "true" ]; then
    _coord_mediator_warn "Mediator returned is_error=true: $errors"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=MEDIATOR_SPAWN_FAILED \
        reason=is_error_true errors="$errors" \
        spawn_session_id="$claude_session_id" \
        total_cost_usd="$total_cost" duration_ms="$duration_ms" 2>/dev/null || true
    fi
    return 1
  fi

  # The Mediator was instructed to write the verdict file via its Bash
  # tool. Confirm the file exists. If we cannot find a fresh verdict
  # file, attempt to extract a JSON verdict from the result text as a
  # fallback (Mediator may have included it inline rather than via
  # Bash write).
  local latest_verdict
  latest_verdict=$(ls -1t "$verdict_dir"/*.json 2>/dev/null | head -1)
  if [ -z "$latest_verdict" ]; then
    # Fallback: try to write the result text as the verdict.
    if printf '%s' "$result_text" | jq -e '.verdict_id' >/dev/null 2>&1; then
      local vname
      vname=$(_coord_mediator_now_iso8601 | tr ':.' '--')
      latest_verdict="$verdict_dir/${vname}.json"
      printf '%s' "$result_text" | jq -c . >"$latest_verdict" 2>/dev/null || latest_verdict=""
    fi
  fi

  if [ -z "$latest_verdict" ] || [ ! -f "$latest_verdict" ]; then
    _coord_mediator_warn "no verdict file found after spawn (Mediator may not have written one)"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=MEDIATOR_SPAWN_FAILED \
        reason=no_verdict_written \
        spawn_session_id="$claude_session_id" \
        duration_ms="$duration_ms" 2>/dev/null || true
    fi
    return 1
  fi

  # Augment the verdict file with spawn_metadata if missing.
  local has_meta
  has_meta=$(jq -r 'has("spawn_metadata")' "$latest_verdict" 2>/dev/null) || has_meta=false
  if [ "$has_meta" != "true" ]; then
    local tmp="${latest_verdict}.tmp.$$.$RANDOM"
    jq --arg duration "$duration_ms" --arg model "$COORD_MEDIATOR_MODEL" \
       --arg session_id "$claude_session_id" --arg cost "$total_cost" \
       '. + {spawn_metadata: {duration_ms: ($duration|tonumber), model: $model, spawn_mode: "no_bare", spawn_session_id: $session_id, total_cost_usd: ($cost|tonumber)}}' \
       "$latest_verdict" >"$tmp" 2>/dev/null \
      && mv -f "$tmp" "$latest_verdict" 2>/dev/null || rm -f "$tmp"
  fi

  if command -v coord_log_event >/dev/null 2>&1; then
    local action_type confidence scope
    action_type=$(jq -r '.action_type // "?"' "$latest_verdict" 2>/dev/null)
    confidence=$(jq -r '.confidence // "?"' "$latest_verdict" 2>/dev/null)
    scope=$(jq -r 'if (.action_type // "") == "lockdown" then "system-wide" else "caller-only" end' "$latest_verdict" 2>/dev/null)
    coord_log_event kind=MEDIATOR_VERDICT \
      verdict_path="$latest_verdict" \
      action_type="$action_type" confidence="$confidence" scope="$scope" \
      depth="$depth" \
      spawn_session_id="$claude_session_id" \
      duration_ms="$duration_ms" total_cost_usd="$total_cost" 2>/dev/null || true
  fi

  # GC pending (per PR-PHASE3-04: GC bundled with verdict-write pass).
  if command -v coord_mediator_gc_pending >/dev/null 2>&1; then
    coord_mediator_gc_pending 2>/dev/null || true
  fi

  printf '%s\n' "$latest_verdict"
  return 0
}

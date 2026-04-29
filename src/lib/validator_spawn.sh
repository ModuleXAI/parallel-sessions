#!/usr/bin/env bash
# validator_spawn.sh — Phase 4 / T4.04 Validator agent spawn helper
# (PR-PHASE4-01 implementation per T4.03 POC findings + Decision 2).
#
# Spawns a `claude -p` subprocess that classifies a stale-read drift
# as SAFE / MINOR / CRITICAL. Builds the 3-section prompt
# (Identity / System Constraints / Drift Context), invokes claude in
# subscription mode (no-bare + CLAUDE_COORD=0 spawn env per T3.07
# convention adopted from CLAUDE.md §A.13 lesson #4), and captures
# stdout JSON.
#
# Per T4.03 POC findings (3 refinements vs Mediator pattern):
#   (a) `is_error` parsed via `jq -r '.is_error // false'` followed
#       by string compare — `// "?"` form is wrong because jq's `//`
#       treats boolean false as alternative-needed.
#   (b) Verdict-file validation: must be non-empty + jq-parseable +
#       has `verdict_id`. Validator may write empty/exploratory files
#       before the real verdict; helper falls through to next-most-
#       recent on failure.
#   (c) `validator_session_id` post-processed: validator agent fills
#       a placeholder string; helper injects the real spawn UUID
#       (claude -p's top-level session_id) before returning.
#
# Public API:
#   coord_validator_spawn <session_id> <file> <read_hash> <current_hash>
#       Returns 0 on completion (verdict written, path on stdout).
#       Returns 1 on refusal (recursion guard, claude binary missing,
#       read snapshot missing) or failure (empty output, is_error,
#       no verdict file).
#
# Environment passed to claude -p:
#   CLAUDE_COORD=0                  — disable coord hooks for spawned process
#   CLAUDE_CODE_VALIDATOR=1         — recursion guard marker (depth-1 only)
#   COORD_DIR                       — inherited so validator can read state
#   PATH                            — inherited
#
# Recursion guard (depth-1 only): if CLAUDE_CODE_VALIDATOR is already
# set to ANY non-empty value in caller's env, refuse spawn. Phase 4
# does not exercise peer review; Phase 5+ may extend.

# Tunables (env-overridable; install.sh / coord health surface formal
# config.json entries via PR-PHASE4-01 §D).
: "${COORD_VALIDATOR_MODEL:=claude-haiku-4-5-20251001}"
: "${COORD_VALIDATOR_BUDGET_USD:=0.50}"
: "${COORD_VALIDATOR_TIMEOUT_SEC:=120}"
: "${COORD_VALIDATOR_MAX_EMBEDDED_BYTES:=102400}"   # 100 KB truncation
: "${COORD_VALIDATOR_MAX_DIFF_BYTES:=51200}"        # 50 KB truncation

# Internal helpers ---------------------------------------------------------

_coord_validator_warn() {
  printf 'coord validator_spawn: %s\n' "$*" >&2
}

_coord_validator_now_iso8601() {
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    coord_now_iso8601
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# _coord_validator_truncate_file <file> <max_bytes> <marker>
#   Print up to max_bytes from file; if truncated, append marker line.
_coord_validator_truncate_file() {
  local f="$1" max="$2" marker="$3"
  [ -f "$f" ] || return 0
  local size
  size=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
  case "$size" in *[!0-9]*|'') size=0 ;; esac
  if [ "$size" -le "$max" ]; then
    cat "$f"
  else
    head -c "$max" "$f"
    printf '\n%s\n' "$marker"
  fi
}

# _coord_validator_build_identity_section
#   Section 1 — fixed text per Decision 2 / PR-PHASE4-01.
_coord_validator_build_identity_section() {
  cat <<'EOF'
# Section 1: Identity

You are a Validator agent in a Claude Code coordination system. Your
role is to classify file drift between two versions: the version a
session read, and the current state. You return ONE of three verdicts:
SAFE / MINOR / CRITICAL. Your judgment determines whether a session's
pending Write should proceed silently, with a warning, or be
escalated to the Mediator. You do not take actions; you classify.
EOF
}

# _coord_validator_build_constraints_section <reference_path>
#   Section 2 — 5 core rules + reference pointer.
_coord_validator_build_constraints_section() {
  local ref_path="$1"
  cat <<EOF
# Section 2: System Constraints

1. Use Bash and Read tools only. NEVER use Edit, Write, or
   NotebookEdit.

2. You are not a tracked session. You operate as a temporary
   classifier.

3. Write your verdict to .coord/validator/verdict/<ts>.json via your
   Bash tool. Use the current ISO timestamp with colons and dots
   replaced by hyphens for the filename (e.g., 2026-04-26T12-30-00Z.json).

4. If CLAUDE_CODE_VALIDATOR=1 in env, you are nested. Do NOT spawn
   another Validator. (Recursion guard.)

5. You DO NOT take actions on state. You only classify. Mediator
   handles CRITICAL escalation actions.

For detailed mechanics (verdict schema, drift classification
heuristics, diff-summary format), read $ref_path when needed.
EOF
}

# _coord_validator_build_context_section <sid> <file> <read_hash> <current_hash> <snapshot_path>
#   Section 3 — embedded read-snapshot + current state + diff.
_coord_validator_build_context_section() {
  local sid="$1" file="$2" rhash="$3" chash="$4" snap_path="$5"
  local diff_block diff_size

  # Compute diff once; truncate if oversized.
  local diff_tmp
  diff_tmp=$(mktemp 2>/dev/null) || diff_tmp=""
  if [ -n "$diff_tmp" ] && [ -f "$snap_path" ] && [ -f "$file" ]; then
    diff -u "$snap_path" "$file" >"$diff_tmp" 2>/dev/null || true
    diff_size=$(wc -c <"$diff_tmp" 2>/dev/null | tr -d ' ')
    case "$diff_size" in *[!0-9]*|'') diff_size=0 ;; esac
    if [ "$diff_size" -gt "$COORD_VALIDATOR_MAX_DIFF_BYTES" ]; then
      diff_block=$(head -c "$COORD_VALIDATOR_MAX_DIFF_BYTES" "$diff_tmp"; printf '\n[diff truncated; total %s bytes]\n' "$diff_size")
    else
      diff_block=$(cat "$diff_tmp")
    fi
    rm -f "$diff_tmp"
  else
    diff_block="[diff unavailable]"
  fi

  cat <<EOF
# Section 3: Drift Context

(a) File path: $file

(b) Read snapshot (sha256 = $rhash):
\`\`\`
$(_coord_validator_truncate_file "$snap_path" "$COORD_VALIDATOR_MAX_EMBEDDED_BYTES" "[snapshot truncated]")
\`\`\`

(c) Current state (sha256 = $chash):
\`\`\`
$(_coord_validator_truncate_file "$file" "$COORD_VALIDATOR_MAX_EMBEDDED_BYTES" "[current truncated]")
\`\`\`

(d) Unified diff (snapshot vs current):
\`\`\`diff
$diff_block
\`\`\`

(e) Verdict contract:
- SAFE: changes that cannot break callers (formatter-only, comment
  additions, blank-line additions, license header updates,
  unused-import reorders).
- MINOR: changes that may surprise callers but cannot break them
  (renamed local variable inside a function, string literal changed,
  test added, typo fixed).
- CRITICAL: changes that can break callers (function signature
  changed, exported variable removed, type definition changed,
  schema migration, behavior reversal).

Verdict JSON schema (write to .coord/validator/verdict/<ts>.json):
{
  "verdict_id": "<UUID v4>",
  "ts": "<ISO 8601 UTC>",
  "for_pending_entry": null,
  "validator_session_id": "<placeholder; spawn helper injects real UUID>",
  "file": "$file",
  "session": "$sid",
  "verdict": "SAFE|MINOR|CRITICAL",
  "reasoning": "<1-3 sentences plain text no apostrophes>",
  "diff_summary": "<1-3 sentences plain text no apostrophes>",
  "spawn_metadata": {
    "duration_ms": 0,
    "model": "$COORD_VALIDATOR_MODEL",
    "spawn_mode": "no_bare"
  }
}

Use Bash + Read to verify or augment context. Then write the verdict.
The spawn helper post-processes spawn_metadata + validator_session_id
after you write the file.
EOF
}

# _coord_validator_assemble_prompt <sid> <file> <read_hash> <current_hash> <snapshot_path>
_coord_validator_assemble_prompt() {
  local sid="$1" file="$2" rhash="$3" chash="$4" snap_path="$5"
  local ref_path=".coord/validator/VALIDATOR_REFERENCE.md"
  printf '%s\n\n%s\n\n%s\n' \
    "$(_coord_validator_build_identity_section)" \
    "$(_coord_validator_build_constraints_section "$ref_path")" \
    "$(_coord_validator_build_context_section "$sid" "$file" "$rhash" "$chash" "$snap_path")"
}

# _coord_validator_validate_verdict_file <path>
#   Returns 0 if file is non-empty AND parses as JSON AND has
#   `verdict_id`. 1 otherwise. (Refinement (b) per T4.03 POC.)
_coord_validator_validate_verdict_file() {
  local p="$1"
  [ -f "$p" ] || return 1
  [ -s "$p" ] || return 1
  jq -e 'has("verdict_id")' "$p" >/dev/null 2>&1
}

# _coord_validator_pick_latest_valid_verdict <verdict_dir>
#   Lists verdict files newest-first; returns the first that
#   passes _coord_validator_validate_verdict_file. Empty if none.
_coord_validator_pick_latest_valid_verdict() {
  local vdir="$1"
  [ -d "$vdir" ] || return 1
  local f
  for f in $(ls -1t "$vdir"/*.json 2>/dev/null); do
    if _coord_validator_validate_verdict_file "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# coord_validator_spawn <session_id> <file> <read_hash> <current_hash>
#   Returns 0 on completion (verdict written, path on stdout).
#   Returns 1 on refusal or failure.
coord_validator_spawn() {
  local sid="$1" file="$2" rhash="$3" chash="$4"

  if [ -z "$sid" ] || [ -z "$file" ] || [ -z "$rhash" ] || [ -z "$chash" ]; then
    _coord_validator_warn "missing args (sid=$sid file=$file rhash=$rhash chash=$chash)"
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "$COORD_DIR" ]; then
    _coord_validator_warn "COORD_DIR unset or missing"
    return 1
  fi

  # Recursion guard (depth-1 only): refuse if caller already has
  # CLAUDE_CODE_VALIDATOR set to any non-empty value.
  if [ -n "${CLAUDE_CODE_VALIDATOR:-}" ] && [ "${CLAUDE_CODE_VALIDATOR}" != "0" ]; then
    _coord_validator_warn "recursion guard: CLAUDE_CODE_VALIDATOR=${CLAUDE_CODE_VALIDATOR}, refusing spawn"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_RECURSION_REFUSED \
        file="$file" caller_validator_env="$CLAUDE_CODE_VALIDATOR" 2>/dev/null || true
    fi
    return 1
  fi

  # Snapshot lookup (T4.02a). Missing snapshot → refuse spawn.
  local snap_path=""
  if command -v coord_read_snapshot_path >/dev/null 2>&1; then
    snap_path=$(coord_read_snapshot_path "$sid" "$rhash" 2>/dev/null) || snap_path=""
  fi
  if [ -z "$snap_path" ] || [ ! -r "$snap_path" ]; then
    _coord_validator_warn "read snapshot missing for sid=$sid hash=$rhash"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_SPAWN_FAILED \
        file="$file" reason=read_snapshot_missing 2>/dev/null || true
    fi
    return 1
  fi
  if [ ! -r "$file" ]; then
    _coord_validator_warn "current file unreadable: $file"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_SPAWN_FAILED \
        file="$file" reason=current_unreadable 2>/dev/null || true
    fi
    return 1
  fi

  # claude binary check.
  if ! command -v claude >/dev/null 2>&1; then
    _coord_validator_warn "claude binary missing on PATH; cannot spawn"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_SPAWN_FAILED \
        file="$file" reason=claude_binary_missing 2>/dev/null || true
    fi
    return 1
  fi

  # Phase 7 / T7.03 mode resolution + cost-guard interlock slot
  # (PR-PHASE7-02 §"3-site refactor pattern"). In semi mode the
  # validator routes to mock (mock binary on PATH); only realistic
  # mode dispatches to real claude -p for validator. Cost-guard hook
  # deferred until T7.05 implements lib/cost_guards.sh.
  local _spawn_mode_resolved=mock
  local _spawn_real_claude=0
  if command -v coord_spawn_helper_resolve_mode >/dev/null 2>&1; then
    _spawn_mode_resolved=$(coord_spawn_helper_resolve_mode 2>/dev/null) \
      || _spawn_mode_resolved=mock
    if coord_spawn_helper_should_use_real_claude validator 2>/dev/null; then
      _spawn_real_claude=1
      if command -v coord_cost_guards_check >/dev/null 2>&1; then
        if ! coord_cost_guards_check validator 2>/dev/null; then
          _coord_validator_warn "cost-guard rate-limited validator spawn"
          if command -v coord_log_event >/dev/null 2>&1; then
            coord_log_event kind=VALIDATOR_SPAWN_FAILED \
              file="$file" reason=rate_limited 2>/dev/null || true
          fi
          return 1
        fi
      fi
    fi
  fi

  local verdict_dir="$COORD_DIR/validator/verdict"
  [ -d "$verdict_dir" ] || mkdir -p "$verdict_dir" 2>/dev/null

  local prompt
  prompt=$(_coord_validator_assemble_prompt "$sid" "$file" "$rhash" "$chash" "$snap_path")

  local t_start
  t_start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || date +%s)

  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=VALIDATOR_SPAWN_STARTED \
      file="$file" read_hash="$rhash" current_hash="$chash" \
      model="$COORD_VALIDATOR_MODEL" spawn_mode=no_bare \
      mode_resolved="$_spawn_mode_resolved" \
      real_claude="$_spawn_real_claude" \
      budget_usd="$COORD_VALIDATOR_BUDGET_USD" \
      timeout_sec="$COORD_VALIDATOR_TIMEOUT_SEC" 2>/dev/null || true
  fi

  # Spawn claude -p. CLAUDE_COORD=0 + CLAUDE_CODE_VALIDATOR=1 in
  # spawn env per T4.03 POC.
  local raw_output spawn_rc
  raw_output=$(
    env CLAUDE_COORD=0 CLAUDE_CODE_VALIDATOR=1 \
        COORD_DIR="$COORD_DIR" \
        claude -p "$prompt" \
          --output-format json \
          --model "$COORD_VALIDATOR_MODEL" \
          --max-budget-usd "$COORD_VALIDATOR_BUDGET_USD" \
          --allowedTools "Bash" "Read" \
          --disallowedTools "Write" "Edit" "NotebookEdit" "Task" \
          2>/dev/null
  )
  spawn_rc=$?

  local t_end duration_ms
  t_end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || date +%s)
  duration_ms=$(( t_end - t_start ))

  # Empty output → fail.
  if [ -z "$raw_output" ]; then
    _coord_validator_warn "spawn produced empty output (rc=$spawn_rc, duration_ms=$duration_ms)"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_SPAWN_FAILED \
        file="$file" reason=empty_output spawn_rc="$spawn_rc" \
        duration_ms="$duration_ms" 2>/dev/null || true
    fi
    return 1
  fi

  # Refinement (a): is_error parsed via Mediator pattern (// false +
  # string compare). The // operator treats boolean false as
  # "alternative needed" only when the LEFT side is null OR false;
  # here the right side is the literal `false`, so result is `false`
  # if .is_error is missing (correct fallback) or `false` if .is_error
  # is false (correct: not an error). String "true" only when actual
  # error.
  # Refinement (a): is_error parsed via Mediator pattern (// false +
  # string compare). All jq calls here use `|| <fallback>` to keep
  # set -e + pipefail (inherited from log_event.sh) from aborting the
  # function on jq parse failures (e.g., malformed claude output).
  local is_error claude_session_id total_cost result_text errors
  is_error=$(printf '%s' "$raw_output" | jq -r '.is_error // false' 2>/dev/null) || is_error=true
  claude_session_id=$(printf '%s' "$raw_output" | jq -r '.session_id // ""' 2>/dev/null) || claude_session_id=""
  total_cost=$(printf '%s' "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null) || total_cost=0
  result_text=$(printf '%s' "$raw_output" | jq -r '.result // ""' 2>/dev/null) || result_text=""
  errors=$(printf '%s' "$raw_output" | jq -rc '.errors // []' 2>/dev/null) || errors='[]'

  if [ "$is_error" = "true" ]; then
    _coord_validator_warn "Validator returned is_error=true: $errors"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_SPAWN_FAILED \
        file="$file" reason=is_error_true errors="$errors" \
        spawn_session_id="$claude_session_id" \
        total_cost_usd="$total_cost" duration_ms="$duration_ms" 2>/dev/null || true
    fi
    return 1
  fi

  # Refinement (b): pick the latest verdict file written by THIS
  # invocation that passes verdict_id validation. Validator may write
  # exploratory zero-byte files first; fall through to next-most-recent.
  local latest_verdict
  latest_verdict=$(_coord_validator_pick_latest_valid_verdict "$verdict_dir") || latest_verdict=""

  # Fallback: try to extract a JSON verdict from the result text if no
  # file was written via Bash (rare edge case).
  if [ -z "$latest_verdict" ]; then
    if printf '%s' "$result_text" | jq -e '.verdict_id' >/dev/null 2>&1; then
      local vname
      vname=$(_coord_validator_now_iso8601 | tr ':.' '--')
      latest_verdict="$verdict_dir/${vname}.json"
      printf '%s' "$result_text" | jq -c . >"$latest_verdict" 2>/dev/null || latest_verdict=""
    fi
  fi

  if [ -z "$latest_verdict" ] || [ ! -f "$latest_verdict" ]; then
    _coord_validator_warn "no valid verdict file found after spawn"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_SPAWN_FAILED \
        file="$file" reason=no_verdict_written \
        spawn_session_id="$claude_session_id" \
        duration_ms="$duration_ms" 2>/dev/null || true
    fi
    return 1
  fi

  # Refinement (c): inject real validator_session_id from spawn output.
  # Also augment spawn_metadata with measured duration + cost.
  local tmp="${latest_verdict}.tmp.$$.$RANDOM"
  jq --arg sid "$claude_session_id" \
     --arg duration "$duration_ms" --arg model "$COORD_VALIDATOR_MODEL" \
     --arg cost "$total_cost" \
     '. as $orig
      | .validator_session_id = $sid
      | .spawn_metadata = (($orig.spawn_metadata // {}) + {
          duration_ms: ($duration|tonumber),
          model: $model,
          spawn_mode: "no_bare",
          spawn_session_id: $sid,
          total_cost_usd: ($cost|tonumber)
        })' \
     "$latest_verdict" >"$tmp" 2>/dev/null \
    && mv -f "$tmp" "$latest_verdict" 2>/dev/null || rm -f "$tmp"

  # Capture verdict for event payload.
  local verdict_value
  verdict_value=$(jq -r '.verdict // "?"' "$latest_verdict" 2>/dev/null) || verdict_value="?"

  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=VALIDATOR_SPAWN_COMPLETED \
      file="$file" verdict="$verdict_value" \
      verdict_path="$latest_verdict" \
      spawn_session_id="$claude_session_id" \
      duration_ms="$duration_ms" total_cost_usd="$total_cost" 2>/dev/null || true
  fi

  printf '%s\n' "$latest_verdict"
  return 0
}

# CLI shim:
#   validator_spawn.sh <session_id> <file> <read_hash> <current_hash>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_validator_spawn "$@"
fi

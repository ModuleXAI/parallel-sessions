#!/usr/bin/env bash
# validator_prefilter.sh — Phase 4 / T4.02b deterministic pre-filter
# fast-tracking trivial drifts to SAFE without spawning the validator
# agent.
#
# Per PR-PHASE4-01 §E + T4.02b user direction: 3-stage pipeline (cache
# → pre-filter → agent); this file is stage 2. Pre-filter takes the
# read-snapshot (via coord_read_snapshot_path from T4.02a) and the
# current file content; computes a diff; classifies as SAFE if the
# drift matches a heuristic, else ESCALATE_TO_AGENT for the validator
# spawn (T4.04).
#
# Heuristics:
#   1. Whitespace-only       — `diff -w` produces no output.
#   2. Blank-line-only       — every +/- line in the diff is purely whitespace.
#   3. Comment-only          — every +/- line matches a single-line comment
#                              regex AND the file contains no multi-line
#                              string markers (""" ''' triple-backtick).
#                              The multi-line guard is the conservative
#                              measure preventing false-SAFE on lines that
#                              look like comments but are actually inside
#                              a docstring or markdown code fence.
#
# Always-ESCALATE conditions:
#   - File >1 MB (either snapshot or current)
#   - Pre-filter elapsed time >5 s (we abandon the heuristics and let the
#     agent classify)
#   - Snapshot missing (T4.02a snapshot for the read_hash absent —
#     defensive fallback per Concern E disposition)
#   - Anything not matching a heuristic
#
# Doctrine: false-negative SAFE on real drift is dangerous; false-positive
# ESCALATE on trivial drift is acceptable. When in doubt, escalate.
#
# Public API:
#   coord_validator_prefilter <session_id> <file> <read_hash> <current_hash>
#       Returns 0 on SAFE (stdout: "safe:<reason>")
#       Returns 1 on ESCALATE_TO_AGENT (stdout: "escalate:<reason>")
#       Returns 2 on internal error (caller treats as ESCALATE)
#
# Bash 3.2 portable. Pure bash + diff(1); no jq dependency for heuristic
# logic.

# Tunables.
: "${COORD_VALIDATOR_PREFILTER_MAX_FILE_KB:=1024}"
: "${COORD_VALIDATOR_PREFILTER_TIMEOUT_SEC:=5}"

# Comment regex (single-line styles only). Multi-line opener/closer
# markers (""" ''' triple-backtick) are intentionally NOT in this regex
# — their presence in the file forces ESCALATE on the comment path.
_COORD_VALIDATOR_PREFILTER_COMMENT_BRE='^[[:space:]]*\(#\|//\|/\*\|\*[^/]*$\|\*$\|<!--\)'

_coord_validator_prefilter_warn() {
  printf 'coord validator_prefilter: %s\n' "$*" >&2
}

_coord_validator_prefilter_log_safe() {
  local reason="$1" file="$2" rhash="$3" chash="$4" elapsed="$5"
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=VALIDATOR_PREFILTER_SAFE \
      file="$file" read_hash="$rhash" current_hash="$chash" \
      prefilter_reason="$reason" elapsed_ms="$elapsed" || true
  fi
  printf 'safe:%s\n' "$reason"
}

_coord_validator_prefilter_log_escalate() {
  local reason="$1" file="$2" rhash="$3" chash="$4" elapsed="$5"
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=VALIDATOR_PREFILTER_ESCALATED \
      file="$file" read_hash="$rhash" current_hash="$chash" \
      escalation_reason="$reason" elapsed_ms="$elapsed" || true
  fi
  printf 'escalate:%s\n' "$reason"
}

# _coord_validator_prefilter_file_size_kb <path>
#   Portable file size in KB (rounded up). F-018 GNU-first probe.
_coord_validator_prefilter_file_size_kb() {
  local f="$1" bytes=""
  [ -e "$f" ] || { printf '0'; return; }
  bytes=$(stat -c '%s' "$f" 2>/dev/null)
  case "$bytes" in
    ''|*[!0-9]*) bytes="" ;;
  esac
  if [ -z "$bytes" ]; then
    bytes=$(stat -f '%z' "$f" 2>/dev/null)
    case "$bytes" in
      ''|*[!0-9]*) bytes=0 ;;
    esac
  fi
  # Round up.
  printf '%d' $(( (bytes + 1023) / 1024 ))
}

# _coord_validator_prefilter_now_ms
#   Best-effort millisecond epoch. perl preferred (F-009).
_coord_validator_prefilter_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null \
    || printf '%d' $(( $(date -u +%s) * 1000 ))
}

# _coord_validator_prefilter_extract_diff_lines <diff_file> <prefix>
#   prefix = "-" or "+". Emits each diff line of that polarity (without
#   the leading character) to stdout, ONE PER LINE. Skips the file
#   headers (--- / +++).
_coord_validator_prefilter_extract_diff_lines() {
  local diff_file="$1" prefix="$2"
  case "$prefix" in
    '-') sed -n '/^---/d; /^-/s/^-//p' "$diff_file" 2>/dev/null ;;
    '+') sed -n '/^+++/d; /^+/s/^+//p' "$diff_file" 2>/dev/null ;;
    *)   return 1 ;;
  esac
}

# _coord_validator_prefilter_lines_blank_only <diff_file>
#   Returns 0 if every changed line (both +/-) is purely whitespace.
#   1 otherwise. Empty diff returns 0 trivially (caller already handled
#   whitespace-only via diff -w).
_coord_validator_prefilter_lines_blank_only() {
  local diff_file="$1"
  # Extract all +/- lines (excluding headers); fail if any non-blank.
  local non_blank
  non_blank=$(
    {
      _coord_validator_prefilter_extract_diff_lines "$diff_file" '-'
      _coord_validator_prefilter_extract_diff_lines "$diff_file" '+'
    } | grep -c '[^[:space:]]' 2>/dev/null
  )
  case "$non_blank" in *[!0-9]*|'') non_blank=0 ;; esac
  [ "$non_blank" -eq 0 ]
}

# _coord_validator_prefilter_has_multiline_markers <file>
#   Returns 0 if the file contains any """, ''', or triple-backtick.
#   1 otherwise.
_coord_validator_prefilter_has_multiline_markers() {
  local f="$1"
  [ -f "$f" ] || return 1
  if grep -q -- '"""' "$f" 2>/dev/null; then return 0; fi
  if grep -q -- "'''" "$f" 2>/dev/null; then return 0; fi
  if grep -q -- '```' "$f" 2>/dev/null; then return 0; fi
  return 1
}

# _coord_validator_prefilter_lines_comment_only <diff_file>
#   Returns 0 if every changed line (both +/-) matches the comment
#   regex. 1 otherwise. Empty diff returns 0 trivially.
_coord_validator_prefilter_lines_comment_only() {
  local diff_file="$1"
  # Pull all changed lines; check each matches comment regex.
  local non_comment
  non_comment=$(
    {
      _coord_validator_prefilter_extract_diff_lines "$diff_file" '-'
      _coord_validator_prefilter_extract_diff_lines "$diff_file" '+'
    } | grep -v -- "$_COORD_VALIDATOR_PREFILTER_COMMENT_BRE" 2>/dev/null \
      | grep -c '[^[:space:]]' 2>/dev/null
  )
  case "$non_comment" in *[!0-9]*|'') non_comment=0 ;; esac
  [ "$non_comment" -eq 0 ]
}

# coord_validator_prefilter <session_id> <file> <read_hash> <current_hash>
coord_validator_prefilter() {
  local sid="$1" file="$2" rhash="$3" chash="$4"
  if [ -z "$sid" ] || [ -z "$file" ] || [ -z "$rhash" ] || [ -z "$chash" ]; then
    return 2
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    return 2
  fi

  local t_start t_end elapsed_ms
  t_start=$(_coord_validator_prefilter_now_ms)

  # Snapshot lookup (T4.02a). Missing snapshot → ESCALATE per defensive
  # fallback (Concern E disposition + PR-PHASE4-05 §6).
  local snapshot_path
  if command -v coord_read_snapshot_path >/dev/null 2>&1; then
    snapshot_path=$(coord_read_snapshot_path "$sid" "$rhash" 2>/dev/null) || snapshot_path=""
  else
    snapshot_path=""
  fi
  if [ -z "$snapshot_path" ] || [ ! -r "$snapshot_path" ]; then
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_escalate read_snapshot_missing \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 1
  fi

  # Current file readable check.
  if [ ! -r "$file" ]; then
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_escalate current_unreadable \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 1
  fi

  # File size check (either snapshot or current >1MB → ESCALATE).
  local snap_kb cur_kb
  snap_kb=$(_coord_validator_prefilter_file_size_kb "$snapshot_path")
  cur_kb=$(_coord_validator_prefilter_file_size_kb "$file")
  if [ "$snap_kb" -gt "$COORD_VALIDATOR_PREFILTER_MAX_FILE_KB" ] \
     || [ "$cur_kb" -gt "$COORD_VALIDATOR_PREFILTER_MAX_FILE_KB" ]; then
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_escalate file_too_large \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 1
  fi

  # Heuristic 1: whitespace-only via `diff -w`.
  # diff exit codes: 0 same, 1 differ, 2 trouble.
  local diff_w_rc
  diff -w -q "$snapshot_path" "$file" >/dev/null 2>&1
  diff_w_rc=$?
  if [ "$diff_w_rc" -eq 0 ]; then
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_safe whitespace_only \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 0
  fi
  if [ "$diff_w_rc" -eq 2 ]; then
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_escalate diff_tool_error \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 1
  fi

  # Compute the unified diff once for heuristics 2 + 3.
  local diff_file
  diff_file=$(mktemp 2>/dev/null) || {
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_escalate mktemp_failed \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 2
  }
  diff -u "$snapshot_path" "$file" >"$diff_file" 2>/dev/null

  # Timeout check before heuristics 2+3.
  local now_check elapsed_check
  now_check=$(_coord_validator_prefilter_now_ms)
  elapsed_check=$(( now_check - t_start ))
  if [ "$elapsed_check" -gt $(( COORD_VALIDATOR_PREFILTER_TIMEOUT_SEC * 1000 )) ]; then
    rm -f "$diff_file" 2>/dev/null
    _coord_validator_prefilter_log_escalate prefilter_timeout \
      "$file" "$rhash" "$chash" "$elapsed_check"
    return 1
  fi

  # Heuristic 2: blank-line-only.
  if _coord_validator_prefilter_lines_blank_only "$diff_file"; then
    rm -f "$diff_file" 2>/dev/null
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_safe blank_only \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 0
  fi

  # Heuristic 3: comment-only with multi-line-string ambiguity guard.
  # If EITHER the snapshot OR the current file contains multi-line
  # markers (""" ''' triple-backtick), we cannot safely determine that
  # changed lines aren't inside a docstring / markdown code fence /
  # heredoc. Conservative: ESCALATE.
  if _coord_validator_prefilter_has_multiline_markers "$snapshot_path" \
     || _coord_validator_prefilter_has_multiline_markers "$file"; then
    rm -f "$diff_file" 2>/dev/null
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_escalate multiline_string_ambiguity \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 1
  fi
  if _coord_validator_prefilter_lines_comment_only "$diff_file"; then
    rm -f "$diff_file" 2>/dev/null
    t_end=$(_coord_validator_prefilter_now_ms)
    elapsed_ms=$(( t_end - t_start ))
    _coord_validator_prefilter_log_safe comment_only \
      "$file" "$rhash" "$chash" "$elapsed_ms"
    return 0
  fi

  # No heuristic matched. ESCALATE.
  rm -f "$diff_file" 2>/dev/null
  t_end=$(_coord_validator_prefilter_now_ms)
  elapsed_ms=$(( t_end - t_start ))
  _coord_validator_prefilter_log_escalate non_trivial_diff \
    "$file" "$rhash" "$chash" "$elapsed_ms"
  return 1
}

# CLI shim:
#   validator_prefilter.sh <sid> <file> <read_hash> <current_hash>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_validator_prefilter "$@"
fi

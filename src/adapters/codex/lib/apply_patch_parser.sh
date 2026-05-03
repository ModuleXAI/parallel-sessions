#!/usr/bin/env bash
# apply_patch_parser.sh — Codex apply_patch grammar parser.
#
# Phase C PR C.2. State-machine parser over a line-by-line pass through the
# patch text. Emits structured AST + per-file pre-image data for the drift
# gate that PR D.4 will consume.
#
# Grammar (per Codex Lark spec at codex-rs/apply-patch/src/parser.rs:6-21):
#
#   start: begin_patch hunk+ end_patch
#   begin_patch: "*** Begin Patch" LF
#   end_patch:   "*** End Patch" LF?
#   hunk: add_hunk | delete_hunk | update_hunk
#   add_hunk:    "*** Add File: " filename LF add_line+
#   delete_hunk: "*** Delete File: " filename LF
#   update_hunk: "*** Update File: " filename LF change_move? change?
#   change_move: "*** Move to: " filename LF
#   change: (change_context | change_line)+ eof_line?
#   change_context: ("@@" | "@@ " /(.+)/) LF
#   change_line:    ("+" | "-" | " ") /(.+)/ LF
#   eof_line:       "*** End of File" LF
#
# Public functions:
#   coord_cx_apply_patch_paths      <patch>           → newline-separated
#   coord_cx_apply_patch_operations <patch>           → TSV op/path/move_to
#   coord_cx_apply_patch_hunks      <patch> <path>    → JSON array of hunks
#   coord_cx_apply_patch_pre_image  <patch> <path>    → text (joined hunk pre-images)
#   coord_cx_apply_patch_pre_image_hash <patch> <path> → sha256 hex
#   coord_cx_apply_patch_edit_range <patch> <path>    → start\tend (TSV)
#
# Internal:
#   _coord_cx_parse_ast <patch>     → JSON document on stdout
#   _coord_cx_strip_heredoc <patch> → patch text (lenient mode for gpt-4.1)
#   _coord_cx_sha256_hex            → reads stdin, prints hex
#
# Returns:
#   0 on success
#   1 missing arg / empty patch / no hunks (rejects 005)
#   2 invalid file-op marker (rejects 013)
#   3 empty update hunk (rejects 008)
#   4 malformed hunk content line (104 — F-C2-03)
#   5 missing Begin/End Patch markers (103 + synth)
#
# Bash 3.2 compatible. No `set -euo pipefail` (sourced; caller governs).
# Single jq dependency.

# --- Marker constants ---
_CX_BEGIN_MARKER="*** Begin Patch"
_CX_END_MARKER="*** End Patch"
_CX_ADD_PREFIX="*** Add File: "
_CX_DELETE_PREFIX="*** Delete File: "
_CX_UPDATE_PREFIX="*** Update File: "
_CX_MOVE_PREFIX="*** Move to: "
_CX_EOF_MARKER="*** End of File"
_CX_HUNK_HEADER_BARE="@@"
_CX_HUNK_HEADER_PREFIX="@@ "

# --- Cross-platform sha256 hex helper ---
_coord_cx_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    printf 'apply_patch_parser: no sha256 binary (need shasum or sha256sum)\n' >&2
    return 1
  fi
}

# --- Lenient mode: strip <<EOF heredoc wrapping per parser.rs:135-172 ---
# If first line is <<EOF / <<'EOF' / <<"EOF" AND last non-empty line ends
# with EOF AND total >= 4 lines, strip the wrapping. Otherwise return input
# unchanged.
_coord_cx_strip_heredoc() {
  local text="$1"
  # Read into array
  local -a lns=()
  local ln
  while IFS= read -r ln; do
    lns+=("$ln")
  done <<<"$text"
  local n="${#lns[@]}"
  [ "$n" -ge 4 ] || { printf '%s' "$text"; return 0; }
  local first="${lns[0]}"
  local last_idx=$((n - 1))
  # Drop trailing empty lines for the EOF check
  while [ "$last_idx" -gt 0 ] && [ -z "${lns[$last_idx]}" ]; do
    last_idx=$((last_idx - 1))
  done
  local last="${lns[$last_idx]}"
  case "$first" in
    "<<EOF"|"<<'EOF'"|'<<"EOF"')
      if [ "$last" = "EOF" ] || [ "${last%EOF}" != "$last" ]; then
        # Emit lines [1..last_idx-1]
        local i
        local out=""
        for ((i=1; i<last_idx; i++)); do
          if [ -n "$out" ]; then out="$out"$'\n'; fi
          out="$out${lns[$i]}"
        done
        printf '%s' "$out"
        return 0
      fi
      ;;
  esac
  printf '%s' "$text"
}

# --- Trim helpers ---
_coord_cx_ltrim() {
  local s="$1"
  # POSIX: strip leading [[:space:]] using parameter expansion
  printf '%s' "${s#"${s%%[![:space:]]*}"}"
}
_coord_cx_rtrim() {
  local s="$1"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}
_coord_cx_trim() {
  local s
  s=$(_coord_cx_ltrim "$1")
  _coord_cx_rtrim "$s"
}

# --- Internal: emit a JSON-encoded string via jq ---
# Avoids hand-rolling escape rules; jq handles control chars + unicode + quotes.
# Use printf+stdin (NOT heredoc) so bash doesn't append a trailing newline
# to every emitted string.
_coord_cx_json_str() {
  printf '%s' "$1" | jq -Rsc '.'
}

# --- Main parser: produces full AST as one JSON document on stdout ---
#
# Output shape:
# {
#   "rc": 0,
#   "paths": ["a", "b", ...],                                    # encounter order
#   "operations": [{"op": "...", "path": "...", "move_to": null|"..."}],
#   "hunks_by_path": {
#     "<path>": [
#       {"header": "...", "pre_image": "...", "post_image": "...", "is_end_of_file": false}
#     ]
#   }
# }
#
# On error: writes message to stderr, returns the error rc, no stdout.
_coord_cx_parse_ast() {
  local patch_text="$1"
  if [ -z "$patch_text" ]; then
    printf 'apply_patch_parser: empty patch\n' >&2
    return 1
  fi

  # Lenient: strip heredoc wrapping if present
  patch_text=$(_coord_cx_strip_heredoc "$patch_text")
  # CRLF normalization: strip trailing \r on each line (107)
  patch_text=$(printf '%s' "$patch_text" | sed 's/\r$//')

  # Read lines into array. The trailing \n is intentional — bash's read with
  # heredoc semantics drops a trailing empty line; that matches parser.rs's
  # behavior of `.lines()` over a `.trim()`-ed string.
  local -a lines=()
  local ln
  while IFS= read -r ln; do
    lines+=("$ln")
  done <<<"$patch_text"
  local n="${#lines[@]}"

  # State machine. State + scratch vars:
  local state="OUTSIDE"
  local current_path=""
  local current_op=""
  local current_move_to=""
  local hunk_header=""
  local hunk_is_eof=0
  local hunk_pre=""
  local hunk_post=""
  local in_hunk=0
  # Accumulators (JSONL: one record per line):
  local paths_jsonl=""
  local ops_jsonl=""
  local hunks_jsonl=""
  # Tracker so we know whether a Begin has been seen (for rc=5)
  local saw_begin=0
  local saw_end=0

  # Helper closures (inline functions): emit accumulated hunk + reset
  _flush_hunk() {
    if [ "$in_hunk" = "1" ]; then
      local hdr_j pre_j post_j path_j
      hdr_j=$(_coord_cx_json_str "$hunk_header")
      pre_j=$(_coord_cx_json_str "$hunk_pre")
      post_j=$(_coord_cx_json_str "$hunk_post")
      path_j=$(_coord_cx_json_str "$current_path")
      hunks_jsonl="$hunks_jsonl"$'\n'"{\"path\":$path_j,\"header\":$hdr_j,\"pre_image\":$pre_j,\"post_image\":$post_j,\"is_end_of_file\":$([ "$hunk_is_eof" = "1" ] && printf true || printf false)}"
      hunk_header=""
      hunk_pre=""
      hunk_post=""
      hunk_is_eof=0
      in_hunk=0
    fi
  }

  _start_hunk() {
    _flush_hunk
    hunk_header="$1"
    hunk_pre=""
    hunk_post=""
    hunk_is_eof=0
    in_hunk=1
  }

  _record_path() {
    local p_j
    p_j=$(_coord_cx_json_str "$1")
    paths_jsonl="$paths_jsonl"$'\n'"$p_j"
  }

  _record_op() {
    local op="$1" path="$2" move="$3"
    local op_j path_j move_j
    op_j=$(_coord_cx_json_str "$op")
    path_j=$(_coord_cx_json_str "$path")
    if [ -z "$move" ]; then
      move_j="null"
    else
      move_j=$(_coord_cx_json_str "$move")
    fi
    ops_jsonl="$ops_jsonl"$'\n'"{\"op\":$op_j,\"path\":$path_j,\"move_to\":$move_j}"
  }

  local i raw trimmed prefix err_rc=0 err_msg=""
  for ((i=0; i<n; i++)); do
    raw="${lines[$i]}"
    trimmed=$(_coord_cx_trim "$raw")

    case "$state" in
      OUTSIDE)
        if [ "$trimmed" = "$_CX_BEGIN_MARKER" ]; then
          state="INSIDE"
          saw_begin=1
        fi
        # Tolerate blank lines / non-marker preamble (lenient); ignore.
        ;;

      INSIDE)
        if [ "$trimmed" = "$_CX_END_MARKER" ]; then
          _flush_hunk
          state="END"
          saw_end=1
        elif [ "${trimmed#"$_CX_ADD_PREFIX"}" != "$trimmed" ]; then
          _flush_hunk
          current_path="${trimmed#"$_CX_ADD_PREFIX"}"
          current_op="add"
          current_move_to=""
          _record_path "$current_path"
          _record_op "add" "$current_path" ""
          state="IN_ADDFILE"
        elif [ "${trimmed#"$_CX_DELETE_PREFIX"}" != "$trimmed" ]; then
          _flush_hunk
          current_path="${trimmed#"$_CX_DELETE_PREFIX"}"
          current_op="delete"
          current_move_to=""
          _record_path "$current_path"
          _record_op "delete" "$current_path" ""
          # Stay in INSIDE — delete has no body.
        elif [ "${trimmed#"$_CX_UPDATE_PREFIX"}" != "$trimmed" ]; then
          _flush_hunk
          current_path="${trimmed#"$_CX_UPDATE_PREFIX"}"
          current_op="update"
          current_move_to=""
          _record_path "$current_path"
          _record_op "update" "$current_path" ""
          state="IN_UPDATEFILE"
        elif [ -z "$trimmed" ]; then
          : # skip blank lines between ops
        else
          err_rc=2
          err_msg="line $((i+1)): invalid file-op marker: '$trimmed'"
          break
        fi
        ;;

      IN_ADDFILE)
        # Accumulate +-prefixed lines until we hit something else.
        # NOTE: only an UNTRIMMED line starting with `+` qualifies — leading
        # whitespace would be content. Use raw line, not trimmed.
        if [ "${raw:0:1}" = "+" ]; then
          # Stash content verbatim into hunk_post (post_image of an add IS
          # the file body; pre_image stays empty). Wrap as pseudo-hunk so
          # downstream code can fetch via hunks_by_path uniformly.
          if [ "$in_hunk" = "0" ]; then
            _start_hunk ""
          fi
          if [ -z "$hunk_post" ]; then
            hunk_post="${raw:1}"
          else
            hunk_post="$hunk_post"$'\n'"${raw:1}"
          fi
        elif [ "$trimmed" = "$_CX_END_MARKER" ]; then
          _flush_hunk
          state="END"
          saw_end=1
        elif [ "${trimmed#"$_CX_ADD_PREFIX"}" != "$trimmed" ] || \
             [ "${trimmed#"$_CX_DELETE_PREFIX"}" != "$trimmed" ] || \
             [ "${trimmed#"$_CX_UPDATE_PREFIX"}" != "$trimmed" ]; then
          _flush_hunk
          state="INSIDE"
          # Re-process this line in INSIDE state by decrementing i.
          i=$((i - 1))
        else
          err_rc=4
          err_msg="line $((i+1)): unexpected line in Add File body: '$trimmed'"
          break
        fi
        ;;

      IN_UPDATEFILE)
        # Look for optional Move to:, then a hunk header (@@), or another
        # file-op, or End Patch.
        if [ "${trimmed#"$_CX_MOVE_PREFIX"}" != "$trimmed" ]; then
          current_move_to="${trimmed#"$_CX_MOVE_PREFIX"}"
          # Move emits an additional path so D-12 alphabetical lock covers
          # both source and destination.
          _record_path "$current_move_to"
          # Re-record the update op WITH move_to (the earlier _record_op
          # had move_to="" — patch the JSONL line in-place).
          # Simpler: pop the last op, re-emit. Use sed on the accumulated
          # JSONL string.
          ops_jsonl=$(printf '%s' "$ops_jsonl" | sed '$d')
          _record_op "update" "$current_path" "$current_move_to"
        elif [ "$trimmed" = "$_CX_HUNK_HEADER_BARE" ]; then
          _start_hunk ""
          state="IN_HUNK"
        elif [ "${trimmed#"$_CX_HUNK_HEADER_PREFIX"}" != "$trimmed" ]; then
          _start_hunk "${trimmed#"$_CX_HUNK_HEADER_PREFIX"}"
          state="IN_HUNK"
        elif [ "$trimmed" = "$_CX_END_MARKER" ]; then
          # Update File without any hunk → empty hunk error (008)
          if [ -z "$current_move_to" ]; then
            err_rc=3
            err_msg="line $((i+1)): empty update hunk for '$current_path'"
            break
          fi
          _flush_hunk
          state="END"
          saw_end=1
        elif [ "${trimmed#"$_CX_ADD_PREFIX"}" != "$trimmed" ] || \
             [ "${trimmed#"$_CX_DELETE_PREFIX"}" != "$trimmed" ] || \
             [ "${trimmed#"$_CX_UPDATE_PREFIX"}" != "$trimmed" ]; then
          # Next file-op without any hunk → empty hunk
          if [ -z "$current_move_to" ]; then
            err_rc=3
            err_msg="line $((i+1)): empty update hunk for '$current_path'"
            break
          fi
          state="INSIDE"
          i=$((i - 1))
        elif [ -z "$trimmed" ]; then
          : # skip blank lines
        else
          err_rc=2
          err_msg="line $((i+1)): expected '@@' or '*** Move to:' in Update block, got: '$trimmed'"
          break
        fi
        ;;

      IN_HUNK)
        # Accumulate change_lines (` `, `+`, `-`) until next hunk / file-op
        # / End Patch / End of File. Use raw line (NOT trimmed) for content
        # because leading whitespace IS content.
        local first_char="${raw:0:1}"
        if [ "$trimmed" = "$_CX_HUNK_HEADER_BARE" ]; then
          _start_hunk ""
          # state stays IN_HUNK (we're starting a new hunk)
        elif [ "${trimmed#"$_CX_HUNK_HEADER_PREFIX"}" != "$trimmed" ]; then
          _start_hunk "${trimmed#"$_CX_HUNK_HEADER_PREFIX"}"
          # state stays IN_HUNK
        elif [ "$trimmed" = "$_CX_EOF_MARKER" ]; then
          hunk_is_eof=1
        elif [ "$trimmed" = "$_CX_END_MARKER" ]; then
          _flush_hunk
          state="END"
          saw_end=1
        elif [ "${trimmed#"$_CX_ADD_PREFIX"}" != "$trimmed" ] || \
             [ "${trimmed#"$_CX_DELETE_PREFIX"}" != "$trimmed" ] || \
             [ "${trimmed#"$_CX_UPDATE_PREFIX"}" != "$trimmed" ]; then
          _flush_hunk
          state="INSIDE"
          i=$((i - 1))
        elif [ "$first_char" = " " ]; then
          # Context line — kept in pre AND post
          local content="${raw:1}"
          if [ -z "$hunk_pre" ]; then hunk_pre="$content"; else hunk_pre="$hunk_pre"$'\n'"$content"; fi
          if [ -z "$hunk_post" ]; then hunk_post="$content"; else hunk_post="$hunk_post"$'\n'"$content"; fi
        elif [ "$first_char" = "-" ]; then
          local content="${raw:1}"
          if [ -z "$hunk_pre" ]; then hunk_pre="$content"; else hunk_pre="$hunk_pre"$'\n'"$content"; fi
        elif [ "$first_char" = "+" ]; then
          local content="${raw:1}"
          if [ -z "$hunk_post" ]; then hunk_post="$content"; else hunk_post="$hunk_post"$'\n'"$content"; fi
        elif [ -z "$raw" ]; then
          # Empty line within a hunk: per parser.rs:410-413, treated as empty
          # content in both pre and post.
          if [ -z "$hunk_pre" ]; then hunk_pre=""; else hunk_pre="$hunk_pre"$'\n'; fi
          if [ -z "$hunk_post" ]; then hunk_post=""; else hunk_post="$hunk_post"$'\n'; fi
        else
          err_rc=4
          err_msg="line $((i+1)): unexpected hunk content prefix: '$first_char' in line '$raw'"
          break
        fi
        ;;

      END)
        # Anything after End Patch is tolerated (trailing whitespace etc).
        ;;
    esac
  done

  # Post-loop validation
  if [ "$err_rc" != "0" ]; then
    printf 'apply_patch_parser: %s\n' "$err_msg" >&2
    return "$err_rc"
  fi
  if [ "$saw_begin" = "0" ] || [ "$saw_end" = "0" ]; then
    printf 'apply_patch_parser: missing %s marker\n' \
      "$([ "$saw_begin" = "0" ] && printf 'Begin Patch' || printf 'End Patch')" >&2
    return 5
  fi
  # Empty patch (Begin Patch immediately followed by End Patch with no ops)
  if [ -z "$paths_jsonl" ]; then
    printf 'apply_patch_parser: empty patch (no operations)\n' >&2
    return 1
  fi

  # Assemble final JSON. paths_jsonl, ops_jsonl, hunks_jsonl all start with
  # an extra newline; jq's --slurpfile / inputs handle that fine.
  local paths_json ops_json hunks_grouped
  paths_json=$(printf '%s\n' "$paths_jsonl" | sed '/^$/d' | jq -sc '.')
  ops_json=$(printf '%s\n' "$ops_jsonl" | sed '/^$/d' | jq -sc '.')
  # hunks_jsonl: list of {path, header, pre_image, post_image, is_end_of_file}.
  # Group by path into the expected map shape, dropping the per-hunk path key.
  hunks_grouped=$(printf '%s\n' "$hunks_jsonl" | sed '/^$/d' \
    | jq -sc 'group_by(.path) | map({(.[0].path): map({header,pre_image,post_image,is_end_of_file})}) | add // {}')

  jq -nc \
    --argjson paths "$paths_json" \
    --argjson ops "$ops_json" \
    --argjson hunks "$hunks_grouped" \
    '{rc: 0, paths: $paths, operations: $ops, hunks_by_path: $hunks}'
}

# --- Public functions: convenience wrappers over _coord_cx_parse_ast ---

coord_cx_apply_patch_paths() {
  local ast
  ast=$(_coord_cx_parse_ast "${1:-}") || return $?
  printf '%s' "$ast" | jq -r '.paths[]'
}

coord_cx_apply_patch_operations() {
  local ast
  ast=$(_coord_cx_parse_ast "${1:-}") || return $?
  printf '%s' "$ast" | jq -r '.operations[] | "\(.op)\t\(.path)\t\(.move_to // "")"'
}

coord_cx_apply_patch_hunks() {
  local ast
  ast=$(_coord_cx_parse_ast "${1:-}") || return $?
  printf '%s' "$ast" | jq -c --arg p "${2:-}" '.hunks_by_path[$p] // []'
}

coord_cx_apply_patch_pre_image() {
  local ast
  ast=$(_coord_cx_parse_ast "${1:-}") || return $?
  printf '%s' "$ast" | jq -r --arg p "${2:-}" '
    (.hunks_by_path[$p] // [])
    | map(.pre_image)
    | join("")
  '
}

coord_cx_apply_patch_pre_image_hash() {
  local pre
  pre=$(coord_cx_apply_patch_pre_image "${1:-}" "${2:-}") || return $?
  printf '%s' "$pre" | _coord_cx_sha256_hex
}

coord_cx_apply_patch_edit_range() {
  # Best-effort line range from @@ headers. Phase A: returns 0\t0 since
  # @@ context labels don't carry line numbers in the Codex grammar.
  # Hooks compute disk-side ranges separately.
  local ast
  ast=$(_coord_cx_parse_ast "${1:-}") || return $?
  printf '0\t0'
}

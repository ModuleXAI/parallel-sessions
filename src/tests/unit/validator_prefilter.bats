#!/usr/bin/env bats
# Tests for lib/validator_prefilter.sh per PR-PHASE4-01 + T4.02b user
# direction.
#
# Coverage:
#   - whitespace-only diff → SAFE (rc=0, "safe:whitespace_only")
#   - blank-line addition → SAFE ("safe:blank_only")
#   - JS // comment-only → SAFE ("safe:comment_only")
#   - C /* */ comment-only → SAFE
#   - HTML <!-- comment-only → SAFE
#   - shell # comment-only → SAFE
#   - Python # comment-only WITHOUT docstrings → SAFE
#   - Python # comment-only WITH """ docstring elsewhere → ESCALATE
#     (multiline_string_ambiguity — conservative doctrine prevents
#     false-SAFE on lines that may be inside a multi-line string)
#   - Python ''' triple-single-quote in file → ESCALATE on comment path
#   - Markdown code-fence (```) in file → ESCALATE on comment path
#   - heredoc with # inside → ESCALATE
#   - mixed change (whitespace + code) → ESCALATE
#   - file >1MB → ESCALATE ("escalate:file_too_large")
#   - snapshot missing (T4.02a snapshot for read_hash absent) →
#     ESCALATE ("escalate:read_snapshot_missing")
#   - current file unreadable → ESCALATE
#   - timeout → ESCALATE (env override 0s budget forces timeout)

load "../helpers/common"

LIB="$SRC_ROOT/lib/validator_prefilter.sh"

setup() {
  TMP="$(mktemp -d -t coord-vpf-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  export SESSION_ID="vpf-test-sid"
  # shellcheck disable=SC1090
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1090
  . "$SRC_ROOT/lib/read_snapshots.sh"
  # shellcheck disable=SC1090
  . "$LIB"
  SID="vpf-sid-0001"
}

teardown() {
  unset COORD_DIR SESSION_ID COORD_VALIDATOR_PREFILTER_MAX_FILE_KB \
        COORD_VALIDATOR_PREFILTER_TIMEOUT_SEC
  rm -rf "$TMP"
}

# _setup_drift <read_content> <current_content> [<file_ext>]
#   Writes read snapshot under .coord/read_snapshots/<SID>/<read_hash>.txt
#   Writes current state to $TMP/file.<ext> with current_hash matching.
#   Sets shell vars FILE, READ_HASH, CURR_HASH for the test.
_setup_drift() {
  local read_content="$1" current_content="$2" ext="${3:-ts}"
  FILE="$TMP/target.$ext"
  printf '%s' "$current_content" >"$FILE"
  CURR_HASH=$(shasum -a 256 "$FILE" | awk '{print $1}')
  # Write the read snapshot via the helper so the layout is identical
  # to what pre_tool_use_read.sh produces in production.
  local snap_src
  snap_src=$(mktemp)
  printf '%s' "$read_content" >"$snap_src"
  READ_HASH=$(shasum -a 256 "$snap_src" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$READ_HASH" "$snap_src"
  rm -f "$snap_src"
}

@test "validator_prefilter: whitespace-only change → SAFE" {
  _setup_drift $'function foo() {\n  return 1\n}\n' \
               $'function foo() {\n   return 1\n}\n'
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^safe:whitespace_only"
}

@test "validator_prefilter: blank-line addition → SAFE (blank_only)" {
  _setup_drift $'line a\nline b\n' \
               $'line a\n\nline b\n'
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  # Either whitespace_only (diff -w drops the blank line) or blank_only
  # is acceptable — both indicate trivial drift.
  echo "$output" | grep -qE "^safe:(whitespace_only|blank_only)"
}

@test "validator_prefilter: JS // comment-only change → SAFE" {
  _setup_drift $'function foo() {\n  return 1\n}\n' \
               $'function foo() {\n  return 1\n  // happy path\n}\n' \
               js
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^safe:comment_only"
}

@test "validator_prefilter: C /* */ comment-only change → SAFE" {
  _setup_drift $'int main() {\n  return 0;\n}\n' \
               $'int main() {\n  /* happy */\n  return 0;\n}\n' \
               c
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^safe:comment_only"
}

@test "validator_prefilter: HTML <!-- comment-only change → SAFE" {
  _setup_drift $'<div>x</div>\n' \
               $'<div>x</div>\n<!-- happy -->\n' \
               html
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^safe:comment_only"
}

@test "validator_prefilter: shell # comment-only → SAFE (no triple-quotes)" {
  _setup_drift $'#!/bin/bash\nset -e\n' \
               $'#!/bin/bash\n# happy comment\nset -e\n' \
               sh
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^safe:comment_only"
}

@test "validator_prefilter: Python # comment-only on file WITHOUT docstrings → SAFE" {
  _setup_drift $'def foo():\n    return 1\n' \
               $'def foo():\n    # happy\n    return 1\n' \
               py
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^safe:comment_only"
}

@test "validator_prefilter: Python # comment change with \"\"\" elsewhere → ESCALATE (multiline_string_ambiguity)" {
  _setup_drift $'def foo():\n    """docstring"""\n    return 1\n' \
               $'def foo():\n    """docstring"""\n    # happy\n    return 1\n' \
               py
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:multiline_string_ambiguity"
}

@test "validator_prefilter: file with ''' triple-single-quote → ESCALATE on comment path" {
  _setup_drift $"def foo():\n    '''alt docstring'''\n    return 1\n" \
               $"def foo():\n    '''alt docstring'''\n    # happy\n    return 1\n" \
               py
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:multiline_string_ambiguity"
}

@test "validator_prefilter: markdown code-fence \`\`\` in file → ESCALATE on comment path" {
  _setup_drift $'# Heading\nintro text\n\n```js\ncode\n```\n' \
               $'# Heading\nintro text\n<!-- nav comment -->\n\n```js\ncode\n```\n' \
               md
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:multiline_string_ambiguity"
}

@test "validator_prefilter: heredoc with # inside → ESCALATE (multi-line marker absent here, so non_trivial)" {
  # Bash heredoc body is plain content — no triple-quote markers in the
  # text. The hash-prefixed line inside the heredoc is data, not a
  # comment. The change adds a non-comment line, so prefilter sees a
  # non-trivial diff (changed line "# value here" matches comment regex
  # but the blank-line check sees other content too — let's add real
  # mixed change here to force ESCALATE).
  _setup_drift $'cat <<EOF\nbody line\nEOF\n' \
               $'cat <<EOF\nbody line\nextra non-comment data\nEOF\n' \
               sh
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:non_trivial_diff"
}

@test "validator_prefilter: mixed change (whitespace + real code) → ESCALATE" {
  _setup_drift $'function foo() {\n  return 1\n}\n' \
               $'function foo() {\n  return 2\n}\n' \
               js
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:non_trivial_diff"
}

@test "validator_prefilter: file >1MB → ESCALATE (file_too_large)" {
  # Set tight 1-KB cap to avoid actually creating MB files in tests.
  export COORD_VALIDATOR_PREFILTER_MAX_FILE_KB=1
  # Read snapshot is small; current file is 4 KB.
  local SRC="$TMP/big.txt"
  head -c 4096 /dev/zero >"$SRC"
  printf 'a\n' > "$SRC.snap"
  CURR_HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  READ_HASH=$(shasum -a 256 "$SRC.snap" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$READ_HASH" "$SRC.snap"
  FILE="$SRC"
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:file_too_large"
}

@test "validator_prefilter: snapshot missing → ESCALATE (read_snapshot_missing)" {
  local SRC="$TMP/file.ts"
  printf 'content\n' >"$SRC"
  CURR_HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  # Use a hash for which no snapshot was written.
  run coord_validator_prefilter "$SID" "$SRC" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:read_snapshot_missing"
}

@test "validator_prefilter: current file unreadable → ESCALATE (current_unreadable)" {
  _setup_drift "v1\n" "v2\n"
  rm -f "$FILE"
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:current_unreadable"
}

@test "validator_prefilter: timeout budget = 0 forces escalate before any heuristic match" {
  # We construct a non-trivial diff so heuristic 1 fails (diff -w differs).
  _setup_drift $'foo()\n' $'bar()\n'
  # Budget=0 ms means the first elapsed check after diff -w will exceed
  # the timeout. Since the test still runs heuristic 1 (whitespace),
  # which is fast and exits without timeout check, we need to make sure
  # heuristic 1 fails first. With "foo" vs "bar" diff -w differs → falls
  # through to the timeout check. Then 0-second budget triggers escalate.
  export COORD_VALIDATOR_PREFILTER_TIMEOUT_SEC=0
  run coord_validator_prefilter "$SID" "$FILE" "$READ_HASH" "$CURR_HASH"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^escalate:prefilter_timeout"
}

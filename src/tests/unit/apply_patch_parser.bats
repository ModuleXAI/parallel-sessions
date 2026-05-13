#!/usr/bin/env bats
# Tests for src/adapters/codex/lib/apply_patch_parser.sh — PR C.2.
#
# One @test per fixture. Each test:
#   - positive: diffs parser-emitted AST against expected.json, then
#     additionally computes sha256(pre_image-from-expected) and compares
#     against parser's coord_cx_apply_patch_pre_image_hash output (per
#     F-C2-02 — proves pre_image extraction AND hashing are both correct).
#   - negative: runs parser, expects a specific rc + stderr substring.
#
# Generated programmatically (one @test per fixture in src/adapters/codex/
# tests/fixtures/apply_patch/), so adding a new fixture means adding a new
# directory and re-running the generator. The generator is a tiny python
# script kept under PR C.2 commit notes.

load "../helpers/common"

setup() {
  PARSER_LIB="$SRC_ROOT/adapters/codex/lib/apply_patch_parser.sh"
  FIXTURE_DIR="$SRC_ROOT/adapters/codex/tests/fixtures/apply_patch"
  # shellcheck disable=SC1091
  . "$PARSER_LIB"
}

# _sha256_from_expected <path-to-expected.json> <fixture-path>
# Read expected.hunks_by_path[<path>], concatenate pre_image fields, and
# print sha256 hex. Mirrors what coord_cx_apply_patch_pre_image_hash does
# but uses expected.json as the source of truth, NOT the parser. Test
# helper-vs-parser divergence on EITHER pre_image extraction OR hashing
# fires here.
_sha256_from_expected() {
  local exp="$1" path="$2"
  # Parser uses $(jq -r ...) which strips jq's trailing newline before
  # hashing. Helper must mirror that — capture into a var via $(...) so
  # the trailing newline is stripped, then printf+pipe to sha256. Without
  # this, helper hashes "<text>\n" while parser hashes "<text>" → spurious
  # diff per F-C2-02 contract review.
  local pre
  pre=$(jq -r --arg p "$path" '
    (.hunks_by_path[$p] // [])
    | map(.pre_image)
    | join("")
  ' "$exp")
  printf '%s' "$pre" | _coord_cx_sha256_hex
}

# _assert_positive <fixture-name>
# Generic positive-fixture comparison. Diffs parser AST against expected,
# then verifies per-path pre_image_hash.
_assert_positive() {
  local f="$1"
  local patch expected actual
  patch=$(cat "$FIXTURE_DIR/$f/patch.txt")
  expected="$FIXTURE_DIR/$f/expected.json"
  actual=$(_coord_cx_parse_ast "$patch")     || { echo "parser failed on $f"; return 1; }
  # Compare sorted-keys JSON for stable diff.
  diff <(jq -S . <<<"$actual") <(jq -S . "$expected")     || { echo "AST mismatch for $f"; return 1; }
  # Hash check per-path (F-C2-02).
  local p exp_hash got_hash
  while IFS= read -r p; do
    exp_hash=$(_sha256_from_expected "$expected" "$p")
    got_hash=$(coord_cx_apply_patch_pre_image_hash "$patch" "$p")       || { echo "pre_image_hash failed on $f path=$p"; return 1; }
    [ "$exp_hash" = "$got_hash" ]       || { echo "hash mismatch for $f path=$p exp=$exp_hash got=$got_hash"; return 1; }
  done < <(jq -r '.paths[]' "$expected")
}

# _assert_negative <fixture-name>
# Generic negative-fixture comparison. Runs parser, expects expected.rc
# and a stderr message containing expected.stderr_substr.
_assert_negative() {
  local f="$1"
  local patch exp_rc exp_substr stderr_out actual_rc=0
  patch=$(cat "$FIXTURE_DIR/$f/patch.txt")
  exp_rc=$(jq -r '.rc' "$FIXTURE_DIR/$f/expected.json")
  exp_substr=$(jq -r '.stderr_substr' "$FIXTURE_DIR/$f/expected.json")
  # Bats enables `set -e` inside @test functions, which would abort on the
  # parser's non-zero rc before $? could be captured on the next line.
  # The `|| actual_rc=$?` idiom keeps the rc inside the test and prevents
  # the abort.
  stderr_out=$(_coord_cx_parse_ast "$patch" 2>&1 >/dev/null) || actual_rc=$?
  [ "$actual_rc" = "$exp_rc" ]     || { echo "rc mismatch for $f: expected $exp_rc, got $actual_rc"; return 1; }
  echo "$stderr_out" | grep -qF "$exp_substr"     || { echo "stderr missing substring '$exp_substr' for $f. Got: $stderr_out"; return 1; }
}

@test "apply_patch_parser (positive): 001_add_file" {
  _assert_positive "001_add_file"
}

@test "apply_patch_parser (positive): 002_multiple_operations" {
  _assert_positive "002_multiple_operations"
}

@test "apply_patch_parser (positive): 003_multiple_chunks" {
  _assert_positive "003_multiple_chunks"
}

@test "apply_patch_parser (positive): 004_move_to_new_directory" {
  _assert_positive "004_move_to_new_directory"
}

@test "apply_patch_parser (negative): 005_rejects_empty_patch" {
  _assert_negative "005_rejects_empty_patch"
}

@test "apply_patch_parser (negative): 008_rejects_empty_update_hunk" {
  _assert_negative "008_rejects_empty_update_hunk"
}

@test "apply_patch_parser (negative): 013_rejects_invalid_hunk_header" {
  _assert_negative "013_rejects_invalid_hunk_header"
}

@test "apply_patch_parser (positive): 016_pure_addition_update_chunk" {
  _assert_positive "016_pure_addition_update_chunk"
}

@test "apply_patch_parser (positive): 017_whitespace_padded_hunk_header" {
  _assert_positive "017_whitespace_padded_hunk_header"
}

@test "apply_patch_parser (positive): 018_whitespace_padded_patch_markers" {
  _assert_positive "018_whitespace_padded_patch_markers"
}

@test "apply_patch_parser (positive): 019_unicode_simple" {
  _assert_positive "019_unicode_simple"
}

@test "apply_patch_parser (positive): 020_delete_file_success" {
  _assert_positive "020_delete_file_success"
}

@test "apply_patch_parser (positive): 020_whitespace_padded_patch_marker_lines" {
  _assert_positive "020_whitespace_padded_patch_marker_lines"
}

@test "apply_patch_parser (positive): 022_update_file_end_of_file_marker" {
  _assert_positive "022_update_file_end_of_file_marker"
}

@test "apply_patch_parser (positive): 100_single_hunk_update" {
  _assert_positive "100_single_hunk_update"
}

@test "apply_patch_parser (positive): 101_context_only_no_changes" {
  _assert_positive "101_context_only_no_changes"
}

@test "apply_patch_parser (positive): 102_lenient_heredoc" {
  _assert_positive "102_lenient_heredoc"
}

@test "apply_patch_parser (negative): 103_missing_end_patch" {
  _assert_negative "103_missing_end_patch"
}

@test "apply_patch_parser (negative): 104_malformed_hunk_content" {
  _assert_negative "104_malformed_hunk_content"
}

@test "apply_patch_parser (positive): 105_adversarial_at_in_add_line" {
  _assert_positive "105_adversarial_at_in_add_line"
}

@test "apply_patch_parser (positive): 106_adversarial_stars_in_add_line" {
  _assert_positive "106_adversarial_stars_in_add_line"
}

@test "apply_patch_parser (positive): 107_adversarial_crlf" {
  _assert_positive "107_adversarial_crlf"
}

@test "apply_patch_parser (positive): 108_adversarial_trailing_whitespace_end_patch" {
  _assert_positive "108_adversarial_trailing_whitespace_end_patch"
}

@test "apply_patch_parser (positive): 109_multi_hunk_pre_image" {
  _assert_positive "109_multi_hunk_pre_image"
}


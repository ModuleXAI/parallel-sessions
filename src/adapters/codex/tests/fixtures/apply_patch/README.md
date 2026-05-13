# apply_patch parser fixtures

Test inputs + expected outputs for `src/adapters/codex/lib/apply_patch_parser.sh`
(PR C.2). Each fixture is one directory containing:

- `patch.txt` — input patch text fed to the parser
- `expected.json` — expected parser output (positive fixtures) OR expected
  error shape (negative fixtures)

The bats helper at `src/tests/unit/apply_patch_parser.bats` iterates every
directory below this one, runs the parser against `patch.txt`, and diffs the
result against `expected.json`. Per F-C2-02 the helper computes
`sha256(pre_image)` at test time rather than reading a baked-in hash from
`expected.json` — this catches both "wrong pre_image extraction" AND
"wrong hashing algorithm" with one assertion.

---

## ID map

Two namespaces:

- **000-099 — verbatim from codex-ref-repo** (preserved IDs so future
  upstream regression checks correlate by directory name; one-to-one byte
  match against the upstream patch.txt).
- **100+ — synthesized / adversarial fixtures** added by this project for
  coverage gaps the upstream suite doesn't address.

### Verbatim from upstream (14 fixtures)

| ID | Name | Category |
|---|---|---|
| 001 | `001_add_file` | A — happy path single op |
| 002 | `002_multiple_operations` | C — multi-file multi-op |
| 003 | `003_multiple_chunks` | B — multi-hunk single file |
| 004 | `004_move_to_new_directory` | A — happy path single op (update + move) |
| 005 | `005_rejects_empty_patch` | H — negative |
| 008 | `008_rejects_empty_update_hunk` | H — negative |
| 013 | `013_rejects_invalid_hunk_header` | H — negative |
| 016 | `016_pure_addition_update_chunk` | D — hunk content variants (empty pre-image) |
| 017 | `017_whitespace_padded_hunk_header` | E — whitespace tolerance |
| 018 | `018_whitespace_padded_patch_markers` | E — whitespace tolerance |
| 019 | `019_unicode_simple` | F — unicode |
| 020 | `020_delete_file_success` | A — happy path single op (delete) |
| 020 | `020_whitespace_padded_patch_marker_lines` | E — whitespace tolerance |
| 022 | `022_update_file_end_of_file_marker` | D — hunk content variants (`*** End of File`) |

**Note on the 020 collision:** upstream has TWO directories sharing numeric
prefix 020. Bats discriminates by full directory name, so both are kept
verbatim. Dropping either would break upstream-regression-check correlation.

### Hand-rolled (10 fixtures)

| ID | Name | Category | Why |
|---|---|---|---|
| 100 | `100_single_hunk_update` | A | Smallest possible Update File pattern (1 hunk, 1 changed line); upstream has nothing this minimal |
| 101 | `101_context_only_no_changes` | D | Hunk that's all ` ` context, no `+`/`-`; pre-image == post-image, hash should be of context content |
| 102 | `102_lenient_heredoc` | G | `<<'EOF'` heredoc-wrapped patch (gpt-4.1 quirk; ports `parser.rs:135-172` lenient mode) |
| 103 | `103_missing_end_patch` | H | Patch without `*** End Patch` terminator → rc 5 |
| 104 | `104_malformed_hunk_content` | H | Hunk body line with unexpected prefix (literal `*` not under `***`); F-C2-03 — without this, rc 4 is unreachable |
| 105 | `105_adversarial_at_in_add_line` | I | `+@@ trick` in an Add File body — must NOT be parsed as hunk header (state-machine prefix-match guarantee) |
| 106 | `106_adversarial_stars_in_add_line` | I | `+*** Update File: oops` in an Add File body — must NOT be parsed as new file-op |
| 107 | `107_adversarial_crlf` | I | CRLF line endings instead of LF — parser must trim or reject cleanly |
| 108 | `108_adversarial_trailing_whitespace_end_patch` | I | `*** End Patch  ` (trailing spaces) — should be trimmed and accepted |
| 109 | `109_multi_hunk_pre_image` | J | 2 hunks, distinct pre-images — D.4 drift gate consumes per-hunk hashes; this fixture validates the hash-per-hunk contract |

---

## Final count: 24 fixtures

(Design preview said "22" — that was a counting error; the breakdown table
in the preview actually summed to 23. With F-C2-03 added the real total is
24. Logged as F-C2-04 for transparency; no plan amendment needed since the
category structure is unchanged.)

---

## Adversarial coverage

Category I (4 fixtures) was added per D-C2-01 plan amendment. Without
fixtures 105-108 the state machine's prefix-matching guarantee — that
`*** ...` and `@@` are only recognized as control markers when they appear
at the start of a line in the right state — is documented but untested.
Each adversarial fixture forces the parser to encounter the marker text
inside a `+`-prefixed line body, where it MUST be treated as literal content.

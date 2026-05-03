#!/usr/bin/env bats
# Tests for src/core/lib/folder_resolver.sh — Phase A PR A.5.
#
# Verifies the 5-step coord_resolve_root algorithm: COORD_DIR env >
# walk-up from cwd > walk-up from BASH_SOURCE > legacy CLAUDE_PROJECT_DIR
# > git fallback.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-fr-XXXX)"
  # Build a nested project structure:
  #   $TMP/proj/
  #     .coord/                 ← target
  #     sub/
  #       deeper/
  unset COORD_DIR CLAUDE_PROJECT_DIR
  mkdir -p "$TMP/proj/.coord"
  mkdir -p "$TMP/proj/sub/deeper"
  mkdir -p "$TMP/notproj"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/folder_resolver.sh"
}
teardown() { rm -rf "$TMP"; }

@test "folder_resolver: step 1 — COORD_DIR env wins over everything" {
  export COORD_DIR="$TMP/proj/.coord"
  cd "$TMP/notproj"
  run coord_resolve_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: step 1 — empty COORD_DIR falls through" {
  export COORD_DIR=""
  cd "$TMP/proj/sub/deeper"
  run coord_resolve_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: step 1 — COORD_DIR pointing to non-existent dir falls through" {
  export COORD_DIR="$TMP/nonexistent"
  cd "$TMP/proj"
  run coord_resolve_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: step 2 — cwd-walk-up finds .coord/ in parent" {
  cd "$TMP/proj/sub/deeper"
  run coord_resolve_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: step 2 — cwd-walk-up finds .coord/ in current dir" {
  cd "$TMP/proj"
  run coord_resolve_root
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: step 2 — explicit \$1 overrides cwd" {
  cd "$TMP/notproj"
  run coord_resolve_root "$TMP/proj/sub"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: step 4 — CLAUDE_PROJECT_DIR consulted on direct check" {
  # Step 2 walks up from CLAUDE_PROJECT_DIR by default, so step 4's
  # explicit branch only kicks in when $1 is passed AND points
  # somewhere without .coord/. Use the explicit-arg branch.
  export CLAUDE_PROJECT_DIR="$TMP/proj"
  cd "$TMP/notproj"
  # Pass an explicit cwd that has no .coord/ in its tree to bypass step 2.
  run coord_resolve_root "$TMP/notproj"
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/proj/.coord" ]
}

@test "folder_resolver: returns rc 1 when no .coord/ anywhere" {
  unset CLAUDE_PROJECT_DIR
  cd "$TMP/notproj"
  # Also need to defeat step 5 (git fallback). $TMP itself is not a git
  # repo (mktemp -d), so git rev-parse should fail or return outside-tree.
  run coord_resolve_root "$TMP/notproj"
  [ "$status" -eq 1 ]
}

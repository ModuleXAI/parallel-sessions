#!/usr/bin/env bats
# Integration tests for the A.5 non-git install path.
#
# Verifies that `bash src/install.sh --yes` works inside a directory
# that is NOT a git repository, creates .coord/ correctly, skips the
# .gitignore step gracefully, and that hooks resolve .coord/ via the
# new folder_resolver.sh (no git rev-parse required).

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-nogit-XXXX)"
  unset COORD_DIR CLAUDE_PROJECT_DIR CLAUDE_COORD
}
teardown() { rm -rf "$TMP"; }

@test "non-git install: bash install.sh --yes creates .coord/ outside git" {
  cd "$TMP"
  # Sanity: $TMP is NOT a git repo.
  run git rev-parse --show-toplevel
  [ "$status" -ne 0 ]
  # Run installer non-interactively.
  run bash "$SRC_ROOT/install.sh" --yes
  [ "$status" -eq 0 ] || { echo "install failed: $output"; return 1; }
  # .coord/ tree exists.
  [ -d "$TMP/.coord" ]
  [ -d "$TMP/.coord/lib" ]
  [ -d "$TMP/.coord/hooks" ]
  [ -x "$TMP/.coord/bin/coord" ]
  # .gitignore was NOT created (no git repo, no pre-existing .gitignore).
  [ ! -f "$TMP/.gitignore" ]
}

@test "non-git install: hooks resolve .coord/ via folder_resolver (no git)" {
  cd "$TMP"
  bash "$SRC_ROOT/install.sh" --yes >/dev/null 2>&1 || { echo "install failed"; return 1; }
  # Sanity: still no git.
  run git -C "$TMP" rev-parse --show-toplevel
  [ "$status" -ne 0 ]
  # Source folder_resolver and confirm it locates .coord from $TMP.
  run bash -c "
    cd '$TMP'
    unset COORD_DIR CLAUDE_PROJECT_DIR
    . '$SRC_ROOT/core/lib/folder_resolver.sh'
    coord_resolve_root
  "
  [ "$status" -eq 0 ]
  [ "$output" = "$TMP/.coord" ]
}

@test "non-git install: install.sh prints 'no git repo detected' banner" {
  cd "$TMP"
  run bash "$SRC_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'no git repo detected'
}

@test "non-git install: pre-existing .gitignore is honored even without git" {
  cd "$TMP"
  # Create a .gitignore manually (e.g., user uses other VCS or git is
  # planned). Installer should still append entries.
  : >"$TMP/.gitignore"
  run bash "$SRC_ROOT/install.sh" --yes
  [ "$status" -eq 0 ]
  grep -qxF '.coord/' "$TMP/.gitignore"
}

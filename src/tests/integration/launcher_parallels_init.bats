#!/usr/bin/env bats
# Tests for bin/parallels-init — PR B.2.
# Verifies the launcher is a thin pass-through to src/install.sh and that
# .coord/ ends up in the launcher's working directory.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-pi-XXXX)"
  unset COORD_DIR CLAUDE_PROJECT_DIR CLAUDE_COORD COORD_ENABLED
}
teardown() { rm -rf "$TMP"; }

@test "parallels-init: --yes succeeds in a non-git tempdir + creates .coord/" {
  cd "$TMP"
  run "$SRC_ROOT/../bin/parallels-init" --yes
  [ "$status" -eq 0 ] || { echo "init failed: $output"; return 1; }
  [ -d "$TMP/.coord" ]
  [ -d "$TMP/.coord/lib" ]
  [ -d "$TMP/.coord/hooks" ]
  [ -x "$TMP/.coord/bin/coord" ]
}

@test "parallels-init: forwards --help verbatim" {
  run "$SRC_ROOT/../bin/parallels-init" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'usage: install.sh'
}

@test "parallels-init: rejects unknown flag (delegates to install.sh)" {
  cd "$TMP"
  run "$SRC_ROOT/../bin/parallels-init" --not-a-real-flag
  [ "$status" -ne 0 ]
}

#!/usr/bin/env bats
# Tests for bin/parallels-status — PR B.2.
# Verifies the status launcher is an alias for `coord status`.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-ps-XXXX)"
  unset COORD_DIR CLAUDE_PROJECT_DIR CLAUDE_COORD COORD_ENABLED
}
teardown() { rm -rf "$TMP"; }

@test "parallels-status: succeeds in a fresh install + reports schema_version" {
  cd "$TMP"
  bash "$SRC_ROOT/install.sh" --yes >/dev/null 2>&1 \
    || { echo "install failed"; return 1; }
  run "$SRC_ROOT/../bin/parallels-status"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'schema_version=1.1'
  echo "$output" | grep -q 'sessions:'
}

@test "parallels-status: forwards extra args to coord status" {
  cd "$TMP"
  bash "$SRC_ROOT/install.sh" --yes >/dev/null 2>&1 \
    || { echo "install failed"; return 1; }
  # `coord status --reads` is the read-set detail mode (Phase 1).
  run "$SRC_ROOT/../bin/parallels-status" --reads
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'read_sets:'
}

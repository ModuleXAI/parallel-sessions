#!/usr/bin/env bats
# Tests for lib/participant.sh per plan §4.

load "../helpers/common"

P="$SRC_ROOT/core/lib/participant.sh"

setup() {
  TMP="$(mktemp -d -t coord-participant-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  export COORD_DIR="$COORD"
}
teardown() {
  rm -rf "$TMP"
}

@test "participant: marker present → exit 0" {
  : >"$COORD_DIR/sessions/abc.active"
  run "$P" abc
  [ "$status" -eq 0 ]
}

@test "participant: marker absent → exit 1" {
  run "$P" abc
  [ "$status" -eq 1 ]
}

@test "participant: missing session_id arg → exit 1 (no crash)" {
  run "$P"
  [ "$status" -eq 1 ]
}

@test "participant: missing COORD_DIR → exit 1 (no crash)" {
  unset COORD_DIR
  : >"$TMP/.coord/sessions/abc.active"
  run "$P" abc
  [ "$status" -eq 1 ]
}

@test "participant: marker for another session does not satisfy this one" {
  : >"$COORD_DIR/sessions/other.active"
  run "$P" mine
  [ "$status" -eq 1 ]
}

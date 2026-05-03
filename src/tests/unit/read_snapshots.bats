#!/usr/bin/env bats
# Tests for lib/read_snapshots.sh per PR-PHASE4-05 (Phase 4 / T4.02a).
#
# Coverage:
#   - coord_read_snapshot_path returns canonical path (no I/O)
#   - coord_read_snapshot_lookup detects presence/absence
#   - coord_read_snapshot_write small-file → snapshot written
#   - coord_read_snapshot_write SKIPPED_LARGE → no write, logs SKIPPED_LARGE event
#   - coord_read_snapshot_write idempotent re-Read same hash → no-op
#   - coord_read_snapshot_supersede deletes prior snapshot
#   - coord_read_snapshot_supersede idempotent on absent prior
#   - coord_read_snapshot_cleanup_session removes session dir
#   - cross-session isolation: two sessions don't collide
#   - LRU eviction triggers when per-session cap exceeded
#   - Missing source file → READ_SNAPSHOT_WRITE_FAILED event
#
# These tests exercise the library directly. The hook integration is
# covered by pre_tool_use_read.bats regression (Phase 1+3 invariants
# must hold).

load "../helpers/common"

LIB="$SRC_ROOT/core/lib/read_snapshots.sh"

setup() {
  TMP="$(mktemp -d -t coord-rsnap-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  export SESSION_ID="rsnap-test-sid"
  # Source the library + log_event so events fire correctly during tests.
  # shellcheck disable=SC1090
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1090
  . "$LIB"
  SID="rsnap-sid-0001"
}

teardown() {
  unset COORD_DIR SESSION_ID COORD_READ_SNAPSHOT_MAX_PER_SESSION_MB
  rm -rf "$TMP"
}

@test "read_snapshots: coord_read_snapshot_path returns canonical path (no I/O)" {
  run coord_read_snapshot_path "$SID" "abc123"
  [ "$status" -eq 0 ]
  [ "$output" = "$COORD/read_snapshots/$SID/abc123.txt" ]
  # No directory created merely by computing the path.
  [ ! -d "$COORD/read_snapshots/$SID" ]
}

@test "read_snapshots: coord_read_snapshot_path errors on missing args" {
  run coord_read_snapshot_path "" "abc"
  [ "$status" -ne 0 ]
  run coord_read_snapshot_path "sid" ""
  [ "$status" -ne 0 ]
}

@test "read_snapshots: write small file → snapshot present + WRITTEN event" {
  local SRC="$TMP/source.txt"
  printf 'hello validator pipeline\n' >"$SRC"
  local HASH
  HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  run coord_read_snapshot_write "$SID" "$HASH" "$SRC"
  [ "$status" -eq 0 ]
  local DEST="$COORD/read_snapshots/$SID/$HASH.txt"
  [ -f "$DEST" ]
  # Byte-identical content.
  diff -q "$SRC" "$DEST"
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_WRITTEN")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "read_snapshots: write SKIPPED_LARGE → no file, SKIPPED_LARGE event logged" {
  local SRC="$TMP/big.bin"
  dd if=/dev/zero of="$SRC" bs=1024 count=4 >/dev/null 2>&1
  run coord_read_snapshot_write "$SID" "SKIPPED_LARGE" "$SRC"
  [ "$status" -eq 0 ]
  # No snapshot file created.
  [ ! -d "$COORD/read_snapshots/$SID" ] || \
    [ -z "$(ls "$COORD/read_snapshots/$SID" 2>/dev/null)" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_SKIPPED_LARGE")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "read_snapshots: write idempotent — re-write same hash → no-op + no second event" {
  local SRC="$TMP/source.txt"
  printf 'idempotent body\n' >"$SRC"
  local HASH
  HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$HASH" "$SRC"
  sleep 0.3
  local first
  first=$(jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_WRITTEN")] | length' "$COORD/events.jsonl")
  # Second write — destination already present; helper short-circuits.
  run coord_read_snapshot_write "$SID" "$HASH" "$SRC"
  [ "$status" -eq 0 ]
  sleep 0.3
  local second
  second=$(jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_WRITTEN")] | length' "$COORD/events.jsonl")
  [ "$first" = "$second" ]
}

@test "read_snapshots: supersede removes prior snapshot + emits SUPERSEDED event" {
  local SRC="$TMP/source.txt"
  printf 'v1\n' >"$SRC"
  local HASH_V1
  HASH_V1=$(shasum -a 256 "$SRC" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$HASH_V1" "$SRC"
  [ -f "$COORD/read_snapshots/$SID/$HASH_V1.txt" ]
  run coord_read_snapshot_supersede "$SID" "$HASH_V1"
  [ "$status" -eq 0 ]
  [ ! -f "$COORD/read_snapshots/$SID/$HASH_V1.txt" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_SUPERSEDED")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "read_snapshots: supersede idempotent on absent prior snapshot" {
  run coord_read_snapshot_supersede "$SID" "deadbeef"
  [ "$status" -eq 0 ]
  # No SUPERSEDED event because nothing was deleted.
  sleep 0.3
  if [ -f "$COORD/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_SUPERSEDED")] | length' "$COORD/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "read_snapshots: supersede SKIPPED_LARGE prior_hash → no-op" {
  run coord_read_snapshot_supersede "$SID" "SKIPPED_LARGE"
  [ "$status" -eq 0 ]
}

@test "read_snapshots: cleanup_session removes per-session directory + emits event" {
  local SRC="$TMP/source.txt"
  printf 'a\n' >"$SRC"
  local HASH_A; HASH_A=$(shasum -a 256 "$SRC" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$HASH_A" "$SRC"
  printf 'b\n' >"$SRC"
  local HASH_B; HASH_B=$(shasum -a 256 "$SRC" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$HASH_B" "$SRC"
  [ -d "$COORD/read_snapshots/$SID" ]
  [ "$(ls "$COORD/read_snapshots/$SID" | wc -l | tr -d ' ')" = "2" ]
  run coord_read_snapshot_cleanup_session "$SID"
  [ "$status" -eq 0 ]
  [ ! -d "$COORD/read_snapshots/$SID" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_SESSION_CLEANUP")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs 'last(.[] | select(.kind == "READ_SNAPSHOT_SESSION_CLEANUP")) | .payload.removed_count' "$COORD/events.jsonl"
  [ "$output" = "2" ]
}

@test "read_snapshots: cleanup_session idempotent on absent directory" {
  [ ! -d "$COORD/read_snapshots/$SID" ]
  run coord_read_snapshot_cleanup_session "$SID"
  [ "$status" -eq 0 ]
}

@test "read_snapshots: cross-session isolation — two sessions same hash do not collide" {
  local SID_A="rsnap-A" SID_B="rsnap-B"
  local SRC_A="$TMP/a.txt" SRC_B="$TMP/b.txt"
  printf 'shared content\n' >"$SRC_A"
  printf 'shared content\n' >"$SRC_B"
  local HASH
  HASH=$(shasum -a 256 "$SRC_A" | awk '{print $1}')
  # Same hash, different sessions.
  coord_read_snapshot_write "$SID_A" "$HASH" "$SRC_A"
  coord_read_snapshot_write "$SID_B" "$HASH" "$SRC_B"
  [ -f "$COORD/read_snapshots/$SID_A/$HASH.txt" ]
  [ -f "$COORD/read_snapshots/$SID_B/$HASH.txt" ]
  # Cleanup A doesn't affect B.
  coord_read_snapshot_cleanup_session "$SID_A"
  [ ! -d "$COORD/read_snapshots/$SID_A" ]
  [ -f "$COORD/read_snapshots/$SID_B/$HASH.txt" ]
}

@test "read_snapshots: LRU eviction triggers when per-session cap exceeded" {
  # Set cap to 1 MB; write 3 files of ~600 KB each → 1.8 MB > 1 MB.
  export COORD_READ_SNAPSHOT_MAX_PER_SESSION_MB=1
  local F1="$TMP/f1" F2="$TMP/f2" F3="$TMP/f3"
  dd if=/dev/zero of="$F1" bs=1024 count=600 >/dev/null 2>&1
  # Make hashes distinct by appending a unique byte.
  printf '\x01' >>"$F1"
  dd if=/dev/zero of="$F2" bs=1024 count=600 >/dev/null 2>&1
  printf '\x02' >>"$F2"
  dd if=/dev/zero of="$F3" bs=1024 count=600 >/dev/null 2>&1
  printf '\x03' >>"$F3"
  local H1 H2 H3
  H1=$(shasum -a 256 "$F1" | awk '{print $1}')
  H2=$(shasum -a 256 "$F2" | awk '{print $1}')
  H3=$(shasum -a 256 "$F3" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$H1" "$F1"
  # Sleep so mtimes differ (LRU sorts by mtime).
  sleep 1
  coord_read_snapshot_write "$SID" "$H2" "$F2"
  sleep 1
  coord_read_snapshot_write "$SID" "$H3" "$F3"
  # Oldest (H1) should have been evicted.
  [ ! -f "$COORD/read_snapshots/$SID/$H1.txt" ]
  # Newer ones should still be present.
  [ -f "$COORD/read_snapshots/$SID/$H3.txt" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_LRU_EVICTED")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "read_snapshots: write fails on missing source file → WRITE_FAILED event" {
  run coord_read_snapshot_write "$SID" "abc123" "$TMP/does-not-exist"
  [ "$status" -ne 0 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "READ_SNAPSHOT_WRITE_FAILED")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "read_snapshots: lookup returns 0 on hit, 1 on miss" {
  local SRC="$TMP/src.txt"
  printf 'hi\n' >"$SRC"
  local HASH
  HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  run coord_read_snapshot_lookup "$SID" "$HASH"
  [ "$status" -eq 1 ]
  coord_read_snapshot_write "$SID" "$HASH" "$SRC"
  run coord_read_snapshot_lookup "$SID" "$HASH"
  [ "$status" -eq 0 ]
}

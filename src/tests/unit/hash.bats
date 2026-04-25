#!/usr/bin/env bats
# Tests for lib/hash.sh per plan §4 test criteria:
#   - same content → same hash
#   - >cap bytes → "SKIPPED_LARGE"
#   - missing file → exit 1

load "../helpers/common"

HASH="$SRC_ROOT/lib/hash.sh"

setup() {
  TMP="$(mktemp -d -t coord-hash-XXXX)"
}
teardown() {
  rm -rf "$TMP"
}

@test "hash: identical content yields identical digest" {
  echo "hello coord" >"$TMP/a"
  echo "hello coord" >"$TMP/b"
  run "$HASH" "$TMP/a"
  [ "$status" -eq 0 ]
  local a="$output"
  run "$HASH" "$TMP/b"
  [ "$status" -eq 0 ]
  [ "$output" = "$a" ]
  # Verify digest format: 64 lowercase hex characters.
  [[ "$a" =~ ^[0-9a-f]{64}$ ]]
}

@test "hash: different content yields different digest" {
  echo "one" >"$TMP/a"
  echo "two" >"$TMP/b"
  run "$HASH" "$TMP/a"; local a="$output"
  run "$HASH" "$TMP/b"; local b="$output"
  [ "$a" != "$b" ]
}

@test "hash: file larger than default cap returns SKIPPED_LARGE" {
  # 11 MB exceeds the 10 MB default cap.
  head -c 11534336 /dev/zero >"$TMP/big"
  run "$HASH" "$TMP/big"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED_LARGE" ]
}

@test "hash: file exactly at cap hashes, one byte over skips" {
  local cap=1024
  head -c $cap /dev/zero >"$TMP/exact"
  head -c $((cap+1)) /dev/zero >"$TMP/over"
  COORD_HASH_SIZE_CAP_BYTES=$cap run "$HASH" "$TMP/exact"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{64}$ ]]
  COORD_HASH_SIZE_CAP_BYTES=$cap run "$HASH" "$TMP/over"
  [ "$status" -eq 0 ]
  [ "$output" = "SKIPPED_LARGE" ]
}

@test "hash: missing file returns exit 1" {
  run "$HASH" "$TMP/absent"
  [ "$status" -eq 1 ]
}

@test "hash: unreadable file returns exit 1" {
  # chmod 000 cannot revoke read access from root, so skip under uid 0
  # (Docker containers default to root). The code path is still covered
  # by "missing file returns exit 1" on every platform.
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 does not bind root"
  echo data >"$TMP/noread"
  chmod 000 "$TMP/noread"
  run "$HASH" "$TMP/noread"
  [ "$status" -eq 1 ]
  chmod 644 "$TMP/noread"  # restore for teardown
}

@test "hash: matches shasum -a 256 reference" {
  echo "reference content" >"$TMP/ref"
  local ref
  ref=$(shasum -a 256 "$TMP/ref" | cut -d' ' -f1)
  run "$HASH" "$TMP/ref"
  [ "$output" = "$ref" ]
}

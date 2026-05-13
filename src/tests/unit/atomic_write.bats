#!/usr/bin/env bats
# Tests for lib/atomic_write.sh per plan §4 + Decision 2.3.
#
# Signature (note: filter BEFORE --arg/--argjson pairs):
#   atomic_write.sh edit <state_file> <jq_filter> [<jq_arg> ...]

load "../helpers/common"

A="$SRC_ROOT/core/lib/atomic_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-atomic-XXXX)"
  STATE="$TMP/sessions.json"
}
teardown() {
  rm -rf "$TMP"
}

@test "atomic: template emits valid empty JSON with required keys" {
  run "$A" template
  [ "$status" -eq 0 ]
  run bash -c "'$A' template | jq -e 'has(\"schema_version\") and has(\"sessions\") and has(\"locks\") and has(\"wait_queues\") and has(\"read_sets\")'"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "atomic: first edit creates file and applies filter" {
  run "$A" edit "$STATE" '.sessions.a1 = {x:1}'
  [ "$status" -eq 0 ]
  [ -f "$STATE" ]
  run jq -r '.sessions.a1.x' "$STATE"
  [ "$output" = "1" ]
}

@test "atomic: second edit merges without clobbering prior keys" {
  "$A" edit "$STATE" '.sessions.a = {k:"v1"}'
  "$A" edit "$STATE" '.sessions.b = {k:"v2"}'
  run jq -r '.sessions | keys | sort | join(",")' "$STATE"
  [ "$output" = "a,b" ]
}

@test "atomic: 10 concurrent edits all persist (no lost writes)" {
  "$A" template >"$STATE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( "$A" edit "$STATE" '.sessions["s\($i)"] = {pid:($i|tonumber)}' --arg i "$i" ) &
  done
  wait
  sleep 0.2
  run jq -r '.sessions | length' "$STATE"
  [ "$output" = "10" ]
  run jq -r '.sessions | keys | sort | join(",")' "$STATE"
  [ "$output" = "s1,s10,s2,s3,s4,s5,s6,s7,s8,s9" ]
}

@test "atomic: corrupt state → reset + archive + mediator pending.jsonl entry" {
  mkdir -p "$TMP/.coord/mediator"
  : >"$TMP/.coord/mediator/pending.jsonl"
  : >"$TMP/.coord/mediator/pending.lock"
  export COORD_DIR="$TMP/.coord"
  printf 'this is not json\n' >"$STATE"
  run "$A" edit "$STATE" '.sessions.after = {ok:true}'
  [ "$status" -eq 0 ]
  run jq -r '.sessions.after.ok' "$STATE"
  [ "$output" = "true" ]
  # Archived original
  run bash -c "ls '$STATE'.corrupt.*.json 2>/dev/null | head -1"
  [ -n "$output" ]
  # Mediator pending.jsonl now has a corrupt_state entry (T3.07 /
  # PR-PHASE3-03: legacy single-file pending.json is retired in
  # favor of unified JSONL queue).
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "corrupt_state")] | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
  run jq -rs '[.[] | select(.kind == "corrupt_state")][-1].source' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "atomic_write" ]
  # Legacy pending.json file is NOT created.
  [ ! -f "$COORD_DIR/mediator/pending.json" ]
}

@test "atomic: flock timeout returns exit 42" {
  "$A" template >"$STATE"
  # Hold flock externally for 6s; our -w 5s should time out and return 42.
  (
    flock -x 9
    sleep 6
  ) 9>"$STATE.lock" &
  HOLDER=$!
  sleep 0.2
  run "$A" edit "$STATE" '.'
  [ "$status" -eq 42 ]
  wait $HOLDER
}

@test "atomic: jq filter error returns exit 43" {
  "$A" template >"$STATE"
  # Unterminated string — syntactic jq error.
  run "$A" edit "$STATE" '.sessions["unterminated'
  [ "$status" -eq 43 ]
}

@test "atomic: reset clears state and archives prior content" {
  "$A" edit "$STATE" '.sessions.x = {a:1}'
  run "$A" reset "$STATE"
  [ "$status" -eq 0 ]
  run jq -r '.sessions | length' "$STATE"
  [ "$output" = "0" ]
  run bash -c "ls '$STATE'.reset.*.json 2>/dev/null | head -1"
  [ -n "$output" ]
}

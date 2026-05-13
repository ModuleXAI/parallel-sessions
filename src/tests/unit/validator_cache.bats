#!/usr/bin/env bats
# Tests for lib/validator_cache.sh per PR-PHASE4-04 (Phase 4 / T4.02b).
#
# Coverage:
#   - empty cache lookup → MISS
#   - SAFE cache hit → returns SAFE + verdict_source + empty diff_summary
#   - MINOR cache hit → returns MINOR + verdict_source + diff_summary
#   - expired entry → MISS (auto-dropped by jq filter on lookup)
#   - TTL boundary respected (1s-grace control test)
#   - CRITICAL refused at write (no-op + WRITE_REFUSED event)
#   - SAFE write must store diff_summary as null (not empty string)
#   - MINOR write requires non-empty diff_summary (rejected without it)
#   - concurrent writes via flock produce no torn JSON
#   - opportunistic GC drops expired entries on subsequent write
#   - clear() resets to {"entries":[]}
#   - lookup of unknown key returns MISS

load "../helpers/common"

LIB="$SRC_ROOT/core/lib/validator_cache.sh"

setup() {
  TMP="$(mktemp -d -t coord-vcache-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  mkdir -p "$COORD/validator"
  export COORD_DIR="$COORD"
  export SESSION_ID="vcache-test-sid"
  # shellcheck disable=SC1090
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1090
  . "$LIB"
}

teardown() {
  unset COORD_DIR SESSION_ID COORD_VALIDATOR_CACHE_TTL_SEC \
        COORD_VALIDATOR_CACHE_MAX_ENTRIES
  rm -rf "$TMP"
}

@test "validator_cache: empty / absent cache lookup → MISS" {
  run coord_validator_cache_lookup "/file.ts" "abc" "def"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "validator_cache: SAFE write + lookup → HIT with empty diff_summary" {
  run coord_validator_cache_write "/file.ts" "abc" "def" "SAFE" "prefilter"
  [ "$status" -eq 0 ]
  run coord_validator_cache_lookup "/file.ts" "abc" "def"
  [ "$status" -eq 0 ]
  # Output: "SAFE\tprefilter\t" (empty diff_summary).
  echo "$output" | awk -F'\t' '{ exit !($1=="SAFE" && $2=="prefilter" && $3=="") }'
}

@test "validator_cache: MINOR write + lookup → HIT with diff_summary populated" {
  run coord_validator_cache_write "/file.ts" "abc" "def" "MINOR" "validator_agent" \
      "Minor drift on imports"
  [ "$status" -eq 0 ]
  run coord_validator_cache_lookup "/file.ts" "abc" "def"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{ exit !($1=="MINOR" && $2=="validator_agent" && $3=="Minor drift on imports") }'
}

@test "validator_cache: MINOR write without diff_summary → rejected (rc=1)" {
  run coord_validator_cache_write "/file.ts" "abc" "def" "MINOR" "validator_agent"
  [ "$status" -eq 1 ]
}

@test "validator_cache: CRITICAL write refused → no-op rc=0 + WRITE_REFUSED event" {
  run coord_validator_cache_write "/file.ts" "abc" "def" "CRITICAL" "validator_agent" "drift"
  [ "$status" -eq 0 ]
  # Lookup returns MISS (entry was not stored).
  run coord_validator_cache_lookup "/file.ts" "abc" "def"
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_CACHE_WRITE_REFUSED")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_cache: invalid verdict_source → rc=1" {
  run coord_validator_cache_write "/file.ts" "abc" "def" "SAFE" "bogus_source"
  [ "$status" -eq 1 ]
}

@test "validator_cache: invalid verdict → rc=1" {
  run coord_validator_cache_write "/file.ts" "abc" "def" "MAYBE" "prefilter"
  [ "$status" -eq 1 ]
}

@test "validator_cache: TTL expiry → lookup returns MISS" {
  # Set TTL to 2 seconds (1s is too tight for the second-precision
  # ttl_until vs lookup-now race); write entry; immediate hit; sleep 3;
  # lookup → MISS (entry now older than 2s TTL).
  export COORD_VALIDATOR_CACHE_TTL_SEC=2
  coord_validator_cache_write "/file.ts" "abc" "def" "SAFE" "prefilter"
  run coord_validator_cache_lookup "/file.ts" "abc" "def"
  [ "$status" -eq 0 ]
  sleep 3
  run coord_validator_cache_lookup "/file.ts" "abc" "def"
  [ "$status" -eq 1 ]
}

@test "validator_cache: opportunistic GC drops expired entries on subsequent write" {
  # Write entry with 1s TTL; sleep; write a different-key entry.
  # The first entry should be GCed during the second write.
  export COORD_VALIDATOR_CACHE_TTL_SEC=1
  coord_validator_cache_write "/a.ts" "h1" "h1c" "SAFE" "prefilter"
  sleep 2
  # Switch back to default TTL for the second write so it lives.
  export COORD_VALIDATOR_CACHE_TTL_SEC=3600
  coord_validator_cache_write "/b.ts" "h2" "h2c" "SAFE" "prefilter"
  # Cache should contain only b.ts (a.ts expired and was GCed).
  run jq -r '.entries | length' "$COORD/validator/cache.json"
  [ "$output" = "1" ]
  run jq -r '.entries[0].file' "$COORD/validator/cache.json"
  [ "$output" = "/b.ts" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_CACHE_GC_RUN")] | length' "$COORD/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_cache: re-write same key replaces prior entry" {
  coord_validator_cache_write "/file.ts" "abc" "def" "SAFE" "prefilter"
  coord_validator_cache_write "/file.ts" "abc" "def" "MINOR" "validator_agent" "second drift"
  run jq -r '.entries | length' "$COORD/validator/cache.json"
  [ "$output" = "1" ]
  run jq -r '.entries[0].verdict' "$COORD/validator/cache.json"
  [ "$output" = "MINOR" ]
  run jq -r '.entries[0].diff_summary' "$COORD/validator/cache.json"
  [ "$output" = "second drift" ]
}

@test "validator_cache: 5 concurrent writes produce 5 valid cache entries (flock prevents torn JSON)" {
  # Five different keys written in parallel; cache must end with exactly 5 entries
  # and parse cleanly as JSON.
  for i in 1 2 3 4 5; do
    coord_validator_cache_write "/file$i.ts" "h$i" "c$i" "SAFE" "prefilter" &
  done
  wait
  # Cache parses cleanly.
  run jq -e . "$COORD/validator/cache.json"
  [ "$status" -eq 0 ]
  run jq -r '.entries | length' "$COORD/validator/cache.json"
  [ "$output" = "5" ]
}

@test "validator_cache: clear() resets entries to empty" {
  coord_validator_cache_write "/file.ts" "abc" "def" "SAFE" "prefilter"
  run jq -r '.entries | length' "$COORD/validator/cache.json"
  [ "$output" = "1" ]
  run coord_validator_cache_clear
  [ "$status" -eq 0 ]
  run jq -r '.entries | length' "$COORD/validator/cache.json"
  [ "$output" = "0" ]
}

@test "validator_cache: SAFE entry stored with null diff_summary (not empty string)" {
  coord_validator_cache_write "/file.ts" "abc" "def" "SAFE" "prefilter"
  run jq -r '.entries[0].diff_summary' "$COORD/validator/cache.json"
  # jq -r prints null as "null".
  [ "$output" = "null" ]
}

@test "validator_cache: max_entries cap enforces LRU eviction by cached_at" {
  export COORD_VALIDATOR_CACHE_MAX_ENTRIES=3
  # Write 5 distinct entries; cache should retain only the 3 newest.
  coord_validator_cache_write "/f1.ts" "h1" "c1" "SAFE" "prefilter"
  sleep 1
  coord_validator_cache_write "/f2.ts" "h2" "c2" "SAFE" "prefilter"
  sleep 1
  coord_validator_cache_write "/f3.ts" "h3" "c3" "SAFE" "prefilter"
  sleep 1
  coord_validator_cache_write "/f4.ts" "h4" "c4" "SAFE" "prefilter"
  sleep 1
  coord_validator_cache_write "/f5.ts" "h5" "c5" "SAFE" "prefilter"
  run jq -r '.entries | length' "$COORD/validator/cache.json"
  [ "$output" = "3" ]
  # Newest 3 retained: f3, f4, f5.
  run jq -r '[.entries[].file] | sort | join(",")' "$COORD/validator/cache.json"
  [ "$output" = "/f3.ts,/f4.ts,/f5.ts" ]
}

#!/usr/bin/env bats
# Tests for lib/watchdog_cache.sh (Phase 3 / T3.04 per PR-PHASE3-02).
#
# Coverage:
#   - cache_lookup empty / fresh-alive / fresh-dead / expired / multi-entry
#   - cache_record append shape + concurrency
#   - cache_expire purges expired, preserves fresh
#   - cache_invalidate_dead drops dead-only, keeps alive/uncertain
#   - acquire_check_lock first-wins / second-fails / stale-auto-clear /
#     fresh-not-cleared
#   - release_check_lock removes file; next acquire succeeds
#
# T3.04 is INFRASTRUCTURE only — no probe heuristics or hook wiring;
# the latter lands in T3.05.

load "../helpers/common"

WC="$SRC_ROOT/core/lib/watchdog_cache.sh"

setup() {
  TMP="$(mktemp -d -t coord-watchdog-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  # Materialize the watchdog layout the installer would create.
  mkdir -p "$COORD/watchdog/checking"
  : >"$COORD/watchdog/recent_checks.jsonl"
  : >"$COORD/watchdog/recent_checks.lock"
  export COORD_DIR="$COORD"
  SESSION_ID="observer-001"
  export SESSION_ID
}

teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# Helpers -----------------------------------------------------------------

# _seed_entry <target> <verdict> <reason> <ttl_seconds>
#   Append a synthetic entry with the canonical shape (used to seed the
#   cache directly without going through cache_record, so we can test
#   the lookup/expire paths in isolation).
_seed_entry() {
  local target="$1" verdict="$2" reason="$3" ttl="$4"
  local now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local now_epoch="$(date -u +%s)"
  local valid_until_epoch=$(( now_epoch + ttl ))
  local valid_until
  valid_until=$(date -u -r "$valid_until_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$valid_until_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$now_iso")
  jq -nc --arg ts "$now_iso" --arg t "$target" --arg v "$verdict" \
         --arg r "$reason" --arg vu "$valid_until" \
         '{ts:$ts, target:$t, verdict:$v, reason:$r, valid_until:$vu}' \
    >>"$COORD/watchdog/recent_checks.jsonl"
}

# --- cache_lookup ---------------------------------------------------------

@test "cache_lookup: empty cache → returns 1, no stdout" {
  run bash -c '. "'"$WC"'"; coord_watchdog_cache_lookup "target-A"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "cache_lookup: fresh alive entry → returns 0 + verdict on stdout" {
  _seed_entry "target-A" "alive" "ps still has pid" 60
  run bash -c '. "'"$WC"'"; coord_watchdog_cache_lookup "target-A"'
  [ "$status" -eq 0 ]
  # Output is TSV: verdict\treason\tvalid_until
  echo "$output" | awk -F'\t' '{exit ($1 == "alive" && $2 == "ps still has pid") ? 0 : 1}'
}

@test "cache_lookup: expired entry → returns 1 (treated as miss)" {
  _seed_entry "target-A" "alive" "stale" -10  # already past
  run bash -c '. "'"$WC"'"; coord_watchdog_cache_lookup "target-A"'
  [ "$status" -ne 0 ]
}

@test "cache_lookup: fresh dead entry → returns it (large TTL keeps it valid)" {
  _seed_entry "target-A" "dead" "pid recycled" 31536000
  run bash -c '. "'"$WC"'"; coord_watchdog_cache_lookup "target-A"'
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "dead") ? 0 : 1}'
}

@test "cache_lookup: multiple entries for same target → returns LAST (most recent)" {
  _seed_entry "target-A" "uncertain" "first" 30
  sleep 0.05
  _seed_entry "target-A" "alive" "second" 60
  run bash -c '. "'"$WC"'"; coord_watchdog_cache_lookup "target-A"'
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "alive" && $2 == "second") ? 0 : 1}'
}

# --- cache_record ---------------------------------------------------------

@test "cache_record: appends a valid JSONL entry with all required fields" {
  bash -c '. "'"$SRC_ROOT/core/lib/log_event.sh"'"; . "'"$WC"'"; coord_watchdog_cache_record "target-A" "alive" "ps still has pid" 60'
  # Exactly one line in the cache.
  run wc -l <"$COORD/watchdog/recent_checks.jsonl"
  [ "$output" -eq 1 ]
  # Validate shape: ts, target, verdict, reason, valid_until all present.
  run jq -e 'has("ts") and has("target") and has("verdict") and has("reason") and has("valid_until")' \
    "$COORD/watchdog/recent_checks.jsonl"
  [ "$output" = "true" ]
  run jq -r '.target' "$COORD/watchdog/recent_checks.jsonl"
  [ "$output" = "target-A" ]
  run jq -r '.verdict' "$COORD/watchdog/recent_checks.jsonl"
  [ "$output" = "alive" ]
}

@test "cache_record: 5 concurrent appends produce 5 valid JSONL lines (no torn writes)" {
  bash -c '
    . "'"$SRC_ROOT/core/lib/log_event.sh"'"
    . "'"$WC"'"
    for i in 1 2 3 4 5; do
      coord_watchdog_cache_record "target-$i" "alive" "concurrent-$i" 60 &
    done
    wait
  '
  run wc -l <"$COORD/watchdog/recent_checks.jsonl"
  [ "$output" -eq 5 ]
  # Every line parses as JSON.
  run bash -c "while IFS= read -r line; do printf '%s' \"\$line\" | jq -e . >/dev/null || exit 1; done <\"$COORD/watchdog/recent_checks.jsonl\"; echo OK"
  [ "$output" = "OK" ]
}

# --- cache_expire ---------------------------------------------------------

@test "cache_expire: purges expired entries, preserves fresh ones" {
  _seed_entry "target-X" "alive" "fresh" 60
  _seed_entry "target-Y" "alive" "stale" -100
  _seed_entry "target-Z" "uncertain" "fresh" 30
  bash -c '. "'"$WC"'"; coord_watchdog_cache_expire'
  # After expire: target-X and target-Z survive, target-Y purged.
  run wc -l <"$COORD/watchdog/recent_checks.jsonl"
  [ "$output" -eq 2 ]
  run jq -rs 'map(.target) | sort | join(",")' "$COORD/watchdog/recent_checks.jsonl"
  [ "$output" = "target-X,target-Z" ]
}

# --- cache_invalidate_dead ------------------------------------------------

@test "cache_invalidate_dead: drops dead entries; preserves alive + uncertain" {
  _seed_entry "target-A" "alive" "fresh-alive" 60
  _seed_entry "target-B" "dead" "long-ttl" 31536000
  _seed_entry "target-C" "uncertain" "fresh-uncertain" 30
  _seed_entry "target-D" "dead" "another-long-ttl" 31536000
  bash -c '. "'"$WC"'"; coord_watchdog_cache_invalidate_dead'
  run wc -l <"$COORD/watchdog/recent_checks.jsonl"
  [ "$output" -eq 2 ]
  run jq -rs 'map(.verdict) | sort | join(",")' "$COORD/watchdog/recent_checks.jsonl"
  [ "$output" = "alive,uncertain" ]
}

# --- acquire_check_lock + release_check_lock ------------------------------

@test "acquire_check_lock: first invocation succeeds + creates file with content" {
  run bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"'
  [ "$status" -eq 0 ]
  [ -f "$COORD/watchdog/checking/target-A.lock" ]
  run grep -c '^writer=' "$COORD/watchdog/checking/target-A.lock"
  [ "$output" -ge 1 ]
  run grep -c '^started_at=' "$COORD/watchdog/checking/target-A.lock"
  [ "$output" -ge 1 ]
}

@test "acquire_check_lock: second concurrent invocation fails with rc=1" {
  bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"' >/dev/null
  run bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"'
  [ "$status" -ne 0 ]
}

@test "release_check_lock: removes file; next acquire succeeds" {
  bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"' >/dev/null
  bash -c '. "'"$WC"'"; coord_watchdog_release_check_lock "target-A"'
  [ ! -f "$COORD/watchdog/checking/target-A.lock" ]
  run bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"'
  [ "$status" -eq 0 ]
}

@test "acquire_check_lock: stale lock (mtime > 30s) auto-cleared, then acquired" {
  # Synthesize a stale lock by backdating a real lock file's mtime.
  # We compute the target epoch directly from `date +%s` and convert
  # via `-r EPOCH` (BSD) or `-d @EPOCH` (GNU) — this is more robust
  # than `date -v-2M` which can produce a touch-format string that
  # differs from the system's epoch interpretation when the system
  # clock and date-format conversions disagree (observed on macOS).
  mkdir -p "$COORD/watchdog/checking"
  printf 'writer=ghost\nstarted_at=ancient\n' >"$COORD/watchdog/checking/target-A.lock"
  # Backdate via perl utime — feeds raw epoch seconds to the system call,
  # bypassing both `touch -t` (which uses local timezone, producing
  # future-dated files when local != UTC) and date-format conversions.
  # Perl ships on macOS + Linux base OS per F-009.
  perl -e 'utime time-60, time-60, $ARGV[0]' \
    "$COORD/watchdog/checking/target-A.lock"
  # Sanity: confirm the backdate landed (file age should be > 30s now).
  local computed_age
  computed_age=$(bash -c '. "'"$WC"'"; _coord_file_age_seconds "'"$COORD/watchdog/checking/target-A.lock"'"')
  [ "$computed_age" -gt 30 ] || { echo "backdate failed; computed_age=$computed_age"; return 1; }
  run bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"'
  [ "$status" -eq 0 ]
  # New content overwrote the stale ghost.
  run grep -q "^writer=$SESSION_ID$" "$COORD/watchdog/checking/target-A.lock"
  [ "$status" -eq 0 ]
}

@test "acquire_check_lock: fresh lock (mtime < 30s) is NOT auto-cleared" {
  bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"' >/dev/null
  # Don't backdate — file is brand new (~0s old).
  run bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "target-A"'
  [ "$status" -ne 0 ]
}

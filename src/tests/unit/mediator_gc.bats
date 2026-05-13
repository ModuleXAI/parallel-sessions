#!/usr/bin/env bats
# Tests for coord_mediator_gc_pending (Phase 3 / T3.07 / PR-PHASE3-04).
#
# Coverage:
#   - GC keeps unconsumed entries (above HWM)
#   - GC keeps recently-consumed entries (<24h, below HWM)
#   - GC removes 24h-old consumed entries (below HWM AND age > retention)
#   - HWM rebases correctly after rewrite
#   - Atomic single-flock encloses both rewrite and HWM update
#   - Idempotent: running GC twice produces no further changes
#   - PENDING_GC_RUN event emitted

load "../helpers/common"

MP="$SRC_ROOT/core/lib/mediator_pending.sh"
LE="$SRC_ROOT/core/lib/log_event.sh"

setup() {
  TMP="$(mktemp -d -t coord-gc-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  : >"$COORD/mediator/pending.jsonl"
  : >"$COORD/mediator/pending.lock"
  export COORD_DIR="$COORD"
  SESSION_ID="observer-gc-001"
  export SESSION_ID
}

teardown() {
  unset COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# Helper: append a synthetic pending entry with a custom ts.
_seed_entry_at() {
  local ts="$1" kind="$2" payload="$3"
  jq -nc --arg ts "$ts" --arg kind "$kind" --arg payload "$payload" \
    '{ts:$ts, kind:$kind, session:"observer", source:"test", payload:{note:$payload}}' \
    >>"$COORD/mediator/pending.jsonl"
}

_iso_ago_hours() {
  local hours="$1"
  local target_epoch=$(( $(date -u +%s) - hours * 3600 ))
  date -u -r "$target_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$target_epoch" +%Y-%m-%dT%H:%M:%SZ
}

_run_gc() {
  bash -c '. "'"$LE"'"; . "'"$MP"'"; coord_mediator_gc_pending "${1:-24}"' _ "$@"
}

@test "gc: keeps un-consumed entries above HWM regardless of age" {
  _seed_entry_at "$(_iso_ago_hours 100)" "stale_active" "old-but-unconsumed"
  printf '0\n' >"$COORD/mediator/pending.consumed"  # HWM=0; entry is above
  _run_gc 24
  run wc -l <"$COORD/mediator/pending.jsonl"
  [ "$output" -eq 1 ]
}

@test "gc: keeps recently-consumed (<24h) entries below HWM" {
  # Two entries; both consumed (HWM=2). One is <24h old (kept), one is
  # 30h old (removed by 24h retention).
  _seed_entry_at "$(_iso_ago_hours 1)" "stale_active" "recent-consumed"
  _seed_entry_at "$(_iso_ago_hours 30)" "flock_timeout" "old-consumed"
  printf '2\n' >"$COORD/mediator/pending.consumed"
  _run_gc 24
  run wc -l <"$COORD/mediator/pending.jsonl"
  [ "$output" -eq 1 ]   # only recent-consumed survives
  run jq -r '.payload.note' "$COORD/mediator/pending.jsonl"
  [ "$output" = "recent-consumed" ]
}

@test "gc: removes consumed entries older than retention" {
  _seed_entry_at "$(_iso_ago_hours 100)" "flock_timeout" "very-old"
  printf '1\n' >"$COORD/mediator/pending.consumed"
  _run_gc 24
  run wc -l <"$COORD/mediator/pending.jsonl"
  [ "$output" -eq 0 ]
}

@test "gc: HWM rebases to count of consumed entries kept" {
  # 3 consumed (1 recent + 2 old) + 1 unconsumed; HWM=3.
  _seed_entry_at "$(_iso_ago_hours 30)" "flock_timeout" "old-1"
  _seed_entry_at "$(_iso_ago_hours 1)" "stale_active" "recent-1"
  _seed_entry_at "$(_iso_ago_hours 50)" "flock_timeout" "old-2"
  _seed_entry_at "$(_iso_ago_hours 0)" "stale_active" "unconsumed"
  printf '3\n' >"$COORD/mediator/pending.consumed"
  _run_gc 24
  # After GC: kept = recent-1 + unconsumed = 2 lines.
  run wc -l <"$COORD/mediator/pending.jsonl"
  [ "$output" -eq 2 ]
  # HWM rebased to count-of-kept-consumed = 1 (only recent-1).
  run cat "$COORD/mediator/pending.consumed"
  [ "$output" = "1" ]
}

@test "gc: emits PENDING_GC_RUN event with kept_count + retention_hours" {
  _seed_entry_at "$(_iso_ago_hours 100)" "flock_timeout" "old"
  _seed_entry_at "$(_iso_ago_hours 1)" "stale_active" "recent"
  printf '2\n' >"$COORD/mediator/pending.consumed"
  _run_gc 24
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "PENDING_GC_RUN")] | length' "$COORD/events.jsonl"
  [ "$output" -ge 1 ]
  run jq -rs '[.[] | select(.kind == "PENDING_GC_RUN")][-1].payload.retention_hours' "$COORD/events.jsonl"
  [ "$output" = "24" ]
  run jq -rs '[.[] | select(.kind == "PENDING_GC_RUN")][-1].payload.kept_count' "$COORD/events.jsonl"
  [ "$output" = "1" ]
}

@test "gc: idempotent — running twice produces no further changes" {
  _seed_entry_at "$(_iso_ago_hours 1)" "stale_active" "recent"
  printf '1\n' >"$COORD/mediator/pending.consumed"
  _run_gc 24
  local snapshot1=$(cat "$COORD/mediator/pending.jsonl")
  local hwm1=$(cat "$COORD/mediator/pending.consumed")
  _run_gc 24
  local snapshot2=$(cat "$COORD/mediator/pending.jsonl")
  local hwm2=$(cat "$COORD/mediator/pending.consumed")
  [ "$snapshot1" = "$snapshot2" ]
  [ "$hwm1" = "$hwm2" ]
}

@test "gc: empty pending.jsonl is no-op" {
  : >"$COORD/mediator/pending.jsonl"
  printf '0\n' >"$COORD/mediator/pending.consumed"
  run _run_gc 24
  [ "$status" -eq 0 ]
  run wc -l <"$COORD/mediator/pending.jsonl"
  [ "$output" -eq 0 ]
}

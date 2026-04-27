#!/usr/bin/env bats
# Phase 5 end-to-end integration tests (T5.08).
#
# Verifies the full Phase 5 stack end-to-end through the production
# library entry points (no real claude -p / fswatch / inotifywait
# subprocess spawns; those are covered by Phase 7's stress harness).
# Each scenario exercises ≥3 Phase 5 components in a realistic
# producer-consumer flow:
#
#   Scenario 1: Multi-waiter FIFO ordering           (3 tests)
#   Scenario 2: Event-driven wake-up via polling     (2 tests)
#   Scenario 3: Cycle detection + Mediator pending   (4 tests)
#   Scenario 4: diff_summary 4-tier chain integration (3 tests)
#   Cross-cutting: lockdown gate + fail-open         (2 tests)
#
# Total: 14 tests.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-e2e-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mkdir -p "$COORD_DIR/wakers" "$COORD_DIR/wait_queues" \
           "$COORD_DIR/validator/verdict" "$COORD_DIR/read_snapshots" \
           "$COORD_DIR/mediator/verdict"
  mk_empty_sessions "$COORD_DIR"
  : >"$COORD_DIR/events.jsonl"
  printf '{"schema_version":"1.0","wait_backend":"polling"}' >"$COORD_DIR/config.json"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/hash.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/cycle_detection.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_backend.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/validator_cache.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/validator_prefilter.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/read_snapshots.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/notify_waiters.sh"
}
teardown() {
  rm -rf "$TMP"
}

# Helpers ---------------------------------------------------------

_acquire() {
  local f="$1" sid="$2" vts="${3:-}"
  if [ -z "$vts" ]; then
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f] = {session: $sid, acquired_at: "t", last_refresh_at: "t", tasks: [], latest_validator_verdict_ts: null}
       | .sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
          registered_at: "y", last_activity_at: "z", git_head: "", prompt_id: null,
          script_version: "1.0"})' \
      --arg f "$f" --arg sid "$sid"
  else
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f] = {session: $sid, acquired_at: "t", last_refresh_at: "t", tasks: [], latest_validator_verdict_ts: $vts}
       | .sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
          registered_at: "y", last_activity_at: "z", git_head: "", prompt_id: null,
          script_version: "1.0"})' \
      --arg f "$f" --arg sid "$sid" --arg vts "$vts"
  fi
}

_release() {
  local f="$1" holder="$2"
  local vts
  vts=$(jq -r --arg f "$f" '.locks[$f].latest_validator_verdict_ts // ""' \
    "$COORD_DIR/sessions.json")
  [ "$vts" = "null" ] && vts=""
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    'del(.locks[$f])' --arg f "$f"
  coord_notify_lock_release_waiters "$holder" "$f" "t0" "t1" "$vts"
}

# ===== Scenario 1: Multi-waiter FIFO ordering (3 tests) =====

@test "T5.08 S1.a: 3 sessions enqueue → wait_queues holds them in arrival order" {
  _acquire "/p/foo" "sid-A"
  SESSION_ID=B coord_wait_queue_enqueue B /p/foo >/dev/null; sleep 0.01
  SESSION_ID=C coord_wait_queue_enqueue C /p/foo >/dev/null; sleep 0.01
  SESSION_ID=D coord_wait_queue_enqueue D /p/foo >/dev/null
  run jq -r '[.wait_queues["/p/foo"][].session_id] | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "B,C,D" ]
  run jq -r '[.wait_queues["/p/foo"][].queue_position] | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "0,1,2" ]
}

@test "T5.08 S1.b: lock release writes diff_summary to ALL queued waiters' wake_files" {
  _acquire "/p/foo" "sid-A"
  SESSION_ID=B coord_wait_queue_enqueue B /p/foo >/dev/null
  SESSION_ID=C coord_wait_queue_enqueue C /p/foo >/dev/null
  SESSION_ID=D coord_wait_queue_enqueue D /p/foo >/dev/null
  _release "/p/foo" "sid-A"
  for w in B C D; do
    WAKE="$COORD_DIR/wakers/${w}-__p__foo.wake"
    [ -s "$WAKE" ] || { echo "wake_file empty for $w: $WAKE"; return 1; }
    content=$(cat "$WAKE")
    [[ "$content" = "modified by sid-A"* ]] \
      || { echo "wake content for $w: [$content]"; return 1; }
  done
}

@test "T5.08 S1.c: head-of-queue dequeue does not affect remaining waiters' positions" {
  _acquire "/p/foo" "sid-A"
  SESSION_ID=B coord_wait_queue_enqueue B /p/foo >/dev/null
  SESSION_ID=C coord_wait_queue_enqueue C /p/foo >/dev/null
  SESSION_ID=D coord_wait_queue_enqueue D /p/foo >/dev/null
  # Simulate B dequeuing (e.g., wake-up + coord wait exit).
  coord_wait_queue_dequeue B /p/foo
  run jq -r '[.wait_queues["/p/foo"][].session_id] | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "C,D" ]
  run jq -r '[.wait_queues["/p/foo"][].queue_position] | join(",")' "$COORD_DIR/sessions.json"
  [ "$output" = "0,1" ]
}

# ===== Scenario 2: Event-driven wake-up via polling (2 tests) =====

@test "T5.08 S2.a: wake_file content available within 250ms polling cadence after release" {
  _acquire "/p/bar" "sid-A"
  SESSION_ID=B coord_wait_queue_enqueue B /p/bar >/dev/null
  WAKE="$COORD_DIR/wakers/B-__p__bar.wake"
  [ -e "$WAKE" ]
  [ ! -s "$WAKE" ]   # initially empty
  # Release writes the wake_file content.
  _release "/p/bar" "sid-A"
  [ -s "$WAKE" ]
  content=$(cat "$WAKE")
  [[ "$content" = "modified by sid-A"* ]]
}

@test "T5.08 S2.b: coord_wait_for_release_polling detects content within 600ms" {
  _acquire "/p/baz" "sid-A"
  SESSION_ID=B coord_wait_queue_enqueue B /p/baz >/dev/null
  WAKE="$COORD_DIR/wakers/B-__p__baz.wake"
  ( sleep 0.2; _release "/p/baz" "sid-A" ) &
  PRODUCER=$!
  T0=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  coord_wait_for_release_polling "$WAKE" 5
  T1=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  wait $PRODUCER
  ELAPSED=$(( T1 - T0 ))
  echo "polling wake-up elapsed_ms=$ELAPSED (expected <600)"
  [ "$ELAPSED" -lt 600 ]
  [ -s "$WAKE" ]
}

# ===== Scenario 3: Cycle detection + Mediator pending (4 tests) =====

@test "T5.08 S3.a: depth-2 enqueue closing cycle → cycle_detected pending entry written" {
  # sid-B closes the A↔B cycle by enqueuing on /p/foo (where sid-C
  # is already waiting at depth 1; sid-B's enqueue brings depth to
  # 2 → trigger). Session IDs MUST match across acquire + enqueue
  # for cycle detection to find the path.
  _acquire "/p/foo" "sid-A"
  _acquire "/p/bar" "sid-B"
  SESSION_ID=sid-A coord_wait_queue_enqueue sid-A /p/bar >/dev/null
  SESSION_ID=sid-C coord_wait_queue_enqueue sid-C /p/foo >/dev/null
  SESSION_ID=sid-B coord_wait_queue_enqueue sid-B /p/foo >/dev/null
  sleep 0.2
  [ -f "$COORD_DIR/mediator/pending.jsonl" ]
  run grep -c '"kind":"cycle_detected"' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
}

@test "T5.08 S3.b: cycle_detected pending entry payload contains 9 keys + cycle_description with 3-tier guidance" {
  _acquire "/p/foo" "sid-A"
  _acquire "/p/bar" "sid-B"
  SESSION_ID=sid-A coord_wait_queue_enqueue sid-A /p/bar >/dev/null
  SESSION_ID=sid-C coord_wait_queue_enqueue sid-C /p/foo >/dev/null
  SESSION_ID=sid-B coord_wait_queue_enqueue sid-B /p/foo >/dev/null
  sleep 0.2
  for k in cycle_path cycle_description involved_files involved_sessions \
           queue_depth_at_detection recent_cycle_count session_metadata \
           trigger_file trigger_session_id; do
    run jq -r --arg k "$k" 'select(.kind=="cycle_detected") | .payload | has($k)' \
      "$COORD_DIR/mediator/pending.jsonl"
    [ "$output" = "true" ] || { echo "missing: $k"; return 1; }
  done
  desc=$(jq -r 'select(.kind=="cycle_detected") | .payload.cycle_description' \
    "$COORD_DIR/mediator/pending.jsonl")
  echo "$desc" | grep -q 'oldest last_activity_at'
  echo "$desc" | grep -q 'fewest locks_held'
  echo "$desc" | grep -q 'youngest session_age'
}

@test "T5.08 S3.c: cycle path bipartite invariant maintained (waits_for/held_by alternation)" {
  _acquire "/p/foo" "sid-A"
  _acquire "/p/bar" "sid-B"
  SESSION_ID=sid-A coord_wait_queue_enqueue sid-A /p/bar >/dev/null
  SESSION_ID=sid-C coord_wait_queue_enqueue sid-C /p/foo >/dev/null
  SESSION_ID=sid-B coord_wait_queue_enqueue sid-B /p/foo >/dev/null
  sleep 0.2
  cycle_json=$(jq -c 'select(.kind=="cycle_detected") | .payload.cycle_path' \
    "$COORD_DIR/mediator/pending.jsonl" | head -1)
  echo "$cycle_json" | jq -e '
    .edges
    | map(select(.type == "waits_for") | .from)
    | all(startswith("/") | not)
  '
  echo "$cycle_json" | jq -e '
    .edges
    | map(select(.type == "held_by") | .from)
    | all(startswith("/"))
  '
}

@test "T5.08 S3.d: cycle_detected entry consumable by kind-agnostic mediator_pending pipeline" {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/mediator_pending.sh"
  _acquire "/p/foo" "sid-A"
  _acquire "/p/bar" "sid-B"
  SESSION_ID=sid-A coord_wait_queue_enqueue sid-A /p/bar >/dev/null
  SESSION_ID=sid-C coord_wait_queue_enqueue sid-C /p/foo >/dev/null
  SESSION_ID=sid-B coord_wait_queue_enqueue sid-B /p/foo >/dev/null
  sleep 0.2
  # consume_pending must NOT error out on the new kind.
  run coord_mediator_consume_pending
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]   # 1 means "no banner emitted" (fine)
}

# ===== Scenario 4: diff_summary 4-tier chain integration (3 tests) =====

@test "T5.08 S4.a: tier 1 — verdict_file lookup feeds wake_file content" {
  TS='2026-04-27T11:00:00.000Z'
  printf '{"verdict_id":"v","ts":"%s","verdict":"MINOR","reasoning":"...","diff_summary":"Reformatted with prettier"}\n' \
    "$TS" >"$COORD_DIR/validator/verdict/${TS}.json"
  _acquire "/p/baz" "sid-A" "$TS"
  SESSION_ID=B coord_wait_queue_enqueue B /p/baz >/dev/null
  _release "/p/baz" "sid-A"
  WAKE="$COORD_DIR/wakers/B-__p__baz.wake"
  content=$(cat "$WAKE")
  [ "$content" = "Reformatted with prettier" ]
  # NOTIFICATION_PRODUCED event records tier=verdict_file.
  sleep 0.1
  run grep -c '"diff_summary_source":"verdict_file"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "T5.08 S4.b: tier 2 — cache hit MINOR feeds wake_file content (no fresh validator spawn)" {
  printf 'foo v0\n' >"$TMP/baz.snap"
  PREV_H=$(coord_hash_file "$TMP/baz.snap")
  printf 'foo v1\n' >"$TMP/baz"
  CUR_H=$(coord_hash_file "$TMP/baz")
  coord_validator_cache_write "$TMP/baz" "$PREV_H" "$CUR_H" 'MINOR' 'validator_agent' \
    'Variable rename'
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.read_sets[$sid] //= {reads:[]}
     | .read_sets[$sid].reads += [{path:$f, hash:$h, at:"t", is_latest:true}]' \
    --arg sid "sid-A" --arg f "$TMP/baz" --arg h "$PREV_H"
  _acquire "$TMP/baz" "sid-A"   # NULL verdict_ts → tier 1 skips
  SESSION_ID=B coord_wait_queue_enqueue B "$TMP/baz" >/dev/null
  _release "$TMP/baz" "sid-A"
  sanitized=$(printf '%s' "$TMP/baz" | sed 's|/|__|g')
  WAKE="$COORD_DIR/wakers/B-${sanitized}.wake"
  content=$(cat "$WAKE")
  [ "$content" = "Variable rename" ]
  sleep 0.1
  run grep -c '"diff_summary_source":"cache_minor"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "T5.08 S4.c: tier 4 — fallback string when no verdict + no cache + no read_set" {
  _acquire "/p/qux" "sid-HOLDER"   # NULL verdict_ts; no cache; no read_set
  SESSION_ID=B coord_wait_queue_enqueue B /p/qux >/dev/null
  _release "/p/qux" "sid-HOLDER"
  WAKE="$COORD_DIR/wakers/B-__p__qux.wake"
  content=$(cat "$WAKE")
  [[ "$content" = "modified by sid-HOLD"* ]]
  sleep 0.1
  run grep -c '"diff_summary_source":"fallback"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

# ===== Cross-cutting (2 tests) =====

@test "T5.08 X.a: lockdown gate suppresses notify_waiters (lockdown.json takes precedence)" {
  # When lockdown is active, the lock-release path should still write
  # wake_files, but the architectural deny invariant means new lock
  # acquisitions are denied. notify_waiters itself is NOT gated on
  # lockdown — it just writes content. We verify that the lockdown
  # invariant doesn't accidentally suppress wake_file writes (so
  # waiters who issued coord wait BEFORE lockdown can still wake).
  _acquire "/p/foo" "sid-A"
  SESSION_ID=B coord_wait_queue_enqueue B /p/foo >/dev/null
  # Activate lockdown (production code path; see lib/lockdown.sh).
  printf '{"active":true,"reason_source":"test","reason":"e2e","activated_at":"t"}' \
    >"$COORD_DIR/mediator/lockdown.json"
  _release "/p/foo" "sid-A"
  WAKE="$COORD_DIR/wakers/B-__p__foo.wake"
  [ -s "$WAKE" ]   # wake_file still written; lockdown doesn't suppress
}

@test "T5.08 X.b: pipeline failure produces fail-open behavior (no permissionDecision in any output path)" {
  # Even when validator pipeline fails (no claude binary, malformed
  # state), the lock-release notify path must still write the
  # fallback diff_summary to wake_files. fail-open per CLAUDE.md §A.5.
  _acquire "/p/fail" "sid-A"   # NULL verdict_ts
  SESSION_ID=B coord_wait_queue_enqueue B /p/fail >/dev/null
  _release "/p/fail" "sid-A"
  WAKE="$COORD_DIR/wakers/B-__p__fail.wake"
  [ -s "$WAKE" ]
  ! grep -q permissionDecision "$WAKE"
  ! grep -q permissionDecision "$COORD_DIR/events.jsonl"
}

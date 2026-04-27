#!/usr/bin/env bats
# Tests for lib/cycle_detection.sh per Phase 5 T5.05 + PR-PHASE5-03 + PR-PHASE5-04.
#
# Categories:
#   1. Basic cycle detection      (4 tests: 2/3/4-cycle + no-cycle)
#   2. Single-waiter / empty      (2 tests)
#   3. Edge cases                 (3 tests)
#   4. Bipartite traversal        (2 tests)
#   5. Bash 3.2 iterative compat  (2 tests)
#   6. coord_cycle_describe       (2 tests)
#   7. Trigger integration        (3 tests via wait_queue.sh)

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-cd-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mkdir -p "$COORD_DIR/wakers" "$COORD_DIR/wait_queues"
  mk_empty_sessions "$COORD_DIR"
  : >"$COORD_DIR/events.jsonl"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/cycle_detection.sh"
}
teardown() {
  rm -rf "$TMP"
}

# Helpers ---------------------------------------------------------

# _setup_lock <file> <sid>
_setup_lock() {
  local f="$1" sid="$2"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f] = {session: $sid, acquired_at: "t", last_refresh_at: "t", tasks: []}
     | .sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
        registered_at: "y", last_activity_at: "z", git_head: "", prompt_id: null,
        script_version: "1.0"})' \
    --arg f "$f" --arg sid "$sid"
}

# _enqueue <sid> <file>
_enqueue() {
  local sid="$1" f="$2"
  SESSION_ID="$sid" coord_wait_queue_enqueue "$sid" "$f" >/dev/null
}

# ----- Category 1: Basic cycle detection -----

@test "cycle_detection: 2-cycle (A waits B, B waits A) → cycle detected" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/foo"
  run coord_cycle_detect "sid-B"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Sessions list contains both sids.
  echo "$output" | jq -e '.sessions | length == 2 and (contains(["sid-A"]) and contains(["sid-B"]))'
  # Files list contains both files.
  echo "$output" | jq -e '.files  | length == 2 and (contains(["/p/foo"]) and contains(["/p/bar"]))'
  # 4 edges: 2 waits_for + 2 held_by.
  echo "$output" | jq -e '(.edges | length) == 4'
  echo "$output" | jq -e '(.edges | map(select(.type == "waits_for")) | length) == 2'
  echo "$output" | jq -e '(.edges | map(select(.type == "held_by"))   | length) == 2'
  # CYCLE_DETECTED event emitted.
  sleep 0.1
  run grep -c '"kind":"CYCLE_DETECTED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "cycle_detection: 3-cycle (A→bar→B→baz→C→foo→A) → cycle detected" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _setup_lock "/p/baz" "sid-C"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/baz"
  _enqueue "sid-C" "/p/foo"
  run coord_cycle_detect "sid-C"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | jq -e '.sessions | length == 3'
  echo "$output" | jq -e '.files    | length == 3'
  echo "$output" | jq -e '.edges    | length == 6'
}

@test "cycle_detection: 4-cycle → cycle detected" {
  _setup_lock "/p/f1" "sid-A"
  _setup_lock "/p/f2" "sid-B"
  _setup_lock "/p/f3" "sid-C"
  _setup_lock "/p/f4" "sid-D"
  _enqueue "sid-A" "/p/f2"
  _enqueue "sid-B" "/p/f3"
  _enqueue "sid-C" "/p/f4"
  _enqueue "sid-D" "/p/f1"
  run coord_cycle_detect "sid-D"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sessions | length == 4'
  echo "$output" | jq -e '.edges    | length == 8'
}

@test "cycle_detection: no cycle (linear A waits B holds, B waits C holds, C no wait) → empty" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _setup_lock "/p/baz" "sid-C"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/baz"
  # sid-C does not wait on anything → no return path.
  run coord_cycle_detect "sid-A"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 0.1
  run grep -c '"kind":"CYCLE_DETECTION_RAN"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

# ----- Category 2: Single-waiter / empty -----

@test "cycle_detection: single waiter on a file → no cycle" {
  _setup_lock "/p/foo" "sid-A"
  _enqueue "sid-B" "/p/foo"
  # sid-A holds /p/foo and is not waiting on anything → cycle from
  # sid-B leads to sid-A which has no outgoing edge.
  run coord_cycle_detect "sid-B"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cycle_detection: empty wait_queues → no cycle" {
  _setup_lock "/p/foo" "sid-A"
  run coord_cycle_detect "sid-A"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----- Category 3: Edge cases -----

@test "cycle_detection: self-loop (waits for self-held lock) → defensive empty" {
  # This is an impossible production state (you don't wait on your
  # own lock; pre_tool_use_write.sh has a self-write fast path) but
  # a corrupt state could expose it; detector must not infinite-loop.
  _setup_lock "/p/foo" "sid-A"
  _enqueue "sid-A" "/p/foo"
  run coord_cycle_detect "sid-A"
  [ "$status" -eq 0 ]
  # Whether or not the detector reports this as a cycle is
  # implementation-defined — but it MUST terminate quickly.
}

@test "cycle_detection: detect from any cycle member returns same cycle" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/foo"
  out_a=$(coord_cycle_detect "sid-A")
  out_b=$(coord_cycle_detect "sid-B")
  [ -n "$out_a" ]
  [ -n "$out_b" ]
  # Both cycles cover the same {sid-A, sid-B} ∪ {/p/foo, /p/bar} sets.
  echo "$out_a" | jq -e '(.sessions | sort) == (["sid-A","sid-B"] | sort)'
  echo "$out_b" | jq -e '(.sessions | sort) == (["sid-A","sid-B"] | sort)'
}

@test "cycle_detection: disjoint cycles in graph → returns the one containing trigger" {
  # Graph 1: sid-A ↔ sid-B (cycle on /p/f1, /p/f2)
  # Graph 2: sid-C ↔ sid-D (cycle on /p/g1, /p/g2)
  _setup_lock "/p/f1" "sid-A"
  _setup_lock "/p/f2" "sid-B"
  _enqueue "sid-A" "/p/f2"
  _enqueue "sid-B" "/p/f1"
  _setup_lock "/p/g1" "sid-C"
  _setup_lock "/p/g2" "sid-D"
  _enqueue "sid-C" "/p/g2"
  _enqueue "sid-D" "/p/g1"
  out=$(coord_cycle_detect "sid-A")
  echo "$out" | jq -e '(.sessions | sort) == (["sid-A","sid-B"] | sort)'
  ! echo "$out" | jq -e '.sessions | contains(["sid-C"])'
}

# ----- Category 4: Bipartite traversal -----

@test "cycle_detection: edges alternate session→file (waits_for) and file→session (held_by)" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/foo"
  out=$(coord_cycle_detect "sid-A")
  # Every "from" of waits_for must be a sid (no leading slash).
  echo "$out" | jq -e '
    .edges
    | map(select(.type == "waits_for") | .from)
    | all(startswith("/") | not)
  '
  # Every "from" of held_by must be a file (leading slash).
  echo "$out" | jq -e '
    .edges
    | map(select(.type == "held_by") | .from)
    | all(startswith("/"))
  '
}

@test "cycle_detection: visited set prevents infinite loop on dense graph" {
  # 4 sessions where each waits on every other's file (creates many
  # potential paths but only one true 4-cycle).
  for sid in A B C D; do _setup_lock "/p/$sid" "sid-$sid"; done
  _enqueue "sid-A" "/p/B"
  _enqueue "sid-B" "/p/C"
  _enqueue "sid-C" "/p/D"
  _enqueue "sid-D" "/p/A"
  # Add cross-edges that don't form additional cycles.
  _enqueue "sid-A" "/p/D"  # extra wait — but D→A already in cycle
  run coord_cycle_detect "sid-A"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ----- Category 5: Bash 3.2 iterative compat -----

@test "cycle_detection: 10-session deep cycle → detected, no stack overflow" {
  for i in 0 1 2 3 4 5 6 7 8 9; do
    _setup_lock "/p/f$i" "sid-$i"
  done
  for i in 0 1 2 3 4 5 6 7 8 9; do
    nxt=$(( (i + 1) % 10 ))
    _enqueue "sid-$i" "/p/f$nxt"
  done
  run coord_cycle_detect "sid-0"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | jq -e '.sessions | length == 10'
}

@test "cycle_detection: 20-session graph completes within 2s" {
  # 20 sessions, 19 of which wait on sid-0's lock. sid-0 holds /p/f0
  # and waits on nothing → no cycle. (sid-0 NOT enqueued onto its
  # own lock to avoid the self-loop edge case.)
  for i in 0 1 2 3 4 5 6 7 8 9 a b c d e f g h i j; do
    _setup_lock "/p/f$i" "sid-$i"
  done
  for i in 1 2 3 4 5 6 7 8 9 a b c d e f g h i j; do
    _enqueue "sid-$i" "/p/f0"
  done
  t0=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  run coord_cycle_detect "sid-0"
  t1=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')
  elapsed=$(( t1 - t0 ))
  echo "elapsed_ms=$elapsed (no cycle expected; budget <2000ms)"
  [ "$elapsed" -lt 2000 ]
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----- Category 6: coord_cycle_describe -----

@test "cycle_detection: describe output includes session/file pairs" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/foo"
  cycle=$(coord_cycle_detect "sid-A")
  desc=$(coord_cycle_describe "$cycle")
  echo "$desc" | grep -q "Deadlock detected"
  echo "$desc" | grep -q "sid-A"
  echo "$desc" | grep -q "sid-B"
  echo "$desc" | grep -q "/p/foo"
  echo "$desc" | grep -q "/p/bar"
  echo "$desc" | grep -q "holds"
  echo "$desc" | grep -q "waits for"
}

@test "cycle_detection: describe includes 3-tier eviction priority guidance" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/foo"
  cycle=$(coord_cycle_detect "sid-A")
  desc=$(coord_cycle_describe "$cycle")
  echo "$desc" | grep -q "Eviction priority"
  echo "$desc" | grep -q "oldest last_activity_at"
  echo "$desc" | grep -q "fewest locks_held"
  echo "$desc" | grep -q "youngest session_age"
}

# ----- Category 7: Trigger integration -----

@test "cycle_detection: wait_queue.sh enqueue depth=2 invokes coord_cycle_detect (real, not stub)" {
  # When cycle_detection.sh is sourced, the real detector runs;
  # CYCLE_DETECTION_SKIPPED_T5_05_PENDING is NOT emitted.
  _setup_lock "/p/foo" "sid-A"
  _enqueue "sid-A" "/p/foo"   # depth=1, no detection
  _enqueue "sid-B" "/p/foo"   # depth=2, detection fires
  sleep 0.1
  run grep -c '"kind":"CYCLE_DETECTION_SKIPPED_T5_05_PENDING"' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
  run grep -c '"kind":"CYCLE_DETECTION_RAN"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "cycle_detection: cycle detected → cycle_detected pending entry written" {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-B" "/p/foo"   # depth=2 on /p/foo, cycle present
  cycle=$(coord_cycle_detect "sid-B")
  [ -n "$cycle" ]
  # Now exercise the producer half explicitly.
  pending_ts=$(coord_cycle_emit_pending "$cycle")
  [ -n "$pending_ts" ]
  [ -f "$COORD_DIR/mediator/pending.jsonl" ]
  run grep -c '"kind":"cycle_detected"' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
  # Payload contains the rich schema fields.
  run jq -r 'select(.kind=="cycle_detected") | .payload | keys | join(",")' "$COORD_DIR/mediator/pending.jsonl"
  for k in cycle_path cycle_description involved_files involved_sessions queue_depth_at_detection recent_cycle_count session_metadata trigger_file trigger_session_id; do
    case "$output" in *"$k"*) : ;; *) echo "missing payload key: $k"; return 1 ;; esac
  done
}

@test "cycle_detection: enqueue with cycle present → pending.jsonl appended (full integration)" {
  # The depth ≥ 2 trigger requires ≥2 waiters on the same file AND
  # the trigger session must be in the cycle (DFS only finds cycles
  # passing through the start_sid). Setup:
  #   - A holds /p/foo, A waits /p/bar (depth 1 on bar — no trigger)
  #   - B holds /p/bar
  #   - C waits /p/foo (depth 1 on foo — no trigger; C is unrelated)
  #   - B enqueues /p/foo (depth 2 on foo — TRIGGER fires from B,
  #     and B IS in the A↔B cycle: B→foo→A→bar→B closes)
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  _enqueue "sid-A" "/p/bar"
  _enqueue "sid-C" "/p/foo"
  _enqueue "sid-B" "/p/foo"   # depth=2 on /p/foo, triggers from sid-B
  sleep 0.2
  [ -f "$COORD_DIR/mediator/pending.jsonl" ]
  run grep -c '"kind":"cycle_detected"' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
}

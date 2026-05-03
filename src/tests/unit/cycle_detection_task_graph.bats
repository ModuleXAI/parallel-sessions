#!/usr/bin/env bats
# Tests for lib/cycle_detection.sh::coord_cycle_detect_task_graph
# (Phase 6 T6.02 + PR-PHASE6-03 + ambiguity dispositions A/B at
# T6.01 close, with rc/stderr contract per T6.02 user binding
# 2026-04-27 P2 reorder).
#
# Categories:
#   1. Usage / trivial gates             (3 tests)
#   2. Happy paths (depth 1/2/3)         (3 tests)
#   3. Depth exceeded (rc 1)             (2 tests)
#   4. Cycle detected (rc 2)             (3 tests)
#   5. Cycle-wins-over-depth combo       (1 test)
#   6. Edges + visited-set hygiene       (3 tests)
#   7. Event emission                    (3 tests)

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-cdtg-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mk_empty_sessions "$COORD_DIR"
  : >"$COORD_DIR/events.jsonl"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/cycle_detection.sh"
}
teardown() {
  rm -rf "$TMP"
}

# Helpers ---------------------------------------------------------

# _ensure_session <sid>
_ensure_session() {
  local sid="$1"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1,
        pid_lstart: "x", registered_at: "y", last_activity_at: "z",
        git_head: "", prompt_id: null, script_version: "1.0"})' \
    --arg sid "$sid"
}

# _make_lock_with_tasks <file> <holder> [opener_of_task1] [target_no_op]
#   Set up locks[<file>] with holder + an empty tasks[] array.
#   Use _add_task to append tasks afterwards.
_make_lock_with_tasks() {
  local f="$1" sid="$2"
  _ensure_session "$sid"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f] = {session: $sid, acquired_at: "t",
        last_refresh_at: "t", tasks: []}' \
    --arg f "$f" --arg sid "$sid"
}

# _add_task <file> <opener_sid> [task_id]
#   Append a minimal task entry to locks[<file>].tasks[]. Only the
#   .opener field is consumed by coord_cycle_detect_task_graph.
_add_task() {
  local f="$1"
  local opener="$2"
  local tid="${3:-tid-$f-$opener}"
  _ensure_session "$opener"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f].tasks += [{
        task_id: $tid, opener: $op, file: $f, instruction: "x",
        complexity: "SIMPLE", anchor: {search: "x",
        window_lines: "1-2"}, created_at: "t",
        affected_lines_at_open: [1, 2], status: "PENDING"
      }]' \
    --arg f "$f" --arg op "$opener" --arg tid "$tid"
}

# ----- Category 1: Usage / trivial gates -----

@test "task_graph: usage error rc 3 when no args" {
  run coord_cycle_detect_task_graph
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "usage: coord_cycle_detect_task_graph"
}

@test "task_graph: target file not locked → rc 0 (no edge to add)" {
  _ensure_session "sid-B"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "task_graph: target file held by start_sid → rc 0 (self-delegation case)" {
  _make_lock_with_tasks "/p/foo" "sid-B"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----- Category 2: Happy paths -----

@test "task_graph: depth 1 (B → A; A has no opened tasks) → rc 0" {
  _make_lock_with_tasks "/p/foo" "sid-A"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "task_graph: depth 2 (B → A → C; A opened task on F2 held by C) → rc 0" {
  _make_lock_with_tasks "/p/foo" "sid-A"
  _make_lock_with_tasks "/p/bar" "sid-C"
  _add_task "/p/bar" "sid-A"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "task_graph: depth 3 (B → A → C → D; chain ends at depth 3) → rc 0" {
  _make_lock_with_tasks "/p/foo" "sid-A"
  _make_lock_with_tasks "/p/bar" "sid-C"
  _make_lock_with_tasks "/p/baz" "sid-D"
  _add_task "/p/bar" "sid-A"
  _add_task "/p/baz" "sid-C"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----- Category 3: Depth exceeded -----

@test "task_graph: depth 4 (B → A → C → D → E) → rc 1 + stderr 'Chain depth exceeded'" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-C"
  _make_lock_with_tasks "/p/f3" "sid-D"
  _make_lock_with_tasks "/p/f4" "sid-E"
  _add_task "/p/f2" "sid-A"
  _add_task "/p/f3" "sid-C"
  _add_task "/p/f4" "sid-D"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Chain depth exceeded (max 3)"
  echo "$output" | grep -q "rejected"
  # Path render contains all 5 sessions (B + A + C + D + E).
  echo "$output" | grep -q "sid-B"
  echo "$output" | grep -q "sid-E"
}

@test "task_graph: depth 5 → rc 1 (deeper rejection still surfaces depth violation)" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-C"
  _make_lock_with_tasks "/p/f3" "sid-D"
  _make_lock_with_tasks "/p/f4" "sid-E"
  _make_lock_with_tasks "/p/f5" "sid-F"
  _add_task "/p/f2" "sid-A"
  _add_task "/p/f3" "sid-C"
  _add_task "/p/f4" "sid-D"
  _add_task "/p/f5" "sid-E"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Chain depth exceeded"
}

# ----- Category 4: Cycle detected -----

@test "task_graph: 2-cycle (B opens on F1 held by A; A has task on F2 held by B) → rc 2" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-B"
  _add_task "/p/f2" "sid-A"   # A → B via task on F2
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "Task cycle detected"
  echo "$output" | grep -q "rejected"
  # Path renders B → A → B.
  echo "$output" | grep -q "sid-B → sid-A → sid-B"
}

@test "task_graph: 3-session cycle B → A → C → B → rc 2" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-C"
  _make_lock_with_tasks "/p/f3" "sid-B"
  _add_task "/p/f2" "sid-A"
  _add_task "/p/f3" "sid-C"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "Task cycle detected"
  echo "$output" | grep -q "sid-B → sid-A → sid-C → sid-B"
}

@test "task_graph: cycle through only one intermediate (no extra branches) → rc 2" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-B"
  _add_task "/p/f2" "sid-A"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 2 ]
}

# ----- Category 5: Cycle-wins-over-depth combo -----

@test "task_graph: depth-3 + cycle combo → rc 2 (cycle wins per user binding)" {
  # B → A → C → D → B  (would also trigger depth 4 → rc 1)
  # Cycle check fires first inside the loop → rc 2.
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-C"
  _make_lock_with_tasks "/p/f3" "sid-D"
  _make_lock_with_tasks "/p/f4" "sid-B"
  _add_task "/p/f2" "sid-A"
  _add_task "/p/f3" "sid-C"
  _add_task "/p/f4" "sid-D"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "Task cycle detected"
}

# ----- Category 6: Edges + visited-set hygiene -----

@test "task_graph: empty task graph (no tasks anywhere) → rc 0" {
  _make_lock_with_tasks "/p/foo" "sid-A"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
}

@test "task_graph: orphan task (task whose file has no current lock) → rc 0 (edge dead)" {
  _make_lock_with_tasks "/p/foo" "sid-A"
  # /p/bar has no lock entry; A's task targets it but holder lookup is empty.
  _ensure_session "sid-A"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks["/p/foo"].tasks += [{
        task_id: "tid-orphan", opener: "sid-A", file: "/p/bar",
        instruction: "x", complexity: "SIMPLE",
        anchor: {search: "x", window_lines: "1-2"},
        created_at: "t", affected_lines_at_open: [1, 2],
        status: "PENDING"
      }]'
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  # Note: /p/bar appears as the task's .file but locks[/p/bar] is
  # absent → next_holder is empty → edge dead → no traversal.
  [ "$status" -eq 0 ]
}

@test "task_graph: visited-set prevents infinite loop on dense graph (no cycle)" {
  # 4 sessions in a diamond: B → A → {C,D} → E (E not back to anyone).
  # A opens 2 tasks (one on F-C, one on F-D), C opens task on F-E,
  # D opens task on F-E. visited_arr ensures E is not pushed twice.
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/fc" "sid-C"
  _make_lock_with_tasks "/p/fd" "sid-D"
  _make_lock_with_tasks "/p/fe" "sid-E"
  _add_task "/p/fc" "sid-A"
  _add_task "/p/fd" "sid-A"
  _add_task "/p/fe" "sid-C"
  _add_task "/p/fe" "sid-D"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  # Depth: B → A (1) → {C,D} (2) → E (3). All within bound; no cycle.
  [ "$status" -eq 0 ]
}

# ----- Category 7: Event emission -----

@test "task_graph: rc 0 path emits CYCLE_DETECTION_TASK_GRAPH_RAN with result=ok" {
  _make_lock_with_tasks "/p/foo" "sid-A"
  run coord_cycle_detect_task_graph "sid-B" "/p/foo"
  [ "$status" -eq 0 ]
  sleep 0.1
  run grep -c '"kind":"CYCLE_DETECTION_TASK_GRAPH_RAN"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  run grep -c '"result":"ok"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "task_graph: rc 1 (depth) emits TASK_GRAPH_VIOLATION_DETECTED with violation=depth" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-C"
  _make_lock_with_tasks "/p/f3" "sid-D"
  _make_lock_with_tasks "/p/f4" "sid-E"
  _add_task "/p/f2" "sid-A"
  _add_task "/p/f3" "sid-C"
  _add_task "/p/f4" "sid-D"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 1 ]
  sleep 0.1
  run grep -c '"kind":"TASK_GRAPH_VIOLATION_DETECTED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  # violation kind sits in .payload (not the top-level .kind, which
  # is reserved by coord_log_event for the event-kind itself).
  jq -e 'select(.kind=="TASK_GRAPH_VIOLATION_DETECTED") | .payload.violation == "depth"' \
    "$COORD_DIR/events.jsonl"
}

@test "task_graph: rc 2 (cycle) emits TASK_GRAPH_VIOLATION_DETECTED with violation=cycle" {
  _make_lock_with_tasks "/p/f1" "sid-A"
  _make_lock_with_tasks "/p/f2" "sid-B"
  _add_task "/p/f2" "sid-A"
  run coord_cycle_detect_task_graph "sid-B" "/p/f1"
  [ "$status" -eq 2 ]
  sleep 0.1
  run grep -c '"kind":"TASK_GRAPH_VIOLATION_DETECTED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  jq -e 'select(.kind=="TASK_GRAPH_VIOLATION_DETECTED") | .payload.violation == "cycle"' \
    "$COORD_DIR/events.jsonl"
}

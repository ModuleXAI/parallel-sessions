#!/usr/bin/env bash
# 03_chain_depth_cycle_rejected — Plan §5 Phase 6 Done-when #3:
# "Chain depth > 3 or cycle → rejected with clear error."
# Two sub-scenarios: chain depth exceeded + 2-cycle. Both
# rejected at CLI level (Decision 6 — exit 1 + stderr; NO
# Mediator escalation; NO permissionDecision).
set -uo pipefail

scenario_run() {
  local sid_a="sid-a-03"
  local sid_b="sid-b-03"
  local sid_c="sid-c-03"
  local sid_d="sid-d-03"
  local sid_e="sid-e-03"
  for s in "$sid_a" "$sid_b" "$sid_c" "$sid_d" "$sid_e"; do
    coord_fixture_p6_register_session "$s"
  done

  # Seed files (need anchor matches).
  printf 'function fn1() { return 1; }\n' >"$WORKDIR/f1.ts"
  printf 'function fn2() { return 2; }\n' >"$WORKDIR/f2.ts"
  printf 'function fn3() { return 3; }\n' >"$WORKDIR/f3.ts"
  printf 'function fn4() { return 4; }\n' >"$WORKDIR/f4.ts"

  # SUB-SCENARIO A: chain depth.
  # Build chain: A holds f1; A opened task on f2 (held by C); C opened
  # task on f3 (held by D); D opened task on f4 (held by E). Then B
  # tries to open task on f1 (held by A) — would extend chain to
  # depth 4 from B's perspective: B → A → C → D → E.
  coord_fixture_p6_acquire "$WORKDIR/f1.ts" "$sid_a"
  coord_fixture_p6_acquire "$WORKDIR/f2.ts" "$sid_c"
  coord_fixture_p6_acquire "$WORKDIR/f3.ts" "$sid_d"
  coord_fixture_p6_acquire "$WORKDIR/f4.ts" "$sid_e"

  # Inject existing tasks via direct atomic_edit (bypasses CLI to
  # set up the chain state without triggering cycle/depth checks
  # against partial state).
  for entry in \
      "$WORKDIR/f2.ts $sid_a tid-A-on-f2" \
      "$WORKDIR/f3.ts $sid_c tid-C-on-f3" \
      "$WORKDIR/f4.ts $sid_d tid-D-on-f4"; do
    set -- $entry
    f="$1"; opener="$2"; tid="$3"
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f].tasks += [{
        task_id:$tid, opener:$op, file:$f,
        instruction:"x", complexity:"SIMPLE",
        anchor:{search:"x", window_lines:"1-2"},
        rationale:null, created_at:"t",
        affected_lines_at_open:[1,2], status:"PENDING",
        outcome_diff:null, outcome_rationale:null, outcome_at:null
      }]' \
      --arg f "$f" --arg op "$opener" --arg tid "$tid"
  done

  # B attempts task-open on f1 → would create depth-4 chain
  # (B → A → C → D → E). Should reject.
  set +e
  CHAIN_OUT=$(coord_fixture_p6_task_open "$sid_b" "$WORKDIR/f1.ts" \
    SIMPLE \
    '{"search":"function fn1","window_lines":"1-1"}' \
    "edit" 2>&1)
  CHAIN_RC=$?
  set -e
  export CHAIN_OUT CHAIN_RC

  # SUB-SCENARIO B: 2-cycle (separate lock state).
  printf 'function fn5() { return 5; }\n' >"$WORKDIR/f5.ts"
  printf 'function fn6() { return 6; }\n' >"$WORKDIR/f6.ts"
  local sid_x="sid-x-03"
  local sid_y="sid-y-03"
  coord_fixture_p6_register_session "$sid_x"
  coord_fixture_p6_register_session "$sid_y"
  coord_fixture_p6_acquire "$WORKDIR/f5.ts" "$sid_x"
  coord_fixture_p6_acquire "$WORKDIR/f6.ts" "$sid_y"
  # X has task on f6 (held by Y) — pre-existing edge X→Y.
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f].tasks += [{
      task_id:"tid-X-on-f6", opener:$op, file:$f,
      instruction:"x", complexity:"SIMPLE",
      anchor:{search:"x", window_lines:"1-2"},
      rationale:null, created_at:"t",
      affected_lines_at_open:[1,2], status:"PENDING",
      outcome_diff:null, outcome_rationale:null, outcome_at:null
    }]' \
    --arg f "$WORKDIR/f6.ts" --arg op "$sid_x"
  # Y attempts task-open on f5 (held by X) — would close cycle X→Y→X.
  set +e
  CYCLE_OUT=$(coord_fixture_p6_task_open "$sid_y" "$WORKDIR/f5.ts" \
    SIMPLE \
    '{"search":"function fn5","window_lines":"1-1"}' \
    "edit" 2>&1)
  CYCLE_RC=$?
  set -e
  export CYCLE_OUT CYCLE_RC

  export SID_A="$sid_a" SID_B="$sid_b" SID_X="$sid_x" SID_Y="$sid_y"
  sleep 0.1
}

scenario_assert() {
  local fail=0

  # SUB-SCENARIO A — chain depth.
  if [ "$CHAIN_RC" != "1" ]; then
    printf '  FAIL 1: chain coord task-open rc=%s; expected 1\n' \
      "$CHAIN_RC" >&2
    fail=1
  fi
  if ! printf '%s' "$CHAIN_OUT" | grep -q "Chain depth exceeded"; then
    printf '  FAIL 2: stderr missing "Chain depth exceeded": %s\n' \
      "$CHAIN_OUT" >&2
    fail=1
  fi
  # Path render shows the chain.
  if ! printf '%s' "$CHAIN_OUT" | grep -q "$SID_B"; then
    printf '  FAIL 3: chain path render missing B\n' >&2
    fail=1
  fi
  # Task NOT persisted on f1.
  local n_tasks
  n_tasks=$(jq -r --arg f "$WORKDIR/f1.ts" '.locks[$f].tasks | length' \
    "$COORD_DIR/sessions.json")
  if [ "$n_tasks" != "0" ]; then
    printf '  FAIL 4: chain task persisted despite rejection (n=%s)\n' \
      "$n_tasks" >&2
    fail=1
  fi

  # SUB-SCENARIO B — cycle.
  if [ "$CYCLE_RC" != "1" ]; then
    printf '  FAIL 5: cycle coord task-open rc=%s; expected 1\n' \
      "$CYCLE_RC" >&2
    fail=1
  fi
  if ! printf '%s' "$CYCLE_OUT" | grep -q "Task cycle detected"; then
    printf '  FAIL 6: stderr missing "Task cycle detected": %s\n' \
      "$CYCLE_OUT" >&2
    fail=1
  fi
  # Cycle path render contains both X and Y.
  if ! printf '%s' "$CYCLE_OUT" | grep -q "$SID_Y.*$SID_X.*$SID_Y"; then
    printf '  FAIL 7: cycle path render missing Y → X → Y\n' >&2
    printf '         OUT=%s\n' "$CYCLE_OUT" >&2
    fail=1
  fi
  # Task NOT persisted on f5.
  n_tasks=$(jq -r --arg f "$WORKDIR/f5.ts" '.locks[$f].tasks | length' \
    "$COORD_DIR/sessions.json")
  if [ "$n_tasks" != "0" ]; then
    printf '  FAIL 8: cycle task persisted despite rejection (n=%s)\n' \
      "$n_tasks" >&2
    fail=1
  fi

  # Phase 6 invariant — neither rejection emitted permissionDecision.
  if printf '%s\n%s' "$CHAIN_OUT" "$CYCLE_OUT" \
       | grep -q '"permissionDecision"'; then
    printf '  FAIL 9: permissionDecision found in CLI output (Phase 6 invariant)\n' >&2
    fail=1
  fi

  # Phase 6 invariant — no Mediator pending entry written for
  # task-graph cycles (Decision 6 — task graph cycles route via
  # CLI rejection, NOT Mediator pending kind).
  if [ -f "$COORD_DIR/mediator/pending.jsonl" ]; then
    if grep -q '"task_cycle' "$COORD_DIR/mediator/pending.jsonl"; then
      printf '  FAIL 10: task_cycle Mediator pending entry written (Decision 6 violation)\n' >&2
      fail=1
    fi
  fi

  return "$fail"
}

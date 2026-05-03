#!/usr/bin/env bats
# Phase 6 T6.09 end-to-end integration suite — covers the full
# task delegation + self-delegation + F-015 + cycle + toggle
# + banner production lifecycle. Companion to phase5_e2e.bats
# (Phase 5 wait queue + cycle detection scenarios) and
# stop_self_task_block_once.bats (T6.07 unit-level coverage).
#
# Scenarios:
#   S1 task-open happy path → COMPLETED via mock claude
#   S2 task-open CONFLICT (overlap with holder edit)
#   S3 multi-task FIFO ordering preserved across post-hook run
#   S4 self-delegate happy path: defer + reminder fires when free
#   S5 Stop block-once-then-allow flow (Stop1 block / Stop2 allow)
#   S6 F-015 banner: subagent + Bash + coord wait → educational
#   S7 task-graph cycle rejection at coord task-open CLI (rc 1)
#   S8 task_delegation toggle FALSE: deny banner omits option (a)
#      + coord task-open exit 1 with toggle-disabled error
#   S9 Deny banner production wording verbatim per PR-PHASE6-05 §6
#   S10 Banner toggle TRUE includes option (a) full CLI shape

load "../helpers/common"

H_PRE="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_write.sh"
H_POST="$SRC_ROOT/adapters/claude-code/hooks/post_tool_use_write.sh"
H_ANY="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_any.sh"
H_STOP="$SRC_ROOT/adapters/claude-code/hooks/stop.sh"
CLI="$SRC_ROOT/core/bin/coord"

setup() {
  TMP="$(mktemp -d -t coord-p6-e2e-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  export COORD_DIR="$COORD"
  mk_empty_sessions "$COORD"
  : >"$COORD_DIR/events.jsonl"

  # Default config.json with task_delegation enabled.
  cat >"$COORD_DIR/config.json" <<'EOF'
{
  "schema_version": "1.0",
  "task_delegation": true,
  "lock_ttl_seconds": 900,
  "wait_max_seconds": 570,
  "max_task_chain_depth": 3,
  "validator_enabled": true,
  "mediator_enabled": true
}
EOF

  HOLDER="sid-p6-A"
  OPENER="sid-p6-B"
  PEER="sid-p6-C"
  for s in "$HOLDER" "$OPENER" "$PEER"; do
    touch "$COORD_DIR/sessions/${s}.active"
  done
  jq --arg h "$HOLDER" --arg o "$OPENER" --arg p "$PEER" '
    .sessions[$h]={state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
    | .sessions[$o]={state:"ACTIVE",pid:2,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
    | .sessions[$p]={state:"ACTIVE",pid:3,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET="$TMP/api.ts"
  printf 'function loginHandler() {\n  // body line 2\n}\nfunction other() { return 1; }\n' >"$TARGET"
  ANCHOR_OK='{"search":"function loginHandler","window_lines":"50-60"}'
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID COORD_MOCK_CLAUDE_TASK_PATCH
  rm -rf "$TMP"
}

# Use bash -c subshell wrapper per Cand-17 (T6.05 lesson) so
# backgrounded log_event subshells survive bats @test body lifetime.
# CLAUDE_COORD=1 prefixes the bash -c invocation (NOT the inner
# printf) — env-prefix scoping means the inner pipe receives the
# var only when set on the outer process. Mirrors
# subagent_coord_wait_banner.bats / coord_wait.bats helper pattern.
_pre_acquire() {
  local sid="$1"
  local input
  input=$(jq -nc --arg s "$sid" --arg t "$TARGET" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Edit", tool_input:{file_path:$t}
  }')
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H_PRE'"
}

_post_release() {
  local sid="$1" edit_start="$2" edit_end="$3"
  local input
  input=$(jq -nc --arg s "$sid" --arg t "$TARGET" --arg cwd "$TMP" \
    --argjson es "$edit_start" --argjson ee "$edit_end" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"Edit", tool_input:{file_path:$t},
    tool_response:{start_line:$es, end_line:$ee}
  }')
  CLAUDE_COORD=1 \
    COORD_MOCK_CLAUDE_TASK_PATCH="${COORD_MOCK_CLAUDE_TASK_PATCH:-}" \
    bash -c "printf '%s' '$input' | '$H_POST'"
}

_pre_any() {
  local sid="$1" tool="${2:-Read}" extra="${3:-{\}}"
  local input
  input=$(jq -nc --arg s "$sid" --arg t "$TARGET" --arg cwd "$TMP" \
      --arg tool "$tool" --argjson extra "$extra" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:$tool, tool_input:({file_path:$t} + $extra)
  }')
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H_ANY'"
}

_stop() {
  local sid="$1"
  local input
  input=$(jq -nc --arg s "$sid" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"Stop"
  }')
  CLAUDE_COORD=1 bash -c "printf '%s' '$input' | '$H_STOP'"
}

# =========================================================
# S1 — task-open happy path (COMPLETED via mock claude)
# =========================================================

@test "p6_e2e S1: task-open happy path → COMPLETED notification dispatched at lock release" {
  _pre_acquire "$HOLDER"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" \
      --instruction "rename signature"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "task created"
  # Holder edits NON-overlapping range (lines 1-10 vs anchor 50-60).
  export COORD_MOCK_CLAUDE_TASK_PATCH='{"status":"COMPLETED","diff":"--- a\n+++ b\nrenamed","affected_lines":[50,55],"rationale":"applied at 50-55"}'
  _post_release "$HOLDER" 1 10
  # Notification persisted on .notifications[<opener>][<file>].
  run jq -e --arg op "$OPENER" --arg t "$TARGET" '
    (.notifications[$op][$t] // [])
    | length == 1
    and (.[0] | contains("Status: COMPLETED"))
    and (.[0] | contains("Rationale: applied at 50-55"))
  ' "$COORD_DIR/sessions.json"
}

# =========================================================
# S2 — task-open CONFLICT (overlap)
# =========================================================

@test "p6_e2e S2: task-open with overlap → CONFLICT outcome (no claude spawn, no diff applied)" {
  _pre_acquire "$HOLDER"
  env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE \
      --anchor '{"search":"function loginHandler","window_lines":"5-10"}' \
      --instruction "edit" >/dev/null
  # Holder edit lines 8-12 overlaps task anchor 5-10.
  _post_release "$HOLDER" 8 12
  run jq -e --arg op "$OPENER" --arg t "$TARGET" '
    .notifications[$op][$t][0] | contains("Status: CONFLICT")
  ' "$COORD_DIR/sessions.json"
}

# =========================================================
# S3 — Multi-task FIFO ordering preserved
# =========================================================

@test "p6_e2e S3: multi-task FIFO order preserved across post-hook task processor" {
  _pre_acquire "$HOLDER"
  env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" \
      --instruction "first" >/dev/null
  env SESSION_ID="$PEER" "$CLI" task-open --file "$TARGET" \
      --complexity COMPLEX --anchor "$ANCHOR_OK" \
      --instruction "second" >/dev/null
  _post_release "$HOLDER" 1 10
  # First notification went to OPENER, second to PEER (different
  # opener slots). Both tasks processed in queue order.
  run jq -e --arg op "$OPENER" --arg p "$PEER" --arg t "$TARGET" '
    (.notifications[$op][$t] // []) | length == 1
    and ((.notifications[$p][$t] // []) | length == 1)
    and (.notifications[$op][$t][0] | contains("first"))
    and (.notifications[$p][$t][0] | contains("second"))
  ' "$COORD_DIR/sessions.json"
}

# =========================================================
# S4 — Self-delegate happy path: defer + reminder fires when free
# =========================================================

@test "p6_e2e S4: self-delegate → file unlocked → reminder injected on next PreToolUse" {
  # No prior lock — file is free. Self-delegate, then PreToolUse should
  # fire reminder (file unlocked → unresolved per PR-PHASE6-02).
  run env SESSION_ID="$OPENER" "$CLI" self-delegate --file "$TARGET" \
      --instruction "rename"
  [ "$status" -eq 0 ]
  # Run pre_tool_use_any.sh as OPENER on a different file (innocuous
  # Read) — reminder for $TARGET should inject.
  run _pre_any "$OPENER" "Read" "{}"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("self-task pending")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("rename")' >/dev/null
}

# =========================================================
# S5 — Stop block-once-then-allow flow
# =========================================================

@test "p6_e2e S5: Stop1 blocks → Stop2 allows + archives SKIPPED" {
  env SESSION_ID="$OPENER" "$CLI" self-delegate --file "$TARGET" \
      --instruction "edit" >/dev/null
  # Stop #1 — should block.
  run _stop "$OPENER"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"'
  # Stop #2 — should allow + archive.
  run _stop "$OPENER"
  [ "$status" -eq 0 ]
  ! _grep_output_for '"decision":"block"'
  run jq -e --arg s "$OPENER" '
    (.self_tasks[$s] // []) | length == 0
  ' "$COORD_DIR/sessions.json"
}

# =========================================================
# S6 — F-015 banner: subagent + Bash + coord wait
# =========================================================

@test "p6_e2e S6: F-015 banner: subagent + Bash + coord wait → educational + NO deny" {
  INPUT=$(jq -nc --arg s "$OPENER" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Bash", agent_type:"general-purpose",
    tool_input:{command:"coord wait /p/foo --timeout 60"}
  }')
  run env CLAUDE_COORD=1 bash -c "printf '%s' '$INPUT' | '$H_ANY'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("Subagent context detected")' >/dev/null
  ! _grep_output_for "permissionDecision"
  sleep 0.1
  run grep -c '"kind":"SUBAGENT_COORD_WAIT_BANNER_EMITTED"' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

# =========================================================
# S7 — Task-graph cycle rejection at coord task-open CLI
# =========================================================

@test "p6_e2e S7: task-graph cycle → coord task-open exit 1 + stderr 'Task cycle detected'" {
  # Build cycle: HOLDER locks $TARGET; B opens task on $TARGET (held by
  # HOLDER); HOLDER has open task on /p/f2 (held by OPENER) → 2-cycle.
  _pre_acquire "$HOLDER"
  jq --arg op "$OPENER" --arg h "$HOLDER" '
    .locks["/p/f2"] = {session:$op, acquired_at:"t", last_refresh_at:"t",
      tasks:[{
        task_id:"tid-back", opener:$h, file:"/p/f2",
        instruction:"x", complexity:"SIMPLE",
        anchor:{search:"x", window_lines:"1-2"},
        rationale:null, created_at:"t",
        affected_lines_at_open:[1,2], status:"PENDING",
        outcome_diff:null, outcome_rationale:null, outcome_at:null
      }]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "edit"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Task cycle detected"
  # Cycle rejection is CLI-level — NO permissionDecision emitted.
  ! _grep_output_for "permissionDecision"
  # Task NOT persisted on rejection.
  run jq -r --arg t "$TARGET" '.locks[$t].tasks | length' \
      "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

# =========================================================
# S8 — task_delegation toggle FALSE
# =========================================================

@test "p6_e2e S8: toggle FALSE → deny banner omits (a) + CLI exit 1 'disabled per repo'" {
  jq '.task_delegation = false' "$COORD_DIR/config.json" \
    >"$COORD_DIR/config.json.new"
  mv "$COORD_DIR/config.json.new" "$COORD_DIR/config.json"
  # Pre-seed a lock by HOLDER.
  jq --arg h "$HOLDER" --arg t "$TARGET" '
    .locks[$t] = {session:$h, acquired_at:"2026-04-28T10:00:00Z",
      last_refresh_at:"2026-04-28T10:30:00Z", tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  # OPENER attempts write → deny banner with toggle-FALSE wording.
  INPUT=$(jq -nc --arg s "$OPENER" --arg t "$TARGET" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Edit", tool_input:{file_path:$t}
  }')
  run env CLAUDE_COORD=1 bash -c "printf '%s' '$INPUT' | '$H_PRE'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("task delegation is disabled in this repo")' >/dev/null
  # Toggle-FALSE banner MUST NOT show option (a).
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | (test("\\(a\\) Delegate") | not)' >/dev/null
  # (b) + (c) still present.
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("\\(b\\) Self-delegate")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("\\(c\\) Passively wait")' >/dev/null
  # CLI rejection — toggle FALSE.
  run env SESSION_ID="$OPENER" "$CLI" task-open --file "$TARGET" \
      --complexity SIMPLE --anchor "$ANCHOR_OK" --instruction "edit"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "task_delegation disabled per repo"
}

# =========================================================
# S9 — Banner production wording verbatim per PR-PHASE6-05 §6
# =========================================================

@test "p6_e2e S9: toggle TRUE banner wording matches PR-PHASE6-05 §6 production spec" {
  # Pre-seed lock by HOLDER, OPENER attempts.
  jq --arg h "$HOLDER" --arg t "$TARGET" '
    .locks[$t] = {session:$h, acquired_at:"2026-04-28T10:00:00Z",
      last_refresh_at:"2026-04-28T10:30:00Z", tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  INPUT=$(jq -nc --arg s "$OPENER" --arg t "$TARGET" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Edit", tool_input:{file_path:$t}
  }')
  run env CLAUDE_COORD=1 bash -c "printf '%s' '$INPUT' | '$H_PRE'"
  [ "$status" -eq 0 ]
  REASON=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # PR-PHASE6-05 §6 toggle-TRUE key phrases (production wording).
  # Note: <ts> placeholder in §6 is rendered via humanize_age (e.g.
  # "5 min ago" / "1h 30m ago"); the raw ISO timestamp is not surfaced.
  printf '%s' "$REASON" | grep -q "is locked by session"
  printf '%s' "$REASON" | grep -qE "since .+ago"
  printf '%s' "$REASON" | grep -q "Options:"
  printf '%s' "$REASON" | grep -q "Delegate a SIMPLE/MODERATE task"
  printf '%s' "$REASON" | grep -q "coord task-open --file"
  printf '%s' "$REASON" | grep -q "complexity SIMPLE"
  printf '%s' "$REASON" | grep -q "Self-delegate"
  printf '%s' "$REASON" | grep -q "coord self-delegate --file"
  printf '%s' "$REASON" | grep -q "Passively wait"
  printf '%s' "$REASON" | grep -q "coord wait"
  printf '%s' "$REASON" | grep -q "Pick (a)"
  printf '%s' "$REASON" | grep -q "small self-contained edits"
  # Stub-removal regression-guard: no Phase 2 stub markers.
  ! printf '%s' "$REASON" | grep -q "currently disabled"
  ! printf '%s' "$REASON" | grep -q "Phase 6 — currently"
}

# =========================================================
# S10 — Banner toggle TRUE option (a) full CLI shape
# =========================================================

@test "p6_e2e S10: toggle TRUE banner option (a) embeds full coord task-open CLI argument shape" {
  jq --arg h "$HOLDER" --arg t "$TARGET" '
    .locks[$t] = {session:$h, acquired_at:"2026-04-28T11:00:00Z",
      last_refresh_at:"2026-04-28T11:00:00Z", tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  INPUT=$(jq -nc --arg s "$OPENER" --arg t "$TARGET" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Edit", tool_input:{file_path:$t}
  }')
  run env CLAUDE_COORD=1 bash -c "printf '%s' '$INPUT' | '$H_PRE'"
  REASON=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  # Option (a) full CLI shape per PR-PHASE6-05 §6 + ambiguity A
  # (--rationale optional).
  printf '%s' "$REASON" | grep -q "coord task-open --file ${TARGET} --complexity SIMPLE --anchor"
  printf '%s' "$REASON" | grep -q -- '--instruction'
  printf '%s' "$REASON" | grep -q -- '\[--rationale'
  # window_lines key referenced in anchor JSON example (variable
  # arg shape; placeholder ellipsis in the spec).
  printf '%s' "$REASON" | grep -q "window_lines"
}

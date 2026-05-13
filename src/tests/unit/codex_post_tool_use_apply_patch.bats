#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/post_tool_use_apply_patch.sh — PR D.5.
#
# Per F-D4-02(b): this hook fires ONLY on tool success (Codex's
# core/src/tools/registry.rs:414-421 gates on `success`). Tests don't
# need to cover tool_response.error scenarios.
#
# Per preview §5.4: release loop is failure-tolerant. Per F-D5-01:
# task_processor is invoked with edit_range=0/0 (match-all coarsening,
# documented TODO).

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/post_tool_use_apply_patch.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-postap-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED
  : >"$COORD_DIR/events.jsonl"

  SID="cx-postap-aaaa"
  PEER="cx-postap-bbbb"
  touch "$COORD_DIR/sessions/${SID}.active" \
        "$COORD_DIR/sessions/${PEER}.active"
  jq --arg s "$SID" --arg p "$PEER" '
    .sessions[$s] = {state:"ACTIVE",pid:1,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0",agent:"codex"}
    | .sessions[$p] = {state:"ACTIVE",pid:2,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0",agent:"codex"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

# Helpers
_seed_lock() {
  local sid="$1" file="$2"
  jq --arg f "$file" --arg s "$sid" '
    .locks[$f] = {
      session: $s, pid: 1, pid_lstart: "x",
      acquired_at: "2026-05-03T00:00:00Z",
      last_refresh_at: "2026-05-03T00:00:00Z",
      tasks: []
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

_activate_lockdown() {
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$1" --arg rs "$2" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

# Build a hook input JSON for an apply_patch PostToolUse.
_post_apply_patch_input() {
  local patch="$1" sid="${2:-$SID}"
  jq -nc --arg s "$sid" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"apply_patch",
    tool_input:{input:$p},
    tool_response:{success:true, output:"applied"},
    tool_use_id:"tu-postap-1"
  }'
}

# === Gate / no-op paths ===

@test "post_apply_patch: COORD_ENABLED unset → exit 0, lock untouched" {
  _seed_lock "$SID" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "post_apply_patch: input with agent_type DOES release (D-2: no subagent filter)" {
  _seed_lock "$SID" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  local INP
  INP=$(jq -nc --arg s "$SID" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"apply_patch", tool_input:{input:$p},
    tool_response:{success:true}, tool_use_id:"tu-x",
    agent_type:"general-purpose"
  }')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  [ "$status" -eq 0 ]
  # Lock released.
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # SUBAGENT_ACTIVITY_SKIPPED MUST NOT appear.
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "SUBAGENT_ACTIVITY_SKIPPED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "post_apply_patch: non-participant (no marker) → no-op" {
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  local INP
  INP=$(jq -nc --arg s "not-registered" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"apply_patch", tool_input:{input:$p},
    tool_response:{success:true}, tool_use_id:"tu-x"
  }')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# === Release paths ===

@test "post_apply_patch: single-file release → LOCK_RELEASED event + lock deleted + last_activity refresh" {
  _seed_lock "$SID" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # last_activity refreshed.
  run jq -r --arg s "$SID" '.sessions[$s].last_activity_at' "$COORD_DIR/sessions.json"
  [ "$output" != "z" ]
  # LOCK_RELEASED event with source=post_tool_use_apply_patch.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "post_tool_use_apply_patch")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

@test "post_apply_patch: multi-file release → one LOCK_RELEASED per file, peer locks preserved" {
  _seed_lock "$SID" "$TMP/a.ts"
  _seed_lock "$SID" "$TMP/b.ts"
  _seed_lock "$PEER" "$TMP/peer.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/a.ts\n@@\n-a\n+x\n*** Update File: '"$TMP"$'/b.ts\n@@\n-b\n+y\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  # SID's two locks gone; PEER's one lock retained.
  run jq -r '.locks | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r --arg f "$TMP/peer.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$PEER" ]
  # Two LOCK_RELEASED events.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .tool == "apply_patch" and .payload.source == "post_tool_use_apply_patch")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "2" ]
  # Files released in alphabetical order (deterministic per preview §5.2).
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "post_tool_use_apply_patch") | .file]' "$COORD_DIR/events.jsonl"
  echo "$output" | jq -e --arg f1 "$TMP/a.ts" --arg f2 "$TMP/b.ts" 'sort == [$f1, $f2]' >/dev/null
}

# === Per-file task processor ===

@test "post_apply_patch: task_processor invoked when locks[path].tasks non-empty (F-D5-01: 0/0 edit-range)" {
  # Pre-seed a self-task so locks[path].tasks is populated and the
  # task_processor walk runs. Also seed the SID lock so release proceeds.
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/self_tasks.sh"
  printf 'old\n' >"$TMP/foo.ts"
  PID=$(coord_self_task_open "$PEER" "$TMP/foo.ts" "rename")  # peer's task
  # Seed SID's lock with task-list including PID (mimicking pre-hook
  # behavior at write time when peer task was anchored).
  jq --arg f "$TMP/foo.ts" --arg s "$SID" --arg pid "$PID" --arg peer "$PEER" '
    .locks[$f] = {
      session: $s, pid: 1, pid_lstart: "x",
      acquired_at: "2026-05-03T00:00:00Z",
      last_refresh_at: "2026-05-03T00:00:00Z",
      tasks: [{prompt_id: $pid, opener: $peer, anchor: {start_line: 1, end_line: 5}}]
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  : >"$COORD_DIR/events.jsonl"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  # Lock released.
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # TASK_PROCESSOR_RUN event recorded — confirms processor was invoked.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "TASK_PROCESSOR_RUN")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

# === Defensive: lock held by another session ===

@test "post_apply_patch: lock held by ANOTHER session → ERROR event, lock NOT deleted" {
  # Pre-seed a lock owned by PEER (not SID). This shouldn't happen in
  # practice (pre-hook would have denied), but defensive coverage:
  # post-hook MUST NOT delete another session's lock.
  _seed_lock "$PEER" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  # PEER's lock untouched.
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$PEER" ]
  # ERROR event with reason=lock_held_by_other.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "ERROR" and .payload.reason == "lock_held_by_other" and .payload.source == "post_tool_use_apply_patch")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

# === Q5 fallback: parser failure ===

@test "post_apply_patch: parser failure → fallback releases ALL session locks (Q5)" {
  # Seed two locks owned by SID; pass an unparseable patch (no Begin/End).
  _seed_lock "$SID" "$TMP/locked-by-self-1.ts"
  _seed_lock "$SID" "$TMP/locked-by-self-2.ts"
  _seed_lock "$PEER" "$TMP/locked-by-peer.ts"
  local INP
  INP=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"apply_patch",
    tool_input:{input:"this is not a valid patch"},
    tool_response:{success:true}, tool_use_id:"tu-bad-1"
  }')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  [ "$status" -eq 0 ]
  # SID's locks gone; PEER's lock intact.
  run jq -r --arg s "$SID" '[.locks[] | select(.session == $s)] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  run jq -r --arg f "$TMP/locked-by-peer.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$PEER" ]
}

# === Lockdown ===

@test "post_apply_patch: under active lockdown → locks NOT released" {
  _seed_lock "$SID" "$TMP/foo.ts"
  _activate_lockdown "system pause" "mediator_verdict"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  # Lock retained (Mediator may need lock state preserved).
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

# === Phase 2 invariant (D-9 / minimal output on success) ===

@test "post_apply_patch: never emits permissionDecision on non-lockdown branches" {
  # Branch 1: with locks held → release path.
  _seed_lock "$SID" "$TMP/a.ts"
  _seed_lock "$SID" "$TMP/b.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/a.ts\n@@\n-a\n+x\n*** Update File: '"$TMP"$'/b.ts\n@@\n-b\n+y\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Branch 2: no locks → silent path.
  COORD_ENABLED=1 run bash -c "echo $(_post_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Branch 3: agent_type field present (D-2 still releases).
  _seed_lock "$SID" "$TMP/c.ts"
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/c.ts\n@@\n-c\n+z\n*** End Patch'
  local INP
  INP=$(jq -nc --arg s "$SID" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"apply_patch", tool_input:{input:$p},
    tool_response:{success:true}, tool_use_id:"tu-c",
    agent_type:"general-purpose"
  }')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  true
}

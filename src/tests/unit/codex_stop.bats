#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/stop.sh — PR D.2.
#
# Mirror coverage of src/tests/unit/stop.bats and stop_self_task_block_once.bats
# adapted for Codex semantics:
#   - COORD_ENABLED=1 (canonical) is the participation gate.
#   - No subagent filter per D-2: an `agent_type` field on the input does NOT
#     suppress lock release (Codex has no subagent concept).
#   - Per D-10, Codex has no SessionEnd. This hook is the ONLY graceful-release
#     point; the watchdog handles dead-session cleanup separately.
#   - Self-task block-once-then-allow semantic carries (Codex Stop input has
#     stop_hook_active per Codex events/stop.rs:30).
#   - Lockdown gate identical to Claude (deny envelope + skip release).

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/stop.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-stop-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED
  : >"$COORD_DIR/events.jsonl"

  SID="cx-stop-aaaa"
  PEER="cx-stop-bbbb"
  touch "$COORD_DIR/sessions/${SID}.active" "$COORD_DIR/sessions/${PEER}.active"
  jq --arg a "$SID" --arg b "$PEER" '
    .sessions[$a]={state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0",agent:"codex"}
    | .sessions[$b]={state:"ACTIVE",pid:2,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0",agent:"codex"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET1="$TMP/foo.ts"; TARGET2="$TMP/bar.ts"
  printf 'foo\n' >"$TARGET1"; printf 'bar\n' >"$TARGET2"

  STOP_INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" \
    '{session_id:$s, cwd:$cwd, hook_event_name:"Stop", stop_hook_active:false, last_assistant_message:"done"}')
  STOP_AGENT_TYPE=$(jq -nc --arg s "$SID" --arg cwd "$TMP" \
    '{session_id:$s, cwd:$cwd, hook_event_name:"Stop", agent_type:"general-purpose"}')
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

# Helper: pre-seed a lock owned by $1 on $2 (lock structure is agent-agnostic
# at the JSON state level; D.4 will wire up the Codex pre_tool_use hook to
# acquire locks from real apply_patch input, but for D.2 we only need the
# lock-release surface, so pre-seeding is sufficient).
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
  local reason="$1" reason_source="$2"
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$reason" --arg rs "$reason_source" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

# Source self_tasks helpers for tests that exercise the block-once path.
_source_self_tasks() {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/self_tasks.sh"
}

# === Gate / no-op paths ===

@test "codex stop: COORD_ENABLED unset → exit 0, lock untouched" {
  _seed_lock "$SID" "$TARGET1"
  run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run jq -r --arg f "$TARGET1" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "codex stop: input with agent_type DOES release (D-2: no subagent filter)" {
  # Claude's stop.sh treats agent_type as SubagentStop and skips. Codex
  # has no subagent concept (D-2): the field is unknown / ignored and
  # the lock IS released.
  _seed_lock "$SID" "$TARGET1"
  COORD_ENABLED=1 run bash -c "echo '$STOP_AGENT_TYPE' | '$H'"
  [ "$status" -eq 0 ]
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Lock released.
  run jq -r --arg f "$TARGET1" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  # SUBAGENT_ACTIVITY_SKIPPED MUST NOT appear.
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "SUBAGENT_ACTIVITY_SKIPPED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "codex stop: non-participant session (no marker) → no-op" {
  local INPUT
  INPUT=$(jq -nc --arg s "not-registered" --arg cwd "$TMP" \
    '{session_id:$s, cwd:$cwd, hook_event_name:"Stop"}')
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "codex stop: no locks held → silent no-op (idempotency basis for repeat Stops)" {
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  sleep 0.3
  if [ -f "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "LOCK_RELEASED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

# === Lock-release paths ===

@test "codex stop: single-lock release → LOCK_RELEASED event (source=stop) + lock entry deleted" {
  _seed_lock "$SID" "$TARGET1"
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Lock gone.
  run jq -r --arg f "$TARGET1" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  # last_activity_at refreshed (no longer "z").
  run jq -r --arg s "$SID" '.sessions[$s].last_activity_at' "$COORD_DIR/sessions.json"
  [ "$output" != "z" ]
  # LOCK_RELEASED event emitted with source=stop.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "stop")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

@test "codex stop: multi-lock release → one LOCK_RELEASED per file, peer locks preserved" {
  _seed_lock "$SID" "$TARGET1"
  _seed_lock "$SID" "$TARGET2"
  # Peer lock on a third file MUST survive.
  local PEER_TARGET="$TMP/peer.ts"
  printf 'peer\n' >"$PEER_TARGET"
  _seed_lock "$PEER" "$PEER_TARGET"

  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # SID's two locks gone; PEER's one lock retained.
  run jq -r '.locks | length' "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
  run jq -r --arg f "$PEER_TARGET" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$PEER" ]
  # Two LOCK_RELEASED events, both source=stop, files are TARGET1+TARGET2.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "stop")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "2" ]
  run jq -rs --arg f1 "$TARGET1" --arg f2 "$TARGET2" '
    [.[] | select(.kind == "LOCK_RELEASED" and .payload.source == "stop") | .file] | sort
    == ([$f1, $f2] | sort)
  ' "$COORD_DIR/events.jsonl"
  [ "$output" = "true" ]
}

# === Self-task block-once-then-allow ===

@test "codex stop: unresolved self-task (count=0) → decision:block + reminder + count→1" {
  _source_self_tasks
  PID=$(coord_self_task_open "$SID" "$TARGET1" "rename")
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block"' >/dev/null
  echo "$output" | jq -e '.reason | test("Stop blocked")' >/dev/null
  echo "$output" | jq -e '.reason | test("rename")' >/dev/null
  # No permissionDecision (Phase 2 invariant).
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Block count incremented.
  run jq -r --arg s "$SID" --arg pid "$PID" \
    '.self_tasks[$s] | map(select(.prompt_id == $pid)) | .[0].stop_block_count' \
    "$COORD_DIR/sessions.json"
  [ "$output" = "1" ]
}

@test "codex stop: second Stop (count=1) → allow + archive SKIPPED + locks released" {
  _source_self_tasks
  PID=$(coord_self_task_open "$SID" "$TARGET1" "edit")
  # Simulate first Stop's effect.
  coord_self_task_increment_stop_block "$SID" "$PID" >/dev/null
  : >"$COORD_DIR/events.jsonl"
  # Pre-seed a lock so we can verify release proceeds in the same Stop.
  _seed_lock "$SID" "$TARGET2"
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  ! _grep_output_for '"decision":"block"'
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Self-task archived.
  run jq -e --arg s "$SID" '(.self_tasks[$s] // []) | length == 0' "$COORD_DIR/sessions.json"
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "SELF_TASK_ARCHIVED" and .payload.reason == "stop_second_attempt")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # Lock on TARGET2 ALSO released in the same Stop (allow path proceeds to release).
  run jq -r --arg f "$TARGET2" '.locks[$f].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
}

# === Lockdown gate ===

@test "codex stop: under active lockdown → emits deny + locks NOT released" {
  _seed_lock "$SID" "$TARGET1"
  _activate_lockdown "system pause" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "Stop"' >/dev/null
  # Lock retained (Mediator may need to inspect).
  run jq -r --arg f "$TARGET1" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

# === Phase 2 invariant: never permissionDecision in any branch ===

@test "codex stop: ship gate — never sets permissionDecision in non-lockdown branches" {
  # Branch 1: with locks held → release path.
  _seed_lock "$SID" "$TARGET1"; _seed_lock "$SID" "$TARGET2"
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Branch 2: no locks → silent path.
  COORD_ENABLED=1 run bash -c "echo '$STOP_INPUT' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  # Branch 3: agent_type field present (D-2: still runs release path; no skip).
  _seed_lock "$SID" "$TARGET1"
  COORD_ENABLED=1 run bash -c "echo '$STOP_AGENT_TYPE' | '$H'"
  case "$output" in *permissionDecision*) return 1 ;; esac
  true
}

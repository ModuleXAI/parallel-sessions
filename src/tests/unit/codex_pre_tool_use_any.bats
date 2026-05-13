#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/pre_tool_use_any.sh — PR D.4
# (plan v1.3, A-D4-02).
#
# This hook is BOOKKEEPING-ONLY on Codex. Per F-D4-04, every test must
# assert BOTH that stdout has no additionalContext AND that the
# bookkeeping side effect occurred — banner removal must NOT regress
# bookkeeping.

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/pre_tool_use_any.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-pany-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED
  : >"$COORD_DIR/events.jsonl"

  (
    cd "$TMP"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'a\n' >a.txt
    git add a.txt
    git commit -q -m one
  )
  HEAD_A=$(git -C "$TMP" rev-parse HEAD)

  SID="cx-pany-aaaa"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg s "$SID" --arg head "$HEAD_A" '
    .sessions[$s] = {
      state: "ACTIVE", pid: 1, pid_lstart: "x",
      registered_at: "2026-04-01T00:00:00Z",
      last_activity_at: "2026-04-01T00:00:00Z",
      git_head: $head, prompt_id: null, script_version: "1.0",
      agent: "codex"
    }
    | .read_sets[$s] = {reads: []}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  INPUT=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"some_tool", tool_input:{}, tool_use_id:"tu-1"
  }')
  INPUT_AGENT_TYPE=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"some_tool", tool_input:{}, tool_use_id:"tu-2",
    agent_type:"general-purpose"
  }')
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

_activate_lockdown() {
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$1" --arg rs "$2" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

# === Gate / no-op paths ===

@test "codex pre_tool_use_any: COORD_ENABLED unset → exit 0, no state change" {
  run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "codex pre_tool_use_any: input with agent_type still runs (D-2: no subagent filter)" {
  # Pre-seed a notification so we can verify the bookkeeping ran.
  jq --arg s "$SID" '.notifications[$s] = {"/tmp/x":["msg"]}' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  COORD_ENABLED=1 run bash -c "echo '$INPUT_AGENT_TYPE' | '$H'"
  [ "$status" -eq 0 ]
  # No SUBAGENT_ACTIVITY_SKIPPED
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "SUBAGENT_ACTIVITY_SKIPPED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
  # Notification atomic clear ran (bookkeeping-not-regressed).
  run jq -r --arg s "$SID" '.notifications[$s]["/tmp/x"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "codex pre_tool_use_any: non-participant → no-op" {
  local INP
  INP=$(jq -nc --arg s "not-registered" --arg cwd "$TMP" \
    '{session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
      tool_name:"x", tool_input:{}, tool_use_id:"tu-x"}')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# === D-D4-02 INVARIANT: never additionalContext + bookkeeping STILL runs ===

@test "codex pre_tool_use_any: notification clear runs WITHOUT additionalContext (F-D4-04)" {
  jq --arg s "$SID" '
    .notifications[$s] = {"/tmp/foo.ts": ["lock_released: foo"]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # Stdout invariant: no additionalContext (and ideally empty).
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
  # Bookkeeping: notification atomic clear ran.
  run jq -r --arg s "$SID" '.notifications[$s]["/tmp/foo.ts"] | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  # NOTIFICATION_DELIVER event recorded (audit trail intact).
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "NOTIFICATION_DELIVER" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "codex pre_tool_use_any: HEAD drift mark runs WITHOUT additionalContext (F-D4-04)" {
  # Pre-seed a stored HEAD that differs from current.
  jq --arg s "$SID" '
    .sessions[$s].git_head = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    | .read_sets[$s] = {reads: [{path:"/tmp/foo.ts", hash:"aaa"}]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # No additionalContext on stdout.
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
  # Bookkeeping: read-set marked superseded_by_head_change.
  run jq -r --arg s "$SID" '.read_sets[$s].reads[0].superseded_by_head_change // false' "$COORD_DIR/sessions.json"
  [ "$output" = "true" ]
  # Stored HEAD now matches the actual current.
  run jq -r --arg s "$SID" '.sessions[$s].git_head' "$COORD_DIR/sessions.json"
  [ "$output" = "$HEAD_A" ]
  # HEAD_CHANGE event logged.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "HEAD_CHANGE" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "codex pre_tool_use_any: mediator-pending consume runs WITHOUT additionalContext (F-D4-04)" {
  mkdir -p "$COORD_DIR/mediator"
  jq -nc '{ts:"2026-05-03T00:00:00Z", kind:"flock_timeout", session:"other-sid", source:"mediator", payload:{}}' \
    >"$COORD_DIR/mediator/pending.jsonl"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # No additionalContext on stdout.
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
  # Bookkeeping: MEDIATOR_PENDING_DELIVERED event logged with source.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "MEDIATOR_PENDING_DELIVERED" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "codex pre_tool_use_any: self-task reminder bookkeeping runs WITHOUT additionalContext (F-D4-04)" {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/self_tasks.sh"
  PID=$(coord_self_task_open "$SID" "$TMP/foo.ts" "rename")
  : >"$COORD_DIR/events.jsonl"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  # No additionalContext on stdout.
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  fi
  # SELF_TASK_REMINDER event was logged (audit trail for future re-routing).
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "SELF_TASK_REMINDER" and .payload.source == "pre_tool_use_any")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # Reminder throttle recorded.
  run jq -r --arg s "$SID" --arg pid "$PID" \
    '.self_tasks[$s] | map(select(.prompt_id == $pid)) | .[0].last_reminded_at // ""' \
    "$COORD_DIR/sessions.json"
  [ -n "$output" ]
}

# === Lockdown gate ===

@test "codex pre_tool_use_any: under active lockdown → emits permissionDecision deny" {
  _activate_lockdown "system pause" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
}

# === Verdict consumer (apply actions, advance pointer, no banner) ===

@test "codex pre_tool_use_any: mediator verdict applied + pointer advanced WITHOUT banner" {
  # Pre-seed an auto_apply verdict file and confirm:
  #   1. Pointer advances.
  #   2. No additionalContext on stdout.
  #   3. message_to_caller is NOT exposed on output.
  mkdir -p "$COORD_DIR/mediator/verdict"
  local VTS="2026-05-03T01-00-00Z"
  jq -nc --arg msg "Mediator-side message that should NOT reach the model" '{
    action_type: "release_lock",
    confidence: "auto_apply",
    depth: 1,
    message_to_caller: $msg,
    actions: []
  }' >"$COORD_DIR/mediator/verdict/${VTS}.json"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
    # Confirm the verdict's message_to_caller is NOT in stdout.
    case "$output" in
      *"Mediator-side message"*) return 1 ;;
    esac
  fi
  # Pointer advanced.
  run cat "$COORD_DIR/sessions/${SID}.last_consumed_verdict"
  [ "$output" = "$VTS" ]
}

# === Phase-2 invariant: never additionalContext on any branch ===

@test "codex pre_tool_use_any: D-D4-02 invariant — never additionalContext on any branch" {
  # Branch 1: gate-disabled.
  run bash -c "echo '$INPUT' | '$H'"
  [ -z "$output" ] || echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Branch 2: happy allow.
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ -z "$output" ] || echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Branch 3: with notification → still no additionalContext.
  jq --arg s "$SID" '.notifications[$s] = {"/tmp/x":["m"]}' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  [ -z "$output" ] || echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Branch 4: lockdown deny — permissionDecision only, no additionalContext.
  _activate_lockdown "x" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo '$INPUT' | '$H'"
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
}

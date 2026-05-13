#!/usr/bin/env bats
# Tests for lib/verdict_apply.sh — verdict-action apply helpers
# (Phase 3 / T3.07 / PR-PHASE3-01 implementation).
#
# Coverage:
#   - coord_verdict_apply_release_lock: held by self / held by other / absent
#   - coord_verdict_apply_evict_session: full eviction (sessions, locks,
#     read_sets, notifications, .active marker)
#   - coord_verdict_apply_clear_read_set: empties reads but preserves row
#   - coord_verdict_apply_action dispatcher
#   - coord_verdict_apply_actions iteration
#   - Idempotency: every helper run twice = same result

load "../helpers/common"

VA="$SRC_ROOT/core/lib/verdict_apply.sh"
AW="$SRC_ROOT/core/lib/atomic_write.sh"
LE="$SRC_ROOT/core/lib/log_event.sh"

setup() {
  TMP="$(mktemp -d -t coord-verdict-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  SID="target-session-001"
  OBSERVER="observer-001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",last_activity_at:"z"}
    | .read_sets[$sid] = {reads:[{path:"/foo",hash:"h1",is_latest:true}]}
    | .notifications[$sid] = {"/bar":["msg"]}
    | .self_tasks[$sid] = []
    | .locks["/foo"] = {session:$sid,acquired_at:"a",last_refresh_at:"a",tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

teardown() {
  unset COORD_DIR
  rm -rf "$TMP"
}

_apply() {
  bash -c '. "'"$LE"'"; . "'"$AW"'"; . "'"$VA"'"; '"$*"
}

@test "release_lock: held by named session → atomic delete + LOCK_RELEASED event" {
  _apply "coord_verdict_apply_release_lock /foo $SID"
  run jq -r '.locks["/foo"].session // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "LOCK_RELEASED" and .payload.released_session == "'"$SID"'")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "release_lock: held by ANOTHER session → no-op + warning" {
  run _apply "coord_verdict_apply_release_lock /foo $OBSERVER"
  # Lock untouched.
  run jq -r '.locks["/foo"].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "release_lock: absent lock → idempotent no-op rc=0" {
  _apply "coord_verdict_apply_release_lock /not-locked $SID"
  run _apply "coord_verdict_apply_release_lock /not-locked $SID"
  [ "$status" -eq 0 ]
}

@test "evict_session: removes session + locks + read_sets + notifications + .active marker" {
  _apply "coord_verdict_apply_evict_session $SID"
  run jq -r '.sessions["'"$SID"'"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  run jq -r '.read_sets["'"$SID"'"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  run jq -r '.notifications["'"$SID"'"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  [ ! -e "$COORD_DIR/sessions/${SID}.active" ]
}

@test "evict_session: idempotent (run twice = same result)" {
  _apply "coord_verdict_apply_evict_session $SID"
  _apply "coord_verdict_apply_evict_session $SID"
  run jq -r '.sessions["'"$SID"'"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
}

@test "clear_read_set: empties reads but keeps row + other fields" {
  _apply "coord_verdict_apply_clear_read_set $SID"
  run jq -r '(.read_sets["'"$SID"'"].reads // []) | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  # Session row still present.
  run jq -r '.sessions["'"$SID"'"].state' "$COORD_DIR/sessions.json"
  [ "$output" = "ACTIVE" ]
  # Lock still held (clear_read_set is read-set-only).
  run jq -r '.locks["/foo"].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "apply_action dispatcher: routes release_lock by op field" {
  local action='{"op":"release_lock","target":"/foo","session":"'"$SID"'"}'
  _apply "coord_verdict_apply_action '$action'"
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
}

@test "apply_action dispatcher: unknown op returns 1" {
  run _apply 'coord_verdict_apply_action "{\"op\":\"nuke_planet\"}"'
  [ "$status" -ne 0 ]
}

@test "apply_actions iteration: applies multiple actions in array order" {
  local actions='[
    {"op":"release_lock","target":"/foo","session":"'"$SID"'"},
    {"op":"clear_read_set","session":"'"$SID"'"}
  ]'
  _apply "coord_verdict_apply_actions '$actions'"
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  run jq -r '(.read_sets["'"$SID"'"].reads // []) | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "apply_actions: empty array returns 0 without mutation" {
  run _apply 'coord_verdict_apply_actions "[]"'
  [ "$status" -eq 0 ]
  run jq -r '.locks["/foo"].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

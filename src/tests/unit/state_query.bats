#!/usr/bin/env bats
# Tests for lib/state_query.sh per plan §4.

load "../helpers/common"

Q="$SRC_ROOT/lib/state_query.sh"
A="$SRC_ROOT/lib/atomic_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-state-query-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  export COORD_DIR="$COORD"
  mk_empty_sessions "$COORD"
}
teardown() { rm -rf "$TMP"; }

@test "state_query: dump on missing file returns empty template" {
  rm -f "$COORD/sessions.json"
  run "$Q" dump
  [ "$status" -eq 0 ]
  run bash -c "'$Q' dump | jq -r .schema_version"
  [ "$output" = "1.0" ]
}

@test "state_query: lock-holder reports empty for unlocked file" {
  run "$Q" lock-holder "/foo/bar.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state_query: lock-holder reports holder for locked file" {
  "$A" edit "$COORD/sessions.json" '.locks["/f/x.ts"] = {session:"sid-42", acquired_at:"t", last_refresh_at:"t", tasks:[]}'
  run "$Q" lock-holder "/f/x.ts"
  [ "$output" = "sid-42" ]
}

@test "state_query: is-locked 0|1" {
  run "$Q" is-locked "/f/y.ts"
  [ "$output" = "0" ]
  "$A" edit "$COORD/sessions.json" '.locks["/f/y.ts"] = {session:"s1", acquired_at:"t", last_refresh_at:"t", tasks:[]}'
  run "$Q" is-locked "/f/y.ts"
  [ "$output" = "1" ]
}

@test "state_query: notifications-for returns [] when none, else JSON array" {
  run "$Q" notifications-for "sid-unknown"
  [ "$output" = "[]" ]
  "$A" edit "$COORD/sessions.json" '.notifications["sid-foo"] = [{type:"stale_read", created_at:"t", payload:{file:"/x"}}]'
  run "$Q" notifications-for "sid-foo"
  [ "$status" -eq 0 ]
  run bash -c "echo '$output' | jq -r 'length'"
  [ "$output" = "1" ]
}

@test "state_query: active-sessions filters by state" {
  "$A" edit "$COORD/sessions.json" '
    .sessions = {
      "a": {state:"ACTIVE",      pid:1, pid_lstart:"x", registered_at:"t", last_activity_at:"t", git_head:"h"},
      "b": {state:"IDLE_ALIVE",  pid:2, pid_lstart:"y", registered_at:"t", last_activity_at:"t", git_head:"h"},
      "c": {state:"IDLE_CLOSED", pid:3, pid_lstart:"z", registered_at:"t", last_activity_at:"t", git_head:"h"}
    }'
  run "$Q" active-sessions
  # c should NOT appear.
  run bash -c "echo '$output' | sort | tr '\\n' ','"
  [ "$output" = "a,b," ]
}

@test "state_query: locks prints TSV rows per lock" {
  "$A" edit "$COORD/sessions.json" '
    .locks = {
      "/p/one.ts": {session:"s1", acquired_at:"t1", last_refresh_at:"t1", tasks:[]},
      "/p/two.ts": {session:"s2", acquired_at:"t2", last_refresh_at:"t2", tasks:[]}
    }'
  run "$Q" locks
  [ "$status" -eq 0 ]
  run bash -c "'$Q' locks | wc -l | tr -d ' '"
  [ "$output" = "2" ]
}

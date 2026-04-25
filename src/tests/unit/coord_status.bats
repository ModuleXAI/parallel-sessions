#!/usr/bin/env bats
# Tests for `coord status` (Phase 0 base + Phase 1 read-set extension).

load "../helpers/common"

C="$SRC_ROOT/bin/coord"

setup() {
  TMP="$(mktemp -d -t coord-status-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  # Seed two sessions with read-sets in varied states.
  jq '
    .sessions["sid-aaaa-1111"] = {state:"ACTIVE",pid:1001,pid_lstart:"x",registered_at:"2026-04-25T00:00:00Z",last_activity_at:"2026-04-25T00:01:00Z",git_head:"head1",prompt_id:null,script_version:"1.0"}
    | .sessions["sid-bbbb-2222"] = {state:"ACTIVE",pid:1002,pid_lstart:"y",registered_at:"2026-04-25T00:00:00Z",last_activity_at:"2026-04-25T00:02:00Z",git_head:"head1",prompt_id:null,script_version:"1.0"}
    | .read_sets["sid-aaaa-1111"] = {reads: [
        {path:"/repo/foo.ts", hash:"aaaa1111", is_latest:true,  at:"2026-04-25T00:00:30Z"},
        {path:"/repo/bar.ts", hash:"bbbb2222", is_latest:true,  at:"2026-04-25T00:00:45Z", superseded_by_head_change:true},
        {path:"/repo/baz.ts", hash:"cccc3333", is_latest:false, at:"2026-04-25T00:00:10Z", superseded_by:"new_prompt"}
      ]}
    | .read_sets["sid-bbbb-2222"] = {reads: [
        {path:"/repo/qux.ts", hash:"dddd4444", is_latest:true, at:"2026-04-25T00:01:00Z"}
      ]}
  ' "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
}

teardown() {
  unset COORD_DIR
  rm -rf "$TMP"
}

@test "coord status: shows active sessions and the new read_sets section" {
  run "$C" status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "schema_version=1.0"
  echo "$output" | grep -q "sid-aaaa"
  echo "$output" | grep -q "sid-bbbb"
  echo "$output" | grep -q "read_sets:"
}

@test "coord status: read_sets summary shows totals + flag counts per session" {
  run "$C" status
  [ "$status" -eq 0 ]
  # Session aaaa: 3 entries total, 2 is_latest (foo, bar), 1 head_invalidated (bar), 1 prompt_invalidated (baz).
  echo "$output" | grep "sid-aaaa" | grep "total=3"
  echo "$output" | grep "sid-aaaa" | grep "is_latest=2"
  echo "$output" | grep "sid-aaaa" | grep "head_invalidated=1"
  echo "$output" | grep "sid-aaaa" | grep "prompt_invalidated=1"
  # Session bbbb: 1 entry, 1 is_latest, 0 invalidated.
  echo "$output" | grep "sid-bbbb" | grep "total=1"
  echo "$output" | grep "sid-bbbb" | grep "is_latest=1"
  echo "$output" | grep "sid-bbbb" | grep "head_invalidated=0"
}

@test "coord status: empty read_sets shows '(none)' line" {
  jq '.read_sets = {}' "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run "$C" status
  [ "$status" -eq 0 ]
  echo "$output" | grep "read_sets: (none)"
}

@test "coord status --reads: detail listing shows file paths and flags" {
  run "$C" status --reads
  [ "$status" -eq 0 ]
  echo "$output" | grep "read_sets (detail):"
  echo "$output" | grep "/repo/foo.ts"
  echo "$output" | grep "/repo/bar.ts" | grep "HEAD!"
  echo "$output" | grep "/repo/baz.ts" | grep "NEW_PROMPT!"
  echo "$output" | grep "/repo/qux.ts"
}

@test "coord status: unknown flag → fail with usage hint" {
  run "$C" status --bogus
  [ "$status" -ne 0 ]
}

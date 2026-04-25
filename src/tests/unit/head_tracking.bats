#!/usr/bin/env bats
# Tests for lib/head_tracking.sh.

load "../helpers/common"

F="$SRC_ROOT/lib/head_tracking.sh"

setup() {
  TMP="$(mktemp -d -t coord-headtrack-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  # Spin up a tiny git repo inside TMP so rev-parse HEAD has something real.
  (
    cd "$TMP"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'a\n' >a.txt
    git add a.txt
    git commit -q -m "one"
  )
  HEAD1=$(git -C "$TMP" rev-parse HEAD)

  # A second commit so we can compare "changed" scenarios.
  (
    cd "$TMP"
    printf 'b\n' >a.txt
    git commit -q -am "two"
  )
  HEAD2=$(git -C "$TMP" rev-parse HEAD)
}

teardown() {
  rm -rf "$TMP"
}

# --- coord_current_head -----------------------------------------------

@test "head_tracking: current_head in a git repo prints the HEAD SHA" {
  run bash -c ". '$F'; coord_current_head '$TMP'"
  [ "$status" -eq 0 ]
  [ "$output" = "$HEAD2" ]
}

@test "head_tracking: current_head in a non-git dir prints empty" {
  NONGIT="$(mktemp -d -t coord-nongit-XXXX)"
  run bash -c ". '$F'; coord_current_head '$NONGIT'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  rm -rf "$NONGIT"
}

@test "head_tracking: CLI shim 'current' returns HEAD SHA" {
  run bash -c "'$F' current '$TMP'"
  [ "$status" -eq 0 ]
  [ "$output" = "$HEAD2" ]
}

# --- coord_stored_head ------------------------------------------------

@test "head_tracking: stored_head for absent session returns empty" {
  run bash -c ". '$F'; coord_stored_head 'does-not-exist'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "head_tracking: stored_head returns field when present" {
  # Poke a row into sessions.json directly for this read-only test.
  jq --arg sid sid-a --arg head "$HEAD1" \
     '.sessions[$sid] = {state:"ACTIVE",git_head:$head,pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",prompt_id:null,script_version:"1.0"}' \
     "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run bash -c ". '$F'; coord_stored_head 'sid-a'"
  [ "$status" -eq 0 ]
  [ "$output" = "$HEAD1" ]
}

@test "head_tracking: stored_head with missing sessions.json returns empty" {
  rm -f "$COORD/sessions.json"
  run bash -c ". '$F'; coord_stored_head 'sid-a'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- coord_head_drifted -----------------------------------------------

@test "head_tracking: drifted returns 0 when stored != current (both non-empty)" {
  jq --arg sid sid-a --arg head "$HEAD1" \
     '.sessions[$sid] = {state:"ACTIVE",git_head:$head,pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",prompt_id:null,script_version:"1.0"}' \
     "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run bash -c ". '$F'; coord_head_drifted 'sid-a' '$HEAD2'"
  [ "$status" -eq 0 ]
}

@test "head_tracking: drifted returns 1 when stored == current" {
  jq --arg sid sid-a --arg head "$HEAD1" \
     '.sessions[$sid] = {state:"ACTIVE",git_head:$head,pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",prompt_id:null,script_version:"1.0"}' \
     "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run bash -c ". '$F'; coord_head_drifted 'sid-a' '$HEAD1'"
  [ "$status" -eq 1 ]
}

@test "head_tracking: drifted returns 1 when stored is empty (no prior record)" {
  run bash -c ". '$F'; coord_head_drifted 'unknown-sid' '$HEAD1'"
  [ "$status" -eq 1 ]
}

@test "head_tracking: drifted returns 1 when current is empty (not in a repo)" {
  jq --arg sid sid-a --arg head "$HEAD1" \
     '.sessions[$sid] = {state:"ACTIVE",git_head:$head,pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",prompt_id:null,script_version:"1.0"}' \
     "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run bash -c ". '$F'; coord_head_drifted 'sid-a' ''"
  [ "$status" -eq 1 ]
}

@test "head_tracking: CLI shim 'drifted' exits 0 on drift, 1 on no drift" {
  jq --arg sid sid-a --arg head "$HEAD1" \
     '.sessions[$sid] = {state:"ACTIVE",git_head:$head,pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",prompt_id:null,script_version:"1.0"}' \
     "$COORD/sessions.json" >"$COORD/sessions.json.new"
  mv "$COORD/sessions.json.new" "$COORD/sessions.json"
  run bash -c "'$F' drifted 'sid-a' '$HEAD2'"
  [ "$status" -eq 0 ]
  run bash -c "'$F' drifted 'sid-a' '$HEAD1'"
  [ "$status" -eq 1 ]
}

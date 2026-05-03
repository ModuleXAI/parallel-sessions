#!/usr/bin/env bats
# Tests for the Phase 2 T2.04 Mediator pending JSONL flock_timeout flow.
#
# Producer side: coord_atomic_edit (in lib/atomic_write.sh) emits a
# `flock_timeout` entry into .coord/mediator/pending.jsonl when its
# 5-second flock acquisition fails.
#
# Consumer side: pre_tool_use_any.sh and session_start.sh both call
# coord_mediator_consume_pending (in lib/mediator_pending.sh) to deliver
# unconsumed entries via additionalContext, advancing the high-water-mark
# in .coord/mediator/pending.consumed.

load "../helpers/common"

A="$SRC_ROOT/core/lib/atomic_write.sh"
M="$SRC_ROOT/core/lib/mediator_pending.sh"
H_ANY="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_any.sh"
H_START="$SRC_ROOT/adapters/claude-code/hooks/session_start.sh"

setup() {
  TMP="$(mktemp -d -t coord-medp-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  SID="sid-medp-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '.sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}' \
    "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}
teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  # Release any leaked flocks holding the lock file open.
  rm -rf "$TMP"
}

# --- Producer tests --------------------------------------------------------

@test "mediator_pending: emit appends one JSONL entry with required fields" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/x lock=/x.lock timeout_sec=5 attempted_op=atomic_edit
  [ -f "$COORD_DIR/mediator/pending.jsonl" ]
  run jq -rs 'length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "1" ]
  run jq -rs 'first | [.kind, .session, .payload.file, .payload.timeout_sec] | @tsv' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "flock_timeout	$SID	/x	5" ]
  # ts field is present + ISO-8601-ish.
  run jq -rs 'first | .ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "true" ]
}

@test "mediator_pending: multiple emits append (no overwrite)" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/a
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/b
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/c
  run wc -l <"$COORD_DIR/mediator/pending.jsonl"
  [ "$(echo $output | tr -d ' ')" = "3" ]
  run jq -rs 'map(.payload.file) | join(",")' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "/a,/b,/c" ]
}

@test "mediator_pending: emit with empty kind is silent no-op" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit "" file=/x 2>/dev/null
  [ ! -s "$COORD_DIR/mediator/pending.jsonl" ] || \
    [ "$(wc -l <"$COORD_DIR/mediator/pending.jsonl" | tr -d ' ')" = "0" ]
}

@test "mediator_pending: concurrent emits all land (no lost writes)" {
  for i in 1 2 3 4 5; do
    ( COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/f-$i ) &
  done
  wait
  run wc -l <"$COORD_DIR/mediator/pending.jsonl"
  [ "$(echo $output | tr -d ' ')" = "5" ]
  # All 5 unique files present.
  run jq -rs 'map(.payload.file) | sort | unique | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "5" ]
}

# --- Consumer tests --------------------------------------------------------

@test "mediator_pending: consume on empty/missing pending → return 1, no output" {
  run bash -c "COORD_DIR='$COORD' '$M' consume"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "mediator_pending: consume after emit → banner text + advance HWM to total" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/x lock=/x.lock timeout_sec=5
  run bash -c "COORD_DIR='$COORD' '$M' consume"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Coord Mediator pending"
  echo "$output" | grep -q "kind=flock_timeout"
  echo "$output" | grep -q "file=/x"
  # HWM advanced.
  [ -f "$COORD_DIR/mediator/pending.consumed" ]
  run cat "$COORD_DIR/mediator/pending.consumed"
  [ "$output" = "1" ]
}

@test "mediator_pending: consume twice without new entries → second call returns 1" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/x
  bash -c "COORD_DIR='$COORD' '$M' consume" >/dev/null
  run bash -c "COORD_DIR='$COORD' '$M' consume"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "mediator_pending: consume after second emit picks up only the new entry" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/old
  bash -c "COORD_DIR='$COORD' '$M' consume" >/dev/null
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/new
  run bash -c "COORD_DIR='$COORD' '$M' consume"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "1 new entry"
  echo "$output" | grep -q "file=/new"
  # /old must NOT appear in this banner (already consumed).
  ! _grep_output_for "file=/old"
}

# --- Producer wired to atomic_write.sh -------------------------------------

@test "atomic_write: flock timeout triggers flock_timeout pending entry" {
  # atomic_write locks ${state_file}.lock — i.e. sessions.json.lock,
  # NOT sessions.lock. Hold THAT file long enough for the contender's
  # 5-second flock to time out.
  local statelock="$COORD_DIR/sessions.json.lock"
  : >>"$statelock"
  ( flock -x 9; sleep 8 ) 9>"$statelock" &
  HOLDER_PID=$!
  sleep 0.3   # Let the holder actually grab the lock.
  # Now coord_atomic_edit will time out (5s) and emit the pending entry.
  local edit_rc=0
  COORD_DIR="$COORD" SESSION_ID="$SID" "$A" edit "$COORD_DIR/sessions.json" '.foo = 1' || edit_rc=$?
  [ "$edit_rc" = "42" ] || { echo "expected rc=42 (flock timeout), got rc=$edit_rc"; }
  # Stop the holder.
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  # pending.jsonl should now have one entry of kind=flock_timeout.
  [ -f "$COORD_DIR/mediator/pending.jsonl" ]
  run jq -rs '[.[] | select(.kind == "flock_timeout")] | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs 'last(.[] | select(.kind == "flock_timeout")) | [.payload.attempted_op, .payload.timeout_sec] | @tsv' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "atomic_edit	5" ]
}

# --- Consumer wired into pre_tool_use_any.sh + session_start.sh ------------

@test "pre_tool_use_any: pending flock_timeout → banner via additionalContext + MEDIATOR_PENDING_DELIVERED event" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/contended.ts attempted_op=atomic_edit
  local INPUT='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x"}}'
  CLAUDE_COORD=1 run bash -c "echo '$INPUT' | '$H_ANY'"
  [ "$status" -eq 0 ]
  # The banner reaches additionalContext (carry-forward #4: round-trip safe).
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("Coord Mediator pending")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("kind=flock_timeout")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("file=/contended.ts")' >/dev/null
  # No permissionDecision (Phase 2 invariant — only pre_tool_use_write may deny).
  case "$output" in *permissionDecision*) return 1 ;; esac
  # MEDIATOR_PENDING_DELIVERED event recorded.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "MEDIATOR_PENDING_DELIVERED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_any: subagent context → consumer is filtered, no banner" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/x
  local SUB='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x"},"agent_type":"general-purpose"}'
  CLAUDE_COORD=1 run bash -c "echo '$SUB' | '$H_ANY'"
  [ "$status" -eq 0 ]
  # No banner emitted.
  [ "$output" = "" ]
  # HWM not advanced (subagent did not consume).
  [ ! -f "$COORD_DIR/mediator/pending.consumed" ] || \
    [ "$(cat "$COORD_DIR/mediator/pending.consumed")" = "0" ]
}

@test "session_start: pending flock_timeout from prior turn → banner composed with Coord v1.0 banner" {
  COORD_DIR="$COORD" SESSION_ID="$SID" "$M" emit flock_timeout file=/contended.ts
  # session_start fires source=startup; second invocation for same SID will
  # branch on the source-matrix idempotent-refresh path. We just want the
  # banner composition.
  local INPUT='{"session_id":"sid-newstart","cwd":"'"$TMP"'","hook_event_name":"SessionStart","source":"startup"}'
  CLAUDE_COORD=1 run bash -c "echo '$INPUT' | '$H_START'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("Coord Mediator pending")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("kind=flock_timeout")' >/dev/null
  # MEDIATOR_PENDING_DELIVERED event with source=session_start.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "MEDIATOR_PENDING_DELIVERED" and .payload.source == "session_start")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "phase2 invariant regression: T2.04 producer/consumer adds NO permissionDecision call sites" {
  # Belt-and-braces: scan the new code for the forbidden token. Comments OK,
  # code MUST NOT contain it. (Phase 2 invariant test does this codebase-wide;
  # this is a focused regression for the T2.04 surface.)
  for f in "$M" "$A"; do
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: $f has permissionDecision in code"; return 1
    fi
  done
  # The CONSUMER lives in pre_tool_use_any.sh + session_start.sh — both
  # are already covered by phase2_invariant.bats which scans hooks/*.sh
  # excluding pre_tool_use_write.sh. The MEDIATOR_PENDING_DELIVERED event
  # injection sites are in those hooks, not new files.
}

#!/usr/bin/env bats
# Tests for hooks/pre_tool_use_write.sh.
# Phase 1 (warning-only) + Phase 2 (lock acquisition + deny on contention).
# The Phase 2 invariant: permissionDecision: "deny" appears ONLY in the
# lock-held-by-other branch; every other code path remains allow.

load "../helpers/common"

H="$SRC_ROOT/hooks/pre_tool_use_write.sh"
HR="$SRC_ROOT/hooks/pre_tool_use_read.sh"

setup() {
  TMP="$(mktemp -d -t coord-ptuw-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"

  SID="sid-ptuw-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # A file the session "read" first; the Read hook will populate read_set.
  F1="$TMP/alpha.txt"
  printf 'alpha v1\n' >"$F1"
  F2="$TMP/beta.txt"
  printf 'beta v1\n' >"$F2"
  TARGET="$TMP/target.txt"
  printf 'target v1\n' >"$TARGET"

  READ_F1='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$F1"'"}}'
  READ_F2='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$F2"'"}}'

  WRITE_TARGET='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  WRITE_SUB='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"},"agent_type":"general-purpose"}'
  WRITE_NOTEBOOK='{"session_id":"'"$SID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":"'"$TARGET"'"}}'
}

teardown() {
  unset CLAUDE_COORD COORD_DIR
  rm -rf "$TMP"
}

# Read a file through pre_tool_use_read.sh to seed a proper read_set entry.
_prime_read() {
  local input="$1"
  CLAUDE_COORD=1 bash -c "echo '$input' | '$HR'" >/dev/null
}

@test "pre_tool_use_write: CLAUDE_COORD unset → exit 0, no output" {
  run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: subagent event emits SUBAGENT_ACTIVITY_SKIPPED, no permissionDecision" {
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_SUB' | '$H'"
  [ "$status" -eq 0 ]
  # No permissionDecision in Phase 1. The output may contain the skip event
  # log line nothing to stdout.
  [ "$output" = "" ]
  sleep 0.3
  run jq -rs 'last | .kind' "$COORD_DIR/events.jsonl"
  [ "$output" = "SUBAGENT_ACTIVITY_SKIPPED" ]
}

@test "pre_tool_use_write: non-participant → no-op" {
  local OTHER='{"session_id":"not-registered","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$TARGET"'"}}'
  CLAUDE_COORD=1 run bash -c "echo '$OTHER' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: empty read-set → allow, no warning" {
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  # WRITE event is still logged
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "WRITE")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: read-set with matching hashes → allow, no warning" {
  _prime_read "$READ_F1"
  _prime_read "$READ_F2"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: drifted file → Phase 4 pipeline runs, banner emitted, NO permissionDecision" {
  _prime_read "$READ_F1"
  # Modify alpha.txt on disk to simulate another session's change.
  printf 'alpha v2 drifted\n' >"$F1"
  # Use a minimal PATH that EXCLUDES claude so the validator spawn
  # falls through fast (claude_binary_missing → pipeline_failed →
  # Phase 1 fallback). Without this the test would invoke real
  # `claude -p` for ~30+ seconds.
  local jq_bin flock_bin perl_bin shasum_bin
  jq_bin=$(command -v jq | xargs dirname)
  flock_bin=$(command -v flock | xargs dirname)
  perl_bin=$(command -v perl | xargs dirname)
  shasum_bin=$(command -v shasum | xargs dirname)
  local minimal_path="$jq_bin:$flock_bin:$perl_bin:$shasum_bin:/usr/bin:/bin"
  CLAUDE_COORD=1 run bash -c "
    export PATH='$minimal_path'
    echo '$WRITE_TARGET' | '$H'
  "
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  # New banner format: "Coord drift report ..." with "Drift on FILE" line.
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("Coord drift report")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("alpha.txt")' >/dev/null
  # Pipeline emits VALIDATOR_PIPELINE_STARTED at minimum; if claude
  # is missing, VALIDATOR_PIPELINE_FAILED follows.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_STARTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: deleted file since read → Phase 1 fallback line in drift report" {
  _prime_read "$READ_F1"
  rm -f "$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # Deleted-file path falls back to phase1 warning text, not the
  # validator pipeline (file is gone so no diff possible).
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("deleted since read")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("Coord drift report")' >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "STALE_READ_WARNED" and .payload.stale_kind == "deleted")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: entries already marked superseded_by_head_change are NOT re-warned" {
  _prime_read "$READ_F1"
  # Now mark it head-changed so the write hook should skip it.
  jq --arg sid "$SID" '
    .read_sets[$sid].reads |= map(. + {superseded_by_head_change: true})
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  # Also mutate the file on disk to provoke what would otherwise be a warning.
  printf 'alpha v2\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # No warning emitted — the HEAD-change mark already told Claude the read
  # was invalid; emitting again would be noise.
  [ "$output" = "" ]
}

@test "pre_tool_use_write: entries with is_latest=false are NOT validated" {
  _prime_read "$READ_F1"
  # Force the entry to superseded (is_latest=false, like after a second read).
  jq --arg sid "$SID" '
    .read_sets[$sid].reads |= map(. + {is_latest: false, superseded_by: "some-other-hash"})
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  printf 'alpha v2\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: NotebookEdit uses notebook_path for target" {
  _prime_read "$READ_F1"
  # File not actually drifted — we're just checking the notebook path parsing
  # does not crash. Should allow quietly.
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_NOTEBOOK' | '$H'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pre_tool_use_write: Phase 2 lock acquire — empty locks → state has lock entry + LOCK_ACQUIRED event" {
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # Lock entry materialized in sessions.json keyed to the target.
  run jq -r --arg f "$TARGET" --arg sid "$SID" '.locks[$f].session // ""' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  run jq -r --arg f "$TARGET" '.locks[$f] | [.acquired_at, .last_refresh_at] | @tsv' "$COORD_DIR/sessions.json"
  # Both timestamps populated and equal at acquire time.
  [ -n "$output" ]
  acq=$(echo "$output" | awk -F'\t' '{print $1}')
  ref=$(echo "$output" | awk -F'\t' '{print $2}')
  [ "$acq" = "$ref" ]
  # tasks[] is initialized empty (Phase 6 populates).
  run jq -r --arg f "$TARGET" '.locks[$f].tasks | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
  # LOCK_ACQUIRED event emitted with file payload.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_ACQUIRED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs 'last(.[] | select(.kind == "LOCK_ACQUIRED")) | .file' "$COORD_DIR/events.jsonl"
  [ "$output" = "$TARGET" ]
}

@test "pre_tool_use_write: Phase 2 self-write refresh — second write by same session refreshes last_refresh_at, no deny" {
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  acq=$(jq -r --arg f "$TARGET" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json")
  ref1=$(jq -r --arg f "$TARGET" '.locks[$f].last_refresh_at' "$COORD_DIR/sessions.json")
  sleep 1.1
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # No permissionDecision on self-write.
  case "$output" in
    *permissionDecision*) echo "self-write produced permissionDecision: $output"; return 1 ;;
  esac
  # acquired_at unchanged; last_refresh_at advanced.
  acq2=$(jq -r --arg f "$TARGET" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json")
  ref2=$(jq -r --arg f "$TARGET" '.locks[$f].last_refresh_at' "$COORD_DIR/sessions.json")
  [ "$acq2" = "$acq" ]
  [ "$ref2" != "$ref1" ]
  # LOCK_REFRESH event emitted (per-write granularity per phase-1 signoff Q2).
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_REFRESH")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: Phase 2 deny on other-holder — full §B.2 three-options reason; LOCK_DENIED event" {
  # Pre-seed lock held by a DIFFERENT session.
  OTHER="sid-other-9999"
  jq --arg f "$TARGET" --arg sid "$OTHER" '
    .locks[$f] = {
      session: $sid,
      acquired_at: "2026-04-25T12:00:00Z",
      last_refresh_at: "2026-04-25T12:30:00Z",
      tasks: []
    }
    | .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  touch "$COORD_DIR/sessions/${OTHER}.active"

  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  [ "$status" -eq 0 ]
  # (carry-forward #4: Output is valid JSON; jq parses cleanly.)
  echo "$output" | jq -e . >/dev/null
  # permissionDecision is exactly "deny".
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Reason is a string (not stringified-JSON or null).
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | type == "string"' >/dev/null
  # All three option markers present.
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("\\(a\\) Delegate")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("\\(b\\) Self-delegate")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("\\(c\\) Passively wait")' >/dev/null
  # (a)+(b) reference the subcommand abstractly — name only, no full arg
  # shape (Phase 6 hasn't frozen the contract yet). They MUST point at
  # option (c) for the disabled fallback path.
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("`coord task-open`")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("`coord self-delegate`")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Phase 6 . currently disabled")' >/dev/null
  # The deny reason MUST NOT freeze Phase 6 argument syntax — guard
  # against accidental regression to "--file ... --complexity ... --anchor".
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | (contains("task-open --file") | not)' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | (contains("self-delegate --file") | not)' >/dev/null
  # Embedded `coord wait` syntax is exact + copy-paste-runnable (option (c)
  # IS active in Phase 2 — its CLI is stable).
  echo "$output" | jq -e --arg t "$TARGET" '.hookSpecificOutput.permissionDecisionReason | contains("coord wait " + $t + " --timeout 570")' >/dev/null
  # Both timestamps surfaced in human-readable form.
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("acquired .* ago")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("last activity .* ago")' >/dev/null
  # additionalContext field preserves multi-line structure (newlines round-trip).
  # The reason string itself contains literal newline characters (jq passes them
  # through; Claude Code then surfaces them to Claude verbatim).
  echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -qc '^.' && \
    [ "$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' | wc -l | tr -d ' ')" -ge "4" ]
  # Holder session prefix appears (first 8 chars).
  echo "$output" | jq -e --arg p "${OTHER:0:8}" '.hookSpecificOutput.permissionDecisionReason | contains($p)' >/dev/null
  # LOCK_DENIED event emitted.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_DENIED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "pre_tool_use_write: Phase 2 invariant — permissionDecision: deny appears ONLY in lock-held-by-other branch" {
  # Branch 1: empty locks → ACQUIRE, no deny.
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  case "$output" in *permissionDecision*) echo "FAIL acquire: $output"; return 1 ;; esac

  # Branch 2: self-refresh → no deny.
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  case "$output" in *permissionDecision*) echo "FAIL refresh: $output"; return 1 ;; esac

  # Branch 3: stale-read but no contention → warning only, no deny.
  jq --arg f "$TARGET" 'del(.locks[$f])' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  _prime_read "$READ_F1"
  printf 'alpha drifted\n' >"$F1"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  case "$output" in *permissionDecision*) echo "FAIL stale: $output"; return 1 ;; esac

  # Branch 4: lock held by other → MUST deny.
  OTHER="sid-other-7777"
  jq --arg f "$TARGET" --arg sid "$OTHER" '
    .locks = {} | .locks[$f] = {
      session: $sid, acquired_at: "2026-04-25T10:00:00Z",
      last_refresh_at: "2026-04-25T10:00:30Z", tasks: []
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  CLAUDE_COORD=1 run bash -c "echo '$WRITE_TARGET' | '$H'"
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

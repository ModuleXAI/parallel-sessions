#!/usr/bin/env bats
# Phase 4 / T4.06 — pipeline-integration tests for
# hooks/pre_tool_use_write.sh.
#
# Real `claude -p` is exercised in Phase 7 integration harness.
# Unit tests use a mock claude binary on PATH (mirrors Phase 3
# mediator_spawn.bats + Phase 4 validator_spawn.bats patterns).
#
# Coverage (per T4.06 user direction):
#   - cache HIT SAFE → silent (no banner) + proceed
#   - cache HIT MINOR → banner with cached diff_summary
#   - cache MISS → falls through to pre-filter
#   - pre-filter SAFE (whitespace-only) → silent + cache write
#   - pre-filter ESCALATE → falls through to validator agent
#   - agent SAFE → silent + cache write
#   - agent MINOR → banner with diff_summary + cache write
#   - agent CRITICAL → critical_drift pending entry + Mediator inline →
#     advice (banner + proceed) / surgical_fix / lockdown
#   - validator spawn fail → Phase 1 fallback line in banner
#   - mediator spawn fail (in CRITICAL path) → Phase 1 fallback
#   - idempotency: T4.06 advances POINTER_FILE so subsequent
#     pre_tool_use_any.sh consumer skips the verdict
#   - phase4 invariant: pipeline does NOT emit permissionDecision

load "../helpers/common"

H="$SRC_ROOT/hooks/pre_tool_use_write.sh"
HR="$SRC_ROOT/hooks/pre_tool_use_read.sh"

setup() {
  TMP="$(mktemp -d -t coord-ptuw-pipe-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  mkdir -p "$COORD/validator/verdict" "$COORD/mediator/verdict" \
           "$COORD/read_snapshots" "$COORD/mediator"
  : >"$COORD/mediator/pending.jsonl"
  : >"$COORD/mediator/pending.lock"
  export COORD_DIR="$COORD"

  SID="sid-pipe-0001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  SRC="$TMP/alpha.txt"
  printf 'function foo() { return 1; }\n' >"$SRC"
  TARGET="$TMP/target.txt"
  printf 'target v1\n' >"$TARGET"
  WRITE_INP="{\"session_id\":\"$SID\",\"cwd\":\"$TMP\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TARGET\"}}"
  READ_INP="{\"session_id\":\"$SID\",\"cwd\":\"$TMP\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$SRC\"}}"

  # Prime read (writes read_set entry + snapshot).
  CLAUDE_COORD=1 bash -c "echo '$READ_INP' | '$HR'" >/dev/null

  # Mutate file to create drift.
  printf 'function foo() { return 2; }\n' >"$SRC"

  # Mock claude binary that scripts validator + mediator outputs based
  # on env vars MOCK_VALIDATOR_VERDICT (SAFE/MINOR/CRITICAL) and
  # MOCK_MEDIATOR_ACTION (advice/surgical_fix/lockdown).
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/claude" <<'CLAUDE_FAKE'
#!/usr/bin/env bash
# Detects validator vs mediator context via CLAUDE_CODE_VALIDATOR /
# CLAUDE_CODE_MEDIATOR env. Writes appropriate verdict file.
set -e
if [ -n "${CLAUDE_CODE_VALIDATOR:-}" ]; then
  vdir="${COORD_DIR}/validator/verdict"
  mkdir -p "$vdir"
  ts="$(date -u +%Y-%m-%dT%H-%M-%S-200000Z)"
  v="${MOCK_VALIDATOR_VERDICT:-SAFE}"
  ds="No semantic change."
  [ "$v" = "MINOR" ] && ds="Variable rename inside function."
  [ "$v" = "CRITICAL" ] && ds="Function signature changed; callers will break."
  jq -n \
    --arg ts "$ts" --arg v "$v" --arg ds "$ds" \
    --arg sid "${SESSION_ID:-mock-sid}" --arg file "${MOCK_FILE:-/tmp/x}" \
    '{verdict_id:"mock-validator-uuid", ts:$ts, for_pending_entry:null,
      validator_session_id:"placeholder",
      file:$file, session:$sid, verdict:$v,
      reasoning:"Mock validator reasoning.", diff_summary:$ds,
      spawn_metadata:{duration_ms:0,model:"claude-haiku-4-5-20251001",spawn_mode:"no_bare"}}' \
    >"$vdir/${ts}.json"
  printf '%s\n' "{\"type\":\"result\",\"is_error\":false,\"session_id\":\"validator-spawn-${v}\",\"total_cost_usd\":0.05,\"duration_ms\":50,\"result\":\"verdict written\"}"
  exit 0
fi
if [ -n "${CLAUDE_CODE_MEDIATOR:-}" ]; then
  vdir="${COORD_DIR}/mediator/verdict"
  mkdir -p "$vdir"
  ts="$(date -u +%Y-%m-%dT%H-%M-%S-300000Z)"
  action="${MOCK_MEDIATOR_ACTION:-advice}"
  msg="Mediator inline advice for mock test."
  [ "$action" = "surgical_fix" ] && msg="Mediator applied surgical_fix; retry your write."
  [ "$action" = "lockdown" ] && msg="Mediator triggered lockdown; system paused."
  actions="[]"
  [ "$action" = "surgical_fix" ] && actions="[{\"op\":\"clear_read_set\",\"session\":\"${SESSION_ID:-mock-sid}\"}]"
  jq -nc \
    --arg ts "$ts" --arg action "$action" --arg msg "$msg" \
    --argjson actions "$actions" \
    '{verdict_id:"mock-mediator-uuid", ts:$ts,
      for_pending_entry:"mock-pending",
      mediator_session_id:"mediator-spawn", depth:1,
      action_type:$action,
      severity:(if $action == "surgical_fix" then "brief" else null end),
      confidence:"auto_apply",
      reasoning:"Mock mediator reasoning.",
      actions:$actions,
      message_to_caller:$msg,
      message_to_others:null}' \
    >"$vdir/${ts}.json"
  printf '%s\n' "{\"type\":\"result\",\"is_error\":false,\"session_id\":\"mediator-spawn\",\"total_cost_usd\":0.10,\"duration_ms\":100,\"result\":\"mediator verdict written\"}"
  exit 0
fi
# Should not reach here in tests — validator or mediator env always set.
printf '%s\n' '{"type":"result","is_error":true,"errors":["unknown spawn context"],"session_id":"err","total_cost_usd":0,"duration_ms":10,"result":""}'
CLAUDE_FAKE
  chmod +x "$TMP/bin/claude"
}

teardown() {
  unset CLAUDE_COORD COORD_DIR PATH MOCK_VALIDATOR_VERDICT MOCK_MEDIATOR_ACTION
  export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
  rm -rf "$TMP"
}

# _run_hook_with_mocks <validator_verdict> [mediator_action]
_run_hook_with_mocks() {
  local v_verdict="${1:-SAFE}" m_action="${2:-advice}"
  CLAUDE_COORD=1 run bash -c "
    export PATH='$TMP/bin:$PATH'
    export MOCK_VALIDATOR_VERDICT='$v_verdict'
    export MOCK_MEDIATOR_ACTION='$m_action'
    export MOCK_FILE='$SRC'
    echo '$WRITE_INP' | '$H'
  "
}

@test "T4.06 pipeline: validator SAFE verdict → silent (no banner) + cache write" {
  _run_hook_with_mocks SAFE
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  ! _grep_output_for "Coord drift report"
  # Cache should have a SAFE entry.
  run jq -r '.entries | length' "$COORD_DIR/validator/cache.json"
  [ "$output" = "1" ]
  run jq -r '.entries[0].verdict' "$COORD_DIR/validator/cache.json"
  [ "$output" = "SAFE" ]
}

@test "T4.06 pipeline: validator MINOR verdict → banner with diff_summary + cache write" {
  _run_hook_with_mocks MINOR
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | test("Coord drift report")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("MINOR")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Variable rename")' >/dev/null
  run jq -r '.entries[0].verdict' "$COORD_DIR/validator/cache.json"
  [ "$output" = "MINOR" ]
  run jq -r '.entries[0].diff_summary' "$COORD_DIR/validator/cache.json"
  [ "$output" = "Variable rename inside function." ]
}

@test "T4.06 pipeline: validator CRITICAL → Mediator advice inline → banner + proceed" {
  _run_hook_with_mocks CRITICAL advice
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Critical drift")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Mediator")' >/dev/null
  # Pending entry written.
  run jq -rs '[.[] | select(.kind == "critical_drift")] | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge "1" ]
  # Mediator verdict file written.
  run bash -c "ls -1 '$COORD_DIR/mediator/verdict/'*.json | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  # Pointer file advanced (idempotency).
  [ -f "$COORD_DIR/sessions/${SID}.last_consumed_verdict" ]
  # Events emitted.
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_VERDICT_CRITICAL_ESCALATED_TO_MEDIATOR")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs '[.[] | select(.kind == "MEDIATOR_INLINE_VERDICT_APPLIED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # CRITICAL is NOT cached.
  if [ -f "$COORD_DIR/validator/cache.json" ]; then
    run jq -r '.entries | length' "$COORD_DIR/validator/cache.json"
    [ "$output" = "0" ]
  fi
}

@test "T4.06 pipeline: validator CRITICAL → Mediator surgical_fix inline → actions applied" {
  _run_hook_with_mocks CRITICAL surgical_fix
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  # Mediator verdict shows surgical_fix.
  vfile=$(ls -1t "$COORD_DIR/mediator/verdict/"*.json | head -1)
  run jq -r '.action_type' "$vfile"
  [ "$output" = "surgical_fix" ]
  # Verdict actions applied: read_set cleared for this session.
  run jq -r ".read_sets[\"$SID\"].reads | length // 0" "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

@test "T4.06 pipeline: idempotency — pointer file matches latest mediator verdict timestamp" {
  _run_hook_with_mocks CRITICAL advice
  [ "$status" -eq 0 ]
  vfile=$(ls -1t "$COORD_DIR/mediator/verdict/"*.json | head -1)
  vname=$(basename "$vfile" .json)
  run cat "$COORD_DIR/sessions/${SID}.last_consumed_verdict"
  # Strip trailing newline.
  pointer=$(printf '%s' "$output" | tr -d '\n')
  [ "$pointer" = "$vname" ]
}

@test "T4.06 pipeline: cache HIT SAFE → silent (no spawn) on subsequent identical drift" {
  # Pre-warm cache with a SAFE verdict for the (file, read_hash, current_hash) triple.
  STORED_HASH=$(jq -r ".read_sets[\"$SID\"].reads[0].hash" "$COORD_DIR/sessions.json")
  CURRENT_HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  bash -c "
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SID'
    . '$SRC_ROOT/core/lib/log_event.sh'
    . '$SRC_ROOT/core/lib/validator_cache.sh'
    coord_validator_cache_write '$SRC' '$STORED_HASH' '$CURRENT_HASH' SAFE prefilter
  "
  # Run the hook — expects cache hit, no spawn, no banner.
  _run_hook_with_mocks SAFE
  [ "$status" -eq 0 ]
  ! _grep_output_for "Coord drift report"
  # Validator was NOT spawned (no VALIDATOR_SPAWN_STARTED for this run).
  # Easiest signal: validator/verdict/ stays empty.
  run bash -c "ls -1 '$COORD_DIR/validator/verdict/'*.json 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_CACHE_HIT")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "T4.06 pipeline: cache HIT MINOR → banner with cached diff_summary, no spawn" {
  STORED_HASH=$(jq -r ".read_sets[\"$SID\"].reads[0].hash" "$COORD_DIR/sessions.json")
  CURRENT_HASH=$(shasum -a 256 "$SRC" | awk '{print $1}')
  bash -c "
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SID'
    . '$SRC_ROOT/core/lib/log_event.sh'
    . '$SRC_ROOT/core/lib/validator_cache.sh'
    coord_validator_cache_write '$SRC' '$STORED_HASH' '$CURRENT_HASH' MINOR validator_agent 'Cached MINOR summary'
  "
  _run_hook_with_mocks SAFE
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Cached MINOR summary")' >/dev/null
  # Validator was NOT spawned.
  run bash -c "ls -1 '$COORD_DIR/validator/verdict/'*.json 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "T4.06 pipeline: validator spawn fail → Phase 1 fallback line + proceed" {
  # Force claude binary missing → validator spawn fail.
  local jq_bin flock_bin perl_bin shasum_bin
  jq_bin=$(command -v jq | xargs dirname)
  flock_bin=$(command -v flock | xargs dirname)
  perl_bin=$(command -v perl | xargs dirname)
  shasum_bin=$(command -v shasum | xargs dirname)
  local minimal_path="$jq_bin:$flock_bin:$perl_bin:$shasum_bin:/usr/bin:/bin"
  CLAUDE_COORD=1 run bash -c "
    export PATH='$minimal_path'
    echo '$WRITE_INP' | '$H'
  "
  [ "$status" -eq 0 ]
  ! _grep_output_for "permissionDecision"
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Pipeline unavailable")' >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_FAILED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "T4.06 pipeline: pre-filter SAFE → silent + cache write (whitespace-only drift)" {
  # Re-prime read with content that will be SAFE after whitespace mutation.
  printf 'a b c\n' >"$SRC"
  CLAUDE_COORD=1 bash -c "echo '$READ_INP' | '$HR'" >/dev/null
  # Whitespace-only mutation.
  printf 'a   b   c\n' >"$SRC"
  _run_hook_with_mocks SAFE
  [ "$status" -eq 0 ]
  ! _grep_output_for "Coord drift report"
  # Cache has a SAFE/prefilter entry.
  run jq -r '.entries[0].verdict_source' "$COORD_DIR/validator/cache.json"
  [ "$output" = "prefilter" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_PREFILTER_SAFE")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "T4.06 pipeline: emits no permissionDecision in any pipeline outcome (Phase 4 invariant assertion)" {
  # Run all 3 verdict types via mocks; assert no permissionDecision emerges.
  for v in SAFE MINOR CRITICAL; do
    _run_hook_with_mocks "$v" advice
    [ "$status" -eq 0 ]
    ! _grep_output_for "permissionDecision"
  done
}

@test "T4.06 pipeline: VALIDATOR_PIPELINE_STARTED + COMPLETED events emitted" {
  _run_hook_with_mocks MINOR
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_STARTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs '[.[] | select(.kind == "VALIDATOR_PIPELINE_COMPLETED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

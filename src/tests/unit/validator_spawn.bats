#!/usr/bin/env bats
# Tests for lib/validator_spawn.sh per PR-PHASE4-01 + T4.03 POC
# findings.
#
# Real `claude -p` is exercised in the Phase 7 integration harness;
# unit tests use a fake claude binary on PATH that mimics the
# real CLI's JSON output shape and writes a synthetic verdict file.
#
# Coverage (per T4.04 user direction):
#   - happy path: SAFE / MINOR / CRITICAL verdicts captured with path
#   - empty verdict file fall-through (validator wrote zero-byte first,
#     real verdict second → helper picks the real one)
#   - no valid verdict file → VALIDATOR_SPAWN_FAILED
#   - mock returns is_error=true → VALIDATOR_SPAWN_FAILED
#   - mock returns malformed JSON → VALIDATOR_SPAWN_FAILED
#   - recursion guard: CLAUDE_CODE_VALIDATOR=1 in caller env → refused
#   - validator_session_id post-process injection (placeholder → real)
#   - claude binary missing → refused
#   - read snapshot missing → refused
#   - VALIDATOR_SPAWN_STARTED + VALIDATOR_SPAWN_COMPLETED events
#   - spawn_metadata.duration_ms + total_cost_usd populated

load "../helpers/common"

LIB="$SRC_ROOT/lib/validator_spawn.sh"
LE="$SRC_ROOT/lib/log_event.sh"
RS="$SRC_ROOT/lib/read_snapshots.sh"

setup() {
  TMP="$(mktemp -d -t coord-vspawn-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  mkdir -p "$COORD/validator/verdict" "$COORD/read_snapshots"
  export COORD_DIR="$COORD"

  SID="vspawn-test-sid"
  export SESSION_ID="$SID"

  # Source the libraries directly (matching mediator_spawn.bats pattern).
  # shellcheck disable=SC1090
  . "$LE"
  # shellcheck disable=SC1090
  . "$RS"
  # shellcheck disable=SC1090
  . "$LIB"

  # Build a fake `claude` on PATH mimicking real CLI's JSON shape.
  # Behavior keyed on env: MOCK_VERDICT (SAFE/MINOR/CRITICAL),
  # MOCK_FAIL (binary_error / malformed_json / empty), MOCK_EXTRA
  # (write_extra_empty_first → emit zero-byte file before real verdict).
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/claude" <<'CLAUDE_FAKE'
#!/usr/bin/env bash
set -e
if [ "${MOCK_FAIL:-}" = "binary_error" ]; then
  printf '%s\n' '{"type":"result","subtype":"error","is_error":true,"errors":["mock error"],"session_id":"fake-spawn-sid","total_cost_usd":0.001,"duration_ms":50,"result":""}'
  exit 0
fi
if [ "${MOCK_FAIL:-}" = "malformed_json" ]; then
  printf '%s\n' 'not actually json {{{'
  exit 0
fi
if [ "${MOCK_FAIL:-}" = "empty" ]; then
  exit 0
fi
verdict_dir="${COORD_DIR}/validator/verdict"
mkdir -p "$verdict_dir"
# Optionally write a zero-byte file FIRST to test fall-through.
if [ "${MOCK_EXTRA:-}" = "write_extra_empty_first" ]; then
  ts_pre=$(date -u +%Y-%m-%dT%H-%M-%S-100000Z)
  : >"$verdict_dir/${ts_pre}.json"
  sleep 0.05
fi
ts="$(date -u +%Y-%m-%dT%H-%M-%S-200000Z)"
verdict_file="$verdict_dir/${ts}.json"
verdict="${MOCK_VERDICT:-SAFE}"
diff_summary="mock summary"
[ "$verdict" = "SAFE" ] && diff_summary="No semantic change. Whitespace only."
[ "$verdict" = "MINOR" ] && diff_summary="Local variable renamed. No caller impact."
[ "$verdict" = "CRITICAL" ] && diff_summary="Function signature changed. Callers will break."
jq -n \
  --arg ts "$ts" --arg v "$verdict" --arg ds "$diff_summary" \
  --arg sid "${MOCK_CALLER_SID:-vspawn-test-sid}" \
  --arg file "${MOCK_FILE:-/tmp/foo.ts}" \
  '{verdict_id: "fake-uuid-0001",
    ts: $ts,
    for_pending_entry: null,
    validator_session_id: "fake-placeholder",
    file: $file,
    session: $sid,
    verdict: $v,
    reasoning: "Mock reasoning for unit test classification of \($v) drift.",
    diff_summary: $ds,
    spawn_metadata: { duration_ms: 0, model: "claude-haiku-4-5-20251001", spawn_mode: "no_bare" }}' \
  >"$verdict_file"
printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"session_id\":\"fake-spawn-sid-${MOCK_VERDICT:-SAFE}\",\"total_cost_usd\":0.05,\"duration_ms\":100,\"result\":\"verdict written\"}"
CLAUDE_FAKE
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"

  # Build a real read snapshot so coord_validator_spawn passes the
  # snapshot-presence check.
  SRC_FILE="$TMP/foo.ts"
  printf 'function foo(){return 1;}\n' >"$SRC_FILE"
  RHASH=$(shasum -a 256 "$SRC_FILE" | awk '{print $1}')
  coord_read_snapshot_write "$SID" "$RHASH" "$SRC_FILE"
  # Mutate to create current state.
  printf 'function foo(){return 2;}\n' >"$SRC_FILE"
  CHASH=$(shasum -a 256 "$SRC_FILE" | awk '{print $1}')
}

teardown() {
  unset COORD_DIR SESSION_ID PATH MOCK_VERDICT MOCK_FAIL MOCK_EXTRA \
        MOCK_CALLER_SID MOCK_FILE CLAUDE_CODE_VALIDATOR
  export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
  rm -rf "$TMP"
}

_spawn() {
  bash -c "
    export PATH='$TMP/bin:$PATH'
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SID'
    export MOCK_VERDICT='${MOCK_VERDICT:-SAFE}'
    export MOCK_FAIL='${MOCK_FAIL:-}'
    export MOCK_EXTRA='${MOCK_EXTRA:-}'
    export MOCK_CALLER_SID='$SID'
    export MOCK_FILE='$SRC_FILE'
    ${CLAUDE_CODE_VALIDATOR:+export CLAUDE_CODE_VALIDATOR='$CLAUDE_CODE_VALIDATOR'}
    . '$LE'
    . '$RS'
    . '$LIB'
    coord_validator_spawn '$SID' '$SRC_FILE' '$RHASH' '$CHASH'
  "
}

@test "validator_spawn: SAFE verdict returns verdict path on stdout (rc=0)" {
  MOCK_VERDICT="SAFE" run _spawn
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output" ]
  run jq -r '.verdict' "$output"
  [ "$output" = "SAFE" ]
}

@test "validator_spawn: MINOR verdict captured with diff_summary" {
  MOCK_VERDICT="MINOR" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  run jq -r '.verdict' "$vfile"
  [ "$output" = "MINOR" ]
  run jq -r '.diff_summary' "$vfile"
  echo "$output" | grep -qi "renamed"
}

@test "validator_spawn: CRITICAL verdict captured" {
  MOCK_VERDICT="CRITICAL" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  run jq -r '.verdict' "$vfile"
  [ "$output" = "CRITICAL" ]
}

@test "validator_spawn: validator_session_id post-process injects real spawn UUID (refinement c)" {
  MOCK_VERDICT="SAFE" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  # Mock writes "fake-placeholder"; helper post-processes to the real
  # session_id from claude -p stdout (= "fake-spawn-sid-SAFE").
  run jq -r '.validator_session_id' "$vfile"
  [ "$output" = "fake-spawn-sid-SAFE" ]
  # spawn_metadata.spawn_session_id mirrors.
  run jq -r '.spawn_metadata.spawn_session_id' "$vfile"
  [ "$output" = "fake-spawn-sid-SAFE" ]
}

@test "validator_spawn: spawn_metadata augmented with duration_ms + total_cost_usd" {
  MOCK_VERDICT="SAFE" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  run jq -r '.spawn_metadata.duration_ms' "$vfile"
  [ "$output" -ge 0 ]
  run jq -r '.spawn_metadata.total_cost_usd' "$vfile"
  [ "$output" = "0.05" ]
  run jq -r '.spawn_metadata.model' "$vfile"
  echo "$output" | grep -q "claude-haiku"
  run jq -r '.spawn_metadata.spawn_mode' "$vfile"
  [ "$output" = "no_bare" ]
}

@test "validator_spawn: empty verdict file present + real verdict → fall through to real (refinement b)" {
  MOCK_VERDICT="SAFE" MOCK_EXTRA="write_extra_empty_first" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  # Helper picked the real verdict (non-empty + verdict_id present).
  [ -s "$vfile" ]
  run jq -r '.verdict_id' "$vfile"
  [ "$output" = "fake-uuid-0001" ]
  # Both files exist; helper picked correctly.
  run bash -c "ls -1 '$COORD_DIR/validator/verdict/'*.json | wc -l | tr -d ' '"
  [ "$output" = "2" ]
}

@test "validator_spawn: no valid verdict file → VALIDATOR_SPAWN_FAILED no_verdict_written" {
  # Make claude succeed but write NO verdict (hacky: override the mock
  # to skip the verdict write).
  cat >"$TMP/bin/claude" <<'CLAUDE_FAKE_NO_VERDICT'
#!/usr/bin/env bash
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-spawn-sid","total_cost_usd":0.05,"duration_ms":100,"result":"no verdict written"}'
CLAUDE_FAKE_NO_VERDICT
  chmod +x "$TMP/bin/claude"
  MOCK_VERDICT="SAFE" run _spawn
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED" and .payload.reason == "no_verdict_written")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_spawn: is_error=true → VALIDATOR_SPAWN_FAILED is_error_true" {
  MOCK_FAIL="binary_error" run _spawn
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED" and .payload.reason == "is_error_true")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_spawn: malformed JSON output → VALIDATOR_SPAWN_FAILED no_verdict_written or is_error_true" {
  # Malformed JSON: jq parse fails on is_error → defaults to false →
  # falls through to verdict-file lookup → no valid file → fail.
  MOCK_FAIL="malformed_json" run _spawn
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_spawn: empty stdout → VALIDATOR_SPAWN_FAILED empty_output" {
  MOCK_FAIL="empty" run _spawn
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED" and .payload.reason == "empty_output")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_spawn: recursion guard refuses spawn when CLAUDE_CODE_VALIDATOR=1" {
  CLAUDE_CODE_VALIDATOR=1 run _spawn
  [ "$status" -eq 1 ]
  # bats `run` merges stderr into $output; helper warns via stderr.
  # Assert the warn message rather than absence.
  echo "$output" | grep -q "recursion guard"
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_RECURSION_REFUSED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # Verify NO spawn happened (no claude session_id event since claude was never invoked).
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_STARTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "validator_spawn: claude binary missing → VALIDATOR_SPAWN_FAILED claude_binary_missing" {
  # Build a minimal PATH that includes jq/flock/perl/shasum but NOT
  # claude (mirrors mediator_spawn.bats:158 pattern).
  mkdir -p "$TMP/empty-bin"
  local jq_bin flock_bin perl_bin shasum_bin
  jq_bin=$(command -v jq | xargs dirname 2>/dev/null)
  flock_bin=$(command -v flock | xargs dirname 2>/dev/null)
  perl_bin=$(command -v perl | xargs dirname 2>/dev/null)
  shasum_bin=$(command -v shasum | xargs dirname 2>/dev/null)
  local minimal_path="$TMP/empty-bin"
  for d in "$jq_bin" "$flock_bin" "$perl_bin" "$shasum_bin" /usr/bin /bin; do
    case ":$minimal_path:" in *":$d:"*) ;; *) minimal_path="$minimal_path:$d" ;; esac
  done
  run bash -c "
    export PATH='$minimal_path'
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SID'
    . '$LE'
    . '$RS'
    . '$LIB'
    coord_validator_spawn '$SID' '$SRC_FILE' '$RHASH' '$CHASH'
  "
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED" and .payload.reason == "claude_binary_missing")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_spawn: read snapshot missing → VALIDATOR_SPAWN_FAILED read_snapshot_missing" {
  # Use a hash that has no snapshot.
  local fake_hash="deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  run bash -c "
    export PATH='$TMP/bin:$PATH'
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SID'
    . '$LE'
    . '$RS'
    . '$LIB'
    coord_validator_spawn '$SID' '$SRC_FILE' '$fake_hash' '$CHASH'
  "
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_FAILED" and .payload.reason == "read_snapshot_missing")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "validator_spawn: emits VALIDATOR_SPAWN_STARTED + VALIDATOR_SPAWN_COMPLETED on success" {
  MOCK_VERDICT="MINOR" _spawn >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_STARTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_COMPLETED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # COMPLETED event payload includes verdict.
  run jq -rs '[.[] | select(.kind == "VALIDATOR_SPAWN_COMPLETED")][-1].payload.verdict' "$COORD_DIR/events.jsonl"
  [ "$output" = "MINOR" ]
}

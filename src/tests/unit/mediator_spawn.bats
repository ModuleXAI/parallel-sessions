#!/usr/bin/env bats
# Tests for lib/mediator_spawn.sh — Mediator agent spawn helper
# (Phase 3 / T3.07 / PR-PHASE3-01).
#
# Real `claude -p` invocations are deferred to Phase 7 integration
# harness (cost: ~$0.10/run). T3.07 unit tests use a fake `claude`
# binary on PATH that emits scripted JSON output + writes a synthetic
# verdict file.
#
# Coverage:
#   - Spawn assembles 3-section prompt
#   - Spawn captures verdict file path on success
#   - Recursion guard refuses depth>=2 caller
#   - Critical bypass refuses spawn
#   - claude binary missing refuses with clear log
#   - Spawn metadata (duration, model, spawn_mode) added to verdict
#   - GC fires after successful verdict write

load "../helpers/common"

MS="$SRC_ROOT/lib/mediator_spawn.sh"
MP="$SRC_ROOT/lib/mediator_pending.sh"
CC="$SRC_ROOT/lib/critical_check.sh"
LK="$SRC_ROOT/lib/lockdown.sh"
LE="$SRC_ROOT/lib/log_event.sh"
AW="$SRC_ROOT/lib/atomic_write.sh"

setup() {
  TMP="$(mktemp -d -t coord-spawn-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  : >"$COORD/mediator/pending.jsonl"
  : >"$COORD/mediator/pending.lock"
  export COORD_DIR="$COORD"
  SESSION_ID="caller-001"
  export SESSION_ID

  # Pre-seed a pending entry so spawn has something to act on.
  bash -c '. "'"$LE"'"; . "'"$MP"'"; coord_mediator_emit_pending stale_active source=test target=ghost-sid' \
    >/dev/null
  PENDING_ID=$(jq -rs '[.[]][-1].ts' "$COORD/mediator/pending.jsonl")

  # Build a fake `claude` binary on PATH that mimics the real CLI's
  # output shape and writes a synthetic verdict file.
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/claude" <<CLAUDE_FAKE
#!/bin/bash
# Fake claude -p for T3.07 unit tests. Reads MOCK_VERDICT_ACTION /
# MOCK_VERDICT_CONFIDENCE / MOCK_FAIL env to script behavior.
set -e
if [ "\${MOCK_FAIL:-}" = "binary_error" ]; then
  echo '{"type":"result","subtype":"error_test","is_error":true,"errors":["mock error"],"session_id":"fake-sid","total_cost_usd":0,"duration_ms":100}'
  exit 0
fi
# Generate verdict file with a unique timestamp.
ts="\$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
verdict_dir="\$COORD_DIR/mediator/verdict"
mkdir -p "\$verdict_dir"
verdict_file="\$verdict_dir/\${ts}.json"
jq -nc \\
  --arg ts "\$ts" \\
  --arg pending "\${MOCK_PENDING_ID:-pending-001}" \\
  --arg action "\${MOCK_VERDICT_ACTION:-advice}" \\
  --arg confidence "\${MOCK_VERDICT_CONFIDENCE:-auto_apply}" \\
  --arg depth "\${CLAUDE_CODE_MEDIATOR:-1}" \\
  '{verdict_id: "fake-uuid",
    ts: \$ts,
    for_pending_entry: \$pending,
    mediator_session_id: "fake-spawn-session",
    depth: (\$depth|tonumber),
    action_type: \$action,
    severity: (if \$action == "surgical_fix" then "brief" else null end),
    confidence: \$confidence,
    reasoning: "fake reasoning for test",
    actions: [],
    message_to_caller: "test verdict applied",
    message_to_others: null}' >"\$verdict_file"
# Emit success JSON to stdout (claude -p shape).
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"fake-spawn-session","total_cost_usd":0.001,"duration_ms":50,"result":"ok"}'
CLAUDE_FAKE
  chmod +x "$TMP/bin/claude"
  export PATH="$TMP/bin:$PATH"
}

teardown() {
  unset COORD_DIR SESSION_ID PATH MOCK_VERDICT_ACTION MOCK_VERDICT_CONFIDENCE MOCK_FAIL CLAUDE_CODE_MEDIATOR PENDING_ID MOCK_PENDING_ID
  export PATH="/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
  rm -rf "$TMP"
}

_spawn() {
  bash -c "
    export PATH='$TMP/bin:$PATH'
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SESSION_ID'
    export MOCK_VERDICT_ACTION='${MOCK_VERDICT_ACTION:-advice}'
    export MOCK_VERDICT_CONFIDENCE='${MOCK_VERDICT_CONFIDENCE:-auto_apply}'
    export MOCK_FAIL='${MOCK_FAIL:-}'
    export MOCK_PENDING_ID='$PENDING_ID'
    ${CLAUDE_CODE_MEDIATOR:+export CLAUDE_CODE_MEDIATOR='$CLAUDE_CODE_MEDIATOR'}
    . '$LE'
    . '$MP'
    . '$LK'
    . '$CC'
    . '$AW'
    . '$MS'
    coord_mediator_spawn '$PENDING_ID' ${1:-1}
  "
}

@test "spawn: writes verdict file + returns its path on success" {
  MOCK_VERDICT_ACTION="advice" MOCK_VERDICT_CONFIDENCE="auto_apply" run _spawn
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$output" ]
  run jq -r '.action_type' "$output"
  [ "$output" = "advice" ]
}

@test "spawn: augments verdict with spawn_metadata (duration_ms, model, spawn_mode)" {
  MOCK_VERDICT_ACTION="surgical_fix" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  run jq -r '.spawn_metadata.spawn_mode' "$vfile"
  [ "$output" = "no_bare" ]
  run jq -r '.spawn_metadata.model' "$vfile"
  echo "$output" | grep -q "claude-haiku"
  run jq -r '.spawn_metadata.duration_ms' "$vfile"
  [ "$output" -ge 0 ]
}

@test "spawn: emits MEDIATOR_VERDICT event with verdict_path + action_type" {
  MOCK_VERDICT_ACTION="advice" _spawn >/dev/null
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "MEDIATOR_VERDICT")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
  run jq -rs '[.[] | select(.kind == "MEDIATOR_VERDICT")][-1].payload.action_type' "$COORD_DIR/events.jsonl"
  [ "$output" = "advice" ]
}

@test "spawn: recursion guard — caller depth=2 refuses spawn" {
  CLAUDE_CODE_MEDIATOR=2 run _spawn 1
  [ "$status" -eq 1 ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_REFUSED" and .payload.reason == "recursion_guard")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "spawn: caller depth=1 spawns peer review at depth=2" {
  CLAUDE_CODE_MEDIATOR=1 MOCK_VERDICT_ACTION="advice" run _spawn
  [ "$status" -eq 0 ]
  vfile="$output"
  # Verdict's depth field should be 2 (peer review).
  run jq -r '.depth' "$vfile"
  [ "$output" = "2" ]
}

@test "spawn: claude binary missing → refuses with clear log" {
  # Need to make `command -v claude` return non-zero. The real claude
  # binary may still be on the system PATH; we shadow with a directory
  # that has NO claude entry and force PATH to that only-directory plus
  # the standard tool dirs (so jq/flock/perl still resolve).
  mkdir -p "$TMP/empty-bin"
  # Discover the directories that hold our required tools so we can
  # build a minimal PATH without claude. This is more robust than
  # hard-coding /usr/bin etc.
  local jq_bin flock_bin perl_bin
  jq_bin=$(command -v jq | xargs dirname 2>/dev/null)
  flock_bin=$(command -v flock | xargs dirname 2>/dev/null)
  perl_bin=$(command -v perl | xargs dirname 2>/dev/null)
  local minimal_path="$TMP/empty-bin"
  for d in "$jq_bin" "$flock_bin" "$perl_bin" /usr/bin /bin; do
    case ":$minimal_path:" in *":$d:"*) ;; *) minimal_path="$minimal_path:$d" ;; esac
  done
  run bash -c "
    export PATH='$minimal_path'
    export COORD_DIR='$COORD_DIR'
    export SESSION_ID='$SESSION_ID'
    . '$LE'
    . '$MP'
    . '$LK'
    . '$CC'
    . '$AW'
    . '$MS'
    coord_mediator_spawn '$PENDING_ID' 1
  "
  [ "$status" -eq 1 ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_REFUSED" and .payload.reason == "claude_binary_missing")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "spawn: is_error=true response → MEDIATOR_SPAWN_FAILED event + non-zero rc" {
  MOCK_FAIL="binary_error" run _spawn
  [ "$status" -eq 1 ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_FAILED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "spawn: triggers GC after successful verdict (PENDING_GC_RUN event present)" {
  # Pre-fill pending.jsonl with old + recent entries to verify GC ran.
  bash -c '. "'"$LE"'"; . "'"$MP"'"; coord_mediator_emit_pending flock_timeout source=test file=foo' >/dev/null
  printf '2\n' >"$COORD_DIR/mediator/pending.consumed"
  MOCK_VERDICT_ACTION="advice" _spawn >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "PENDING_GC_RUN")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

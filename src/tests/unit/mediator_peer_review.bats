#!/usr/bin/env bats
# Tests for the peer-review escalation hierarchy in the
# pre_tool_use_any.sh verdict consumer (Phase 3 / T3.07 /
# PR-PHASE3-01 max-depth-2 escalation).
#
# Coverage:
#   - confidence=needs_review at depth=1 spawns peer at depth=2
#   - peer agrees on action_type → primary applied with more
#     conservative severity
#   - peer disagrees → user-escalation banner; no apply
#   - peer-spawn failure → user-escalation banner; no apply

load "../helpers/common"

HANY="$SRC_ROOT/hooks/pre_tool_use_any.sh"
LE="$SRC_ROOT/lib/log_event.sh"

setup() {
  TMP="$(mktemp -d -t coord-peer-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  : >"$COORD/mediator/pending.jsonl"
  : >"$COORD/mediator/pending.lock"
  export COORD_DIR="$COORD"

  CALLER="caller-001"
  TARGET="target-victim-001"
  touch "$COORD_DIR/sessions/${CALLER}.active"
  jq --arg sid "$CALLER" --arg tgt "$TARGET" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",last_activity_at:"z"}
    | .sessions[$tgt] = {state:"ACTIVE",pid:99999,pid_lstart:"old",last_activity_at:"old"}
    | .locks["/foo"] = {session:$tgt,acquired_at:"old",last_refresh_at:"old",tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  # Seed a primary verdict file with confidence=needs_review.
  PRIMARY_TS="2026-04-26T03-00-00Z"
  PEER_TS="2026-04-26T03-00-30Z"

  # Fake claude binary that the spawn helper will invoke for peer review.
  # MOCK_PEER_ACTION env decides whether peer agrees or disagrees.
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/claude" <<CLAUDE_FAKE
#!/bin/bash
ts="$PEER_TS"
verdict_dir="\$COORD_DIR/mediator/verdict"
mkdir -p "\$verdict_dir"
verdict_file="\$verdict_dir/\${ts}.json"
jq -nc \\
  --arg ts "\$ts" \\
  --arg action "\${MOCK_PEER_ACTION:-surgical_fix}" \\
  --arg severity "\${MOCK_PEER_SEVERITY:-brief}" \\
  '{verdict_id: "peer-uuid",
    ts: \$ts,
    for_pending_entry: "primary-pending-id",
    mediator_session_id: "peer-session",
    depth: 2,
    action_type: \$action,
    severity: (if \$action == "surgical_fix" then \$severity else null end),
    confidence: "auto_apply",
    reasoning: "peer review reasoning",
    actions: [],
    message_to_caller: "peer review concluded",
    message_to_others: null}' >"\$verdict_file"
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"peer-fake","total_cost_usd":0.001,"duration_ms":50,"result":"ok"}'
CLAUDE_FAKE
  chmod +x "$TMP/bin/claude"
}

teardown() {
  unset COORD_DIR MOCK_PEER_ACTION MOCK_PEER_SEVERITY
  # Backgrounded watchdog probes / coord_log_event jobs may still be
  # writing into $TMP when teardown fires. Drain briefly + retry rm.
  sleep 0.2
  rm -rf "$TMP" 2>/dev/null || { sleep 0.3; rm -rf "$TMP" 2>/dev/null || true; }
}

# Pre-seed primary verdict with given action_type/severity.
_seed_primary_verdict() {
  local action="$1" severity="$2"
  local primary_file="$COORD_DIR/mediator/verdict/${PRIMARY_TS}.json"
  jq -nc --arg ts "$PRIMARY_TS" --arg action "$action" --arg severity "$severity" \
    '{verdict_id:"primary-uuid",
      ts:$ts,
      for_pending_entry:"primary-pending-id",
      mediator_session_id:"primary-session",
      depth:1,
      action_type:$action,
      severity:(if $action == "surgical_fix" then $severity else null end),
      confidence:"needs_review",
      reasoning:"primary needed peer review",
      actions:[{op:"release_lock",target:"/foo",session:"'"$TARGET"'"}],
      message_to_caller:"primary verdict applied after peer review",
      message_to_others:null}' \
    >"$primary_file"
}

_run_consumer() {
  local input='{"session_id":"'"$CALLER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  PATH="$TMP/bin:$PATH" CLAUDE_COORD=1 bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$HANY"
}

@test "peer review: needs_review primary + agreeing peer → primary actions applied + MEDIATOR_PEER_AGREED event" {
  _seed_primary_verdict "surgical_fix" "brief"
  MOCK_PEER_ACTION="surgical_fix" MOCK_PEER_SEVERITY="brief" run _run_consumer
  [ "$status" -eq 0 ]
  # Lock /foo released (primary's action applied after peer agreement).
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "MEDIATOR_PEER_AGREED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "peer review: needs_review primary + disagreeing peer → no apply + MEDIATOR_PEER_DISAGREED + escalation banner" {
  _seed_primary_verdict "surgical_fix" "brief"
  MOCK_PEER_ACTION="lockdown" run _run_consumer
  [ "$status" -eq 0 ]
  # Banner contains escalation language. Captured in $output from `run`.
  case "$output" in *"peer-review disagreed"*) : ;; *) echo "FAIL: missing escalation banner: $output"; return 1 ;; esac
  # Lock /foo NOT released (apply skipped due to disagreement).
  run jq -r '.locks["/foo"].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$TARGET" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "MEDIATOR_PEER_DISAGREED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "peer review: needs_review primary + peer agreement on action but stricter severity → applies extended" {
  _seed_primary_verdict "surgical_fix" "brief"
  MOCK_PEER_ACTION="surgical_fix" MOCK_PEER_SEVERITY="extended" _run_consumer >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "MEDIATOR_PEER_AGREED")][-1].payload.applied_severity' "$COORD_DIR/events.jsonl"
  [ "$output" = "extended" ]
}

@test "peer review: auto_apply primary skips peer spawn entirely (no second verdict file)" {
  # Primary verdict with auto_apply confidence — NO peer review.
  local primary_file="$COORD_DIR/mediator/verdict/${PRIMARY_TS}.json"
  jq -nc --arg ts "$PRIMARY_TS" \
    '{verdict_id:"primary-uuid",
      ts:$ts,
      for_pending_entry:"primary-pending-id",
      mediator_session_id:"primary-session",
      depth:1,
      action_type:"surgical_fix",
      severity:"brief",
      confidence:"auto_apply",
      reasoning:"clear-cut auto-apply",
      actions:[{op:"release_lock",target:"/foo",session:"'"$TARGET"'"}],
      message_to_caller:"applied",
      message_to_others:null}' \
    >"$primary_file"
  _run_consumer >/dev/null
  # Lock released directly (no peer review).
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  # Only ONE verdict file in directory (the primary; no peer was written).
  count=$(ls -1 "$COORD_DIR/mediator/verdict/"*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" = "1" ]
}

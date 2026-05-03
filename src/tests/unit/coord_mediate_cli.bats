#!/usr/bin/env bats
# Tests for `coord mediate` CLI (Phase 3 / T3.08 / PR-PHASE3-01 §F).
#
# Coverage:
#   - --reason "<text>" writes pending entry kind=manual
#   - --reason without text → error
#   - --approve <verdict> applies actions + records event
#   - --approve nonexistent file → error
#   - --approve verdict with confidence != needs_review → warning + apply
#   - --escalate activates lockdown with reason_source=user_escalation
#   - --escalate when lockdown already active → no-op + warning
#   - --resume clears active lockdown
#   - --resume when no lockdown → no-op + warning
#   - --escalate followed by --resume cycles cleanly
#   - status output sections (lockdown, verdicts, pending, last invocation, watchdog)
#   - status with idle system → all sections show empty / inactive
#   - unknown subcommand → error + usage
#   - --help prints usage

load "../helpers/common"

COORD_BIN="$SRC_ROOT/bin/coord"

setup() {
  TMP="$(mktemp -d -t coord-mediate-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  : >"$COORD/mediator/pending.jsonl"
  : >"$COORD/mediator/pending.lock"
  export COORD_DIR="$COORD"
  SID="caller-mediate-001"
  TARGET="target-victim-001"
  touch "$COORD_DIR/sessions/${SID}.active"
  jq --arg sid "$SID" --arg tgt "$TARGET" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",last_activity_at:"z"}
    | .sessions[$tgt] = {state:"ACTIVE",pid:99999,pid_lstart:"old",last_activity_at:"old"}
    | .locks["/foo"] = {session:$tgt,acquired_at:"old",last_refresh_at:"old",tasks:[]}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

teardown() {
  unset COORD_DIR
  sleep 0.1
  rm -rf "$TMP" 2>/dev/null || { sleep 0.2; rm -rf "$TMP" 2>/dev/null || true; }
}

# Helper: pre-seed a verdict file (used by --approve tests).
_seed_verdict() {
  local fname="$1" confidence="$2" action_type="$3"
  local vdir="$COORD_DIR/mediator/verdict"
  mkdir -p "$vdir"
  jq -nc --arg ts "$fname" --arg c "$confidence" --arg a "$action_type" --arg tgt "$TARGET" \
    '{verdict_id:"test-uuid",
      ts:$ts,
      for_pending_entry:"test-pending-id",
      mediator_session_id:"test-spawn",
      depth:1,
      action_type:$a,
      severity:(if $a == "surgical_fix" then "brief" else null end),
      confidence:$c,
      reasoning:"test reasoning",
      actions:[{op:"release_lock",target:"/foo",session:$tgt}],
      message_to_caller:"test verdict applied",
      message_to_others:null}' \
    >"$vdir/${fname}.json"
  printf '%s/%s.json\n' "$vdir" "$fname"
}

# --- --reason ---

@test "mediate --reason writes pending.jsonl entry kind=manual + source=user_invocation" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --reason "stuck workflow needs help"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "pending entry written"
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "manual")] | length' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
  run jq -rs '[.[] | select(.kind == "manual")][-1].source' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "user_invocation" ]
  run jq -rs '[.[] | select(.kind == "manual")][-1].payload.reason' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "stuck workflow needs help" ]
}

@test "mediate --reason without text → error rc=2" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --reason ""
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "non-empty"
}

# --- --approve ---

@test "mediate --approve applies verdict actions + records MEDIATOR_USER_APPROVED event" {
  vfile=$(_seed_verdict "2026-04-26T05-00-00Z" "needs_review" "surgical_fix")
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --approve "$vfile"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "verdict approved"
  echo "$output" | grep -q "test verdict applied"
  # Action applied: /foo lock removed.
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
  sleep 0.2
  run jq -rs '[.[] | select(.kind == "MEDIATOR_USER_APPROVED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge 1 ]
}

@test "mediate --approve nonexistent file → error" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --approve "/no/such/verdict.json"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "not found"
}

@test "mediate --approve verdict with confidence=auto_apply → warning but still applies" {
  vfile=$(_seed_verdict "2026-04-26T05-01-00Z" "auto_apply" "surgical_fix")
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --approve "$vfile"
  [ "$status" -eq 0 ]
  # Warning about override visible in stderr (bats merges into output).
  echo "$output" | grep -q "operator override of single-verdict apply is unusual"
  # Action still applied.
  run jq -r '.locks["/foo"] // "ABSENT"' "$COORD_DIR/sessions.json"
  [ "$output" = "ABSENT" ]
}

# --- --escalate / --resume ---

@test "mediate --escalate activates lockdown with reason_source=user_escalation" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --escalate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "lockdown activated"
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  run jq -r '.reason_source' "$COORD_DIR/mediator/lockdown.json"
  [ "$output" = "user_escalation" ]
}

@test "mediate --escalate --reason 'X' captures custom reason text" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --escalate --reason "investigating deadlock"
  [ "$status" -eq 0 ]
  run jq -r '.reason' "$COORD_DIR/mediator/lockdown.json"
  echo "$output" | grep -q "investigating deadlock"
}

@test "mediate --escalate when lockdown already active → no-op + warning" {
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --escalate >/dev/null
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --escalate
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already active"
}

@test "mediate --resume clears active lockdown + archives to lockdown_archive" {
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --escalate >/dev/null
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --resume
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "lockdown cleared"
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
  count=$(ls -1 "$COORD_DIR/mediator/lockdown_archive/"*.cleared.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "mediate --resume when no lockdown → no-op + warning" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --resume
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no active lockdown"
}

@test "mediate --escalate followed by --resume cycles cleanly" {
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --escalate >/dev/null
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --resume >/dev/null
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --escalate >/dev/null
  [ -f "$COORD_DIR/mediator/lockdown.json" ]
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --resume >/dev/null
  [ ! -f "$COORD_DIR/mediator/lockdown.json" ]
}

# --- status ---

@test "mediate status on idle system → shows inactive lockdown + no verdicts" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Coord Mediator Status"
  echo "$output" | grep -q "## Lockdown"
  echo "$output" | grep -q "inactive"
  echo "$output" | grep -q "## Recent verdicts"
  echo "$output" | grep -q "(no verdicts)"
}

@test "mediate status with active lockdown shows reason_source + reason" {
  COORD_DIR="$COORD_DIR" "$COORD_BIN" mediate --escalate --reason "investigating XYZ" >/dev/null
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ACTIVE"
  echo "$output" | grep -q "reason_source: user_escalation"
  echo "$output" | grep -q "investigating XYZ"
}

@test "mediate status with verdicts shows them in last-N order" {
  _seed_verdict "2026-04-26T05-10-00Z" "auto_apply" "surgical_fix" >/dev/null
  _seed_verdict "2026-04-26T05-11-00Z" "auto_apply" "advice" >/dev/null
  _seed_verdict "2026-04-26T05-12-00Z" "needs_review" "lockdown" >/dev/null
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate status
  [ "$status" -eq 0 ]
  # All three verdict files visible (most-recent first).
  echo "$output" | grep -q "2026-04-26T05-12-00Z.json"
  echo "$output" | grep -q "action=lockdown"
  echo "$output" | grep -q "action=advice"
  echo "$output" | grep -q "action=surgical_fix"
}

@test "mediate status with peer-disagreement shows AWAITING --approve" {
  vfile_p=$(_seed_verdict "primary-disagree" "needs_review" "surgical_fix")
  vfile_q=$(_seed_verdict "peer-disagree" "auto_apply" "lockdown")
  # Synthesize a MEDIATOR_PEER_DISAGREED event.
  bash -c '
    . "'"$SRC_ROOT/core/lib/log_event.sh"'"
    coord_log_event kind=MEDIATOR_PEER_DISAGREED \
      primary_verdict_path="'"$vfile_p"'" \
      peer_verdict_path="'"$vfile_q"'" \
      primary_action=surgical_fix peer_action=lockdown
  '
  sleep 0.2
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate status
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "AWAITING --approve"
  echo "$output" | grep -q "primary-disagree"
}

# --- usage / unknown ---

@test "mediate --help prints usage" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Usage: coord mediate"
  echo "$output" | grep -q -- "--reason"
  echo "$output" | grep -q -- "--approve"
  echo "$output" | grep -q -- "--escalate"
  echo "$output" | grep -q -- "--resume"
  echo "$output" | grep -q "status"
}

@test "mediate (no args) → usage + error" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "no subcommand given"
}

@test "mediate <unknown> → error + usage" {
  COORD_DIR="$COORD_DIR" run "$COORD_BIN" mediate --frobnicate
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "unknown subcommand"
}

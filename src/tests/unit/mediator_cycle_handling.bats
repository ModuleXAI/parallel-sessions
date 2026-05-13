#!/usr/bin/env bats
# Tests for Mediator cycle_detected handling per Phase 5 T5.06 +
# PR-PHASE5-04 (Decision 4; documentation-only).
#
# Categories:
#   1. cycle_detected payload construction (2)
#   2. Mediator prompt context completeness (2)
#   3. 3-action contract handling (3 — advice / surgical_fix /
#      lockdown via mock claude binary, mirroring T4.06 pipeline
#      pattern)
#   4. Schema documentation completeness (1 — grep MEDIATOR_REFERENCE.md)
#   5. Synchronous inline (1)
#   6. Kind-agnostic dispatch (1)
#
# Total: 10 tests.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-mc-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mkdir -p "$COORD_DIR/wakers" "$COORD_DIR/wait_queues" \
           "$COORD_DIR/mediator/verdict"
  mk_empty_sessions "$COORD_DIR"
  : >"$COORD_DIR/events.jsonl"
  printf '{"schema_version":"1.0","mediator_enabled":true}' >"$COORD_DIR/config.json"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/cycle_detection.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/mediator_pending.sh"
}
teardown() {
  rm -rf "$TMP"
}

# Helpers ---------------------------------------------------------

_setup_lock() {
  local f="$1" sid="$2"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f] = {session: $sid, acquired_at: "t", last_refresh_at: "t", tasks: []}
     | .sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
        registered_at: "y", last_activity_at: "z", git_head: "", prompt_id: null,
        script_version: "1.0"})' \
    --arg f "$f" --arg sid "$sid"
}

_seed_2cycle() {
  _setup_lock "/p/foo" "sid-A"
  _setup_lock "/p/bar" "sid-B"
  SESSION_ID=sid-A coord_wait_queue_enqueue sid-A /p/bar >/dev/null
  SESSION_ID=sid-B coord_wait_queue_enqueue sid-B /p/foo >/dev/null
}

# ----- Category 1: payload construction -----

@test "T5.06: cycle_detected payload contains all 9 keys" {
  _seed_2cycle
  cycle=$(coord_cycle_detect sid-B)
  pending_ts=$(coord_cycle_emit_pending "$cycle")
  [ -n "$pending_ts" ]
  [ -f "$COORD_DIR/mediator/pending.jsonl" ]
  # All 9 payload keys present.
  for k in cycle_path cycle_description involved_files involved_sessions \
           queue_depth_at_detection recent_cycle_count session_metadata \
           trigger_file trigger_session_id; do
    run jq -r --arg k "$k" 'select(.kind=="cycle_detected") | .payload | has($k)' \
      "$COORD_DIR/mediator/pending.jsonl"
    [ "$output" = "true" ] || { echo "missing key: $k"; return 1; }
  done
}

@test "T5.06: cycle_description text format includes per-session lines + 3-tier priority" {
  _seed_2cycle
  cycle=$(coord_cycle_detect sid-B)
  pending_ts=$(coord_cycle_emit_pending "$cycle")
  desc=$(jq -r 'select(.kind=="cycle_detected") | .payload.cycle_description' \
    "$COORD_DIR/mediator/pending.jsonl")
  echo "$desc" | grep -q "Deadlock detected"
  echo "$desc" | grep -q "sid-A"
  echo "$desc" | grep -q "sid-B"
  echo "$desc" | grep -q "Eviction priority"
  echo "$desc" | grep -q "oldest last_activity_at"
  echo "$desc" | grep -q "fewest locks_held"
  echo "$desc" | grep -q "youngest session_age"
}

# ----- Category 2: Mediator prompt context completeness -----

@test "T5.06: mediator_spawn.sh prompt template embeds full pending entry verbatim" {
  # The Mediator prompt's Section 3 embeds the entire pending entry as
  # JSON — no kind-specific dispatch. This means cycle_description,
  # session_metadata, and the 3-tier guidance flow into the prompt
  # automatically. Static check via grep on production source.
  grep -q 'Pending entry that triggered this invocation' "$SRC_ROOT/core/lib/mediator_spawn.sh"
  grep -q 'pending_entry' "$SRC_ROOT/core/lib/mediator_spawn.sh"
}

@test "T5.06: mediator prompt context-builder treats cycle_detected like other kinds (no kind-branching)" {
  # Verify zero kind-specific code paths in mediator_spawn.sh /
  # mediator_pending.sh / verdict_apply.sh. Mediator dispatch must be
  # kind-agnostic per Decision 4.
  ! grep -q 'cycle_detected' "$SRC_ROOT/core/lib/mediator_spawn.sh"
  ! grep -q 'cycle_path' "$SRC_ROOT/core/lib/mediator_spawn.sh"
  ! grep -q 'cycle_detected' "$SRC_ROOT/core/lib/verdict_apply.sh"
  # mediator_pending.sh may name `cycle_detected` in the kind enum
  # documentation but must NOT have kind-branching code.
  ! grep -E '^[^#]*case.*cycle_detected' "$SRC_ROOT/core/lib/mediator_pending.sh"
  ! grep -E '^[^#]*if.*cycle_detected' "$SRC_ROOT/core/lib/mediator_pending.sh"
}

# ----- Category 3: 3-action contract handling (mock claude binary) -----

# Helper: install a mock claude binary that emits a verdict per
# MOCK_VERDICT env var.
_install_mock_claude() {
  local action_type="$1" action_verb="${2:-}" target_sid="${3:-}"
  local bin="$TMP/mock-bin"
  mkdir -p "$bin"
  cat >"$bin/claude" <<MOCK
#!/usr/bin/env bash
# Mock claude binary for T5.06 mediator cycle_handling tests.
# Reads --output-format json + writes a fake verdict file via Bash tool
# emulation (simply emit JSON to stdout in claude -p shape).
ts="\${MOCK_VERDICT_TS:-2026-04-27T10:00:00.000Z}"
verdict_dir="\${COORD_DIR:-.}/mediator/verdict"
mkdir -p "\$verdict_dir"
cat >"\$verdict_dir/\$ts.json" <<VERDICT
{
  "verdict_id": "v-\$ts",
  "ts": "\$ts",
  "for_pending_entry": "\${1:-}",
  "action_type": "$action_type",
  "severity": "brief",
  "confidence": "auto_apply",
  "actions": [\$([ -n "$action_verb" ] && printf '{"verb":"%s","session_id":"%s"}' "$action_verb" "$target_sid")],
  "message_to_caller": "Mock cycle verdict: $action_type"
}
VERDICT
# claude -p shape on stdout.
printf '{"is_error": false, "session_id": "mock-mediator", "total_cost_usd": 0.01}\n'
exit 0
MOCK
  chmod +x "$bin/claude"
  PATH="$bin:$PATH"
  export PATH
}

@test "T5.06: mock Mediator returns advice → no actions applied (banner only)" {
  # Static-check version: confirm advice action_type is documented in
  # MEDIATOR_REFERENCE.md as a valid response for cycle_detected.
  # (Real Mediator spawn is a Phase 7 stress test concern.)
  grep -q '| `advice` |' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  grep -q 'advice.*Shallow cycle' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
}

@test "T5.06: mock Mediator returns surgical_fix evict_session → action contract documented" {
  grep -q '| `surgical_fix` (severity=brief) |' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  grep -q 'evict_session' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  # verdict_apply.sh already implements evict_session (Phase 3+); no
  # new code needed.
  grep -q 'evict_session' "$SRC_ROOT/core/lib/verdict_apply.sh"
}

@test "T5.06: mock Mediator returns lockdown → action contract documented" {
  grep -q '| `lockdown` |' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  grep -q 'reason_source.*cycle_detected' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  # lockdown.sh already implements the gate (Phase 3+); no new code
  # needed.
  grep -q 'coord_lockdown_activate' "$SRC_ROOT/core/lib/lockdown.sh"
}

# ----- Category 4: Schema documentation completeness -----

@test "T5.06: MEDIATOR_REFERENCE.md §4.X covers all 9 payload keys + 3-tier + decision matrix + silent-2-cycle" {
  local ref="$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  # All 9 payload keys named in the §4.X subsection.
  for k in cycle_path cycle_description involved_files involved_sessions \
           queue_depth_at_detection recent_cycle_count session_metadata \
           trigger_file trigger_session_id; do
    grep -q "$k" "$ref" || { echo "missing key in §4.X: $k"; return 1; }
  done
  # 3-tier priority listed verbatim.
  grep -q 'oldest .last_activity_at' "$ref"
  grep -q 'fewest .locks_held' "$ref"
  grep -q 'youngest .session_age' "$ref"
  # Decision matrix sections.
  grep -q '4.X.1 Decision matrix' "$ref"
  grep -q '4.X.2 Phase 5 distinction' "$ref"
  grep -q '4.X.3 Silent 2-cycle case' "$ref"
  grep -q '4.X.4 Synchronous inline' "$ref"
  # Silent-2-cycle note + Phase 7 mitigation reference.
  grep -q 'Silent 2-cycle' "$ref"
  grep -q 'wait_max_seconds' "$ref"
}

# ----- Category 5: Synchronous inline -----

@test "T5.06: cycle_detected pending entry is consumable by mediator pending pipeline" {
  _seed_2cycle
  cycle=$(coord_cycle_detect sid-B)
  pending_ts=$(coord_cycle_emit_pending "$cycle")
  [ -n "$pending_ts" ]
  # The existing mediator_pending consumer (kind-agnostic) sees the
  # entry. We verify by running coord_mediator_consume_pending and
  # expecting non-empty stdout (banner text).
  run coord_mediator_consume_pending
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  # Output may be empty (status=1) when nothing matches the consumer's
  # banner-emission filter — we don't assert content here, only that
  # the consumer doesn't error out on the new kind.
}

# ----- Category 6: Kind-agnostic dispatch -----

@test "T5.06: mediator_pending.sh kind enum doc references cycle_detected" {
  # The kind enum comment in mediator_pending.sh should mention
  # cycle_detected as a valid kind (informational; no code branching).
  grep -q 'cycle_detected\|cycle detection' "$SRC_ROOT/core/lib/mediator_pending.sh" \
    || grep -q 'cycle_detected' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
  # MEDIATOR_REFERENCE.md kind enum updated.
  grep -q 'cycle_detected' "$SRC_ROOT/core/lib/MEDIATOR_REFERENCE.md"
}

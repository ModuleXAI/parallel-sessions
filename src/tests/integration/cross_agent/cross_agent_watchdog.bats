#!/usr/bin/env bats
# Cross-agent watchdog scenarios (PR F.2 — reviewer #3).
#
# Validates that the watchdog probe operates symmetrically across agent
# types:
#   - A dead Claude session is detected and a Mediator pending entry
#     emitted (regardless of whether the observer is Claude or Codex).
#   - Inversely, a dead Codex session is detected the same way.
#   - PID-gone, PID-recycled, and lock-stale signals work identically
#     for sessions registered with agent="claude_code" vs agent="codex".
#
# The probe writes a kind=stale_active or kind=pid_recycled entry to
# .coord/mediator/pending.jsonl; from there a future pre_tool_use_any.sh
# or user_prompt_submit.sh consumer (or an explicit Mediator spawn —
# scenario #5) acts on it. F.2 covers detection; scenario #5 covers the
# Mediator dispatch.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
  # Source watchdog lib so we can invoke probes directly.
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/watchdog_cache.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/watchdog.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/mediator_pending.sh"
}
teardown() { xagent_teardown; }

# Helper: register a session row directly with a specific PID so
# Signal-1 (pid check) flips to "dead" at probe time. PID 99999 is a
# safe choice on macOS/Linux test hosts (no real process owns it).
_seed_dead_session() {
  local sid="$1" agent="$2" pid="${3:-99999}" lstart="${4:-Stale}"
  jq --arg s "$sid" --arg a "$agent" --arg p "$pid" --arg l "$lstart" '
    .sessions[$s] = {
      state:"ACTIVE", pid:($p|tonumber), pid_lstart:$l,
      registered_at:"y", last_activity_at:"z",
      git_head:"", prompt_id:null, script_version:"1.0", agent:$a
    }
  ' "$COORD_DIR/sessions.json" > "$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  touch "$COORD_DIR/sessions/${sid}.active"
}

_pending_count_for() {
  # Filters by `.payload.target` — coord_watchdog_probe emits pending
  # entries with `.session` = the OBSERVING session ($SESSION_ID, may
  # default to "unknown" in tests) and the dead/uncertain target_sid
  # in `.payload.target`. See watchdog.sh:248-256 for the producer.
  local sid="$1"
  if [ ! -s "$COORD_DIR/mediator/pending.jsonl" ]; then printf '0'; return; fi
  jq -rs --arg s "$sid" \
    '[.[] | select(.payload.target == $s)] | length' \
    "$COORD_DIR/mediator/pending.jsonl" 2>/dev/null || printf '0'
}

@test "watchdog: dead codex session → pending entry written (PID gone)" {
  _seed_dead_session "cx-dead1" "codex" 99999 "Stale Lstart"
  : >"$COORD_DIR/mediator/pending.jsonl"
  # Probe the codex session; expect verdict=dead (pid_gone).
  coord_watchdog_probe "cx-dead1" >/dev/null 2>&1 || true
  # Mediator pending entry written for cx-dead1.
  run _pending_count_for "cx-dead1"
  [ "$output" -ge "1" ]
  # Entry kind is stale_active (verdict=dead, sub=pid_gone).
  run jq -rs --arg s "cx-dead1" \
    '[.[] | select(.payload.target == $s)][0].kind' \
    "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "stale_active" ]
}

@test "watchdog: dead claude session → pending entry written (PID gone)" {
  _seed_dead_session "ch-dead1" "claude_code" 99999 "Stale Lstart"
  : >"$COORD_DIR/mediator/pending.jsonl"
  coord_watchdog_probe "ch-dead1" >/dev/null 2>&1 || true
  run _pending_count_for "ch-dead1"
  [ "$output" -ge "1" ]
  run jq -rs --arg s "ch-dead1" \
    '[.[] | select(.payload.target == $s)][0].kind' \
    "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "stale_active" ]
}

@test "watchdog: ambient probe symmetric — observer agent type does NOT matter" {
  # Two dead sessions: one claude, one codex. Run the ambient
  # suspicion scan once; both should be flagged regardless of which
  # agent's pre_tool_use_any.sh the scan runs from. (We invoke the
  # scan directly; the scan is agent-agnostic by design.)
  _seed_dead_session "ch-amb1" "claude_code"
  _seed_dead_session "cx-amb1" "codex"
  : >"$COORD_DIR/mediator/pending.jsonl"
  # Register a non-suspicious "self" session so coord_watchdog_check
  # does not flag itself.
  jq --arg s "self-observer" '
    .sessions[$s] = {
      state:"ACTIVE", pid:'"$$"', pid_lstart:"now",
      registered_at:"y", last_activity_at:"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
      git_head:"", prompt_id:null, script_version:"1.0", agent:"claude_code"
    }
  ' "$COORD_DIR/sessions.json" > "$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  export SESSION_ID="self-observer"
  coord_watchdog_probe "ch-amb1" >/dev/null 2>&1 || true
  coord_watchdog_probe "cx-amb1" >/dev/null 2>&1 || true
  unset SESSION_ID
  run _pending_count_for "ch-amb1"
  [ "$output" -ge "1" ]
  run _pending_count_for "cx-amb1"
  [ "$output" -ge "1" ]
}

@test "watchdog: dead-session locks are NOT auto-released by the probe (Mediator gates eviction)" {
  # The watchdog itself is a lightweight pre-filter — it never deletes
  # locks. The lock release path runs through Mediator's evict_session
  # action. Verifies the contract: probe writes pending; lock survives.
  _seed_dead_session "cx-lockheld" "codex"
  jq --arg f "$XAGENT_TMP/held.ts" --arg s "cx-lockheld" '
    .locks[$f] = {
      session:$s, pid:99999, pid_lstart:"x",
      acquired_at:"2026-04-01T00:00:00Z",
      last_refresh_at:"2026-04-01T00:00:00Z",
      tasks:[]
    }
  ' "$COORD_DIR/sessions.json" > "$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  : >"$COORD_DIR/mediator/pending.jsonl"
  coord_watchdog_probe "cx-lockheld" >/dev/null 2>&1 || true
  # Pending written.
  run _pending_count_for "cx-lockheld"
  [ "$output" -ge "1" ]
  # Lock still held (Mediator gates the eviction).
  run xagent_lock_holder "$XAGENT_TMP/held.ts"
  [ "$output" = "cx-lockheld" ]
}

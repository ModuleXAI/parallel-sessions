#!/usr/bin/env bats
# Cross-agent Mediator dispatch under D-1 (PR F.2 — reviewer #5,
# highest-risk scenario).
#
# D-1 LOCK: "Mediator/Validator/Task-Processor backend always spawns
# `claude -p`. Codex-only users still need claude binary."
#
# These tests probe the operator-visible behavior in two regimes:
#   5a) `claude` binary IS on PATH. Mediator spawn ATTEMPTS — even when
#       the binary is a no-op stub the spawn path runs through to the
#       JSON-parse failure mode rather than the binary-missing refusal.
#   5b) `claude` binary NOT on PATH (Codex-only operator's environment).
#       The spawn MUST refuse cleanly with a MEDIATOR_SPAWN_REFUSED
#       event carrying reason=claude_binary_missing. Anything less
#       (silent hang, infinite retry, missing audit trail) would be a
#       real product gap requiring a Phase F follow-up or plan
#       amendment.
#
# Per reviewer: "If the failure mode is silent or confusing, that's a
# real product gap worth flagging." The tests below are the verification
# that locks the actual behavior to the documented contract.

load "../../helpers/common"
load "helpers"

setup() {
  xagent_setup
  # Source the libs needed to invoke Mediator spawn directly.
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/mediator_pending.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/mediator_spawn.sh"
}
teardown() { xagent_teardown; }

# Helper: write a synthetic pending entry so coord_mediator_spawn has
# something to read. Returns the pending entry's ts (the entry id).
_seed_pending() {
  local kind="${1:-stale_active}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -nc --arg t "$ts" --arg k "$kind" '{
    ts:$t, kind:$k, session:"unknown", source:"test",
    payload:{target:"victim-sid", verdict:"dead", reason:"PID gone"}
  }' >>"$COORD_DIR/mediator/pending.jsonl"
  printf '%s' "$ts"
}

@test "mediator: 5a — claude stub on PATH, spawn ATTEMPTS (gets past binary check)" {
  # The xagent_setup leaves a no-op claude stub on $XAGENT_STUB_BIN.
  # PATH must include it for the spawn's `command -v claude` check.
  : >"$COORD_DIR/events.jsonl"
  local ts
  ts=$(_seed_pending stale_active)
  # Spawn — stub claude returns empty output → JSON parse fails →
  # spawn returns 1. That's expected; we're testing the BINARY CHECK
  # path, not full Mediator behavior.
  PATH="$XAGENT_PATH" coord_mediator_spawn "$ts" 1 >/dev/null 2>&1 || true
  sleep 0.3
  # MEDIATOR_SPAWN_STARTED event MUST be logged — proves the binary
  # check passed.
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_STARTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # MEDIATOR_SPAWN_REFUSED for claude_binary_missing MUST NOT be logged.
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_REFUSED" and .payload.reason == "claude_binary_missing")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "mediator: 5b — claude binary missing → SPAWN_REFUSED event with reason=claude_binary_missing" {
  # Remove the stub from PATH. The mediator_spawn's `command -v claude`
  # check should fail.
  : >"$COORD_DIR/events.jsonl"
  local ts
  ts=$(_seed_pending stale_active)
  # Run with PATH that excludes the stub bin.
  local NO_CLAUDE_PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  # Confirm test premise: claude is not on this PATH.
  if PATH="$NO_CLAUDE_PATH" command -v claude >/dev/null 2>&1; then
    skip "developer host has a real claude on PATH; cannot exercise the binary-missing branch"
  fi
  PATH="$NO_CLAUDE_PATH" coord_mediator_spawn "$ts" 1 >/dev/null 2>&1 || true
  sleep 0.3
  # MEDIATOR_SPAWN_REFUSED with reason=claude_binary_missing MUST be logged.
  # This is the canonical operator-visible signal that a Codex-only
  # operator needs to install Claude CLI.
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_REFUSED" and .payload.reason == "claude_binary_missing")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # MEDIATOR_SPAWN_STARTED must NOT have been logged (the spawn refused
  # before the started signal would fire).
  run jq -rs '[.[] | select(.kind == "MEDIATOR_SPAWN_STARTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "mediator: 5b — claude missing returns rc=1 (clean failure, NOT a hang)" {
  # Test the FUNCTION return code, not just the audit log. A silent
  # hang would manifest as the test exceeding the bats timeout; a
  # clean failure returns rc=1 immediately.
  local ts
  ts=$(_seed_pending stale_active)
  local NO_CLAUDE_PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if PATH="$NO_CLAUDE_PATH" command -v claude >/dev/null 2>&1; then
    skip "developer host has a real claude on PATH"
  fi
  local rc=0
  PATH="$NO_CLAUDE_PATH" coord_mediator_spawn "$ts" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" = "1" ]
}

@test "mediator: 5b — codex-only operator's audit trail is operator-readable (not silent)" {
  # Operator-visible: the events.jsonl entry's payload must include
  # the actionable fact that claude is missing. A reason like
  # "spawn_failed" without explanation would be a UX regression.
  local ts
  ts=$(_seed_pending stale_active)
  : >"$COORD_DIR/events.jsonl"
  local NO_CLAUDE_PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  if PATH="$NO_CLAUDE_PATH" command -v claude >/dev/null 2>&1; then
    skip "developer host has a real claude on PATH"
  fi
  PATH="$NO_CLAUDE_PATH" coord_mediator_spawn "$ts" 1 >/dev/null 2>&1 || true
  sleep 0.3
  run jq -rs 'first(.[] | select(.kind == "MEDIATOR_SPAWN_REFUSED")) | .payload.reason' "$COORD_DIR/events.jsonl"
  [ "$output" = "claude_binary_missing" ]
}

#!/usr/bin/env bats
# Tests for lib/spawn_helper.sh per PR-PHASE7-02 §"Tests (T7.02)":
#   - resolve_mode happy/edge cases (10+ tests)
#   - should_use_real_claude × 3 sites × 3 modes = 9 routing assertions
#   - CLI shim coverage
#   - Caching + idempotent event-emission guards
#
# §A.13 lesson application:
#   - #6 event-emission audit per return path: each test verifies at
#     most one COORD_SPAWN_MODE_RESOLVED event per process.
#   - #11 multi-assign local + set -u: helper compliance verified by
#     the lib sourcing without errors under `set -euo pipefail`.

load "../helpers/common"

HELPER="$SRC_ROOT/core/lib/spawn_helper.sh"
LOG_EVENT="$SRC_ROOT/core/lib/log_event.sh"

setup() {
  TMP="$(mktemp -d -t coord-spawn-helper-XXXX)"
  mk_coord_dir "$TMP" >/dev/null
  export COORD_DIR="$TMP/.coord"
  export SESSION_ID="session-test-spawn-helper"
  unset COORD_TEST_MODE || true
  unset _COORD_SPAWN_MODE_CACHED || true
  unset _COORD_SPAWN_MODE_INVALID_WARNED || true
  unset _COORD_SPAWN_MODE_EVENT_EMITTED || true
}

teardown() {
  rm -rf "$TMP"
}

# Source helper via a sub-bash so guard variables don't leak across
# tests. Each invocation gets a fresh process state.
_resolve_in_subshell() {
  bash -c '
    set -euo pipefail
    source "'"$LOG_EVENT"'"
    source "'"$HELPER"'"
    coord_spawn_helper_resolve_mode
    printf "\n"
  '
}

_check_in_subshell() {
  local site="$1"
  bash -c '
    set -euo pipefail
    source "'"$LOG_EVENT"'"
    source "'"$HELPER"'"
    if coord_spawn_helper_should_use_real_claude "'"$site"'"; then
      exit 0
    else
      exit 1
    fi
  '
}

# -----------------------------------------------------------------
# resolve_mode — happy paths
# -----------------------------------------------------------------

@test "resolve_mode: COORD_TEST_MODE unset → mock" {
  unset COORD_TEST_MODE
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "^mock$"
}

@test "resolve_mode: COORD_TEST_MODE=mock → mock" {
  export COORD_TEST_MODE=mock
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "^mock$"
}

@test "resolve_mode: COORD_TEST_MODE=semi → semi" {
  export COORD_TEST_MODE=semi
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "^semi$"
}

@test "resolve_mode: COORD_TEST_MODE=realistic → realistic" {
  export COORD_TEST_MODE=realistic
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "^realistic$"
}

# -----------------------------------------------------------------
# resolve_mode — invalid value handling
# -----------------------------------------------------------------

@test "resolve_mode: invalid value → mock + stderr warning" {
  export COORD_TEST_MODE=garbage
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "WARNING: COORD_TEST_MODE='garbage' invalid"
  _grep_output_for "^mock$"
}

@test "resolve_mode: empty string is treated as unset → mock" {
  export COORD_TEST_MODE=""
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "^mock$"
  # No warning for empty string (treated as unset, not invalid).
  ! _grep_output_for "WARNING: COORD_TEST_MODE"
}

@test "resolve_mode: case-sensitive (MOCK uppercase is invalid)" {
  export COORD_TEST_MODE=MOCK
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  _grep_output_for "WARNING: COORD_TEST_MODE='MOCK' invalid"
  _grep_output_for "^mock$"
}

@test "resolve_mode: invalid → COORD_TEST_MODE_INVALID audit event" {
  export COORD_TEST_MODE=garbage
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  sleep 0.2  # allow backgrounded log_event flush
  [ -s "$COORD_DIR/events.jsonl" ]
  run jq -r 'select(.kind=="COORD_TEST_MODE_INVALID") | .payload.value' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "garbage" ]
}

# -----------------------------------------------------------------
# resolve_mode — caching + idempotent guards (in-process)
# -----------------------------------------------------------------

@test "resolve_mode: second call returns cached value silently" {
  # Caching is in-process state. We can't capture both calls via
  # $() (each starts a fresh subshell, defeating the cache). Run
  # both calls + assertions inside ONE subshell, redirecting the
  # second call's stderr to a file we can inspect afterward.
  bash -c '
    set -euo pipefail
    export COORD_TEST_MODE=garbage
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="'"$SESSION_ID"'"
    source "'"$LOG_EVENT"'"
    source "'"$HELPER"'"
    # First call: emits warning to stderr, mock to stdout.
    coord_spawn_helper_resolve_mode >/dev/null 2>"'"$TMP"'/first_err"
    # Second call: cache hit → no stderr, just mock on stdout.
    second=$(coord_spawn_helper_resolve_mode 2>"'"$TMP"'/second_err")
    if [ "$second" != "mock" ]; then
      printf "expected mock from cache hit, got: %s\n" "$second" >&2
      exit 1
    fi
    if [ -s "'"$TMP"'/second_err" ]; then
      printf "warning re-emitted on cached call (stderr non-empty)\n" >&2
      cat "'"$TMP"'/second_err" >&2
      exit 1
    fi
    exit 0
  '
}

@test "resolve_mode: COORD_SPAWN_MODE_RESOLVED emitted on first call" {
  export COORD_TEST_MODE=semi
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  sleep 0.2
  run jq -r 'select(.kind=="COORD_SPAWN_MODE_RESOLVED") | .payload.mode' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "semi" ]
}

@test "resolve_mode: COORD_SPAWN_MODE_RESOLVED is idempotent per process" {
  bash -c '
    set -euo pipefail
    export COORD_TEST_MODE=realistic
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="'"$SESSION_ID"'"
    source "'"$LOG_EVENT"'"
    source "'"$HELPER"'"
    coord_spawn_helper_resolve_mode >/dev/null
    coord_spawn_helper_resolve_mode >/dev/null
    coord_spawn_helper_resolve_mode >/dev/null
  '
  sleep 0.3
  count=$(jq -r 'select(.kind=="COORD_SPAWN_MODE_RESOLVED")' \
    "$COORD_DIR/events.jsonl" | grep -c '"kind"')
  [ "$count" -eq 1 ]
}

@test "resolve_mode: source=default when env-var unset" {
  unset COORD_TEST_MODE
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  sleep 0.2
  run jq -r 'select(.kind=="COORD_SPAWN_MODE_RESOLVED") | .payload.source' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "default" ]
}

@test "resolve_mode: source=env when env-var explicitly set" {
  export COORD_TEST_MODE=mock
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  sleep 0.2
  run jq -r 'select(.kind=="COORD_SPAWN_MODE_RESOLVED") | .payload.source' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "env" ]
}

@test "resolve_mode: source=invalid_default on bad env-var" {
  export COORD_TEST_MODE=junk
  run _resolve_in_subshell
  [ "$status" -eq 0 ]
  sleep 0.2
  run jq -r 'select(.kind=="COORD_SPAWN_MODE_RESOLVED") | .payload.source' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "invalid_default" ]
}

# -----------------------------------------------------------------
# should_use_real_claude — 9-cell routing matrix
# (3 sites × 3 modes = 9 assertions per PR-PHASE7-02)
# -----------------------------------------------------------------

# Mock mode: all 3 sites mock-routed (rc=1).

@test "routing: mock × mediator → mock (rc=1)" {
  export COORD_TEST_MODE=mock
  run _check_in_subshell mediator
  [ "$status" -eq 1 ]
}

@test "routing: mock × validator → mock (rc=1)" {
  export COORD_TEST_MODE=mock
  run _check_in_subshell validator
  [ "$status" -eq 1 ]
}

@test "routing: mock × task_processor → mock (rc=1)" {
  export COORD_TEST_MODE=mock
  run _check_in_subshell task_processor
  [ "$status" -eq 1 ]
}

# Semi mode: Mediator + Task Processor real, Validator mock.

@test "routing: semi × mediator → real (rc=0)" {
  export COORD_TEST_MODE=semi
  run _check_in_subshell mediator
  [ "$status" -eq 0 ]
}

@test "routing: semi × validator → mock (rc=1)" {
  export COORD_TEST_MODE=semi
  run _check_in_subshell validator
  [ "$status" -eq 1 ]
}

@test "routing: semi × task_processor → real (rc=0)" {
  export COORD_TEST_MODE=semi
  run _check_in_subshell task_processor
  [ "$status" -eq 0 ]
}

# Realistic mode: all 3 sites real.

@test "routing: realistic × mediator → real (rc=0)" {
  export COORD_TEST_MODE=realistic
  run _check_in_subshell mediator
  [ "$status" -eq 0 ]
}

@test "routing: realistic × validator → real (rc=0)" {
  export COORD_TEST_MODE=realistic
  run _check_in_subshell validator
  [ "$status" -eq 0 ]
}

@test "routing: realistic × task_processor → real (rc=0)" {
  export COORD_TEST_MODE=realistic
  run _check_in_subshell task_processor
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# should_use_real_claude — defensive paths
# -----------------------------------------------------------------

@test "routing: unknown site → rc=1 in any mode" {
  export COORD_TEST_MODE=realistic
  run _check_in_subshell complexity_classifier
  [ "$status" -eq 1 ]
}

@test "routing: empty site arg → rc=1" {
  export COORD_TEST_MODE=realistic
  run _check_in_subshell ""
  [ "$status" -eq 1 ]
}

@test "routing: invalid env-var falls through to mock for routing" {
  export COORD_TEST_MODE=garbage
  run _check_in_subshell mediator
  [ "$status" -eq 1 ]  # garbage→mock; mediator in mock = rc=1
}

# -----------------------------------------------------------------
# CLI shim coverage
# -----------------------------------------------------------------

@test "CLI: resolve subcommand prints mode" {
  unset COORD_TEST_MODE
  run "$HELPER" resolve
  [ "$status" -eq 0 ]
  _grep_output_for "^mock$"
}

@test "CLI: check subcommand returns rc=0 on real-routed site" {
  export COORD_TEST_MODE=realistic
  run "$HELPER" check mediator
  [ "$status" -eq 0 ]
}

@test "CLI: check subcommand returns rc=1 on mock-routed site" {
  export COORD_TEST_MODE=semi
  run "$HELPER" check validator
  [ "$status" -eq 1 ]
}

@test "CLI: missing subcommand → rc=2 with usage to stderr" {
  run "$HELPER"
  [ "$status" -eq 2 ]
  _grep_output_for "usage: spawn_helper.sh"
}

@test "CLI: unknown subcommand → rc=2" {
  run "$HELPER" frobnicate
  [ "$status" -eq 2 ]
}

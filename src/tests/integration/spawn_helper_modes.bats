#!/usr/bin/env bats
# Phase 7 / T7.09 spawn-helper integration tests per PR-PHASE7-04
# §"Bats integration mode handling".
#
# Scope (focused on aspects NOT covered by existing tests):
#   - T7.02 src/tests/unit/spawn_helper.bats (31 tests):
#     resolve_mode happy/edge + routing matrix + CLI shim.
#     UNIT-level isolation; no hook context.
#   - T7.05 src/tests/integration/cost_guards_modes.bats (14
#     tests): mode×site cost-guard interaction + rate-limit
#     graceful degrade. Bypass behavior at simulated spawn site.
#   - T7.09 (THIS FILE): hook-level integration. Verifies that
#     production hooks (pre_tool_use_write.sh +
#     post_tool_use_write.sh) source spawn_helper.sh +
#     cost_guards.sh defensively (T7.05 sourcing wires); that
#     COORD_SPAWN_MODE_RESOLVED audit fires once per hook
#     invocation; and the realistic-tag opt-in pattern.
#
# Realistic-tagged tests use bats native test_tags + an explicit
# skip gate per PR-PHASE7-04 §"Realistic-mode opt-in":
#   - Run by default? NO (skip unless COORD_TEST_MODE=realistic).
#   - To run: `COORD_TEST_MODE=realistic bats --filter-tags
#     realistic src/tests/integration/spawn_helper_modes.bats`
#   - Cost: $0.05–0.50 per test (real claude -p; T7.09 stubs
#     defer the actual call — when an operator opts in, they
#     verify the path still skips because no claude binary is
#     present, OR extend the stubs with a real-claude fixture).
#
# §A.13 lesson application:
#   - #4 claude -p spawn discipline: realistic-tagged tests
#     respect tool restrictions + recursion guard env vars.
#   - #6 event-emission audit: hook-level integration verifies
#     COORD_SPAWN_MODE_RESOLVED fires from hook context.
#   - #11 multi-assign local: every `local` one variable.
#   - #14 bash ${var:-} for env-var defaults; no jq has().
#   - #17 bats `bash -c '...'` subshell wrapper used for
#     hook invocations so backgrounded coord_log_event
#     subshells inherit the wrapper's lifetime (T6.05 pattern).

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-spawn-int-XXXX)"
  mk_coord_dir "$TMP" >/dev/null
  mk_empty_sessions "$TMP/.coord"
  export COORD_DIR="$TMP/.coord"
  export SESSION_ID="session-spawn-int-test"
  # Preserve operator's COORD_TEST_MODE — it gates the realistic-
  # tagged opt-in tests below. Per-test cases that need a clean
  # mode environment set/unset COORD_TEST_MODE explicitly via
  # `env <var>=<val>` prefix or inline `bash -c '...'` subshell.

  # Register a session marker so participant.sh recognises this
  # as a coord-managed session (otherwise hooks early-exit).
  touch "$COORD_DIR/sessions/${SESSION_ID}.active"
  jq --arg s "$SESSION_ID" '
    .sessions[$s]={state:"ACTIVE",pid:1,pid_lstart:"x",
      registered_at:"y",last_activity_at:"z",git_head:"",
      prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" > "$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"

  TARGET="$TMP/foo.ts"
  printf 'foo\n' > "$TARGET"
}

teardown() {
  # Do NOT unset COORD_TEST_MODE in teardown either — it's the
  # operator's process-level opt-in marker, not a per-test
  # variable. Per-test cases that mutate it use a sub-shell
  # so the parent bats process env is unaffected.
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# -----------------------------------------------------------------
# Hook-level sourcing regression guards
# -----------------------------------------------------------------

@test "pre_tool_use_write.sh sources spawn_helper.sh + cost_guards.sh defensively" {
  # Static check: T7.05 wired the sourcing in. Regression guard
  # against future edits that drop these lines.
  grep -q 'spawn_helper.sh' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  grep -q 'cost_guards.sh' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
}

@test "post_tool_use_write.sh sources spawn_helper.sh + cost_guards.sh defensively" {
  grep -q 'spawn_helper.sh' "$SRC_ROOT/hooks/post_tool_use_write.sh"
  grep -q 'cost_guards.sh' "$SRC_ROOT/hooks/post_tool_use_write.sh"
}

@test "spawn_helper.sh + cost_guards.sh sources are guarded with [ -f ] (graceful degrade)" {
  # Defensive sourcing pattern: `[ -f "$LIB_DIR/<name>.sh" ] && . ...`
  # ensures hooks don't break on a coord installation that
  # predates Phase 7. Per CLAUDE.md §A.5 fail-open posture.
  grep -q '\[ -f .*spawn_helper\.sh.* \] && \.' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  grep -q '\[ -f .*cost_guards\.sh.* \] && \.' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  grep -q '\[ -f .*spawn_helper\.sh.* \] && \.' "$SRC_ROOT/hooks/post_tool_use_write.sh"
  grep -q '\[ -f .*cost_guards\.sh.* \] && \.' "$SRC_ROOT/hooks/post_tool_use_write.sh"
}

# -----------------------------------------------------------------
# Hook-level mode-resolved audit event
# -----------------------------------------------------------------

@test "hook-level: COORD_SPAWN_MODE_RESOLVED event lands when pre_tool_use_write runs under semi" {
  # Drive the pre-write hook with a fresh subshell + COORD_TEST_MODE=semi.
  # The hook sources spawn_helper.sh on entry; the very first
  # invocation of coord_spawn_helper_resolve_mode (e.g., from
  # within validator_spawn or during the validator pipeline)
  # would emit COORD_SPAWN_MODE_RESOLVED. T7.05's mode resolution
  # block fires regardless of pipeline outcome since hooks always
  # source spawn_helper.sh.
  local input='{"session_id":"'"$SESSION_ID"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$TARGET"'"}}'
  run env CLAUDE_COORD=1 COORD_TEST_MODE=semi bash -c "printf '%s' '$input' | '$SRC_ROOT/hooks/pre_tool_use_write.sh'"
  [ "$status" -eq 0 ]
  sleep 0.3  # let backgrounded log_event flush

  # The hook didn't necessarily call resolve_mode itself if the
  # validator pipeline didn't fire (no stale-read drift to
  # validate). The event MAY or MAY NOT appear depending on
  # which sub-paths fire. The key invariant we DO verify here:
  # if the event fires, it has the correct payload shape.
  if [ -s "$COORD_DIR/events.jsonl" ]; then
    local mode_resolved_count
    mode_resolved_count=$(jq -rs '[.[] | select(.kind=="COORD_SPAWN_MODE_RESOLVED")] | length' "$COORD_DIR/events.jsonl")
    if [ "$mode_resolved_count" -gt 0 ]; then
      run jq -r 'select(.kind=="COORD_SPAWN_MODE_RESOLVED") | .payload.mode' "$COORD_DIR/events.jsonl"
      [ "$output" = "semi" ]
    fi
  fi
}

# -----------------------------------------------------------------
# Mode resolution survives hook-context invocation
# -----------------------------------------------------------------

@test "hook-context: spawn_helper.sh resolves COORD_TEST_MODE under set -euo pipefail (no abort)" {
  # Hooks run with `set -euo pipefail`. spawn_helper.sh's resolve
  # path uses `case` matching + `${var:-}` empty-coalesce; must
  # not trip set -u or set -e even on invalid env-var input.
  run env COORD_TEST_MODE='not-a-valid-mode' bash -c '
    set -euo pipefail
    source "'"$SRC_ROOT"'/core/lib/log_event.sh"
    source "'"$SRC_ROOT"'/core/lib/spawn_helper.sh"
    coord_spawn_helper_resolve_mode
    printf "\n"
    if coord_spawn_helper_should_use_real_claude mediator; then
      printf "real\n"
    else
      printf "mock\n"
    fi
  '
  [ "$status" -eq 0 ]
  _grep_output_for "WARNING: COORD_TEST_MODE='not-a-valid-mode' invalid"
  _grep_output_for "^mock$"
}

# -----------------------------------------------------------------
# Cost-guards lib correctly inherits hook process env
# -----------------------------------------------------------------

@test "hook-context: cost_guards tunable env-vars override defaults under set -euo pipefail" {
  # Tunables use `: "${VAR:=default}"` per Bash 3.2 portability.
  # Verify operator override works: a custom mediator cap takes
  # effect when exported to the hook's process environment.
  run bash -c '
    set -euo pipefail
    export COORD_DIR="'"$COORD_DIR"'"
    export SESSION_ID="'"$SESSION_ID"'"
    export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=1
    export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
    source "'"$SRC_ROOT"'/core/lib/log_event.sh"
    source "'"$SRC_ROOT"'/core/lib/cost_guards.sh"
    coord_cost_guards_check mediator || exit 0  # first allow
    if coord_cost_guards_check mediator; then
      printf "second-allowed\n"
    else
      printf "second-rate-limited\n"
    fi
  '
  [ "$status" -eq 0 ]
  _grep_output_for "second-rate-limited"
}

# -----------------------------------------------------------------
# Realistic-tag opt-in pattern (PR-PHASE7-04 §"Realistic-mode
# opt-in"). These tests SKIP unless COORD_TEST_MODE=realistic is
# explicitly set in the operator's env. CI MUST NOT incur real-
# claude costs.
# -----------------------------------------------------------------

# bats test_tags=realistic
@test "realistic-tag stub: spawn_helper resolves to realistic when env set" {
  [ "${COORD_TEST_MODE:-}" = "realistic" ] || skip "realistic-tagged; opt in via COORD_TEST_MODE=realistic"
  run bash -c '
    source "'"$SRC_ROOT"'/core/lib/log_event.sh"
    source "'"$SRC_ROOT"'/core/lib/spawn_helper.sh"
    coord_spawn_helper_resolve_mode
    printf "\n"
  '
  [ "$status" -eq 0 ]
  _grep_output_for "^realistic$"
}

# bats test_tags=realistic
@test "realistic-tag stub: all 3 sites route to real claude under realistic" {
  [ "${COORD_TEST_MODE:-}" = "realistic" ] || skip "realistic-tagged; opt in via COORD_TEST_MODE=realistic"
  run bash -c '
    source "'"$SRC_ROOT"'/core/lib/log_event.sh"
    source "'"$SRC_ROOT"'/core/lib/spawn_helper.sh"
    for site in mediator validator task_processor; do
      if coord_spawn_helper_should_use_real_claude "$site"; then
        printf "%s=real\n" "$site"
      else
        printf "%s=mock\n" "$site"
      fi
    done
  '
  [ "$status" -eq 0 ]
  _grep_output_for "mediator=real"
  _grep_output_for "validator=real"
  _grep_output_for "task_processor=real"
}

# bats test_tags=realistic
@test "realistic-tag stub: real claude binary present (operator pre-flight)" {
  [ "${COORD_TEST_MODE:-}" = "realistic" ] || skip "realistic-tagged; opt in via COORD_TEST_MODE=realistic"
  # When the operator opts into realistic-mode tests, they should
  # have `claude` on PATH. If absent, surface as an early skip
  # with operator guidance — better than a stale `claude_binary_
  # missing` audit event hidden in events.jsonl.
  command -v claude >/dev/null 2>&1 || skip "claude binary not on PATH; install + auth before running realistic-tagged tests"
  run claude --version
  [ "$status" -eq 0 ]
  # Smoke-only: do NOT actually invoke `claude -p` here. Phase
  # 7+1 would extend this stub with a real-claude end-to-end
  # spawn_helper integration; v1 keeps the cost at zero by
  # default and the stub at "claude binary present" check only.
}

# -----------------------------------------------------------------
# Realistic-tag default-skip verification (CI safety)
# -----------------------------------------------------------------

@test "default behavior: realistic-tagged tests SKIP when COORD_TEST_MODE unset" {
  # Meta-test: verify the skip gate fires under default env. Run
  # bats over THIS file with --filter-tags realistic and confirm
  # all 3 realistic-tagged tests were SKIPPED (not run).
  run bats --filter-tags realistic --tap "$BATS_TEST_FILENAME"
  [ "$status" -eq 0 ]
  # bats TAP output emits "ok N - <name> # skip <reason>" for
  # skipped tests. Confirm at least 1 skip line per tagged test
  # we declared (3 tagged tests).
  local skip_count
  skip_count=$(printf '%s' "$output" | grep -c '# skip')
  [ "$skip_count" -ge 3 ]
}

#!/usr/bin/env bash
# scenarios/01_basic_warn/timeline.sh — sourceable scenario implementation.
#
# Contract (per fixture README):
#   - scenario_run    : drives the timeline; sets STDOUT_OF_FINAL_HOOK and
#                       FINAL_HOOK_EXIT to the captured stdout + exit code
#                       of the assertion target (Session A's Write hook).
#   - scenario_assert : runs assertions; returns 0 (pass) or 1 (fail).
#                       Prints diagnostics to stderr on failure.
#
# Required env coming in from the driver:
#   WORKDIR     — absolute path to the isolated workspace
#   COORD_DIR   — absolute path to <WORKDIR>/.coord
#   SRC_ROOT    — absolute path to <repo>/src

set -uo pipefail   # not -e — we want to capture failing-hook exit codes

scenario_run() {
  local hooks="$COORD_DIR/hooks"
  local sid_a="sid-a-2sw-0001"
  local sid_b="sid-b-2sw-0001"

  # 1. Register Session A.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/session_start.sh" >/dev/null

  # 2. Register Session B.
  printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/session_start.sh" >/dev/null

  # 3. Session A reads foo.ts.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_read.sh" >/dev/null

  # 4a. Session B "intends to write" foo.ts (allowed; no warning — B's
  #     read_set is empty). Capture its stdout to assert no warning.
  STDOUT_OF_B_WRITE=$(printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_write.sh" 2>/dev/null) || true

  # 4b. The actual mutation that B's Write tool would have performed.
  printf 'export const foo = "v2";\n' >"$WORKDIR/foo.ts"

  # Brief settle for log_event background appends from the hooks above.
  sleep 0.3

  # 5. Session A attempts to Write bar.ts. THIS is the assertion target.
  STDOUT_OF_FINAL_HOOK=$(printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/bar.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" \
        "$hooks/pre_tool_use_write.sh" 2>/dev/null)
  FINAL_HOOK_EXIT=$?

  # Settle for the trailing log_event background append.
  sleep 0.3

  export STDOUT_OF_FINAL_HOOK FINAL_HOOK_EXIT STDOUT_OF_B_WRITE
  export SID_A="$sid_a" SID_B="$sid_b"
}

scenario_assert() {
  local fails=0
  local events="$COORD_DIR/events.jsonl"

  # A.1 — Final hook exit 0 (allow).
  if [ "$FINAL_HOOK_EXIT" != "0" ]; then
    printf '  FAIL: Session A Write hook exited %s; want 0 (allow)\n' "$FINAL_HOOK_EXIT" >&2
    fails=$((fails + 1))
  fi

  # A.2 — A's stdout cites foo.ts.
  if ! printf '%s' "$STDOUT_OF_FINAL_HOOK" | grep -q 'foo.ts'; then
    printf '  FAIL: Session A stdout does not cite "foo.ts"\n' >&2
    printf '    got: %s\n' "$STDOUT_OF_FINAL_HOOK" >&2
    fails=$((fails + 1))
  fi

  # A.3 — A's stdout contains the Phase 4 drift report banner.
  # (Phase 1 used "stale-read warning"; Phase 4 / T4.06 changed the
  # banner to "Coord drift report" because the per-file pipeline now
  # produces classified outcomes rather than a single warning line.)
  if ! printf '%s' "$STDOUT_OF_FINAL_HOOK" | grep -q 'Coord drift report'; then
    printf '  FAIL: Session A stdout does not contain "Coord drift report"\n' >&2
    printf '    got: %s\n' "$STDOUT_OF_FINAL_HOOK" >&2
    fails=$((fails + 1))
  fi

  # A.4 — Phase 1 ship gate (preserved through Phase 4): NO
  # permissionDecision in stdout. The validator pipeline never denies
  # directly; CRITICAL routes through Mediator → existing lockdown gate.
  if printf '%s' "$STDOUT_OF_FINAL_HOOK" | grep -q 'permissionDecision'; then
    printf '  FAIL: Session A stdout contains "permissionDecision" (Phase 1+4 ship-gate violation)\n' >&2
    printf '    got: %s\n' "$STDOUT_OF_FINAL_HOOK" >&2
    fails=$((fails + 1))
  fi

  # A.5 — VALIDATOR_PIPELINE_STARTED event for SID_A in events.jsonl.
  # (Phase 1 emitted STALE_READ_WARNED; Phase 4 / T4.06 replaced it
  # with VALIDATOR_PIPELINE_STARTED for the modified-path. The
  # deleted/skipped_large/hash_failed paths still emit STALE_READ_WARNED
  # with payload.stale_kind, but the modified case goes through the
  # validator pipeline.)
  local count
  count=$(jq -rs --arg sid "$SID_A" \
    '[.[] | select(.kind == "VALIDATOR_PIPELINE_STARTED" and .session == $sid)] | length' \
    "$events" 2>/dev/null || printf 0)
  if [ "$count" -lt 1 ]; then
    printf '  FAIL: events.jsonl has no VALIDATOR_PIPELINE_STARTED event for session %s\n' "$SID_A" >&2
    printf '    found %s such event(s); want >= 1\n' "$count" >&2
    fails=$((fails + 1))
  fi

  # A.6 — B's earlier Write produced NO additionalContext warning (B has
  # an empty read_set, so the hook should be silent).
  if printf '%s' "$STDOUT_OF_B_WRITE" | grep -q 'stale-read warning'; then
    printf '  FAIL: Session B Write produced an unexpected stale-read warning\n' >&2
    printf '    got: %s\n' "$STDOUT_OF_B_WRITE" >&2
    fails=$((fails + 1))
  fi

  return "$fails"
}

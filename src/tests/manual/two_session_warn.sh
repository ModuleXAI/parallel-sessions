#!/usr/bin/env bash
# two_session_warn.sh — driver for the two_session_warn fixture.
#
# Runs each scenario under src/tests/fixtures/two_session_warn/scenarios/
# and asserts the Phase 1 ship-gate done-when criterion #1.
#
# Usage:
#   two_session_warn.sh [--mode=<hook-sim|real>] [--scenario=<name>] [--keep]
#
# Modes:
#   --mode=hook-sim    (default) drives via direct hook invocations; no
#                       API key required; deterministic; CI-quality.
#   --mode=real        Phase-7 path: spawns actual `claude -p` sessions
#                       per scenario description. STUBBED in Phase 1 —
#                       exits 77 (skip) on invocation.
#
# Scenario filter:
#   --scenario=<name>  run only one scenario (e.g. 01_basic_warn).
#                       Default: run every directory under scenarios/.
#
# Keep-workdir flag:
#   --keep             do NOT remove the temporary workdir on exit; print
#                       its path so a developer can poke around.
#
# Exit codes:
#   0  all scenarios PASS
#   1  >= 1 scenario FAILED (with diagnostics on stderr)
#   2  driver usage / setup error
#  77  scenarios skipped (real mode without ANTHROPIC_API_KEY, etc.)

set -uo pipefail

MODE=hook-sim
SCENARIO_FILTER=""
KEEP_WORKDIR=0

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode=*)     MODE="${1#--mode=}"; shift ;;
    --scenario=*) SCENARIO_FILTER="${1#--scenario=}"; shift ;;
    --keep)       KEEP_WORKDIR=1; shift ;;
    --help|-h)    usage; exit 0 ;;
    *) printf 'two_session_warn.sh: unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  hook-sim) : ;;
  real)
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      printf 'SKIP: --mode=real requires ANTHROPIC_API_KEY\n' >&2
      exit 77
    fi
    printf 'SKIP: --mode=real path is stubbed in Phase 1; Phase 7 will implement.\n' >&2
    exit 77
    ;;
  *) printf 'two_session_warn.sh: bad --mode: %s (want hook-sim|real)\n' "$MODE" >&2; exit 2 ;;
esac

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$DRIVER_DIR/../.." && pwd)"   # src/tests/manual → src/
FIXTURE_DIR="$SRC_ROOT/tests/fixtures/two_session_warn"
SCEN_DIR="$FIXTURE_DIR/scenarios"

if [ ! -d "$SCEN_DIR" ]; then
  printf 'two_session_warn.sh: scenarios dir missing: %s\n' "$SCEN_DIR" >&2
  exit 2
fi

# Discover scenarios in lex order.
discover_scenarios() {
  local dir
  for dir in "$SCEN_DIR"/*/; do
    [ -d "$dir" ] || continue
    local name
    name=$(basename "$dir")
    if [ -n "$SCENARIO_FILTER" ] && [ "$name" != "$SCENARIO_FILTER" ]; then
      continue
    fi
    printf '%s\n' "$dir"
  done
}

# Load the fixture init helpers.
# shellcheck disable=SC1091
. "$FIXTURE_DIR/init.sh"

PASS_COUNT=0
FAIL_COUNT=0

for scenario_dir in $(discover_scenarios); do
  scenario_name=$(basename "$scenario_dir")
  printf '── scenario: %s\n' "$scenario_name"

  # Fresh workspace per scenario (isolation between scenarios).
  coord_fixture_init
  export SRC_ROOT WORKDIR COORD_DIR

  # Source the scenario's timeline (must define scenario_run + scenario_assert).
  STDOUT_OF_FINAL_HOOK=""
  FINAL_HOOK_EXIT=0
  STDOUT_OF_B_WRITE=""
  SID_A=""
  SID_B=""

  # shellcheck disable=SC1091
  if ! . "$scenario_dir/timeline.sh"; then
    printf '  ERROR: failed to source %s/timeline.sh\n' "$scenario_dir" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$KEEP_WORKDIR" = "0" ] && rm -rf "$WORKDIR"
    continue
  fi
  if ! command -v scenario_run >/dev/null 2>&1; then
    printf '  ERROR: scenario %s did not define scenario_run\n' "$scenario_name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$KEEP_WORKDIR" = "0" ] && rm -rf "$WORKDIR"
    continue
  fi
  if ! command -v scenario_assert >/dev/null 2>&1; then
    printf '  ERROR: scenario %s did not define scenario_assert\n' "$scenario_name" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    [ "$KEEP_WORKDIR" = "0" ] && rm -rf "$WORKDIR"
    continue
  fi

  # Run + assert.
  scenario_run

  if scenario_assert; then
    printf '  PASS\n'
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '  FAIL  (workdir: %s)\n' "$WORKDIR"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  if [ "$KEEP_WORKDIR" = "0" ]; then
    rm -rf "$WORKDIR"
  else
    printf '  workdir kept at: %s\n' "$WORKDIR"
  fi

  # Unset scenario functions so the next iteration's source can redefine cleanly.
  unset -f scenario_run scenario_assert 2>/dev/null || true
done

printf '\n'
printf '== two_session_warn: %s pass, %s fail (mode=%s)\n' "$PASS_COUNT" "$FAIL_COUNT" "$MODE"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
if [ "$PASS_COUNT" = "0" ]; then
  printf 'no scenarios matched (filter=%s)\n' "$SCENARIO_FILTER" >&2
  exit 2
fi
exit 0

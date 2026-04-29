#!/usr/bin/env bash
# phase7_ship_gate.sh — driver for the Phase 7 ship-gate fixtures.
#
# Runs each scenario under
# src/tests/fixtures/phase7_ship_gate/scenarios/ and asserts the
# Phase 7 plan §7 revised Done-when criteria (post-OQ6 descope):
#   1. Three-mode COORD_TEST_MODE switch functional
#   2. Cost guard tunables enforced under semi + realistic
#   3. F-016 dispositioned (RESOLVED-with-fix per T7.06a)
#   4. F-019 RESOLVED (linux_probe.sh relocated)
#   5. Stress harness operational (covered by T7.08 smoke run)
#
# Usage:
#   phase7_ship_gate.sh [--mode=<hook-sim|real>] [--scenario=<name>] [--keep]
#
# Modes:
#   --mode=hook-sim   (default) drives via fixture init.sh + mock
#                     binary. Phase 7 mode-routing verified at
#                     spawn_helper layer; underlying claude calls
#                     hit PATH-injected fake. Deterministic.
#   --mode=real       Phase 7+1 — exits 77 (skip).
#
# Scenario filter:
#   --scenario=<name>  run only one scenario directory name.
#
# Keep-workdir:
#   --keep             do not rm -rf $WORKDIR after each scenario.
#
# Exit codes:
#   0  all scenarios PASS
#   1  >= 1 scenario FAILED
#   2  driver usage / setup error
#  77  scenarios skipped (real mode)

set -uo pipefail

DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$DRIVER_DIR/../.." && pwd)"
FIXTURE_ROOT="$SRC_ROOT/tests/fixtures/phase7_ship_gate"
SCENARIOS_ROOT="$FIXTURE_ROOT/scenarios"

MODE="hook-sim"
SCENARIO_FILTER=""
KEEP_WORKDIR="0"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode=*)     MODE="${1#--mode=}"; shift ;;
    --scenario=*) SCENARIO_FILTER="${1#--scenario=}"; shift ;;
    --keep)       KEEP_WORKDIR="1"; shift ;;
    -h|--help)
      sed -n '/^# /,/^$/p' "$0" | head -30
      exit 0
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ "$MODE" = "real" ]; then
  printf 'phase7_ship_gate: real-mode deferred to Phase 7+1 stress harness\n'
  exit 77
fi

if [ "$MODE" != "hook-sim" ]; then
  printf 'unknown mode: %s\n' "$MODE" >&2
  exit 2
fi

if [ ! -d "$SCENARIOS_ROOT" ]; then
  printf 'scenarios directory missing: %s\n' "$SCENARIOS_ROOT" >&2
  exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

printf '== phase7_ship_gate driver — mode=%s ==\n\n' "$MODE"

for scenario_dir in $(ls -1d "$SCENARIOS_ROOT"/*/ 2>/dev/null | sort); do
  scenario_name="$(basename "$scenario_dir")"
  if [ -n "$SCENARIO_FILTER" ] && [ "$scenario_name" != "$SCENARIO_FILTER" ]; then
    continue
  fi
  printf '## %s\n' "$scenario_name"

  # shellcheck disable=SC1091
  . "$FIXTURE_ROOT/init.sh"
  if ! coord_fixture_init; then
    printf '  ERROR: coord_fixture_init failed\n' >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

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

  scenario_run

  if scenario_assert; then
    printf '  PASS\n'
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf '  FAIL  (workdir: %s)\n' "$WORKDIR"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  if [ "$KEEP_WORKDIR" = "0" ]; then
    sleep 0.2
    rm -rf "$WORKDIR" 2>/dev/null || { sleep 0.3; rm -rf "$WORKDIR" 2>/dev/null || true; }
  else
    printf '  workdir kept at: %s\n' "$WORKDIR"
  fi

  unset -f scenario_run scenario_assert 2>/dev/null || true
done

printf '\n'
printf '== phase7_ship_gate: %s pass, %s fail (mode=%s)\n' "$PASS_COUNT" "$FAIL_COUNT" "$MODE"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
if [ "$PASS_COUNT" = "0" ]; then
  printf 'no scenarios matched (filter=%s)\n' "$SCENARIO_FILTER" >&2
  exit 2
fi
exit 0

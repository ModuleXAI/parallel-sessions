#!/usr/bin/env bash
# 05_linux_probe_relocation_verified — Plan §7 revised Done-when
# #4 (F-019 RESOLVED evidence): "F-019 RESOLVED — linux_probe.sh
# relocated to src/tests/manual/, tracked in git, Linux Docker
# probe clean post-relocation."
#
# Verifies the T7.07 relocation integrity (Linux Docker runtime
# verification deferred to T7.12 per T7.07 disposition):
#   a. linux_probe.sh exists at the new path src/tests/manual/
#   b. Old gitignored copy at .coord/experiments/linux-parity/ is
#      gone from working tree
#   c. Bash 3.2 syntax PASS on relocated file
#   d. All 5 phase ship-gate invocation blocks present
#   e. Git tracks the new path (relocated file is committed)
set -uo pipefail

scenario_run() {
  NEW_PATH="$SRC_ROOT/tests/manual/linux_probe.sh"
  OLD_PATH="$SRC_ROOT/../.coord/experiments/linux-parity/linux_probe.sh"
  export NEW_PATH OLD_PATH

  EXISTS_NEW=0
  if [ -f "$NEW_PATH" ]; then EXISTS_NEW=1; fi
  export EXISTS_NEW

  EXISTS_OLD=0
  if [ -f "$OLD_PATH" ]; then EXISTS_OLD=1; fi
  export EXISTS_OLD

  # Bash 3.2 syntax check.
  SYNTAX_RC=0
  /bin/bash -n "$NEW_PATH" 2>/dev/null || SYNTAX_RC=$?
  export SYNTAX_RC

  # Count phase ship-gate invocation blocks. Expected:
  # two_session_warn + phase{3,4,5,6}_ship_gate = 5.
  SHIP_GATE_BLOCKS=$(grep -cE 'phase[3-6]_ship_gate\.sh|two_session_warn\.sh' "$NEW_PATH" 2>/dev/null || printf 0)
  export SHIP_GATE_BLOCKS

  # Git tracks the new path. Use git ls-files relative to repo
  # root.
  REPO_ROOT="$(cd "$SRC_ROOT/.." && pwd)"
  GIT_TRACKED=0
  if (cd "$REPO_ROOT" && git ls-files src/tests/manual/linux_probe.sh 2>/dev/null | grep -q 'linux_probe.sh'); then
    GIT_TRACKED=1
  fi
  export GIT_TRACKED REPO_ROOT
}

scenario_assert() {
  local fail=0

  # 1. New path exists.
  if [ "$EXISTS_NEW" -ne 1 ]; then
    printf '  FAIL 1: linux_probe.sh missing at relocated path %s\n' "$NEW_PATH" >&2
    fail=1
  fi

  # 2. Old gitignored path is gone (T7.07 deleted it from
  #    working tree).
  if [ "$EXISTS_OLD" -ne 0 ]; then
    printf '  FAIL 2: old gitignored linux_probe.sh still present at %s\n' "$OLD_PATH" >&2
    fail=1
  fi

  # 3. Bash 3.2 syntax PASS.
  if [ "$SYNTAX_RC" -ne 0 ]; then
    printf '  FAIL 3: bash 3.2 syntax check failed (rc=%s)\n' "$SYNTAX_RC" >&2
    fail=1
  fi

  # 4. All 5 phase ship-gate invocation blocks present.
  if [ "$SHIP_GATE_BLOCKS" -lt 5 ]; then
    printf '  FAIL 4: expected 5 ship-gate invocation blocks, got %s\n' "$SHIP_GATE_BLOCKS" >&2
    fail=1
  fi

  # 5. Git tracks the new path (relocation persists across fresh
  #    checkouts — F-019 root cause fix).
  if [ "$GIT_TRACKED" -ne 1 ]; then
    printf '  FAIL 5: git does not track src/tests/manual/linux_probe.sh; F-019 not yet fixed via commit\n' >&2
    fail=1
  fi

  return "$fail"
}

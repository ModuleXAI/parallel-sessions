#!/usr/bin/env bash
# participant.sh — O(1) check whether the current session is a coord
# participant, via `.coord/sessions/<session_id>.active` marker file.
#
# Contract (plan §4):
#   coord_is_participant <session_id>
#     exit 0 if the marker exists; exit 1 otherwise.
#
# Environment:
#   COORD_DIR — required. The coord root (usually <repo>/.coord).

set -euo pipefail

coord_is_participant() {
  local session_id="${1:-}"
  local coord_dir="${COORD_DIR:-}"
  if [ -z "$session_id" ] || [ -z "$coord_dir" ]; then
    return 1
  fi
  [ -e "$coord_dir/sessions/${session_id}.active" ]
}

# CLI shim for bats: participant.sh <session_id>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if coord_is_participant "${1:-}"; then exit 0; else exit 1; fi
fi

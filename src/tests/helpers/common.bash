# common.bash — bats test helpers for the coord suite.
# Sourced via `load "../helpers/common"` in each .bats file.
#
# Sets:
#   SRC_ROOT  — absolute path to src/ directory (parent of lib/, hooks/, bin/).
#   REPO_ROOT — absolute path to the git repo root.

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$SRC_ROOT/.." && pwd)"

# mk_coord_dir <base>
#   Create a minimal `.coord/` layout at $base/.coord and print the path.
mk_coord_dir() {
  local base="$1"
  mkdir -p "$base/.coord" \
           "$base/.coord/sessions" \
           "$base/.coord/validation" \
           "$base/.coord/mediator" \
           "$base/.coord/mediator/verdict" \
           "$base/.coord/hooks" \
           "$base/.coord/lib" \
           "$base/.coord/bin"
  printf '%s/.coord\n' "$base"
}

# _grep_output_for <pattern>
#   Apostrophe-safe replacement for the legacy
#   `run bash -c "echo '$output' | grep -c '<pattern>' || true"` scaffold.
#   Returns 0 if bats's `$output` contains <pattern>, 1 otherwise.
#   Pipes $output via printf — no `bash -c`, no inner single-quoted shell
#   fragments — so an ASCII apostrophe in either $output or <pattern> cannot
#   terminate string scaffolding mid-flight (F-014 root fix).
#
#   Usage:
#     _grep_output_for "stale-read warning"           # positive
#     ! _grep_output_for "permissionDecision"         # negative
#
#   Note: leaves bats's `$output` and `$status` (set by the most recent `run`)
#   untouched, unlike the legacy pattern which rebinds them to grep's stdout.
_grep_output_for() {
  local pattern="$1"
  printf '%s' "$output" | grep -q -- "$pattern"
}

# mk_empty_sessions <.coord_dir>
#   Write an empty valid sessions.json to the given .coord directory.
mk_empty_sessions() {
  local coord="$1"
  printf '%s' '{
    "schema_version": "1.0",
    "sessions": {},
    "locks": {},
    "wait_queue": {},
    "read_sets": {},
    "notifications": {},
    "self_tasks": {},
    "anomaly_votes": {},
    "task_graph": {}
  }' >"$coord/sessions.json"
  touch "$coord/sessions.lock" "$coord/events.lock" "$coord/history.lock"
}

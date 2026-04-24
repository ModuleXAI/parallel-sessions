#!/usr/bin/env bash
# state_query.sh — read-only helpers over sessions.json.
#
# Contract (plan §4):
#   These functions answer "is file X locked?", "what notifications exist
#   for session Y?", etc., without taking flock. Reads are safe because
#   sessions.json is only ever replaced via atomic rename (§4 + Decision
#   2.3), so a reader never observes a half-written object.
#
# Environment:
#   COORD_DIR  — required; `<COORD_DIR>/sessions.json` is consulted.

set -euo pipefail

_state_file() {
  printf '%s/sessions.json\n' "${COORD_DIR:?COORD_DIR not set}"
}

# Print the raw state JSON (or the empty template if the file is missing).
coord_state_dump() {
  local f
  f=$(_state_file)
  if [ -f "$f" ]; then
    cat "$f"
  else
    jq -n '{
      schema_version: "1.0",
      sessions: {}, locks: {}, wait_queue: {}, read_sets: {},
      notifications: {}, self_tasks: {}, anomaly_votes: {}, task_graph: {}
    }'
  fi
}

# Print the active lock-holder session_id for <file>, or empty if unlocked.
coord_lock_holder() {
  local file="$1"
  coord_state_dump | jq -r --arg f "$file" '.locks[$f].session // empty'
}

# Print 0|1: is <file> locked by ANYONE?
coord_is_locked() {
  local file="$1"
  local h
  h=$(coord_lock_holder "$file")
  if [ -n "$h" ]; then printf '1\n'; else printf '0\n'; fi
}

# Print notifications for <session_id> as JSON array (empty array if none).
coord_notifications_for() {
  local sid="$1"
  coord_state_dump | jq -c --arg s "$sid" '.notifications[$s] // []'
}

# Print active (not-closed) session_ids, one per line.
coord_active_sessions() {
  coord_state_dump | jq -r '
    .sessions
    | to_entries[]
    | select(.value.state == "ACTIVE" or .value.state == "IDLE_ALIVE")
    | .key
  '
}

# Print all locks as lines: "<file>\t<session_id>\t<acquired_at>".
coord_locks() {
  coord_state_dump | jq -r '
    .locks | to_entries[]
    | [.key, .value.session, .value.acquired_at] | @tsv
  '
}

# Print self-tasks for <session_id> as JSON array.
coord_self_tasks_for() {
  local sid="$1"
  coord_state_dump | jq -c --arg s "$sid" '.self_tasks[$s] // []'
}

# CLI shim: state_query.sh <subcommand> [args...]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    dump)              coord_state_dump ;;
    lock-holder)       shift; coord_lock_holder "$@" ;;
    is-locked)         shift; coord_is_locked "$@" ;;
    notifications-for) shift; coord_notifications_for "$@" ;;
    active-sessions)   coord_active_sessions ;;
    locks)             coord_locks ;;
    self-tasks-for)    shift; coord_self_tasks_for "$@" ;;
    *)
      printf 'usage: state_query.sh {dump|lock-holder|is-locked|notifications-for|active-sessions|locks|self-tasks-for} [...]\n' >&2
      exit 2 ;;
  esac
fi

#!/usr/bin/env bash
# atomic_write.sh — the coordinator's single-source-of-truth mutator.
#
# Contract (plan §4 + Decision 2.3):
#   coord_atomic_edit <state_file> <jq_filter> [<jq_arg> ...]
#     1. flock -x on the sentinel file (<state_file>.lock) with -w 5 s.
#     2. Read current state; if missing or unparseable, reset to empty
#        template and flag Mediator (§B.9.1/§B.9.2).
#     3. Apply `jq <jq_filter>` (any extra args forwarded to jq, e.g.
#        `--arg`, `--argjson`).
#     4. Write to <state_file>.tmp.<pid> and `mv` over the target
#        (atomic rename on POSIX local fs — plan §4).
#     5. Release flock.
#
#   Exit codes (plan §4):
#     0  success
#    42  flock timeout (>5 s)              — caller decides fail-open/closed
#    43  jq non-zero during filter         — caller must escalate
#    44  write failure (temp + rename)     — caller must escalate
#
# Callers MUST NOT write sessions.json any other way.
# See FINDINGS F-003: the subshell + redirected-fd flock form is the
# portable contract; do not use `flock ... --`.
#
# Also provides:
#   coord_atomic_reset <state_file>        — reset to empty valid template,
#                                            archive old content if non-empty.
#   coord_state_empty_template             — prints the empty state JSON.

set -euo pipefail

coord_state_empty_template() {
  # Emitted via jq to guarantee a canonical JSON object.
  jq -n '{
    schema_version: "1.0",
    sessions: {},
    locks: {},
    wait_queue: {},
    read_sets: {},
    notifications: {},
    self_tasks: {},
    anomaly_votes: {},
    task_graph: {}
  }'
}

coord_atomic_edit() {
  local state_file="$1"; shift
  local jq_filter="$1"; shift
  # Remaining positional args passed to jq (--arg/--argjson pairs).

  local lock_file="${state_file}.lock"
  local dir
  dir=$(dirname "$state_file")
  mkdir -p "$dir"
  if [ ! -e "$lock_file" ]; then
    : >"$lock_file"
  fi

  local rc=0
  # Subshell + redirected fd per F-003.
  (
    if ! flock -x -w 5 9; then
      exit 42
    fi

    local cur
    if [ -f "$state_file" ]; then
      cur=$(cat "$state_file" 2>/dev/null || printf '')
    else
      cur=""
    fi

    # Validate parse. Corrupt → archive + reset (fail-open per §B.9.2).
    if [ -z "$cur" ] || ! printf '%s' "$cur" | jq -e . >/dev/null 2>&1; then
      local ts
      ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
      if [ -n "$cur" ] && [ -f "$state_file" ]; then
        cp "$state_file" "${state_file}.corrupt.$ts.json" 2>/dev/null || true
      fi
      cur=$(coord_state_empty_template)
      # Write the reset state as the base before the filter runs.
      : >"${state_file}.tmp.$$"
      printf '%s' "$cur" >"${state_file}.tmp.$$"
      if ! mv "${state_file}.tmp.$$" "$state_file"; then
        rm -f "${state_file}.tmp.$$"
        exit 44
      fi
      # Set a Mediator pending flag so downstream hooks surface the reset.
      if [ -n "${COORD_DIR:-}" ] && [ -d "$COORD_DIR/mediator" ]; then
        jq -n --arg ts "$ts" --arg file "$state_file" \
          '{kind:"corrupt_state", ts:$ts, file:$file}' \
          >"$COORD_DIR/mediator/pending.json" 2>/dev/null || true
      fi
    fi

    local new
    if ! new=$(printf '%s' "$cur" | jq "$@" "$jq_filter" 2>/dev/null); then
      exit 43
    fi
    if [ -z "$new" ]; then
      exit 43
    fi

    # Atomic write: temp then rename. mktemp in same dir for rename-atomicity.
    local tmp
    tmp="${state_file}.tmp.$$"
    printf '%s\n' "$new" >"$tmp" || { rm -f "$tmp"; exit 44; }
    if ! mv "$tmp" "$state_file"; then
      rm -f "$tmp"
      exit 44
    fi
  ) 9>"$lock_file" || rc=$?

  return "$rc"
}

coord_atomic_reset() {
  local state_file="$1"
  local lock_file="${state_file}.lock"
  mkdir -p "$(dirname "$state_file")"
  : >"$lock_file"
  (
    if ! flock -x -w 5 9; then exit 42; fi
    local ts
    ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    if [ -s "$state_file" ]; then
      cp "$state_file" "${state_file}.reset.$ts.json" 2>/dev/null || true
    fi
    coord_state_empty_template >"${state_file}.tmp.$$"
    mv "${state_file}.tmp.$$" "$state_file" || { rm -f "${state_file}.tmp.$$"; exit 44; }
  ) 9>"$lock_file"
}

# coord_consume_corrupt_state_flag
#   Implements §B.9.2 step 4: if a corrupt_state Mediator-pending flag is
#   present at $COORD_DIR/mediator/pending.json AND has not yet been
#   delivered (no .delivered.* counterpart), print the user-facing banner
#   text on stdout AND rename the flag to pending.delivered.<ts>.json so
#   the same banner is not emitted twice.
#
#   Returns 0 if a banner was emitted (caller should compose into
#   additionalContext); 1 if no flag was found / not corrupt_state.
#
#   This function does NOT format the JSON envelope — it just prints the
#   banner text. Callers wrap it with their own jq -nc shape.
coord_consume_corrupt_state_flag() {
  local pending="${COORD_DIR:-}/mediator/pending.json"
  [ -f "$pending" ] || return 1
  local kind
  kind=$(jq -r '.kind // ""' "$pending" 2>/dev/null || printf '')
  if [ "$kind" != "corrupt_state" ]; then
    return 1
  fi
  printf 'Coord: coordination state was reset due to corruption. Mediator will diagnose; prior locks are lost. Retry your operation.'
  local ts
  ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  mv "$pending" "${COORD_DIR}/mediator/pending.delivered.${ts}.json" 2>/dev/null || rm -f "$pending" 2>/dev/null || true
  return 0
}

# CLI shim for tests and ad-hoc use:
#   atomic_write.sh edit  <state_file> <jq_filter> [<jq_args> ...]
#   atomic_write.sh reset <state_file>
#   atomic_write.sh template          (prints empty template)
#   atomic_write.sh consume-corrupt-banner  (prints + clears pending flag)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    edit)      shift; coord_atomic_edit "$@" ;;
    reset)     shift; coord_atomic_reset "$@" ;;
    template)  coord_state_empty_template ;;
    consume-corrupt-banner) coord_consume_corrupt_state_flag ;;
    *) printf 'usage: atomic_write.sh {edit|reset|template|consume-corrupt-banner} ...\n' >&2; exit 2 ;;
  esac
fi

#!/usr/bin/env bash
# verdict_apply.sh — Phase 3 / T3.07 verdict-action applier.
#
# Mediator emits a verdict JSON with an `actions` array (per
# PR-PHASE3-01 § verdict schema). The hook layer that consumes the
# verdict invokes this library to translate each action object into a
# concrete state mutation. All mutations go through Bash + atomic_write
# helpers (PR-PHASE3-01 disposition #2 P2: Mediator MUST NOT use
# Edit/Write/NotebookEdit; these helpers are how the hook layer
# applies on Mediator's behalf).
#
# Apply ordering rules (per PR-PHASE3-04 Note B / T3.07 user direction):
#   1. lockdown actions FIRST — so other sessions see the lockdown
#      immediately and don't race against subsequent state mutations.
#   2. release_lock for a session BEFORE evict_session for that same
#      session — otherwise we evict while holding state references.
#   3. clear_read_set is independent — can run anywhere in the order.
#
# The caller (hooks/pre_tool_use_any.sh verdict consumer) is
# responsible for sorting the actions array per the rules above before
# iterating. This library's individual functions are idempotent; if
# the caller runs them out of order, the result is correct but may
# emit extra warnings / log lines.
#
# Public functions:
#   coord_verdict_apply_release_lock <file> <session>
#       Release the lock at locks[$file] iff held by $session.
#   coord_verdict_apply_evict_session <session>
#       Remove sessions[$session] entirely; also delete any locks
#       still referencing it (defense in depth — caller should have
#       released them via release_lock first).
#   coord_verdict_apply_clear_read_set <session>
#       Clear read_sets[$session].reads = [] without removing the
#       session row itself.
#   coord_verdict_apply_action <action_json>
#       Dispatcher: parses the action object's `op` field and routes
#       to the appropriate helper. Returns 0 on apply-success, 1 on
#       unknown op or malformed action.
#   coord_verdict_apply_actions <actions_json>
#       Iterates an actions array (sorted by caller per ordering rules).
#       Each action is dispatched via coord_verdict_apply_action.
#       Returns 0 if all actions applied successfully; non-zero
#       count of failures otherwise.
#
# All helpers are idempotent + fail-open. Failure to apply emits a
# stderr warning + ERROR event log entry but does not propagate as a
# hook-level failure.

# Internal: warn helper.
_coord_verdict_warn() {
  printf 'coord verdict_apply: %s\n' "$*" >&2
}

# coord_verdict_apply_release_lock <file> <session>
#   Atomically release the lock at locks[$file] iff currently held by
#   $session. If held by another session OR not held, log INFO + skip.
#   Idempotent: running twice with the same input is a silent no-op
#   on the second call.
coord_verdict_apply_release_lock() {
  local file="$1"
  local session="$2"
  if [ -z "$file" ] || [ -z "$session" ]; then
    _coord_verdict_warn "release_lock: missing args (file=$file session=$session)"
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_verdict_warn "release_lock: COORD_DIR unset"
    return 1
  fi
  local state="$COORD_DIR/sessions.json"
  [ -f "$state" ] || return 0   # nothing to release
  # Confirm the lock IS held by the named session before deletion.
  local current_holder
  current_holder=$(jq -r --arg f "$file" '.locks[$f].session // ""' "$state" 2>/dev/null) \
    || current_holder=""
  if [ -z "$current_holder" ]; then
    return 0   # lock already absent — idempotent no-op
  fi
  if [ "$current_holder" != "$session" ]; then
    _coord_verdict_warn "release_lock: lock on $file held by $current_holder, not $session — skipping"
    return 0
  fi
  if ! coord_atomic_edit "$state" \
        'del(.locks[$f])' \
        --arg f "$file"; then
    _coord_verdict_warn "release_lock: atomic_edit failed for $file"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=ERROR source=verdict_apply op=release_lock \
        file="$file" session="$session" reason=atomic_edit_failed 2>/dev/null || true
    fi
    return 1
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=LOCK_RELEASED source=verdict_apply \
      file="$file" released_session="$session" 2>/dev/null || true
  fi
  return 0
}

# coord_verdict_apply_evict_session <session>
#   Remove sessions[$session] AND any locks still referencing it.
#   Used by Mediator's surgical_fix when a session is determined dead
#   (PID gone / lstart mismatch) and watchdog escalation confirmed.
coord_verdict_apply_evict_session() {
  local session="$1"
  if [ -z "$session" ]; then
    _coord_verdict_warn "evict_session: missing session arg"
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_verdict_warn "evict_session: COORD_DIR unset"
    return 1
  fi
  local state="$COORD_DIR/sessions.json"
  [ -f "$state" ] || return 0
  if ! coord_atomic_edit "$state" \
        'del(.sessions[$sid])
         | .locks |= with_entries(select(.value.session != $sid))
         | del(.read_sets[$sid])
         | del(.notifications[$sid])
         | del(.self_tasks[$sid])
        ' \
        --arg sid "$session"; then
    _coord_verdict_warn "evict_session: atomic_edit failed for $session"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=ERROR source=verdict_apply op=evict_session \
        session="$session" reason=atomic_edit_failed 2>/dev/null || true
    fi
    return 1
  fi
  # Best-effort: also remove the .active marker file.
  rm -f "$COORD_DIR/sessions/${session}.active" 2>/dev/null || true
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=SESSION_EVICTED source=verdict_apply \
      session="$session" 2>/dev/null || true
  fi
  return 0
}

# coord_verdict_apply_clear_read_set <session>
#   Clear read_sets[$session].reads to []. Leaves the read_set
#   container in place (so subsequent reads can populate). Used by
#   Mediator when a session's read-set is determined unsafe (e.g.,
#   after a HEAD-change drift the validator agent escalates).
coord_verdict_apply_clear_read_set() {
  local session="$1"
  if [ -z "$session" ]; then
    _coord_verdict_warn "clear_read_set: missing session arg"
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_verdict_warn "clear_read_set: COORD_DIR unset"
    return 1
  fi
  local state="$COORD_DIR/sessions.json"
  [ -f "$state" ] || return 0
  if ! coord_atomic_edit "$state" \
        '.read_sets[$sid].reads = []' \
        --arg sid "$session"; then
    _coord_verdict_warn "clear_read_set: atomic_edit failed for $session"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=ERROR source=verdict_apply op=clear_read_set \
        session="$session" reason=atomic_edit_failed 2>/dev/null || true
    fi
    return 1
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=READ_SET_CLEARED source=verdict_apply \
      session="$session" 2>/dev/null || true
  fi
  return 0
}

# coord_verdict_apply_action <action_json>
#   Dispatcher. Parses {"op": "...", ...} and routes.
coord_verdict_apply_action() {
  local action_json="$1"
  [ -z "$action_json" ] && return 1
  local op
  op=$(printf '%s' "$action_json" | jq -r '.op // ""' 2>/dev/null) || op=""
  case "$op" in
    release_lock)
      local file session
      file=$(printf '%s' "$action_json" | jq -r '.target // .file // ""')
      session=$(printf '%s' "$action_json" | jq -r '.session // ""')
      coord_verdict_apply_release_lock "$file" "$session"
      ;;
    evict_session)
      local session
      session=$(printf '%s' "$action_json" | jq -r '.session // ""')
      coord_verdict_apply_evict_session "$session"
      ;;
    clear_read_set)
      local session
      session=$(printf '%s' "$action_json" | jq -r '.session // ""')
      coord_verdict_apply_clear_read_set "$session"
      ;;
    "")
      _coord_verdict_warn "apply_action: missing op field"
      return 1
      ;;
    *)
      _coord_verdict_warn "apply_action: unknown op=$op"
      return 1
      ;;
  esac
}

# coord_verdict_apply_actions <actions_json>
#   Iterate the actions array (already sorted by caller per ordering
#   rules). Returns 0 if all succeed; non-zero failure count otherwise.
coord_verdict_apply_actions() {
  local actions_json="$1"
  [ -z "$actions_json" ] && return 0
  local count
  count=$(printf '%s' "$actions_json" | jq -r 'length' 2>/dev/null) || count=0
  case "$count" in *[!0-9]*|'') count=0 ;; esac
  [ "$count" -eq 0 ] && return 0
  local i=0 failures=0
  while [ "$i" -lt "$count" ]; do
    local action
    action=$(printf '%s' "$actions_json" | jq -c --argjson i "$i" '.[$i]' 2>/dev/null)
    if [ -n "$action" ] && [ "$action" != "null" ]; then
      coord_verdict_apply_action "$action" || failures=$((failures + 1))
    fi
    i=$((i + 1))
  done
  return "$failures"
}

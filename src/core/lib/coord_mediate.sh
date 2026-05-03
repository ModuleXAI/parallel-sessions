#!/usr/bin/env bash
# coord_mediate.sh — operator CLI for Mediator interaction
# (Phase 3 / T3.08 / PR-PHASE3-01 §F coord mediate component spec).
#
# Subcommands:
#   coord mediate --reason "<text>"
#       Manual escalation primitive. Writes a pending.jsonl entry with
#       kind=manual, source=user_invocation, payload.reason. The next
#       tool call's pre_tool_use_any.sh consumer will surface the
#       entry → Mediator spawn fires (or critical-bypass / lockdown
#       gate intercepts).
#
#   coord mediate --approve <verdict_path>
#       Operator selects one of the verdicts after a peer-review
#       disagreement escalation. Reads verdict, applies actions via
#       verdict_apply helpers, records MEDIATOR_USER_APPROVED event.
#       Optionally cleans up the rejected sibling verdict (the second
#       verdict file from the same peer-review pair).
#
#   coord mediate --escalate [--reason "<text>"]
#       Operator-initiated lockdown. Activates lockdown.json with
#       reason_source=user_escalation. User then resolves the issue
#       manually (via coord reset, direct file edits, etc.) and
#       eventually runs --resume to clear lockdown.
#
#   coord mediate --resume
#       Clears any active lockdown (regardless of reason_source).
#       No-op + warning if no lockdown active.
#
#   coord mediate status
#       Read-only operator visibility:
#         - Active lockdown (if any)
#         - Recent verdicts (last 10)
#         - Pending unresolved verdicts (peer-disagreement, awaiting
#           --approve)
#         - Last Mediator invocation timing + cost
#         - Recent watchdog probe verdicts
#       No state mutation.
#
# Bash 3.2 compat. Sourced by src/core/bin/coord.

# Tunables (env-overridable).
: "${COORD_MEDIATE_STATUS_VERDICT_LIMIT:=10}"
: "${COORD_MEDIATE_STATUS_WATCHDOG_LIMIT:=5}"

_coord_mediate_die() {
  printf 'coord mediate: %s\n' "$*" >&2
  exit 2
}

_coord_mediate_warn() {
  printf 'coord mediate: %s\n' "$*" >&2
}

_coord_mediate_usage() {
  cat <<'USAGE'
Usage: coord mediate <subcommand> [options]

Subcommands:
  --reason "<text>"          Write a manual pending entry; next tool
                             call triggers Mediator with this reason.
  --approve <verdict_path>   Apply the verdict at <verdict_path>;
                             record MEDIATOR_USER_APPROVED event.
  --escalate [--reason X]    Activate lockdown with
                             reason_source=user_escalation.
  --resume                   Clear any active lockdown.
  status                     Read-only summary of recent Mediator
                             activity, pending verdicts, lockdown
                             state, watchdog probes.
  --help                     Print this usage.
USAGE
}

# coord_mediate_reason <reason_text>
#   Manual escalation: write a pending.jsonl entry with kind=manual.
coord_mediate_reason() {
  local reason="$1"
  if [ -z "$reason" ]; then
    _coord_mediate_die "--reason requires a non-empty text argument"
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_mediate_die "COORD_DIR not set; run inside a coord-installed repo"
  fi
  if ! command -v coord_mediator_emit_pending >/dev/null 2>&1; then
    _coord_mediate_die "lib/mediator_pending.sh not sourced; cannot emit"
  fi
  coord_mediator_emit_pending manual \
    source=user_invocation \
    reason="$reason" \
    invoked_by="${USER:-unknown}" \
    || _coord_mediate_die "failed to write pending entry"
  printf 'coord mediate: pending entry written (kind=manual). Mediator will spawn on the next tool call.\n'
  return 0
}

# coord_mediate_approve <verdict_path>
#   Operator-approves a verdict; applies its actions; records event.
coord_mediate_approve() {
  local vfile="$1"
  if [ -z "$vfile" ]; then
    _coord_mediate_die "--approve requires a verdict file path"
  fi
  if [ ! -f "$vfile" ]; then
    _coord_mediate_die "verdict file not found: $vfile"
  fi
  if ! jq -e . "$vfile" >/dev/null 2>&1; then
    _coord_mediate_die "verdict file is not valid JSON: $vfile"
  fi
  local action_type confidence depth actions message_to_caller
  action_type=$(jq -r '.action_type // "?"' "$vfile")
  confidence=$(jq -r '.confidence // "?"' "$vfile")
  depth=$(jq -r '.depth // 1' "$vfile")
  actions=$(jq -c '.actions // []' "$vfile")
  message_to_caller=$(jq -r '.message_to_caller // ""' "$vfile")
  # Warn if this verdict's confidence wasn't needs_review — operator
  # is overriding what would have auto-applied, which is unusual but
  # allowed.
  if [ "$confidence" != "needs_review" ]; then
    _coord_mediate_warn "verdict at $vfile has confidence=$confidence (not needs_review); operator override of single-verdict apply is unusual but allowed"
  fi
  # Apply actions via the verdict_apply pipeline.
  if ! command -v coord_verdict_apply_actions >/dev/null 2>&1; then
    _coord_mediate_die "lib/verdict_apply.sh not sourced; cannot apply"
  fi
  if [ "$actions" != "null" ] && [ "$actions" != "[]" ]; then
    coord_verdict_apply_actions "$actions" || _coord_mediate_warn "some actions failed; check events.jsonl for ERROR entries"
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=MEDIATOR_USER_APPROVED \
      verdict_path="$vfile" \
      action_type="$action_type" \
      confidence="$confidence" \
      depth="$depth" \
      approved_by="${USER:-unknown}" 2>/dev/null || true
  fi
  printf 'coord mediate: verdict approved (action_type=%s).\n' "$action_type"
  if [ -n "$message_to_caller" ]; then
    printf '  message_to_caller: %s\n' "$message_to_caller"
  fi
  return 0
}

# coord_mediate_escalate [<reason>]
#   Activate lockdown with reason_source=user_escalation.
coord_mediate_escalate() {
  local reason="${1:-Operator escalation: user requested system pause}"
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_mediate_die "COORD_DIR not set"
  fi
  if ! command -v coord_lockdown_activate >/dev/null 2>&1; then
    _coord_mediate_die "lib/lockdown.sh not sourced; cannot escalate"
  fi
  if command -v coord_lockdown_check >/dev/null 2>&1 && coord_lockdown_check; then
    _coord_mediate_warn "lockdown is already active; --escalate is a no-op"
    return 0
  fi
  if ! coord_lockdown_activate "$reason" "user_escalation"; then
    _coord_mediate_die "lockdown activation failed"
  fi
  printf 'coord mediate: lockdown activated (reason_source=user_escalation).\n'
  printf '  Reason: %s\n' "$reason"
  printf '  All sessions will be denied tool calls until you run: coord mediate --resume\n'
  return 0
}

# coord_mediate_resume
#   Clear any active lockdown (regardless of reason_source).
coord_mediate_resume() {
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_mediate_die "COORD_DIR not set"
  fi
  if ! command -v coord_lockdown_clear >/dev/null 2>&1; then
    _coord_mediate_die "lib/lockdown.sh not sourced; cannot resume"
  fi
  if ! command -v coord_lockdown_check >/dev/null 2>&1 || ! coord_lockdown_check; then
    _coord_mediate_warn "no active lockdown; --resume is a no-op"
    return 0
  fi
  if ! coord_lockdown_clear; then
    _coord_mediate_die "lockdown clear failed"
  fi
  printf 'coord mediate: lockdown cleared. Sessions resume normal operation.\n'
  return 0
}

# coord_mediate_status
#   Read-only summary. Output sections:
#     1. Active lockdown
#     2. Recent verdicts (last N)
#     3. Pending unresolved verdicts (peer-disagreement awaiting approve)
#     4. Last Mediator invocation timing + cost
#     5. Recent watchdog probes
coord_mediate_status() {
  if [ -z "${COORD_DIR:-}" ]; then
    _coord_mediate_die "COORD_DIR not set"
  fi
  printf '=== Coord Mediator Status ===\n\n'

  # Section 1: Active lockdown
  printf '## Lockdown\n'
  local lockdown_file="$COORD_DIR/mediator/lockdown.json"
  if [ -f "$lockdown_file" ]; then
    local reason rs started
    reason=$(jq -r '.reason // ""' "$lockdown_file" 2>/dev/null)
    rs=$(jq -r '.reason_source // "?"' "$lockdown_file" 2>/dev/null)
    started=$(jq -r '.started_at // "?"' "$lockdown_file" 2>/dev/null)
    printf '  ACTIVE\n'
    printf '    reason_source: %s\n' "$rs"
    printf '    started_at:    %s\n' "$started"
    printf '    reason:        %s\n' "$reason"
    printf '    To clear: coord mediate --resume\n'
  else
    printf '  inactive\n'
  fi
  printf '\n'

  # Section 2: Recent verdicts
  printf '## Recent verdicts (last %d)\n' "$COORD_MEDIATE_STATUS_VERDICT_LIMIT"
  local verdict_dir="$COORD_DIR/mediator/verdict"
  if [ -d "$verdict_dir" ]; then
    local found=0
    for vfile in $(ls -1t "$verdict_dir"/*.json 2>/dev/null | head -n "$COORD_MEDIATE_STATUS_VERDICT_LIMIT"); do
      found=1
      local action_type severity confidence ts
      action_type=$(jq -r '.action_type // "?"' "$vfile" 2>/dev/null)
      severity=$(jq -r '.severity // "n/a"' "$vfile" 2>/dev/null)
      confidence=$(jq -r '.confidence // "?"' "$vfile" 2>/dev/null)
      ts=$(jq -r '.ts // "?"' "$vfile" 2>/dev/null)
      printf '  %s  action=%s severity=%s confidence=%s\n' \
        "$(basename "$vfile")" "$action_type" "$severity" "$confidence"
    done
    [ "$found" -eq 0 ] && printf '  (no verdicts)\n'
  else
    printf '  (no verdict directory)\n'
  fi
  printf '\n'

  # Section 3: Pending unresolved (peer-disagreement awaiting --approve)
  # Scan events.jsonl for the most-recent MEDIATOR_PEER_DISAGREED event;
  # if that event is more recent than the most-recent
  # MEDIATOR_USER_APPROVED, the pair is unresolved.
  printf '## Pending peer-review disagreements\n'
  local events="$COORD_DIR/events.jsonl"
  if [ -f "$events" ]; then
    local last_disagree last_approve
    last_disagree=$(jq -rs 'reverse | map(select(.kind == "MEDIATOR_PEER_DISAGREED")) | .[0] // empty | .ts' "$events" 2>/dev/null)
    last_approve=$(jq -rs 'reverse | map(select(.kind == "MEDIATOR_USER_APPROVED")) | .[0] // empty | .ts' "$events" 2>/dev/null)
    if [ -n "$last_disagree" ] && [ "$last_disagree" \> "${last_approve:-}" ]; then
      local primary_path peer_path
      primary_path=$(jq -rs 'reverse | map(select(.kind == "MEDIATOR_PEER_DISAGREED")) | .[0].payload.primary_verdict_path // ""' "$events" 2>/dev/null)
      peer_path=$(jq -rs 'reverse | map(select(.kind == "MEDIATOR_PEER_DISAGREED")) | .[0].payload.peer_verdict_path // ""' "$events" 2>/dev/null)
      printf '  AWAITING --approve\n'
      printf '    primary_verdict: %s\n' "$primary_path"
      printf '    peer_verdict:    %s\n' "$peer_path"
      printf '    Resolve via: coord mediate --approve <one_of_the_two_paths>\n'
    else
      printf '  (none)\n'
    fi
  else
    printf '  (no events log)\n'
  fi
  printf '\n'

  # Section 4: Last Mediator invocation timing + cost
  printf '## Last Mediator invocation\n'
  if [ -f "$events" ]; then
    local last_verdict
    last_verdict=$(jq -rs 'reverse | map(select(.kind == "MEDIATOR_VERDICT")) | .[0] // empty' "$events" 2>/dev/null)
    if [ -n "$last_verdict" ] && [ "$last_verdict" != "null" ]; then
      local v_ts v_action v_duration v_cost v_session
      v_ts=$(printf '%s' "$last_verdict" | jq -r '.ts // "?"')
      v_action=$(printf '%s' "$last_verdict" | jq -r '.payload.action_type // "?"')
      v_duration=$(printf '%s' "$last_verdict" | jq -r '.payload.duration_ms // 0')
      v_cost=$(printf '%s' "$last_verdict" | jq -r '.payload.total_cost_usd // 0')
      v_session=$(printf '%s' "$last_verdict" | jq -r '.payload.spawn_session_id // "?"')
      printf '  ts:                  %s\n' "$v_ts"
      printf '  action_type:         %s\n' "$v_action"
      printf '  duration_ms:         %s\n' "$v_duration"
      printf '  total_cost_usd:      %s\n' "$v_cost"
      printf '  spawn_session_id:    %s\n' "$v_session"
    else
      printf '  (no Mediator invocations recorded)\n'
    fi
  else
    printf '  (no events log)\n'
  fi
  printf '\n'

  # Section 5: Recent watchdog probes
  printf '## Recent watchdog probes (last %d)\n' "$COORD_MEDIATE_STATUS_WATCHDOG_LIMIT"
  if [ -f "$events" ]; then
    local probes
    probes=$(jq -rs --argjson n "$COORD_MEDIATE_STATUS_WATCHDOG_LIMIT" \
      'reverse | map(select(.kind == "WATCHDOG_PROBED")) | .[0:$n]
       | map("  " + .ts + "  target=" + (.payload.target // "?") + " verdict=" + (.payload.verdict // "?"))
       | join("\n")' "$events" 2>/dev/null)
    if [ -n "$probes" ]; then
      printf '%s\n' "$probes"
    else
      printf '  (no probes)\n'
    fi
  else
    printf '  (no events log)\n'
  fi
  printf '\n'
  return 0
}

# coord_mediate_dispatch <args...>
#   Top-level subcommand router invoked by src/core/bin/coord.
coord_mediate_dispatch() {
  if [ $# -eq 0 ]; then
    _coord_mediate_usage
    _coord_mediate_die "no subcommand given"
  fi
  case "$1" in
    --help|-h|help)
      _coord_mediate_usage
      return 0
      ;;
    --reason)
      shift
      coord_mediate_reason "${1:-}"
      ;;
    --reason=*)
      coord_mediate_reason "${1#--reason=}"
      ;;
    --approve)
      shift
      coord_mediate_approve "${1:-}"
      ;;
    --approve=*)
      coord_mediate_approve "${1#--approve=}"
      ;;
    --escalate)
      shift
      local reason=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --reason) reason="${2:-}"; shift 2 ;;
          --reason=*) reason="${1#--reason=}"; shift ;;
          *) shift ;;
        esac
      done
      coord_mediate_escalate "$reason"
      ;;
    --resume)
      coord_mediate_resume
      ;;
    status)
      coord_mediate_status
      ;;
    *)
      _coord_mediate_usage
      _coord_mediate_die "unknown subcommand: $1"
      ;;
  esac
}

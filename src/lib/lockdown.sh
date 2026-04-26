#!/usr/bin/env bash
# lockdown.sh — Mediator system-wide lockdown helpers (Phase 3 / T3.03).
#
# Per PR-PHASE3-01 (Decision 1) the Mediator may activate a system-wide
# pause when a problem's scope demands it. Lockdown is the second of the
# Phase 3 invariant's exactly-two `permissionDecision: deny` sources;
# the first is pre_tool_use_write.sh's lock-held-by-other branch
# (existing Phase 2). Every coord-owned hook checks the lockdown gate
# before its main work; on active lockdown, the hook emits a stop
# signal via `coord_lockdown_emit_deny` and exits 0.
#
# Lockdown semantics (per disposition #2):
#   - Existence-based gate: lockdown.json existing AND parsing with
#     `active=true` means the system is paused. Cleared lockdowns are
#     archived to `.coord/mediator/lockdown_archive/<ts>.cleared.json`
#     by atomic rename — there is no `active=false` retention state.
#   - Fail-open on parse failure: an unparseable lockdown.json is
#     treated as "lockdown infrastructure is broken" and the caller
#     proceeds without emitting deny. A loud stderr warning + ERROR
#     event log is emitted so the operator can repair.
#
# lockdown.json schema (per disposition #3):
#   {
#     "active": true,
#     "reason": "<human-readable text for user display>",
#     "reason_source": "critical_bypass" | "mediator_verdict",
#     "started_at": "<ISO timestamp>"
#   }
#
# Public functions:
#   coord_lockdown_check
#       Returns 0 if lockdown is active, 1 otherwise (incl. parse fail).
#   coord_lockdown_activate <reason> <reason_source>
#       Atomically writes lockdown.json + emits LOCKDOWN_ACTIVATED.
#   coord_lockdown_clear
#       Atomic rename → lockdown_archive/; emits LOCKDOWN_CLEARED.
#   coord_lockdown_emit_deny <hook_event_name>
#       Reads reason; emits permissionDecision:deny JSON; logs
#       HOOK_DENIED_BY_LOCKDOWN. Returns 1 (suppress) on parse failure.
#
# Dependencies: callers must already have sourced log_event.sh (for
# coord_log_event + coord_now_iso8601). Hooks satisfy this naturally
# since log_event.sh is sourced everywhere.

# Note: this file is sourced; do not set -e here (caller governs).

# Resolve lockdown.json path. COORD_DIR must be set by the caller.
_coord_lockdown_file() {
  printf '%s/mediator/lockdown.json' "${COORD_DIR:-}"
}

_coord_lockdown_archive_dir() {
  printf '%s/mediator/lockdown_archive' "${COORD_DIR:-}"
}

# coord_lockdown_check
#   Returns 0 if lockdown active (file exists AND parses AND active=true).
#   Returns 1 if lockdown absent OR parse fails OR active!=true.
#   On parse failure, emits stderr warning + ERROR event (fail-open).
#   Fast-path: file existence check before invoking jq.
coord_lockdown_check() {
  local f
  f=$(_coord_lockdown_file)
  [ -z "${COORD_DIR:-}" ] && return 1
  [ ! -f "$f" ] && return 1
  local active
  if ! active=$(jq -r '.active // false' "$f" 2>/dev/null); then
    printf 'coord lockdown: %s parse failed; failing open\n' "$f" >&2
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=ERROR source=lockdown_check reason=parse_failed file="$f" 2>/dev/null || true
    fi
    return 1
  fi
  [ "$active" = "true" ] && return 0
  return 1
}

# coord_lockdown_activate <reason> <reason_source>
#   Writes lockdown.json atomically (temp + rename); emits
#   LOCKDOWN_ACTIVATED event. reason_source ∈
#   {critical_bypass, mediator_verdict}.
#   Concurrent calls: temp-file pid-suffix prevents collision; the
#   final mv-rename is atomic so one writer's content lands in place
#   (last-mv wins; both succeed at the rc level — the file is whole
#   either way; an extra LOCKDOWN_ACTIVATED event is logged for the
#   loser, which is acceptable audit noise for a rare race).
coord_lockdown_activate() {
  local reason="$1"
  local reason_source="$2"
  if [ -z "${COORD_DIR:-}" ]; then
    printf 'coord lockdown: COORD_DIR unset; cannot activate\n' >&2
    return 1
  fi
  local lockdown_dir="${COORD_DIR}/mediator"
  local f="${lockdown_dir}/lockdown.json"
  [ -d "$lockdown_dir" ] || mkdir -p "$lockdown_dir" 2>/dev/null || {
    printf 'coord lockdown: cannot create %s\n' "$lockdown_dir" >&2
    return 1
  }
  local now
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    now=$(coord_now_iso8601)
  else
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  # $$ in backgrounded subshells stays the parent PID under Bash 3.2 (no
  # BASHPID); $RANDOM is reseeded per subshell so the combination yields a
  # unique temp path even when two activates race.
  local tmp="${f}.tmp.$$.$RANDOM"
  if ! jq -nc --arg r "$reason" --arg rs "$reason_source" --arg t "$now" \
        '{active: true, reason: $r, reason_source: $rs, started_at: $t}' >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf 'coord lockdown: jq build failed during activate\n' >&2
    return 1
  fi
  if ! mv -f "$tmp" "$f" 2>/dev/null; then
    rm -f "$tmp"
    printf 'coord lockdown: atomic rename failed during activate\n' >&2
    return 1
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=LOCKDOWN_ACTIVATED \
      reason="$reason" reason_source="$reason_source" started_at="$now" 2>/dev/null || true
  fi
  return 0
}

# coord_lockdown_clear
#   Atomically rename lockdown.json → lockdown_archive/<ts>.cleared.json.
#   Emits LOCKDOWN_CLEARED event with archived_to payload.
#   Returns 1 if no lockdown.json present.
coord_lockdown_clear() {
  if [ -z "${COORD_DIR:-}" ]; then
    printf 'coord lockdown: COORD_DIR unset; cannot clear\n' >&2
    return 1
  fi
  local f
  f=$(_coord_lockdown_file)
  if [ ! -f "$f" ]; then
    return 1
  fi
  local archive_dir
  archive_dir=$(_coord_lockdown_archive_dir)
  [ -d "$archive_dir" ] || mkdir -p "$archive_dir" 2>/dev/null || {
    printf 'coord lockdown: cannot create %s\n' "$archive_dir" >&2
    return 1
  }
  local now
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    now=$(coord_now_iso8601)
  else
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
  # Sanitize timestamp for filename (colons + dots become dashes).
  local fname_safe
  fname_safe=$(printf '%s' "$now" | tr ':.' '--')
  local archived="${archive_dir}/${fname_safe}.cleared.json"
  if ! mv "$f" "$archived" 2>/dev/null; then
    printf 'coord lockdown: archive rename failed (%s -> %s)\n' "$f" "$archived" >&2
    return 1
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=LOCKDOWN_CLEARED archived_to="$archived" cleared_at="$now" 2>/dev/null || true
  fi
  return 0
}

# coord_lockdown_emit_deny <hook_event_name>
#   Read `reason` + `reason_source` from lockdown.json; emit
#   permissionDecision:deny JSON to stdout (Claude Code respects this
#   for PreToolUse events; for non-PreToolUse events Claude Code
#   ignores the field — but the architectural invariant is preserved
#   AND the hook's main bookkeeping is skipped via the caller's
#   exit-after-emit pattern). Logs HOOK_DENIED_BY_LOCKDOWN.
#   On parse failure: stderr warning + ERROR event + return 1; the
#   caller treats return 1 as "do not deny" (fail-open).
coord_lockdown_emit_deny() {
  local hook_event="${1:-Unknown}"
  local f
  f=$(_coord_lockdown_file)
  if [ ! -f "$f" ]; then
    return 1
  fi
  local reason reason_source
  if ! reason=$(jq -r '.reason // ""' "$f" 2>/dev/null); then
    printf 'coord lockdown: emit_deny parse failed for %s; suppressing deny\n' "$f" >&2
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=ERROR source=lockdown_emit_deny reason=parse_failed file="$f" 2>/dev/null || true
    fi
    return 1
  fi
  reason_source=$(jq -r '.reason_source // ""' "$f" 2>/dev/null || printf '')
  # The reason text is what Claude Code surfaces in PreToolUse contexts.
  # We embed reason_source as a tagged audit suffix so bats can verify
  # both fields are visible in a single string and operators see the
  # source even when only the reason text is rendered.
  local full_reason
  full_reason=$(printf 'System-wide pause: %s. Wait, do not retry until lockdown is cleared. [reason_source=%s]' \
                       "$reason" "$reason_source")
  jq -nc --arg event "$hook_event" --arg r "$full_reason" \
    '{hookSpecificOutput: {hookEventName: $event,
                            permissionDecision: "deny",
                            permissionDecisionReason: $r}}'
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=HOOK_DENIED_BY_LOCKDOWN \
      hook="$hook_event" source=lockdown reason_source="$reason_source" 2>/dev/null || true
  fi
  return 0
}

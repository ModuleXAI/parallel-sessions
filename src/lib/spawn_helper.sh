#!/usr/bin/env bash
# spawn_helper.sh — mode-aware claude binary routing for coord spawn sites.
#
# Per PR-PHASE7-01 + PR-PHASE7-02 (Phase 7 OQ4 binding). Resolves
# COORD_TEST_MODE env-var into one of {mock, semi, realistic}, then
# tells each spawn site whether to invoke real `claude -p` for the
# current process.
#
# Contract (PR-PHASE7-02 §"Helper API"):
#
#   coord_spawn_helper_resolve_mode
#     Print the resolved mode on stdout (mock | semi | realistic).
#     Cached in process-scoped variable _COORD_SPAWN_MODE_CACHED;
#     re-resolves only if the cache is unset. Always rc=0 (invalid
#     env-var values fall through to mock with a one-time stderr
#     warning + COORD_TEST_MODE_INVALID audit event).
#
#   coord_spawn_helper_should_use_real_claude <site>
#     Site ∈ {mediator, validator, task_processor}. rc=0 if the site
#     uses real `claude -p` in the current mode; rc=1 otherwise.
#
#   _coord_spawn_helper_emit_resolved_event <mode> <source>
#     Internal: emits COORD_SPAWN_MODE_RESOLVED once per process via
#     guard variable _COORD_SPAWN_MODE_EVENT_EMITTED.
#
# Routing matrix (PR-PHASE7-01):
#
#   | site            | mock | semi | realistic |
#   |-----------------|------|------|-----------|
#   | mediator        | mock | real | real      |
#   | validator       | mock | mock | real      |
#   | task_processor  | mock | real | real      |
#
# Complexity Classifier is SKIPPED in all modes (OQ4 follow-up;
# Phase 6 caller-supplied --complexity is sufficient for v1).
#
# Phase 7 §A.13 lesson application notes:
#   - Lesson #11 (multi-assign local + set -u): every `local` assigns
#     exactly one variable.
#   - Lesson #6 (event-emission audit per return path): each return
#     path of resolve_mode emits the resolved event exactly once via
#     idempotent guard.
#   - Lesson #14 (jq // false-trigger): NOT applicable here — env-var
#     handling uses bash ${var:-default}, not jq has().
#   - No file I/O; no flock; no jq; no perl. Pure bash 3.2.

set -euo pipefail

# Process-scoped caches (idempotent guards).
_COORD_SPAWN_MODE_CACHED="${_COORD_SPAWN_MODE_CACHED:-}"
_COORD_SPAWN_MODE_INVALID_WARNED="${_COORD_SPAWN_MODE_INVALID_WARNED:-}"
_COORD_SPAWN_MODE_EVENT_EMITTED="${_COORD_SPAWN_MODE_EVENT_EMITTED:-}"

# coord_spawn_helper_resolve_mode
#   Resolve COORD_TEST_MODE env-var to one of {mock, semi, realistic}.
#   First call per process: parse env-var, validate, emit one-time
#   warning + audit event on invalid value, cache result. Subsequent
#   calls: return cached value silently.
coord_spawn_helper_resolve_mode() {
  if [ -n "$_COORD_SPAWN_MODE_CACHED" ]; then
    printf '%s' "$_COORD_SPAWN_MODE_CACHED"
    return 0
  fi

  local raw="${COORD_TEST_MODE:-}"
  local resolved
  local source

  case "$raw" in
    '')
      resolved=mock
      source=default
      ;;
    mock)
      resolved=mock
      source=env
      ;;
    semi)
      resolved=semi
      source=env
      ;;
    realistic)
      resolved=realistic
      source=env
      ;;
    *)
      # Invalid value → fail-closed to mock with one-time warning +
      # audit event (PR-PHASE7-01 §"User-resolved decision").
      resolved=mock
      source=invalid_default
      if [ -z "$_COORD_SPAWN_MODE_INVALID_WARNED" ]; then
        _COORD_SPAWN_MODE_INVALID_WARNED=1
        printf "WARNING: COORD_TEST_MODE='%s' invalid; defaulting to 'mock'. Valid values: mock | semi | realistic.\n" \
          "$raw" >&2
        if command -v coord_log_event >/dev/null 2>&1; then
          coord_log_event kind=COORD_TEST_MODE_INVALID \
            value="$raw" defaulted_to=mock 2>/dev/null || true
        fi
      fi
      ;;
  esac

  _COORD_SPAWN_MODE_CACHED="$resolved"
  _coord_spawn_helper_emit_resolved_event "$resolved" "$source"
  printf '%s' "$resolved"
  return 0
}

# coord_spawn_helper_should_use_real_claude <site>
#   <site> ∈ {mediator, validator, task_processor}. rc=0 if real
#   claude in current mode; rc=1 otherwise. Unknown sites return
#   rc=1 (conservative — never claim "real" for an unenumerated
#   site).
coord_spawn_helper_should_use_real_claude() {
  local site="${1:-}"
  if [ -z "$site" ]; then
    return 1
  fi

  local mode
  mode=$(coord_spawn_helper_resolve_mode)

  case "$mode" in
    mock)
      # All sites mock-routed.
      return 1
      ;;
    semi)
      case "$site" in
        mediator|task_processor) return 0 ;;
        validator) return 1 ;;
        *) return 1 ;;
      esac
      ;;
    realistic)
      case "$site" in
        mediator|validator|task_processor) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      # Defensive: cache should never hold an invalid mode, but
      # treat unknown as mock-routed.
      return 1
      ;;
  esac
}

# _coord_spawn_helper_emit_resolved_event <mode> <source>
#   Internal. Emit COORD_SPAWN_MODE_RESOLVED once per process.
#   Source ∈ {env, default, invalid_default}.
_coord_spawn_helper_emit_resolved_event() {
  if [ -n "$_COORD_SPAWN_MODE_EVENT_EMITTED" ]; then
    return 0
  fi
  _COORD_SPAWN_MODE_EVENT_EMITTED=1

  local mode="${1:-}"
  local source="${2:-unknown}"

  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=COORD_SPAWN_MODE_RESOLVED \
      mode="$mode" source="$source" 2>/dev/null || true
  fi
  return 0
}

# CLI shim for bats / ad-hoc:
#   spawn_helper.sh resolve              → prints mode
#   spawn_helper.sh check <site>         → rc 0/1
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    resolve)
      coord_spawn_helper_resolve_mode
      printf '\n'
      ;;
    check)
      if coord_spawn_helper_should_use_real_claude "${2:-}"; then
        exit 0
      else
        exit 1
      fi
      ;;
    *)
      printf 'usage: spawn_helper.sh resolve | check <site>\n' >&2
      exit 2
      ;;
  esac
fi

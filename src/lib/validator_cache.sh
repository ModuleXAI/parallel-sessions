#!/usr/bin/env bash
# validator_cache.sh — Phase 4 / T4.02b validator verdict cache.
#
# Per PR-PHASE4-04 (Concern D in-scope disposition; ship-gate item 4):
# repeated SAFE/MINOR verdicts on the same (file, read_hash, current_
# hash) drift triple are cached to avoid token churn. CRITICAL is NEVER
# cached — every CRITICAL drift triggers fresh Mediator escalation.
#
# Cache layout:
#   .coord/validator/cache.json    — JSON object with "entries" array
#   .coord/validator/cache.lock    — flock sentinel
#
# Entry schema (per PR-PHASE4-04 disposition #4):
#   {
#     "file": "<path>",
#     "read_hash": "<sha256>",
#     "current_hash": "<sha256>",
#     "verdict": "SAFE" | "MINOR",
#     "verdict_source": "prefilter" | "validator_agent",
#     "diff_summary": "<text — for MINOR banner regeneration; null for SAFE>",
#     "cached_at": "<ISO 8601 UTC>",
#     "ttl_until": "<ISO 8601 UTC>"
#   }
#
# Public functions:
#   coord_validator_cache_lookup <file> <read_hash> <current_hash>
#       Returns 0 on HIT (stdout TSV: <verdict>\t<verdict_source>\t<diff_summary>);
#       1 on MISS (no stdout); 2 on cache file unreadable (treated as MISS by caller).
#   coord_validator_cache_write <file> <read_hash> <current_hash>
#                               <verdict> <verdict_source> [<diff_summary>]
#       Returns 0 on success / no-op (CRITICAL refused);
#       1 on failure. Opportunistic GC drops expired entries during write.
#   coord_validator_cache_clear
#       Resets cache.json to {"entries": []}. Idempotent.
#
# CRITICAL handling: refused at write (no-op + warning event). The
# rationale per PR-PHASE4-04: every CRITICAL drift event must trigger
# fresh Mediator escalation to ensure intervention; cached CRITICAL
# would short-circuit Mediator invocation with stale state.
#
# Concurrency: all writes hold flock on cache.lock for the entirety of
# read-current → filter-expired → append-new → atomic-rename window.
# Lookups also hold flock briefly (for atomic JSON read + GC drop).
#
# Bash 3.2 portable.

# Tunables (env-overridable; install.sh / coord health surface formal
# config.json entries via PR-PHASE4-04 §C).
: "${COORD_VALIDATOR_CACHE_TTL_SEC:=3600}"
: "${COORD_VALIDATOR_CACHE_MAX_ENTRIES:=1000}"

_coord_validator_cache_root() {
  printf '%s/validator' "${COORD_DIR:-}"
}

_coord_validator_cache_file() {
  printf '%s/validator/cache.json' "${COORD_DIR:-}"
}

_coord_validator_cache_lock() {
  printf '%s/validator/cache.lock' "${COORD_DIR:-}"
}

_coord_validator_cache_now_iso8601() {
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    coord_now_iso8601
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# _coord_validator_cache_iso_to_epoch <iso>
#   Strip ms suffix if present; convert to epoch.
_coord_validator_cache_iso_to_epoch() {
  local iso="$1"
  [ -z "$iso" ] && { printf '0'; return; }
  local base="${iso%.*Z}"
  case "$iso" in
    *.*Z) base="${base}Z" ;;
    *)    base="$iso" ;;
  esac
  date -u -d "$base" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$base" +%s 2>/dev/null \
    || printf '0'
}

# _coord_validator_cache_ensure_root
#   Lazy mkdir + initial cache.json bootstrap. Caller MUST hold flock
#   when this fires under concurrency to avoid double-create races.
_coord_validator_cache_ensure_root() {
  local root
  root=$(_coord_validator_cache_root)
  [ -d "$root" ] || mkdir -p "$root" 2>/dev/null || return 1
  local cache_file lock_file
  cache_file=$(_coord_validator_cache_file)
  lock_file=$(_coord_validator_cache_lock)
  [ -f "$lock_file" ] || : >"$lock_file"
  if [ ! -f "$cache_file" ]; then
    printf '%s\n' '{"entries":[]}' >"$cache_file" 2>/dev/null || return 1
  fi
  return 0
}

# coord_validator_cache_lookup <file> <read_hash> <current_hash>
#   On HIT, prints "<verdict>\t<verdict_source>\t<diff_summary>" to
#   stdout (diff_summary is empty string for SAFE) and returns 0.
#   On MISS or unreadable cache, returns 1.
coord_validator_cache_lookup() {
  local file="$1" rhash="$2" chash="$3"
  if [ -z "$file" ] || [ -z "$rhash" ] || [ -z "$chash" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    return 1
  fi
  local cache_file
  cache_file=$(_coord_validator_cache_file)
  [ -f "$cache_file" ] || return 1
  local now_iso now_epoch
  now_iso=$(_coord_validator_cache_now_iso8601)
  now_epoch=$(_coord_validator_cache_iso_to_epoch "$now_iso")
  local hit
  hit=$(jq -r --arg f "$file" --arg rh "$rhash" --arg ch "$chash" --argjson now "$now_epoch" '
    (.entries // [])
    | map(select(.file == $f and .read_hash == $rh and .current_hash == $ch))
    | map(select((.ttl_until | fromdateiso8601) > $now))
    | last
    | if . == null then "" else "\(.verdict)\t\(.verdict_source)\t\((.diff_summary // ""))" end
  ' "$cache_file" 2>/dev/null) || return 1
  [ -z "$hit" ] && return 1
  if command -v coord_log_event >/dev/null 2>&1; then
    local verdict verdict_source
    verdict=$(printf '%s' "$hit" | awk -F'\t' '{print $1}')
    verdict_source=$(printf '%s' "$hit" | awk -F'\t' '{print $2}')
    coord_log_event kind=VALIDATOR_CACHE_HIT \
      file="$file" read_hash="$rhash" current_hash="$chash" \
      cached_verdict="$verdict" verdict_source="$verdict_source" || true
  fi
  printf '%s\n' "$hit"
  return 0
}

# coord_validator_cache_write <file> <read_hash> <current_hash>
#                             <verdict> <verdict_source> [<diff_summary>]
#   Atomically rewrites cache.json with the new entry appended and any
#   expired entries dropped. CRITICAL refused. Returns 0 on success or
#   refused-no-op; 1 on failure.
coord_validator_cache_write() {
  local file="$1" rhash="$2" chash="$3" verdict="$4" verdict_source="$5"
  local diff_summary="${6:-}"
  if [ -z "$file" ] || [ -z "$rhash" ] || [ -z "$chash" ] \
     || [ -z "$verdict" ] || [ -z "$verdict_source" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    return 1
  fi
  if [ "$verdict" = "CRITICAL" ]; then
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_CACHE_WRITE_REFUSED \
        file="$file" reason=critical_not_cacheable || true
    fi
    return 0
  fi
  case "$verdict" in
    SAFE|MINOR) : ;;
    *) return 1 ;;
  esac
  case "$verdict_source" in
    prefilter|validator_agent) : ;;
    *) return 1 ;;
  esac
  if [ "$verdict" = "MINOR" ] && [ -z "$diff_summary" ]; then
    # MINOR requires diff_summary (banner regeneration).
    return 1
  fi
  if ! _coord_validator_cache_ensure_root; then
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_CACHE_WRITE_REFUSED \
        file="$file" reason=ensure_root_failed || true
    fi
    return 1
  fi
  local cache_file lock_file
  cache_file=$(_coord_validator_cache_file)
  lock_file=$(_coord_validator_cache_lock)
  local cached_at ttl_until cached_at_epoch ttl_epoch
  cached_at=$(_coord_validator_cache_now_iso8601)
  cached_at_epoch=$(_coord_validator_cache_iso_to_epoch "$cached_at")
  ttl_epoch=$(( cached_at_epoch + COORD_VALIDATOR_CACHE_TTL_SEC ))
  ttl_until=$(date -u -r "$ttl_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$ttl_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$cached_at")
  local diff_summary_arg=""
  if [ "$verdict" = "MINOR" ]; then
    diff_summary_arg="$diff_summary"
  fi
  local tmp="${cache_file}.tmp.$$.$RANDOM"
  local rc=0
  (
    flock -x -w 5 9 || exit 1
    # Read current state (after possible bootstrap by ensure_root).
    local cur
    cur=$(cat "$cache_file" 2>/dev/null || printf '%s' '{"entries":[]}')
    # Drop expired entries + same-key duplicate, then append new.
    # GC counters captured for event payload.
    local before after removed
    before=$(printf '%s' "$cur" | jq -r '(.entries // []) | length' 2>/dev/null || printf '0')
    local new_json
    new_json=$(printf '%s' "$cur" | jq -c \
      --arg f "$file" --arg rh "$rhash" --arg ch "$chash" \
      --arg v "$verdict" --arg vs "$verdict_source" \
      --arg ds "$diff_summary_arg" --arg vdrop_null "$verdict" \
      --arg cached_at "$cached_at" --arg ttl_until "$ttl_until" \
      --argjson now "$cached_at_epoch" \
      --argjson cap "$COORD_VALIDATOR_CACHE_MAX_ENTRIES" '
        (.entries // [])
        # Drop expired entries.
        | map(select((.ttl_until | fromdateiso8601) > $now))
        # Drop any prior entry for this exact key.
        | map(select(.file != $f or .read_hash != $rh or .current_hash != $ch))
        # Append new entry. diff_summary is null for SAFE; string for MINOR.
        | . + [{
            file: $f,
            read_hash: $rh,
            current_hash: $ch,
            verdict: $v,
            verdict_source: $vs,
            diff_summary: (if $vdrop_null == "MINOR" then $ds else null end),
            cached_at: $cached_at,
            ttl_until: $ttl_until
          }]
        # LRU bound: keep newest $cap entries by cached_at.
        | (if length > $cap then
             sort_by(.cached_at)
             | .[length - $cap : length]
           else . end)
        | {entries: .}
      ' 2>/dev/null)
    if [ -z "$new_json" ]; then
      exit 2
    fi
    after=$(printf '%s' "$new_json" | jq -r '(.entries // []) | length' 2>/dev/null || printf '0')
    case "$before" in *[!0-9]*|'') before=0 ;; esac
    case "$after"  in *[!0-9]*|'') after=0  ;; esac
    # before+1 (new entry) - after = removed (expired + over-cap evicted)
    removed=$(( (before + 1) - after ))
    [ "$removed" -lt 0 ] && removed=0
    printf '%s\n' "$new_json" >"$tmp" 2>/dev/null || exit 3
    mv -f "$tmp" "$cache_file" 2>/dev/null || exit 4
    # Emit GC event when entries were actually removed.
    if [ "$removed" -gt 0 ] && command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_CACHE_GC_RUN \
        kept_count="$after" removed_count="$removed" \
        triggered_by=validator_run_opportunistic || true
    fi
  ) 9>"$lock_file" || rc=$?
  rm -f "$tmp" 2>/dev/null
  if [ "$rc" -ne 0 ]; then
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=VALIDATOR_CACHE_WRITE_REFUSED \
        file="$file" reason="lock_or_write_failure_rc${rc}" || true
    fi
    return 1
  fi
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=VALIDATOR_CACHE_WRITE \
      file="$file" read_hash="$rhash" current_hash="$chash" \
      verdict="$verdict" verdict_source="$verdict_source" \
      ttl_seconds="$COORD_VALIDATOR_CACHE_TTL_SEC" || true
  fi
  return 0
}

# coord_validator_cache_clear
#   Reset cache.json to empty. Idempotent.
coord_validator_cache_clear() {
  if [ -z "${COORD_DIR:-}" ]; then
    return 1
  fi
  if ! _coord_validator_cache_ensure_root; then
    return 1
  fi
  local cache_file lock_file
  cache_file=$(_coord_validator_cache_file)
  lock_file=$(_coord_validator_cache_lock)
  (
    flock -x -w 5 9 || exit 1
    printf '%s\n' '{"entries":[]}' >"$cache_file" 2>/dev/null || exit 2
  ) 9>"$lock_file"
}

# CLI shim for tests + ad-hoc:
#   validator_cache.sh lookup <file> <read_hash> <current_hash>
#   validator_cache.sh write  <file> <read_hash> <current_hash> <verdict> <source> [<summary>]
#   validator_cache.sh clear
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    lookup) shift; coord_validator_cache_lookup "$@" ;;
    write)  shift; coord_validator_cache_write  "$@" ;;
    clear)  coord_validator_cache_clear ;;
    *) printf 'usage: validator_cache.sh {lookup|write|clear} ...\n' >&2; exit 2 ;;
  esac
fi

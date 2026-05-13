#!/usr/bin/env bash
# read_snapshots.sh — Phase 4 / T4.02a content-addressable read-snapshot
# store for the validator pipeline.
#
# Per PR-PHASE4-05 (T4.01 amendment surfacing the read-snapshot content
# gap): the Phase 4 validator pipeline (pre-filter + agent) needs the
# bytes of a file as the session read it, not just the hash. Phase 1's
# read_sets[].reads[] only stores the hash; this library captures the
# bytes alongside hash recording in pre_tool_use_read.sh.
#
# Layout (created by install.sh and lazily on first Read):
#   .coord/read_snapshots/                       — root
#   .coord/read_snapshots/<session_id>/          — per-session subdir
#   .coord/read_snapshots/<session_id>/<hash>.txt — exact read-time bytes
#
# Public functions:
#   coord_read_snapshot_path <sid> <hash>
#       String-only canonical path (no I/O). Used by validator pipeline
#       consumers to resolve the snapshot file location.
#   coord_read_snapshot_write <sid> <hash> <source_file>
#       Copy <source_file> to the snapshot path via temp+rename.
#       Idempotent: if destination exists (re-Read of unchanged file),
#       no-op. Skips silently when hash == "SKIPPED_LARGE" (logs
#       READ_SNAPSHOT_SKIPPED_LARGE). Returns 0 on success / no-op,
#       1 on failure (logs READ_SNAPSHOT_WRITE_FAILED).
#   coord_read_snapshot_supersede <sid> <prior_hash>
#       Delete the prior snapshot. Returns 0 idempotent. Logs
#       READ_SNAPSHOT_SUPERSEDED only when a file was removed.
#   coord_read_snapshot_cleanup_session <sid>
#       Recursively remove .coord/read_snapshots/<sid>/. Returns 0
#       idempotent. Logs READ_SNAPSHOT_SESSION_CLEANUP with counts.
#   coord_read_snapshot_lookup <sid> <hash>
#       Returns 0 if the snapshot exists and is readable; 1 otherwise.
#
# LRU eviction (per PR-PHASE4-05 ambiguity disposition #3):
#   Triggered inside coord_read_snapshot_write when the per-session
#   directory exceeds COORD_READ_SNAPSHOT_MAX_PER_SESSION_MB. Oldest
#   files (by mtime) are deleted until the cap is met. Logs
#   READ_SNAPSHOT_LRU_EVICTED per evicted file.
#
# Concurrency model (per PR-PHASE4-05 ambiguity disposition #5):
#   Per-session subdirectory means no cross-session collisions; no
#   flock needed for per-session writes. Within a session, two
#   simultaneous Reads of the same file with different hashes would
#   race — Decision 2.17 excludes subagents, so the race is bounded
#   to one Read per session per file per turn. Atomic temp+rename
#   handles any residual race.
#
# Bash 3.2 portable. F-018 GNU-first stat probe pattern used for
# portable mtime / size queries.

# Tunables (env-overridable; install.sh / coord health surface formal
# config.json entries via PR-PHASE4-05 §D).
: "${COORD_READ_SNAPSHOT_MAX_PER_SESSION_MB:=100}"

_coord_read_snapshot_root() {
  printf '%s/read_snapshots' "${COORD_DIR:-}"
}

_coord_read_snapshot_session_dir() {
  local sid="$1"
  printf '%s/read_snapshots/%s' "${COORD_DIR:-}" "$sid"
}

# coord_read_snapshot_path <sid> <hash>
#   Returns the canonical path on stdout. No I/O performed.
coord_read_snapshot_path() {
  local sid="$1" hash="$2"
  if [ -z "$sid" ] || [ -z "$hash" ] || [ -z "${COORD_DIR:-}" ]; then
    return 1
  fi
  printf '%s/read_snapshots/%s/%s.txt' "$COORD_DIR" "$sid" "$hash"
}

# coord_read_snapshot_lookup <sid> <hash>
#   Returns 0 if a readable snapshot exists; 1 otherwise.
coord_read_snapshot_lookup() {
  local sid="$1" hash="$2"
  [ -z "$sid" ] || [ -z "$hash" ] && return 1
  [ -z "${COORD_DIR:-}" ] && return 1
  local path
  path=$(coord_read_snapshot_path "$sid" "$hash") || return 1
  [ -r "$path" ]
}

# _coord_read_snapshot_file_size <path>
#   Portable file-size in bytes. F-018 GNU-first probe pattern.
#   Empty/missing → 0.
_coord_read_snapshot_file_size() {
  local f="$1" size=""
  [ -e "$f" ] || { printf '0'; return; }
  size=$(stat -c '%s' "$f" 2>/dev/null)
  case "$size" in
    ''|*[!0-9]*) size="" ;;
  esac
  if [ -z "$size" ]; then
    size=$(stat -f '%z' "$f" 2>/dev/null)
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
  fi
  printf '%d' "$size"
}

# _coord_read_snapshot_file_mtime <path>
#   Portable file-mtime epoch. F-018 GNU-first probe pattern.
_coord_read_snapshot_file_mtime() {
  local f="$1" mtime=""
  [ -e "$f" ] || { printf '0'; return; }
  mtime=$(stat -c '%Y' "$f" 2>/dev/null)
  case "$mtime" in
    ''|*[!0-9]*) mtime="" ;;
  esac
  if [ -z "$mtime" ]; then
    mtime=$(stat -f '%m' "$f" 2>/dev/null)
    case "$mtime" in
      ''|*[!0-9]*) mtime=0 ;;
    esac
  fi
  printf '%d' "$mtime"
}

# _coord_read_snapshot_session_bytes <sid>
#   Sum of all snapshot file sizes for a session. 0 if dir absent.
_coord_read_snapshot_session_bytes() {
  local sid="$1"
  local dir
  dir=$(_coord_read_snapshot_session_dir "$sid")
  [ -d "$dir" ] || { printf '0'; return; }
  local total=0 size f
  # Bash 3.2: no readarray; use for loop with glob.
  for f in "$dir"/*.txt; do
    [ -f "$f" ] || continue
    size=$(_coord_read_snapshot_file_size "$f")
    total=$(( total + size ))
  done
  printf '%d' "$total"
}

# _coord_read_snapshot_lru_evict <sid>
#   When session bytes exceed the cap, evict oldest snapshots (by mtime)
#   until under the cap. Each eviction logs READ_SNAPSHOT_LRU_EVICTED.
_coord_read_snapshot_lru_evict() {
  local sid="$1"
  local dir
  dir=$(_coord_read_snapshot_session_dir "$sid")
  [ -d "$dir" ] || return 0
  local cap_bytes=$(( COORD_READ_SNAPSHOT_MAX_PER_SESSION_MB * 1024 * 1024 ))
  local current
  current=$(_coord_read_snapshot_session_bytes "$sid")
  [ "$current" -le "$cap_bytes" ] && return 0
  # Build mtime|path list, sorted oldest-first.
  local f mtime
  local list_file
  list_file=$(mktemp 2>/dev/null) || return 1
  for f in "$dir"/*.txt; do
    [ -f "$f" ] || continue
    mtime=$(_coord_read_snapshot_file_mtime "$f")
    printf '%s\t%s\n' "$mtime" "$f" >>"$list_file"
  done
  # Sort numerically by first column (mtime), oldest first.
  local sorted_file
  sorted_file=$(mktemp 2>/dev/null) || { rm -f "$list_file"; return 1; }
  sort -n "$list_file" >"$sorted_file" 2>/dev/null
  rm -f "$list_file"
  # Evict from oldest until under cap.
  local victim_path victim_size victim_hash
  while IFS=$'\t' read -r _ victim_path; do
    [ -f "$victim_path" ] || continue
    [ "$current" -le "$cap_bytes" ] && break
    victim_size=$(_coord_read_snapshot_file_size "$victim_path")
    victim_hash=$(basename "$victim_path" .txt)
    if rm -f "$victim_path" 2>/dev/null; then
      current=$(( current - victim_size ))
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=READ_SNAPSHOT_LRU_EVICTED \
          target_session="$sid" hash="$victim_hash" \
          bytes="$victim_size" cap_bytes="$cap_bytes" || true
      fi
    fi
  done <"$sorted_file"
  rm -f "$sorted_file"
  return 0
}

# coord_read_snapshot_write <sid> <hash> <source_file>
#   Copy source_file to the canonical snapshot path. Idempotent: re-Read
#   of unchanged file (snapshot exists already) → no-op. SKIPPED_LARGE
#   sentinel → logs and returns 0 without writing.
coord_read_snapshot_write() {
  local sid="$1" hash="$2" source_file="$3"
  if [ -z "$sid" ] || [ -z "$hash" ] || [ -z "$source_file" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    return 1
  fi
  if [ "$hash" = "SKIPPED_LARGE" ]; then
    if command -v coord_log_event >/dev/null 2>&1; then
      local source_bytes
      source_bytes=$(_coord_read_snapshot_file_size "$source_file")
      coord_log_event kind=READ_SNAPSHOT_SKIPPED_LARGE \
        file="$source_file" hash="SKIPPED_LARGE" bytes="$source_bytes" || true
    fi
    return 0
  fi
  if [ ! -r "$source_file" ]; then
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=READ_SNAPSHOT_WRITE_FAILED \
        file="$source_file" hash="$hash" reason=source_unreadable || true
    fi
    return 1
  fi
  local dest_dir dest_path
  dest_dir=$(_coord_read_snapshot_session_dir "$sid")
  dest_path=$(coord_read_snapshot_path "$sid" "$hash") || return 1
  # Idempotent fast-path.
  if [ -f "$dest_path" ]; then
    return 0
  fi
  if [ ! -d "$dest_dir" ]; then
    if ! mkdir -p "$dest_dir" 2>/dev/null; then
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=READ_SNAPSHOT_WRITE_FAILED \
          file="$source_file" hash="$hash" reason=mkdir_failed || true
      fi
      return 1
    fi
  fi
  # Atomic copy via temp + rename within same dir for rename-atomicity.
  local tmp="${dest_path}.tmp.$$.$RANDOM"
  if ! cp "$source_file" "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=READ_SNAPSHOT_WRITE_FAILED \
        file="$source_file" hash="$hash" reason=copy_failed || true
    fi
    return 1
  fi
  if ! mv "$tmp" "$dest_path" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=READ_SNAPSHOT_WRITE_FAILED \
        file="$source_file" hash="$hash" reason=rename_failed || true
    fi
    return 1
  fi
  # Opportunistic LRU eviction if the session dir is over cap.
  _coord_read_snapshot_lru_evict "$sid" 2>/dev/null || true
  if command -v coord_log_event >/dev/null 2>&1; then
    local bytes
    bytes=$(_coord_read_snapshot_file_size "$dest_path")
    coord_log_event kind=READ_SNAPSHOT_WRITTEN \
      file="$source_file" hash="$hash" bytes="$bytes" path="$dest_path" || true
  fi
  return 0
}

# coord_read_snapshot_supersede <sid> <prior_hash>
#   Delete prior snapshot file. Idempotent (no-op if absent).
coord_read_snapshot_supersede() {
  local sid="$1" prior_hash="$2"
  if [ -z "$sid" ] || [ -z "$prior_hash" ]; then
    return 0
  fi
  if [ -z "${COORD_DIR:-}" ]; then
    return 0
  fi
  if [ "$prior_hash" = "SKIPPED_LARGE" ]; then
    # No snapshot was written for SKIPPED_LARGE; nothing to delete.
    return 0
  fi
  local path
  path=$(coord_read_snapshot_path "$sid" "$prior_hash") || return 0
  if [ -f "$path" ]; then
    if rm -f "$path" 2>/dev/null; then
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=READ_SNAPSHOT_SUPERSEDED \
          target_session="$sid" prior_hash="$prior_hash" || true
      fi
    fi
  fi
  return 0
}

# coord_read_snapshot_cleanup_session <sid>
#   Remove the entire per-session snapshot directory.
coord_read_snapshot_cleanup_session() {
  local sid="$1"
  if [ -z "$sid" ] || [ -z "${COORD_DIR:-}" ]; then
    return 0
  fi
  local dir
  dir=$(_coord_read_snapshot_session_dir "$sid")
  if [ ! -d "$dir" ]; then
    return 0
  fi
  local removed_count=0 bytes_freed=0 size f
  for f in "$dir"/*.txt; do
    [ -f "$f" ] || continue
    size=$(_coord_read_snapshot_file_size "$f")
    bytes_freed=$(( bytes_freed + size ))
    removed_count=$(( removed_count + 1 ))
  done
  rm -rf "$dir" 2>/dev/null || true
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=READ_SNAPSHOT_SESSION_CLEANUP \
      target_session="$sid" removed_count="$removed_count" \
      bytes_freed="$bytes_freed" || true
  fi
  return 0
}

# CLI shim for tests and ad-hoc use:
#   read_snapshots.sh path <sid> <hash>
#   read_snapshots.sh write <sid> <hash> <source_file>
#   read_snapshots.sh supersede <sid> <prior_hash>
#   read_snapshots.sh cleanup-session <sid>
#   read_snapshots.sh lookup <sid> <hash>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    path)             shift; coord_read_snapshot_path "$@" ;;
    write)            shift; coord_read_snapshot_write "$@" ;;
    supersede)        shift; coord_read_snapshot_supersede "$@" ;;
    cleanup-session)  shift; coord_read_snapshot_cleanup_session "$@" ;;
    lookup)           shift; coord_read_snapshot_lookup "$@" ;;
    *) printf 'usage: read_snapshots.sh {path|write|supersede|cleanup-session|lookup} ...\n' >&2; exit 2 ;;
  esac
fi

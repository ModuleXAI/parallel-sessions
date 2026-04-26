#!/usr/bin/env bash
# watchdog_cache.sh — Phase 3 / T3.04 watchdog support infrastructure
# (cache + dedupe lock; NO probe heuristics, NO decision logic — those
# are T3.05).
#
# Per PR-PHASE3-02 (Decision 2 dispositions): the peer watchdog is the
# Mediator's lightweight pre-filter. To keep watchdog runs cheap and
# correct under multi-session contention this file provides:
#
#   - A recent-checks JSONL cache so observers can skip a probe when a
#     fresh verdict already exists for the suspected target.
#   - A per-target dedupe lock so when 5+ sessions notice the same
#     anomaly simultaneously, only ONE watchdog instance runs.
#
# Layout (created by install.sh):
#   .coord/watchdog/                       — root for watchdog state
#   .coord/watchdog/recent_checks.jsonl    — append-only verdict log
#   .coord/watchdog/recent_checks.lock     — flock sentinel for cache writes
#   .coord/watchdog/checking/              — per-target dedupe lock dir
#   .coord/watchdog/checking/<sid>.lock    — dedupe lock file (text content:
#                                             writer=<session>\nstarted_at=<iso>)
#
# recent_checks.jsonl entry shape (per PR-PHASE3-02 §B):
#   {"ts":"<ISO>","target":"<sid>","verdict":"alive|dead|uncertain",
#    "reason":"<short>","valid_until":"<ISO>"}
#
# TTL semantics (per PR-PHASE3-02 dispositions; alive=60s, uncertain=30s,
# dead=effectively-infinite-until-invalidate-pass):
#   - alive   → COORD_WATCHDOG_TTL_ALIVE_SEC      (default 60)
#   - uncertain → COORD_WATCHDOG_TTL_UNCERTAIN_SEC (default 30)
#   - dead    → COORD_WATCHDOG_TTL_DEAD_SEC       (default 31536000 = 1 year);
#               cleared on demand via coord_watchdog_cache_invalidate_dead
#               (which T3.05 will wire into session_start.sh).
#
# Public functions:
#   coord_watchdog_cache_lookup <target>
#       0/1 + stdout "<verdict>\t<reason>\t<valid_until>" on hit (last
#       non-expired entry for target wins).
#   coord_watchdog_cache_record <target> <verdict> <reason> <ttl_seconds>
#       Appends a JSONL entry under flock.
#   coord_watchdog_cache_expire
#       Atomic rewrite (temp+rename) keeping only entries with
#       valid_until > now.
#   coord_watchdog_cache_invalidate_dead
#       Atomic rewrite dropping every entry where verdict == "dead"
#       regardless of valid_until.
#   coord_watchdog_acquire_check_lock <target>
#       0 if dedupe lock acquired, 1 if held by another invoker.
#       Auto-clears stale locks (mtime older than
#       COORD_WATCHDOG_DEDUPE_STALE_TTL, default 30s) before the
#       attempt — covers crashed-watchdog recovery without operator
#       intervention.
#   coord_watchdog_release_check_lock <target>
#       rm -f the dedupe lock; always returns 0.
#
# Caller responsibilities (T3.05 territory):
#   - Decide WHETHER to probe (suspicion heuristics).
#   - Translate verdict → ttl using the TTL constants above.
#   - Wire coord_watchdog_cache_invalidate_dead into session_start.sh.

# Config tunables (env-overridable; T3.07 will surface formal config.json
# entries via PR-PHASE3-02 §C).
: "${COORD_WATCHDOG_TTL_ALIVE_SEC:=60}"
: "${COORD_WATCHDOG_TTL_UNCERTAIN_SEC:=30}"
: "${COORD_WATCHDOG_TTL_DEAD_SEC:=31536000}"
: "${COORD_WATCHDOG_DEDUPE_STALE_TTL:=30}"

_coord_watchdog_root() {
  printf '%s/watchdog' "${COORD_DIR:-}"
}

_coord_watchdog_cache_file() {
  printf '%s/watchdog/recent_checks.jsonl' "${COORD_DIR:-}"
}

_coord_watchdog_cache_lock() {
  printf '%s/watchdog/recent_checks.lock' "${COORD_DIR:-}"
}

_coord_watchdog_check_lock_dir() {
  printf '%s/watchdog/checking' "${COORD_DIR:-}"
}

# _coord_iso8601_to_epoch <iso>
#   Convert an ISO-8601 UTC timestamp to a Unix epoch integer. Strips
#   millisecond precision (.123Z) to keep BSD/GNU date happy.
_coord_iso8601_to_epoch() {
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

# _coord_epoch_now
_coord_epoch_now() { date -u +%s 2>/dev/null || printf '0'; }

# _coord_file_age_seconds <path>
#   Portable file-mtime-to-now-difference in seconds. macOS BSD stat
#   uses -f %m; GNU stat uses -c %Y. Returns 0 if unreadable.
_coord_file_age_seconds() {
  local f="$1" mtime
  [ -e "$f" ] || { printf '0'; return; }
  mtime=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || printf '0')
  local now
  now=$(_coord_epoch_now)
  local diff=$(( now - mtime ))
  [ "$diff" -lt 0 ] && diff=0
  printf '%d' "$diff"
}

# _coord_watchdog_now_iso8601
#   Local fallback if log_event.sh's coord_now_iso8601 hasn't been sourced.
_coord_watchdog_now_iso8601() {
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    coord_now_iso8601
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# coord_watchdog_cache_lookup <target_session_id>
#   Returns the most-recent non-expired entry for <target> on stdout
#   (TSV: verdict\treason\tvalid_until); rc=0. If no fresh entry,
#   prints nothing and returns 1.
coord_watchdog_cache_lookup() {
  local target="$1"
  [ -z "$target" ] && return 1
  [ -z "${COORD_DIR:-}" ] && return 1
  local f
  f=$(_coord_watchdog_cache_file)
  [ ! -f "$f" ] && return 1
  local now_epoch
  now_epoch=$(_coord_epoch_now)
  # Find the LAST entry matching target whose valid_until_epoch > now.
  # The cache file is small in practice (entries are pruned by expire),
  # so a single jq pass is fine. We compute valid_until_epoch via jq's
  # fromdate on the stored ISO string.
  local hit
  hit=$(jq -rs --arg t "$target" --argjson now "$now_epoch" '
    [.[] | select(.target == $t) | select((.valid_until | fromdateiso8601) > $now)]
    | last
    | if . == null then "" else "\(.verdict)\t\(.reason)\t\(.valid_until)" end
  ' "$f" 2>/dev/null) || return 1
  [ -z "$hit" ] && return 1
  printf '%s\n' "$hit"
  return 0
}

# coord_watchdog_cache_record <target> <verdict> <reason> <ttl_seconds>
#   Appends a JSONL entry under flock. Best-effort: returns 0 on success,
#   1 on lock timeout / disk error.
coord_watchdog_cache_record() {
  local target="$1" verdict="$2" reason="$3" ttl="$4"
  [ -z "$target" ] || [ -z "$verdict" ] || [ -z "$ttl" ] && return 1
  [ -z "${COORD_DIR:-}" ] && return 1
  local watchdog_root
  watchdog_root=$(_coord_watchdog_root)
  [ -d "$watchdog_root" ] || mkdir -p "$watchdog_root" 2>/dev/null || return 1
  local f lock_file
  f=$(_coord_watchdog_cache_file)
  lock_file=$(_coord_watchdog_cache_lock)
  [ -f "$lock_file" ] || : >"$lock_file"
  local ts now_epoch valid_until_epoch valid_until
  ts=$(_coord_watchdog_now_iso8601)
  now_epoch=$(_coord_epoch_now)
  valid_until_epoch=$(( now_epoch + ttl ))
  valid_until=$(date -u -r "$valid_until_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$valid_until_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$ts")
  local line
  line=$(jq -nc \
    --arg ts "$ts" --arg t "$target" --arg v "$verdict" \
    --arg r "$reason" --arg vu "$valid_until" \
    '{ts:$ts, target:$t, verdict:$v, reason:$r, valid_until:$vu}' 2>/dev/null) \
    || return 1
  (
    flock -x -w 5 9 || exit 1
    printf '%s\n' "$line" >>"$f" 2>/dev/null || exit 1
  ) 9>"$lock_file"
}

# coord_watchdog_cache_expire
#   Atomic rewrite: keep only entries whose valid_until > now. Idempotent.
coord_watchdog_cache_expire() {
  [ -z "${COORD_DIR:-}" ] && return 1
  local f lock_file
  f=$(_coord_watchdog_cache_file)
  lock_file=$(_coord_watchdog_cache_lock)
  [ ! -f "$f" ] && return 0
  [ -f "$lock_file" ] || : >"$lock_file"
  local now_epoch
  now_epoch=$(_coord_epoch_now)
  local tmp="${f}.tmp.$$.$RANDOM"
  (
    flock -x -w 5 9 || exit 1
    jq -c --argjson now "$now_epoch" \
      'select((.valid_until | fromdateiso8601) > $now)' "$f" >"$tmp" 2>/dev/null \
      || { rm -f "$tmp"; exit 1; }
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; exit 1; }
  ) 9>"$lock_file"
}

# coord_watchdog_cache_invalidate_dead
#   Atomic rewrite: drop entries where verdict == "dead" regardless of
#   valid_until. Called on session_start (T3.05 wiring) per disposition
#   "dead until next session_start of any session."
coord_watchdog_cache_invalidate_dead() {
  [ -z "${COORD_DIR:-}" ] && return 1
  local f lock_file
  f=$(_coord_watchdog_cache_file)
  lock_file=$(_coord_watchdog_cache_lock)
  [ ! -f "$f" ] && return 0
  [ -f "$lock_file" ] || : >"$lock_file"
  local tmp="${f}.tmp.$$.$RANDOM"
  (
    flock -x -w 5 9 || exit 1
    jq -c 'select(.verdict != "dead")' "$f" >"$tmp" 2>/dev/null \
      || { rm -f "$tmp"; exit 1; }
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; exit 1; }
  ) 9>"$lock_file"
}

# coord_watchdog_acquire_check_lock <target_session_id>
#   Atomic create-or-fail of .coord/watchdog/checking/<target>.lock.
#   Returns 0 if acquired (file created with content), 1 if already
#   held. Auto-clears stale locks (mtime > COORD_WATCHDOG_DEDUPE_STALE_TTL)
#   before the attempt so a crashed watchdog cannot wedge the dedupe
#   gate forever.
coord_watchdog_acquire_check_lock() {
  local target="$1"
  [ -z "$target" ] && return 1
  [ -z "${COORD_DIR:-}" ] && return 1
  local lock_dir lock_file
  lock_dir=$(_coord_watchdog_check_lock_dir)
  lock_file="${lock_dir}/${target}.lock"
  [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || return 1

  # Stale-lock auto-clear.
  if [ -f "$lock_file" ]; then
    local age
    age=$(_coord_file_age_seconds "$lock_file")
    if [ "$age" -gt "$COORD_WATCHDOG_DEDUPE_STALE_TTL" ]; then
      rm -f "$lock_file" 2>/dev/null
    fi
  fi

  # Atomic create-or-fail via noclobber redirection. The subshell
  # contains `set -C` so its scope doesn't pollute the caller. If the
  # lock_file already exists, the redirection fails inside the subshell
  # and the subshell exits non-zero — which is the function's return.
  local writer started_at
  writer="${SESSION_ID:-unknown}"
  started_at=$(_coord_watchdog_now_iso8601)
  ( set -C
    printf 'writer=%s\nstarted_at=%s\n' "$writer" "$started_at" \
      >"$lock_file"
  ) 2>/dev/null
}

# coord_watchdog_release_check_lock <target_session_id>
#   Best-effort release; always returns 0 (idempotent).
coord_watchdog_release_check_lock() {
  local target="$1"
  [ -z "$target" ] && return 0
  [ -z "${COORD_DIR:-}" ] && return 0
  local lock_dir lock_file
  lock_dir=$(_coord_watchdog_check_lock_dir)
  lock_file="${lock_dir}/${target}.lock"
  rm -f "$lock_file" 2>/dev/null || true
  return 0
}

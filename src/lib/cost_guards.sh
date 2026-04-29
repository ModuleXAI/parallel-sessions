#!/usr/bin/env bash
# cost_guards.sh — Phase 7 / T7.04 sliding-window rate-limit
# enforcement for real-claude spawn sites (PR-PHASE7-03 §"User-
# resolved decision" / OQ5 binding).
#
# Public API (PR-PHASE7-03 §"Implementation surface" verbatim):
#
#   coord_cost_guards_check <site>
#     Atomic check + append-on-allow within a single per-site
#     flock-held critical section. Returns rc=0 if the spawn is
#     allowed (counter appended); rc=1 if rate-limited (counter
#     NOT appended). Site ∈ {mediator, validator}. Emits
#     COST_GUARD_RATE_LIMITED event on rc=1; emits
#     COST_GUARD_COUNTER_RESET event on auto-prune that empties
#     a previously over-limit counter.
#
#   coord_cost_guards_status <site>
#     Read-only inspection. Prints "current_count=<N>
#     threshold=<T> window=<W> seconds_until_next_slot=<S>" on
#     stdout. No counter mutation. Pruning is performed during
#     read so the count reflects the current sliding window.
#
#   coord_cost_guards_clear <site>
#     Operator escape-hatch. Truncates the counter file under
#     flock; emits COST_GUARD_MANUAL_CLEAR event with prior_count.
#     Returns rc=0 always (idempotent — clearing an absent
#     counter is a no-op).
#
# Tunables (PR-PHASE7-03 §"Three tunables", env-overridable):
#   COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS  (default 300)
#   COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR         (default 12)
#   COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR             (default 120)
#
# Counter file format (per T7.04 user prompt):
#   Plain text, ms-precision Unix timestamps, one per line,
#   sorted ascending (oldest first). Pruned on every read.
#   Maximum size bounded by max_per_hour * 2 (conservative
#   buffer; pruning ensures we never grow unbounded).
#
# Storage:
#   $COORD_DIR/cost_guards/<site>.counter  (data; gitignored
#                                            via .coord/ blanket)
#   $COORD_DIR/cost_guards/<site>.lock     (per-site flock)
#
# Audit events (PR-PHASE7-03 §"Audit event TTL reset" + §"Block
# path"):
#   COST_GUARD_RATE_LIMITED  — site, count, limit, window,
#                                reset_at_ms (oldest_ts + window)
#   COST_GUARD_COUNTER_RESET — site, prior_count, reset_method
#                                (auto_prune | corrupt | manual)
#   COST_GUARD_MANUAL_CLEAR  — site, prior_count
#
# Fail-open semantics (PR-PHASE7-03 §"Hard block vs graceful
# degrade"; cost guard is rate limit, not security gate):
#   - Counter file unreadable / corrupt → reset to empty + emit
#     COUNTER_RESET event + allow spawn.
#   - flock acquisition timeout (5s default) → log warning +
#     allow spawn.
#   - Atomic write failure → log warning + allow spawn.
#
# §A.13 lesson application:
#   - #5 if var=$(cmd); then ... fi: flock-held subshell rc
#     captured via the if-form to avoid set-e + pipefail trap.
#   - #6 event-emission audit per return path: every rc=0/rc=1
#     path under flock emits at most one of {RATE_LIMITED,
#     COUNTER_RESET}; clear emits MANUAL_CLEAR.
#   - #7 Bash 3.2 parser: temp-file inter-subshell comms
#     (mirrors lib/wait_queue.sh pattern); avoid
#     `out=$( ( cmd ) 9>"lock" )` form.
#   - #11 multi-assign local + set -u: every `local` declares
#     exactly one variable.
#   - #14 N/A (env-var via bash ${var:-}, no jq has()).
#
# Mode interlock is OUT OF SCOPE for T7.04 — T7.05 spawn-site
# integration calls coord_cost_guards_check only when
# coord_spawn_helper_should_use_real_claude returns rc=0
# (mock mode bypass at the call site, not in this lib).

set -euo pipefail

# Tunables ---------------------------------------------------------

: "${COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS:=300}"
: "${COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR:=12}"
: "${COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR:=120}"
: "${COORD_COST_GUARDS_FLOCK_TIMEOUT:=5}"

# Constants
_COORD_CG_WINDOW_HOUR_MS=3600000
_COORD_CG_WINDOW_MIN_INTERVAL_LABEL=min_interval

# Internal helpers -------------------------------------------------

_coord_cg_warn() {
  printf 'coord cost_guards: %s\n' "$*" >&2
}

# _coord_cg_now_ms — ms-precision Unix epoch via Time::HiRes; falls
# back to second precision via date.
_coord_cg_now_ms() {
  local ms
  if ms=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null); then
    case "$ms" in
      ''|*[!0-9]*) ms="" ;;
    esac
  else
    ms=""
  fi
  if [ -z "$ms" ]; then
    local sec
    sec=$(date +%s 2>/dev/null) || sec=0
    ms="${sec}000"
  fi
  printf '%s' "$ms"
}

# _coord_cg_paths <site> — print counter + lock paths on two lines.
# Validates site against the enumerated allow-list.
_coord_cg_paths() {
  local site="${1:-}"
  case "$site" in
    mediator|validator|task_processor) ;;
    *)
      _coord_cg_warn "unknown site: $site"
      return 1
      ;;
  esac
  local coord_dir="${COORD_DIR:-}"
  if [ -z "$coord_dir" ]; then
    _coord_cg_warn "COORD_DIR unset"
    return 1
  fi
  local dir="${coord_dir}/cost_guards"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || {
      _coord_cg_warn "cannot create $dir"
      return 1
    }
  fi
  printf '%s\n%s\n' \
    "${dir}/${site}.counter" \
    "${dir}/${site}.lock"
}

# _coord_cg_thresholds <site> — print "max_per_hour|min_interval_sec"
# (min_interval_sec=0 if not applicable).
_coord_cg_thresholds() {
  local site="${1:-}"
  case "$site" in
    mediator)
      printf '%s|%s\n' \
        "$COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR" \
        "$COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS"
      ;;
    validator)
      printf '%s|%s\n' \
        "$COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR" \
        "0"
      ;;
    task_processor)
      # Reserved per PR-PHASE7-03 §"Task Processor"; unset →
      # always-allow. max=0 sentinel = disabled.
      printf '%s|%s\n' "0" "0"
      ;;
    *)
      return 1
      ;;
  esac
}

# _coord_cg_prune_inplace <counter_file> <now_ms> — drop entries
# older than (now_ms - WINDOW_HOUR_MS) by rewriting the file in
# place. Stdout: prior_count|new_count (pipe-separated).
# Used INSIDE the flock-held critical section.
_coord_cg_prune_inplace() {
  local counter="$1"
  local now_ms="$2"
  local cutoff=$(( now_ms - _COORD_CG_WINDOW_HOUR_MS ))
  if [ ! -e "$counter" ]; then
    printf '0|0\n'
    return 0
  fi
  local prior new
  prior=$(wc -l <"$counter" 2>/dev/null | tr -d ' ')
  case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  # Rewrite counter retaining only rows with ts >= cutoff. Each
  # line must be a pure positive integer; non-numeric lines are
  # discarded as corruption (fail-soft).
  local tmp="${counter}.prune.$$"
  awk -v cutoff="$cutoff" '
    /^[0-9]+$/ { if ($0+0 >= cutoff) print $0 }
  ' "$counter" >"$tmp" 2>/dev/null || {
    : >"$tmp"
  }
  mv -f "$tmp" "$counter" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
  }
  new=$(wc -l <"$counter" 2>/dev/null | tr -d ' ')
  case "$new" in ''|*[!0-9]*) new=0 ;; esac
  printf '%s|%s\n' "$prior" "$new"
}

# Public: coord_cost_guards_check ----------------------------------

# coord_cost_guards_check <site>
#   Atomic check+append-on-allow under per-site flock.
#   rc=0 allow (counter appended) / rc=1 rate_limited.
coord_cost_guards_check() {
  local site="${1:-}"
  local thresholds_line
  if ! thresholds_line=$(_coord_cg_thresholds "$site" 2>/dev/null); then
    _coord_cg_warn "thresholds lookup failed for site=$site"
    return 0  # fail-open: unknown site allows
  fi
  local max_per_hour="${thresholds_line%|*}"
  local min_interval_sec="${thresholds_line#*|}"
  if [ "$max_per_hour" = "0" ]; then
    # Unset / disabled (e.g., task_processor reserved); allow.
    return 0
  fi

  local paths
  if ! paths=$(_coord_cg_paths "$site" 2>/dev/null); then
    return 0  # fail-open: COORD_DIR unset etc.
  fi
  local counter_file lock_file
  counter_file=$(printf '%s' "$paths" | sed -n '1p')
  lock_file=$(printf '%s' "$paths" | sed -n '2p')

  # Ensure lock file exists before flock (F-003 portable contract).
  [ -e "$lock_file" ] || : >"$lock_file"

  # Per-site flock. Use temp-file inter-subshell comms (Lesson #7).
  # Subshell exit codes:
  #   0 → allow (counter appended)
  #   1 → rate_limited (counter NOT appended)
  #   2 → flock acquisition timeout
  #   3 → fail-open path (corruption / write failure)
  local now_ms
  now_ms=$(_coord_cg_now_ms)
  local out_tmp="${counter_file}.check.$$"
  : >"$out_tmp"

  (
    flock -x -w "$COORD_COST_GUARDS_FLOCK_TIMEOUT" 9 || exit 2

    # Prune within critical section (sliding window pruning).
    local prune_line prior new
    prune_line=$(_coord_cg_prune_inplace "$counter_file" "$now_ms")
    prior="${prune_line%|*}"
    new="${prune_line#*|}"

    # Auto-COUNTER_RESET event when prune reduced over-limit
    # counter back into bounds.
    if [ "$prior" -gt "$max_per_hour" ] && [ "$new" -le "$max_per_hour" ]; then
      printf 'reset_auto|%s\n' "$prior" >"$out_tmp"
    fi

    # Min-interval check (Mediator only; min_interval_sec>0).
    if [ "$min_interval_sec" -gt 0 ] && [ "$new" -gt 0 ]; then
      local last_ms diff_ms diff_sec
      last_ms=$(tail -n 1 "$counter_file" 2>/dev/null)
      case "$last_ms" in ''|*[!0-9]*) last_ms=0 ;; esac
      diff_ms=$(( now_ms - last_ms ))
      diff_sec=$(( diff_ms / 1000 ))
      if [ "$diff_sec" -lt "$min_interval_sec" ]; then
        # Rate-limited via min-interval. Compute reset_at_ms.
        local reset_at_ms=$(( last_ms + (min_interval_sec * 1000) ))
        printf 'rate_limited|%s|%s|%s|%s\n' \
          "$new" "$max_per_hour" "$_COORD_CG_WINDOW_MIN_INTERVAL_LABEL" \
          "$reset_at_ms" >>"$out_tmp"
        exit 1
      fi
    fi

    # Per-hour cap check.
    if [ "$new" -ge "$max_per_hour" ]; then
      # Compute reset_at_ms from oldest entry + 1 hour.
      local oldest_ms=0
      if [ -s "$counter_file" ]; then
        oldest_ms=$(head -n 1 "$counter_file" 2>/dev/null)
        case "$oldest_ms" in ''|*[!0-9]*) oldest_ms=0 ;; esac
      fi
      local reset_at_ms=$(( oldest_ms + _COORD_CG_WINDOW_HOUR_MS ))
      printf 'rate_limited|%s|%s|%s|%s\n' \
        "$new" "$max_per_hour" "hour" "$reset_at_ms" >>"$out_tmp"
      exit 1
    fi

    # Allow path: append now_ms to counter.
    printf '%s\n' "$now_ms" >>"$counter_file" 2>/dev/null || exit 3
    exit 0
  ) 9>"$lock_file"
  local subshell_rc=$?

  local out_text=""
  if [ -s "$out_tmp" ]; then
    out_text=$(cat "$out_tmp" 2>/dev/null)
  fi
  rm -f "$out_tmp" 2>/dev/null

  # Auto COUNTER_RESET event (if prune reduced over-limit).
  local reset_line
  reset_line=$(printf '%s\n' "$out_text" | grep '^reset_auto|' 2>/dev/null | head -n 1)
  if [ -n "$reset_line" ]; then
    local prior_count="${reset_line#reset_auto|}"
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=COST_GUARD_COUNTER_RESET \
        site="$site" prior_count="$prior_count" \
        reset_method=auto_prune 2>/dev/null || true
    fi
  fi

  case "$subshell_rc" in
    0)
      return 0
      ;;
    1)
      # rate_limited|count|limit|window_label|reset_at_ms
      local rl_line
      rl_line=$(printf '%s\n' "$out_text" | grep '^rate_limited|' 2>/dev/null | head -n 1)
      local rl_count rl_limit rl_window rl_reset
      rl_count=$(printf '%s' "$rl_line" | awk -F'|' '{print $2}')
      rl_limit=$(printf '%s' "$rl_line" | awk -F'|' '{print $3}')
      rl_window=$(printf '%s' "$rl_line" | awk -F'|' '{print $4}')
      rl_reset=$(printf '%s' "$rl_line" | awk -F'|' '{print $5}')
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=COST_GUARD_RATE_LIMITED \
          site="$site" count="$rl_count" limit="$rl_limit" \
          window="$rl_window" reset_at_ms="$rl_reset" \
          2>/dev/null || true
      fi
      return 1
      ;;
    2)
      _coord_cg_warn "flock timeout for site=$site; allowing (fail-open)"
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=COST_GUARD_FLOCK_TIMEOUT \
          site="$site" timeout_sec="$COORD_COST_GUARDS_FLOCK_TIMEOUT" \
          2>/dev/null || true
      fi
      return 0  # fail-open
      ;;
    3|*)
      _coord_cg_warn "write failure for site=$site; allowing (fail-open)"
      if command -v coord_log_event >/dev/null 2>&1; then
        coord_log_event kind=COST_GUARD_WRITE_FAILED \
          site="$site" 2>/dev/null || true
      fi
      return 0  # fail-open
      ;;
  esac
}

# Public: coord_cost_guards_status ---------------------------------

# coord_cost_guards_status <site>
#   Read-only inspection. Prints
#   "current_count=<N> threshold=<T> window=<W>
#    seconds_until_next_slot=<S>"
#   on stdout. No counter mutation (pruning here writes back the
#   pruned file but does NOT add new entries — semantically still
#   read-only WRT cost-guard semantics).
coord_cost_guards_status() {
  local site="${1:-}"
  local thresholds_line
  if ! thresholds_line=$(_coord_cg_thresholds "$site" 2>/dev/null); then
    return 1
  fi
  local max_per_hour="${thresholds_line%|*}"
  local paths
  if ! paths=$(_coord_cg_paths "$site" 2>/dev/null); then
    return 1
  fi
  local counter_file lock_file
  counter_file=$(printf '%s' "$paths" | sed -n '1p')
  lock_file=$(printf '%s' "$paths" | sed -n '2p')
  [ -e "$lock_file" ] || : >"$lock_file"

  local now_ms
  now_ms=$(_coord_cg_now_ms)
  local out_tmp="${counter_file}.status.$$"
  : >"$out_tmp"

  (
    flock -x -w "$COORD_COST_GUARDS_FLOCK_TIMEOUT" 9 || exit 2
    local prune_line new oldest_ms
    prune_line=$(_coord_cg_prune_inplace "$counter_file" "$now_ms")
    new="${prune_line#*|}"
    oldest_ms=0
    if [ -s "$counter_file" ]; then
      oldest_ms=$(head -n 1 "$counter_file" 2>/dev/null)
      case "$oldest_ms" in ''|*[!0-9]*) oldest_ms=0 ;; esac
    fi
    printf '%s|%s\n' "$new" "$oldest_ms" >"$out_tmp"
    exit 0
  ) 9>"$lock_file"
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp" 2>/dev/null
    return 1
  fi

  local payload
  payload=$(cat "$out_tmp" 2>/dev/null)
  rm -f "$out_tmp" 2>/dev/null
  local count="${payload%|*}"
  local oldest_ms="${payload#*|}"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$oldest_ms" in ''|*[!0-9]*) oldest_ms=0 ;; esac

  local seconds_until=0
  if [ "$count" -ge "$max_per_hour" ] && [ "$max_per_hour" -gt 0 ] && [ "$oldest_ms" -gt 0 ]; then
    local reset_at=$(( oldest_ms + _COORD_CG_WINDOW_HOUR_MS ))
    local diff_ms=$(( reset_at - now_ms ))
    if [ "$diff_ms" -lt 0 ]; then
      seconds_until=0
    else
      seconds_until=$(( diff_ms / 1000 ))
    fi
  fi

  printf 'current_count=%s threshold=%s window=hour seconds_until_next_slot=%s\n' \
    "$count" "$max_per_hour" "$seconds_until"
  return 0
}

# Public: coord_cost_guards_clear ----------------------------------

# coord_cost_guards_clear <site>
#   Operator escape-hatch. Truncates the counter file under flock;
#   emits COST_GUARD_MANUAL_CLEAR event with prior_count.
#   rc=0 always (idempotent — clearing an absent counter is a
#   no-op).
coord_cost_guards_clear() {
  local site="${1:-}"
  local paths
  if ! paths=$(_coord_cg_paths "$site" 2>/dev/null); then
    return 0
  fi
  local counter_file lock_file
  counter_file=$(printf '%s' "$paths" | sed -n '1p')
  lock_file=$(printf '%s' "$paths" | sed -n '2p')
  [ -e "$lock_file" ] || : >"$lock_file"

  local out_tmp="${counter_file}.clear.$$"
  : >"$out_tmp"

  (
    flock -x -w "$COORD_COST_GUARDS_FLOCK_TIMEOUT" 9 || exit 2
    local prior=0
    if [ -e "$counter_file" ]; then
      prior=$(wc -l <"$counter_file" 2>/dev/null | tr -d ' ')
      case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
    fi
    printf '%s\n' "$prior" >"$out_tmp"
    : >"$counter_file" 2>/dev/null || exit 3
    exit 0
  ) 9>"$lock_file"
  local rc=$?

  local prior=0
  if [ -s "$out_tmp" ]; then
    prior=$(cat "$out_tmp" 2>/dev/null)
    case "$prior" in ''|*[!0-9]*) prior=0 ;; esac
  fi
  rm -f "$out_tmp" 2>/dev/null

  if [ "$rc" -eq 0 ]; then
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=COST_GUARD_MANUAL_CLEAR \
        site="$site" prior_count="$prior" 2>/dev/null || true
    fi
  fi
  return 0
}

# CLI shim for bats / ad-hoc:
#   cost_guards.sh check <site>    → rc 0 allow / rc 1 rate-limited
#   cost_guards.sh status <site>   → stdout payload
#   cost_guards.sh clear <site>    → rc 0 always
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    check)
      if coord_cost_guards_check "${2:-}"; then exit 0; else exit 1; fi
      ;;
    status)
      coord_cost_guards_status "${2:-}"
      ;;
    clear)
      coord_cost_guards_clear "${2:-}"
      ;;
    *)
      printf 'usage: cost_guards.sh check|status|clear <site>\n' >&2
      exit 2
      ;;
  esac
fi

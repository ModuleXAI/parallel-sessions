#!/usr/bin/env bash
# watchdog.sh — Phase 3 / T3.05 peer-watchdog probe + verdict logic.
#
# Per PR-PHASE3-02 (Decision 2): the watchdog is the Mediator's
# lightweight pre-filter. It NEVER decides eviction itself — it triages
# ambient suspicion about ANOTHER session and either:
#   (alive)     no-op, cache the verdict, return.
#   (dead)      cache + emit a Mediator-pending entry; Mediator decides.
#   (uncertain) cache + emit a pending entry with uncertain flag.
#
# T3.04 supplied the storage primitives (recent_checks.jsonl cache +
# .coord/watchdog/checking/<target>.lock dedupe). T3.05 supplies:
#   1. Probe heuristics (PID/lstart liveness + activity/lock timing)
#   2. Verdict computation
#   3. Ambient-suspicion scanner (called from pre_tool_use_any.sh)
#   4. Pending-entry emission via the existing T2.04 producer.
#
# Public functions:
#   coord_watchdog_probe <target_session_id>
#       Full probe orchestrator. Cache check → dedupe → signals →
#       verdict → cache record → optional pending emit. Caller is
#       fire-and-forget (`coord_watchdog_probe X &`); rc is informational
#       only (0 on completion, 1 on dedupe-skipped or COORD_DIR missing).
#       Stdout: "<verdict>\t<reason>" on completion; empty on skip.
#
#   coord_watchdog_check_ambient_suspicion
#       Scans sessions.json for OTHER-session anomalies and prints one
#       target_session_id per line. Caller (pre_tool_use_any.sh) iterates
#       and fires off watchdog probes in the background. Triggers (per
#       PR-PHASE3-02 dispositioned thresholds):
#         - last_activity_at > COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC
#         - any lock with last_refresh_at == acquired_at AND
#           acquired_at age > COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC
#         - PID listed in sessions.json but `ps -p` returns empty
#           (cheap drive-by check; subsequent probe confirms)
#       Self is filtered out (a session never probes itself).
#
# Verdict-to-pending mapping:
#   verdict=dead, sub=pid_gone     → kind=stale_active   source=watchdog
#   verdict=dead, sub=pid_recycled → kind=pid_recycled  source=watchdog
#   verdict=uncertain              → kind=stale_active  source=watchdog
#                                    payload.uncertain=true
#   verdict=alive                  → no pending entry
#
# Hook-latency budget: ambient-suspicion check is single jq pass over
# sessions.json + small recent_checks scan. Probe itself is BACKGROUNDED
# by the caller, so its execution time does not count against the hook.
#
# Bash 3.2 compat. No `set -euo pipefail` (sourced; caller governs).

# Config tunables (env-overridable; T3.07 surfaces formal config.json
# entries via PR-PHASE3-02 §C).
: "${COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC:=600}"     # 10 min
: "${COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC:=1800}" # 30 min
: "${COORD_WATCHDOG_TTL_ALIVE_SEC:=60}"
: "${COORD_WATCHDOG_TTL_UNCERTAIN_SEC:=30}"
: "${COORD_WATCHDOG_TTL_DEAD_SEC:=31536000}"

# _coord_watchdog_iso8601_to_epoch <iso>
#   Same conversion as watchdog_cache.sh's helper but redeclared so
#   watchdog.sh doesn't strictly require watchdog_cache.sh to be
#   sourced first. (In practice both are sourced together in the
#   hook.)
_coord_watchdog_iso8601_to_epoch() {
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

# _coord_watchdog_ps_lstart <pid>
#   Portable wrapper around `ps -p <pid> -o lstart=`. Returns the
#   trimmed lstart string on stdout, or empty if the PID is gone /
#   ps fails. Both BSD (macOS) and GNU (Linux) ps support `-o lstart=`
#   per Phase 0 Experiment #1; we trim the leading-space alignment
#   identically to lib/session_start.sh's PID_LSTART capture.
_coord_watchdog_ps_lstart() {
  local pid="$1"
  [ -z "$pid" ] && return 0   # never fail the caller (set -o pipefail safe)
  # `ps -p <gone>` returns rc=1 with empty stdout. Under callers using
  # `set -o pipefail`, the rc=1 in this pipeline would propagate and
  # kill the caller; capture into a var first so the function's
  # exit status is the trailing `printf` (always 0).
  local raw
  raw=$(ps -p "$pid" -o lstart= 2>/dev/null) || raw=""
  printf '%s' "$raw" | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n'
}

# coord_watchdog_probe <target_session_id>
#   Full orchestrator. Caller backgrounds this (`coord_watchdog_probe X &`)
#   and never blocks on it.
#   Returns 0 on completed probe (verdict computed + cached). Returns 1
#   on dedupe-skipped (another invoker is already running) or
#   COORD_DIR missing (no work possible).
coord_watchdog_probe() {
  local target="$1"
  [ -z "$target" ] && return 1
  [ -z "${COORD_DIR:-}" ] && return 1
  local state="$COORD_DIR/sessions.json"
  [ -f "$state" ] || return 1

  # 1. Cache check — if we have a non-expired verdict, surface it and
  # exit. Saves a probe round-trip when 5+ sessions notice the same
  # anomaly within 60s of the last verdict.
  local cached
  cached=$(coord_watchdog_cache_lookup "$target" 2>/dev/null) || cached=""
  if [ -n "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi

  # 2. Dedupe lock — only one watchdog runs per target at a time.
  if ! coord_watchdog_acquire_check_lock "$target"; then
    return 1
  fi

  # Helper: release dedupe lock unconditionally on every return path.
  _watchdog_release() {
    coord_watchdog_release_check_lock "$target" 2>/dev/null || true
  }

  # 3. Read target's session record.
  local row pid pid_lstart last_activity
  row=$(jq -c --arg sid "$target" '.sessions[$sid] // null' "$state" 2>/dev/null) || row="null"
  if [ "$row" = "null" ]; then
    # Target session not registered — degenerate input; no probe possible.
    coord_watchdog_cache_record "$target" "uncertain" \
      "no session record" "$COORD_WATCHDOG_TTL_UNCERTAIN_SEC" 2>/dev/null
    _watchdog_release
    printf 'uncertain\tno session record\n'
    return 0
  fi
  pid=$(printf '%s' "$row" | jq -r '.pid // ""' 2>/dev/null)
  pid_lstart=$(printf '%s' "$row" | jq -r '.pid_lstart // ""' 2>/dev/null)
  last_activity=$(printf '%s' "$row" | jq -r '.last_activity_at // ""' 2>/dev/null)

  # 4. Signal 1 — PID/lstart liveness (deterministic).
  local sig1_dead="" sig1_subkind=""
  if [ -z "$pid" ] || [ "$pid" = "null" ] || [ "$pid" = "0" ]; then
    sig1_dead="1"
    sig1_subkind="pid_gone"
  else
    local current_lstart
    current_lstart=$(_coord_watchdog_ps_lstart "$pid")
    if [ -z "$current_lstart" ]; then
      sig1_dead="1"
      sig1_subkind="pid_gone"
    elif [ -n "$pid_lstart" ] && [ "$current_lstart" != "$pid_lstart" ]; then
      sig1_dead="1"
      sig1_subkind="pid_recycled"
    fi
  fi

  # 5. Signal 2 — last_activity_at age.
  local sig2_suspicious=""
  if [ -n "$last_activity" ] && [ "$last_activity" != "null" ]; then
    local last_epoch now activity_age
    last_epoch=$(_coord_watchdog_iso8601_to_epoch "$last_activity")
    now=$(date -u +%s 2>/dev/null || printf '0')
    activity_age=$(( now - last_epoch ))
    if [ "$activity_age" -gt "$COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC" ]; then
      sig2_suspicious="1"
    fi
  fi

  # 6. Signal 3 — lock acquired but never refreshed past threshold.
  local sig3_suspicious="" sig3_file=""
  local lock_tsv
  lock_tsv=$(jq -r --arg sid "$target" '
    .locks
    | to_entries[]
    | select(.value.session == $sid)
    | [.key, (.value.acquired_at // ""), (.value.last_refresh_at // "")]
    | @tsv
  ' "$state" 2>/dev/null || printf '')
  if [ -n "$lock_tsv" ]; then
    local OLD_IFS="$IFS"
    IFS='
'
    set -- $lock_tsv
    IFS="$OLD_IFS"
    local entry path acq_iso ref_iso
    for entry in "$@"; do
      path=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
      acq_iso=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
      ref_iso=$(printf '%s' "$entry" | awk -F'\t' '{print $3}')
      [ -z "$acq_iso" ] && continue
      if [ "$acq_iso" = "$ref_iso" ]; then
        local acq_epoch lock_age
        acq_epoch=$(_coord_watchdog_iso8601_to_epoch "$acq_iso")
        local now2; now2=$(date -u +%s 2>/dev/null || printf '0')
        lock_age=$(( now2 - acq_epoch ))
        if [ "$lock_age" -gt "$COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC" ]; then
          sig3_suspicious="1"
          sig3_file="$path"
          break
        fi
      fi
    done
  fi

  # 7. Verdict computation.
  #    - dead requires Signal 1 confirmation; subkind drives pending kind.
  #    - alive requires Signal 1 confirms-alive AND no Signal 2/3.
  #    - uncertain when Signal 1 is alive but Signal 2 or 3 fires
  #      (suspicion without deterministic dead confirmation).
  local verdict reason ttl pending_kind pending_uncertain=""
  if [ -n "$sig1_dead" ]; then
    verdict="dead"
    if [ "$sig1_subkind" = "pid_recycled" ]; then
      reason="PID $pid recycled (lstart mismatch: stored=$pid_lstart current=$(_coord_watchdog_ps_lstart "$pid"))"
      pending_kind="pid_recycled"
    else
      reason="PID $pid is gone (no ps record)"
      pending_kind="stale_active"
    fi
    ttl="$COORD_WATCHDOG_TTL_DEAD_SEC"
  elif [ -n "$sig2_suspicious" ] || [ -n "$sig3_suspicious" ]; then
    verdict="uncertain"
    if [ -n "$sig3_suspicious" ]; then
      reason="lock $sig3_file held > ${COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC}s without refresh"
    else
      reason="last_activity > ${COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC}s but PID still alive"
    fi
    ttl="$COORD_WATCHDOG_TTL_UNCERTAIN_SEC"
    pending_kind="stale_active"
    pending_uncertain="1"
  else
    verdict="alive"
    reason="PID $pid alive; activity recent; locks healthy"
    ttl="$COORD_WATCHDOG_TTL_ALIVE_SEC"
    pending_kind=""   # alive emits no pending entry
  fi

  # 8. Cache record.
  coord_watchdog_cache_record "$target" "$verdict" "$reason" "$ttl" 2>/dev/null || true

  # 9. Mediator pending emit (dead + uncertain only). Uses existing
  # T2.04 producer per user direction "existing helpers are sufficient."
  if [ -n "$pending_kind" ]; then
    if command -v coord_mediator_emit_pending >/dev/null 2>&1; then
      if [ -n "$pending_uncertain" ]; then
        coord_mediator_emit_pending "$pending_kind" \
          source=watchdog target="$target" verdict="$verdict" \
          reason="$reason" uncertain=true 2>/dev/null || true
      else
        coord_mediator_emit_pending "$pending_kind" \
          source=watchdog target="$target" verdict="$verdict" \
          reason="$reason" subkind="$sig1_subkind" 2>/dev/null || true
      fi
    fi
    if command -v coord_log_event >/dev/null 2>&1; then
      coord_log_event kind=WATCHDOG_ESCALATED_TO_MEDIATOR \
        target="$target" verdict="$verdict" \
        mediator_pending_kind="$pending_kind" 2>/dev/null || true
    fi
  fi

  # 10. WATCHDOG_PROBED audit event regardless of verdict.
  if command -v coord_log_event >/dev/null 2>&1; then
    coord_log_event kind=WATCHDOG_PROBED \
      target="$target" verdict="$verdict" reason="$reason" 2>/dev/null || true
  fi

  printf '%s\t%s\n' "$verdict" "$reason"
  _watchdog_release
  return 0
}

# coord_watchdog_check_ambient_suspicion
#   Scans sessions.json for sessions OTHER than $SESSION_ID that match
#   any ambient-suspicion trigger. Prints one target_session_id per
#   line on stdout. Caller iterates + backgrounds probes.
#
#   Cheap: single jq pass over sessions.json + per-PID `ps` checks
#   only for sessions that pass the activity/lock heuristics (so we
#   don't fork ps for every healthy session on every hook firing).
coord_watchdog_check_ambient_suspicion() {
  [ -z "${COORD_DIR:-}" ] && return 0
  local state="$COORD_DIR/sessions.json"
  [ -f "$state" ] || return 0
  local self="${SESSION_ID:-}"

  # Pass 1 (cheap): jq filter for sessions matching activity/lock
  # heuristics. Output: one TSV per suspect: sid<TAB>pid<TAB>reason
  local now
  now=$(date -u +%s 2>/dev/null || printf '0')
  local activity_threshold="$COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC"
  local lock_threshold="$COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC"

  # Activity-based suspects: last_activity_at older than threshold AND
  # session is not self. Compute via fromdateiso8601 in jq for
  # portability across macOS/Linux date formats.
  local act_suspects
  act_suspects=$(jq -r --arg self "$self" --argjson now "$now" \
                       --argjson thresh "$activity_threshold" '
    (.sessions // {})
    | to_entries[]
    | select(.key != $self)
    | select(.value.state == "ACTIVE")
    | select(.value.last_activity_at != null)
    | select((.value.last_activity_at | fromdateiso8601) < ($now - $thresh))
    | "\(.key)\t\(.value.pid // "")\tactivity_stale"
  ' "$state" 2>/dev/null || printf '')

  # Lock-based suspects: any lock owned by a non-self session whose
  # acquired_at == last_refresh_at AND acquired_at age > lock_threshold.
  local lock_suspects
  lock_suspects=$(jq -r --arg self "$self" --argjson now "$now" \
                        --argjson thresh "$lock_threshold" '
    (.locks // {})
    | to_entries[]
    | select(.value.session != $self)
    | select((.value.acquired_at // null) != null)
    | select(.value.acquired_at == .value.last_refresh_at)
    | select((.value.acquired_at | fromdateiso8601) < ($now - $thresh))
    | "\(.value.session)\t\(.value.pid // "")\tlock_stale_\(.key)"
  ' "$state" 2>/dev/null || printf '')

  # PID-gone suspects: cheap drive-by — for each ACTIVE non-self
  # session, if pid is set AND ps returns empty, flag it. We bound
  # this by only checking sessions that aren't already flagged above
  # to avoid double-work + fork-bomb risk on huge session counts.
  local pid_check_input
  pid_check_input=$(jq -r --arg self "$self" '
    (.sessions // {})
    | to_entries[]
    | select(.key != $self)
    | select(.value.state == "ACTIVE")
    | select((.value.pid // 0) > 0)
    | "\(.key)\t\(.value.pid)"
  ' "$state" 2>/dev/null || printf '')

  local pid_gone_suspects=""
  if [ -n "$pid_check_input" ]; then
    local OLD_IFS="$IFS"
    IFS='
'
    set -- $pid_check_input
    IFS="$OLD_IFS"
    local entry sid pid lstart_check
    for entry in "$@"; do
      sid=$(printf '%s' "$entry" | awk -F'\t' '{print $1}')
      pid=$(printf '%s' "$entry" | awk -F'\t' '{print $2}')
      [ -z "$sid" ] || [ -z "$pid" ] && continue
      lstart_check=$(_coord_watchdog_ps_lstart "$pid")
      if [ -z "$lstart_check" ]; then
        pid_gone_suspects="${pid_gone_suspects}${sid}"$'\t'"${pid}"$'\t'"pid_gone"$'\n'
      fi
    done
  fi

  # Merge + dedupe by session_id (a session may match multiple
  # triggers; we only need to fire one probe per target).
  printf '%s\n%s\n%s\n' "$act_suspects" "$lock_suspects" "$pid_gone_suspects" \
    | awk -F'\t' 'NF >= 1 && $1 != "" && !seen[$1]++ {print $1}'
}

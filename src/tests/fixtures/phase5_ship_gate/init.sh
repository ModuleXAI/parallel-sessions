#!/usr/bin/env bash
# init.sh — create an isolated workspace for phase5_ship_gate fixtures.
#
# Mirrors phase4_ship_gate/init.sh with Phase 5 additions:
#   - wait_queues/ and wakers/ directories created by install.sh
#   - cycle_detection.sh + wait_queue.sh + wait_backend.sh +
#     notify_waiters.sh sourced by callers
#   - mock claude binary still scripts validator + Mediator (Phase 4
#     pattern) — Phase 5 cycle_detected verdicts are Mediator
#     surgical_fix per PR-PHASE5-04 (existing 3-action contract;
#     no new mock dispatch required).
#
# Usage:
#   . init.sh                 # sourced by driver; sets WORKDIR + COORD_DIR

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"

coord_fixture_init() {
  WORKDIR="$(mktemp -d -t coord-fixture-p5sg-XXXX)"

  (
    cd "$WORKDIR"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'placeholder for fixture init commit\n' >.fixture-seed
    git add .fixture-seed
    git commit -q -m "fixture: initial seed" 2>/dev/null
  )

  ( cd "$WORKDIR" && "$SRC_ROOT/install.sh" --yes --repair >/dev/null )

  # Force polling backend so the fixture is deterministic across hosts
  # (some CI may have inotifywait but timing assertions assume polling
  # cadence to keep latency budgets host-independent).
  jq '.wait_backend = "polling"' "$WORKDIR/.coord/config.json" \
    >"$WORKDIR/.coord/config.json.tmp" \
    && mv "$WORKDIR/.coord/config.json.tmp" "$WORKDIR/.coord/config.json"

  # Default fake claude binary — same dispatch as Phase 4 (validator
  # + Mediator). Phase 5 scenarios use this for cycle_detected
  # Mediator surgical_fix outputs (action_type=surgical_fix +
  # actions=[{verb:evict_session,session_id:<chosen>}] via
  # MOCK_MEDIATOR_ACTION + MOCK_MEDIATOR_EVICT_SID env vars).
  mkdir -p "$WORKDIR/bin"
  cat >"$WORKDIR/bin/claude" <<'CLAUDE_DEFAULT'
#!/usr/bin/env bash
set -e
if [ -n "${CLAUDE_CODE_VALIDATOR:-}" ]; then
  vdir="${COORD_DIR}/validator/verdict"
  mkdir -p "$vdir"
  ts="$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
  v="${MOCK_VALIDATOR_VERDICT:-SAFE}"
  ds="No semantic change."
  [ "$v" = "MINOR" ] && ds="${MOCK_VALIDATOR_DIFF_SUMMARY:-Variable rename inside function. No caller impact.}"
  [ "$v" = "CRITICAL" ] && ds="Function signature changed. Callers will break."
  jq -n \
    --arg ts "$ts" --arg v "$v" --arg ds "$ds" \
    --arg sid "${MOCK_CALLER_SID:-fixture-caller}" \
    --arg file "${MOCK_FILE:-/tmp/x}" \
    '{verdict_id:"fixture-validator-uuid", ts:$ts, for_pending_entry:null,
      validator_session_id:"placeholder",
      file:$file, session:$sid, verdict:$v,
      reasoning:"Fixture mock validator reasoning.", diff_summary:$ds,
      spawn_metadata:{duration_ms:0,model:"claude-haiku-4-5-20251001",spawn_mode:"no_bare"}}' \
    >"$vdir/${ts}.json"
  printf '%s\n' "{\"type\":\"result\",\"is_error\":false,\"session_id\":\"validator-spawn-${v}\",\"total_cost_usd\":0.05,\"duration_ms\":50,\"result\":\"verdict written\"}"
  exit 0
fi
if [ -n "${CLAUDE_CODE_MEDIATOR:-}" ]; then
  vdir="${COORD_DIR}/mediator/verdict"
  mkdir -p "$vdir"
  ts="$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
  action="${MOCK_MEDIATOR_ACTION:-advice}"
  msg="Mediator inline advice for fixture test."
  [ "$action" = "surgical_fix" ] && msg="Mediator applied surgical_fix; cycle resolved."
  [ "$action" = "lockdown" ] && msg="Mediator triggered lockdown; system paused."
  actions="[]"
  evict_sid="${MOCK_MEDIATOR_EVICT_SID:-}"
  if [ "$action" = "surgical_fix" ] && [ -n "$evict_sid" ]; then
    actions="[{\"verb\":\"evict_session\",\"session_id\":\"${evict_sid}\"}]"
  elif [ "$action" = "surgical_fix" ]; then
    actions="[{\"op\":\"clear_read_set\",\"session\":\"${MOCK_CALLER_SID:-fixture-caller}\"}]"
  fi
  jq -nc \
    --arg ts "$ts" --arg action "$action" --arg msg "$msg" \
    --argjson actions "$actions" \
    '{verdict_id:"fixture-mediator-uuid", ts:$ts,
      for_pending_entry:"fixture-pending",
      mediator_session_id:"mediator-spawn", depth:1,
      action_type:$action,
      severity:(if $action == "surgical_fix" then "brief" else null end),
      confidence:"auto_apply",
      reasoning:"Fixture mock mediator reasoning.",
      actions:$actions,
      message_to_caller:$msg,
      message_to_others:null}' \
    >"$vdir/${ts}.json"
  printf '%s\n' "{\"type\":\"result\",\"is_error\":false,\"session_id\":\"mediator-spawn\",\"total_cost_usd\":0.10,\"duration_ms\":100,\"result\":\"mediator verdict written\"}"
  exit 0
fi
printf '%s\n' '{"type":"result","is_error":true,"errors":["unknown spawn context"],"session_id":"err","total_cost_usd":0,"duration_ms":10,"result":""}'
CLAUDE_DEFAULT
  chmod +x "$WORKDIR/bin/claude"

  # Seed files used by scenarios.
  printf 'export const foo = "v1";\n' >"$WORKDIR/foo.ts"
  printf 'export const bar = "v1";\n' >"$WORKDIR/bar.ts"
  printf 'export const baz = "v1";\n' >"$WORKDIR/baz.ts"

  COORD_DIR="$WORKDIR/.coord"
  export WORKDIR COORD_DIR SRC_ROOT
  export PATH="$WORKDIR/bin:$PATH"

  # Source Phase 5 libs once per fixture so scenarios can call the
  # public API directly (coord_wait_queue_enqueue,
  # coord_notify_lock_release_waiters, coord_cycle_detect, etc.).
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/hash.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/wait_backend.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/cycle_detection.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/validator_cache.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/validator_prefilter.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/read_snapshots.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/notify_waiters.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/mediator_pending.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/mediator_spawn.sh"
}

# Helper: register a session row in sessions.json + .active marker.
coord_fixture_p5_register_session() {
  local sid="$1"
  touch "$COORD_DIR/sessions/${sid}.active"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
       registered_at: "y", last_activity_at: $now, git_head: "", prompt_id: null,
       script_version: "1.0"})' \
    --arg sid "$sid" --arg now "$(coord_now_iso8601)"
}

# Helper: synthetic lock acquisition (bypassing the full Phase 4
# pipeline; scenario controls the lock state directly).
coord_fixture_p5_acquire() {
  local file="$1" sid="$2" vts="${3:-}"
  if [ -z "$vts" ]; then
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f] = {session: $sid, acquired_at: $now, last_refresh_at: $now,
                     tasks: [], latest_validator_verdict_ts: null}' \
      --arg f "$file" --arg sid "$sid" --arg now "$(coord_now_iso8601)"
  else
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f] = {session: $sid, acquired_at: $now, last_refresh_at: $now,
                     tasks: [], latest_validator_verdict_ts: $vts}' \
      --arg f "$file" --arg sid "$sid" --arg now "$(coord_now_iso8601)" \
      --arg vts "$vts"
  fi
}

# Helper: synthetic lock release (delete locks[file] + invoke
# notify_waiters with the captured verdict_ts).
coord_fixture_p5_release() {
  local file="$1" holder="$2"
  local vts
  vts=$(jq -r --arg f "$file" '.locks[$f].latest_validator_verdict_ts // ""' \
    "$COORD_DIR/sessions.json")
  [ "$vts" = "null" ] && vts=""
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    'del(.locks[$f])' --arg f "$file"
  coord_notify_lock_release_waiters "$holder" "$file" \
    "$(coord_now_iso8601)" "$(coord_now_iso8601)" "$vts"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_fixture_init
  printf '%s\n' "$WORKDIR"
fi

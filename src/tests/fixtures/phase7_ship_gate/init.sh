#!/usr/bin/env bash
# init.sh — create an isolated workspace for phase7_ship_gate
# fixtures. Phase 7 T7.11.
#
# Mirrors phase6_ship_gate/init.sh with Phase 7 additions:
#   - lib/spawn_helper.sh + lib/cost_guards.sh sourced
#   - cost-guard counter file path helper
#   - cost-guard tunable env-var defaults set conservatively
#     so scenarios can hit boundaries quickly
#
# Usage:
#   . init.sh                 # sourced by driver; sets WORKDIR + COORD_DIR

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"

coord_fixture_init() {
  WORKDIR="$(mktemp -d -t coord-fixture-p7sg-XXXX)"

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

  # Force polling backend (deterministic across hosts).
  jq '.wait_backend = "polling"' "$WORKDIR/.coord/config.json" \
    >"$WORKDIR/.coord/config.json.tmp" \
    && mv "$WORKDIR/.coord/config.json.tmp" "$WORKDIR/.coord/config.json"

  # Default fake claude binary (Phase 4-5-6 dispatch carry-forward).
  # Phase 7 mode-routing is verified at the spawn_helper layer
  # via COORD_TEST_MODE; the underlying claude invocation still
  # hits this PATH-injected fake for repeatability per OQ4
  # binding (real-claude verification reserved for stress
  # scripts T7.08).
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
  jq -n --arg ts "$ts" --arg v "$v" --arg ds "$ds" \
    --arg sid "${MOCK_CALLER_SID:-fixture-caller}" \
    --arg file "${MOCK_FILE:-/tmp/x}" \
    '{verdict_id:"fixture-validator-uuid", ts:$ts,
      validator_session_id:"placeholder",
      file:$file, session:$sid, verdict:$v,
      reasoning:"Fixture mock validator.", diff_summary:$ds,
      spawn_metadata:{duration_ms:0,model:"claude-haiku-4-5-20251001",spawn_mode:"no_bare"}}' \
    >"$vdir/${ts}.json"
  printf '%s\n' "{\"type\":\"result\",\"is_error\":false,\"session_id\":\"validator-spawn-${v}\",\"total_cost_usd\":0.05,\"duration_ms\":50,\"result\":\"verdict written\"}"
  exit 0
fi
if [ -n "${CLAUDE_CODE_MEDIATOR:-}" ]; then
  vdir="${COORD_DIR}/mediator/verdict"
  mkdir -p "$vdir"
  ts="$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
  jq -nc --arg ts "$ts" \
    '{verdict_id:"fixture-mediator-uuid", ts:$ts,
      for_pending_entry:"fixture-pending",
      mediator_session_id:"mediator-spawn", depth:1,
      action_type:"advice", confidence:"auto_apply",
      reasoning:"Fixture mock mediator.",
      actions:[],
      message_to_caller:"Fixture mediator advice.",
      message_to_others:null}' \
    >"$vdir/${ts}.json"
  printf '%s\n' "{\"type\":\"result\",\"is_error\":false,\"session_id\":\"mediator-spawn\",\"total_cost_usd\":0.10,\"duration_ms\":100,\"result\":\"mediator verdict written\"}"
  exit 0
fi
printf '%s\n' '{"type":"result","is_error":true,"errors":["unknown spawn context"],"session_id":"err","total_cost_usd":0,"duration_ms":10,"result":""}'
CLAUDE_DEFAULT
  chmod +x "$WORKDIR/bin/claude"

  # Seed files for scenarios.
  printf 'export const foo = "v1";\n' >"$WORKDIR/foo.ts"
  printf 'export const bar = "v1";\n' >"$WORKDIR/bar.ts"

  COORD_DIR="$WORKDIR/.coord"
  export WORKDIR COORD_DIR SRC_ROOT
  export PATH="$WORKDIR/bin:$PATH"

  # Source all required libs (Phase 0..7 cumulative).
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
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/self_tasks.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/task_processor.sh"
  # Phase 7 NEW libs.
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/spawn_helper.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/cost_guards.sh"

  # Phase 7 cost-guard tunables: tight defaults for fixture
  # boundary verification (production defaults are 12/120/300).
  : "${COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR:=2}"
  : "${COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS:=0}"
  : "${COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR:=2}"
  : "${COORD_COST_GUARDS_FLOCK_TIMEOUT:=2}"
  export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR \
         COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS \
         COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR \
         COORD_COST_GUARDS_FLOCK_TIMEOUT
}

# Helper: register a session row.
coord_fixture_p7_register_session() {
  local sid="$1"
  touch "$COORD_DIR/sessions/${sid}.active"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
       registered_at: "y", last_activity_at: $now, git_head: "", prompt_id: null,
       script_version: "1.0"})' \
    --arg sid "$sid" --arg now "$(coord_now_iso8601)"
}

# Helper: cost-guard counter path resolver.
coord_fixture_p7_counter_path() {
  local site="$1"
  printf '%s/cost_guards/%s.counter\n' "$COORD_DIR" "$site"
}

# Helper: count lines in a counter file (0 if absent).
coord_fixture_p7_counter_count() {
  local f="$1"
  if [ -e "$f" ]; then
    wc -l <"$f" | tr -d ' '
  else
    printf '0'
  fi
}

# Helper: invoke spawn_helper resolve in a sub-shell with given mode.
coord_fixture_p7_resolve_in_mode() {
  local mode="$1"
  bash -c '
    set -euo pipefail
    export COORD_TEST_MODE="'"$mode"'"
    source "'"$COORD_DIR"'/lib/log_event.sh"
    source "'"$COORD_DIR"'/lib/spawn_helper.sh"
    coord_spawn_helper_resolve_mode
    printf "\n"
  '
}

# Helper: invoke spawn_helper should_use_real_claude in a sub-shell.
coord_fixture_p7_should_use_real_in_mode() {
  local mode="$1" site="$2"
  bash -c '
    set -euo pipefail
    export COORD_TEST_MODE="'"$mode"'"
    source "'"$COORD_DIR"'/lib/log_event.sh"
    source "'"$COORD_DIR"'/lib/spawn_helper.sh"
    if coord_spawn_helper_should_use_real_claude "'"$site"'"; then
      exit 0
    else
      exit 1
    fi
  '
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_fixture_init
  printf '%s\n' "$WORKDIR"
fi

#!/usr/bin/env bash
# init.sh — create an isolated workspace for phase6_ship_gate
# fixtures. Phase 6 T6.10.
#
# Mirrors phase5_ship_gate/init.sh with Phase 6 additions:
#   - lib/self_tasks.sh + lib/task_processor.sh sourced
#   - mock claude binary extended with task-patch dispatch path
#     via COORD_MOCK_CLAUDE_TASK_PATCH env (read directly by
#     coord_task_processor_spawn_claude per PR-PHASE6-05 §5
#     env-var contract; no inline fake binary task-patch path
#     required since the lib reads the env directly)
#   - helpers for `coord task-open` + `coord self-delegate` CLI
#     invocation against the installed .coord/bin/coord
#
# Usage:
#   . init.sh                 # sourced by driver; sets WORKDIR + COORD_DIR

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"

coord_fixture_init() {
  WORKDIR="$(mktemp -d -t coord-fixture-p6sg-XXXX)"

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

  # Default fake claude binary (Phase 4-5 dispatch carry-forward).
  # Phase 6 task-patch contract is read by
  # coord_task_processor_spawn_claude via COORD_MOCK_CLAUDE_TASK_PATCH
  # env directly — no claude -p invocation needed in Phase 6 task
  # processor flow.
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

  # Seed files used by scenarios. Each contains a unique
  # function name so task-open anchors match exactly once.
  printf 'export const foo = "v1";\nfunction getUser() { return null; }\nfunction other() { return 1; }\n' \
    >"$WORKDIR/api.ts"
  printf 'export const bar = "v1";\n' >"$WORKDIR/bar.ts"
  printf 'export const baz = "v1";\n' >"$WORKDIR/baz.ts"

  COORD_DIR="$WORKDIR/.coord"
  export WORKDIR COORD_DIR SRC_ROOT
  export PATH="$WORKDIR/bin:$PATH"

  # Source all required libs (Phase 0..6 cumulative).
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
  # Phase 6 NEW libs.
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/self_tasks.sh"
  # shellcheck disable=SC1091
  . "$COORD_DIR/lib/task_processor.sh"
}

# Helper: register a session row in sessions.json + .active marker.
coord_fixture_p6_register_session() {
  local sid="$1"
  touch "$COORD_DIR/sessions/${sid}.active"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.sessions[$sid] = (.sessions[$sid] // {state: "ACTIVE", pid: 1, pid_lstart: "x",
       registered_at: "y", last_activity_at: $now, git_head: "", prompt_id: null,
       script_version: "1.0"})' \
    --arg sid "$sid" --arg now "$(coord_now_iso8601)"
}

# Helper: synthetic lock acquisition (bypassing pre_tool_use_write
# pipeline; scenario controls lock state directly).
coord_fixture_p6_acquire() {
  local file="$1" sid="$2"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.locks[$f] = {session: $sid, acquired_at: $now, last_refresh_at: $now,
                   tasks: [], latest_validator_verdict_ts: null}' \
    --arg f "$file" --arg sid "$sid" --arg now "$(coord_now_iso8601)"
}

# Helper: invoke the production `coord task-open` CLI against the
# installed .coord/bin/coord. Returns rc + captures stdout/stderr.
# Caller passes args after fixed --file <path> --complexity <c>
# --anchor <json> --instruction <text>; remainder is forwarded.
coord_fixture_p6_task_open() {
  local sid="$1" file="$2" complexity="$3" anchor="$4" instruction="$5"
  shift 5
  SESSION_ID="$sid" CLAUDE_COORD=1 COORD_DIR="$COORD_DIR" \
    "$COORD_DIR/bin/coord" task-open \
      --file "$file" --complexity "$complexity" \
      --anchor "$anchor" --instruction "$instruction" "$@"
}

# Helper: invoke the production `coord self-delegate` CLI.
coord_fixture_p6_self_delegate() {
  local sid="$1" file="$2" instruction="$3"
  SESSION_ID="$sid" CLAUDE_COORD=1 COORD_DIR="$COORD_DIR" \
    "$COORD_DIR/bin/coord" self-delegate \
      --file "$file" --instruction "$instruction"
}

# Helper: invoke pre_tool_use_write hook for given session + file
# (Edit tool). Returns rc + captures hook stdout (additionalContext
# JSON or empty).
coord_fixture_p6_pre_write() {
  local sid="$1" file="$2"
  local input
  input=$(jq -nc --arg s "$sid" --arg t "$file" --arg cwd "$WORKDIR" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"Edit", tool_input:{file_path:$t}
  }')
  CLAUDE_COORD=1 COORD_DIR="$COORD_DIR" CLAUDE_PROJECT_DIR="$WORKDIR" \
    bash -c "printf '%s' '$input' | '$SRC_ROOT/hooks/pre_tool_use_write.sh'"
}

# Helper: invoke post_tool_use_write hook (release lock + run task
# processor). Args: sid, file, edit_start, edit_end.
coord_fixture_p6_post_write() {
  local sid="$1" file="$2" edit_start="${3:-1}" edit_end="${4:-5}"
  local input
  input=$(jq -nc --arg s "$sid" --arg t "$file" --arg cwd "$WORKDIR" \
    --argjson es "$edit_start" --argjson ee "$edit_end" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
    tool_name:"Edit", tool_input:{file_path:$t},
    tool_response:{start_line:$es, end_line:$ee}
  }')
  CLAUDE_COORD=1 COORD_DIR="$COORD_DIR" CLAUDE_PROJECT_DIR="$WORKDIR" \
    COORD_MOCK_CLAUDE_TASK_PATCH="${COORD_MOCK_CLAUDE_TASK_PATCH:-}" \
    bash -c "printf '%s' '$input' | '$SRC_ROOT/hooks/post_tool_use_write.sh'"
}

# Helper: invoke pre_tool_use_any hook (cross-cutting; reminders,
# F-015 banner, notifications). Args: sid, [tool=Read], [target_file].
coord_fixture_p6_pre_any() {
  local sid="$1" tool="${2:-Read}" target="${3:-$WORKDIR/foo.ts}"
  local input
  input=$(jq -nc --arg s "$sid" --arg t "$target" --arg cwd "$WORKDIR" \
    --arg tool "$tool" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:$tool, tool_input:{file_path:$t}
  }')
  CLAUDE_COORD=1 COORD_DIR="$COORD_DIR" CLAUDE_PROJECT_DIR="$WORKDIR" \
    bash -c "printf '%s' '$input' | '$SRC_ROOT/hooks/pre_tool_use_any.sh'"
}

# Helper: invoke stop hook for given session.
coord_fixture_p6_stop() {
  local sid="$1"
  local input
  input=$(jq -nc --arg s "$sid" --arg cwd "$WORKDIR" '{
    session_id:$s, cwd:$cwd, hook_event_name:"Stop"
  }')
  CLAUDE_COORD=1 COORD_DIR="$COORD_DIR" CLAUDE_PROJECT_DIR="$WORKDIR" \
    bash -c "printf '%s' '$input' | '$SRC_ROOT/hooks/stop.sh'"
}

# Helper: write task_delegation toggle into config.json.
coord_fixture_p6_set_task_delegation() {
  local enabled="$1"   # "true" or "false"
  jq --argjson v "$enabled" '.task_delegation = $v' \
    "$COORD_DIR/config.json" >"$COORD_DIR/config.json.tmp" \
    && mv "$COORD_DIR/config.json.tmp" "$COORD_DIR/config.json"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_fixture_init
  printf '%s\n' "$WORKDIR"
fi

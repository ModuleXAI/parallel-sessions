#!/usr/bin/env bash
# init.sh — create an isolated workspace for phase4_ship_gate fixtures.
#
# Usage:
#   . init.sh                 # sourced by driver; sets WORKDIR + COORD_DIR
#
# Side effects (idempotent within a single scenario run):
#   - mktemp -d → WORKDIR
#   - git init at WORKDIR + initial commit
#   - install.sh --yes --repair against WORKDIR (creates .coord/ layout
#     including validator/, mediator/, read_snapshots/)
#   - $WORKDIR/bin/claude — fake claude binary that scripts BOTH the
#     validator and Mediator paths via env-var dispatch. Scenarios
#     overwrite this to script different behaviors.
#   - PATH prepended with $WORKDIR/bin so coord_validator_spawn +
#     coord_mediator_spawn pick it up.
#
# Caller is responsible for cleanup via `rm -rf "$WORKDIR"` when done.

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"

coord_fixture_init() {
  WORKDIR="$(mktemp -d -t coord-fixture-p4sg-XXXX)"

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

  # Default fake claude binary — dispatches by env var:
  #   CLAUDE_CODE_VALIDATOR=1 → write validator verdict per
  #     MOCK_VALIDATOR_VERDICT (defaults SAFE).
  #   CLAUDE_CODE_MEDIATOR=N  → write mediator verdict per
  #     MOCK_MEDIATOR_ACTION (defaults advice).
  # Scenarios overwrite this binary or set the MOCK_* env vars before
  # invoking the hook.
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
  [ "$v" = "MINOR" ] && ds="Variable rename inside function. No caller impact."
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
  [ "$action" = "surgical_fix" ] && msg="Mediator applied surgical_fix; retry your write."
  [ "$action" = "lockdown" ] && msg="Mediator triggered lockdown; system paused."
  actions="[]"
  if [ "$action" = "surgical_fix" ]; then
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

  COORD_DIR="$WORKDIR/.coord"
  export WORKDIR COORD_DIR SRC_ROOT
  export PATH="$WORKDIR/bin:$PATH"
}

# Helper: register a session via session_start.sh hook (so the .active
# marker exists and read-set tracking works).
coord_fixture_register_session() {
  local sid="$1"
  local hooks="$COORD_DIR/hooks"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/session_start.sh" >/dev/null
}

# Helper: prime a Read for SID on FILE (writes read-set entry + snapshot).
coord_fixture_prime_read() {
  local sid="$1" file="$2"
  local hooks="$COORD_DIR/hooks"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$file"'"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/pre_tool_use_read.sh" >/dev/null
}

# Helper: invoke pre_tool_use_write.sh as SID writing TARGET_FILE.
# Returns the hook's stdout on stdout (caller captures).
coord_fixture_invoke_write() {
  local sid="$1" target="$2"
  local hooks="$COORD_DIR/hooks"
  printf '%s' '{"session_id":"'"$sid"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$target"'"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/pre_tool_use_write.sh"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_fixture_init
  printf '%s\n' "$WORKDIR"
fi

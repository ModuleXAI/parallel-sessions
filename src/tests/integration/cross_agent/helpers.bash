# helpers.bash — cross-agent test helpers (PR F.1).
#
# Sourced via `load "helpers"` in cross-agent bats files. Provides a
# uniform API to spin up "fake" Claude and Codex sessions, exercise their
# write hooks, and inspect coordination state. The helpers wrap the real
# adapter hook scripts (no fake binaries) — each operation runs the
# actual production hook with controlled stdin, so any divergence
# between the fake and real session paths shows up immediately.
#
# Public API (all helpers expect xagent_setup to have been called):
#
#   Setup / teardown:
#     xagent_setup                              install both adapters at TMP
#     xagent_teardown                           rm -rf the TMP, unset state
#
#   Session lifecycle:
#     xagent_session_start  <agent> <sid>      register a new session
#     xagent_session_stop   <agent> <sid>      graceful stop (releases locks)
#     xagent_session_kill   <sid>              abrupt: drops marker only
#                                              (watchdog territory)
#
#   Write operations (Claude=Edit; Codex=apply_patch on the same path):
#     xagent_pretooluse_write   <agent> <sid> <file_path>
#     xagent_posttooluse_write  <agent> <sid> <file_path>
#       Stdout captured into XAGENT_LAST_OUTPUT for assertion.
#
#   Inspection:
#     xagent_lock_holder    <file_path>        echo session_id or empty
#     xagent_lock_count                        echo total lock count
#     xagent_session_count                     echo total session row count
#     xagent_session_agent  <sid>              echo "claude_code" or "codex"
#     xagent_session_state  <sid>              echo session.state
#     xagent_event_count    <kind>             echo count of events.kind
#     xagent_event_count_for <kind> <sid>      echo count filtered by .session
#
#   Output helpers (operate on XAGENT_LAST_OUTPUT):
#     xagent_last_was_deny                     rc=0 if last op was a deny
#     xagent_last_deny_reason                  echo permissionDecisionReason
#
# Agent values: "claude_code" or "codex". The adapter hooks live at:
#   $COORD_DIR/hooks/                          (claude flat)
#   $COORD_DIR/hooks/codex/                    (codex namespaced)
#
# Per F-D4-02 / D-9, Codex PreToolUse hooks emit ONLY permissionDecision
# (no additionalContext). Claude PreToolUse hooks may emit either or
# both. xagent_last_was_deny / xagent_last_deny_reason work for both
# agent shapes by reading the permissionDecision field.

# === Setup / teardown =======================================================

xagent_setup() {
  XAGENT_TMP="$(mktemp -d -t coord-xagent-XXXX)"
  XAGENT_STUB_BIN="$XAGENT_TMP/stub-bin"
  mkdir -p "$XAGENT_STUB_BIN"
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR

  # Stub `codex` binary so the dispatcher's auto-detect picks Codex up.
  # Stub `claude` similarly so future tests that look for the binary
  # don't need to know where it lives. Neither stub is invoked at runtime
  # — we drive hooks directly — so the contents are intentionally trivial.
  cat >"$XAGENT_STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat >"$XAGENT_STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$XAGENT_STUB_BIN/codex" "$XAGENT_STUB_BIN/claude"

  XAGENT_PATH="$XAGENT_STUB_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # Initialize as a git repo + install both adapters via the dispatcher.
  # The install MUST run from $XAGENT_TMP so the dispatcher's
  # `git rev-parse --show-toplevel` resolves to the test tree, not the
  # outer parallel-sessions repo.
  ( cd "$XAGENT_TMP" && git init -q && \
       git config user.email t@t && git config user.name T )
  ( cd "$XAGENT_TMP" && PATH="$XAGENT_PATH" bash "$SRC_ROOT/install.sh" \
       --yes --with-claude-code --with-codex >/dev/null )

  export COORD_DIR="$XAGENT_TMP/.coord"
  export XAGENT_TMP XAGENT_PATH XAGENT_STUB_BIN

  XAGENT_LAST_OUTPUT=""
  : >"$COORD_DIR/events.jsonl"

  # Each adapter installer's smoke test leaves residue: Claude smoke
  # registers a session then SessionEnd's it (row left at IDLE_CLOSED).
  # Reset sessions.json + sessions/ markers so xagent_session_count etc.
  # see a clean slate for tests.
  jq -n '{schema_version:"1.1",sessions:{},locks:{},wait_queues:{},
          read_sets:{},notifications:{},self_tasks:{},
          anomaly_votes:{},task_graph:{}}' \
    >"$COORD_DIR/sessions.json"
  rm -f "$COORD_DIR/sessions"/*.active 2>/dev/null || true
}

xagent_teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  unset XAGENT_PATH XAGENT_STUB_BIN XAGENT_LAST_OUTPUT
  if [ -n "${XAGENT_TMP:-}" ] && [ -d "$XAGENT_TMP" ]; then
    rm -rf "$XAGENT_TMP"
  fi
  unset XAGENT_TMP
}

# === Session lifecycle =====================================================

# _xagent_run_hook <env_pair> <hook_path> <input_json>
# Internal: runs the hook with the given env (CLAUDE_COORD=1 or
# COORD_ENABLED=1) and the canned stdin. Captures stdout into
# XAGENT_LAST_OUTPUT. Returns the hook's rc (so callers can test rc when
# they care; XAGENT_LAST_OUTPUT is always populated).
_xagent_run_hook() {
  local env_pair="$1" hook="$2" input="$3"
  if ! [ -x "$hook" ]; then
    XAGENT_LAST_OUTPUT=""
    return 127
  fi
  local rc=0
  XAGENT_LAST_OUTPUT=$(env "$env_pair" "$hook" <<<"$input" 2>/dev/null) || rc=$?
  return "$rc"
}

xagent_session_start() {
  local agent="$1" sid="$2"
  local input
  case "$agent" in
    claude_code)
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" '{
        session_id:$s, cwd:$cwd, hook_event_name:"SessionStart",
        source:"startup"
      }')
      _xagent_run_hook "CLAUDE_COORD=1" "$COORD_DIR/hooks/session_start.sh" "$input"
      ;;
    codex)
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" '{
        session_id:$s, cwd:$cwd, hook_event_name:"SessionStart",
        source:"startup", model:"x", permission_mode:"default",
        transcript_path:null
      }')
      _xagent_run_hook "COORD_ENABLED=1" "$COORD_DIR/hooks/codex/session_start.sh" "$input"
      ;;
    *) return 2 ;;
  esac
}

xagent_session_stop() {
  local agent="$1" sid="$2"
  local input
  case "$agent" in
    claude_code)
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" '{
        session_id:$s, cwd:$cwd, hook_event_name:"Stop"
      }')
      _xagent_run_hook "CLAUDE_COORD=1" "$COORD_DIR/hooks/stop.sh" "$input"
      ;;
    codex)
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" '{
        session_id:$s, cwd:$cwd, hook_event_name:"Stop",
        stop_hook_active:false, last_assistant_message:""
      }')
      _xagent_run_hook "COORD_ENABLED=1" "$COORD_DIR/hooks/codex/stop.sh" "$input"
      ;;
    *) return 2 ;;
  esac
}

# Abrupt termination: drop the .active marker without invoking any hook.
# Locks remain held; sessions.json row remains ACTIVE; only watchdog can
# clean up. Used to simulate process kill / SIGKILL.
xagent_session_kill() {
  local sid="$1"
  rm -f "$COORD_DIR/sessions/${sid}.active" 2>/dev/null || true
}

# === Write operations =======================================================

# xagent_pretooluse_write <agent> <sid> <file_path>
# For Claude: pipes an Edit-shaped PreToolUse through pre_tool_use_write.sh.
# For Codex: builds a single-hunk apply_patch over <file_path> (creating
#   the file if absent so the drift gate finds the pre_image) and pipes
#   it through pre_tool_use_apply_patch.sh.
# Captures hook stdout into XAGENT_LAST_OUTPUT.
xagent_pretooluse_write() {
  local agent="$1" sid="$2" path="$3"
  local input
  case "$agent" in
    claude_code)
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" --arg f "$path" '{
        session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
        tool_name:"Edit",
        tool_input:{file_path:$f, old_string:"old", new_string:"new"},
        tool_use_id:"tu-x"
      }')
      _xagent_run_hook "CLAUDE_COORD=1" "$COORD_DIR/hooks/pre_tool_use_write.sh" "$input" || true
      ;;
    codex)
      [ -f "$path" ] || printf 'old\n' >"$path"
      local patch
      patch="*** Begin Patch
*** Update File: $path
@@
-old
+new
*** End Patch"
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" --arg p "$patch" '{
        session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
        tool_name:"apply_patch",
        tool_input:{input:$p},
        tool_use_id:"tu-x"
      }')
      _xagent_run_hook "COORD_ENABLED=1" "$COORD_DIR/hooks/codex/pre_tool_use_apply_patch.sh" "$input" || true
      ;;
    *) return 2 ;;
  esac
}

# xagent_posttooluse_write <agent> <sid> <file_path>
# Mirror of pretooluse_write for the post-hook (lock release).
xagent_posttooluse_write() {
  local agent="$1" sid="$2" path="$3"
  local input
  case "$agent" in
    claude_code)
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" --arg f "$path" '{
        session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
        tool_name:"Edit",
        tool_input:{file_path:$f, old_string:"old", new_string:"new"},
        tool_response:{success:true},
        tool_use_id:"tu-x"
      }')
      _xagent_run_hook "CLAUDE_COORD=1" "$COORD_DIR/hooks/post_tool_use_write.sh" "$input" || true
      ;;
    codex)
      local patch
      patch="*** Begin Patch
*** Update File: $path
@@
-old
+new
*** End Patch"
      input=$(jq -nc --arg s "$sid" --arg cwd "$XAGENT_TMP" --arg p "$patch" '{
        session_id:$s, cwd:$cwd, hook_event_name:"PostToolUse",
        tool_name:"apply_patch",
        tool_input:{input:$p},
        tool_response:{success:true, output:"applied"},
        tool_use_id:"tu-x"
      }')
      _xagent_run_hook "COORD_ENABLED=1" "$COORD_DIR/hooks/codex/post_tool_use_apply_patch.sh" "$input" || true
      ;;
    *) return 2 ;;
  esac
}

# === Inspection =============================================================

xagent_lock_holder() {
  local path="$1"
  jq -r --arg f "$path" '.locks[$f].session // ""' "$COORD_DIR/sessions.json" 2>/dev/null || printf ''
}

xagent_lock_count() {
  jq -r '.locks | length' "$COORD_DIR/sessions.json" 2>/dev/null || printf '0'
}

xagent_session_count() {
  jq -r '.sessions | length' "$COORD_DIR/sessions.json" 2>/dev/null || printf '0'
}

xagent_session_agent() {
  local sid="$1"
  jq -r --arg s "$sid" '.sessions[$s].agent // ""' "$COORD_DIR/sessions.json" 2>/dev/null || printf ''
}

xagent_session_state() {
  local sid="$1"
  jq -r --arg s "$sid" '.sessions[$s].state // ""' "$COORD_DIR/sessions.json" 2>/dev/null || printf ''
}

xagent_event_count() {
  local kind="$1"
  if [ ! -s "$COORD_DIR/events.jsonl" ]; then printf '0'; return; fi
  jq -rs --arg k "$kind" '[.[] | select(.kind == $k)] | length' \
    "$COORD_DIR/events.jsonl" 2>/dev/null || printf '0'
}

xagent_event_count_for() {
  local kind="$1" sid="$2"
  if [ ! -s "$COORD_DIR/events.jsonl" ]; then printf '0'; return; fi
  jq -rs --arg k "$kind" --arg s "$sid" \
    '[.[] | select(.kind == $k and .session == $s)] | length' \
    "$COORD_DIR/events.jsonl" 2>/dev/null || printf '0'
}

# === Output helpers (operate on XAGENT_LAST_OUTPUT) ========================

xagent_last_was_deny() {
  [ -n "${XAGENT_LAST_OUTPUT:-}" ] || return 1
  printf '%s' "$XAGENT_LAST_OUTPUT" \
    | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1
}

xagent_last_deny_reason() {
  [ -n "${XAGENT_LAST_OUTPUT:-}" ] || return 0
  printf '%s' "$XAGENT_LAST_OUTPUT" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null \
    || printf ''
}

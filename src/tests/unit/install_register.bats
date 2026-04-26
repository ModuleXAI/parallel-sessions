#!/usr/bin/env bats
# Tests for install.sh hook registration (Phase 2 expanded set).
# Phase 1 had 6 hooks; Phase 2 adds post_tool_use_write.sh (PostToolUse
# matcher Write|Edit|NotebookEdit, T2.01) AND stop.sh (Stop matcher *,
# T2.02). Total: 8 hooks.

load "../helpers/common"

I="$SRC_ROOT/install.sh"

setup() {
  TMP="$(mktemp -d -t coord-install-XXXX)"
  # Fresh git repo so install.sh's `git rev-parse --show-toplevel` finds it.
  (
    cd "$TMP"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'placeholder\n' >a.txt
    git add a.txt
    git commit -q -m one
  )
  SETTINGS="$TMP/.claude/settings.local.json"
}

teardown() {
  rm -rf "$TMP"
}

# Run install.sh non-interactively in the fresh repo.
_install() {
  ( cd "$TMP" && "$I" --yes "$@" )
}

@test "install: --repair (clean) registers all 8 Phase-2 hooks" {
  _install --repair >/dev/null
  [ -f "$SETTINGS" ]
  # SessionStart
  run jq -r '[.hooks.SessionStart[].hooks[].command] | join(",")' "$SETTINGS"
  echo "$output" | grep -q "session_start.sh"
  # SessionEnd
  run jq -r '[.hooks.SessionEnd[].hooks[].command] | join(",")' "$SETTINGS"
  echo "$output" | grep -q "session_end.sh"
  # Stop — Phase 2 T2.02 graceful release hook.
  run jq -r '[.hooks.Stop[].hooks[].command] | join(",")' "$SETTINGS"
  echo "$output" | grep -q "stop.sh"
  # UserPromptSubmit
  run jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join(",")' "$SETTINGS"
  echo "$output" | grep -q "user_prompt_submit.sh"
  # PreToolUse — all 3 tool-specific hooks.
  run jq -r '[.hooks.PreToolUse[].hooks[].command] | join(",")' "$SETTINGS"
  echo "$output" | grep -q "pre_tool_use_any.sh"
  echo "$output" | grep -q "pre_tool_use_read.sh"
  echo "$output" | grep -q "pre_tool_use_write.sh"
  # PostToolUse — Phase 2 T2.01 lock release hook.
  run jq -r '[.hooks.PostToolUse[].hooks[].command] | join(",")' "$SETTINGS"
  echo "$output" | grep -q "post_tool_use_write.sh"
}

@test "install: PostToolUse matcher is Write|Edit|NotebookEdit (Phase 2 T2.01)" {
  _install --repair >/dev/null
  run jq -r '.hooks.PostToolUse[0].matcher' "$SETTINGS"
  [ "$output" = "Write|Edit|NotebookEdit" ]
}

@test "install: Stop matcher is * (Phase 2 T2.02)" {
  _install --repair >/dev/null
  run jq -r '.hooks.Stop[0].matcher' "$SETTINGS"
  [ "$output" = "*" ]
}

@test "install: PreToolUse matchers are correct (any=*, read=Read, write=Write|Edit|NotebookEdit)" {
  _install --repair >/dev/null
  run jq -r '[.hooks.PreToolUse[] | {matcher, cmd: (.hooks[0].command | split("/") | last)}]' "$SETTINGS"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"matcher": "\*"'
  echo "$output" | grep -q '"matcher": "Read"'
  echo "$output" | grep -q '"matcher": "Write|Edit|NotebookEdit"'
}

@test "install: re-running --repair is idempotent (no duplicate entries)" {
  _install --repair >/dev/null
  _install --repair >/dev/null
  _install --repair >/dev/null
  # Each event should still have exactly the expected number of OUR entries.
  run jq -r '[.hooks.PreToolUse[] | select(.hooks[].command | contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "3" ]
  run jq -r '[.hooks.PostToolUse[] | select(.hooks[].command | contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
  run jq -r '[.hooks.SessionStart[] | select(.hooks[].command | contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
  run jq -r '[.hooks.SessionEnd[] | select(.hooks[].command | contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
  run jq -r '[.hooks.Stop[] | select(.hooks[].command | contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
  run jq -r '[.hooks.UserPromptSubmit[] | select(.hooks[].command | contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
}

@test "install: --repair preserves user-authored hook entries in settings" {
  # Simulate a user-authored entry alongside ours.
  mkdir -p "$TMP/.claude"
  cat >"$SETTINGS" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "matcher": "*",
        "hooks": [{ "type": "command", "command": "/users/me/my-own-hook.sh", "timeout": 5 }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "/users/me/audit-bash.sh" }] }
    ]
  }
}
JSON
  _install --repair >/dev/null
  # Single dump of all commands across all events; assertions go against it.
  run jq -r '[.. | objects | select(has("command")) | .command] | join("|")' "$SETTINGS"
  # User entries survive.
  echo "$output" | grep -q "my-own-hook.sh"
  echo "$output" | grep -q "audit-bash.sh"
  # Our entries also present.
  echo "$output" | grep -q "session_start.sh"
  echo "$output" | grep -q "pre_tool_use_any.sh"
}

@test "install: --uninstall strips ALL coord hook entries across every event but preserves user entries" {
  _install --repair >/dev/null
  # Add a user entry alongside ours.
  jq '.hooks.PreToolUse += [{ "matcher": "Bash",
                              "hooks": [{ "type": "command", "command": "/users/me/audit.sh" }] }]' \
     "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  _install --uninstall >/dev/null
  # No coord entries remain anywhere.
  run jq -r '[.. | objects | select(has("command")) | .command | select(contains(".coord/hooks/"))] | length' "$SETTINGS"
  [ "$output" = "0" ]
  # User entry preserved.
  run jq -r '[.. | objects | select(has("command")) | .command | select(contains("audit.sh"))] | length' "$SETTINGS"
  [ "$output" = "1" ]
}

@test "install: hook scripts are copied + executable in .coord/hooks/" {
  _install --repair >/dev/null
  for h in session_start session_end stop user_prompt_submit pre_tool_use_any pre_tool_use_read pre_tool_use_write post_tool_use_write; do
    [ -x "$TMP/.coord/hooks/$h.sh" ] || { echo "missing: $h.sh"; return 1; }
  done
  for l in atomic_write log_event participant state_query subagent_filter head_tracking hash notify_waiters mediator_pending; do
    [ -f "$TMP/.coord/lib/$l.sh" ] || { echo "missing lib: $l.sh"; return 1; }
  done
}

@test "install: --repair refuses to overwrite invalid JSON in settings.local.json" {
  mkdir -p "$TMP/.claude"
  printf '{ this is not valid }' >"$SETTINGS"
  run _install --repair
  [ "$status" -ne 0 ]
  # Settings file is left untouched (still invalid JSON).
  run cat "$SETTINGS"
  [ "$output" = '{ this is not valid }' ]
}

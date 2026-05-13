#!/usr/bin/env bash
# install.sh — Claude Code adapter installer for coord (PR E.2).
#
# Phase E PR E.2. Adapter-specific installer for Claude Code. Materializes
# the Claude hooks + adapter libs under an existing .coord/ install, writes
# the Claude-side `.claude/settings.local.json` registration, and runs a
# Claude SessionStart smoke test. The top-level src/install.sh dispatcher
# is responsible for creating .coord/ itself; this script REQUIRES it
# to exist and only handles the Claude-specific install surface.
#
# Usage:
#   bash src/adapters/claude-code/install.sh [--yes] [--repair] [--uninstall]
#                                            [--bypass-permissions]
#                                            [--repo-root <path>]
#
#   --yes, -y               non-interactive
#   --repair                overwrite hooks/libs from src/, keep state
#   --uninstall             strip claude coord hook entries from
#                           settings.local.json (preserves .coord/)
#   --bypass-permissions    OPT-IN: also set
#                           .claude/settings.local.json
#                           permissions.defaultMode = "bypassPermissions".
#                           DANGEROUS — disables every Claude Code
#                           tool-permission prompt in this repo.
#   --repo-root <path>      install root (default: git toplevel or PWD)
#
# Layout produced (idempotent):
#   <repo>/.coord/hooks/                    Claude hooks (8 files, flat)
#   <repo>/.coord/lib/                      Core + Claude adapter libs (flat)
#   <repo>/.claude/settings.local.json      Claude hook registration
#                                            (6 events, 8 hook commands)
#
# Idempotency: re-running strips prior coord-owned entries (commands
# containing `/.coord/hooks/`) — same pattern as the codex installer.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$SELF"
SRC_ROOT="$(cd "$SELF/../.." && pwd)"

MODE="install"
YES="0"
BYPASS="0"
REPO_ROOT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)              YES="1" ;;
    --repair)              MODE="repair" ;;
    --uninstall)           MODE="uninstall" ;;
    --bypass-permissions)  BYPASS="1" ;;
    --repo-root)           REPO_ROOT="$2"; shift ;;
    --repo-root=*)         REPO_ROOT="${1#*=}" ;;
    -h|--help)
      sed -n '1,30p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    -*)
      printf 'claude install: unknown flag %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [ -z "$REPO_ROOT" ]; then REPO_ROOT="$1"; fi
      ;;
  esac
  shift
done

# Repo root: explicit > git rev-parse > walk-up.
if [ -z "$REPO_ROOT" ]; then
  if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
  else
    cur="$PWD"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      if [ -d "$cur/.coord" ]; then REPO_ROOT="$cur"; break; fi
      cur=$(dirname "$cur")
    done
  fi
fi

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  printf 'claude install: cannot locate repo root (pass --repo-root <path>)\n' >&2
  exit 2
fi

COORD_DIR="$REPO_ROOT/.coord"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.local.json"
HOOK_DST="$COORD_DIR/hooks"
LIB_DST="$COORD_DIR/lib"

say()  { printf 'claude install: %s\n' "$*"; }
warn() { printf 'claude install: warn: %s\n' "$*" >&2; }
die()  { printf 'claude install: error: %s\n' "$*" >&2; exit 1; }

if [ "$BYPASS" = "1" ] && [ "$MODE" = "uninstall" ]; then
  warn "--bypass-permissions is ignored under --uninstall"
  BYPASS="0"
fi

# === uninstall mode ===
if [ "$MODE" = "uninstall" ]; then
  say "uninstall: removing Claude coord hook entries from $CLAUDE_SETTINGS (leaving .coord/ in place)"
  if [ -s "$CLAUDE_SETTINGS" ]; then
    tmp=$(mktemp)
    if jq '
      if has("hooks") then
        .hooks |= with_entries(
          .value |= ((. // []) | map(
            .hooks = ((.hooks // []) | map(select(((.command // "") | contains("/.coord/hooks/")) | not)))
          ) | map(select((.hooks // []) | length > 0)))
        )
      else . end
    ' "$CLAUDE_SETTINGS" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$CLAUDE_SETTINGS"
      say "stripped coord-owned entries from $CLAUDE_SETTINGS"
    else
      rm -f "$tmp"
      warn "could not parse $CLAUDE_SETTINGS; manual edit may be required"
    fi
  fi
  exit 0
fi

# === pre-flight: .coord/ must exist ===
if [ ! -d "$COORD_DIR" ]; then
  die "$COORD_DIR does not exist. The top-level dispatcher (src/install.sh) creates it; invoke that first or pass --repo-root pointing at a tree where .coord/ already exists."
fi

# === step 1: copy adapter libs + hooks (flat into .coord/lib/ + .coord/hooks/)  ===
# Claude hooks live flat at .coord/hooks/; adapter libs at .coord/lib/ (alongside
# core libs). Codex's namespaced subdirs (.coord/hooks/codex/, .coord/lib/codex/)
# do NOT collide with Claude's flat layout — names differ AND the directory
# trees are disjoint.

say "materializing $HOOK_DST and $LIB_DST"
mkdir -p "$HOOK_DST" "$LIB_DST"

# Adapter libs (subagent_filter.sh and any other claude-specific lib).
cp -f "$ADAPTER_ROOT/lib"/*.sh "$LIB_DST/" 2>/dev/null || true

# Claude Code hooks (8 files registered in settings.local.json).
cp -f "$ADAPTER_ROOT/hooks"/*.sh "$HOOK_DST/"

# Optional agent .md files (legacy: spawn_helper references go here).
if [ -d "$SRC_ROOT/agents" ]; then
  if ls "$SRC_ROOT/agents"/*.md >/dev/null 2>&1; then
    cp -f "$SRC_ROOT/agents"/*.md "$HOOK_DST/" 2>/dev/null || true
  fi
fi

chmod +x "$HOOK_DST"/*.sh

# === step 2: write/merge .claude/settings.local.json ===

mkdir -p "$REPO_ROOT/.claude"
say "writing Claude hook registration to $CLAUDE_SETTINGS"

current='{}'
if [ -s "$CLAUDE_SETTINGS" ]; then
  current=$(cat "$CLAUDE_SETTINGS")
  if ! printf '%s' "$current" | jq -e . >/dev/null 2>&1; then
    die "$CLAUDE_SETTINGS is not valid JSON; refusing to overwrite. Fix or remove it and re-run."
  fi
fi

# Strategy:
#   1. Strip any prior coord-owned entries (commands containing
#      `/.coord/hooks/` — covers BOTH the claude flat layout and codex
#      subdir layout, but the codex installer manages its OWN file
#      .codex/hooks.json so this only touches claude's settings).
#   2. Append the 8 Phase-2 Claude hook entries.
#   3. If --bypass-permissions, also set .permissions.defaultMode.
tmp=$(mktemp)
printf '%s' "$current" | jq \
    --arg hdir "$HOOK_DST" \
    --arg bypass "$BYPASS" '
  .hooks //= {}
  | .hooks |= with_entries(
      .value |= ((. // []) | map(
        .hooks = ((.hooks // []) | map(select(((.command // "") | contains("/.coord/hooks/")) | not)))
      ) | map(select((.hooks // []) | length > 0)))
    )
  | (if $bypass == "1" then
       .permissions //= {}
       | .permissions.defaultMode = "bypassPermissions"
     else . end)
  | .hooks.SessionStart      = ((.hooks.SessionStart // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/session_start.sh"),     timeout:10}]}])
  | .hooks.SessionEnd        = ((.hooks.SessionEnd // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/session_end.sh"),       timeout:10}]}])
  | .hooks.Stop              = ((.hooks.Stop // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/stop.sh"),              timeout:10}]}])
  | .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/user_prompt_submit.sh"),timeout:10}]}])
  | .hooks.PreToolUse        = ((.hooks.PreToolUse // [])
      + [{matcher:"*",                       hooks:[{type:"command", command:($hdir+"/pre_tool_use_any.sh"),   timeout:10}]},
         {matcher:"Read",                    hooks:[{type:"command", command:($hdir+"/pre_tool_use_read.sh"),  timeout:10}]},
         {matcher:"Write|Edit|NotebookEdit", hooks:[{type:"command", command:($hdir+"/pre_tool_use_write.sh"), timeout:10}]}])
  | .hooks.PostToolUse       = ((.hooks.PostToolUse // [])
      + [{matcher:"Write|Edit|NotebookEdit", hooks:[{type:"command", command:($hdir+"/post_tool_use_write.sh"),timeout:10}]}])
' >"$tmp"
mv "$tmp" "$CLAUDE_SETTINGS"

# === step 3: smoke test ===
# Pipe canned Claude SessionStart → SessionEnd. Verifies banner emit +
# .active marker creation/teardown. Failure here → die.

smoke_test() {
  local sid="claude-install-smoke-$RANDOM"
  local out
  if ! out=$(CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$REPO_ROOT" \
              "$HOOK_DST/session_start.sh" <<EOF
{"session_id":"$sid","cwd":"$REPO_ROOT","hook_event_name":"SessionStart","source":"startup"}
EOF
  ); then
    die "smoke test failed: session_start.sh exited non-zero"
  fi
  if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null 2>&1; then
    die "smoke test failed: session_start did not emit Coord banner"
  fi
  if [ ! -e "$COORD_DIR/sessions/${sid}.active" ]; then
    die "smoke test failed: .active marker not created"
  fi
  CLAUDE_COORD=1 "$HOOK_DST/session_end.sh" <<EOF >/dev/null 2>&1 || true
{"session_id":"$sid","hook_event_name":"SessionEnd","reason":"install-smoke"}
EOF
  if [ -e "$COORD_DIR/sessions/${sid}.active" ]; then
    die "smoke test failed: .active marker not removed after SessionEnd"
  fi
  # M-T1-05 hygiene (post-H.1 finding): SessionEnd transitions the
  # session to IDLE_CLOSED but leaves the row in sessions.json. Pre-fix
  # this left a `claude-install-smoke-*` row in `coord status` after
  # every install. Mirror the codex installer's coord_atomic_edit
  # cleanup so a real first-time user's `coord status` doesn't show
  # install-smoke residue.
  if [ -s "$COORD_DIR/sessions.json" ] && [ -s "$COORD_DIR/lib/atomic_write.sh" ]; then
    # shellcheck disable=SC1091
    . "$COORD_DIR/lib/atomic_write.sh"
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      'del(.sessions[$sid])
       | del(.read_sets[$sid])
       | .locks |= with_entries(select(.value.session != $sid))
       | .wait_queues |= with_entries(.value |= map(select(.session != $sid)))
       | .wait_queues |= with_entries(select((.value // []) | length > 0))' \
      --arg sid "$sid" >/dev/null 2>&1 || true
  fi
  say "smoke test passed"
}
smoke_test

if [ "$BYPASS" = "1" ]; then
  say ""
  say "permissions.defaultMode is now \"bypassPermissions\" in:"
  say "    $CLAUDE_SETTINGS"
  say "To revert: edit and remove the \"defaultMode\" key under \"permissions\","
  say "or replace its value with \"default\" / \"acceptEdits\" / \"plan\"."
fi
say "Claude adapter installed at $HOOK_DST + $LIB_DST"

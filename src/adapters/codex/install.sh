#!/usr/bin/env bash
# install.sh — Codex adapter installer for coord (PR E.1).
#
# Phase E PR E.1. Adapter-specific installer for the Codex CLI. Materializes
# Codex hooks + adapter libs under an existing .coord/ install and writes
# the Codex-side `.codex/hooks.json` registration. The top-level coord
# installer (Phase E.2 will land the dispatcher) is responsible for
# creating .coord/ itself; this script REQUIRES it to exist.
#
# Usage:
#   bash src/adapters/codex/install.sh                    # interactive
#   bash src/adapters/codex/install.sh --yes              # non-interactive
#   bash src/adapters/codex/install.sh --repair           # overwrite hooks/libs
#   bash src/adapters/codex/install.sh --uninstall        # remove hook entries
#   bash src/adapters/codex/install.sh --enable-codex-feature
#       Best-effort flip of [features] codex_hooks = true in .codex/config.toml.
#       Without the flag, the installer warns when the feature gate is absent.
#
# Layout produced (idempotent):
#   <repo>/.coord/hooks/codex/                    Codex hooks (7 files)
#   <repo>/.coord/lib/codex/                      Codex adapter libs
#                                                 (translator.sh,
#                                                  apply_patch_parser.sh)
#   <repo>/.codex/hooks.json                      Codex hook registration
#                                                 (5 events, 7 hook commands)
#
# Codex hook entries written (D-10: NO SessionEnd; D-D4-02: PreToolUse hooks
# only emit permissionDecision deny via lockdown — additionalContext is
# rejected by Codex's PreToolUse parser):
#   SessionStart       matcher *           → session_start.sh
#   Stop               matcher *           → stop.sh
#   UserPromptSubmit   matcher *           → user_prompt_submit.sh
#   PreToolUse         matcher *           → pre_tool_use_any.sh
#                      matcher ^Bash$      → pre_tool_use_bash.sh
#                      matcher ^apply_patch$ → pre_tool_use_apply_patch.sh
#   PostToolUse        matcher ^apply_patch$ → post_tool_use_apply_patch.sh
#
# Idempotency: re-running strips prior coord-owned entries (commands
# containing `/.coord/hooks/codex/`) before appending — same pattern as
# the Claude installer's `.claude/settings.local.json` handling.

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_ROOT="$SELF"
SRC_ROOT="$(cd "$SELF/../.." && pwd)"

MODE="install"
YES="0"
ENABLE_CODEX_FEATURE="0"
REPO_ROOT="${1:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --yes)                     YES="1" ;;
    --repair)                  MODE="repair" ;;
    --uninstall)               MODE="uninstall" ;;
    --enable-codex-feature)    ENABLE_CODEX_FEATURE="1" ;;
    --repo-root)               REPO_ROOT="$2"; shift ;;
    --repo-root=*)             REPO_ROOT="${1#*=}" ;;
    -h|--help)
      sed -n '1,30p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    -*)
      printf 'codex install: unknown flag %s\n' "$1" >&2
      exit 2
      ;;
    *)
      # First positional arg is the repo root if not already set via flag.
      if [ -z "${REPO_ROOT}" ] || [ "${REPO_ROOT}" = "$1" ]; then
        REPO_ROOT="$1"
      fi
      ;;
  esac
  shift
done

# Repo root resolution: explicit flag > git rev-parse > walk-up from PWD.
if [ -z "$REPO_ROOT" ]; then
  if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
  else
    cur="$PWD"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      if [ -d "$cur/.coord" ]; then
        REPO_ROOT="$cur"; break
      fi
      cur=$(dirname "$cur")
    done
  fi
fi

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  printf 'codex install: cannot locate repo root (pass --repo-root <path>)\n' >&2
  exit 2
fi

COORD_DIR="$REPO_ROOT/.coord"
HOOK_DST="$COORD_DIR/hooks/codex"
LIB_DST="$COORD_DIR/lib/codex"
CODEX_DIR="$REPO_ROOT/.codex"
CODEX_HOOKS_JSON="$CODEX_DIR/hooks.json"
CODEX_CONFIG_TOML="$CODEX_DIR/config.toml"

say()  { printf 'codex install: %s\n' "$*"; }
warn() { printf 'codex install: warn: %s\n' "$*" >&2; }
die()  { printf 'codex install: error: %s\n' "$*" >&2; exit 1; }

# === uninstall mode ===
if [ "$MODE" = "uninstall" ]; then
  say "uninstall: removing Codex coord hook entries from $CODEX_HOOKS_JSON (leaving .coord/ in place)"
  if [ -s "$CODEX_HOOKS_JSON" ]; then
    tmp=$(mktemp)
    if jq '
      .hooks //= {}
      | .hooks |= with_entries(
          .value |= ((. // []) | map(
            .hooks = ((.hooks // []) | map(select(((.command // "") | contains("/.coord/hooks/codex/")) | not)))
          ) | map(select((.hooks // []) | length > 0)))
        )
    ' "$CODEX_HOOKS_JSON" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$CODEX_HOOKS_JSON"
      say "stripped coord-owned entries from $CODEX_HOOKS_JSON"
    else
      rm -f "$tmp"
      warn "could not parse $CODEX_HOOKS_JSON; manual edit may be required"
    fi
  fi
  exit 0
fi

# === pre-flight: .coord/ must exist ===
if [ ! -d "$COORD_DIR" ]; then
  die "$COORD_DIR does not exist. Run 'bash src/install.sh' first to materialize the shared coord layout, then re-run this adapter installer."
fi

# === pre-flight: dependencies (jq, codex CLI optional) ===
for dep in jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    die "required dependency '$dep' is not on PATH"
  fi
done

# `codex` binary is not strictly required for install — the user may install
# coord first and Codex CLI later. Warn but proceed.
if ! command -v codex >/dev/null 2>&1; then
  warn "'codex' binary not on PATH; install Codex CLI from https://github.com/openai/codex to use these hooks"
fi

# === step 1: copy adapter hooks + libs ===

say "materializing $HOOK_DST and $LIB_DST"
mkdir -p "$HOOK_DST" "$LIB_DST"

# Hook files: 7 scripts under src/adapters/codex/hooks/.
HOOK_FILES=(
  session_start.sh
  stop.sh
  user_prompt_submit.sh
  pre_tool_use_any.sh
  pre_tool_use_bash.sh
  pre_tool_use_apply_patch.sh
  post_tool_use_apply_patch.sh
)
for h in "${HOOK_FILES[@]}"; do
  if [ ! -f "$ADAPTER_ROOT/hooks/$h" ]; then
    die "missing source hook: $ADAPTER_ROOT/hooks/$h"
  fi
  cp -f "$ADAPTER_ROOT/hooks/$h" "$HOOK_DST/$h"
done

# Adapter libs: translator.sh + apply_patch_parser.sh.
LIB_FILES=(translator.sh apply_patch_parser.sh)
for l in "${LIB_FILES[@]}"; do
  if [ ! -f "$ADAPTER_ROOT/lib/$l" ]; then
    die "missing source lib: $ADAPTER_ROOT/lib/$l"
  fi
  cp -f "$ADAPTER_ROOT/lib/$l" "$LIB_DST/$l"
done

chmod +x "$HOOK_DST"/*.sh

# === step 2: write/merge .codex/hooks.json ===

mkdir -p "$CODEX_DIR"
say "writing Codex hook registration to $CODEX_HOOKS_JSON"

current='{}'
if [ -s "$CODEX_HOOKS_JSON" ]; then
  current=$(cat "$CODEX_HOOKS_JSON")
  if ! printf '%s' "$current" | jq -e . >/dev/null 2>&1; then
    die "$CODEX_HOOKS_JSON is not valid JSON; refusing to overwrite. Fix or remove it and re-run."
  fi
fi

tmp=$(mktemp)
printf '%s' "$current" | jq \
    --arg hdir "$HOOK_DST" '
  .hooks //= {}
  | .hooks |= with_entries(
      .value |= ((. // []) | map(
        .hooks = ((.hooks // []) | map(select(((.command // "") | contains("/.coord/hooks/codex/")) | not)))
      ) | map(select((.hooks // []) | length > 0)))
    )
  | .hooks.SessionStart      = ((.hooks.SessionStart // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/session_start.sh"),     timeout:10}]}])
  | .hooks.Stop              = ((.hooks.Stop // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/stop.sh"),              timeout:10}]}])
  | .hooks.UserPromptSubmit  = ((.hooks.UserPromptSubmit // [])
      + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/user_prompt_submit.sh"),timeout:10}]}])
  | .hooks.PreToolUse        = ((.hooks.PreToolUse // [])
      + [{matcher:"*",                hooks:[{type:"command", command:($hdir+"/pre_tool_use_any.sh"),         timeout:10}]},
         {matcher:"^Bash$",           hooks:[{type:"command", command:($hdir+"/pre_tool_use_bash.sh"),        timeout:10}]},
         {matcher:"^apply_patch$",    hooks:[{type:"command", command:($hdir+"/pre_tool_use_apply_patch.sh"), timeout:10}]}])
  | .hooks.PostToolUse       = ((.hooks.PostToolUse // [])
      + [{matcher:"^apply_patch$",    hooks:[{type:"command", command:($hdir+"/post_tool_use_apply_patch.sh"),timeout:10}]}])
' >"$tmp"
mv "$tmp" "$CODEX_HOOKS_JSON"

# === step 3: codex_hooks feature flag check (.codex/config.toml) ===

# Codex hooks require [features] codex_hooks = true in .codex/config.toml.
# We can't reliably parse arbitrary TOML in pure bash, but we can do a
# best-effort grep for the literal line. On --enable-codex-feature, append
# the section if absent.
codex_feature_check() {
  if [ ! -f "$CODEX_CONFIG_TOML" ]; then
    if [ "$ENABLE_CODEX_FEATURE" = "1" ]; then
      mkdir -p "$CODEX_DIR"
      printf '[features]\ncodex_hooks = true\n' >"$CODEX_CONFIG_TOML"
      say "created $CODEX_CONFIG_TOML with [features] codex_hooks = true"
      return 0
    fi
    warn "$CODEX_CONFIG_TOML does not exist."
    warn "  Codex hooks require [features] codex_hooks = true in this file."
    warn "  Either re-run with --enable-codex-feature OR add manually:"
    warn "    [features]"
    warn "    codex_hooks = true"
    return 0
  fi
  if grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX_CONFIG_TOML" 2>/dev/null; then
    say "codex_hooks feature flag already enabled in $CODEX_CONFIG_TOML"
    return 0
  fi
  if [ "$ENABLE_CODEX_FEATURE" = "1" ]; then
    if grep -qE '^[[:space:]]*\[features\]' "$CODEX_CONFIG_TOML" 2>/dev/null; then
      # Append codex_hooks under existing [features] section (best-effort
      # via awk; not a full TOML rewriter — any user-authored content
      # under [features] preserved).
      awk '
        BEGIN { added=0 }
        /^[[:space:]]*\[features\][[:space:]]*$/ { print; print "codex_hooks = true"; added=1; next }
        { print }
        END { if (!added) { print ""; print "[features]"; print "codex_hooks = true" } }
      ' "$CODEX_CONFIG_TOML" >"$CODEX_CONFIG_TOML.tmp.$$" \
        && mv "$CODEX_CONFIG_TOML.tmp.$$" "$CODEX_CONFIG_TOML"
      say "added codex_hooks = true under [features] in $CODEX_CONFIG_TOML"
    else
      printf '\n[features]\ncodex_hooks = true\n' >>"$CODEX_CONFIG_TOML"
      say "appended [features] codex_hooks = true to $CODEX_CONFIG_TOML"
    fi
    return 0
  fi
  warn "$CODEX_CONFIG_TOML exists but [features] codex_hooks = true is not set."
  warn "  Re-run with --enable-codex-feature OR add manually:"
  warn "    [features]"
  warn "    codex_hooks = true"
}
codex_feature_check

# === step 4: smoke test ===
# Pipe canned Codex SessionStart JSON; verify .active marker created.

smoke_test() {
  local sid="codex-install-smoke-$RANDOM"
  local input
  input=$(jq -nc --arg s "$sid" --arg cwd "$REPO_ROOT" '{
    session_id:$s, cwd:$cwd, hook_event_name:"SessionStart",
    source:"startup", model:"gpt-test", permission_mode:"default",
    transcript_path:null
  }')
  local out err hook_rc=0
  err=$(mktemp)
  # The hook's own `set -euo pipefail` gives it deterministic execution;
  # we capture stderr separately so smoke failure messages can include
  # actionable diagnostics. `|| hook_rc=$?` captures the rc without
  # propagating set -e from the install's own shell.
  # COORD_DIR is exported explicitly so coord_resolve_root inside the
  # hook does not need to walk up — the hook is being run directly from
  # the install layout, not from a session inside a shell whose cwd is
  # a subdir of REPO_ROOT.
  out=$(COORD_ENABLED=1 COORD_DIR="$COORD_DIR" \
        "$HOOK_DST/session_start.sh" <<<"$input" 2>"$err") || hook_rc=$?
  if [ "$hook_rc" -ne 0 ]; then
    local errmsg
    errmsg=$(cat "$err" 2>/dev/null || printf '<no stderr>')
    rm -f "$err"
    die "smoke test failed: session_start.sh exited non-zero (rc=$hook_rc). stderr: $errmsg"
  fi
  rm -f "$err"
  # Output must be JSON with hookSpecificOutput.additionalContext.
  if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null 2>&1; then
    die "smoke test failed: session_start did not emit Coord banner"
  fi
  if [ ! -e "$COORD_DIR/sessions/${sid}.active" ]; then
    die "smoke test failed: .active marker not created"
  fi
  # Tear down via stop.sh (Codex has no SessionEnd per D-10; stop.sh is
  # the graceful-release point).
  local stop_input
  stop_input=$(jq -nc --arg s "$sid" --arg cwd "$REPO_ROOT" '{
    session_id:$s, cwd:$cwd, hook_event_name:"Stop", stop_hook_active:false
  }')
  COORD_ENABLED=1 "$HOOK_DST/stop.sh" <<<"$stop_input" >/dev/null 2>&1 || true
  # Marker is NOT removed on Stop (per D-10: cleanup is watchdog's job for
  # Codex). Manually remove the smoke session's marker so we don't pollute
  # the install with a fake session row.
  rm -f "$COORD_DIR/sessions/${sid}.active"
  # Also delete the synthetic session row from sessions.json.
  if [ -f "$COORD_DIR/sessions.json" ]; then
    local cleanup_tmp
    cleanup_tmp=$(mktemp)
    jq --arg sid "$sid" 'del(.sessions[$sid])' "$COORD_DIR/sessions.json" \
      >"$cleanup_tmp" 2>/dev/null && mv "$cleanup_tmp" "$COORD_DIR/sessions.json" \
      || rm -f "$cleanup_tmp"
  fi
  say "smoke test passed (session_id $sid)"
}
smoke_test

say "Codex adapter installed at $HOOK_DST + $LIB_DST"
say "next: ensure 'codex' binary is on PATH, then run 'parallels-codex' from inside this repo"

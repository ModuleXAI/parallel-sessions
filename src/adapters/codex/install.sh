#!/usr/bin/env bash
# install.sh — Codex adapter installer for coord (PR E.1; A-M-T1-04 plan v1.4).
#
# Phase E PR E.1. Adapter-specific installer for the Codex CLI. Materializes
# Codex hooks + adapter libs under an existing .coord/ install and writes
# the Codex-side `.codex/hooks.json` registration. The top-level coord
# installer (`src/install.sh`) is responsible for creating `.coord/` itself;
# this script REQUIRES it to exist.
#
# Plan v1.4 amendment (A-M-T1-04, commit 8cec664) — root motivation:
#   The codex feature flag `[features] codex_hooks = true` in
#   `<repo>/.codex/config.toml` is no longer optional. Per OpenAI's Codex
#   hooks documentation, hook discovery requires an "active config layer":
#     "Codex discovers hooks next to active config layers in either of
#      these forms: hooks.json | inline [hooks] tables inside config.toml.
#      ... Project-local hooks load only when the project .codex/ layer is
#      trusted."
#   A directory containing `hooks.json` ALONE is NOT an active layer; the
#   layer becomes active only when a sibling `config.toml` exists. The
#   pre-v1.4 install path that wrote `hooks.json` without `config.toml`
#   produced a silent product failure (install rc=0, no hook ever fired,
#   no log surface). M-T1-04 captured the BEFORE evidence on a clean
#   macOS install with Codex CLI v0.128.0 and led to plan v1.4. This
#   installer therefore ALWAYS writes/merges the flag into config.toml,
#   regardless of CLI flags (`--enable-codex-feature` is now a no-op).
#
# Post-completion finding ID schema:
#   M-T<tier>-<NN>   Manual-test finding from tier <tier> testing,
#                    finding <NN> in sequence (chronological).
#   A-M-T<tier>-<NN> Plan amendment landing the corresponding M-T finding.
#   Tier 1 = post-H.1 clean-install smoke. Findings filed by the user
#   during real-machine testing rather than the pre-H phase-by-phase
#   integration arc (which used `M-T1-01..05` here on the parallel-sessions
#   repository for first-tier manual testing).
#   Note: the M-T1-* sequence has gaps (01 deferred to "package
#   distribution" effort; 02 and 03 not assigned — were rolled into
#   adjacent findings during the user's smoke run). Gaps are recorded
#   in `codex-integration-log.md` 2026-05-05 dated section.
#
# Usage:
#   bash src/adapters/codex/install.sh                    # interactive
#   bash src/adapters/codex/install.sh --yes              # non-interactive
#   bash src/adapters/codex/install.sh --repair           # overwrite hooks/libs
#   bash src/adapters/codex/install.sh --uninstall        # remove hook entries
#   bash src/adapters/codex/install.sh --enable-codex-feature
#       DEPRECATED no-op (kept for back-compat with pre-v1.4 install
#       runbooks). The installer ALWAYS ensures `[features] codex_hooks
#       = true` in `.codex/config.toml`; passing this flag is harmless
#       but unnecessary.
#
# Layout produced (idempotent):
#   <repo>/.coord/hooks/codex/                    Codex hooks (7 files)
#   <repo>/.coord/lib/codex/                      Codex adapter libs
#                                                 (translator.sh,
#                                                  apply_patch_parser.sh)
#   <repo>/.codex/hooks.json                      Codex hook registration
#                                                 (5 events, 7 hook commands)
#   <repo>/.codex/config.toml                     [features] codex_hooks = true
#                                                 (active config layer; required
#                                                  for hooks.json to be loaded
#                                                  by Codex per A-M-T1-04)
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
# Idempotency contracts (A-M-T1-04 plan v1.4):
#   .codex/hooks.json:   strip prior coord-owned entries (commands
#                        containing `/.coord/hooks/codex/`) before
#                        appending — same pattern as Claude's
#                        `.claude/settings.local.json` handling.
#   .codex/config.toml:  three-path always-write
#                          (a) absent → create with minimal flag content
#                          (b) present + codex_hooks = true already set →
#                              no-op (file byte-stable across re-runs)
#                          (c) present + flag missing → grep+awk inline
#                              merge: insert `codex_hooks = true` directly
#                              under existing `[features]` block, OR
#                              append a new `[features]` block at EOF
#                              (with a leading blank line for hygiene).
#                              User-authored content outside the merge
#                              point is preserved byte-for-byte.
#                        Full TOML round-trip is intentionally NOT
#                        attempted — pure-bash TOML editing is fragile
#                        and risks corrupting user content with
#                        formatting drift. We only ensure the flag is
#                        present somewhere; exotic cases (commented
#                        flags, multi-line values, nested table syntax)
#                        are user-edited content and we leave them
#                        alone.
#   --uninstall:         strip our `codex_hooks = true` line if other
#                        user content remains in config.toml; remove the
#                        file only if it was solely our content (no
#                        other user-authored sections/keys). The
#                        `.codex/hooks.json` strip is unchanged from
#                        v1.3.

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

  # A-M-T1-04 uninstall contract: strip our `codex_hooks = true` line from
  # config.toml only if other user-authored content remains. If the file
  # was created by the installer with ONLY our content (one `[features]`
  # block containing one `codex_hooks = true` line, optional trailing
  # whitespace), remove it entirely. Else leave user content untouched.
  if [ -f "$CODEX_CONFIG_TOML" ]; then
    # Pattern-match what `_codex_create_minimal_config_toml` produces:
    # a single [features] block containing only `codex_hooks = true`,
    # nothing else (modulo blank lines and trailing whitespace). Awk
    # because we want a precise structural test, not just a grep.
    is_solely_ours=$(awk '
      BEGIN { lines=0; ours=1; in_features=0 }
      /^[[:space:]]*$/ { lines++; next }
      /^[[:space:]]*\[features\][[:space:]]*$/ {
        if (in_features) { ours=0 }
        in_features=1; lines++; next
      }
      /^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
        if (!in_features) { ours=0 }
        lines++; next
      }
      { ours=0; lines++; next }
      END { print ours }
    ' "$CODEX_CONFIG_TOML")
    if [ "$is_solely_ours" = "1" ]; then
      rm -f "$CODEX_CONFIG_TOML"
      say "removed installer-only $CODEX_CONFIG_TOML"
    else
      tmp=$(mktemp)
      # Strip ONLY the `codex_hooks = true` line; leave [features] block
      # header in place even if empty afterward. User may add other
      # feature flags later; we don't second-guess their structure.
      awk '
        /^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$/ { next }
        { print }
      ' "$CODEX_CONFIG_TOML" >"$tmp" \
        && mv "$tmp" "$CODEX_CONFIG_TOML" \
        || rm -f "$tmp"
      say "stripped codex_hooks = true from $CODEX_CONFIG_TOML (preserved user content)"
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

# === step 3: codex_hooks feature flag — ALWAYS ensured (A-M-T1-04 plan v1.4) ===
#
# A-M-T1-04 (M-T1-04 manual-test finding, plan v1.4 amendment, commit
# 8cec664): Codex hooks discovery requires an "active config layer" — a
# sibling `config.toml` in the .codex/ directory. Without config.toml,
# .codex/hooks.json is invisible to Codex and the entire coord pipeline
# is silently dead. The installer therefore ALWAYS ensures the flag is
# present in `.codex/config.toml`, regardless of CLI flags. Path-by-path:
#
#   (a) file absent → create with `[features]\ncodex_hooks = true\n`
#       (minimal content; the installer's only contribution).
#   (b) file present + flag set → no-op (byte-stable across re-runs).
#   (c) file present + flag missing →
#       (c1) `[features]` block exists somewhere → grep+awk inline merge:
#            insert `codex_hooks = true` immediately under the matched
#            block header, preserving the rest of the file.
#       (c2) `[features]` block does NOT exist → append a new
#            `\n[features]\ncodex_hooks = true\n` block at end-of-file.
#
# Pure-bash TOML editing is intentionally minimal — we don't round-trip
# the file through a parser/serializer because round-tripping risks
# corrupting user formatting (comment positions, blank lines, key
# ordering, quoting style). Exotic cases (commented `# codex_hooks =
# true`, multi-line values, inline tables, nested `[a.b]` sections)
# are user-edited content and we leave them alone — our grep is
# anchored on a `^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true`
# literal, so a commented-out flag line does NOT match (the user clearly
# intended to disable it; we respect that and append a separate
# uncommented line, which TOML's last-write-wins semantics resolves to
# `true` at runtime).
#
# `--enable-codex-feature` is accepted as a no-op for back-compat with
# pre-v1.4 install runbooks; passing it is harmless but unnecessary.
codex_feature_check() {
  mkdir -p "$CODEX_DIR"

  # Path A: file absent → create.
  if [ ! -f "$CODEX_CONFIG_TOML" ]; then
    printf '[features]\ncodex_hooks = true\n' >"$CODEX_CONFIG_TOML"
    say "created $CODEX_CONFIG_TOML with [features] codex_hooks = true (active config layer; required per A-M-T1-04)"
    return 0
  fi

  # Path B: flag already set → idempotent no-op.
  if grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$CODEX_CONFIG_TOML" 2>/dev/null; then
    say "codex_hooks feature flag already enabled in $CODEX_CONFIG_TOML"
    return 0
  fi

  # Path C: file present + flag missing → merge.
  # Sub-path C1: [features] block exists → insert codex_hooks under it.
  # Sub-path C2: [features] block absent → append new block at EOF.
  if grep -qE '^[[:space:]]*\[features\][[:space:]]*$' "$CODEX_CONFIG_TOML" 2>/dev/null; then
    # Sub-path C1: awk inline-insert under the FIRST matched [features]
    # header. Preserve user content above and below; only one new line
    # added. No TOML round-trip — pure line-shuffle.
    tmp="$CODEX_CONFIG_TOML.tmp.$$"
    awk '
      BEGIN { added=0 }
      /^[[:space:]]*\[features\][[:space:]]*$/ {
        if (!added) { print; print "codex_hooks = true"; added=1; next }
      }
      { print }
    ' "$CODEX_CONFIG_TOML" >"$tmp" \
      && mv "$tmp" "$CODEX_CONFIG_TOML" \
      || { rm -f "$tmp"; die "failed to merge codex_hooks into $CODEX_CONFIG_TOML"; }
    say "merged codex_hooks = true under existing [features] block in $CODEX_CONFIG_TOML"
  else
    # Sub-path C2: append a new [features] block. The leading blank line
    # is hygiene — separates our addition from prior user content,
    # parsers don't care but humans reading the file appreciate it.
    # Edge case: the existing file may already end with a trailing
    # newline, in which case the leading \n produces a single blank
    # line; if the file ends without a trailing newline, the leading
    # \n still produces a clean separator. Either reading is correct.
    printf '\n[features]\ncodex_hooks = true\n' >>"$CODEX_CONFIG_TOML"
    say "appended [features] codex_hooks = true to $CODEX_CONFIG_TOML"
  fi
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
  # M-T1-05 hygiene: delete the synthetic session row + read-set + lock
  # entries from sessions.json via coord_atomic_edit. The pre-v1.4 path
  # used an inline `jq | mv` that bypassed sessions.lock, racing with
  # the concurrently-running watchdog probe spawned by session_start.sh.
  # Reviewer-mandated atomic_edit cleanup eliminates the race window
  # without introducing a SESSION_END dependency (per D-10 there isn't
  # one for Codex anyway).
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
  say "smoke test passed (session_id $sid)"
}
smoke_test

say "Codex adapter installed at $HOOK_DST + $LIB_DST"
say "next: ensure 'codex' binary is on PATH, then run 'parallels-codex' from inside this repo"

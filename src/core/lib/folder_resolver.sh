#!/usr/bin/env bash
# folder_resolver.sh — locate the active .coord/ root from arbitrary cwd.
# Phase A PR A.5. Replaces the inline `coord_resolve_root` definitions
# previously duplicated across every adapter hook (8 copies).
#
# Resolution algorithm (5 steps, ordered by precedence; first match wins):
#   1. $COORD_DIR env var, when it points to an existing directory.
#   2. Walk up from $1 (or $CLAUDE_PROJECT_DIR, or $PWD) looking for .coord/.
#   3. Walk up from BASH_SOURCE[1] (the calling script) looking for .coord/.
#      Lets a hook installed at .coord/hooks/X.sh resolve correctly even
#      when invoked with cwd outside the project (Claude Code does this
#      occasionally).
#   4. Direct check on $CLAUDE_PROJECT_DIR/.coord (legacy compatibility;
#      step 2 already covers the common case where CLAUDE_PROJECT_DIR
#      itself contains .coord, but explicit step 4 also catches the case
#      where step 2's $1 was passed in non-standard).
#   5. git rev-parse --show-toplevel as last-resort fallback. Optional —
#      coord works in non-git folders post-A.5.
#
# Returns:
#   stdout: absolute path to .coord/ on success.
#   exit 0 on success, exit 1 when .coord/ cannot be found.
#
# Calling convention: hooks call `coord_resolve_root` with no args and
# capture stdout. Direct callers may pass a cwd as $1 to bias step 2.

coord_resolve_root() {
  # 1. COORD_DIR env (highest precedence — lets tests inject a workspace)
  if [ -n "${COORD_DIR:-}" ] && [ -d "$COORD_DIR" ]; then
    printf '%s\n' "$COORD_DIR"
    return 0
  fi

  local cur

  # 2. Walk up from explicit $1, then CLAUDE_PROJECT_DIR, then $PWD.
  cur="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -d "$cur/.coord" ]; then
      printf '%s/.coord\n' "$cur"
      return 0
    fi
    cur=$(dirname "$cur")
  done

  # 3. Walk up from this script's caller (BASH_SOURCE[1]). Useful when
  # cwd has drifted but the hook itself sits inside a project tree.
  if [ -n "${BASH_SOURCE[1]:-}" ]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" 2>/dev/null && pwd)" || script_dir=""
    cur="$script_dir"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      if [ -d "$cur/.coord" ]; then
        printf '%s/.coord\n' "$cur"
        return 0
      fi
      cur=$(dirname "$cur")
    done
  fi

  # 4. Legacy CLAUDE_PROJECT_DIR direct check (covers a rare case where
  # step 2 started from a passed-in $1 and never visited
  # CLAUDE_PROJECT_DIR's tree).
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/.coord" ]; then
    printf '%s/.coord\n' "${CLAUDE_PROJECT_DIR}"
    return 0
  fi

  # 5. git rev-parse fallback. Stays available so existing git-based
  # workflows keep working, but is no longer required.
  local git_root
  git_root=$(git rev-parse --show-toplevel 2>/dev/null) || git_root=""
  if [ -n "$git_root" ] && [ -d "$git_root/.coord" ]; then
    printf '%s/.coord\n' "$git_root"
    return 0
  fi

  return 1
}

#!/usr/bin/env bash
# head_tracking.sh — read-only helpers for git-HEAD tracking.
#
# Per Decision 2.5 (source-matrix, PR-PHASE1-01) and Decision 2.22, multiple
# hooks need to compare a session's stored `git_head` against the current
# repository HEAD to decide whether to mark read-set entries with
# `superseded_by_head_change: true`:
#   - session_start.sh (source=resume branch)
#   - user_prompt_submit.sh (mid-session HEAD drift)
#   - pre_tool_use_any.sh (defensive recheck at tool-call time)
#
# This module provides the two primitive reads. The actual *mutation*
# (marking read_set entries) is intentionally NOT provided here — callers
# compose it into their own atomic_edit filters so the compare-and-mark
# happens as a single atomic transaction rather than two separate writes.
# See session_start.sh resume branch and user_prompt_submit.sh for the
# inline-jq-filter pattern.
#
# Dependencies: git, jq. Uses $COORD_DIR (for coord_stored_head).
# Bash 3.2 compat; sourced, not executed.

# coord_current_head <cwd>
#   Print the repository's current HEAD SHA to stdout, or empty string if
#   the directory is not a git working tree / no HEAD exists yet.
#   Exit status is always 0 — absence of HEAD is not an error.
coord_current_head() {
  local cwd="${1:-.}"
  if git -C "$cwd" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$cwd" rev-parse HEAD 2>/dev/null || printf ''
  else
    printf ''
  fi
}

# coord_stored_head <session_id>
#   Print the `git_head` field stored in sessions.json for the given session,
#   or empty string if the file / session / field is missing or unreadable.
#   Exit status is always 0. Requires $COORD_DIR to point at the coord root.
coord_stored_head() {
  local sid="${1:-}"
  local state="${COORD_DIR:-}/sessions.json"
  if [ -z "$sid" ] || [ ! -f "$state" ]; then
    printf ''
    return 0
  fi
  jq -r --arg sid "$sid" '.sessions[$sid].git_head // ""' "$state" 2>/dev/null || printf ''
}

# coord_head_drifted <session_id> <current_head>
#   Return 0 (true) iff the stored head for this session is non-empty AND
#   differs from <current_head>. Return 1 otherwise (including when the
#   stored head is empty, which means "no prior record — no drift to report").
#   A null/empty current_head cannot drift (returns 1).
coord_head_drifted() {
  local sid="${1:-}"
  local current="${2:-}"
  local stored
  stored=$(coord_stored_head "$sid")
  [ -n "$stored" ] && [ -n "$current" ] && [ "$stored" != "$current" ]
}

# CLI shim for bats / ad-hoc probes:
#   head_tracking.sh current <cwd>
#   head_tracking.sh stored  <sid>
#   head_tracking.sh drifted <sid> <current>    # exit 0 if drifted, 1 if not
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    current) coord_current_head "${1:-.}" ;;
    stored)  coord_stored_head  "${1:-}" ;;
    drifted) coord_head_drifted "${1:-}" "${2:-}" ;;
    *) printf 'usage: head_tracking.sh {current|stored|drifted} ...\n' >&2; exit 2 ;;
  esac
fi

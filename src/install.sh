#!/usr/bin/env bash
# install.sh — one-shot coord installer per plan §4.
#
# Usage:
#   ./install.sh                       # interactive-ish; prompts on ambiguous fs types
#   ./install.sh --yes                 # non-interactive; accept defaults
#   ./install.sh --repair              # overwrite hooks/libs/bin from src/, keep state
#   ./install.sh --uninstall           # remove hook registrations (delegates to coord uninstall)
#   ./install.sh --bypass-permissions  # OPT-IN: also set
#                                      # .claude/settings.local.json
#                                      # permissions.defaultMode = "bypassPermissions".
#                                      # DANGEROUS: disables every Claude Code
#                                      # tool-permission prompt in this repo. Off by
#                                      # default. Combinable with --yes / --repair.
#
# Plan behaviors:
#   1. Locate repo root via `git rev-parse --show-toplevel`.
#   2. Check deps: bash≥3.2, jq, shasum, flock, ps, git, perl (optional).
#   3. Detect filesystem; refuse on NFS/FUSE/iCloud/Dropbox.
#   4. Create .coord/ layout (§3.2).
#   5. Copy src/hooks, src/lib, src/bin, src/agents into .coord/ equivalents.
#   6. Write initial sessions.json, config.json, schema_version (Decision 2.9).
#   7. Append hook entries to .claude/settings.local.json.
#   8. Append .coord/ and .claude/settings.local.json to .gitignore.
#   9. Smoke test: invoke session_start.sh against a canned stdin.
#  10. Print next-steps banner.
#
# Every action is idempotent; repeat runs do not corrupt an existing install.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0
MODE=install
BYPASS=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y)              YES=1 ;;
    --repair)              MODE=repair ;;
    --uninstall)           MODE=uninstall ;;
    --bypass-permissions)  BYPASS=1 ;;
    --help|-h)
      cat <<'USAGE'
usage: install.sh [--yes] [--repair] [--uninstall] [--bypass-permissions]

  --yes, -y               non-interactive; accept defaults
  --repair                overwrite hooks/libs/bin from src/, keep state
  --uninstall             remove coord hook entries from settings.local.json
                          (preserves .coord/ state and audit log)
  --bypass-permissions    OPT-IN: also set
                          .claude/settings.local.json
                          permissions.defaultMode = "bypassPermissions".
                          DANGEROUS — disables every Claude Code tool-permission
                          prompt in this repo. Off by default. Combinable with
                          --yes / --repair.
USAGE
      exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n'  "$*"; }
warn() { printf 'install.sh: warning: %s\n' "$*" >&2; }
die()  { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }

if [ "$BYPASS" = 1 ] && [ "$MODE" = uninstall ]; then
  warn "--bypass-permissions is ignored under --uninstall (uninstall does not modify permissions)"
  BYPASS=0
fi

# --- Step 1: install root (no longer requires a git repo per A.5) ---
# Prefer the git repo top-level when present; fall back to $PWD otherwise.
# Non-git installs print a banner so the user knows where .coord/ landed.
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  say "install root: $REPO_ROOT (git repo top-level)"
else
  REPO_ROOT="$PWD"
  say "install root: $REPO_ROOT (no git repo detected)"
  if [ "${YES:-0}" != 1 ]; then
    say "Note: .coord/ state will live at '$REPO_ROOT/.coord'."
    say "      Re-run with --yes to skip this prompt next time."
    printf 'Continue? (y/n): '
    read -r _ans
    [ "$_ans" = "y" ] || die "install aborted"
  fi
fi

COORD_DIR="$REPO_ROOT/.coord"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.local.json"

# --- Step 2: deps ---
check_bash_version() {
  # Require 3.2+. bash --version prints like "GNU bash, version 3.2.57(1)-release ..."
  local line major minor
  line=$(bash --version | head -1)
  major=$(printf '%s' "$line" | sed -E 's/.*version ([0-9]+)\.([0-9]+).*/\1/')
  minor=$(printf '%s' "$line" | sed -E 's/.*version ([0-9]+)\.([0-9]+).*/\2/')
  if [ -z "$major" ] || [ -z "$minor" ]; then
    warn "could not parse bash version: $line"
    return 0  # soft-pass
  fi
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 2 ]; }; then
    die "bash $major.$minor is too old; need 3.2+"
  fi
}

check_deps() {
  local missing=()
  for c in jq flock shasum ps git; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  check_bash_version
  if ! command -v perl >/dev/null 2>&1; then
    warn "perl not found — events.jsonl timestamps will be seconds, not ms (F-009)"
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    say "Missing required dependencies: ${missing[*]}"
    case "$(uname -s)" in
      Darwin*) say "Install with: brew install ${missing[*]}" ;;
      Linux*)  say "Install via your package manager (apt/dnf/pacman) packages named similarly." ;;
    esac
    die "dependency check failed"
  fi
}

# --- Step 3: filesystem refusal ---
# Parse `mount` for the repo's path and refuse if the backing fs is of a
# known-bad type (NFS / FUSE / iCloud / Dropbox / CIFS / SMB).
detect_fs_type() {
  local path="$1"
  # df -P emits (header line, then) "Filesystem <blocks> <used> <avail> <cap> <mount>".
  # Use the mount point to look up the fs type in `mount` output.
  local mp
  mp=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $NF}') || mp=""
  if [ -z "$mp" ]; then printf 'unknown\n'; return 0; fi
  # mount output differs between macOS and Linux:
  #   macOS:  /dev/X on /path (FS, opts)
  #   Linux:  X on /path type FS (opts)
  # Prefer "type FS" (Linux form); fall back to first paren-token (macOS).
  mount | awk -v mp="$mp" '
    {
      on_idx=0
      for (i=1;i<=NF;i++) if ($i == "on") { on_idx=i; break }
      if (!on_idx) next
      if ($(on_idx+1) != mp) next
      # Linux form: "type FS" follows the mount path.
      for (i=on_idx+2; i<=NF; i++) {
        if ($i == "type") { print $(i+1); exit }
      }
      # macOS form: first paren contains "FS, opts".
      pos = index($0, "(")
      if (pos > 0) {
        rest = substr($0, pos+1)
        n = split(rest, parts, /[,)]/)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[1])
        print parts[1]
      }
      exit
    }'
}

check_filesystem() {
  local fs
  fs=$(detect_fs_type "$REPO_ROOT")
  say "filesystem at repo root: $fs"
  case "$fs" in
    nfs|nfs4|autofs|smbfs|cifs|fuse|fuse.*|osxfuse|macfuse)
      die "filesystem '$fs' is not supported — flock semantics unreliable; use a local volume"
      ;;
    unknown)
      warn "could not determine filesystem type; assuming local POSIX"
      ;;
  esac
  # Extra: refuse on iCloud and Dropbox mount points (heuristic by path).
  case "$REPO_ROOT" in
    *"/Mobile Documents/"*|*"/Dropbox/"*|*"/Google Drive/"*|*"/OneDrive/"*)
      die "repo path contains a cloud-sync prefix; flock semantics unreliable"
      ;;
  esac
  # Smoke-check flock on a scratch file within the repo fs.
  local scratch
  scratch=$(mktemp "$REPO_ROOT/.coord-install-probe.XXXX" 2>/dev/null || printf '')
  if [ -z "$scratch" ]; then die "cannot create a scratch file in $REPO_ROOT"; fi
  trap 'rm -f "$scratch" 2>/dev/null || true' EXIT
  if ! ( flock -x -n 9 ) 9>"$scratch" >/dev/null 2>&1; then
    die "flock is not functional on this filesystem"
  fi
  rm -f "$scratch"; trap - EXIT
}

# --- Steps 4-6: materialize .coord/ and copy source artefacts ---
materialize_coord() {
  mkdir -p "$COORD_DIR" \
           "$COORD_DIR/sessions" \
           "$COORD_DIR/validation" \
           "$COORD_DIR/mediator" \
           "$COORD_DIR/mediator/verdict" \
           "$COORD_DIR/mediator/lockdown_archive" \
           "$COORD_DIR/validator" \
           "$COORD_DIR/validator/verdict" \
           "$COORD_DIR/watchdog" \
           "$COORD_DIR/watchdog/checking" \
           "$COORD_DIR/read_snapshots" \
           "$COORD_DIR/wait_queues" \
           "$COORD_DIR/wakers" \
           "$COORD_DIR/hooks" \
           "$COORD_DIR/lib" \
           "$COORD_DIR/bin" \
           "$COORD_DIR/agents"
  # Copy source artefacts.
  # Core libs: shared across all agent adapters.
  cp -f "$SELF_DIR"/core/lib/*.sh    "$COORD_DIR/lib/"
  # Adapter-specific libs (Claude Code): subagent_filter.sh etc. The runtime
  # layout flattens core + adapter libs into .coord/lib/; hooks resolve a
  # single dir at runtime via dual-fallback LIB_DIR resolution.
  cp -f "$SELF_DIR"/adapters/claude-code/lib/*.sh "$COORD_DIR/lib/"
  # Claude Code hooks (the ones registered in .claude/settings.local.json).
  cp -f "$SELF_DIR"/adapters/claude-code/hooks/*.sh  "$COORD_DIR/hooks/"
  if [ -d "$SELF_DIR/agents" ]; then
    # Agents may not exist yet in Phase 0; copy only .md files if present.
    if ls "$SELF_DIR/agents"/*.md >/dev/null 2>&1; then
      cp -f "$SELF_DIR/agents"/*.md "$COORD_DIR/hooks/" 2>/dev/null || true
    fi
  fi
  # bin: copy coord CLI (may be absent in very early Phase 0 commits).
  if [ -f "$SELF_DIR/core/bin/coord" ]; then
    cp -f "$SELF_DIR/core/bin/coord" "$COORD_DIR/bin/coord"
  fi
  # T3.07: copy MEDIATOR_REFERENCE.md alongside lib/. Idempotent —
  # if the user customized the installed copy, preserve it (compare
  # via shasum); otherwise update.
  if [ -f "$SELF_DIR/core/lib/MEDIATOR_REFERENCE.md" ]; then
    local ref_dst="$COORD_DIR/mediator/MEDIATOR_REFERENCE.md"
    if [ -f "$ref_dst" ]; then
      local src_hash dst_hash
      src_hash=$(shasum -a 256 "$SELF_DIR/core/lib/MEDIATOR_REFERENCE.md" 2>/dev/null | awk '{print $1}')
      dst_hash=$(shasum -a 256 "$ref_dst" 2>/dev/null | awk '{print $1}')
      if [ -n "$src_hash" ] && [ -n "$dst_hash" ] && [ "$src_hash" != "$dst_hash" ]; then
        # Backup user-customized copy before overwriting on --repair;
        # leave alone on plain re-install.
        if [ "$MODE" = "repair" ]; then
          cp -f "$ref_dst" "${ref_dst}.user-backup.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
          cp -f "$SELF_DIR/core/lib/MEDIATOR_REFERENCE.md" "$ref_dst"
        fi
      else
        # Hashes match or one missing — safe to overwrite (idempotent).
        cp -f "$SELF_DIR/core/lib/MEDIATOR_REFERENCE.md" "$ref_dst" 2>/dev/null || true
      fi
    else
      cp -f "$SELF_DIR/core/lib/MEDIATOR_REFERENCE.md" "$ref_dst" 2>/dev/null || true
    fi
  fi
  # T4.05: copy VALIDATOR_REFERENCE.md alongside the validator lib.
  # Idempotent with same user-customization-preservation contract as
  # MEDIATOR_REFERENCE.md above.
  if [ -f "$SELF_DIR/core/lib/VALIDATOR_REFERENCE.md" ]; then
    local vref_dst="$COORD_DIR/validator/VALIDATOR_REFERENCE.md"
    if [ -f "$vref_dst" ]; then
      local vsrc_hash vdst_hash
      vsrc_hash=$(shasum -a 256 "$SELF_DIR/core/lib/VALIDATOR_REFERENCE.md" 2>/dev/null | awk '{print $1}')
      vdst_hash=$(shasum -a 256 "$vref_dst" 2>/dev/null | awk '{print $1}')
      if [ -n "$vsrc_hash" ] && [ -n "$vdst_hash" ] && [ "$vsrc_hash" != "$vdst_hash" ]; then
        if [ "$MODE" = "repair" ]; then
          cp -f "$vref_dst" "${vref_dst}.user-backup.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
          cp -f "$SELF_DIR/core/lib/VALIDATOR_REFERENCE.md" "$vref_dst"
        fi
      else
        cp -f "$SELF_DIR/core/lib/VALIDATOR_REFERENCE.md" "$vref_dst" 2>/dev/null || true
      fi
    else
      cp -f "$SELF_DIR/core/lib/VALIDATOR_REFERENCE.md" "$vref_dst" 2>/dev/null || true
    fi
  fi

  chmod +x "$COORD_DIR/lib"/*.sh "$COORD_DIR/hooks"/*.sh
  [ -f "$COORD_DIR/bin/coord" ] && chmod +x "$COORD_DIR/bin/coord"

  # schema_version (single-line; Decision 2.9).
  # 1.1 (PR B.1): session rows carry `agent` field. Readers
  # tolerate 1.0 files via `// "claude_code"` defaults.
  printf '1.1\n' >"$COORD_DIR/schema_version"

  # config.json (plan §3.6 + PR-PHASE5-02 §D wait_backend).
  if [ ! -s "$COORD_DIR/config.json" ] || [ "$MODE" = repair ]; then
    cat >"$COORD_DIR/config.json" <<'JSON'
{
  "schema_version": "1.1",
  "task_delegation": true,
  "lock_ttl_seconds": 900,
  "watchdog_suspicion_seconds": 1200,
  "watchdog_confirm_seconds": 1500,
  "read_set_cap_per_session": 200,
  "wait_poll_schedule_seconds": [30, 60, 120],
  "wait_max_seconds": 570,
  "wait_backend": "auto",
  "max_task_chain_depth": 3,
  "max_tasks_per_lock": 5,
  "max_anchor_window_lines": 10,
  "validator_enabled": true,
  "mediator_enabled": true
}
JSON
  fi

  # PR-PHASE5-02 §4: detect wake-event backend (fswatch / inotifywait /
  # polling) and bake the resolved value into config.json. Auto-detection
  # runs at install + --repair so an admin install on a fresh host gets
  # the right backend without an extra step. Records WAIT_BACKEND_DETECTED
  # for the audit trail (idempotent at repair: re-emits with current
  # detection result).
  if [ -f "$COORD_DIR/lib/wait_backend.sh" ] && [ -f "$COORD_DIR/lib/log_event.sh" ]; then
    local _wb_backend _wb_platform _wb_tmp
    # shellcheck disable=SC1091
    . "$COORD_DIR/lib/log_event.sh"
    # shellcheck disable=SC1091
    . "$COORD_DIR/lib/wait_backend.sh"
    _wb_backend=$(coord_wait_backend_detect)
    _wb_platform=$(coord_wait_backend_platform)
    _wb_tmp="$COORD_DIR/config.json.wb.$$"
    if jq --arg b "$_wb_backend" '.wait_backend = $b' \
         "$COORD_DIR/config.json" >"$_wb_tmp" 2>/dev/null; then
      mv "$_wb_tmp" "$COORD_DIR/config.json"
    else
      rm -f "$_wb_tmp" 2>/dev/null || true
    fi
    coord_log_event kind=WAIT_BACKEND_DETECTED \
      source=install \
      backend="$_wb_backend" \
      platform="$_wb_platform" \
      mode="$MODE" 2>/dev/null || true
  fi

  # sessions.json — initialize only if missing or repair.
  if [ ! -s "$COORD_DIR/sessions.json" ] || [ "$MODE" = repair ]; then
    "$COORD_DIR/lib/atomic_write.sh" template >"$COORD_DIR/sessions.json"
  fi

  # Lock sentinels.
  for f in sessions.lock events.lock history.lock; do
    : >"$COORD_DIR/$f"
  done

  # Watchdog cache layout (T3.04 / PR-PHASE3-02 §E):
  # recent_checks.jsonl is append-only; recent_checks.lock is the flock
  # sentinel. Idempotent: only create if absent, never clobber existing
  # cache entries on --repair.
  [ -f "$COORD_DIR/watchdog/recent_checks.jsonl" ] || \
    : >"$COORD_DIR/watchdog/recent_checks.jsonl"
  [ -f "$COORD_DIR/watchdog/recent_checks.lock" ] || \
    : >"$COORD_DIR/watchdog/recent_checks.lock"

  # Mediator pending JSONL queue layout (T2.04 + T3.07 / PR-PHASE3-03):
  # pending.jsonl is append-only; pending.lock is the flock sentinel;
  # pending.consumed is the high-water-mark file (single integer line).
  [ -f "$COORD_DIR/mediator/pending.jsonl" ] || \
    : >"$COORD_DIR/mediator/pending.jsonl"
  [ -f "$COORD_DIR/mediator/pending.lock" ] || \
    : >"$COORD_DIR/mediator/pending.lock"

  # Legacy pending.json migration (T3.07 / PR-PHASE3-03 / Decision 4):
  # Pre-Phase-3 installs used a single-file pending.json for
  # corrupt_state. Migrate any active entry forward into the unified
  # pending.jsonl queue, then delete the legacy file. Idempotent: if
  # pending.json is absent, no-op.
  if [ -f "$COORD_DIR/mediator/pending.json" ]; then
    local legacy="$COORD_DIR/mediator/pending.json"
    if jq -e . "$legacy" >/dev/null 2>&1; then
      # Valid JSON: shape into the new top-level + payload form.
      local migrated_line
      migrated_line=$(jq -c '
        {
          ts: (.ts // "1970-01-01T00:00:00Z"),
          kind: (.kind // "unknown"),
          session: null,
          source: "install_migration",
          payload: (. | del(.ts) | del(.kind))
        }
      ' "$legacy" 2>/dev/null)
      if [ -n "$migrated_line" ]; then
        printf '%s\n' "$migrated_line" >>"$COORD_DIR/mediator/pending.jsonl"
      fi
      rm -f "$legacy" 2>/dev/null || true
    else
      # Unparseable legacy file: archive forensically; do not migrate.
      mv "$legacy" "${legacy}.legacy.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || rm -f "$legacy" 2>/dev/null
    fi
  fi

  # sessions_history.json.
  if [ ! -s "$COORD_DIR/sessions_history.json" ] || [ "$MODE" = repair ]; then
    jq -n '{schema_version:"1.1", events:[]}' >"$COORD_DIR/sessions_history.json"
  fi

  # events.jsonl — just ensure exists.
  : >>"$COORD_DIR/events.jsonl"
}

# --- Step 7: hook registrations in .claude/settings.local.json ---
register_hooks() {
  mkdir -p "$REPO_ROOT/.claude"
  local tmp current
  tmp=$(mktemp)
  if [ -s "$CLAUDE_SETTINGS" ]; then
    current=$(cat "$CLAUDE_SETTINGS")
    # Validate it parses; if not, fail loudly — we won't silently overwrite.
    if ! printf '%s' "$current" | jq -e . >/dev/null 2>&1; then
      die "$CLAUDE_SETTINGS is not valid JSON; refusing to overwrite. Fix or remove it and re-run."
    fi
  else
    current='{}'
  fi

  # Strategy:
  #   1. Remove any prior coord-owned entries (commands under .coord/hooks/)
  #      from EVERY event's hook list. This preserves user-authored entries
  #      sitting alongside ours.
  #   2. Append our Phase-2 hook set:
  #        SessionStart       → session_start.sh         (matcher *)
  #        SessionEnd         → session_end.sh           (matcher *)
  #        Stop               → stop.sh                  (matcher *)              ← Phase 2 T2.02
  #        UserPromptSubmit   → user_prompt_submit.sh    (matcher *)
  #        PreToolUse         → pre_tool_use_any.sh      (matcher *)
  #                             pre_tool_use_read.sh     (matcher Read)
  #                             pre_tool_use_write.sh    (matcher Write|Edit|NotebookEdit)
  #        PostToolUse        → post_tool_use_write.sh   (matcher Write|Edit|NotebookEdit)  ← Phase 2 T2.01
  #   3. If --bypass-permissions was passed, also set
  #      .permissions.defaultMode = "bypassPermissions". This is OPT-IN ONLY:
  #      the default install never touches the .permissions object so user-
  #      authored allow/deny lists and modes are preserved verbatim.
  #
  # Idempotent: re-running install/--repair strips the prior entries and
  # re-adds the current set, so changes to commands/timeouts roll forward.
  # --bypass-permissions on a re-run idempotently re-asserts the bypass
  # mode; omitting the flag on a re-run leaves any existing defaultMode
  # alone (we never silently demote a user's chosen mode).
  printf '%s' "$current" | jq \
      --arg hdir "$COORD_DIR/hooks" \
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
}

# --- Step 8: .gitignore entries ---
gitignore_entries() {
  local gi="$REPO_ROOT/.gitignore"
  # Skip entirely when not a git repo AND no pre-existing .gitignore.
  # Per A.5: non-git installs are a supported configuration.
  if [ ! -d "$REPO_ROOT/.git" ] && [ ! -f "$gi" ]; then
    say "skipping .gitignore (no git repo, no existing .gitignore)"
    return 0
  fi
  [ -f "$gi" ] || : >"$gi"
  local entry
  for entry in '.coord/' '.claude/settings.local.json' 'IMPLEMENTATION_LOG.md' 'FINDINGS.md' 'phase-*-signoff.md' 'phase0-verification.md'; do
    if ! grep -qxF "$entry" "$gi" 2>/dev/null; then
      printf '%s\n' "$entry" >>"$gi"
    fi
  done
}

# --- Step 9: smoke test ---
smoke_test() {
  local sid="install-smoke-$RANDOM"
  # Run session_start.sh with CLAUDE_COORD=1 against canned stdin.
  local out
  out=$(CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$REPO_ROOT" \
         "$COORD_DIR/hooks/session_start.sh" <<EOF
{"session_id":"$sid","cwd":"$REPO_ROOT","hook_event_name":"SessionStart","source":"startup"}
EOF
  )
  # Validate banner output.
  if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null 2>&1; then
    die "smoke test failed: session_start did not emit banner"
  fi
  # Active marker should exist
  [ -e "$COORD_DIR/sessions/$sid.active" ] \
    || die "smoke test failed: .active marker not created"
  # Tear down the smoke session (session_end).
  CLAUDE_COORD=1 "$COORD_DIR/hooks/session_end.sh" <<EOF >/dev/null 2>&1
{"session_id":"$sid","hook_event_name":"SessionEnd","reason":"install-smoke"}
EOF
  [ ! -e "$COORD_DIR/sessions/$sid.active" ] \
    || die "smoke test failed: .active marker not removed after SessionEnd"
  say "smoke test passed"
}

# --- uninstall mode (delegates to coord uninstall semantics) ---
if [ "$MODE" = uninstall ]; then
  say "uninstall: removing hook entries from $CLAUDE_SETTINGS (leaving .coord/ in place)"
  if [ -s "$CLAUDE_SETTINGS" ]; then
    tmp=$(mktemp)
    # Strip any coord-owned entries (commands under .coord/hooks/) across
    # ALL events; preserves user-authored entries alongside ours.
    jq '
      if has("hooks") then
        .hooks |= with_entries(
          .value |= ((. // []) | map(
            .hooks = ((.hooks // []) | map(select(((.command // "") | contains("/.coord/hooks/")) | not)))
          ) | map(select((.hooks // []) | length > 0)))
        )
      else . end
    ' "$CLAUDE_SETTINGS" >"$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    say "hooks entries removed from settings.local.json"
  fi
  say "uninstall complete; .coord/ directory, IMPLEMENTATION_LOG.md, FINDINGS.md left untouched"
  say "to fully remove: rm -rf .coord   (destructive)"
  exit 0
fi

# --- install / repair flow ---
if [ "$BYPASS" = 1 ]; then
  warn "--bypass-permissions ENABLED — settings.local.json will set permissions.defaultMode=\"bypassPermissions\" (every Claude Code tool-permission prompt in this repo will be auto-approved)"
fi
say "[1/8] checking dependencies"
check_deps
say "[2/8] checking filesystem"
check_filesystem
say "[3/8] materializing .coord/"
materialize_coord
say "[4/8] registering hooks in $CLAUDE_SETTINGS"
register_hooks
say "[5/8] updating .gitignore"
gitignore_entries
say "[6/8] running smoke test"
smoke_test
say "[7/8] coord installation ready"
say ""
say "[8/8] next steps:"
say "  1. Set CLAUDE_COORD=1 in the shell that launches Claude Code, e.g.:"
say "       export CLAUDE_COORD=1"
say "     and then start claude as usual."
say "  2. Verify with:  $COORD_DIR/bin/coord status"
say "  3. Uninstall with: $SELF_DIR/install.sh --uninstall"
if [ "$BYPASS" = 1 ]; then
  say ""
  say "  permissions.defaultMode is now \"bypassPermissions\" in:"
  say "       $CLAUDE_SETTINGS"
  say "  To revert: edit that file and remove the \"defaultMode\" key under \"permissions\","
  say "  or replace its value with \"default\" / \"acceptEdits\" / \"plan\"."
fi

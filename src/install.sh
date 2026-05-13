#!/usr/bin/env bash
# install.sh — coord top-level adapter dispatcher (PR E.2 rewrite).
#
# Dispatches to per-adapter installers under src/adapters/<agent>/install.sh.
# This script handles the SHARED concerns (deps, filesystem, .coord/
# materialization, .gitignore) and then runs the requested adapter
# installers, which handle their own hooks/libs/registration.
#
# Usage:
#   ./install.sh                              # claude (back-compat) + auto-codex
#   ./install.sh --yes                        # non-interactive
#   ./install.sh --repair                     # overwrite hooks/libs, keep state
#   ./install.sh --uninstall                  # strip hook entries, leave .coord/
#   ./install.sh --bypass-permissions         # OPT-IN claude permissions bypass
#
#   Adapter selection (default behavior preserves Claude back-compat):
#   ./install.sh --with-codex                 # install codex too (errors if
#                                              codex binary not on PATH)
#   ./install.sh --without-codex              # skip codex even if on PATH
#   ./install.sh --with-claude-code           # explicit claude (default)
#   ./install.sh --without-claude-code        # skip claude (codex-only install)
#   ./install.sh --with-claude-code --with-codex
#                                              # both, errors if either CLI absent
#
# Default selection rules (no explicit --with-*/--without-* flags):
#   - claude:  always enabled (back-compat — `bash src/install.sh` has
#              always meant "install claude" since Phase 0).
#   - codex:   auto-enabled when `codex` is on PATH; silently skipped
#              otherwise (no error). Per reviewer guidance: explicit
#              --with-codex with missing codex binary errors clearly;
#              auto-detect with missing binary silently proceeds.
#
# Every action is idempotent; repeat runs do not corrupt an existing install.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="install"
YES="0"
BYPASS="0"
WITH_CLAUDE=""    # tri-state: ""=auto, "1"=force on, "0"=force off
WITH_CODEX=""
ENABLE_CODEX_FEATURE="0"

for arg in "$@"; do
  case "$arg" in
    --yes|-y)                  YES="1" ;;
    --repair)                  MODE="repair" ;;
    --uninstall)               MODE="uninstall" ;;
    --bypass-permissions)      BYPASS="1" ;;
    --with-claude-code)        WITH_CLAUDE="1" ;;
    --without-claude-code)     WITH_CLAUDE="0" ;;
    --with-codex)              WITH_CODEX="1" ;;
    --without-codex)           WITH_CODEX="0" ;;
    --enable-codex-feature)    ENABLE_CODEX_FEATURE="1" ;;
    --help|-h)
      cat <<'USAGE'
usage: install.sh [--yes] [--repair] [--uninstall] [--bypass-permissions]
                  [--with-claude-code | --without-claude-code]
                  [--with-codex       | --without-codex]
                  [--enable-codex-feature]

  Modes:
    --yes, -y               non-interactive; accept defaults
    --repair                overwrite hooks/libs/bin from src/, keep state
    --uninstall             remove coord hook entries from each adapter's
                            settings file (preserves .coord/ state)
    --bypass-permissions    OPT-IN claude .permissions.defaultMode bypass

  Adapter selection (default = claude always + codex if codex on PATH):
    --with-claude-code      install Claude Code adapter (default ON)
    --without-claude-code   skip Claude
    --with-codex            install Codex adapter; errors if codex absent
    --without-codex         skip Codex even if codex on PATH
    --enable-codex-feature  DEPRECATED no-op (kept for back-compat).
                            Per A-M-T1-04 (plan v1.4 / commit 8cec664)
                            the Codex installer now ALWAYS writes
                            [features] codex_hooks = true into
                            .codex/config.toml; passing this flag is
                            harmless but unnecessary.
USAGE
      exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n'  "$*"; }
warn() { printf 'install.sh: warning: %s\n' "$*" >&2; }
die()  { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }

# === step 1: install root resolution ===
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  say "install root: $REPO_ROOT (git repo top-level)"
else
  REPO_ROOT="$PWD"
  say "install root: $REPO_ROOT (no git repo detected)"
  if [ "$YES" != "1" ] && [ "$MODE" != "uninstall" ]; then
    say "Note: .coord/ state will live at '$REPO_ROOT/.coord'."
    say "      Re-run with --yes to skip this prompt next time."
    printf 'Continue? (y/n): '
    read -r _ans
    [ "$_ans" = "y" ] || die "install aborted"
  fi
fi

COORD_DIR="$REPO_ROOT/.coord"

# === step 2: resolve adapter selection ===
# `claude` binary presence is informational ONLY for the dispatcher: Claude
# install is the back-compat default, so it runs regardless. Verifying the
# binary is on PATH is the user's responsibility (they may install claude
# CLI later). The Codex side is stricter — explicit --with-codex requires
# the binary to be present per reviewer guidance.

claude_available="0"
codex_available="0"
command -v claude >/dev/null 2>&1 && claude_available="1"
command -v codex  >/dev/null 2>&1 && codex_available="1"

# Resolve final on/off per adapter.
if [ -z "$WITH_CLAUDE" ]; then
  WITH_CLAUDE="1"   # default ON for back-compat
fi
if [ -z "$WITH_CODEX" ]; then
  if [ "$codex_available" = "1" ]; then
    WITH_CODEX="1"
    say "codex binary detected on PATH → enabling Codex adapter (use --without-codex to skip)"
  else
    WITH_CODEX="0"
  fi
else
  if [ "$WITH_CODEX" = "1" ] && [ "$codex_available" = "0" ]; then
    die "--with-codex passed explicitly but \`codex\` binary is not on PATH. Install Codex CLI from https://github.com/openai/codex (or drop --with-codex for back-compat behavior)."
  fi
fi

if [ "$WITH_CLAUDE" = "0" ] && [ "$WITH_CODEX" = "0" ]; then
  die "no adapters selected — both --without-claude-code and --without-codex (or codex absent). Nothing to install."
fi

# === step 3: deps ===
check_bash_version() {
  local line major minor
  line=$(bash --version | head -1)
  major=$(printf '%s' "$line" | sed -E 's/.*version ([0-9]+)\.([0-9]+).*/\1/')
  minor=$(printf '%s' "$line" | sed -E 's/.*version ([0-9]+)\.([0-9]+).*/\2/')
  if [ -z "$major" ] || [ -z "$minor" ]; then
    warn "could not parse bash version: $line"; return 0
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

# === step 4: filesystem refusal ===
detect_fs_type() {
  local path="$1"
  local mp
  mp=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $NF}') || mp=""
  if [ -z "$mp" ]; then printf 'unknown\n'; return 0; fi
  mount | awk -v mp="$mp" '
    {
      on_idx=0
      for (i=1;i<=NF;i++) if ($i == "on") { on_idx=i; break }
      if (!on_idx) next
      if ($(on_idx+1) != mp) next
      for (i=on_idx+2; i<=NF; i++) {
        if ($i == "type") { print $(i+1); exit }
      }
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
  case "$REPO_ROOT" in
    *"/Mobile Documents/"*|*"/Dropbox/"*|*"/Google Drive/"*|*"/OneDrive/"*)
      die "repo path contains a cloud-sync prefix; flock semantics unreliable"
      ;;
  esac
  local scratch
  scratch=$(mktemp "$REPO_ROOT/.coord-install-probe.XXXX" 2>/dev/null || printf '')
  if [ -z "$scratch" ]; then die "cannot create a scratch file in $REPO_ROOT"; fi
  trap 'rm -f "$scratch" 2>/dev/null || true' EXIT
  if ! ( flock -x -n 9 ) 9>"$scratch" >/dev/null 2>&1; then
    die "flock is not functional on this filesystem"
  fi
  rm -f "$scratch"; trap - EXIT
}

# === step 5: materialize SHARED .coord/ infrastructure ===
# Adapter-specific lib/hook copies happen in each adapter's installer.
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

  # Core libs: shared across all agent adapters.
  cp -f "$SELF_DIR"/core/lib/*.sh "$COORD_DIR/lib/"

  # coord CLI binary (shared).
  if [ -f "$SELF_DIR/core/bin/coord" ]; then
    cp -f "$SELF_DIR/core/bin/coord" "$COORD_DIR/bin/coord"
  fi

  # Reference docs (shared; idempotent with user-customization preservation).
  for ref_pair in "core/lib/MEDIATOR_REFERENCE.md:mediator/MEDIATOR_REFERENCE.md" \
                  "core/lib/VALIDATOR_REFERENCE.md:validator/VALIDATOR_REFERENCE.md"; do
    src_rel="${ref_pair%%:*}"
    dst_rel="${ref_pair##*:}"
    src_path="$SELF_DIR/$src_rel"
    dst_path="$COORD_DIR/$dst_rel"
    [ -f "$src_path" ] || continue
    if [ -f "$dst_path" ]; then
      local sh dh
      sh=$(shasum -a 256 "$src_path" 2>/dev/null | awk '{print $1}')
      dh=$(shasum -a 256 "$dst_path" 2>/dev/null | awk '{print $1}')
      if [ -n "$sh" ] && [ -n "$dh" ] && [ "$sh" != "$dh" ]; then
        if [ "$MODE" = "repair" ]; then
          cp -f "$dst_path" "${dst_path}.user-backup.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
          cp -f "$src_path" "$dst_path"
        fi
      else
        cp -f "$src_path" "$dst_path" 2>/dev/null || true
      fi
    else
      cp -f "$src_path" "$dst_path" 2>/dev/null || true
    fi
  done

  chmod +x "$COORD_DIR/lib"/*.sh
  [ -f "$COORD_DIR/bin/coord" ] && chmod +x "$COORD_DIR/bin/coord"

  # schema_version + config.json + sessions.json + lock sentinels.
  printf '1.1\n' >"$COORD_DIR/schema_version"

  if [ ! -s "$COORD_DIR/config.json" ] || [ "$MODE" = "repair" ]; then
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

  # Detect wake-event backend (PR-PHASE5-02 §4).
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

  if [ ! -s "$COORD_DIR/sessions.json" ] || [ "$MODE" = "repair" ]; then
    "$COORD_DIR/lib/atomic_write.sh" template >"$COORD_DIR/sessions.json"
  fi

  for f in sessions.lock events.lock history.lock; do
    : >"$COORD_DIR/$f"
  done

  [ -f "$COORD_DIR/watchdog/recent_checks.jsonl" ] || \
    : >"$COORD_DIR/watchdog/recent_checks.jsonl"
  [ -f "$COORD_DIR/watchdog/recent_checks.lock" ] || \
    : >"$COORD_DIR/watchdog/recent_checks.lock"

  [ -f "$COORD_DIR/mediator/pending.jsonl" ] || \
    : >"$COORD_DIR/mediator/pending.jsonl"
  [ -f "$COORD_DIR/mediator/pending.lock" ] || \
    : >"$COORD_DIR/mediator/pending.lock"

  # Legacy pending.json migration (T3.07 / PR-PHASE3-03 / Decision 4).
  if [ -f "$COORD_DIR/mediator/pending.json" ]; then
    local legacy="$COORD_DIR/mediator/pending.json"
    if jq -e . "$legacy" >/dev/null 2>&1; then
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
      mv "$legacy" "${legacy}.legacy.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || rm -f "$legacy" 2>/dev/null
    fi
  fi

  if [ ! -s "$COORD_DIR/sessions_history.json" ] || [ "$MODE" = "repair" ]; then
    jq -n '{schema_version:"1.1", events:[]}' >"$COORD_DIR/sessions_history.json"
  fi

  : >>"$COORD_DIR/events.jsonl"
}

# === step 6: .gitignore management ===
gitignore_entries() {
  local gi="$REPO_ROOT/.gitignore"
  if [ ! -d "$REPO_ROOT/.git" ] && [ ! -f "$gi" ]; then
    say "skipping .gitignore (no git repo, no existing .gitignore)"
    return 0
  fi
  [ -f "$gi" ] || : >"$gi"
  local entry
  for entry in '.coord/' '.claude/settings.local.json' '.codex/hooks.json' \
               'IMPLEMENTATION_LOG.md' 'FINDINGS.md' 'phase-*-signoff.md' \
               'phase0-verification.md'; do
    if ! grep -qxF "$entry" "$gi" 2>/dev/null; then
      printf '%s\n' "$entry" >>"$gi"
    fi
  done
}

# === step 7: dispatch to adapter installers ===
dispatch_adapter() {
  local adapter="$1"; shift
  local script="$SELF_DIR/adapters/$adapter/install.sh"
  if [ ! -x "$script" ]; then
    die "adapter installer missing or not executable: $script"
  fi
  "$script" "$@"
}

build_adapter_args() {
  local args=()
  [ "$YES" = "1" ]    && args+=("--yes")
  [ "$BYPASS" = "1" ] && args+=("--bypass-permissions")
  [ "$MODE" = "repair" ] && args+=("--repair")
  args+=("--repo-root" "$REPO_ROOT")
  printf '%s\n' "${args[@]}"
}

# === uninstall mode ===
if [ "$MODE" = "uninstall" ]; then
  say "uninstall: dispatching to adapter installers (leaving .coord/ in place)"
  if [ "$WITH_CLAUDE" = "1" ]; then
    "$SELF_DIR/adapters/claude-code/install.sh" --uninstall --repo-root "$REPO_ROOT" || true
  fi
  if [ "$WITH_CODEX" = "1" ]; then
    "$SELF_DIR/adapters/codex/install.sh" --uninstall --repo-root "$REPO_ROOT" || true
  fi
  say "uninstall complete; .coord/ directory and audit log left untouched"
  say "to fully remove: rm -rf .coord   (destructive)"
  exit 0
fi

# === install / repair flow ===
if [ "$BYPASS" = "1" ]; then
  warn "--bypass-permissions ENABLED — Claude .claude/settings.local.json will set permissions.defaultMode=\"bypassPermissions\""
fi

say "[1/6] checking dependencies"
check_deps
say "[2/6] checking filesystem"
check_filesystem
say "[3/6] materializing shared .coord/"
materialize_coord
say "[4/6] updating .gitignore"
gitignore_entries

say "[5/6] dispatching to adapter installers"
ADAPTER_ARGS=()
[ "$YES" = "1" ]      && ADAPTER_ARGS+=("--yes")
[ "$BYPASS" = "1" ]   && ADAPTER_ARGS+=("--bypass-permissions")
[ "$MODE" = "repair" ] && ADAPTER_ARGS+=("--repair")
ADAPTER_ARGS+=("--repo-root" "$REPO_ROOT")

if [ "$WITH_CLAUDE" = "1" ]; then
  say "  → claude-code adapter"
  "$SELF_DIR/adapters/claude-code/install.sh" "${ADAPTER_ARGS[@]}"
fi
if [ "$WITH_CODEX" = "1" ]; then
  say "  → codex adapter"
  CODEX_ARGS=("${ADAPTER_ARGS[@]}")
  # --bypass-permissions is claude-only; strip from codex args.
  CODEX_ARGS_FILTERED=()
  for a in "${CODEX_ARGS[@]}"; do
    [ "$a" = "--bypass-permissions" ] && continue
    CODEX_ARGS_FILTERED+=("$a")
  done
  [ "$ENABLE_CODEX_FEATURE" = "1" ] && CODEX_ARGS_FILTERED+=("--enable-codex-feature")
  "$SELF_DIR/adapters/codex/install.sh" "${CODEX_ARGS_FILTERED[@]}"
fi

say "[6/6] coord installation ready"
say ""
say "next steps:"
if [ "$WITH_CLAUDE" = "1" ]; then
  say "  Claude:"
  say "    Set CLAUDE_COORD=1 and start claude as usual, OR run \`parallels-claude\`."
fi
if [ "$WITH_CODEX" = "1" ]; then
  say "  Codex:"
  say "    Run \`parallels-codex\` to start a coordinated Codex session."
  # Pre-v1.4 the dispatcher printed a NOTE block here whenever
  # .codex/config.toml lacked codex_hooks = true. Per A-M-T1-04 the codex
  # adapter now writes the flag unconditionally, so the warning path is
  # unreachable and the block was removed.
fi
say "  Verify:    $COORD_DIR/bin/coord status"
say "  Uninstall: bash $SELF_DIR/install.sh --uninstall"

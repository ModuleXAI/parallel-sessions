#!/usr/bin/env bats
# Tests for src/install.sh as adapter dispatcher (PR E.2).
#
# Coverage matrix:
#   Default behavior (back-compat: claude on, codex auto-detect)
#   Explicit --with-codex with codex absent → error
#   --without-claude-code: claude artifacts skipped
#   --without-codex: codex artifacts skipped even if codex on PATH
#   Both adapters installed simultaneously
#   --uninstall dispatches to both adapters
#   Auto-detect: codex absent silently skipped (no error)
#
# Test isolation: bats puts a stub `codex` (and optionally `claude`) on
# PATH via a sandbox bin directory so tests don't depend on which CLIs
# the developer happens to have installed.

load "../helpers/common"

INSTALL="$SRC_ROOT/install.sh"

setup() {
  TMP="$(mktemp -d -t coord-disp-XXXX)"
  STUB_BIN="$TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  # Sandbox PATH: keep system tools (jq, flock, git, perl, mount, etc.)
  # but control whether claude/codex stubs are visible. /sbin and
  # /usr/sbin host `mount` on macOS+Linux — install.sh's filesystem
  # check uses it.
  export TEST_BASE_PATH="$STUB_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  # Initialize as a git repo so install.sh's git rev-parse path works.
  ( cd "$TMP" && git init -q && git config user.email t@t && git config user.name T )
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR TEST_BASE_PATH
  rm -rf "$TMP"
}

# Helpers
_make_codex_stub() {
  cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/codex"
}
_make_claude_stub() {
  cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_BIN/claude"
}

# === Default behavior ===

@test "dispatcher: default install (no flags) → claude only when codex absent" {
  cd "$TMP"
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes
  [ "$status" -eq 0 ]
  [ -f "$TMP/.claude/settings.local.json" ]
  [ -d "$TMP/.coord/hooks" ]
  # Claude hooks installed flat at .coord/hooks/.
  [ -x "$TMP/.coord/hooks/session_start.sh" ]
  # Codex NOT installed.
  [ ! -d "$TMP/.coord/hooks/codex" ]
  [ ! -f "$TMP/.codex/hooks.json" ]
}

@test "dispatcher: default install with codex on PATH → both adapters auto-installed" {
  cd "$TMP"
  _make_codex_stub
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'codex binary detected on PATH'
  # Both layouts present.
  [ -f "$TMP/.claude/settings.local.json" ]
  [ -x "$TMP/.coord/hooks/session_start.sh" ]
  [ -d "$TMP/.coord/hooks/codex" ]
  [ -x "$TMP/.coord/hooks/codex/session_start.sh" ]
  [ -f "$TMP/.codex/hooks.json" ]
  # Codex hooks.json has all 5 events.
  run jq -r '.hooks | keys | sort | join(",")' "$TMP/.codex/hooks.json"
  [ "$output" = "PostToolUse,PreToolUse,SessionStart,Stop,UserPromptSubmit" ]
}

# === Explicit flags ===

@test "dispatcher: --with-codex without codex binary → error clearly" {
  cd "$TMP"
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes --with-codex
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\-\-with-codex passed explicitly'
  echo "$output" | grep -q 'codex.*not on PATH'
  # Nothing installed.
  [ ! -d "$TMP/.coord" ]
}

@test "dispatcher: --without-codex skips codex even when on PATH" {
  cd "$TMP"
  _make_codex_stub
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes --without-codex
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'codex binary detected on PATH'
  # Claude installed.
  [ -f "$TMP/.claude/settings.local.json" ]
  # Codex NOT installed.
  [ ! -d "$TMP/.coord/hooks/codex" ]
  [ ! -f "$TMP/.codex/hooks.json" ]
}

@test "dispatcher: --without-claude-code --with-codex → codex only" {
  cd "$TMP"
  _make_codex_stub
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes --without-claude-code --with-codex
  [ "$status" -eq 0 ]
  # Claude NOT installed.
  [ ! -f "$TMP/.claude/settings.local.json" ]
  # The shared .coord/hooks/ directory exists (materialize_coord creates
  # it for shared layout) but has NO claude hook scripts.
  ! ls "$TMP/.coord/hooks"/*.sh >/dev/null 2>&1
  # Codex installed.
  [ -d "$TMP/.coord/hooks/codex" ]
  [ -f "$TMP/.codex/hooks.json" ]
}

@test "dispatcher: both adapters explicit → both installed" {
  cd "$TMP"
  _make_codex_stub
  _make_claude_stub
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes --with-claude-code --with-codex
  [ "$status" -eq 0 ]
  [ -f "$TMP/.claude/settings.local.json" ]
  [ -f "$TMP/.codex/hooks.json" ]
  [ -x "$TMP/.coord/hooks/session_start.sh" ]
  [ -x "$TMP/.coord/hooks/codex/session_start.sh" ]
  # Shared .coord/lib/ has BOTH core libs and Claude adapter libs flat.
  [ -f "$TMP/.coord/lib/atomic_write.sh" ]
  [ -f "$TMP/.coord/lib/subagent_filter.sh" ]
  # Codex adapter libs namespaced under .coord/lib/codex/.
  [ -f "$TMP/.coord/lib/codex/translator.sh" ]
  [ -f "$TMP/.coord/lib/codex/apply_patch_parser.sh" ]
}

@test "dispatcher: --without-claude-code --without-codex → error (nothing to install)" {
  cd "$TMP"
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes --without-claude-code --without-codex
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'no adapters selected'
}

# === Idempotency ===

@test "dispatcher: re-run with both adapters is sha-stable" {
  cd "$TMP"
  _make_codex_stub
  PATH="$TEST_BASE_PATH" bash "$INSTALL" --yes --with-claude-code --with-codex >/dev/null
  local CLAUDE_SHA1 CODEX_SHA1
  CLAUDE_SHA1=$(shasum -a 256 "$TMP/.claude/settings.local.json" | awk '{print $1}')
  CODEX_SHA1=$(shasum -a 256 "$TMP/.codex/hooks.json" | awk '{print $1}')
  PATH="$TEST_BASE_PATH" bash "$INSTALL" --yes --with-claude-code --with-codex >/dev/null
  local CLAUDE_SHA2 CODEX_SHA2
  CLAUDE_SHA2=$(shasum -a 256 "$TMP/.claude/settings.local.json" | awk '{print $1}')
  CODEX_SHA2=$(shasum -a 256 "$TMP/.codex/hooks.json" | awk '{print $1}')
  [ "$CLAUDE_SHA1" = "$CLAUDE_SHA2" ]
  [ "$CODEX_SHA1" = "$CODEX_SHA2" ]
}

# === Uninstall ===

@test "dispatcher: --uninstall strips both adapters' entries when both installed" {
  cd "$TMP"
  _make_codex_stub
  PATH="$TEST_BASE_PATH" bash "$INSTALL" --yes --with-claude-code --with-codex >/dev/null
  # Sanity: coord-owned entries present in both files.
  run jq -r '[.hooks[]?[]?.hooks[]?.command] | map(select(test("\\.coord/hooks/"))) | length' "$TMP/.claude/settings.local.json"
  [ "$output" -gt "0" ]
  run jq -r '[.hooks[]?[]?.hooks[]?.command] | map(select(test("\\.coord/hooks/codex/"))) | length' "$TMP/.codex/hooks.json"
  [ "$output" -gt "0" ]
  # Run uninstall.
  PATH="$TEST_BASE_PATH" run bash "$INSTALL" --yes --uninstall --with-claude-code --with-codex
  [ "$status" -eq 0 ]
  # Both files have NO coord-owned entries now.
  run jq -r '[.hooks[]?[]?.hooks[]?.command] | map(select(test("\\.coord/hooks/"))) | length' "$TMP/.claude/settings.local.json"
  [ "$output" = "0" ]
  run jq -r '[.hooks[]?[]?.hooks[]?.command] | map(select(test("\\.coord/hooks/codex/"))) | length' "$TMP/.codex/hooks.json"
  [ "$output" = "0" ]
  # .coord/ left in place per uninstall contract.
  [ -d "$TMP/.coord" ]
}

# === Materialize-once invariant ===

@test "dispatcher: shared .coord/ materialized once regardless of adapter selection" {
  cd "$TMP"
  _make_codex_stub
  PATH="$TEST_BASE_PATH" bash "$INSTALL" --yes --with-claude-code --with-codex >/dev/null
  # Shared core libs present (flat).
  [ -f "$TMP/.coord/lib/atomic_write.sh" ]
  [ -f "$TMP/.coord/lib/log_event.sh" ]
  [ -f "$TMP/.coord/lib/folder_resolver.sh" ]
  # Bin (shared coord CLI).
  [ -x "$TMP/.coord/bin/coord" ]
  # Schema + config.
  [ -f "$TMP/.coord/schema_version" ]
  [ -f "$TMP/.coord/config.json" ]
  run cat "$TMP/.coord/schema_version"
  [ "$output" = "1.1" ]
}

# === .gitignore covers both adapters ===

@test "dispatcher: .gitignore includes both .claude and .codex entries" {
  cd "$TMP"
  PATH="$TEST_BASE_PATH" bash "$INSTALL" --yes >/dev/null
  grep -qxF '.claude/settings.local.json' "$TMP/.gitignore"
  grep -qxF '.codex/hooks.json' "$TMP/.gitignore"
  grep -qxF '.coord/' "$TMP/.gitignore"
}

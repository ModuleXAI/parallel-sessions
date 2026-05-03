#!/usr/bin/env bats
# Tests for src/adapters/codex/install.sh — PR E.1.
#
# Coverage:
#   - Pre-flight: .coord/ must exist (helpful error if absent)
#   - Hook + lib materialization at .coord/hooks/codex/ and .coord/lib/codex/
#   - .codex/hooks.json shape: 5 events, 7 hook commands, correct matchers
#   - Idempotent re-run: no duplicate entries
#   - User-authored entries preserved across coord install/repair
#   - Feature flag handling (warn-only by default; --enable-codex-feature
#     writes config.toml)
#   - Smoke test runs (session_start emits banner)
#   - Uninstall strips coord-owned entries
#   - Installed hooks resolve LIB_DIR correctly (.coord/hooks/codex/ →
#     .coord/lib/codex/ + .coord/lib/)

load "../helpers/common"

INSTALL="$SRC_ROOT/adapters/codex/install.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-install-XXXX)"
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  # Materialize a minimal .coord/ layout (the top-level installer's job
  # in production; we synthesize here without dragging in the full
  # Claude install).
  mkdir -p "$TMP/.coord/sessions" "$TMP/.coord/lib" "$TMP/.coord/mediator"
  jq -nc '{schema_version:"1.1",sessions:{},locks:{},wait_queues:{},
           read_sets:{},notifications:{},self_tasks:{},
           anomaly_votes:{},task_graph:{}}' \
    > "$TMP/.coord/sessions.json"
  : >"$TMP/.coord/sessions.lock"
  : >"$TMP/.coord/events.lock"
  : >"$TMP/.coord/history.lock"
  printf '1.1\n' >"$TMP/.coord/schema_version"
  jq -nc '{schema_version:"1.1",task_delegation:true,wait_backend:"polling"}' \
    >"$TMP/.coord/config.json"
  # Copy core libs so installed hooks can resolve dependencies
  # (../../lib from .coord/hooks/codex/).
  cp -f "$SRC_ROOT/core/lib"/*.sh "$TMP/.coord/lib/"
  cp -f "$SRC_ROOT/adapters/claude-code/lib"/*.sh "$TMP/.coord/lib/" 2>/dev/null || true
  chmod +x "$TMP/.coord/lib"/*.sh
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

# === Pre-flight ===

@test "codex install: aborts when .coord/ does not exist (helpful error)" {
  rm -rf "$TMP/.coord"
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'does not exist'
  echo "$output" | grep -q 'src/install.sh'
}

# === Materialization ===

@test "codex install: creates .coord/hooks/codex/ with all 7 hook scripts" {
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ] || { echo "stdout/err: $output"; return 1; }
  for h in session_start.sh stop.sh user_prompt_submit.sh \
           pre_tool_use_any.sh pre_tool_use_bash.sh \
           pre_tool_use_apply_patch.sh post_tool_use_apply_patch.sh; do
    [ -x "$TMP/.coord/hooks/codex/$h" ] || { echo "missing: $h"; return 1; }
  done
}

@test "codex install: creates .coord/lib/codex/ with translator + parser" {
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/.coord/lib/codex/translator.sh" ]
  [ -f "$TMP/.coord/lib/codex/apply_patch_parser.sh" ]
}

# === .codex/hooks.json shape ===

@test "codex install: writes .codex/hooks.json with 5 events + correct matchers" {
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  [ -f "$TMP/.codex/hooks.json" ]
  # 5 top-level event keys.
  run jq -r '.hooks | keys | sort | join(",")' "$TMP/.codex/hooks.json"
  [ "$output" = "PostToolUse,PreToolUse,SessionStart,Stop,UserPromptSubmit" ]
  # SessionStart, Stop, UserPromptSubmit each have one matcher: "*".
  for evt in SessionStart Stop UserPromptSubmit; do
    run jq -r --arg e "$evt" '[.hooks[$e][].matcher] | sort | unique | join(",")' "$TMP/.codex/hooks.json"
    [ "$output" = "*" ]
  done
  # PreToolUse has 3 matchers: *, ^Bash$, ^apply_patch$.
  run jq -r '[.hooks.PreToolUse[].matcher] | sort | join(",")' "$TMP/.codex/hooks.json"
  [ "$output" = "*,^Bash$,^apply_patch$" ]
  # PostToolUse has 1 matcher: ^apply_patch$.
  run jq -r '[.hooks.PostToolUse[].matcher] | join(",")' "$TMP/.codex/hooks.json"
  [ "$output" = "^apply_patch$" ]
  # SessionEnd MUST NOT appear (D-10).
  run jq -r '.hooks | has("SessionEnd")' "$TMP/.codex/hooks.json"
  [ "$output" = "false" ]
}

@test "codex install: hook commands point to .coord/hooks/codex/" {
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # Every command path contains '.coord/hooks/codex/'.
  run jq -r '
    [.hooks[][] | .hooks[] | .command]
    | map(test("\\.coord/hooks/codex/")) | all
  ' "$TMP/.codex/hooks.json"
  [ "$output" = "true" ]
}

# === Idempotency / strip-prior-coord ===

@test "codex install: re-run produces stable hooks.json (no duplicate coord entries)" {
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  local SHA1
  SHA1=$(shasum -a 256 "$TMP/.codex/hooks.json" | awk '{print $1}')
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  local SHA2
  SHA2=$(shasum -a 256 "$TMP/.codex/hooks.json" | awk '{print $1}')
  [ "$SHA1" = "$SHA2" ]
}

@test "codex install: preserves user-authored entries alongside coord ones" {
  # Pre-seed a user-authored entry for SessionStart that points to a
  # script OUTSIDE .coord/hooks/codex/.
  mkdir -p "$TMP/.codex"
  jq -nc '{
    hooks: {
      SessionStart: [{matcher:"*", hooks:[{type:"command",
        command:"/usr/local/bin/user-custom-hook.sh", timeout:5}]}]
    }
  }' >"$TMP/.codex/hooks.json"
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # User entry preserved.
  run jq -r '
    [.hooks.SessionStart[].hooks[].command]
    | map(select(. == "/usr/local/bin/user-custom-hook.sh")) | length
  ' "$TMP/.codex/hooks.json"
  [ "$output" = "1" ]
  # Coord entry also present.
  run jq -r '
    [.hooks.SessionStart[].hooks[].command]
    | map(select(test("\\.coord/hooks/codex/session_start.sh"))) | length
  ' "$TMP/.codex/hooks.json"
  [ "$output" = "1" ]
}

# === Feature flag (codex_hooks) ===

@test "codex install: warns when .codex/config.toml is absent (no flag)" {
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'codex_hooks'
}

@test "codex install: --enable-codex-feature creates config.toml when absent" {
  run bash "$INSTALL" --yes --enable-codex-feature --repo-root "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/.codex/config.toml" ]
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*\[features\]' "$TMP/.codex/config.toml"
}

@test "codex install: --enable-codex-feature appends to config.toml without [features]" {
  mkdir -p "$TMP/.codex"
  printf '[other]\nfoo = "bar"\n' >"$TMP/.codex/config.toml"
  bash "$INSTALL" --yes --enable-codex-feature --repo-root "$TMP" >/dev/null
  grep -qE '^[[:space:]]*\[other\]' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*\[features\]' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"
}

@test "codex install: --enable-codex-feature is idempotent on already-enabled config" {
  mkdir -p "$TMP/.codex"
  printf '[features]\ncodex_hooks = true\n' >"$TMP/.codex/config.toml"
  local SHA1
  SHA1=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  bash "$INSTALL" --yes --enable-codex-feature --repo-root "$TMP" >/dev/null
  local SHA2
  SHA2=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  [ "$SHA1" = "$SHA2" ]
}

# === Smoke test ===

@test "codex install: smoke test passes (session_start emits banner)" {
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'smoke test passed'
}

# === Installed-layout LIB_DIR resolution ===

@test "codex install: installed hook resolves CORE+ADAPTER libs from .coord/lib + .coord/lib/codex" {
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # Construct a Codex SessionStart input and feed it directly into the
  # INSTALLED hook. The hook must source its libs from the installed
  # layout (../../lib + ../../lib/codex), not the source tree.
  # COORD_DIR is exported explicitly so coord_resolve_root takes the
  # env-var precedence path — under bats the install runs with PWD ==
  # the repo root (not $TMP), and CLAUDE_PROJECT_DIR is unset, so the
  # walk-up paths in folder_resolver.sh would otherwise miss $TMP/.coord.
  # In production, the user's PWD is inside the repo so walk-up works
  # naturally; this env-var override is purely a test-environment
  # accommodation.
  local SID="cx-installed-$RANDOM"
  local INP
  INP=$(jq -nc --arg s "$SID" --arg cwd "$TMP" '{
    session_id:$s, cwd:$cwd, hook_event_name:"SessionStart",
    source:"startup", model:"x", permission_mode:"default",
    transcript_path:null
  }')
  COORD_ENABLED=1 COORD_DIR="$TMP/.coord" run bash -c "echo '$INP' | '$TMP/.coord/hooks/codex/session_start.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("Coord v1.0 active")' >/dev/null
  [ -e "$TMP/.coord/sessions/${SID}.active" ]
}

# === Uninstall ===

@test "codex install --uninstall: strips coord-owned entries, preserves user entries" {
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # Seed a user-authored entry alongside coord's.
  jq '.hooks.SessionStart += [{matcher:"*", hooks:[{type:"command",
       command:"/path/to/user-hook.sh", timeout:5}]}]' \
    "$TMP/.codex/hooks.json" >"$TMP/.codex/hooks.json.new"
  mv "$TMP/.codex/hooks.json.new" "$TMP/.codex/hooks.json"
  run bash "$INSTALL" --yes --uninstall --repo-root "$TMP"
  [ "$status" -eq 0 ]
  # Coord entries gone. (Note: `// false` after select would defeat the
  # filter — select drops elements when the predicate is false; the //
  # alternative would replace dropped elements with `false`, inflating
  # the count. Plain select-only is correct.)
  run jq -r '
    [.hooks[]?[]?.hooks[]?.command]
    | map(select(test("\\.coord/hooks/codex/"))) | length
  ' "$TMP/.codex/hooks.json"
  [ "$output" = "0" ]
  # User entry preserved.
  run jq -r '
    [.hooks.SessionStart[]?.hooks[]?.command]
    | map(select(. == "/path/to/user-hook.sh")) | length
  ' "$TMP/.codex/hooks.json"
  [ "$output" = "1" ]
}

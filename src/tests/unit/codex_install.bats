#!/usr/bin/env bats
# Tests for src/adapters/codex/install.sh — PR E.1 + A-M-T1-04 plan v1.4.
#
# Coverage:
#   - Pre-flight: .coord/ must exist (helpful error if absent)
#   - Hook + lib materialization at .coord/hooks/codex/ and .coord/lib/codex/
#   - .codex/hooks.json shape: 5 events, 7 hook commands, correct matchers
#   - Idempotent re-run: no duplicate entries
#   - User-authored entries preserved across coord install/repair
#   - codex_hooks feature flag in .codex/config.toml (A-M-T1-04 plan v1.4):
#     unconditionally written/merged on install; three paths exercised
#     (absent / present-with-flag / present-without-flag); user content
#     under [features] preserved; "warn: config.toml does not exist"
#     never emitted; --enable-codex-feature accepted as no-op back-compat
#   - Smoke test runs (session_start emits banner) AND leaves no
#     install-smoke residue in sessions.json (M-T1-05)
#   - Uninstall strips coord-owned entries from hooks.json AND strips
#     codex_hooks line from config.toml while preserving user content;
#     removes config.toml only when it was solely our content
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

# === Feature flag (codex_hooks) — A-M-T1-04 plan v1.4 always-write contract ==
#
# Per A-M-T1-04 the installer ALWAYS ensures `[features] codex_hooks =
# true` in `.codex/config.toml`. The five contract paths covered below:
#   (1) file absent → create with minimal flag content
#   (2) file present + flag set → idempotent no-op (byte-stable)
#   (3) file present + [features] block has OTHER flags but not
#       codex_hooks → grep+awk inline merge under [features]; preserve
#       OTHER flags AND non-features blocks byte-for-byte
#   (4) file present without [features] block at all → append a new
#       [features] block at EOF; preserve other content
#   (5) "warn: .codex/config.toml does not exist" stderr line is NEVER
#       emitted post-fix (this is the M-T1-04 BEFORE-evidence string;
#       its presence indicates a regression to flag-gated behavior)
#
# Plus back-compat:
#   - --enable-codex-feature accepted as no-op (does not error on
#     unknown-flag rejection; same behavior with or without the flag)

@test "codex install: (1) creates .codex/config.toml unconditionally when absent (A-M-T1-04)" {
  # No --enable-codex-feature flag passed.
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/.codex/config.toml" ]
  grep -qE '^[[:space:]]*\[features\][[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP/.codex/config.toml"
}

@test "codex install: (2) idempotent on already-enabled config (byte-stable)" {
  mkdir -p "$TMP/.codex"
  printf '[features]\ncodex_hooks = true\n' >"$TMP/.codex/config.toml"
  local SHA1
  SHA1=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  local SHA2
  SHA2=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  [ "$SHA1" = "$SHA2" ]
  # Twice for good measure — running install three times in a row leaves
  # the file byte-stable.
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  local SHA3
  SHA3=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  [ "$SHA1" = "$SHA3" ]
}

@test "codex install: (3) merge under [features] preserves OTHER flags + sibling blocks" {
  # The canonical merge case the reviewer flagged as easy to miss: user
  # already has a [features] block with OTHER flags. The installer must
  # add `codex_hooks = true` UNDER [features] AND leave the other flags
  # AND non-features blocks alone.
  mkdir -p "$TMP/.codex"
  cat >"$TMP/.codex/config.toml" <<'TOML'
[other]
foo = "bar"
nested_value = 42

[features]
unrelated_user_flag = true
another_flag = false

[third_section]
preserved = "yes"
TOML
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null

  # Our flag inserted under [features].
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP/.codex/config.toml"

  # OTHER user flags preserved verbatim.
  grep -qE '^[[:space:]]*unrelated_user_flag[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*another_flag[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$TMP/.codex/config.toml"

  # Sibling blocks preserved.
  grep -qE '^[[:space:]]*\[other\][[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*foo[[:space:]]*=[[:space:]]*"bar"[[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*nested_value[[:space:]]*=[[:space:]]*42[[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*\[third_section\][[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*preserved[[:space:]]*=[[:space:]]*"yes"[[:space:]]*$' "$TMP/.codex/config.toml"

  # Exactly ONE [features] block (we did not duplicate the header).
  local features_count
  features_count=$(grep -cE '^[[:space:]]*\[features\][[:space:]]*$' "$TMP/.codex/config.toml")
  [ "$features_count" = "1" ]

  # Exactly ONE codex_hooks line (we did not duplicate the line).
  local codex_hooks_count
  codex_hooks_count=$(grep -cE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP/.codex/config.toml")
  [ "$codex_hooks_count" = "1" ]

  # Re-running the install is a no-op (still byte-stable on the merged content).
  local SHA1 SHA2
  SHA1=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  SHA2=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  [ "$SHA1" = "$SHA2" ]
}

@test "codex install: (4) appends [features] block when config.toml has only other sections" {
  mkdir -p "$TMP/.codex"
  printf '[other]\nfoo = "bar"\n' >"$TMP/.codex/config.toml"
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # Other section preserved, new [features] block appended with our flag.
  grep -qE '^[[:space:]]*\[other\][[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*foo[[:space:]]*=[[:space:]]*"bar"[[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*\[features\][[:space:]]*$' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP/.codex/config.toml"
}

@test "codex install: (5) NEVER emits 'config.toml does not exist' warn (M-T1-04 regression sentinel)" {
  # The pre-v1.4 install path printed `codex install: warn:
  # .codex/config.toml does not exist.` and copy-paste instructions
  # whenever the user did not pass --enable-codex-feature. Plan v1.4
  # eliminates the warn entirely (the installer creates the file
  # unconditionally). If this string EVER appears in the install
  # output again, the M-T1-04 fix has regressed.
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'config\.toml does not exist'
  ! echo "$output" | grep -q 'Re-run with --enable-codex-feature'
}

# === --enable-codex-feature back-compat (no-op) ============================

@test "codex install: --enable-codex-feature accepted as no-op (back-compat)" {
  # Pre-v1.4 the flag was required for unattended config.toml writes.
  # Plan v1.4 makes it a no-op. Existing user runbooks that still pass
  # the flag must continue working without an "unknown flag" error.
  run bash "$INSTALL" --yes --enable-codex-feature --repo-root "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/.codex/config.toml" ]
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"
  # Behavior with the flag is identical to behavior without — the
  # install must produce the SAME .codex/config.toml content.
  rm -f "$TMP/.codex/config.toml"
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  local SHA_NO_FLAG
  SHA_NO_FLAG=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  rm -f "$TMP/.codex/config.toml"
  bash "$INSTALL" --yes --enable-codex-feature --repo-root "$TMP" >/dev/null
  local SHA_WITH_FLAG
  SHA_WITH_FLAG=$(shasum -a 256 "$TMP/.codex/config.toml" | awk '{print $1}')
  [ "$SHA_NO_FLAG" = "$SHA_WITH_FLAG" ]
}

# === Smoke test ===

@test "codex install: smoke test passes (session_start emits banner)" {
  run bash "$INSTALL" --yes --repo-root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'smoke test passed'
}

@test "codex install: smoke test leaves no codex-install-smoke-* residue in sessions.json (M-T1-05)" {
  # Per M-T1-05 the install-time smoke session must NOT leave a row in
  # sessions.json after install completes. The cleanup path uses
  # coord_atomic_edit (per reviewer guidance) to atomically delete the
  # synthetic row, eliminating the race window where the watchdog
  # spawned by session_start.sh could re-insert it.
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # Zero codex-install-smoke-* rows.
  local residue
  residue=$(jq -r '
    .sessions // {}
    | to_entries
    | map(select(.key | startswith("codex-install-smoke-")))
    | length
  ' "$TMP/.coord/sessions.json")
  [ "$residue" = "0" ]
  # Also verify no orphan locks/wait_queues for the smoke session.
  local locks_residue
  locks_residue=$(jq -r '
    [(.locks // {}) | to_entries[].value.session]
    | map(select(. // "" | startswith("codex-install-smoke-")))
    | length
  ' "$TMP/.coord/sessions.json")
  [ "$locks_residue" = "0" ]
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

# === Uninstall config.toml preservation (A-M-T1-04 uninstall contract) =====

@test "codex install --uninstall: removes config.toml when it is solely our content" {
  # Install creates config.toml with ONLY [features] codex_hooks = true.
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  [ -f "$TMP/.codex/config.toml" ]
  # Uninstall should remove the file entirely.
  bash "$INSTALL" --yes --uninstall --repo-root "$TMP" >/dev/null
  [ ! -f "$TMP/.codex/config.toml" ]
}

@test "codex install --uninstall: preserves user content; strips only codex_hooks" {
  # User has a config.toml with their own content; install merged our
  # flag in. Uninstall must remove only our line and leave their content.
  mkdir -p "$TMP/.codex"
  cat >"$TMP/.codex/config.toml" <<'TOML'
[other]
foo = "bar"

[features]
unrelated_user_flag = true

[third]
preserved = "yes"
TOML
  bash "$INSTALL" --yes --repo-root "$TMP" >/dev/null
  # Sanity: install added our flag.
  grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*unrelated_user_flag[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"

  # Uninstall.
  bash "$INSTALL" --yes --uninstall --repo-root "$TMP" >/dev/null

  # File still exists (user content remained).
  [ -f "$TMP/.codex/config.toml" ]
  # Our line gone.
  ! grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"
  # User flags preserved.
  grep -qE '^[[:space:]]*\[other\]' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*foo[[:space:]]*=[[:space:]]*"bar"' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*\[features\]' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*unrelated_user_flag[[:space:]]*=[[:space:]]*true' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*\[third\]' "$TMP/.codex/config.toml"
  grep -qE '^[[:space:]]*preserved[[:space:]]*=[[:space:]]*"yes"' "$TMP/.codex/config.toml"
}

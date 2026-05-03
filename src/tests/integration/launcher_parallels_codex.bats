#!/usr/bin/env bats
# Tests for bin/parallels-codex — PR C.4.
# Verifies the launcher's pre-flight checks (.coord/, codex binary,
# soft .codex/hooks.json check) and that it execs `codex` with
# COORD_ENABLED=1 set.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-pcx-XXXX)"
  STUB_BIN="$TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  unset COORD_DIR CLAUDE_PROJECT_DIR CLAUDE_COORD COORD_ENABLED
  PCMD="$SRC_ROOT/../bin/parallels-codex"
}
teardown() { rm -rf "$TMP"; }

@test "parallels-codex: aborts with rc 2 when no .coord/ found" {
  cd "$TMP"
  PATH="$STUB_BIN:$PATH" run "$PCMD"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'no .coord/ found'
}

@test "parallels-codex: aborts with rc 3 when codex binary absent" {
  cd "$TMP"
  mkdir -p "$TMP/.coord"
  # Keep base PATH so the launcher's own shebang resolves; STUB_BIN
  # is empty so codex still can't be found.
  PATH="$STUB_BIN:/usr/bin:/bin" run "$PCMD"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'codex.*PATH'
}

@test "parallels-codex: warns (no hard error) when .codex/hooks.json missing" {
  cd "$TMP"
  mkdir -p "$TMP/.coord"
  cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf 'STUB-CODEX COORD_ENABLED=%s\n' "${COORD_ENABLED:-unset}"
STUB
  chmod +x "$STUB_BIN/codex"
  # Note: NO .codex/hooks.json file created.
  PATH="$STUB_BIN:$PATH" run "$PCMD"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'warning.*hooks.json is missing'
  echo "$output" | grep -q 'STUB-CODEX COORD_ENABLED=1'
}

@test "parallels-codex: silent + execs codex when both .coord/ and .codex/hooks.json present" {
  cd "$TMP"
  mkdir -p "$TMP/.coord" "$TMP/.codex"
  printf '{"hooks":{}}' >"$TMP/.codex/hooks.json"
  cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf 'OK COORD_ENABLED=%s ARGS=%s\n' "${COORD_ENABLED:-unset}" "$*"
STUB
  chmod +x "$STUB_BIN/codex"
  PATH="$STUB_BIN:$PATH" run "$PCMD" foo bar
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK COORD_ENABLED=1 ARGS=foo bar'
  # No warning when hooks.json exists.
  ! echo "$output" | grep -q 'warning'
}

@test "parallels-codex: walks up parent dirs to find .coord/" {
  cd "$TMP"
  mkdir -p "$TMP/.coord" "$TMP/sub/deeper"
  cat >"$STUB_BIN/codex" <<'STUB'
#!/usr/bin/env bash
printf 'OK COORD_ENABLED=%s\n' "${COORD_ENABLED:-unset}"
STUB
  chmod +x "$STUB_BIN/codex"
  cd "$TMP/sub/deeper"
  PATH="$STUB_BIN:$PATH" run "$PCMD"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK COORD_ENABLED=1'
}

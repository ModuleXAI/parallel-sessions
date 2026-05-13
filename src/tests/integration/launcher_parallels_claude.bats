#!/usr/bin/env bats
# Tests for bin/parallels-claude — PR B.2.
# Verifies the launcher's pre-flight checks (.coord/ presence, claude binary)
# and that it execs `claude` with COORD_ENABLED=1 set.

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-pc-XXXX)"
  STUB_BIN="$TMP/stub-bin"
  mkdir -p "$STUB_BIN"
  unset COORD_DIR CLAUDE_PROJECT_DIR CLAUDE_COORD COORD_ENABLED
  PCMD="$SRC_ROOT/../bin/parallels-claude"
}
teardown() { rm -rf "$TMP"; }

@test "parallels-claude: aborts with rc 2 when no .coord/ found" {
  cd "$TMP"
  # No .coord/ in $TMP nor any ancestor (mktemp dir is isolated).
  PATH="$STUB_BIN:$PATH" run "$PCMD"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'no .coord/ found'
}

@test "parallels-claude: aborts with rc 3 when claude binary absent" {
  cd "$TMP"
  mkdir -p "$TMP/.coord"
  # PATH=STUB_BIN only would also strip /usr/bin and break the script's
  # own shebang (`env bash` exits 127 with no /usr/bin). Keep base
  # system paths so the launcher itself runs; STUB_BIN is empty so
  # `claude` is still absent.
  PATH="$STUB_BIN:/usr/bin:/bin" run "$PCMD"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q 'claude.*PATH'
}

@test "parallels-claude: execs claude with COORD_ENABLED=1 in env" {
  cd "$TMP"
  mkdir -p "$TMP/.coord"
  # Stub claude binary that prints whether COORD_ENABLED is set.
  cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'STUB-CLAUDE COORD_ENABLED=%s ARGS=%s\n' "${COORD_ENABLED:-unset}" "$*"
STUB
  chmod +x "$STUB_BIN/claude"
  PATH="$STUB_BIN:$PATH" run "$PCMD" some-arg another
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'STUB-CLAUDE COORD_ENABLED=1'
  echo "$output" | grep -q 'ARGS=some-arg another'
}

@test "parallels-claude: walks up parent dirs to find .coord/" {
  cd "$TMP"
  mkdir -p "$TMP/.coord"
  mkdir -p "$TMP/sub/deeper"
  cat >"$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'OK COORD_ENABLED=%s\n' "${COORD_ENABLED:-unset}"
STUB
  chmod +x "$STUB_BIN/claude"
  cd "$TMP/sub/deeper"
  PATH="$STUB_BIN:$PATH" run "$PCMD"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'OK COORD_ENABLED=1'
}

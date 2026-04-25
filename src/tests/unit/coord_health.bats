#!/usr/bin/env bats
# Tests for `coord health` — the operator-facing self-check.
#
# Coverage focus per F-012 / PR-12 directive (d):
#   - stray digit-named files at the repo root are flagged (F-003 anti-pattern).
#   - clean repo passes (no false positive).
#   - the check is independent of config-bound checks (it fires alongside,
#     not in place of).

load "../helpers/common"

C="$SRC_ROOT/bin/coord"

# Build a minimal isolated repo with a valid coord layout + config.
mk_isolated_repo() {
  local base="$1"
  (
    cd "$base"
    git init -q
    git config user.email t@t
    git config user.name  T
    : >.fixture-seed
    git add .fixture-seed
    git commit -q -m seed
  )
  local coord
  coord=$(mk_coord_dir "$base")
  mk_empty_sessions "$coord"
  cat >"$coord/config.json" <<'JSON'
{
  "schema_version": "1.0",
  "task_delegation": true,
  "lock_ttl_seconds": 900,
  "watchdog_suspicion_seconds": 1200,
  "watchdog_confirm_seconds": 1500,
  "read_set_cap_per_session": 200,
  "wait_poll_schedule_seconds": [30, 60, 120],
  "wait_max_seconds": 570,
  "max_task_chain_depth": 3,
  "max_tasks_per_lock": 5,
  "max_anchor_window_lines": 10
}
JSON
  printf '%s\n' "$coord"
}

setup() {
  TMP="$(mktemp -d -t coord-health-XXXX)"
  COORD="$(mk_isolated_repo "$TMP")"
  export COORD_DIR="$COORD"
  PRIOR_PWD=$PWD
  cd "$TMP"
}

teardown() {
  cd "$PRIOR_PWD" 2>/dev/null || true
  unset COORD_DIR
  rm -rf "$TMP"
}

@test "coord health: clean repo passes (deps + config bounds + no stray files)" {
  run "$C" health
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'config bounds OK'
  ! echo "$output" | grep -q 'stray digit-named file'
}

@test "coord health: stray digit-named file at repo root is flagged" {
  : >"$TMP/9"
  run "$C" health
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'stray digit-named file'
  echo "$output" | grep -q '\b9\b'
  echo "$output" | grep -q 'F-012'
}

@test "coord health: multi-digit name (e.g. 42) is flagged" {
  : >"$TMP/42"
  run "$C" health
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'stray digit-named file'
  echo "$output" | grep -q '\b42\b'
}

@test "coord health: alphanumeric file (9a) is NOT flagged" {
  : >"$TMP/9a"
  run "$C" health
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'stray digit-named file'
}

@test "coord health: digit-named subdir does NOT trigger root scan" {
  mkdir "$TMP/9dir"
  run "$C" health
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'stray digit-named file'
}

@test "coord health: deletion clears the warning" {
  : >"$TMP/9"
  run "$C" health
  [ "$status" -ne 0 ]
  rm -f "$TMP/9"
  run "$C" health
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'stray digit-named file'
}

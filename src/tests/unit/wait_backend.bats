#!/usr/bin/env bats
# Tests for lib/wait_backend.sh per Phase 5 T5.03 + PR-PHASE5-02 §4.
#
# Categories:
#   1. Backend detection (3 tests)
#   2. coord wait fswatch path     (3 tests; macOS-only, skip if absent)
#   3. coord wait inotifywait path (3 tests; Linux-only, skip if absent)
#   4. coord wait polling path     (3 tests; both platforms)
#   5. Content read protocol       (2 tests)
#   6. Runtime fallback            (1 test)

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-wb-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mkdir -p "$COORD_DIR/wakers" "$COORD_DIR/wait_queues"
  mk_empty_sessions "$COORD_DIR"
  printf '{"schema_version":"1.0","wait_backend":"auto"}' >"$COORD_DIR/config.json"
  : >"$COORD_DIR/events.jsonl"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_backend.sh"
}
teardown() {
  rm -rf "$TMP"
}

# ----- Category 1: Backend detection -----
#
# Detection tests use skip-checks against the live host rather than
# PATH manipulation: stripping /usr/bin from PATH (to fake-absent a
# real inotifywait) also breaks chmod/rm/sleep, which surfaced in the
# Linux probe failure pattern. Skip-based tests are simpler and
# correctly reflect what the resolver does.

@test "wait_backend: fswatch present + macOS -> backend=fswatch" {
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "macOS-only test (uname=$(uname -s))"
  fi
  command -v fswatch >/dev/null 2>&1 || skip "fswatch not installed on host"
  run coord_wait_backend_detect
  [ "$status" -eq 0 ]
  [ "$output" = "fswatch" ]
}

@test "wait_backend: fswatch absent + inotifywait present + Linux -> backend=inotifywait" {
  if [ "$(uname -s)" != "Linux" ]; then
    skip "Linux-only test (uname=$(uname -s))"
  fi
  command -v inotifywait >/dev/null 2>&1 || skip "inotifywait not installed on host"
  command -v fswatch     >/dev/null 2>&1 && skip "host has fswatch (preempts inotifywait order)"
  run coord_wait_backend_detect
  [ "$status" -eq 0 ]
  [ "$output" = "inotifywait" ]
}

@test "wait_backend: both absent -> backend=polling" {
  command -v fswatch     >/dev/null 2>&1 && skip "host has fswatch — cannot fake-absent"
  command -v inotifywait >/dev/null 2>&1 && skip "host has inotifywait — cannot fake-absent"
  run coord_wait_backend_detect
  [ "$status" -eq 0 ]
  [ "$output" = "polling" ]
}

# ----- Category 2: fswatch path (macOS-only) -----

@test "wait_backend: fswatch wake on touch + content write" {
  command -v fswatch >/dev/null 2>&1 || skip "fswatch not installed"
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "fswatch primary path is macOS"
  fi
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  ( sleep 0.3; printf 'modified by sid-A\n' >"$wake" ) &
  local writer=$!
  run coord_wait_for_release_fswatch "$wake" 5
  wait "$writer"
  [ "$status" -eq 0 ]
}

@test "wait_backend: fswatch wake-up latency < 500ms" {
  command -v fswatch >/dev/null 2>&1 || skip "fswatch not installed"
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "fswatch primary path is macOS"
  fi
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  ( sleep 0.2; printf 'modified by sid-A\n' >"$wake" ) &
  local writer=$!
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  coord_wait_for_release_fswatch "$wake" 5
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  wait "$writer"
  local elapsed_ms
  elapsed_ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d\n", (b-a)*1000}')
  echo "fswatch wake-up elapsed_ms=$elapsed_ms (expected <500)"
  [ "$elapsed_ms" -lt 500 ]
}

@test "wait_backend: fswatch returns rc=1 on timeout" {
  command -v fswatch >/dev/null 2>&1 || skip "fswatch not installed"
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "fswatch primary path is macOS"
  fi
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  run coord_wait_for_release_fswatch "$wake" 1
  [ "$status" -eq 1 ]
}

# ----- Category 3: inotifywait path (Linux-only) -----

@test "wait_backend: inotifywait wake on touch + content write" {
  command -v inotifywait >/dev/null 2>&1 || skip "inotifywait not installed"
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  ( sleep 0.3; printf 'modified by sid-A\n' >"$wake" ) &
  local writer=$!
  run coord_wait_for_release_inotifywait "$wake" 5
  wait "$writer"
  [ "$status" -eq 0 ]
}

@test "wait_backend: inotifywait wake-up latency < 500ms" {
  command -v inotifywait >/dev/null 2>&1 || skip "inotifywait not installed"
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  ( sleep 0.2; printf 'modified by sid-A\n' >"$wake" ) &
  local writer=$!
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  coord_wait_for_release_inotifywait "$wake" 5
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  wait "$writer"
  local elapsed_ms
  elapsed_ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d\n", (b-a)*1000}')
  echo "inotifywait wake-up elapsed_ms=$elapsed_ms (expected <500)"
  [ "$elapsed_ms" -lt 500 ]
}

@test "wait_backend: inotifywait returns rc=1 on timeout" {
  command -v inotifywait >/dev/null 2>&1 || skip "inotifywait not installed"
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  run coord_wait_for_release_inotifywait "$wake" 1
  [ "$status" -eq 1 ]
}

# ----- Category 4: polling path (both platforms) -----

@test "wait_backend: polling wake on content write" {
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  ( sleep 0.3; printf 'modified by sid-A\n' >"$wake" ) &
  local writer=$!
  run coord_wait_for_release_polling "$wake" 5
  wait "$writer"
  [ "$status" -eq 0 ]
}

@test "wait_backend: polling wake-up latency < 600ms" {
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  ( sleep 0.2; printf 'modified by sid-A\n' >"$wake" ) &
  local writer=$!
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  coord_wait_for_release_polling "$wake" 5
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f\n", time')
  wait "$writer"
  local elapsed_ms
  elapsed_ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%d\n", (b-a)*1000}')
  echo "polling wake-up elapsed_ms=$elapsed_ms (expected <600)"
  [ "$elapsed_ms" -lt 600 ]
}

@test "wait_backend: polling returns rc=1 on timeout" {
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  run coord_wait_for_release_polling "$wake" 1
  [ "$status" -eq 1 ]
}

# ----- Category 5: Content read protocol -----

@test "wait_backend: content read on first try (non-empty file)" {
  local wake="$COORD_DIR/wakers/test.wake"
  printf 'modified by sid-A\n' >"$wake"
  run coord_wait_read_content "$wake" "fallback-sid"
  [ "$status" -eq 0 ]
  [ "$output" = "modified by sid-A" ]
}

@test "wait_backend: empty file -> 50ms grace -> empty fallback string" {
  local wake="$COORD_DIR/wakers/test.wake"
  : >"$wake"
  run coord_wait_read_content "$wake" "fallback-sid"
  [ "$status" -eq 0 ]
  [ "$output" = "modified by fallback-sid" ]
}

# ----- Category 6: Runtime fallback -----

@test "wait_backend: configured backend missing at runtime -> polling fallback + RUNTIME_BACKEND_FALLBACK event" {
  # Config requests a backend that the host doesn't have; resolver must
  # detect at runtime and downgrade to polling, emitting
  # RUNTIME_BACKEND_FALLBACK. Skip when the host happens to have BOTH
  # backends (no easy way to test missing-at-runtime in that case).
  local request
  if   ! command -v fswatch     >/dev/null 2>&1; then request='fswatch'
  elif ! command -v inotifywait >/dev/null 2>&1; then request='inotifywait'
  else
    skip "host has both fswatch and inotifywait — cannot exercise missing-at-runtime"
  fi
  printf '{"schema_version":"1.0","wait_backend":"%s"}' "$request" >"$COORD_DIR/config.json"
  run coord_wait_backend_get
  [ "$status" -eq 0 ]
  [ "$output" = "polling" ]
  sleep 0.2
  count=$(grep -c '"kind":"RUNTIME_BACKEND_FALLBACK"' "$COORD_DIR/events.jsonl" 2>/dev/null || printf '0')
  [ "$count" -ge 1 ]
}

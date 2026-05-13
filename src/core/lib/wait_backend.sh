#!/usr/bin/env bash
# wait_backend.sh — Phase 5 T5.03 platform abstraction for event-driven
# wake-up. Implements PR-PHASE5-02 §4 (platform detection + 3-mode
# dispatch) per pin-point (d).
#
# Public API:
#   coord_wait_backend_detect              — auto-detect host tooling
#   coord_wait_backend_get                 — read config + runtime fallback
#   coord_wait_for_release <wake> <secs>   — dispatcher (consumer side)
#   coord_wait_read_content <wake>         — 50 ms grace re-read protocol
#   coord_wait_emit_first_use_event        — emit WAIT_BACKEND on first use
#
# Detection priority (PR-PHASE5-02 §4):
#   - macOS: fswatch first, polling fallback (NOT inotifywait, even if
#     installed via Linux compat layer — fswatch is macOS-native)
#   - Linux: inotifywait first, fswatch second (rare on Linux), polling
#     fallback
#   - Other Unix: polling unconditional
#
# Wake_file content protocol (consumer side, PR-PHASE5-02 §3):
#   1. Block on backend-specific watch.
#   2. Read content; if empty, sleep 50 ms; re-read.
#   3. If still empty, fallback to "modified by <unknown>".
#
# Dependencies (must be sourced by caller before invoking these):
#   - lib/atomic_write.sh    (coord_atomic_edit; for config read)
#   - lib/log_event.sh       (coord_log_event, coord_now_iso8601)
#   - jq                     (config read)
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern).

# ---------------------------------------------------------------
# Detection
# ---------------------------------------------------------------

# coord_wait_backend_platform — print darwin / linux / bsd / unix.
coord_wait_backend_platform() {
  local u
  u=$(uname -s 2>/dev/null || printf 'unknown')
  case "$u" in
    Darwin)   printf 'darwin' ;;
    Linux)    printf 'linux' ;;
    *BSD*)    printf 'bsd' ;;
    *)        printf 'unix' ;;
  esac
}

# coord_wait_backend_detect — print fswatch / inotifywait / polling.
#   Detection priority per PR-PHASE5-02 §4. Pure read-only; no I/O
#   beyond `command -v` probes.
coord_wait_backend_detect() {
  local platform
  platform=$(coord_wait_backend_platform)
  case "$platform" in
    darwin)
      if command -v fswatch >/dev/null 2>&1; then
        printf 'fswatch'; return 0
      fi
      ;;
    linux)
      if command -v inotifywait >/dev/null 2>&1; then
        printf 'inotifywait'; return 0
      fi
      if command -v fswatch >/dev/null 2>&1; then
        printf 'fswatch'; return 0
      fi
      ;;
    *)
      ;;
  esac
  printf 'polling'
  return 0
}

# coord_wait_backend_get — read .coord/config.json `wait_backend` field;
#   if "auto" or absent, run detection. Subsequent runtime fallback to
#   polling when the configured backend's binary is missing at runtime.
#
#   Stdout: fswatch | inotifywait | polling
coord_wait_backend_get() {
  local cfg backend
  cfg="${COORD_DIR:-}/config.json"
  if [ -s "$cfg" ]; then
    backend=$(jq -r '.wait_backend // "auto"' "$cfg" 2>/dev/null || printf 'auto')
  else
    backend='auto'
  fi
  case "$backend" in
    auto|''|null) backend=$(coord_wait_backend_detect) ;;
    fswatch|inotifywait|polling) : ;;
    *) backend=$(coord_wait_backend_detect) ;;
  esac
  # Runtime fallback: configured backend binary missing.
  case "$backend" in
    fswatch)
      if ! command -v fswatch >/dev/null 2>&1; then
        coord_log_event kind=RUNTIME_BACKEND_FALLBACK \
          source=coord_wait_backend_get \
          configured=fswatch fallback=polling \
          reason=binary_missing 2>/dev/null || true
        backend='polling'
      fi
      ;;
    inotifywait)
      if ! command -v inotifywait >/dev/null 2>&1; then
        coord_log_event kind=RUNTIME_BACKEND_FALLBACK \
          source=coord_wait_backend_get \
          configured=inotifywait fallback=polling \
          reason=binary_missing 2>/dev/null || true
        backend='polling'
      fi
      ;;
  esac
  printf '%s' "$backend"
  return 0
}

# coord_wait_emit_first_use_event <backend>
#   Emit WAIT_BACKEND_FIRST_USE event the first time `coord wait` runs
#   in this shell process. Idempotent at process scope (not session
#   scope; tracked via in-process env var).
coord_wait_emit_first_use_event() {
  local backend="$1"
  if [ -n "${_COORD_WAIT_BACKEND_EMITTED:-}" ]; then
    return 0
  fi
  _COORD_WAIT_BACKEND_EMITTED=1
  export _COORD_WAIT_BACKEND_EMITTED
  coord_log_event kind=WAIT_BACKEND \
    source=coord_wait \
    backend="$backend" \
    reason=first_use 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------
# Consumer: wake_file content read
# ---------------------------------------------------------------

# coord_wait_read_content <wake_file> <fallback_releaser>
#   50 ms grace re-read protocol per PR-PHASE5-02 §3 (pin-point c-3).
#   If the file is non-empty, print its content (trailing newline
#   stripped). Else sleep 50 ms and re-read. Else "modified by
#   <fallback_releaser>".
#
#   Stdout: diff_summary text (single line, no trailing newline)
coord_wait_read_content() {
  local wake_file="$1" fallback="${2:-unknown}"
  local content
  content=$(cat "$wake_file" 2>/dev/null || printf '')
  # Strip trailing newline.
  content="${content%$'\n'}"
  if [ -z "$content" ]; then
    sleep 0.05
    content=$(cat "$wake_file" 2>/dev/null || printf '')
    content="${content%$'\n'}"
  fi
  if [ -z "$content" ]; then
    content="modified by ${fallback}"
  fi
  printf '%s' "$content"
}

# ---------------------------------------------------------------
# Consumer: 3-mode dispatcher
# ---------------------------------------------------------------

# Phase 7 / T7.06a (F-016 fix): expose fswatch + sleeper PIDs to
# cleanup_interrupt via globals. Initialized empty; set inside
# coord_wait_for_release_fswatch after backgrounding; cleared
# before that function returns. cleanup_interrupt reads them and
# kills any still-alive PID before exit 130 — prevents orphaning
# to PID 1 under SIGINT delivery.
_COORD_WAIT_FSWATCH_PID="${_COORD_WAIT_FSWATCH_PID:-}"
_COORD_WAIT_SLEEPER_PID="${_COORD_WAIT_SLEEPER_PID:-}"

# coord_wait_for_release_fswatch <wake_file> <timeout_seconds>
#   Block on fswatch; rc=0 on event, rc=1 on timeout. fswatch has no
#   built-in timeout; we use a parallel `sleep` racer + kill.
coord_wait_for_release_fswatch() {
  local wake_file="$1" timeout="$2"
  local fswatch_pid sleeper_pid winner_pid winner_rc
  # fswatch -1 exits after first event. -l 0.05 = 50 ms latency.
  fswatch -1 -l 0.05 "$wake_file" >/dev/null 2>&1 &
  fswatch_pid=$!
  ( sleep "$timeout"; ) &
  sleeper_pid=$!
  # Phase 7 / T7.06a: expose to cleanup_interrupt.
  _COORD_WAIT_FSWATCH_PID="$fswatch_pid"
  _COORD_WAIT_SLEEPER_PID="$sleeper_pid"
  # Wait for either to exit. Use `wait -n` if available (bash 4+);
  # bash 3.2 fallback uses a polling loop on `kill -0`.
  while :; do
    if ! kill -0 "$fswatch_pid" 2>/dev/null; then
      winner_pid="$fswatch_pid"
      break
    fi
    if ! kill -0 "$sleeper_pid" 2>/dev/null; then
      winner_pid="$sleeper_pid"
      break
    fi
    sleep 0.05
  done
  # Clean up the loser.
  if [ "$winner_pid" = "$fswatch_pid" ]; then
    kill "$sleeper_pid" 2>/dev/null || true
    wait "$sleeper_pid" 2>/dev/null || true
    # Both children gone; clear the globals so cleanup_interrupt
    # doesn't try to kill stale PIDs.
    _COORD_WAIT_FSWATCH_PID=""
    _COORD_WAIT_SLEEPER_PID=""
    return 0
  else
    kill "$fswatch_pid" 2>/dev/null || true
    wait "$fswatch_pid" 2>/dev/null || true
    _COORD_WAIT_FSWATCH_PID=""
    _COORD_WAIT_SLEEPER_PID=""
    return 1
  fi
}

# coord_wait_for_release_inotifywait <wake_file> <timeout_seconds>
#   Block on inotifywait -e modify -e create -t <timeout>; rc=0 on
#   event, rc=2 on timeout (inotifywait's own timeout exit).
coord_wait_for_release_inotifywait() {
  local wake_file="$1" timeout="$2"
  if inotifywait -q -e modify -e create -t "$timeout" "$wake_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# coord_wait_for_release_polling <wake_file> <timeout_seconds>
#   250 ms cadence on wake_file content non-emptiness. Producer's
#   `printf "%s\n" "$summary" > "$wake_file"` makes the file non-empty;
#   consumer detects via `[ -s "$wake_file" ]`.
coord_wait_for_release_polling() {
  local wake_file="$1" timeout="$2"
  local started_epoch deadline now
  started_epoch=$(date -u +%s)
  deadline=$(( started_epoch + timeout ))
  while :; do
    if [ -s "$wake_file" ]; then
      return 0
    fi
    now=$(date -u +%s)
    if [ "$now" -ge "$deadline" ]; then
      return 1
    fi
    sleep 0.25
  done
}

# coord_wait_for_release <wake_file> <timeout_seconds>
#   Dispatcher: read wait_backend from config, call the appropriate
#   wait_for_release_* helper. Returns the helper's rc.
coord_wait_for_release() {
  local wake_file="$1" timeout="$2"
  local backend
  backend=$(coord_wait_backend_get)
  case "$backend" in
    fswatch)     coord_wait_for_release_fswatch     "$wake_file" "$timeout" ;;
    inotifywait) coord_wait_for_release_inotifywait "$wake_file" "$timeout" ;;
    polling|*)   coord_wait_for_release_polling     "$wake_file" "$timeout" ;;
  esac
}

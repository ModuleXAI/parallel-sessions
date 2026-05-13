#!/usr/bin/env bash
# wait_queue.sh — Phase 5 per-file FIFO data structure for passive
# waiters. Implements PR-PHASE5-01 (Decision 1; pin-points a-1 + c-1).
#
# Public API (six functions):
#   coord_wait_queue_enqueue       <sid> <file_path>
#   coord_wait_queue_dequeue       <sid> <file_path>
#   coord_wait_queue_head          <file_path>
#   coord_wait_queue_size          <file_path>
#   coord_wait_queue_position      <sid> <file_path>
#   coord_wait_queue_cleanup_session <sid>
#
# Per-file flock at $COORD_DIR/wait_queues/<sanitized_path>.lock.
# Path sanitization: literal `tr / __`. Leading underscore preserved
# (e.g., /src/api.ts → __src__api.ts).
#
# Wake files at $COORD_DIR/wakers/<sid>-<sanitized_path>.wake. Created
# empty on enqueue (touch); content written by notify_waiters.sh on
# lock release (PR-PHASE5-02).
#
# Cycle-detection trigger: post-enqueue queue depth >= 2 invokes
# coord_cycle_detect <sid>. PR-PHASE5-03 / T5.05 implements the real
# detector; this file ships a stub forwarder (logs
# CYCLE_DETECTION_SKIPPED_T5_05_PENDING) so the trigger wiring is
# present from T5.02.
#
# Dependencies (must be sourced by caller before invoking these):
#   - lib/atomic_write.sh    (coord_atomic_edit)
#   - lib/log_event.sh       (coord_log_event, coord_now_iso8601)
#   - jq, flock              (caller's deps gate already verified)
#
# Environment:
#   COORD_DIR     — required; resolves wait_queues/ + wakers/ + state.
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern;
# functions handle their own rc semantics).

# ---------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------

# _coord_wq_sanitize <file_path>
#   Print the sanitized form on stdout: every "/" replaced with "__"
#   (literal tr / __ per PR-PHASE5-01 §1 pin-point a-1). Leading "/"
#   yields a leading "__" (e.g., /src/api.ts -> __src__api.ts).
#   Reverse mapping is unambiguous: every "__" was a "/" in the
#   original. Bash 3.2 supports ${var//pattern/replacement} so no
#   subprocess needed.
_coord_wq_sanitize() {
  local p="$1"
  printf '%s' "${p//\//__}"
}

# _coord_wq_lock_path <file_path>
_coord_wq_lock_path() {
  local p
  p=$(_coord_wq_sanitize "$1")
  printf '%s/wait_queues/%s.lock' "${COORD_DIR}" "$p"
}

# _coord_wq_wake_path <sid> <file_path>
_coord_wq_wake_path() {
  local sid="$1"
  local p
  p=$(_coord_wq_sanitize "$2")
  # Caller resolves to absolute when needed; we keep this relative so
  # it round-trips through sessions.json without absolute-path leak.
  printf '%s/wakers/%s-%s.wake' "${COORD_DIR}" "$sid" "$p"
}

# _coord_wq_ensure_dirs — create wait_queues/ + wakers/ if missing.
_coord_wq_ensure_dirs() {
  [ -n "${COORD_DIR:-}" ] || return 1
  mkdir -p "${COORD_DIR}/wait_queues" "${COORD_DIR}/wakers" 2>/dev/null
  return 0
}

# _coord_wq_state — print the path to sessions.json (or empty).
_coord_wq_state() {
  [ -n "${COORD_DIR:-}" ] || return 1
  printf '%s/sessions.json' "${COORD_DIR}"
}

# _coord_wq_flock_timeout — seconds to wait for per-file flock.
_coord_wq_flock_timeout() {
  printf '%s' "${COORD_WAIT_QUEUE_FLOCK_TIMEOUT:-5}"
}

# _coord_cycle_detect_or_stub <sid> <file> <depth>
#   Phase 5 T5.05 wiring. When lib/cycle_detection.sh is sourced,
#   forward to the real detector + (on cycle hit) emit the
#   cycle_detected pending entry + spawn Mediator inline. When the
#   detector lib is absent (e.g., minimal install), emit the legacy
#   T5.02 placeholder so the trigger wiring stays observable.
_coord_cycle_detect_or_stub() {
  local sid="$1" file="$2" depth="$3"
  if command -v coord_cycle_detect >/dev/null 2>&1; then
    local cycle_json
    cycle_json=$(coord_cycle_detect "$sid" 2>/dev/null) || cycle_json=""
    if [ -n "$cycle_json" ]; then
      # Cycle found — write pending entry + spawn Mediator inline
      # synchronously (mirrors the Phase 4 critical_drift pattern per
      # PR-PHASE4-02 + Concern B). T5.06 will integrate this with the
      # full Mediator verdict-apply pipeline; T5.05 ships the
      # producer half (pending entry write).
      if command -v coord_cycle_emit_pending >/dev/null 2>&1; then
        local pending_ts
        pending_ts=$(coord_cycle_emit_pending "$cycle_json" 2>/dev/null) \
          || pending_ts=""
        if [ -n "$pending_ts" ] \
           && command -v coord_mediator_spawn >/dev/null 2>&1; then
          # Synchronous Mediator spawn. Best-effort: failures
          # surface via MEDIATOR_SPAWN_FAILED events; do not block
          # the enqueue-caller.
          coord_mediator_spawn "$pending_ts" 1 >/dev/null 2>&1 || true
        fi
      fi
    fi
    return 0
  fi
  # Stub path — detector unavailable; emit observability event so the
  # trigger wiring is still visible.
  coord_log_event kind=CYCLE_DETECTION_SKIPPED_T5_05_PENDING \
    source=wait_queue_enqueue session="$sid" file="$file" \
    depth_at_enqueue="$depth" \
    note="cycle_detection.sh not sourced; trigger fired but no detector available"
  return 0
}

# ---------------------------------------------------------------
# Public API
# ---------------------------------------------------------------

# coord_wait_queue_enqueue <sid> <file_path>
#   Append <sid> to wait_queues[<file_path>] under per-file flock.
#   Idempotent: returns existing wake_file path if <sid> already
#   queued. Triggers cycle detection on post-append depth >= 2.
#
#   Stdout: wake_file path (relative to repo root, e.g.,
#           ".coord/wakers/<sid>-<sanitized>.wake")
#   Returns: 0 success (incl. idempotent no-op)
#            1 missing arg / COORD_DIR / dependency
#            2 flock timeout
#            3 atomic_edit failure
coord_wait_queue_enqueue() {
  local sid="$1" file="$2"
  if [ -z "$sid" ] || [ -z "$file" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  if ! _coord_wq_ensure_dirs; then
    return 1
  fi

  local state lock_path wake_path timeout
  state=$(_coord_wq_state) || return 1
  lock_path=$(_coord_wq_lock_path "$file")
  wake_path=$(_coord_wq_wake_path "$sid" "$file")
  timeout=$(_coord_wq_flock_timeout)

  # Critical section: per-file flock guards the enqueue + idempotency
  # check + queue_position renumbering. Subshell + redirected fd per
  # F-003 (discoteq flock has no -- separator).
  local now post_size sanitized wake_abs
  now=$(coord_now_iso8601)
  sanitized=$(_coord_wq_sanitize "$file")
  wake_abs="${COORD_DIR}/wakers/${sid}-${sanitized}.wake"

  # Use a temp file as the inter-subshell communication channel (Bash
  # 3.2 has parser fragility with `out=$( ( ... ) 9>"lock" )` when the
  # inner subshell contains nested $(cmd "arg") inside double-quoted
  # strings; existing libs avoid the pattern entirely).
  local out_tmp
  out_tmp="${COORD_DIR}/wait_queues/.enq.$$.${sid}.out"
  : >"$out_tmp"
  (
    flock -x -w "$timeout" 9 || exit 2
    # Idempotency check.
    local already
    already=$(jq -r --arg f "$file" --arg s "$sid" \
      '(.wait_queues[$f] // []) | map(.session_id) | index($s) // -1' \
      "$state" 2>/dev/null || printf '%s' '-1')
    case "$already" in
      ''|*[!0-9-]*) already="-1" ;;
    esac
    if [ "$already" != "-1" ]; then
      printf 'idempotent\n' >"$out_tmp"
      exit 0
    fi
    # Build the new entry; append; renumber queue_position.
    if ! coord_atomic_edit "$state" '
          .wait_queues[$f] = (.wait_queues[$f] // [])
          | .wait_queues[$f] += [{
              session_id: $s,
              waiting_since: $ts,
              wake_file: $w,
              queue_position: 0
            }]
          | .wait_queues[$f] |= (
              . as $arr
              | reduce range(0; length) as $i ($arr;
                  .[$i].queue_position = $i
                )
            )
        ' \
        --arg f "$file" --arg s "$sid" --arg ts "$now" --arg w "$wake_path"; then
      exit 3
    fi
    # Touch the wake_file empty.
    : >"$wake_abs"
    local sz
    sz=$(jq -r --arg f "$file" '.wait_queues[$f] | length' "$state" 2>/dev/null || printf '0')
    printf 'appended\t%s\n' "$sz" >"$out_tmp"
    exit 0
  ) 9>"$lock_path"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp"
    return "$rc"
  fi
  local out mode
  out=$(cat "$out_tmp" 2>/dev/null || printf '')
  rm -f "$out_tmp"
  mode=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $1}')
  if [ "$mode" = "appended" ]; then
    post_size=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $2}')
    coord_log_event kind=WAIT_QUEUE_ENQUEUED source=coord_wait_queue_enqueue \
      session="$sid" file="$file" wake_file="$wake_path" \
      queue_position=$((post_size - 1)) queue_size="$post_size"
    case "$post_size" in
      ''|0|1) : ;;
      *)
        _coord_cycle_detect_or_stub "$sid" "$file" "$post_size" >/dev/null 2>&1 || true
        ;;
    esac
  fi
  printf '%s\n' "$wake_path"
  return 0
}

# coord_wait_queue_dequeue <sid> <file_path>
#   Remove <sid> from wait_queues[<file_path>]. Idempotent (no-op when
#   absent; rc=0).
#
#   Returns: 0 success (incl. no-op)
#            1 missing arg / COORD_DIR
#            2 flock timeout
#            3 atomic_edit failure
coord_wait_queue_dequeue() {
  local sid="$1" file="$2"
  if [ -z "$sid" ] || [ -z "$file" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  _coord_wq_ensure_dirs || return 1

  local state lock_path wake_path timeout sanitized wake_abs
  state=$(_coord_wq_state) || return 1
  lock_path=$(_coord_wq_lock_path "$file")
  wake_path=$(_coord_wq_wake_path "$sid" "$file")
  timeout=$(_coord_wq_flock_timeout)
  sanitized=$(_coord_wq_sanitize "$file")
  wake_abs="${COORD_DIR}/wakers/${sid}-${sanitized}.wake"

  local out_tmp
  out_tmp="${COORD_DIR}/wait_queues/.deq.$$.${sid}.out"
  : >"$out_tmp"
  (
    flock -x -w "$timeout" 9 || exit 2
    local pos
    pos=$(jq -r --arg f "$file" --arg s "$sid" \
      '(.wait_queues[$f] // []) | map(.session_id) | index($s) // -1' \
      "$state" 2>/dev/null || printf '%s' '-1')
    case "$pos" in
      ''|*[!0-9-]*) pos="-1" ;;
    esac
    if [ "$pos" = "-1" ]; then
      printf 'absent\n' >"$out_tmp"
      exit 0
    fi
    if ! coord_atomic_edit "$state" '
          .wait_queues[$f] = ((.wait_queues[$f] // [])
                               | map(select(.session_id != $s)))
          | (if (.wait_queues[$f] | length) == 0
             then del(.wait_queues[$f])
             else .wait_queues[$f] |= (
               . as $arr
               | reduce range(0; length) as $i ($arr;
                   .[$i].queue_position = $i
                 )
             )
             end)
        ' \
        --arg f "$file" --arg s "$sid"; then
      exit 3
    fi
    local remaining
    remaining=$(jq -r --arg f "$file" '(.wait_queues[$f] // []) | length' "$state" 2>/dev/null || printf '0')
    printf 'removed\t%s\t%s\n' "$pos" "$remaining" >"$out_tmp"
    exit 0
  ) 9>"$lock_path"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp"
    return "$rc"
  fi
  local out mode
  out=$(cat "$out_tmp" 2>/dev/null || printf '')
  rm -f "$out_tmp"
  mode=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $1}')
  if [ "$mode" = "removed" ]; then
    local removed_pos remaining_size
    removed_pos=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $2}')
    remaining_size=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $3}')
    coord_log_event kind=WAIT_QUEUE_DEQUEUED source=coord_wait_queue_dequeue \
      session="$sid" file="$file" \
      removed_position="$removed_pos" remaining_size="$remaining_size"
    rm -f "$wake_abs"
  fi
  return 0
}

# coord_wait_queue_head <file_path>
#   Print head waiter as TSV (<sid>\t<wake_file>). Empty stdout if
#   queue is empty or absent.
#
#   Returns: 0 success (incl. empty), 2 flock timeout
coord_wait_queue_head() {
  local file="$1"
  [ -z "$file" ] && return 1
  [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ] && return 1
  _coord_wq_ensure_dirs || return 1
  local state lock_path timeout
  state=$(_coord_wq_state) || return 1
  lock_path=$(_coord_wq_lock_path "$file")
  timeout=$(_coord_wq_flock_timeout)
  (
    flock -s -w "$timeout" 9 || exit 2
    jq -r --arg f "$file" '
      (.wait_queues[$f] // [])
      | if length == 0 then empty
        else (.[0] | "\(.session_id)\t\(.wake_file)")
        end
    ' "$state" 2>/dev/null
  ) 9>"$lock_path"
}

# coord_wait_queue_size <file_path>
#   Print queue length on stdout (0 for empty/absent).
coord_wait_queue_size() {
  local file="$1"
  [ -z "$file" ] && { printf '0'; return 0; }
  [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ] && { printf '0'; return 0; }
  _coord_wq_ensure_dirs || { printf '0'; return 0; }
  local state lock_path timeout
  state=$(_coord_wq_state) || { printf '0'; return 0; }
  lock_path=$(_coord_wq_lock_path "$file")
  timeout=$(_coord_wq_flock_timeout)
  local sz
  sz=$(
    (
      flock -s -w "$timeout" 9 || exit 2
      jq -r --arg f "$file" '(.wait_queues[$f] // []) | length' "$state" 2>/dev/null
    ) 9>"$lock_path"
  )
  case "$sz" in
    ''|*[!0-9]*) sz=0 ;;
  esac
  printf '%s' "$sz"
  return 0
}

# coord_wait_queue_position <sid> <file_path>
#   Print 0-indexed position on stdout, or -1 if not in queue.
coord_wait_queue_position() {
  local sid="$1" file="$2"
  [ -z "$sid" ] || [ -z "$file" ] && { printf '%s' '-1'; return 0; }
  [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ] && { printf '%s' '-1'; return 0; }
  _coord_wq_ensure_dirs || { printf '%s' '-1'; return 0; }
  local state lock_path timeout
  state=$(_coord_wq_state) || { printf '%s' '-1'; return 0; }
  lock_path=$(_coord_wq_lock_path "$file")
  timeout=$(_coord_wq_flock_timeout)
  local p
  p=$(
    (
      flock -s -w "$timeout" 9 || exit 2
      jq -r --arg f "$file" --arg s "$sid" \
        '(.wait_queues[$f] // []) | map(.session_id) | index($s) // -1' \
        "$state" 2>/dev/null
    ) 9>"$lock_path"
  )
  case "$p" in
    ''|*[!0-9-]*) p='-1' ;;
  esac
  printf '%s' "$p"
  return 0
}

# coord_wait_queue_cleanup_session <sid>
#   Walk every file in wait_queues and remove <sid> from each. Per-
#   file dequeues use the per-file flock; the walk itself does NOT
#   hold a global lock (each file is independent).
#
#   Wake files are removed alongside queue entries. Idempotent.
#
#   Emits WAIT_QUEUE_SESSION_CLEANUP with affected_files +
#   removed_count.
coord_wait_queue_cleanup_session() {
  local sid="$1"
  [ -z "$sid" ] && return 1
  [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ] && return 1
  _coord_wq_ensure_dirs || return 1
  local state
  state=$(_coord_wq_state) || return 1
  [ ! -f "$state" ] && return 0

  # Snapshot the file list of queues that contain this sid. Read-only;
  # no flock needed for the snapshot itself (per-file dequeue under
  # per-file flock handles concurrent mutation defensively).
  local files_json files
  files_json=$(jq -r --arg s "$sid" '
    [ .wait_queues // {}
      | to_entries[]
      | select(.value | any(.session_id == $s))
      | .key ]
  ' "$state" 2>/dev/null || printf '[]')
  files=$(printf '%s' "$files_json" | jq -r '.[]' 2>/dev/null)

  local affected=0 removed=0
  if [ -n "$files" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      affected=$((affected + 1))
      if coord_wait_queue_dequeue "$sid" "$f"; then
        removed=$((removed + 1))
      fi
    done <<<"$files"
  fi

  # Defensive sweep: remove any stale wake files matching this sid
  # (e.g., from a crash where the queue entry was already gone but
  # the wake_file lingered).
  local sweep_count=0
  if [ -d "${COORD_DIR}/wakers" ]; then
    local f
    for f in "${COORD_DIR}/wakers/${sid}-"*.wake; do
      [ -e "$f" ] || continue
      rm -f "$f"
      sweep_count=$((sweep_count + 1))
    done
  fi

  coord_log_event kind=WAIT_QUEUE_SESSION_CLEANUP source=coord_wait_queue_cleanup_session \
    session="$sid" affected_files="$affected" removed_count="$removed" \
    wake_files_swept="$sweep_count"
  return 0
}

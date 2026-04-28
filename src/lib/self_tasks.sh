#!/usr/bin/env bash
# self_tasks.sh — Phase 6 T6.04 per-session self-delegation record
# store. Implements PR-PHASE6-02 (Decision 2 — file-unlock-based
# Stop "unresolved" semantic) + Decision 2.13 (self-delegation
# mechanism) + PR-PHASE6-05 §4/§7 (prompt_id synthesis +
# self_tasks schema).
#
# Public API (five functions; mirrors Phase 5 wait_queue.sh shape):
#   coord_self_task_open              <sid> <file> <instruction>
#   coord_self_task_list              <sid>
#   coord_self_task_check_unlocked    <sid>
#   coord_self_task_archive           <sid> <prompt_id> <reason>
#   coord_self_task_cleanup_session   <sid>
#
# Per-session flock at $COORD_DIR/self_tasks/<sanitized_sid>.lock.
# Path sanitization: literal `tr / __` (mirrors PR-PHASE5-01 §1
# pin-point a-1 wait_queue pattern). Session IDs typically contain
# no slashes; the sanitization is defensive parity with wait_queue.
#
# self_tasks[<sid>] schema (sessions.json top-level slot;
# Decision 2.13 + PR-PHASE6-05 §7 + T6.06 additive
# last_reminded_at field for reminder throttling):
#   {
#     "self_tasks": {
#       "<sid>": [
#         {
#           "file":              "/absolute/path/to/file",
#           "instruction":       "human-readable task description",
#           "created_at":        "<ISO8601 with ms>",
#           "prompt_id":         "<sid>-self-<created_at_ms>-<random_4_hex>",
#           "last_reminded_at":  null | "<ISO8601 with ms>"
#         }
#       ]
#     }
#   }
#
# T6.06 additive field: last_reminded_at — null until first
# reminder injection by pre_tool_use_any.sh; updated to ISO
# timestamp on each reminder emission. Throttle window: 5
# minutes (300s) — coord_self_task_check_reminder_due returns
# rc 0 only when null OR more than 5 minutes have elapsed.
#
# T6.07 additive field: stop_block_count — integer, default 0.
# Incremented by stop.sh when a Stop attempt encounters this
# self-task as unresolved (file unlocked) per Decision 2.13.
# stop_block_count == 0 → first Stop blocks with reminder.
# stop_block_count >= 1 → second Stop allows + archives the
# task as SKIPPED with reason=stop_second_attempt.
#
# Schema additive; schema_version stays at 1.0 per user T6.04
# binding (Phase 6 additive-only).
#
# Events emitted:
#   SELF_TASK_OPENED         — coord_self_task_open new entry
#   SELF_TASK_OPEN_IDEMPOTENT — coord_self_task_open dedup hit
#   SELF_TASK_ARCHIVED        — coord_self_task_archive
#                                (payload.reason=COMPLETED|SKIPPED)
#   SELF_TASK_SKIPPED        — coord_self_task_cleanup_session
#                                (payload.reason=session_end)
#
# Note on event vocabulary: PR-PHASE6-02 §"Audit event vocabulary"
# enumerated SELF_TASK_OPENED/REMINDER/SKIPPED for the full Phase 6
# self-task lifecycle. SELF_TASK_REMINDER is emitted by
# pre_tool_use_any.sh (T6.06), not by this lib. T6.04 adds
# SELF_TASK_ARCHIVED + SELF_TASK_OPEN_IDEMPOTENT as audit-trail
# additives consistent with the lib's open/archive boundary.
#
# Dependencies (must be sourced by caller before invoking these):
#   - lib/atomic_write.sh    (coord_atomic_edit)
#   - lib/log_event.sh       (coord_log_event, coord_now_iso8601)
#   - jq, flock              (caller's deps gate already verified)
#
# Environment:
#   COORD_DIR — required.
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern).
# §A.13 pre-implementation audit applied; lessons #1, #2, #5, #6,
# #7, #9, #10 + Phase 6 candidates Cand-11..Cand-14.

# ---------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------

# _coord_st_sanitize <sid>
#   Mirror wait_queue's `tr / __` sanitization for the per-session
#   lock file name. Session IDs are typically UUIDs (no slashes) but
#   sanitize defensively for parity.
_coord_st_sanitize() {
  local s="$1"
  printf '%s' "${s//\//__}"
}

# _coord_st_lock_path <sid>
_coord_st_lock_path() {
  local s
  s=$(_coord_st_sanitize "$1")
  printf '%s/self_tasks/%s.lock' "${COORD_DIR}" "$s"
}

# _coord_st_state — print the path to sessions.json (rc 1 if no
# COORD_DIR).
_coord_st_state() {
  [ -n "${COORD_DIR:-}" ] || return 1
  printf '%s/sessions.json' "${COORD_DIR}"
}

# _coord_st_ensure_dirs — create self_tasks/ if missing.
_coord_st_ensure_dirs() {
  [ -n "${COORD_DIR:-}" ] || return 1
  mkdir -p "${COORD_DIR}/self_tasks" 2>/dev/null
  return 0
}

# _coord_st_flock_timeout — seconds to wait for per-session flock.
_coord_st_flock_timeout() {
  printf '%s' "${COORD_SELF_TASK_FLOCK_TIMEOUT:-5}"
}

# _coord_st_now_ms — millisecond epoch (perl Time::HiRes preferred;
# fallback to second-resolution * 1000 per F-009 portability note).
_coord_st_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time*1000' 2>/dev/null \
    || date -u +%s000
}

# _coord_st_random_hex4 — 4 hex characters; openssl primary,
# RANDOM*RANDOM fallback (Bash 3.2 portable; coord task-open's
# task_id synthesis precedent).
_coord_st_random_hex4() {
  local hex
  if hex=$(openssl rand -hex 2 2>/dev/null); then
    printf '%s' "$hex"
    return 0
  fi
  printf '%04x' $((RANDOM*RANDOM)) | tail -c 4
}

# _coord_st_synth_prompt_id <sid> <ms>
#   Synthesize prompt_id per PR-PHASE6-05 §4 +Q4 binding:
#   <sid>-self-<created_at_ms>-<random_4_hex>.
_coord_st_synth_prompt_id() {
  local sid="$1" ms="$2"
  local hex
  hex=$(_coord_st_random_hex4)
  printf '%s-self-%s-%s' "$sid" "$ms" "$hex"
}

# ---------------------------------------------------------------
# Public: coord_self_task_open
# ---------------------------------------------------------------

# coord_self_task_open <sid> <file> <instruction>
#   Persist a self-task into self_tasks[<sid>]. Idempotent within
#   a 1-second window: if the same (sid, file, instruction) tuple
#   exists with created_at_ms within 1000 ms of now, return the
#   existing prompt_id without creating a duplicate (mirrors
#   wait_queue idempotent-enqueue spirit; per user T6.04 binding).
#
#   Stdout: prompt_id (newly synthesized or existing on idempotent
#           hit).
#   Returns: 0 success (new or idempotent)
#            1 missing arg / COORD_DIR
#            2 flock timeout
#            3 atomic_edit failure
coord_self_task_open() {
  local sid="$1" file="$2" instruction="$3"
  if [ -z "$sid" ] || [ -z "$file" ] || [ -z "$instruction" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  if ! _coord_st_ensure_dirs; then
    return 1
  fi

  local state lock_path timeout
  state=$(_coord_st_state) || return 1
  lock_path=$(_coord_st_lock_path "$sid")
  timeout=$(_coord_st_flock_timeout)

  local now_ms now_iso prompt_id
  now_ms=$(_coord_st_now_ms)
  now_iso=$(coord_now_iso8601)
  prompt_id=$(_coord_st_synth_prompt_id "$sid" "$now_ms")

  # Inter-subshell channel for prompt_id + status (Bash 3.2 parser
  # fragility on `out=$( ( cmd ) 9>"lock" )` — mirror wait_queue
  # temp-file pattern).
  local out_tmp
  out_tmp="${COORD_DIR}/self_tasks/.open.$$.$(_coord_st_sanitize "$sid").out"
  : >"$out_tmp"

  (
    flock -x -w "$timeout" 9 || exit 2

    # Idempotency check: search self_tasks[<sid>] for an entry with
    # the same (file, instruction) pair whose created_at is within
    # 1000 ms of now_ms. ISO8601 ms suffix stripped via sub() before
    # fromdateiso8601 (jq 1.6+ doesn't handle the .NNN fraction
    # natively). Returns the existing prompt_id, or empty when no
    # match.
    local existing_pid
    existing_pid=$(jq -r --arg s "$sid" --arg f "$file" \
      --arg ins "$instruction" --arg now "$now_ms" \
      '(.self_tasks[$s] // [])
       | map(select(.file == $f and .instruction == $ins))
       | map(. + {
           _ms: (try (.created_at | sub("\\.\\d+Z$"; "Z")
                                  | fromdateiso8601 * 1000) catch 0)
         })
       | map(select(($now | tonumber) - ._ms <= 1000))
       | if length > 0 then .[0].prompt_id else "" end
      ' "$state" 2>/dev/null) || existing_pid=""

    if [ -n "$existing_pid" ]; then
      printf 'idempotent\t%s\n' "$existing_pid" >"$out_tmp"
      exit 0
    fi

    # Append new entry. Field order per Decision 2.13 +
    # T6.06 additive last_reminded_at (null until first
    # reminder) + T6.07 additive stop_block_count
    # (default 0; incremented by stop.sh on each block).
    if ! coord_atomic_edit "$state" '
          .self_tasks[$s] = (.self_tasks[$s] // [])
          | .self_tasks[$s] += [{
              file:             $f,
              instruction:      $ins,
              created_at:       $cat,
              prompt_id:        $pid,
              last_reminded_at: null,
              stop_block_count: 0
            }]
        ' \
        --arg s   "$sid" \
        --arg f   "$file" \
        --arg ins "$instruction" \
        --arg cat "$now_iso" \
        --arg pid "$prompt_id"; then
      exit 3
    fi
    printf 'new\t%s\n' "$prompt_id" >"$out_tmp"
    exit 0
  ) 9>"$lock_path"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp"
    return "$rc"
  fi

  local out mode resolved_pid
  out=$(cat "$out_tmp" 2>/dev/null || printf '')
  rm -f "$out_tmp"
  mode=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $1}')
  resolved_pid=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $2}')

  if [ "$mode" = "idempotent" ]; then
    coord_log_event kind=SELF_TASK_OPEN_IDEMPOTENT \
      session="$sid" file="$file" prompt_id="$resolved_pid" \
      2>/dev/null || true
  else
    coord_log_event kind=SELF_TASK_OPENED \
      session="$sid" file="$file" prompt_id="$resolved_pid" \
      created_at="$now_iso" \
      2>/dev/null || true
  fi
  printf '%s\n' "$resolved_pid"
  return 0
}

# ---------------------------------------------------------------
# Public: coord_self_task_list
# ---------------------------------------------------------------

# coord_self_task_list <sid>
#   Stdout: JSON array of self_tasks[<sid>] (file, instruction,
#   created_at, prompt_id). Empty array `[]` when no tasks.
#   rc 0 always (read-only).
coord_self_task_list() {
  local sid="$1"
  if [ -z "$sid" ] || [ -z "${COORD_DIR:-}" ]; then
    printf '[]\n'
    return 0
  fi
  local state
  state=$(_coord_st_state) || { printf '[]\n'; return 0; }
  [ -f "$state" ] || { printf '[]\n'; return 0; }

  local out
  out=$(jq -c --arg s "$sid" '.self_tasks[$s] // []' "$state" 2>/dev/null) \
    || out='[]'
  printf '%s\n' "$out"
  return 0
}

# ---------------------------------------------------------------
# Public: coord_self_task_check_unlocked
# ---------------------------------------------------------------

# coord_self_task_check_unlocked <sid>
#   Walk self_tasks[<sid>] and return the subset whose .file is
#   either NOT currently locked OR locked by <sid> itself (B can
#   acquire it now). PR-PHASE6-02 §"User-resolved decision":
#   "unresolved" semantic is file-unlock-based.
#
#   Stdout: JSON array of unlocked tasks.
#   rc 0 always.
coord_self_task_check_unlocked() {
  local sid="$1"
  if [ -z "$sid" ] || [ -z "${COORD_DIR:-}" ]; then
    printf '[]\n'
    return 0
  fi
  local state
  state=$(_coord_st_state) || { printf '[]\n'; return 0; }
  [ -f "$state" ] || { printf '[]\n'; return 0; }

  # jq filter: for each self-task, keep iff
  #   .locks[<file>] is absent OR .locks[<file>].session == sid
  # Save the per-task object as $t before piping so $t.file
  # references the task's file (not $lk's "file" key — without
  # the save, `($lk | has(.file))` rebinds `.` to $lk and
  # has() reads $lk["file"] which is always absent).
  local out
  out=$(jq -c --arg s "$sid" '
    (.locks // {}) as $lk
    | (.self_tasks[$s] // [])
    | map(. as $t | select(
        ($lk | has($t.file) | not)
        or ($lk[$t.file].session == $s)
      ))
  ' "$state" 2>/dev/null) || out='[]'
  printf '%s\n' "$out"
  return 0
}

# ---------------------------------------------------------------
# Public: coord_self_task_archive
# ---------------------------------------------------------------

# coord_self_task_archive <sid> <prompt_id> <reason>
#   Remove the entry matching <prompt_id> from self_tasks[<sid>].
#   <reason>: "COMPLETED" | "SKIPPED" (free-form for caller; lib
#   does not enforce enum but caller per PR-PHASE6-02 should pass
#   one of these).
#
#   Returns: 0 archived (entry was present and removed)
#            1 prompt_id not found / args missing / atomic_edit fail
#            2 flock timeout
coord_self_task_archive() {
  local sid="$1" prompt_id="$2" reason="$3"
  if [ -z "$sid" ] || [ -z "$prompt_id" ] || [ -z "$reason" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  if ! _coord_st_ensure_dirs; then
    return 1
  fi

  local state lock_path timeout
  state=$(_coord_st_state) || return 1
  lock_path=$(_coord_st_lock_path "$sid")
  timeout=$(_coord_st_flock_timeout)

  local out_tmp
  out_tmp="${COORD_DIR}/self_tasks/.archive.$$.$(_coord_st_sanitize "$sid").out"
  : >"$out_tmp"

  (
    flock -x -w "$timeout" 9 || exit 2

    # Snapshot: was the prompt_id present pre-edit? (Drives rc.)
    local present
    present=$(jq -r --arg s "$sid" --arg pid "$prompt_id" \
      '(.self_tasks[$s] // []) | map(select(.prompt_id == $pid)) | length' \
      "$state" 2>/dev/null) || present=0
    case "$present" in
      ''|*[!0-9]*) present=0 ;;
    esac
    if [ "$present" = "0" ]; then
      printf 'not_found\n' >"$out_tmp"
      exit 0
    fi

    if ! coord_atomic_edit "$state" '
          .self_tasks[$s] = (.self_tasks[$s] // [])
          | .self_tasks[$s] |= map(select(.prompt_id != $pid))
        ' \
        --arg s "$sid" --arg pid "$prompt_id"; then
      printf 'atomic_fail\n' >"$out_tmp"
      exit 0
    fi
    printf 'archived\n' >"$out_tmp"
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
  mode=$(printf '%s' "$out" | awk 'NR==1{print $1}')

  case "$mode" in
    archived)
      coord_log_event kind=SELF_TASK_ARCHIVED \
        session="$sid" prompt_id="$prompt_id" reason="$reason" \
        2>/dev/null || true
      return 0
      ;;
    not_found|atomic_fail|*)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------
# Public: coord_self_task_cleanup_session
# ---------------------------------------------------------------

# coord_self_task_cleanup_session <sid>
#   Drops self_tasks[<sid>] entirely (called from session_end.sh).
#   Each removed task emits SELF_TASK_SKIPPED with
#   payload.reason=session_end.
#
#   Returns: 0 success (or no-op if no tasks present)
#            1 missing arg / COORD_DIR
#            2 flock timeout
#            3 atomic_edit failure
coord_self_task_cleanup_session() {
  local sid="$1"
  if [ -z "$sid" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  if ! _coord_st_ensure_dirs; then
    return 1
  fi

  local state lock_path timeout
  state=$(_coord_st_state) || return 1
  lock_path=$(_coord_st_lock_path "$sid")
  timeout=$(_coord_st_flock_timeout)

  local out_tmp
  out_tmp="${COORD_DIR}/self_tasks/.cleanup.$$.$(_coord_st_sanitize "$sid").out"
  : >"$out_tmp"

  (
    flock -x -w "$timeout" 9 || exit 2

    # Snapshot the prompt_ids before deletion so we can emit one
    # SELF_TASK_SKIPPED event per archived task in the post-flock
    # block (event emission outside the critical section per
    # CLAUDE.md §A.5: "No subshells inside critical (flock-held)
    # sections" — log_event itself backgrounds an append, but we
    # surface the IDs to the parent via $out_tmp anyway for
    # cleanliness).
    jq -r --arg s "$sid" \
      '(.self_tasks[$s] // [])[].prompt_id' \
      "$state" 2>/dev/null >"$out_tmp" || :

    if ! coord_atomic_edit "$state" \
        'if .self_tasks then .self_tasks |= del(.[$s]) else . end' \
        --arg s "$sid"; then
      exit 3
    fi
    exit 0
  ) 9>"$lock_path"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp"
    return "$rc"
  fi

  # Per-removed-task event emission. Empty file → no events.
  local pid
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    coord_log_event kind=SELF_TASK_SKIPPED \
      session="$sid" prompt_id="$pid" reason=session_end \
      2>/dev/null || true
  done <"$out_tmp"
  rm -f "$out_tmp"
  return 0
}

# ---------------------------------------------------------------
# Phase 6 T6.06 — Reminder throttling helpers
# ---------------------------------------------------------------

# coord_self_task_check_reminder_due <sid> <prompt_id>
#   Decide whether the self-task identified by <prompt_id> in
#   self_tasks[<sid>] is due for a reminder injection. Throttle
#   window: 5 minutes (300s). null last_reminded_at OR
#   (now_ms - last_reminded_at_ms > 300_000) → due.
#
#   Returns: 0 due (caller should inject reminder)
#            1 not due (within throttle window)
#            2 prompt_id not found
coord_self_task_check_reminder_due() {
  local sid="$1" prompt_id="$2"
  if [ -z "$sid" ] || [ -z "$prompt_id" ] \
     || [ -z "${COORD_DIR:-}" ]; then
    return 2
  fi
  local state
  state=$(_coord_st_state) || return 2
  [ -f "$state" ] || return 2

  # Lookup the entry. Returns "absent" / "null" / <ISO timestamp>.
  local last
  last=$(jq -r --arg s "$sid" --arg pid "$prompt_id" '
    (.self_tasks[$s] // [])
    | map(select(.prompt_id == $pid))
    | if length == 0 then "absent"
      elif (.[0].last_reminded_at // null) == null then "null"
      else .[0].last_reminded_at
      end
  ' "$state" 2>/dev/null) || last="absent"

  case "$last" in
    absent) return 2 ;;
    null)   return 0 ;;
  esac

  local now_ms last_ms diff
  now_ms=$(_coord_st_now_ms)
  last_ms=$(printf '%s' "$last" \
    | jq -Rr 'sub("\\.\\d+Z$"; "Z") | fromdateiso8601 * 1000' 2>/dev/null) \
    || last_ms=0
  case "$last_ms" in
    ''|*[!0-9]*) last_ms=0 ;;
  esac
  diff=$(( now_ms - last_ms ))
  if [ "$diff" -gt 300000 ]; then
    return 0
  fi
  return 1
}

# coord_self_task_record_reminder <sid> <prompt_id>
#   Update self_tasks[<sid>][?(.prompt_id == <pid>)].last_reminded_at
#   to the current ISO ms timestamp. Idempotent (same caller can
#   set repeatedly; throttle gate is in check_reminder_due).
#
#   Returns: 0 success
#            1 args missing / atomic_edit failure / prompt_id not found
#            2 flock timeout
coord_self_task_record_reminder() {
  local sid="$1" prompt_id="$2"
  if [ -z "$sid" ] || [ -z "$prompt_id" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  if ! _coord_st_ensure_dirs; then
    return 1
  fi

  local state lock_path timeout
  state=$(_coord_st_state) || return 1
  lock_path=$(_coord_st_lock_path "$sid")
  timeout=$(_coord_st_flock_timeout)

  local now_iso
  now_iso=$(coord_now_iso8601)

  local out_tmp
  out_tmp="${COORD_DIR}/self_tasks/.reminder.$$.$(_coord_st_sanitize "$sid").out"
  : >"$out_tmp"

  (
    flock -x -w "$timeout" 9 || exit 2

    # Confirm the prompt_id exists.
    local present
    present=$(jq -r --arg s "$sid" --arg pid "$prompt_id" \
      '(.self_tasks[$s] // []) | map(select(.prompt_id == $pid)) | length' \
      "$state" 2>/dev/null) || present=0
    case "$present" in
      ''|*[!0-9]*) present=0 ;;
    esac
    if [ "$present" = "0" ]; then
      printf 'not_found\n' >"$out_tmp"
      exit 0
    fi

    if ! coord_atomic_edit "$state" '
          .self_tasks[$s] = (.self_tasks[$s] // [])
          | .self_tasks[$s] |= map(
              if .prompt_id == $pid
              then .last_reminded_at = $now
              else .
              end
            )
        ' \
        --arg s "$sid" --arg pid "$prompt_id" --arg now "$now_iso"; then
      printf 'atomic_fail\n' >"$out_tmp"
      exit 0
    fi
    printf 'recorded\n' >"$out_tmp"
    exit 0
  ) 9>"$lock_path"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp"
    return "$rc"
  fi
  local mode
  mode=$(awk 'NR==1{print $1}' "$out_tmp" 2>/dev/null)
  rm -f "$out_tmp"
  case "$mode" in
    recorded) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------
# Phase 6 T6.07 — Stop block-count helper
# ---------------------------------------------------------------

# coord_self_task_increment_stop_block <sid> <prompt_id>
#   Atomically increment self_tasks[<sid>][?(.prompt_id ==
#   <pid>)].stop_block_count by 1. Used by stop.sh on the first
#   Stop attempt encountering an unresolved self-task; the
#   incremented count is what stop.sh reads on the SECOND Stop
#   attempt to know "we already blocked this once → allow +
#   archive SKIPPED" per Decision 2.13.
#
#   Stdout: new count value (post-increment), e.g. "1" / "2".
#   Returns: 0 success
#            1 args missing / atomic_edit failure / prompt_id
#              not found
#            2 flock timeout
coord_self_task_increment_stop_block() {
  local sid="$1" prompt_id="$2"
  if [ -z "$sid" ] || [ -z "$prompt_id" ]; then
    return 1
  fi
  if [ -z "${COORD_DIR:-}" ] || [ ! -d "${COORD_DIR}" ]; then
    return 1
  fi
  if ! _coord_st_ensure_dirs; then
    return 1
  fi

  local state lock_path timeout
  state=$(_coord_st_state) || return 1
  lock_path=$(_coord_st_lock_path "$sid")
  timeout=$(_coord_st_flock_timeout)

  local out_tmp
  out_tmp="${COORD_DIR}/self_tasks/.stopblock.$$.$(_coord_st_sanitize "$sid").out"
  : >"$out_tmp"

  (
    flock -x -w "$timeout" 9 || exit 2

    # Confirm the prompt_id exists.
    local present
    present=$(jq -r --arg s "$sid" --arg pid "$prompt_id" \
      '(.self_tasks[$s] // []) | map(select(.prompt_id == $pid)) | length' \
      "$state" 2>/dev/null) || present=0
    case "$present" in
      ''|*[!0-9]*) present=0 ;;
    esac
    if [ "$present" = "0" ]; then
      printf 'not_found\n' >"$out_tmp"
      exit 0
    fi

    # Atomic increment: |= map(if pid match then add 1 else
    # passthrough). Coalesce missing field to 0 before adding.
    if ! coord_atomic_edit "$state" '
          .self_tasks[$s] = (.self_tasks[$s] // [])
          | .self_tasks[$s] |= map(
              if .prompt_id == $pid
              then .stop_block_count = (((.stop_block_count // 0)) + 1)
              else .
              end
            )
        ' \
        --arg s "$sid" --arg pid "$prompt_id"; then
      printf 'atomic_fail\n' >"$out_tmp"
      exit 0
    fi

    # Read the new count for stdout return.
    local new_count
    new_count=$(jq -r --arg s "$sid" --arg pid "$prompt_id" \
      '(.self_tasks[$s] // [])
       | map(select(.prompt_id == $pid))
       | (first.stop_block_count // 0)' \
      "$state" 2>/dev/null) || new_count=0
    case "$new_count" in
      ''|*[!0-9]*) new_count=0 ;;
    esac
    printf 'incremented\t%s\n' "$new_count" >"$out_tmp"
    exit 0
  ) 9>"$lock_path"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$out_tmp"
    return "$rc"
  fi

  local out mode count
  out=$(cat "$out_tmp" 2>/dev/null || printf '')
  rm -f "$out_tmp"
  mode=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $1}')
  count=$(printf '%s' "$out" | awk -F'\t' 'NR==1{print $2}')

  case "$mode" in
    incremented)
      coord_log_event kind=SELF_TASK_STOP_BLOCKED \
        session="$sid" prompt_id="$prompt_id" \
        stop_block_count="$count" \
        2>/dev/null || true
      printf '%s\n' "$count"
      return 0
      ;;
    *) return 1 ;;
  esac
}

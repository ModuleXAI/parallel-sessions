#!/usr/bin/env bats
# Tests for lib/notify_waiters.sh 4-tier diff_summary computation
# per Phase 5 T5.04 + PR-PHASE5-02 §5.
#
# Categories:
#   1. Verdict-file lookup path (3 tests)
#   2. Cache lookup path        (3 tests)
#   3. Pre-filter path          (3 tests)
#   4. Fallback path            (2 tests)
#   5. Multi-waiter broadcast   (2 tests)
#   6. events.jsonl scan deletion verification (2 tests)
#   7. Schema field population  (1 test)

load "../helpers/common"

setup() {
  TMP="$(mktemp -d -t coord-nw-XXXX)"
  COORD_DIR="$(mk_coord_dir "$TMP")"
  export COORD_DIR
  mkdir -p "$COORD_DIR/wakers" "$COORD_DIR/wait_queues" \
           "$COORD_DIR/validator/verdict" "$COORD_DIR/read_snapshots"
  mk_empty_sessions "$COORD_DIR"
  : >"$COORD_DIR/events.jsonl"
  printf '{"schema_version":"1.0","wait_backend":"polling"}' >"$COORD_DIR/config.json"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/atomic_write.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/log_event.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/hash.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/wait_queue.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/validator_cache.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/read_snapshots.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/validator_prefilter.sh"
  # shellcheck disable=SC1091
  . "$SRC_ROOT/lib/notify_waiters.sh"
  HOLDER='holder-001'
  WAITER='waiter-001'
  FILE="$TMP/foo.ts"
  printf 'foo content v1\n' >"$FILE"
}
teardown() {
  rm -rf "$TMP"
}

# Helpers ---------------------------------------------------------

# _setup_lock_with_verdict <verdict_ts>
#   Create a lock for $HOLDER on $FILE with optional verdict_ts.
_setup_lock_with_verdict() {
  local vts="${1:-}"
  if [ -z "$vts" ]; then
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f] = {session: $sid, acquired_at: "2026-04-27T00:00:00Z",
                     last_refresh_at: "2026-04-27T00:00:00Z", tasks: [],
                     latest_validator_verdict_ts: null}' \
      --arg f "$FILE" --arg sid "$HOLDER"
  else
    coord_atomic_edit "$COORD_DIR/sessions.json" \
      '.locks[$f] = {session: $sid, acquired_at: "2026-04-27T00:00:00Z",
                     last_refresh_at: "2026-04-27T00:00:00Z", tasks: [],
                     latest_validator_verdict_ts: $vts}' \
      --arg f "$FILE" --arg sid "$HOLDER" --arg vts "$vts"
  fi
}

# _enqueue_waiter — places $WAITER in wait_queues[$FILE].
_enqueue_waiter() {
  SESSION_ID=$WAITER coord_wait_queue_enqueue "$WAITER" "$FILE" >/dev/null
}

# _wake_file_path
_wake_file_path() {
  local sanitized="${FILE//\//__}"
  printf '%s/wakers/%s-%s.wake' "$COORD_DIR" "$WAITER" "$sanitized"
}

# _write_verdict_file <ts> <diff_summary>
_write_verdict_file() {
  local ts="$1" summary="$2"
  printf '{"verdict_id":"v-%s","ts":"%s","verdict":"MINOR","reasoning":"...","diff_summary":"%s"}\n' \
    "$ts" "$ts" "$summary" >"$COORD_DIR/validator/verdict/${ts}.json"
}

# _write_read_set_entry <hash>
#   Add a is_latest=true read_set entry for $HOLDER on $FILE.
_write_read_set_entry() {
  local h="$1"
  coord_atomic_edit "$COORD_DIR/sessions.json" \
    '.read_sets[$sid] //= {reads: []}
     | .read_sets[$sid].reads += [{path: $f, hash: $h, at: "2026-04-27T00:00:00Z", is_latest: true}]' \
    --arg sid "$HOLDER" --arg f "$FILE" --arg h "$h"
}

# ----- Category 1: Verdict-file lookup path -----

@test "notify_waiters: tier 1 verdict-file → wake_file content matches verdict diff_summary" {
  local ts='2026-04-27T01:00:00.000Z'
  _write_verdict_file "$ts" "Renamed loginHandler to signInHandler"
  _setup_lock_with_verdict "$ts"
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z' "$ts"
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [ "$content" = "Renamed loginHandler to signInHandler" ]
}

@test "notify_waiters: tier 1 verdict-file deleted (GC) → falls back to next tier" {
  local ts='2026-04-27T01:00:00.000Z'
  _setup_lock_with_verdict "$ts"
  # Verdict file does not exist (simulating GC after lock acquire).
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z' "$ts"
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  # Should NOT match the verdict text (file gone) — falls to fallback
  # "modified by <8>".
  [[ "$content" = "modified by holder-0"* ]]
}

@test "notify_waiters: tier 1 verdict-file malformed JSON → falls back to next tier" {
  local ts='2026-04-27T01:00:00.000Z'
  printf 'not-valid-json\n' >"$COORD_DIR/validator/verdict/${ts}.json"
  _setup_lock_with_verdict "$ts"
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z' "$ts"
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [[ "$content" = "modified by holder-0"* ]]
}

# ----- Category 2: Cache lookup path -----

@test "notify_waiters: tier 2 cache hit MINOR → wake_file content matches cached diff_summary" {
  local prev_h cur_h
  printf 'foo v0\n' >"$FILE.snap"
  prev_h=$(coord_hash_file "$FILE.snap")
  cur_h=$(coord_hash_file "$FILE")
  # Pre-populate read_set so the helper can derive prev_hash.
  _write_read_set_entry "$prev_h"
  # Pre-populate cache.
  coord_validator_cache_write "$FILE" "$prev_h" "$cur_h" \
    'MINOR' 'validator_agent' 'Reformatted with prettier'
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [ "$content" = "Reformatted with prettier" ]
}

@test "notify_waiters: tier 2 cache hit SAFE → wake_file content is trivial-change marker" {
  local prev_h cur_h
  printf 'foo v0\n' >"$FILE.snap"
  prev_h=$(coord_hash_file "$FILE.snap")
  cur_h=$(coord_hash_file "$FILE")
  _write_read_set_entry "$prev_h"
  coord_validator_cache_write "$FILE" "$prev_h" "$cur_h" \
    'SAFE' 'prefilter'
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [ "$content" = "trivial change (no semantic drift)" ]
}

@test "notify_waiters: tier 2 cache miss + no read_set → falls to fallback (no prev_hash)" {
  # No read_set entry → tier 2 + tier 3 short-circuit; goes to tier 4.
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [[ "$content" = "modified by holder-0"* ]]
}

# ----- Category 3: Pre-filter path -----

@test "notify_waiters: tier 3 pre-filter SAFE (whitespace) → trivial change marker" {
  # Snapshot has same content with trailing whitespace; current is clean.
  printf 'foo content v1   \n' >"$FILE.tmp"
  printf 'foo content v1\n'    >"$FILE"
  local prev_h cur_h
  prev_h=$(coord_hash_file "$FILE.tmp")
  cur_h=$(coord_hash_file "$FILE")
  # Write the snapshot to read_snapshots/<sid>/<hash>.txt for pre-filter.
  coord_read_snapshot_write "$HOLDER" "$prev_h" "$FILE.tmp"
  _write_read_set_entry "$prev_h"
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [ "$content" = "trivial change (whitespace/comment)" ]
}

@test "notify_waiters: tier 3 pre-filter ESCALATE → fallback (real semantic drift)" {
  # Snapshot vs current differ by a real code line, not whitespace.
  printf 'function login() { return 1; }\n' >"$FILE.tmp"
  printf 'function authenticate() { return 1; }\n' >"$FILE"
  local prev_h cur_h
  prev_h=$(coord_hash_file "$FILE.tmp")
  cur_h=$(coord_hash_file "$FILE")
  coord_read_snapshot_write "$HOLDER" "$prev_h" "$FILE.tmp"
  _write_read_set_entry "$prev_h"
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [[ "$content" = "modified by holder-0"* ]]
}

@test "notify_waiters: tier 3 pre-filter snapshot missing → fallback" {
  # read_set entry exists but no snapshot file present → pre-filter
  # ESCALATEs; falls to fallback.
  _write_read_set_entry "deadbeef00000000000000000000000000000000000000000000000000000000"
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [[ "$content" = "modified by holder-0"* ]]
}

# ----- Category 4: Fallback path -----

@test "notify_waiters: tier 4 fallback string format = 'modified by <8>'" {
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  content=$(cat "$wake")
  [ "$content" = "modified by holder-0" ]
}

@test "notify_waiters: all-tier-failure still produces non-empty wake_file (resilience)" {
  _setup_lock_with_verdict ''
  _enqueue_waiter
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local wake content
  wake=$(_wake_file_path)
  [ -s "$wake" ]
  content=$(cat "$wake")
  [ -n "$content" ]
}

# ----- Category 5: Multi-waiter broadcast -----

@test "notify_waiters: 3 waiters receive same diff_summary (computed once, broadcast)" {
  local ts='2026-04-27T01:00:00.000Z'
  _write_verdict_file "$ts" "Variable rename: x to y"
  _setup_lock_with_verdict "$ts"
  coord_wait_queue_enqueue 'wA' "$FILE" >/dev/null
  coord_wait_queue_enqueue 'wB' "$FILE" >/dev/null
  coord_wait_queue_enqueue 'wC' "$FILE" >/dev/null
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z' "$ts"
  local sanitized
  sanitized="${FILE//\//__}"
  for w in wA wB wC; do
    local content
    content=$(cat "$COORD_DIR/wakers/${w}-${sanitized}.wake")
    [ "$content" = "Variable rename: x to y" ]
  done
}

@test "notify_waiters: NOTIFICATION_PRODUCED event records diff_summary_source tier" {
  local ts='2026-04-27T01:00:00.000Z'
  _write_verdict_file "$ts" "Renamed function"
  _setup_lock_with_verdict "$ts"
  _enqueue_waiter
  : >"$COORD_DIR/events.jsonl"
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z' "$ts"
  sleep 0.1
  run grep -c '"diff_summary_source":"verdict_file"' "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
}

# ----- Category 6: events.jsonl scan deletion verification -----

@test "notify_waiters: lib/notify_waiters.sh contains NO LOCK_DENIED scan" {
  ! grep -q '"LOCK_DENIED"' "$SRC_ROOT/lib/notify_waiters.sh"
}

@test "notify_waiters: legacy LOCK_DENIED entries do NOT trigger notification (wait_queues authoritative)" {
  # Pre-populate events.jsonl with a LOCK_DENIED entry that would
  # have triggered notification under Phase 2's scan logic.
  printf '{"ts":"2026-04-27T00:30:00Z","kind":"LOCK_DENIED","file":"%s","session":"old-denied","payload":{}}\n' \
    "$FILE" >"$COORD_DIR/events.jsonl"
  _setup_lock_with_verdict ''
  # NO enqueue. notify_waiters should produce ZERO wake_file writes.
  coord_notify_lock_release_waiters "$HOLDER" "$FILE" \
    '2026-04-27T00:00:00Z' '2026-04-27T01:00:30Z'
  local sanitized
  sanitized="${FILE//\//__}"
  # No wake_file should exist for the legacy LOCK_DENIED session.
  [ ! -e "$COORD_DIR/wakers/old-denied-${sanitized}.wake" ]
  # No notifications entry should be added either (Phase 2 producer
  # path is dead).
  run jq -r '.notifications // {} | keys | length' "$COORD_DIR/sessions.json"
  [ "$output" = "0" ]
}

# ----- Category 7: Schema field population -----

@test "schema: locks[<file>].latest_validator_verdict_ts populates from validator pipeline run" {
  # Static check: pre_tool_use_write.sh's lock-acquire atomic_edit
  # filter writes the latest_validator_verdict_ts field. Verifying
  # via grep over the production code (the full hook integration
  # is exercised in pre_tool_use_write_pipeline.bats).
  grep -q 'latest_validator_verdict_ts' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  # And the field is plumbed via TARGET_VERDICT_TS captured from the
  # pipeline's _COORD_PHASE4_LAST_VERDICT_TS output variable.
  grep -q 'TARGET_VERDICT_TS=' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
  grep -q '_COORD_PHASE4_LAST_VERDICT_TS' "$SRC_ROOT/hooks/pre_tool_use_write.sh"
}

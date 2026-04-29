#!/usr/bin/env bats
# Tests for lib/log_event.sh per plan §4 test criteria:
#   - concurrent log_event calls from N sessions produce valid JSONL
#     with no interleaved bytes
#   - single call writes a well-formed event
#   - caller never sees a delayed hook (non-blocking)

load "../helpers/common"

LOG="$SRC_ROOT/lib/log_event.sh"

setup() {
  TMP="$(mktemp -d -t coord-logevent-XXXX)"
  mk_coord_dir "$TMP" >/dev/null
  export COORD_DIR="$TMP/.coord"
  export SESSION_ID="session-test-0001"
}

teardown() {
  rm -rf "$TMP"
}

@test "log_event: single call produces a valid JSON line" {
  run "$LOG" kind=READ tool=Read file=/foo hash=deadbeef
  [ "$status" -eq 0 ]
  sleep 0.2  # allow backgrounded append to flush
  [ -s "$COORD_DIR/events.jsonl" ]
  run jq -c . "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "log_event: required scalar fields land at the top level" {
  "$LOG" kind=WRITE tool=Edit file=/path/x hash=beefface
  sleep 0.2
  local line
  line=$(head -1 "$COORD_DIR/events.jsonl")
  [ "$(echo "$line" | jq -r .kind)" = "WRITE" ]
  [ "$(echo "$line" | jq -r .tool)" = "Edit" ]
  [ "$(echo "$line" | jq -r .file)" = "/path/x" ]
  [ "$(echo "$line" | jq -r .hash)" = "beefface" ]
  [ "$(echo "$line" | jq -r .session)" = "$SESSION_ID" ]
  [[ "$(echo "$line" | jq -r .ts)" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "log_event: extra keys land in .payload" {
  "$LOG" kind=INFO reason=test counter=7
  sleep 0.2
  local line
  line=$(head -1 "$COORD_DIR/events.jsonl")
  [ "$(echo "$line" | jq -r .payload.reason)" = "test" ]
  [ "$(echo "$line" | jq -r .payload.counter)" = "7" ]
}

@test "log_event: 5 concurrent appends produce 5 valid JSON lines, no interleave" {
  for i in 1 2 3 4 5; do
    ( "$LOG" kind=LOCK_ACQUIRE tool=Write file=/f/$i hash=h$i index="$i" ) &
  done
  wait
  # Give backgrounded appenders a beat.
  sleep 0.3
  local n
  n=$(wc -l <"$COORD_DIR/events.jsonl" | tr -d ' ')
  [ "$n" -eq 5 ]
  run jq -c . "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  # Every line has kind=LOCK_ACQUIRE
  local k
  k=$(jq -r 'select(.kind == "LOCK_ACQUIRE") | .kind' "$COORD_DIR/events.jsonl" | wc -l | tr -d ' ')
  [ "$k" -eq 5 ]
}

@test "log_event: caller returns quickly (non-blocking append)" {
  local start end dur_ms
  start=$(perl -MTime::HiRes=gettimeofday -e 'my @t=gettimeofday; print int($t[0]*1000)+int($t[1]/1000)')
  "$LOG" kind=READ tool=Read file=/a hash=aaaa
  end=$(perl -MTime::HiRes=gettimeofday -e 'my @t=gettimeofday; print int($t[0]*1000)+int($t[1]/1000)')
  dur_ms=$((end - start))
  # Caller should return in well under 1 second even under load.
  [ "$dur_ms" -lt 1000 ]
}

@test "log_event: no COORD_DIR → silent no-op, not an error" {
  unset COORD_DIR
  run "$LOG" kind=INFO message=nocoord
  [ "$status" -eq 0 ]
}

@test "log_event: malformed key in extra pair is dropped, not injected" {
  "$LOG" kind=INFO 'bad key=value' good=y
  sleep 0.2
  local line
  line=$(head -1 "$COORD_DIR/events.jsonl")
  [ "$(echo "$line" | jq -r '.payload.good')" = "y" ]
  # "bad key" (space in key) must NOT become a field.
  [ "$(echo "$line" | jq -r '.payload | keys | length')" -eq 1 ]
}

# -----------------------------------------------------------------
# Phase 7 / T7.06a — coord_log_event_sync (F-016 fix)
# -----------------------------------------------------------------

@test "log_event_sync: write completes BEFORE function returns (no sleep needed)" {
  # Critical contract: caller can grep events.jsonl immediately
  # after sync return, no sleep delay required (vs the async
  # variant which needs sleep 0.2 above).
  run "$LOG" --sync kind=WAIT_TIMEOUT reason=interrupted file=/foo
  [ "$status" -eq 0 ]
  # NO sleep here — write must already be flushed.
  [ -s "$COORD_DIR/events.jsonl" ]
  local line
  line=$(head -1 "$COORD_DIR/events.jsonl")
  [ "$(echo "$line" | jq -r .kind)" = "WAIT_TIMEOUT" ]
  [ "$(echo "$line" | jq -r .payload.reason)" = "interrupted" ]
}

@test "log_event_sync: payload shape identical to async variant" {
  run "$LOG" --sync kind=WAIT_TIMEOUT tool=Bash file=/x hash=ff reason=interrupted
  [ "$status" -eq 0 ]
  local line
  line=$(head -1 "$COORD_DIR/events.jsonl")
  [ "$(echo "$line" | jq -r .kind)" = "WAIT_TIMEOUT" ]
  [ "$(echo "$line" | jq -r .tool)" = "Bash" ]
  [ "$(echo "$line" | jq -r .file)" = "/x" ]
  [ "$(echo "$line" | jq -r .hash)" = "ff" ]
  [ "$(echo "$line" | jq -r .session)" = "$SESSION_ID" ]
  [ "$(echo "$line" | jq -r .payload.reason)" = "interrupted" ]
}

@test "log_event_sync: missing COORD_DIR → silent no-op (same as async)" {
  unset COORD_DIR
  run "$LOG" --sync kind=INFO message=nocoord
  [ "$status" -eq 0 ]
}

@test "log_event_sync: 5 concurrent sync appends serialize via flock" {
  for i in 1 2 3 4 5; do
    ( "$LOG" --sync kind=LOCK_ACQUIRE tool=Write file=/sf/$i hash=s$i index="$i" ) &
  done
  wait
  # NO post-wait sleep — sync semantics guarantee writes complete
  # before each `wait` $! returns.
  local k
  k=$(jq -r 'select(.kind == "LOCK_ACQUIRE") | .kind' "$COORD_DIR/events.jsonl" | wc -l | tr -d ' ')
  [ "$k" -eq 5 ]
}

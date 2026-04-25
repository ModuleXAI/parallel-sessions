#!/usr/bin/env bash
# concurrent_smoke.sh — 5-session concurrent events.jsonl smoke test.
# Ship-gate criterion (plan §5 Phase 0): events.jsonl must remain valid
# JSONL under 5-session concurrent load.
#
# Simulation:
#   - Spawn 5 subshells each acting as a session.
#   - Each session runs session_start (registration), then 50 log_event
#     appends mixing READ / WRITE / LOCK_ACQUIRE / LOCK_RELEASE kinds, then
#     session_end.
#   - After all finish, assert every events.jsonl line parses as JSON, the
#     sessions.json is still valid JSON, and registry contains all 5 sessions
#     in IDLE_CLOSED state.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t coord-smoke-XXXX)"
trap 'rm -rf "$TMP"' EXIT

# Set up a fake coord dir.
COORD_DIR="$TMP/.coord"
mkdir -p "$COORD_DIR/sessions" "$COORD_DIR/hooks" "$COORD_DIR/lib" "$COORD_DIR/mediator"
cp "$SRC_DIR"/lib/*.sh    "$COORD_DIR/lib/"
cp "$SRC_DIR"/hooks/*.sh  "$COORD_DIR/hooks/"
"$COORD_DIR/lib/atomic_write.sh" template >"$COORD_DIR/sessions.json"
for f in sessions.lock events.lock history.lock; do : >"$COORD_DIR/$f"; done
: >"$COORD_DIR/events.jsonl"
export COORD_DIR CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$TMP"

N_SESSIONS=5
EVENTS_PER_SESSION=50

run_session() {
  local sid="$1"
  # Register.
  printf '%s\n' "{\"session_id\":\"$sid\",\"cwd\":\"$TMP\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
    | "$COORD_DIR/hooks/session_start.sh" >/dev/null
  # Log events mixing kinds.
  local i
  export SESSION_ID="$sid"
  local kinds=(READ WRITE LOCK_ACQUIRE LOCK_RELEASE NOTIFICATION_EMIT INFO)
  for i in $(seq 1 "$EVENTS_PER_SESSION"); do
    local k="${kinds[$((i % ${#kinds[@]}))]}"
    "$COORD_DIR/lib/log_event.sh" kind="$k" tool=Write file="/f/$sid/$i" hash="h$i" seq="$i"
  done
  # End.
  printf '%s\n' "{\"session_id\":\"$sid\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"smoke\"}" \
    | "$COORD_DIR/hooks/session_end.sh" >/dev/null
}

printf '[smoke] launching %d sessions × %d events each ...\n' "$N_SESSIONS" "$EVENTS_PER_SESSION" >&2
PIDS=()
for i in $(seq 1 "$N_SESSIONS"); do
  run_session "sid-smoke-$i" &
  PIDS+=("$!")
done
for p in "${PIDS[@]}"; do wait "$p"; done
# Give backgrounded appenders a moment to flush.
sleep 0.5

# Assertions --------------------------------------------------------------
fail=0

# 1. Every events.jsonl line is valid JSON.
line_count=$(wc -l <"$COORD_DIR/events.jsonl" | tr -d ' ')
bad_lines=0
while IFS= read -r line || [ -n "$line" ]; do
  if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    bad_lines=$((bad_lines+1))
  fi
done <"$COORD_DIR/events.jsonl"
printf '[smoke] events.jsonl: %s lines, %s invalid\n' "$line_count" "$bad_lines"
if [ "$bad_lines" -ne 0 ]; then fail=1; fi

# 2. At least (N_SESSIONS * EVENTS_PER_SESSION + 2*N_SESSIONS) lines — registrations, events, ends.
min_expected=$(( N_SESSIONS * EVENTS_PER_SESSION + 2 * N_SESSIONS ))
if [ "$line_count" -lt "$min_expected" ]; then
  printf '[smoke] FAIL: expected at least %s lines, got %s\n' "$min_expected" "$line_count"
  fail=1
fi

# 3. sessions.json parses cleanly and contains all sessions in IDLE_CLOSED.
if ! jq -e . "$COORD_DIR/sessions.json" >/dev/null 2>&1; then
  printf '[smoke] FAIL: sessions.json is not valid JSON\n'
  fail=1
fi
closed_count=$(jq -r '[.sessions[] | select(.state == "IDLE_CLOSED")] | length' "$COORD_DIR/sessions.json" 2>/dev/null || printf '0')
printf '[smoke] sessions in IDLE_CLOSED: %s/%s\n' "$closed_count" "$N_SESSIONS"
if [ "$closed_count" != "$N_SESSIONS" ]; then fail=1; fi

# 4. No lock remains held.
lock_count=$(jq -r '.locks | length' "$COORD_DIR/sessions.json" 2>/dev/null || printf '0')
printf '[smoke] locks held at end: %s\n' "$lock_count"
if [ "$lock_count" != "0" ]; then fail=1; fi

# 5. Active markers cleaned.
markers_remaining=0
for f in "$COORD_DIR/sessions"/*.active; do
  [ -e "$f" ] && markers_remaining=$((markers_remaining+1))
done
printf '[smoke] .active markers remaining: %s\n' "$markers_remaining"
if [ "$markers_remaining" != "0" ]; then fail=1; fi

# 6. Every session emitted exactly 1 REGISTER + EVENTS_PER_SESSION events + 1 END.
for i in $(seq 1 "$N_SESSIONS"); do
  _sid="sid-smoke-$i"
  # jq -s reads the whole file as an array, then filters.
  reg=$(jq -rs --arg s "$_sid" '[.[] | select(.session == $s and .kind == "SESSION_REGISTER")] | length' "$COORD_DIR/events.jsonl")
  end=$(jq -rs --arg s "$_sid" '[.[] | select(.session == $s and .kind == "SESSION_END")] | length' "$COORD_DIR/events.jsonl")
  mid=$(jq -rs --arg s "$_sid" '[.[] | select(.session == $s and .kind != "SESSION_REGISTER" and .kind != "SESSION_END")] | length' "$COORD_DIR/events.jsonl")
  printf '[smoke]   %s: reg=%s mid=%s end=%s\n' "$_sid" "$reg" "$mid" "$end"
  if [ "$reg" != "1" ] || [ "$end" != "1" ] || [ "$mid" != "$EVENTS_PER_SESSION" ]; then fail=1; fi
done

if [ "$fail" -ne 0 ]; then
  printf '[smoke] FAIL\n'
  exit 1
fi
printf '[smoke] PASS\n'

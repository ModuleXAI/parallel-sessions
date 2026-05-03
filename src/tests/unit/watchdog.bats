#!/usr/bin/env bats
# Tests for lib/watchdog.sh + pre_tool_use_any.sh ambient-suspicion
# wiring (Phase 3 / T3.05 per PR-PHASE3-02).
#
# Coverage:
#   - probe with 4 PID/activity/lock signal combinations -> verdict
#   - probe cache hit short-circuits fresh probe
#   - probe under concurrent invocations: only one runs (dedupe)
#   - ambient_suspicion: healthy / activity-stale / lock-stale / pid-gone
#   - pre_tool_use_any.sh: invokes watchdog when suspicion present
#   - pre_tool_use_any.sh: no invocation when healthy
#   - probe writes Mediator pending entries with correct kind +
#     uncertain flag

load "../helpers/common"

WD="$SRC_ROOT/core/lib/watchdog.sh"
WC="$SRC_ROOT/core/lib/watchdog_cache.sh"
MP="$SRC_ROOT/core/lib/mediator_pending.sh"
LE="$SRC_ROOT/core/lib/log_event.sh"
HANY="$SRC_ROOT/adapters/claude-code/hooks/pre_tool_use_any.sh"

setup() {
  TMP="$(mktemp -d -t coord-watchdog-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  mkdir -p "$COORD/watchdog/checking" "$COORD/mediator"
  : >"$COORD/watchdog/recent_checks.jsonl"
  : >"$COORD/watchdog/recent_checks.lock"
  : >"$COORD/mediator/pending.lock"
  # Pre-create empty pending.jsonl so `wc -l <file` works even on
  # alive-verdict / dedupe-skipped paths where no producer ever writes.
  : >"$COORD/mediator/pending.jsonl"
  export COORD_DIR="$COORD"
  # The OBSERVER session (the one running the watchdog).
  OBSERVER="observer-001"
  touch "$COORD_DIR/sessions/${OBSERVER}.active"
  jq --arg sid "$OBSERVER" '
    .sessions[$sid] = {state:"ACTIVE",pid:1,pid_lstart:"x",registered_at:"y",last_activity_at:"z",git_head:"",prompt_id:null,script_version:"1.0"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  export SESSION_ID="$OBSERVER"
  TARGET="target-002"
}

teardown() {
  unset CLAUDE_COORD COORD_DIR SESSION_ID
  rm -rf "$TMP"
}

# Helpers -----------------------------------------------------------------

# _seed_target <pid> <pid_lstart> <last_activity_iso>
#   Insert a target session record into sessions.json with the given
#   PID/lstart/activity timestamp.
_seed_target() {
  local pid="$1" lstart="$2" act="$3"
  jq --arg sid "$TARGET" --arg pid "$pid" --arg lstart "$lstart" --arg act "$act" '
    .sessions[$sid] = {
      state: "ACTIVE",
      pid: ($pid | tonumber),
      pid_lstart: $lstart,
      registered_at: "2026-04-01T00:00:00Z",
      last_activity_at: $act,
      git_head: "",
      prompt_id: null,
      script_version: "1.0"
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

# _seed_target_lock <file> <session_id> <acquired_at> <last_refresh_at>
_seed_target_lock() {
  local file="$1" sid="$2" acq="$3" ref="$4"
  jq --arg f "$file" --arg sid "$sid" --arg acq "$acq" --arg ref "$ref" '
    .locks[$f] = {session: $sid, acquired_at: $acq, last_refresh_at: $ref, tasks: []}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

# _now_iso, _ago_iso <seconds>
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ago_iso() {
  local secs="$1" target_epoch
  target_epoch="$(( $(date -u +%s) - secs ))"
  date -u -r "$target_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$target_epoch" +%Y-%m-%dT%H:%M:%SZ
}

# _probe <target>
#   Run probe synchronously (NOT backgrounded — bats needs to wait for
#   verdict). Loads all required helpers in one bash -c.
_probe() {
  local t="$1"
  bash -c '
    . "'"$LE"'"
    . "'"$WC"'"
    . "'"$MP"'"
    . "'"$WD"'"
    coord_watchdog_probe "'"$t"'"
  '
}

# --- Probe verdicts -------------------------------------------------------

@test "probe: PID gone -> dead/pid_gone, kind=stale_active in pending" {
  # Pick a PID that almost certainly doesn't exist.
  _seed_target 99999 "Sat Jan  1 00:00:00 2000" "$(_now_iso)"
  run _probe "$TARGET"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "dead") ? 0 : 1}'
  echo "$output" | grep -q "PID 99999 is gone"
  # Pending entry: kind=stale_active source=watchdog
  sleep 0.2
  run jq -rs 'last | .kind' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "stale_active" ]
  run jq -rs 'last | .source' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "watchdog" ]
  run jq -rs 'last | .payload.target' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "$TARGET" ]
}

@test "probe: PID alive but lstart mismatched -> dead/pid_recycled" {
  # Use the bats process's own PID + a deliberately-wrong lstart string.
  _seed_target "$$" "Sat Jan  1 00:00:00 2000" "$(_now_iso)"
  run _probe "$TARGET"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "dead") ? 0 : 1}'
  echo "$output" | grep -q "recycled"
  sleep 0.2
  run jq -rs 'last | .kind' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "pid_recycled" ]
}

@test "probe: PID alive + activity recent + no locks -> alive (no pending)" {
  # Use bats process's actual PID + actual lstart so PID/lstart match.
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_now_iso)"
  run _probe "$TARGET"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "alive") ? 0 : 1}'
  # No pending entry written.
  run wc -l <"$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -eq 0 ]
}

@test "probe: PID alive + activity stale (>10min) -> uncertain/stale_active+uncertain=true" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_ago_iso 700)"  # 700s = >10min
  run _probe "$TARGET"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "uncertain") ? 0 : 1}'
  echo "$output" | grep -q "last_activity"
  sleep 0.2
  run jq -rs 'last | .kind' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "stale_active" ]
  run jq -rs 'last | .payload.uncertain' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "true" ]
}

@test "probe: PID alive + lock held > 30min, never refreshed -> uncertain" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_now_iso)"
  local stale_ts; stale_ts=$(_ago_iso 2000)  # 2000s > 30min threshold
  _seed_target_lock "$TMP/foo.txt" "$TARGET" "$stale_ts" "$stale_ts"
  run _probe "$TARGET"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "uncertain") ? 0 : 1}'
  echo "$output" | grep -q "without refresh"
  sleep 0.2
  run jq -rs 'last | .payload.uncertain' "$COORD_DIR/mediator/pending.jsonl"
  [ "$output" = "true" ]
}

@test "probe: cache hit short-circuits fresh probe" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_now_iso)"
  # Pre-seed a fresh "alive" verdict in the cache.
  bash -c '. "'"$LE"'"; . "'"$WC"'"; coord_watchdog_cache_record "'"$TARGET"'" alive "cached" 60'
  # Now probe — should return cached value WITHOUT re-running ps or
  # writing a second WATCHDOG_PROBED event.
  run _probe "$TARGET"
  [ "$status" -eq 0 ]
  echo "$output" | awk -F'\t' '{exit ($1 == "alive" && $2 == "cached") ? 0 : 1}'
  # No WATCHDOG_PROBED event (the cache short-circuit returned before
  # the audit-log step that fires only on fresh probe).
  sleep 0.2
  if [ -f "$COORD_DIR/events.jsonl" ]; then
    run jq -rs '[.[] | select(.kind == "WATCHDOG_PROBED")] | length' "$COORD_DIR/events.jsonl"
    [ "$output" = "0" ]
  fi
}

@test "probe: dedupe lock prevents concurrent fresh probes" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_ago_iso 700)"  # uncertain target
  # Manually acquire the dedupe lock on behalf of "another invoker".
  bash -c '. "'"$WC"'"; coord_watchdog_acquire_check_lock "'"$TARGET"'"' >/dev/null
  # A second probe attempt must skip (rc=1, no output).
  run _probe "$TARGET"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # No verdict cached; no pending entry.
  run wc -l <"$COORD_DIR/watchdog/recent_checks.jsonl"
  [ "$output" -eq 0 ]
  run wc -l <"$COORD_DIR/mediator/pending.jsonl"
  [ "$output" -eq 0 ]
}

# --- Ambient suspicion ----------------------------------------------------

# _suspicion: invoke check_ambient_suspicion in a fresh bash for clean state.
_suspicion() {
  bash -c '
    . "'"$LE"'"
    . "'"$WC"'"
    . "'"$WD"'"
    coord_watchdog_check_ambient_suspicion
  '
}

@test "ambient_suspicion: healthy other-sessions -> empty output" {
  # Add a second healthy session (not self).
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_now_iso)"
  run _suspicion
  [ -z "$output" ]
}

@test "ambient_suspicion: stale-activity session is flagged" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_ago_iso 700)"
  run _suspicion
  echo "$output" | grep -q "$TARGET"
}

@test "ambient_suspicion: stale-lock session is flagged" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_now_iso)"
  local stale_ts; stale_ts=$(_ago_iso 2000)
  _seed_target_lock "$TMP/foo.txt" "$TARGET" "$stale_ts" "$stale_ts"
  run _suspicion
  echo "$output" | grep -q "$TARGET"
}

@test "ambient_suspicion: pid-gone session is flagged" {
  _seed_target 99999 "Sat Jan  1 00:00:00 2000" "$(_now_iso)"
  run _suspicion
  echo "$output" | grep -q "$TARGET"
}

@test "ambient_suspicion: SELF is never flagged" {
  # Make our own observer record stale to confirm the self-filter.
  jq --arg sid "$OBSERVER" --arg ago "$(_ago_iso 9999)" '
    .sessions[$sid].last_activity_at = $ago
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
  run _suspicion
  case "$output" in *"$OBSERVER"*) echo "VIOLATION: self flagged"; return 1 ;; esac
}

@test "ambient_suspicion: same target hit by 2 triggers is deduped to 1 line" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  # Stale activity + stale lock on same target.
  _seed_target "$$" "$lstart" "$(_ago_iso 700)"
  local stale_ts; stale_ts=$(_ago_iso 2000)
  _seed_target_lock "$TMP/foo.txt" "$TARGET" "$stale_ts" "$stale_ts"
  run _suspicion
  count=$(printf '%s\n' "$output" | grep -c "^$TARGET$" || true)
  [ "$count" -eq 1 ]
}

# --- Hook wiring ----------------------------------------------------------

@test "pre_tool_use_any: ambient suspicion present -> watchdog backgrounded" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  # Seed a stale-activity target so suspicion fires.
  _seed_target "$$" "$lstart" "$(_ago_iso 700)"
  local input='{"session_id":"'"$OBSERVER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$HANY"
  [ "$status" -eq 0 ]
  # Hook returned quickly (background probe); allow time for it to run.
  sleep 1
  # Probe should have written a verdict (uncertain — alive PID + stale activity).
  run jq -rs 'map(.target == "'"$TARGET"'")  | any' "$COORD_DIR/watchdog/recent_checks.jsonl"
  [ "$output" = "true" ]
  run jq -rs '[.[] | select(.target == "'"$TARGET"'")] | last | .verdict' "$COORD_DIR/watchdog/recent_checks.jsonl"
  [ "$output" = "uncertain" ]
}

@test "pre_tool_use_any: no ambient suspicion -> no watchdog probe" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_now_iso)"
  local input='{"session_id":"'"$OBSERVER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  CLAUDE_COORD=1 run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$HANY"
  [ "$status" -eq 0 ]
  sleep 0.5
  # No verdict cached.
  run wc -l <"$COORD_DIR/watchdog/recent_checks.jsonl"
  [ "$output" -eq 0 ]
}

@test "pre_tool_use_any: hook latency under suspicion stays below 1000ms wall-clock (probe is backgrounded)" {
  local lstart
  lstart=$(ps -p $$ -o lstart= 2>/dev/null | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\n')
  _seed_target "$$" "$lstart" "$(_ago_iso 700)"
  local input='{"session_id":"'"$OBSERVER"'","cwd":"'"$TMP"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  # Use perl for portable millisecond timing.
  local t_start t_end
  t_start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  CLAUDE_COORD=1 bash -c 'printf "%s" "$1" | "$2" >/dev/null 2>&1' _ "$input" "$HANY"
  t_end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  local elapsed_ms=$(( t_end - t_start ))
  echo "hook elapsed: ${elapsed_ms}ms" >&2
  # Loose budget (1000ms) — bats environment overhead + ps fork is the
  # bulk; the watchdog probe itself runs in the background and does
  # not count. Plan §A.6 hard ceiling is 2000ms p99.
  [ "$elapsed_ms" -lt 1000 ]
}

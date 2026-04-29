#!/usr/bin/env bats
# Tests for lib/cost_guards.sh per PR-PHASE7-03 §"Tests (T7.04)":
#   - 18-25 unit tests covering: first-invoke / under-cap / cap+1
#     rate-limit / hour-prune / counter-reset event / mediator
#     min-interval / concurrent flock / missing file / corrupted
#     file / cross-site independence / status read-only
#     semantics / clear idempotency.
#
# Mode interlock testing is OUT OF SCOPE for T7.04 (covered at
# T7.05 cross-mode integration tests).
#
# §A.13 lesson application:
#   - #5 if var=$(cmd); then ... fi: bats helpers wrap the lib's
#     CLI shim with this form when capturing rc + stdout.
#   - #6 event-emission audit per return path: separate tests
#     per emitted-event kind.
#   - #11 multi-assign local + set -u: helper compliance.

load "../helpers/common"

LIB="$SRC_ROOT/lib/cost_guards.sh"
LOG_EVENT="$SRC_ROOT/lib/log_event.sh"

setup() {
  TMP="$(mktemp -d -t coord-cost-guards-XXXX)"
  mk_coord_dir "$TMP" >/dev/null
  export COORD_DIR="$TMP/.coord"
  export SESSION_ID="session-test-cost-guards"
  # Conservative thresholds for boundary tests (small values let us
  # hit cap quickly without time-padding).
  export COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=3
  export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=0
  export COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=4
  export COORD_COST_GUARDS_FLOCK_TIMEOUT=2
}

teardown() {
  rm -rf "$TMP"
}

# Source helper: invoke via bash -c to make sure backgrounded
# log_event subshells inherit the wrapper's lifetime (Lesson #17).
_check() {
  local site="$1"
  bash -c '
    set -euo pipefail
    source "'"$LOG_EVENT"'"
    source "'"$LIB"'"
    if coord_cost_guards_check "'"$site"'"; then exit 0; else exit 1; fi
  '
}

_status() {
  local site="$1"
  bash -c '
    source "'"$LOG_EVENT"'"
    source "'"$LIB"'"
    coord_cost_guards_status "'"$site"'"
  '
}

_clear() {
  local site="$1"
  bash -c '
    source "'"$LOG_EVENT"'"
    source "'"$LIB"'"
    coord_cost_guards_clear "'"$site"'"
  '
}

_counter_path() {
  printf '%s/cost_guards/%s.counter\n' "$COORD_DIR" "$1"
}

_count_lines() {
  local f="$1"
  if [ -e "$f" ]; then
    wc -l <"$f" | tr -d ' '
  else
    printf '0'
  fi
}

# -----------------------------------------------------------------
# check — happy paths
# -----------------------------------------------------------------

@test "check: first invocation allows + counter file created" {
  run _check mediator
  [ "$status" -eq 0 ]
  [ -e "$(_counter_path mediator)" ]
  [ "$(_count_lines "$(_counter_path mediator)")" = "1" ]
}

@test "check: invocations under cap all allow" {
  run _check mediator; [ "$status" -eq 0 ]
  run _check mediator; [ "$status" -eq 0 ]
  run _check mediator; [ "$status" -eq 0 ]
  [ "$(_count_lines "$(_counter_path mediator)")" = "3" ]
}

@test "check: cap+1 invocation rate-limits + COST_GUARD_RATE_LIMITED event" {
  run _check mediator; [ "$status" -eq 0 ]
  run _check mediator; [ "$status" -eq 0 ]
  run _check mediator; [ "$status" -eq 0 ]
  run _check mediator
  [ "$status" -eq 1 ]
  # Counter NOT appended on rate_limited (still 3).
  [ "$(_count_lines "$(_counter_path mediator)")" = "3" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind=="COST_GUARD_RATE_LIMITED")] | length' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "check: rate_limited event payload carries site/count/limit/window" {
  run _check mediator; run _check mediator; run _check mediator
  run _check mediator
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -r 'select(.kind=="COST_GUARD_RATE_LIMITED") | "\(.payload.site)|\(.payload.count)|\(.payload.limit)|\(.payload.window)"' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "mediator|3|3|hour" ]
}

# -----------------------------------------------------------------
# check — sliding-window prune
# -----------------------------------------------------------------

@test "check: hour-old timestamps pruned + array shrinks" {
  # Pre-seed counter with timestamps older than 1 hour (cutoff).
  local cf
  cf=$(_counter_path mediator)
  mkdir -p "$(dirname "$cf")"
  local two_hours_ago
  two_hours_ago=$(perl -MTime::HiRes=time -e 'printf "%d", (time-7200)*1000')
  printf '%s\n%s\n%s\n' \
    "$two_hours_ago" "$two_hours_ago" "$two_hours_ago" > "$cf"
  [ "$(_count_lines "$cf")" = "3" ]
  # Next check should auto-prune the 3 stale entries + allow.
  run _check mediator
  [ "$status" -eq 0 ]
  # Counter now has only the freshly-appended entry.
  [ "$(_count_lines "$cf")" = "1" ]
}

@test "check: COUNTER_RESET event when prune drops over-limit count" {
  # Pre-seed counter with 5 stale + 0 fresh (over-cap=3).
  local cf
  cf=$(_counter_path mediator)
  mkdir -p "$(dirname "$cf")"
  local two_hours_ago
  two_hours_ago=$(perl -MTime::HiRes=time -e 'printf "%d", (time-7200)*1000')
  for _ in 1 2 3 4 5; do printf '%s\n' "$two_hours_ago" >> "$cf"; done
  run _check mediator
  [ "$status" -eq 0 ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind=="COST_GUARD_COUNTER_RESET")] | length' \
    "$COORD_DIR/events.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run jq -r 'select(.kind=="COST_GUARD_COUNTER_RESET") | "\(.payload.site)|\(.payload.prior_count)|\(.payload.reset_method)"' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "mediator|5|auto_prune" ]
}

# -----------------------------------------------------------------
# check — Mediator min-interval (PR §"Min-interval check")
# -----------------------------------------------------------------

@test "check: mediator min-interval enforced when set" {
  export COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=300
  run _check mediator; [ "$status" -eq 0 ]
  # Second call within 300s → rate-limited via min-interval.
  run _check mediator
  [ "$status" -eq 1 ]
  sleep 0.3
  run jq -r 'select(.kind=="COST_GUARD_RATE_LIMITED") | .payload.window' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "min_interval" ]
}

@test "check: validator does NOT enforce min-interval (only mediator)" {
  # Validator min-interval is 0; rapid calls allowed up to per-hour cap.
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 0 ]
  # 4th allowed (cap=4); 5th blocks.
  run _check validator
  [ "$status" -eq 1 ]
}

# -----------------------------------------------------------------
# check — concurrency (atomicity per PR §Atomicity)
# -----------------------------------------------------------------

@test "check: concurrent invocations under flock serialize correctly" {
  # Spawn 5 parallel checks; cap=3. Expect exactly 3 allows + 2
  # rate_limits across the parallel batch.
  local pids=() results_dir
  results_dir="$TMP/results"
  mkdir -p "$results_dir"
  for i in 1 2 3 4 5; do
    (
      if _check mediator; then
        printf 'allow\n' >"$results_dir/$i"
      else
        printf 'deny\n' >"$results_dir/$i"
      fi
    ) &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do wait "$pid"; done
  local allows denies
  allows=$(grep -l '^allow$' "$results_dir"/* 2>/dev/null | wc -l | tr -d ' ')
  denies=$(grep -l '^deny$' "$results_dir"/* 2>/dev/null | wc -l | tr -d ' ')
  [ "$allows" = "3" ]
  [ "$denies" = "2" ]
  [ "$(_count_lines "$(_counter_path mediator)")" = "3" ]
}

# -----------------------------------------------------------------
# check — failure modes (fail-open per PR §Fail-open)
# -----------------------------------------------------------------

@test "check: missing counter file → created on demand" {
  [ ! -e "$(_counter_path mediator)" ]
  run _check mediator
  [ "$status" -eq 0 ]
  [ -e "$(_counter_path mediator)" ]
}

@test "check: corrupted counter file → non-numeric lines dropped on prune" {
  local cf
  cf=$(_counter_path mediator)
  mkdir -p "$(dirname "$cf")"
  printf 'garbage\nNaN\nabc123\n%s\n' \
    "$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')" > "$cf"
  # 4 lines, only 1 valid → after prune+append should be 2 valid lines.
  run _check mediator
  [ "$status" -eq 0 ]
  # Only the originally-valid line + the new appended line should
  # remain. Garbage lines pruned silently (corruption tolerated).
  [ "$(_count_lines "$cf")" = "2" ]
}

@test "check: unknown site allows (fail-open) without writing counter" {
  run _check unknown_site
  [ "$status" -eq 0 ]
  [ ! -e "$COORD_DIR/cost_guards/unknown_site.counter" ]
}

@test "check: task_processor (reserved) always allows; no counter" {
  # task_processor max=0 sentinel = disabled.
  run _check task_processor
  [ "$status" -eq 0 ]
  run _check task_processor
  [ "$status" -eq 0 ]
  [ ! -e "$(_counter_path task_processor)" ]
}

# -----------------------------------------------------------------
# check — cross-site independence
# -----------------------------------------------------------------

@test "check: mediator counter does NOT affect validator counter" {
  # Hit mediator cap (3).
  run _check mediator; run _check mediator; run _check mediator
  run _check mediator; [ "$status" -eq 1 ]
  # Validator still has full quota (4).
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 0 ]
  run _check validator; [ "$status" -eq 1 ]
}

# -----------------------------------------------------------------
# status — read-only inspection
# -----------------------------------------------------------------

@test "status: empty counter prints count=0 + threshold" {
  run _status mediator
  [ "$status" -eq 0 ]
  _grep_output_for "current_count=0"
  _grep_output_for "threshold=3"
}

@test "status: at-cap counter prints non-zero seconds_until_next_slot" {
  run _check mediator; run _check mediator; run _check mediator
  run _status mediator
  [ "$status" -eq 0 ]
  _grep_output_for "current_count=3"
  # seconds_until_next_slot is the ms-diff to oldest+3600s; a
  # non-zero value (was 3599 in smoke test).
  _grep_output_for "seconds_until_next_slot="
  ! _grep_output_for "seconds_until_next_slot=0$"
}

@test "status: under-cap counter prints seconds_until_next_slot=0" {
  run _check mediator
  run _status mediator
  [ "$status" -eq 0 ]
  _grep_output_for "current_count=1"
  _grep_output_for "seconds_until_next_slot=0"
}

# -----------------------------------------------------------------
# clear — operator escape-hatch
# -----------------------------------------------------------------

@test "clear: truncates counter + emits MANUAL_CLEAR event" {
  run _check mediator; run _check mediator; run _check mediator
  [ "$(_count_lines "$(_counter_path mediator)")" = "3" ]
  run _clear mediator
  [ "$status" -eq 0 ]
  [ "$(_count_lines "$(_counter_path mediator)")" = "0" ]
  sleep 0.3
  run jq -rs '[.[] | select(.kind=="COST_GUARD_MANUAL_CLEAR")] | length' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "1" ]
  run jq -r 'select(.kind=="COST_GUARD_MANUAL_CLEAR") | "\(.payload.site)|\(.payload.prior_count)"' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "mediator|3" ]
}

@test "clear: idempotent on absent counter (rc=0; no event payload count)" {
  [ ! -e "$(_counter_path mediator)" ]
  run _clear mediator
  [ "$status" -eq 0 ]
  sleep 0.3
  # Event still emitted with prior_count=0.
  run jq -r 'select(.kind=="COST_GUARD_MANUAL_CLEAR") | .payload.prior_count' \
    "$COORD_DIR/events.jsonl"
  [ "$output" = "0" ]
}

@test "clear: post-clear next check allows" {
  run _check mediator; run _check mediator; run _check mediator
  run _check mediator; [ "$status" -eq 1 ]
  run _clear mediator
  run _check mediator
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------
# CLI shim coverage
# -----------------------------------------------------------------

@test "CLI: check subcommand returns rc=0 on allow" {
  run "$LIB" check mediator
  [ "$status" -eq 0 ]
}

@test "CLI: check subcommand returns rc=1 on rate-limit" {
  run "$LIB" check mediator
  run "$LIB" check mediator
  run "$LIB" check mediator
  run "$LIB" check mediator
  [ "$status" -eq 1 ]
}

@test "CLI: status subcommand prints payload" {
  run "$LIB" status mediator
  [ "$status" -eq 0 ]
  _grep_output_for "current_count="
}

@test "CLI: clear subcommand returns rc=0" {
  run "$LIB" clear mediator
  [ "$status" -eq 0 ]
}

@test "CLI: missing subcommand → rc=2 + usage" {
  run "$LIB"
  [ "$status" -eq 2 ]
  _grep_output_for "usage: cost_guards.sh"
}

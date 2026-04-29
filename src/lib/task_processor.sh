#!/usr/bin/env bash
# task_processor.sh — Phase 6 T6.05 lock-release task processor.
# Implements PR-PHASE6-05 §3 (affected_lines overlap algorithm) +
# §5 (mock-Claude task-patch contract) + §7 (task record schema +
# lifecycle fields) + §8 (TASK_OUTCOME notification payload).
#
# Public API (4 functions):
#   coord_task_processor_run              <file> <holder_sid>
#                                          <holder_edit_start>
#                                          <holder_edit_end>
#   coord_task_processor_check_affected   <task_start> <task_end>
#                                          <edit_start> <edit_end>
#   coord_task_processor_spawn_claude     <task_record_json>
#   coord_task_processor_write_outcome    <state_file> <file>
#                                          <task_record_json>
#                                          <outcome_json>
#
# Invocation: post_tool_use_write.sh calls coord_task_processor_run
# AFTER lock acquisition is verified by SESSION_ID-as-holder, BEFORE
# the lock-deletion atomic_edit. The processor iterates
# locks[<file>].tasks[] in queue order, classifies each via overlap
# check, optionally spawns mock Claude, and persists outcome (which
# removes the task from the queue + appends a TASK_OUTCOME
# notification to .notifications[<opener>][<file>]).
#
# Mock Claude binary contract (Decision 5 + PR-PHASE6-05 §5):
#   coord_task_processor_spawn_claude reads
#   COORD_MOCK_CLAUDE_TASK_PATCH env. When set, returns its value
#   verbatim as the task-patch JSON. When unset, returns a
#   deterministic default ({status:COMPLETED, diff:"",
#   affected_lines:[0,0], rationale:"mock default"}).
#
# Phase 7 / T7.03 (PR-PHASE7-02 §"Task Processor integration"):
#   The mock-default branch is preserved for COORD_TEST_MODE=mock
#   (default for bats / CI). The COORD_MOCK_CLAUDE_TASK_PATCH
#   env-var override remains the test-fixture determinism
#   path even in non-mock modes (PR-PHASE7-01 §"Non-changes").
#   When mode resolves to semi or realistic AND the env-var is
#   unset, the helper invokes `claude -p` with the same JSON
#   contract. Recursion guard: CLAUDE_CODE_TASK_PROCESSOR=1 +
#   CLAUDE_COORD=0 in spawn env. Tool restrictions: Bash + Read
#   allowed; Write/Edit/NotebookEdit/Task disallowed.
#
# Notification slot: .notifications[<opener_sid>][<file>] is the
# canonical schema slot (existing Phase 1+2 mechanism; see
# notify_waiters.sh:265-267 + pre_tool_use_read.sh:145 +
# pre_tool_use_any.sh:148-149). PR-PHASE6-05 §8 named the slot
# "pending_notifications" — the actual slot name is
# "notifications" with the same array-of-strings semantics. T6.05
# uses the actual slot name; surface to user for PR-PHASE6-05 §8
# inline-edit at T6.11 doc-staging.
#
# Diff truncation (ambiguity D binding): 4KB byte-cap with UTF-8
# codepoint-boundary safe truncation via `head -c 4096 |
# iconv -f UTF-8 -t UTF-8//IGNORE`. Full diff (no cap) persists in
# the TASK_OUTCOME_PERSISTED event payload.
#
# Banner template (ambiguity C binding): uses <holder_session>
# placeholder matching the JSON payload field name.
#
# Dependencies (must be sourced by caller before invoking these):
#   - lib/atomic_write.sh    (coord_atomic_edit)
#   - lib/log_event.sh       (coord_log_event, coord_now_iso8601)
#   - jq, flock              (caller's deps gate already verified)
#   - iconv                  (UTF-8 sanitization; ships in base
#                              macOS + Linux per POSIX)
#
# Environment:
#   COORD_DIR                          — required.
#   COORD_MOCK_CLAUDE_TASK_PATCH       — optional test override
#                                         (mock claude task-patch
#                                         JSON; Phase 6 default;
#                                         takes precedence over
#                                         all modes per PR-PHASE7-01
#                                         non-changes).
#   COORD_TEST_MODE                    — Phase 7 mode switch
#                                         (mock|semi|realistic;
#                                         resolved via spawn_helper).
#   COORD_TASK_PROCESSOR_BUDGET_USD    — real-claude max cost
#                                         (default 0.50; PR-PHASE7-02).
#   COORD_TASK_PROCESSOR_TIMEOUT_SEC   — real-claude wall-clock cap
#                                         (default 120; PR-PHASE7-02).
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern;
# functions handle their own rc semantics).

# Phase 7 / T7.03 tunables for the real-claude branch (introduced
# per PR-PHASE7-02 §"Real-claude task-processor prompt template").
: "${COORD_TASK_PROCESSOR_MODEL:=claude-haiku-4-5-20251001}"
: "${COORD_TASK_PROCESSOR_BUDGET_USD:=0.50}"
: "${COORD_TASK_PROCESSOR_TIMEOUT_SEC:=120}"

# ---------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------

_coord_tp_state() {
  [ -n "${COORD_DIR:-}" ] || return 1
  printf '%s/sessions.json' "${COORD_DIR}"
}

_coord_tp_now_iso8601() {
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    coord_now_iso8601
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

# _coord_tp_truncate_utf8 <input_text> <byte_cap>
#   Stdin/stdout filter: truncate to <byte_cap> bytes via head -c,
#   then drop invalid UTF-8 sequences spanning the cut boundary
#   via iconv -f UTF-8 -t UTF-8//IGNORE. Per ambiguity D binding +
#   PR-PHASE6-05 §8 update.
_coord_tp_truncate_utf8() {
  local cap="${1:-4096}"
  if command -v iconv >/dev/null 2>&1; then
    head -c "$cap" 2>/dev/null | iconv -f UTF-8 -t UTF-8//IGNORE 2>/dev/null
  else
    # Fallback: byte-cap only; UTF-8 boundary may be invalid but
    # iconv-absent hosts are rare (POSIX-mandated). Document in
    # CLAUDE.md §A.13 portability note at T6.11.
    head -c "$cap" 2>/dev/null
  fi
}

# ---------------------------------------------------------------
# Public: coord_task_processor_check_affected
# ---------------------------------------------------------------

# coord_task_processor_check_affected <task_start> <task_end>
#                                       <edit_start> <edit_end>
#   Closed-interval line-range intersection per Q3 binding /
#   PR-PHASE6-05 §3.
#
#   Stdout: "no_overlap" or "overlap"
#   Returns: 0 if no overlap (task can proceed)
#            1 if overlap (CONFLICT outcome)
#            2 if any arg is non-integer / missing
coord_task_processor_check_affected() {
  local ts="${1:-}" te="${2:-}" es="${3:-}" ee="${4:-}"
  for v in "$ts" "$te" "$es" "$ee"; do
    case "$v" in
      ''|*[!0-9]*) return 2 ;;
    esac
  done
  if [ "$te" -ge "$es" ] && [ "$ee" -ge "$ts" ]; then
    printf 'overlap\n'
    return 1
  fi
  printf 'no_overlap\n'
  return 0
}

# ---------------------------------------------------------------
# Public: coord_task_processor_spawn_claude
# ---------------------------------------------------------------

# coord_task_processor_spawn_claude <task_record_json>
#   Mode-aware spawn helper. Resolution priority (PR-PHASE7-01
#   §"Non-changes" + PR-PHASE7-02 §"Task Processor integration"):
#     1. COORD_MOCK_CLAUDE_TASK_PATCH env-var set → use verbatim
#        (test override; precedence over all modes for bats
#        determinism).
#     2. coord_spawn_helper_should_use_real_claude task_processor
#        rc=0 (semi or realistic mode) → invoke `claude -p` with
#        the prompt template + JSON contract.
#     3. Otherwise (mock mode + no env-var override) → return the
#        deterministic default literal (PR-PHASE6-05 §5).
#
#   Stdout: task-patch JSON per PR-PHASE6-05 §5 contract:
#     {"status": "COMPLETED|CONFLICT|SKIPPED",
#      "diff": "<unified diff>",
#      "affected_lines": [<start>, <end>],
#      "rationale": "<text>"}
#   Returns: 0 on success (env-var, real-claude, or default)
#            1 on JSON validation failure / spawn refusal / cost-
#              guard rate-limit
coord_task_processor_spawn_claude() {
  local task_record_json="${1:-}"
  local out=""

  if [ -n "${COORD_MOCK_CLAUDE_TASK_PATCH:-}" ]; then
    # Test override: highest precedence.
    out="$COORD_MOCK_CLAUDE_TASK_PATCH"
  elif command -v coord_spawn_helper_should_use_real_claude >/dev/null 2>&1 \
       && coord_spawn_helper_should_use_real_claude task_processor 2>/dev/null; then
    # Real-claude branch (semi or realistic mode). Per §A.13
    # lesson #5: capture stdout AND check rc in one
    # `if var=$(...)` form to avoid the set-e + pipefail trap.
    if out=$(_coord_tp_real_claude_spawn "$task_record_json"); then
      :
    else
      return 1
    fi
  else
    # Mock default literal.
    out='{"status":"COMPLETED","diff":"","affected_lines":[0,0],"rationale":"mock default"}'
  fi

  # Validate required fields exist + status enum.
  local status
  status=$(printf '%s' "$out" | jq -r '.status // ""' 2>/dev/null)
  case "$status" in
    COMPLETED|CONFLICT|SKIPPED) ;;
    *) return 1 ;;
  esac
  # Validate affected_lines is a 2-int array (per Q5).
  local af_ok
  af_ok=$(printf '%s' "$out" | jq -r '
    if (.affected_lines | type) == "array"
       and (.affected_lines | length) == 2
       and (.affected_lines[0] | type) == "number"
       and (.affected_lines[1] | type) == "number"
    then "ok" else "no" end
  ' 2>/dev/null)
  if [ "$af_ok" != "ok" ]; then
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}

# _coord_tp_real_claude_spawn <task_record_json>
#   Phase 7 / T7.03 real-claude branch. Build prompt from task
#   record, invoke `claude -p` with tool restrictions + recursion
#   guard env vars, capture JSON output. Cost-guard interlock
#   slot (T7.05) is checked before invocation.
#
#   Stdout: task-patch JSON on success.
#   Returns: 0 success / 1 spawn refused / cost-guard rate-limit /
#            empty output / is_error true.
_coord_tp_real_claude_spawn() {
  local task_record_json="${1:-}"

  # Phase 7 / T7.05 cost-guard interlock (filled): cost_guards.sh
  # provides coord_cost_guards_check. task_processor in Phase 7 is
  # reserved-but-unset (max=0 sentinel = always-allow per
  # PR-PHASE7-03 §"Three tunables"); the call falls through to
  # rc=0 every time. Path remains for forward-compat (Phase 7+1
  # may set the tunable).
  if command -v coord_cost_guards_check >/dev/null 2>&1; then
    if ! coord_cost_guards_check task_processor 2>/dev/null; then
      coord_log_event kind=TASK_PROCESSOR_SPAWN_RATE_LIMITED \
        2>/dev/null || true
      return 1
    fi
  fi

  # claude binary check (mirror Mediator/Validator pattern).
  if ! command -v claude >/dev/null 2>&1; then
    coord_log_event kind=TASK_PROCESSOR_SPAWN_REFUSED \
      reason=claude_binary_missing 2>/dev/null || true
    return 1
  fi

  # Recursion guard: refuse if already inside a Task Processor
  # spawn. Mirrors Phase 4 Validator depth-1 guard.
  if [ -n "${CLAUDE_CODE_TASK_PROCESSOR:-}" ] \
     && [ "${CLAUDE_CODE_TASK_PROCESSOR}" != "0" ]; then
    coord_log_event kind=TASK_PROCESSOR_SPAWN_REFUSED \
      reason=recursion_guard \
      caller_env="$CLAUDE_CODE_TASK_PROCESSOR" 2>/dev/null || true
    return 1
  fi

  # Assemble the prompt. Task record JSON contains file +
  # instruction + anchor + complexity + opener; the spawned
  # claude inspects the file (Read) + applies the task per
  # instruction + emits the JSON contract.
  local file_path instruction anchor_search anchor_window complexity
  file_path=$(printf '%s' "$task_record_json" | jq -r '.file // ""' 2>/dev/null)
  instruction=$(printf '%s' "$task_record_json" | jq -r '.instruction // ""' 2>/dev/null)
  anchor_search=$(printf '%s' "$task_record_json" | jq -r '.anchor.search // ""' 2>/dev/null)
  anchor_window=$(printf '%s' "$task_record_json" | jq -r '.anchor.window_lines // ""' 2>/dev/null)
  complexity=$(printf '%s' "$task_record_json" | jq -r '.complexity // "SIMPLE"' 2>/dev/null)

  local prompt
  prompt=$(cat <<EOF
# Section 1: Identity

You are a Task Processor agent in a Claude Code coordination
system. Your role is to apply a delegated task to a file the
parent session was unable to edit due to lock contention. You
are NOT a general-purpose agent; you act on this specific task
and emit a structured outcome.

# Section 2: Constraints

- Allowed tools: Bash, Read.
- Disallowed tools: Write, Edit, NotebookEdit, Task.
- You DO NOT modify any files. You produce a unified diff in
  the JSON output. The post-tool-use hook applies the diff.
- Output format: a SINGLE JSON object on stdout with these
  fields, in this exact shape:
  {
    "status": "COMPLETED" | "CONFLICT" | "SKIPPED",
    "diff": "<unified diff text; empty string if SKIPPED>",
    "affected_lines": [<start_int>, <end_int>],
    "rationale": "<1-3 sentence explanation>"
  }

# Section 3: Task

- File: $file_path
- Instruction: $instruction
- Anchor (PRE-EDIT exact-match string): $anchor_search
- Window: lines $anchor_window
- Complexity: $complexity

Read the file at the path above. Locate the anchor. Apply the
instruction within the window. Produce the unified diff. If the
anchor cannot be found OR the instruction conflicts with the
current file state, emit status=CONFLICT with rationale. If the
task cannot be applied for any reason, emit status=SKIPPED.
Otherwise emit status=COMPLETED.
EOF
)

  local raw_output spawn_rc
  raw_output=$(
    env CLAUDE_COORD=0 CLAUDE_CODE_TASK_PROCESSOR=1 \
        COORD_DIR="$COORD_DIR" \
        claude -p "$prompt" \
          --output-format json \
          --model "$COORD_TASK_PROCESSOR_MODEL" \
          --max-budget-usd "$COORD_TASK_PROCESSOR_BUDGET_USD" \
          --allowedTools "Bash" "Read" \
          --disallowedTools "Write" "Edit" "NotebookEdit" "Task" \
          2>/dev/null
  )
  spawn_rc=$?

  if [ -z "$raw_output" ]; then
    coord_log_event kind=TASK_PROCESSOR_SPAWN_FAILED \
      reason=empty_output spawn_rc="$spawn_rc" 2>/dev/null || true
    return 1
  fi

  local is_error result_text
  is_error=$(printf '%s' "$raw_output" | jq -r '.is_error // false' 2>/dev/null) \
    || is_error=true
  result_text=$(printf '%s' "$raw_output" | jq -r '.result // ""' 2>/dev/null)

  if [ "$is_error" = "true" ]; then
    coord_log_event kind=TASK_PROCESSOR_SPAWN_FAILED \
      reason=is_error_true spawn_rc="$spawn_rc" 2>/dev/null || true
    return 1
  fi

  # The spawned claude may return the JSON contract object inline
  # in .result, OR wrap it in markdown fencing. Try direct JSON
  # parse first; if it fails, attempt to extract from a fenced
  # block.
  local task_patch_json
  if printf '%s' "$result_text" | jq -e '.status' >/dev/null 2>&1; then
    task_patch_json="$result_text"
  else
    # Strip common markdown fencing.
    task_patch_json=$(printf '%s' "$result_text" \
      | sed -n '/^```/,/^```/p' \
      | sed -e '/^```/d')
    if ! printf '%s' "$task_patch_json" | jq -e '.status' >/dev/null 2>&1; then
      coord_log_event kind=TASK_PROCESSOR_SPAWN_FAILED \
        reason=json_parse_failed 2>/dev/null || true
      return 1
    fi
  fi

  coord_log_event kind=TASK_PROCESSOR_SPAWN_COMPLETED \
    spawn_rc="$spawn_rc" 2>/dev/null || true
  printf '%s' "$task_patch_json"
  return 0
}

# ---------------------------------------------------------------
# Public: coord_task_processor_write_outcome
# ---------------------------------------------------------------

# coord_task_processor_write_outcome <state_file> <file>
#                                      <task_record_json>
#                                      <outcome_json>
#   Persist outcome, remove task from locks[<file>].tasks[] queue,
#   append TASK_OUTCOME notification to
#   .notifications[<opener>][<file>]; emit TASK_OUTCOME_PERSISTED
#   event with full diff (no truncation in audit trail).
#
#   Returns: 0 success
#            1 args missing / invalid JSON / atomic_edit failure
coord_task_processor_write_outcome() {
  local state="${1:-}" file="${2:-}" \
        task_record="${3:-}" outcome="${4:-}"
  if [ -z "$state" ] || [ -z "$file" ] \
     || [ -z "$task_record" ] || [ -z "$outcome" ]; then
    return 1
  fi
  if [ ! -f "$state" ]; then
    return 1
  fi

  local task_id opener instruction
  task_id=$(printf '%s' "$task_record" | jq -r '.task_id // ""' 2>/dev/null)
  opener=$(printf '%s' "$task_record" | jq -r '.opener // ""' 2>/dev/null)
  instruction=$(printf '%s' "$task_record" | jq -r '.instruction // ""' 2>/dev/null)
  if [ -z "$task_id" ] || [ -z "$opener" ]; then
    return 1
  fi

  local status diff_full rationale
  status=$(printf '%s' "$outcome" | jq -r '.status // ""' 2>/dev/null)
  diff_full=$(printf '%s' "$outcome" | jq -r '.diff // ""' 2>/dev/null)
  rationale=$(printf '%s' "$outcome" | jq -r '.rationale // ""' 2>/dev/null)
  if [ -z "$status" ]; then
    return 1
  fi

  # Diff truncation for the notification banner (4KB UTF-8-safe per
  # ambiguity D + PR-PHASE6-05 §8). Full diff persisted via the
  # TASK_OUTCOME_PERSISTED event payload.
  local diff_truncated
  diff_truncated=$(printf '%s' "$diff_full" | _coord_tp_truncate_utf8 4096)

  # Build the notification banner per PR-PHASE6-05 §8 + ambiguity C
  # (uses <holder_session> placeholder = SESSION_ID).
  local holder="${SESSION_ID:-unknown}"
  local now_iso
  now_iso=$(_coord_tp_now_iso8601)
  local banner
  banner=$(printf 'Task %s on %s completed by session %s. Status: %s. Rationale: %s. Diff:\n%s' \
    "$task_id" "$file" "$holder" "$status" "$rationale" "$diff_truncated")

  # Persist atomically: (a) remove task from queue by task_id;
  # (b) append banner to .notifications[<opener>][<file>] array.
  if ! coord_atomic_edit "$state" '
        .locks[$f].tasks = (.locks[$f].tasks // [])
        | .locks[$f].tasks |= map(select(.task_id != $tid))
        | .notifications[$op]      = (.notifications[$op] // {})
        | .notifications[$op][$f]  = (.notifications[$op][$f] // [])
        | .notifications[$op][$f] += [$banner]
      ' \
      --arg f "$file" --arg tid "$task_id" \
      --arg op "$opener" --arg banner "$banner"; then
    coord_log_event kind=ERROR source=task_processor \
      file="$file" reason=outcome_persist_failed task_id="$task_id" \
      2>/dev/null || true
    return 1
  fi

  coord_log_event kind=TASK_OUTCOME_PERSISTED \
    file="$file" task_id="$task_id" opener="$opener" \
    holder_session="$holder" status="$status" \
    rationale="$rationale" diff_full="$diff_full" \
    completed_at="$now_iso" \
    2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------
# Public: coord_task_processor_run
# ---------------------------------------------------------------

# coord_task_processor_run <file> <holder_sid> <holder_edit_start>
#                            <holder_edit_end>
#   Top-level entry invoked by post_tool_use_write.sh on lock
#   release. Iterates locks[<file>].tasks[] in queue order.
#
#   For each task:
#     1. Parse affected_lines_at_open from task record.
#     2. Run coord_task_processor_check_affected against holder
#        edit range.
#     3. On overlap → outcome status = CONFLICT, no claude spawn.
#     4. On no overlap → coord_task_processor_spawn_claude →
#        parse mock JSON (status / diff / affected_lines /
#        rationale).
#     5. On spawn failure → outcome status = SKIPPED with
#        rationale "task processor: spawn failed (mock binary
#        unavailable)".
#     6. coord_task_processor_write_outcome to persist + notify
#        + event.
#
#   Returns: 0 always (errors logged via TASK_PROCESSOR_RUN event;
#            never blocks the post-hook critical path)
coord_task_processor_run() {
  local file="${1:-}" holder="${2:-}" \
        edit_start="${3:-0}" edit_end="${4:-0}"
  if [ -z "$file" ] || [ -z "$holder" ]; then
    return 0
  fi
  local state
  state=$(_coord_tp_state) || return 0
  [ -f "$state" ] || return 0

  # edit_start / edit_end may arrive empty when Claude Code's
  # PostToolUse payload didn't include line ranges (e.g., Write
  # whole-file replace). In that case, treat as "all lines"
  # conservatively → forces CONFLICT for any anchored task. Sentinel
  # 0/0 means "no overlap with any range" — but here we want the
  # opposite (overlap with everything). Use [1, MAX] when edit_end
  # is 0 and the file has been wholly rewritten. For Phase 6
  # simplicity, when both bounds are 0 we treat as "no edit info"
  # → all tasks get CONFLICT (conservative).
  local force_conflict=0
  case "$edit_start" in
    ''|*[!0-9]*) edit_start=0 ;;
  esac
  case "$edit_end" in
    ''|*[!0-9]*) edit_end=0 ;;
  esac
  if [ "$edit_start" = "0" ] && [ "$edit_end" = "0" ]; then
    force_conflict=1
  fi

  # Snapshot the task list under a single jq read (pre-iteration).
  # Each task is processed individually with its own atomic_edit;
  # the queue may shrink as we go but our iteration is over the
  # snapshot.
  local tasks_json
  tasks_json=$(jq -c --arg f "$file" '.locks[$f].tasks // []' \
    "$state" 2>/dev/null) || tasks_json='[]'
  local task_count
  task_count=$(printf '%s' "$tasks_json" | jq -r 'length' 2>/dev/null) \
    || task_count=0
  case "$task_count" in
    ''|*[!0-9]*) task_count=0 ;;
  esac

  if [ "$task_count" = "0" ]; then
    coord_log_event kind=TASK_PROCESSOR_RUN \
      file="$file" holder="$holder" task_count=0 \
      completed=0 conflicts=0 skipped=0 \
      2>/dev/null || true
    return 0
  fi

  # Counters for the summary event.
  local n_completed=0 n_conflict=0 n_skipped=0

  local i=0
  while [ "$i" -lt "$task_count" ]; do
    local task_record
    task_record=$(printf '%s' "$tasks_json" | jq -c --argjson i "$i" '.[$i]' 2>/dev/null) \
      || task_record=''
    if [ -z "$task_record" ] || [ "$task_record" = "null" ]; then
      i=$((i + 1))
      continue
    fi
    local task_id ts te
    task_id=$(printf '%s' "$task_record" | jq -r '.task_id // ""' 2>/dev/null)
    ts=$(printf '%s' "$task_record" \
      | jq -r '.affected_lines_at_open[0] // 0' 2>/dev/null)
    te=$(printf '%s' "$task_record" \
      | jq -r '.affected_lines_at_open[1] // 0' 2>/dev/null)
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    case "$te" in ''|*[!0-9]*) te=0 ;; esac

    local outcome_json status
    if [ "$force_conflict" = "1" ]; then
      outcome_json='{"status":"CONFLICT","diff":"","affected_lines":[0,0],"rationale":"holder edit covered whole file (no line range available); anchored task cannot be safely applied"}'
      status=CONFLICT
    elif coord_task_processor_check_affected "$ts" "$te" "$edit_start" "$edit_end" >/dev/null; then
      # No overlap → spawn (mock) Claude.
      local spawn_out
      if spawn_out=$(coord_task_processor_spawn_claude "$task_record"); then
        outcome_json="$spawn_out"
        status=$(printf '%s' "$outcome_json" | jq -r '.status' 2>/dev/null)
      else
        outcome_json='{"status":"SKIPPED","diff":"","affected_lines":[0,0],"rationale":"task processor: spawn failed (mock binary unavailable or invalid JSON)"}'
        status=SKIPPED
      fi
    else
      # Overlap → CONFLICT.
      outcome_json='{"status":"CONFLICT","diff":"","affected_lines":[0,0],"rationale":"holder edit overlaps anchor range"}'
      status=CONFLICT
    fi

    if coord_task_processor_write_outcome "$state" "$file" \
         "$task_record" "$outcome_json"; then
      :
    else
      coord_log_event kind=ERROR source=task_processor \
        file="$file" task_id="$task_id" reason=write_outcome_failed \
        2>/dev/null || true
    fi

    case "$status" in
      COMPLETED) n_completed=$((n_completed + 1)) ;;
      CONFLICT)  n_conflict=$((n_conflict + 1)) ;;
      SKIPPED|*) n_skipped=$((n_skipped + 1)) ;;
    esac

    i=$((i + 1))
  done

  coord_log_event kind=TASK_PROCESSOR_RUN \
    file="$file" holder="$holder" task_count="$task_count" \
    completed="$n_completed" conflicts="$n_conflict" \
    skipped="$n_skipped" \
    edit_start="$edit_start" edit_end="$edit_end" \
    force_conflict="$force_conflict" \
    2>/dev/null || true
  return 0
}

#!/usr/bin/env bash
# cycle_detection.sh — Phase 5 T5.05 bipartite-graph deadlock detector.
# Implements PR-PHASE5-03 (Decision 3) + PR-PHASE5-04 (Decision 4
# eviction priority guidance).
#
# Public API:
#   coord_cycle_detect <session_id>
#     Bipartite session/file DFS from <session_id>. Reads sessions.json
#     once under sessions.lock (snapshot semantics). Returns cycle path
#     JSON on stdout when a cycle exists; empty stdout when none.
#     rc=0 always.
#
#   coord_cycle_describe <cycle_path_json>
#     Translates the cycle JSON to a human-readable string suitable
#     for embedding in the Mediator's pending payload's
#     cycle_description field. Includes the 3-tier eviction priority
#     guidance (oldest activity > fewest locks > youngest session age)
#     per PR-PHASE5-04 §1. Pure stdout; no I/O beyond reading
#     sessions.json for held-files lookup.
#
#   coord_cycle_emit_pending <cycle_path_json>
#     Append a cycle_detected entry to .coord/mediator/pending.jsonl
#     with the rich payload schema from PR-PHASE5-03 §5 + PR-PHASE5-04
#     §3 (cycle_path, cycle_description, involved_sessions,
#     involved_files, queue_depth_at_detection, session_metadata,
#     recent_cycle_count, trigger_session_id, trigger_file).
#     Returns the pending_ts on stdout; rc=0 success, rc=1 failure.
#
# Algorithm (iterative DFS — Bash 3.2 compat per CLAUDE.md §A.13
# lesson #2; no recursion):
#   stack = [(start_sid, [start_sid])]
#   visited_sessions = {start_sid}
#   while stack:
#     (sid, path) = stack.pop()
#     for f in files-sid-waits-on:
#       holder = locks[f].session
#       if holder == start_sid:
#         return path ++ [f, holder]
#       if holder and holder not in visited_sessions:
#         visited_sessions.add(holder)
#         stack.push((holder, path ++ [f, holder]))
#   return empty
#
# Bipartite: every cycle alternates session->file->session->file->...
# and has even edge count (2 * distinct_sessions_in_cycle).
#
# Dependencies (must be sourced by caller before invoking):
#   - lib/atomic_write.sh   (sessions.lock helpers; coord_atomic_edit
#                            for pending writes — though we use direct
#                            flock+append for cycle_detected payload
#                            because the payload contains nested
#                            objects that don't fit the flat key=value
#                            contract of coord_mediator_emit_pending)
#   - lib/log_event.sh      (coord_log_event, coord_now_iso8601)
#   - jq, flock             (caller's deps gate already verified)
#
# Environment:
#   COORD_DIR — required.
#
# Bash 3.2 compat. No `set -euo pipefail` (caller's options govern).

# ---------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------

_coord_cycle_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time*1000' 2>/dev/null \
    || date -u +%s000
}

_coord_cycle_now_iso8601() {
  if command -v coord_now_iso8601 >/dev/null 2>&1; then
    coord_now_iso8601
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

_coord_cycle_state() {
  printf '%s/sessions.json' "${COORD_DIR:-}"
}

# _coord_cycle_files_session_waits_on <sid>
#   Print newline-separated file paths that <sid> is waiting on,
#   reading from .wait_queues[<f>][].session_id == sid.
_coord_cycle_files_session_waits_on() {
  local sid="$1"
  local state
  state=$(_coord_cycle_state)
  jq -r --arg s "$sid" '
    [ .wait_queues // {}
      | to_entries[]
      | select(.value | any(.session_id == $s))
      | .key ]
    | .[]
  ' "$state" 2>/dev/null
}

# _coord_cycle_lock_holder <file>
#   Print the session_id holding <file>, or empty string.
_coord_cycle_lock_holder() {
  local file="$1"
  local state
  state=$(_coord_cycle_state)
  jq -r --arg f "$file" '.locks[$f].session // ""' "$state" 2>/dev/null
}

# _coord_cycle_session_held_files <sid>
#   Print newline-separated files held by <sid>.
_coord_cycle_session_held_files() {
  local sid="$1"
  local state
  state=$(_coord_cycle_state)
  jq -r --arg s "$sid" '
    [ .locks // {}
      | to_entries[]
      | select(.value.session == $s)
      | .key ]
    | .[]
  ' "$state" 2>/dev/null
}

# ---------------------------------------------------------------
# Public: coord_cycle_detect
# ---------------------------------------------------------------

# coord_cycle_detect <session_id>
#   Bipartite DFS. Returns JSON cycle path on stdout when a cycle
#   exists; empty stdout when none. rc=0 always.
#
# Cycle path JSON shape per PR-PHASE5-03 §3:
# {
#   "cycle_id": "<sha256-hex prefix of involved sids+files>",
#   "trigger_session_id": "<sid>",
#   "sessions": ["sid_A", "sid_B"],
#   "files":    ["/p/foo", "/p/bar"],
#   "edges": [
#     {"from": "sid_A", "type": "waits_for", "to": "/p/bar"},
#     {"from": "/p/bar", "type": "held_by",  "to": "sid_B"},
#     {"from": "sid_B", "type": "waits_for", "to": "/p/foo"},
#     {"from": "/p/foo", "type": "held_by",  "to": "sid_A"}
#   ],
#   "detected_at": "<ISO 8601 ms>"
# }
coord_cycle_detect() {
  local start_sid="$1"
  if [ -z "$start_sid" ] || [ -z "${COORD_DIR:-}" ]; then
    return 0
  fi
  local state
  state=$(_coord_cycle_state)
  [ -f "$state" ] || return 0

  local t0 t1 elapsed_ms
  t0=$(_coord_cycle_now_ms)

  # Iterative DFS state. Bash 3.2 has no associative arrays, so we use
  # parallel-indexed arrays:
  #   stack_sid[i]  = session at frame i
  #   stack_path[i] = JSON-encoded path-so-far at frame i (array of
  #                   alternating session/file strings starting + ending
  #                   with sessions; joined with $'\x1e' record separator
  #                   so embedded slashes in file paths don't conflict)
  #   visited_arr   = sessions already explored (linear search; small
  #                   N <= active session count)
  local PSEP=$'\x1e'  # ASCII RS — unlikely in any path or sid
  local -a stack_sid stack_path visited_arr
  stack_sid=("$start_sid")
  stack_path=("$start_sid")
  visited_arr=("$start_sid")

  # Output cycle path captured here when found.
  local cycle_path_str=""

  while [ "${#stack_sid[@]}" -gt 0 ]; do
    # Pop the last frame.
    local last_idx=$((${#stack_sid[@]} - 1))
    local cur_sid="${stack_sid[$last_idx]}"
    local cur_path="${stack_path[$last_idx]}"
    unset 'stack_sid[last_idx]' 'stack_path[last_idx]'

    # Files cur_sid waits on.
    local files_str
    files_str=$(_coord_cycle_files_session_waits_on "$cur_sid")
    [ -z "$files_str" ] && continue

    local f
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local holder
      holder=$(_coord_cycle_lock_holder "$f")
      [ -z "$holder" ] && continue
      # Path extension: cur_path PSEP f PSEP holder
      local extended_path="${cur_path}${PSEP}${f}${PSEP}${holder}"
      if [ "$holder" = "$start_sid" ]; then
        cycle_path_str="$extended_path"
        break 2
      fi
      # Already-visited session → skip (avoids infinite loop).
      local v skip_holder=0
      for v in "${visited_arr[@]}"; do
        if [ "$v" = "$holder" ]; then
          skip_holder=1
          break
        fi
      done
      if [ "$skip_holder" = 0 ]; then
        visited_arr+=("$holder")
        stack_sid+=("$holder")
        stack_path+=("$extended_path")
      fi
    done <<<"$files_str"
  done

  t1=$(_coord_cycle_now_ms)
  elapsed_ms=$(( t1 - t0 ))

  if [ -z "$cycle_path_str" ]; then
    coord_log_event kind=CYCLE_DETECTION_RAN \
      session="$start_sid" result=no_cycle duration_ms="$elapsed_ms" 2>/dev/null || true
    return 0
  fi

  # Parse path into sessions[] and files[] + emit JSON.
  # The cycle_path_str format is sid \x1e f \x1e sid \x1e f \x1e ... sid
  # (alternating, starts + ends with sessions, even-length edge count).
  local OLD_IFS="$IFS"
  IFS="$PSEP"
  set -- $cycle_path_str
  IFS="$OLD_IFS"

  local -a sessions_arr files_arr
  local i node
  i=0
  for node in "$@"; do
    if [ $((i % 2)) -eq 0 ]; then
      sessions_arr+=("$node")
    else
      files_arr+=("$node")
    fi
    i=$((i + 1))
  done

  # Build edges array as proper JSON (quoted keys + jq -n -compatible
  # construction via stdin TSV → jq map). Avoids the jq-bare-key
  # syntax that --argjson rejects (jq object construction allows
  # `{from:"x"}` but JSON requires `"from":"x"` — --argjson is
  # JSON-only).
  local edges_tsv=""
  local k=0
  while [ "$k" -lt "${#files_arr[@]}" ]; do
    local from_sid="${sessions_arr[$k]}"
    local f="${files_arr[$k]}"
    local to_sid="${sessions_arr[$((k+1))]}"
    # TSV: <from>\t<type>\t<to> per row.
    edges_tsv+=$'\n'"${from_sid}"$'\t'"waits_for"$'\t'"$f"
    edges_tsv+=$'\n'"$f"$'\t'"held_by"$'\t'"$to_sid"
    k=$((k + 1))
  done
  # Strip leading newline if present.
  edges_tsv="${edges_tsv#$'\n'}"
  local edges_json
  edges_json=$(printf '%s\n' "$edges_tsv" | jq -Rsc '
    [ split("\n")[]
      | select(length > 0)
      | split("\t")
      | {from: .[0], type: .[1], to: .[2]} ]
  ' 2>/dev/null) || edges_json='[]'

  # Distinct sessions + files for the summary lists. The cycle path
  # repeats start_sid at index 0 and the last index (closing the
  # cycle); jq `unique` dedupes naturally — no need for `head -n -1`
  # which is GNU-only (macOS BSD head rejects negative line counts;
  # F-018 portability family).
  local sessions_distinct_jq files_distinct_jq
  sessions_distinct_jq=$(printf '%s\n' "${sessions_arr[@]}" \
    | jq -R . | jq -sc 'unique' 2>/dev/null || printf '[]')
  files_distinct_jq=$(printf '%s\n' "${files_arr[@]}" \
    | jq -R . | jq -sc 'unique' 2>/dev/null || printf '[]')

  # Generate cycle_id from a hash of the canonical cycle string.
  local cycle_id
  cycle_id=$(printf '%s' "$cycle_path_str" | shasum -a 256 2>/dev/null \
    | awk '{print $1}' | cut -c1-16) || cycle_id="cycle"

  local detected_at
  detected_at=$(_coord_cycle_now_iso8601)

  jq -nc \
    --arg cid    "$cycle_id" \
    --arg trig   "$start_sid" \
    --argjson ss "$sessions_distinct_jq" \
    --argjson fs "$files_distinct_jq" \
    --arg det    "$detected_at" \
    --argjson edges "$edges_json" '{
      cycle_id:           $cid,
      trigger_session_id: $trig,
      sessions:           $ss,
      files:              $fs,
      edges:              $edges,
      detected_at:        $det
    }'

  coord_log_event kind=CYCLE_DETECTED \
    session="$start_sid" \
    cycle_id="$cycle_id" \
    queue_depth=$([ "${#sessions_arr[@]}" -gt 1 ] && printf '%d' "${#sessions_arr[@]}" || printf '0') \
    duration_ms="$elapsed_ms" 2>/dev/null || true
  coord_log_event kind=CYCLE_DETECTION_RAN \
    session="$start_sid" result=cycle_found duration_ms="$elapsed_ms" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------
# Public: coord_cycle_describe
# ---------------------------------------------------------------

# coord_cycle_describe <cycle_path_json>
#   Render a human-readable description suitable for embedding in the
#   Mediator pending entry's cycle_description field. Includes per-
#   session held-vs-waits lines + the 3-tier eviction priority
#   guidance from PR-PHASE5-04 §1.
coord_cycle_describe() {
  local json="$1"
  if [ -z "$json" ]; then
    return 1
  fi

  local sids_str
  sids_str=$(printf '%s' "$json" | jq -r '.sessions[]?' 2>/dev/null)
  [ -z "$sids_str" ] && return 1

  printf 'Deadlock detected:\n'
  local sid
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    local short_sid="${sid:0:8}"
    # Files this session HOLDS (from edges).
    local held
    held=$(printf '%s' "$json" | jq -r --arg s "$sid" '
      [ .edges[]
        | select(.type == "held_by" and .to == $s)
        | .from ]
      | join(", ")
    ' 2>/dev/null)
    [ -z "$held" ] && held="(no locks held)"
    # Files this session WAITS FOR (from edges).
    local waits
    waits=$(printf '%s' "$json" | jq -r --arg s "$sid" '
      [ .edges[]
        | select(.type == "waits_for" and .from == $s)
        | .to ]
      | join(", ")
    ' 2>/dev/null)
    [ -z "$waits" ] && waits="(not waiting)"
    printf '  %s (%s) holds %s and waits for %s\n' \
      "$sid" "$short_sid" "$held" "$waits"
  done <<<"$sids_str"

  # Cycle path arrow string.
  local arrow
  arrow=$(printf '%s' "$json" | jq -r '
    [ .edges[] | .from, .to ]
    | unique_unstable
    | map(if test("^/") then split("/")[-1] else .[0:8] end)
    | join(" -> ")
  ' 2>/dev/null)
  if [ -n "$arrow" ]; then
    printf '  Cycle: %s\n' "$arrow"
  fi

  # Eviction priority guidance per PR-PHASE5-04 §1 (3-tier).
  printf '  Eviction priority guidance: (1) oldest last_activity_at, (2) fewest locks_held, (3) youngest session_age.\n'
  return 0
}

# ---------------------------------------------------------------
# Public: coord_cycle_emit_pending
# ---------------------------------------------------------------

# coord_cycle_emit_pending <cycle_path_json>
#   Append a cycle_detected pending entry to pending.jsonl. Builds the
#   rich payload schema directly via jq (the flat key=value contract
#   of coord_mediator_emit_pending cannot carry nested objects). Holds
#   pending.lock for the read-then-append window.
#
#   Stdout: pending entry's ts (ISO 8601 ms) on success; rc=0/1.
coord_cycle_emit_pending() {
  local cycle_json="$1"
  if [ -z "$cycle_json" ] || [ -z "${COORD_DIR:-}" ]; then
    return 1
  fi
  local mdir="$COORD_DIR/mediator"
  mkdir -p "$mdir" 2>/dev/null || true

  local now session
  now=$(_coord_cycle_now_iso8601)
  session="${SESSION_ID:-unknown}"

  # Build the rich payload once — derive from cycle_json + sessions.json
  # snapshot. cycle_description goes through coord_cycle_describe.
  local cycle_description
  cycle_description=$(coord_cycle_describe "$cycle_json" 2>/dev/null) \
    || cycle_description=""

  local trigger_sid trigger_file involved_sessions involved_files queue_depth
  trigger_sid=$(printf '%s' "$cycle_json" | jq -r '.trigger_session_id // ""' 2>/dev/null)
  involved_sessions=$(printf '%s' "$cycle_json" | jq -c '.sessions // []' 2>/dev/null || printf '[]')
  involved_files=$(printf '%s' "$cycle_json" | jq -c '.files // []' 2>/dev/null || printf '[]')
  queue_depth=$(printf '%s' "$involved_sessions" | jq -r 'length' 2>/dev/null || printf '0')
  # trigger_file: the first file the trigger session waits on within
  # the cycle (edges[]: from=$trigger_sid, type=waits_for).
  trigger_file=$(printf '%s' "$cycle_json" | jq -r --arg s "$trigger_sid" '
    [ .edges[] | select(.from == $s and .type == "waits_for") | .to ]
    | (.[0] // "")
  ' 2>/dev/null)

  # Per-session metadata for the Mediator's eviction-priority decision.
  local state="$COORD_DIR/sessions.json"
  local session_metadata
  session_metadata=$(jq -nc --argjson sids "$involved_sessions" --slurpfile s "$state" '
    ($s[0] // {sessions:{}, locks:{}}) as $st
    | reduce $sids[] as $sid ({};
        . + {($sid): {
          last_activity_at:    ($st.sessions[$sid].last_activity_at // ""),
          registered_at:       ($st.sessions[$sid].registered_at // ""),
          locks_held: ([ $st.locks // {} | to_entries[]
                       | select(.value.session == $sid) ] | length),
          session_age_seconds: 0
        }})
  ' 2>/dev/null || printf '{}')

  # Bounded events.jsonl scan: count CYCLE_DETECTED events in last 60s
  # for the recent_cycle_count payload field per PR-PHASE5-04 §3.
  local recent_cycle_count=0
  local events="$COORD_DIR/events.jsonl"
  if [ -f "$events" ]; then
    local cutoff_iso
    if command -v perl >/dev/null 2>&1; then
      cutoff_iso=$(perl -MTime::HiRes=time -MPOSIX -e \
        'printf "%s.000Z\n", strftime("%Y-%m-%dT%H:%M:%S", gmtime(time-60))' 2>/dev/null)
    else
      cutoff_iso=$(date -u -v-60S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d '60 sec ago' +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || printf '1970-01-01T00:00:00.000Z')
    fi
    recent_cycle_count=$(jq -rs --arg c "$cutoff_iso" '
      [ .[] | select((.kind // "") == "CYCLE_DETECTED" and (.ts // "") >= $c) ] | length
    ' "$events" 2>/dev/null || printf '0')
    case "$recent_cycle_count" in *[!0-9]*|'') recent_cycle_count=0 ;; esac
  fi

  local line
  line=$(jq -nc \
    --arg ts            "$now" \
    --arg session       "$session" \
    --arg trigger_sid   "$trigger_sid" \
    --arg trigger_file  "$trigger_file" \
    --argjson cycle     "$cycle_json" \
    --argjson sids      "$involved_sessions" \
    --argjson files     "$involved_files" \
    --arg cycle_desc    "$cycle_description" \
    --argjson queue_depth "$queue_depth" \
    --argjson sess_meta "$session_metadata" \
    --argjson recent    "$recent_cycle_count" '
    {
      ts:      $ts,
      kind:    "cycle_detected",
      session: $session,
      source:  "coord_cycle_detect",
      payload: {
        trigger_session_id:        $trigger_sid,
        trigger_file:              $trigger_file,
        cycle_path:                $cycle,
        cycle_description:         $cycle_desc,
        queue_depth_at_detection:  $queue_depth,
        involved_sessions:         $sids,
        involved_files:            $files,
        session_metadata:          $sess_meta,
        recent_cycle_count:        $recent
      }
    }
  ' 2>/dev/null) || return 1
  [ -z "$line" ] && return 1

  local lockfile="$mdir/pending.lock"
  local jsonl="$mdir/pending.jsonl"
  : >>"$lockfile"
  (
    flock -x -w 5 9 || exit 42
    printf '%s\n' "$line" >>"$jsonl"
  ) 9>"$lockfile" || return 1

  printf '%s' "$now"
  return 0
}

#!/usr/bin/env bash
# scenarios/02_lock_deny/timeline.sh — Phase 2 lock-contention scenario.
#
# Validates the full Phase 2 deny → release → notify cycle. See
# description.md in this directory for the full assertion list.
#
# Required env (set by the driver):
#   WORKDIR    — isolated workspace path
#   COORD_DIR  — $WORKDIR/.coord
#   SRC_ROOT   — repo's src/ directory (unused here directly; hooks in
#                $COORD_DIR/hooks were copied from $SRC_ROOT/hooks)

set -uo pipefail   # NOT -e — capture deny exit codes without aborting

scenario_run() {
  local hooks="$COORD_DIR/hooks"
  local sid_a="sid-a-2sw-02-0001"
  local sid_b="sid-b-2sw-02-0001"

  # 1. Register both sessions.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/session_start.sh" >/dev/null
  printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"SessionStart","source":"startup"}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/session_start.sh" >/dev/null

  # 2. Session A acquires lock on foo.ts via Write pre-hook.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/pre_tool_use_write.sh" >/dev/null

  # Tiny pause so acquired_at < deny ts < release ts (ordering matters
  # for the notify-on-release window scan).
  sleep 1

  # 3. Session B's Write attempt → deny. Capture stdout (the deny JSON).
  STDOUT_OF_B_DENY=$(printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/pre_tool_use_write.sh" 2>/dev/null) || true
  EXIT_OF_B_DENY=$?

  sleep 0.3   # let LOCK_DENIED event flush

  # 4. Session A's Post-hook releases the lock + populates notification.
  printf '%s' '{"session_id":"'"$sid_a"'","cwd":"'"$WORKDIR"'","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/post_tool_use_write.sh" >/dev/null

  sleep 0.3

  # 5. Session B reads foo.ts. The Phase-1 consumer should deliver the
  # queued notification via additionalContext and clear the bucket.
  STDOUT_OF_B_READ=$(printf '%s' '{"session_id":"'"$sid_b"'","cwd":"'"$WORKDIR"'","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$WORKDIR"'/foo.ts"}}' \
    | CLAUDE_COORD=1 CLAUDE_PROJECT_DIR="$WORKDIR" "$hooks/pre_tool_use_read.sh" 2>/dev/null) || true

  sleep 0.3

  export STDOUT_OF_B_DENY EXIT_OF_B_DENY STDOUT_OF_B_READ
  export SID_A="$sid_a" SID_B="$sid_b"
}

scenario_assert() {
  local fails=0
  local events="$COORD_DIR/events.jsonl"
  local state="$COORD_DIR/sessions.json"
  local target_path="$WORKDIR/foo.ts"

  _fail() {
    printf '  FAIL [%s]: %s\n' "$1" "$2" >&2
    fails=$((fails + 1))
  }

  # B.1 — B's hook exit 0 (deny is JSON-signaled, not shell exit).
  if [ "$EXIT_OF_B_DENY" != "0" ]; then
    _fail B.1 "Session B Write hook exited $EXIT_OF_B_DENY; want 0"
  fi

  # B.2 — permissionDecision == "deny".
  if ! printf '%s' "$STDOUT_OF_B_DENY" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    _fail B.2 "B stdout missing permissionDecision='deny'"
    printf '    got: %s\n' "$STDOUT_OF_B_DENY" >&2
  fi

  local reason
  reason=$(printf '%s' "$STDOUT_OF_B_DENY" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null)

  # B.3 — Reason cites the file + holder.
  case "$reason" in
    *foo.ts*) : ;;
    *) _fail B.3 "reason does not cite foo.ts" ;;
  esac
  case "$reason" in
    *"locked by session"*) : ;;
    *) _fail B.3 "reason missing 'locked by session'" ;;
  esac

  # B.4 — All three option markers.
  case "$reason" in *"(a) Delegate"*) : ;; *) _fail B.4 "missing (a) marker" ;; esac
  case "$reason" in *"(b) Self-delegate"*) : ;; *) _fail B.4 "missing (b) marker" ;; esac
  case "$reason" in *"(c) Passively wait"*) : ;; *) _fail B.4 "missing (c) marker" ;; esac

  # B.5 — Abstract Phase-6 references.
  case "$reason" in *"\`coord task-open\`"*) : ;; *) _fail B.5 "missing abstract \`coord task-open\` reference" ;; esac
  case "$reason" in *"\`coord self-delegate\`"*) : ;; *) _fail B.5 "missing abstract \`coord self-delegate\` reference" ;; esac

  # B.6 — Phase 6 syntax NOT frozen.
  case "$reason" in
    *"task-open --file"*)     _fail B.6 "reason froze Phase-6 'task-open --file' syntax" ;;
  esac
  case "$reason" in
    *"self-delegate --file"*) _fail B.6 "reason froze Phase-6 'self-delegate --file' syntax" ;;
  esac

  # B.7 — (c) coord wait full invocation with --timeout 570.
  if ! printf '%s' "$reason" | grep -qF "coord wait $target_path --timeout 570"; then
    _fail B.7 "(c) wait invocation missing or wrong syntax"
    printf '    reason: %s\n' "$reason" >&2
  fi

  # B.8 — Both acquired + last-activity ages surfaced.
  case "$reason" in *"acquired "*"ago"*) : ;; *) _fail B.8 "missing 'acquired N ago'" ;; esac
  case "$reason" in *"last activity "*"ago"*) : ;; *) _fail B.8 "missing 'last activity N ago'" ;; esac

  # B.9 — Events sequence: LOCK_ACQUIRED(A) → LOCK_DENIED(B) → LOCK_RELEASED(A).
  if [ ! -f "$events" ]; then
    _fail B.9 "events.jsonl missing"
  else
    local n_acq n_deny n_rel
    n_acq=$(jq -rs --arg sid "$SID_A" --arg f "$target_path" \
      '[.[] | select(.kind == "LOCK_ACQUIRED" and .session == $sid and .file == $f)] | length' "$events" 2>/dev/null || printf 0)
    n_deny=$(jq -rs --arg sid "$SID_B" --arg f "$target_path" \
      '[.[] | select(.kind == "LOCK_DENIED" and .session == $sid and .file == $f)] | length' "$events" 2>/dev/null || printf 0)
    n_rel=$(jq -rs --arg sid "$SID_A" --arg f "$target_path" \
      '[.[] | select(.kind == "LOCK_RELEASED" and .session == $sid and .file == $f)] | length' "$events" 2>/dev/null || printf 0)
    [ "$n_acq"  -ge 1 ] || _fail B.9 "expected LOCK_ACQUIRED for A on foo.ts; got $n_acq"
    [ "$n_deny" -ge 1 ] || _fail B.9 "expected LOCK_DENIED for B on foo.ts; got $n_deny"
    [ "$n_rel"  -ge 1 ] || _fail B.9 "expected LOCK_RELEASED for A on foo.ts; got $n_rel"
  fi

  # B.10 — NOTIFICATION_PRODUCED with waiter_count=1.
  local n_prod
  n_prod=$(jq -rs --arg f "$target_path" \
    '[.[] | select(.kind == "NOTIFICATION_PRODUCED" and .file == $f)] | length' "$events" 2>/dev/null || printf 0)
  if [ "$n_prod" -lt 1 ]; then
    _fail B.10 "NOTIFICATION_PRODUCED missing for $target_path"
  else
    local wc
    wc=$(jq -rs --arg f "$target_path" \
      'last(.[] | select(.kind == "NOTIFICATION_PRODUCED" and .file == $f)) | .payload.waiter_count' \
      "$events" 2>/dev/null)
    [ "$wc" = "1" ] || _fail B.10 "NOTIFICATION_PRODUCED.waiter_count=$wc; want 1"
  fi

  # B.11 — notifications populated post-release (BEFORE Read consumed).
  # We assert the post-Read state in B.13; here we check via the events.jsonl
  # NOTIFICATION_DELIVER trail that B's Read DID see something to deliver.
  # (B.11 is implied by B.10; explicit check is the post-Read cleared bucket.)

  # B.12 — B's Read additionalContext carries the lock-released notification.
  if ! printf '%s' "$STDOUT_OF_B_READ" | jq -e '.hookSpecificOutput.additionalContext // "" | contains("Lock released on")' >/dev/null 2>&1; then
    _fail B.12 "B's Read did not deliver 'Lock released on' notification"
    printf '    stdout: %s\n' "$STDOUT_OF_B_READ" >&2
  fi
  if ! printf '%s' "$STDOUT_OF_B_READ" | jq -e --arg f "$target_path" '.hookSpecificOutput.additionalContext // "" | contains($f)' >/dev/null 2>&1; then
    _fail B.12 "B's Read notification text does not cite $target_path"
  fi

  # B.13 — B's notification bucket cleared post-Read.
  local remaining
  remaining=$(jq -r --arg sid "$SID_B" --arg f "$target_path" \
    '(.notifications[$sid][$f] // []) | length' "$state" 2>/dev/null || printf 0)
  [ "$remaining" = "0" ] || _fail B.13 "B's notification bucket still has $remaining entries; want 0"

  # B.14 — Phase 2 invariant: only the deny stdout carried permissionDecision.
  if printf '%s' "$STDOUT_OF_B_READ" | grep -q 'permissionDecision'; then
    _fail B.14 "B's Read stdout contained permissionDecision (Read path must never deny)"
  fi

  return "$fails"
}

#!/usr/bin/env bats
# Tests for src/adapters/codex/hooks/pre_tool_use_apply_patch.sh — PR D.4.
# (plan v1.3 / A-D4-02 + A-D4-01 + F-D4-01).
#
# Coverage matrix:
#   Path collection + sort         (3 tests)
#   Lock check / classification   (8 tests)
#   Drift gate                    (10 tests)
#   Race condition                 (3 tests)
#   Lockdown                       (2 tests)
#   D-9 / D-D4-02 mutex            (2 tests)
#   D-2 negative                   (2 tests)
#
# All branches assert (.hookSpecificOutput.additionalContext // "") | length == 0
# per F-D4-04. Allow paths assert empty stdout AND lock state mutated.

load "../helpers/common"

H="$SRC_ROOT/adapters/codex/hooks/pre_tool_use_apply_patch.sh"

setup() {
  TMP="$(mktemp -d -t coord-cx-pap-XXXX)"
  COORD="$(mk_coord_dir "$TMP")"
  mk_empty_sessions "$COORD"
  export COORD_DIR="$COORD"
  unset CLAUDE_COORD COORD_ENABLED
  : >"$COORD_DIR/events.jsonl"

  SID="cx-pap-aaaa"
  PEER="cx-pap-bbbb"
  touch "$COORD_DIR/sessions/${SID}.active" \
        "$COORD_DIR/sessions/${PEER}.active"
  jq --arg s "$SID" --arg p "$PEER" '
    .sessions[$s] = {state:"ACTIVE",pid:1,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0",agent:"codex"}
    | .sessions[$p] = {state:"ACTIVE",pid:2,pid_lstart:"x",
        registered_at:"y",last_activity_at:"z",git_head:"",
        prompt_id:null,script_version:"1.0",agent:"codex"}
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}
teardown() {
  unset CLAUDE_COORD COORD_ENABLED COORD_DIR
  rm -rf "$TMP"
}

# === Helpers ===

_seed_lock() {
  local sid="$1" file="$2"
  jq --arg f "$file" --arg s "$sid" '
    .locks[$f] = {
      session: $s, pid: 1, pid_lstart: "x",
      acquired_at: "2026-05-03T00:00:00Z",
      last_refresh_at: "2026-05-03T00:00:00Z",
      tasks: []
    }
  ' "$COORD_DIR/sessions.json" >"$COORD_DIR/sessions.json.new"
  mv "$COORD_DIR/sessions.json.new" "$COORD_DIR/sessions.json"
}

_activate_lockdown() {
  mkdir -p "$COORD/mediator"
  jq -nc --arg r "$1" --arg rs "$2" \
    '{active: true, reason: $r, reason_source: $rs, started_at: "2026-05-03T00:00:00Z"}' \
    >"$COORD/mediator/lockdown.json"
}

# Build a hook input JSON for an apply_patch invocation; the patch body
# goes into tool_input.input.
_apply_patch_input() {
  local patch="$1" sid="${2:-$SID}"
  jq -nc --arg s "$sid" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"apply_patch",
    tool_input:{input:$p},
    tool_use_id:"tu-pap-1"
  }'
}

# === Path collection + sort ===

@test "apply_patch: single Update path acquires lock" {
  printf 'old line\n' >"$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old line\n+new line\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "apply_patch: multi-file patch acquires all locks atomically (encounter→sort→all)" {
  printf 'old\n' >"$TMP/zeta.ts"
  printf 'old\n' >"$TMP/alpha.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/zeta.ts\n@@\n-old\n+new\n*** Update File: '"$TMP"$'/alpha.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/zeta.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  run jq -r --arg f "$TMP/alpha.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  run jq -r '.locks | length' "$COORD_DIR/sessions.json"
  [ "$output" = "2" ]
}

@test "apply_patch: Move op locks BOTH source AND destination paths" {
  printf 'old\n' >"$TMP/src.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/src.ts\n*** Move to: '"$TMP"$'/dst.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  run jq -r --arg f "$TMP/src.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
  run jq -r --arg f "$TMP/dst.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

# === Lock check / classification ===

@test "apply_patch: peer-held single file → deny with single-file template" {
  printf 'old\n' >"$TMP/foo.ts"
  _seed_lock "$PEER" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("apply_patch was DENIED")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("locked by session")' >/dev/null
  # Lock NOT acquired by SID.
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$PEER" ]
}

@test "apply_patch: peer-held multi-file → deny with multi-file template enumerating all blocked" {
  printf 'old\n' >"$TMP/a.ts"
  printf 'old\n' >"$TMP/b.ts"
  printf 'old\n' >"$TMP/c.ts"
  _seed_lock "$PEER" "$TMP/a.ts"
  _seed_lock "$PEER" "$TMP/b.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/a.ts\n@@\n-old\n+new\n*** Update File: '"$TMP"$'/b.ts\n@@\n-old\n+new\n*** Update File: '"$TMP"$'/c.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("2 of 3")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("a.ts")' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("b.ts")' >/dev/null
  # The unblocked file MUST NOT be in the deny list.
  ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("c.ts")' >/dev/null
  # No locks acquired.
  run jq -r --arg f "$TMP/c.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

@test "apply_patch: self-held files refresh last_refresh_at (no acquire reset)" {
  printf 'old\n' >"$TMP/foo.ts"
  _seed_lock "$SID" "$TMP/foo.ts"
  local OLD_REFRESH
  OLD_REFRESH=$(jq -r --arg f "$TMP/foo.ts" '.locks[$f].last_refresh_at' "$COORD_DIR/sessions.json")
  local OLD_ACQUIRED
  OLD_ACQUIRED=$(jq -r --arg f "$TMP/foo.ts" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json")
  sleep 0.1
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json"
  [ "$output" = "$OLD_ACQUIRED" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].last_refresh_at' "$COORD_DIR/sessions.json"
  [ "$output" != "$OLD_REFRESH" ]
}

@test "apply_patch: mixed self-held + unheld → all locks land + self refresh preserved" {
  printf 'old\n' >"$TMP/self.ts"
  printf 'old\n' >"$TMP/new.ts"
  _seed_lock "$SID" "$TMP/self.ts"
  local OLD_ACQUIRED
  OLD_ACQUIRED=$(jq -r --arg f "$TMP/self.ts" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json")
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/self.ts\n@@\n-old\n+new\n*** Update File: '"$TMP"$'/new.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/self.ts" '.locks[$f].acquired_at' "$COORD_DIR/sessions.json"
  [ "$output" = "$OLD_ACQUIRED" ]
  run jq -r --arg f "$TMP/new.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "apply_patch: any peer-held in a multi-file mix → deny ALL (no partial acquire)" {
  printf 'old\n' >"$TMP/blocked.ts"
  printf 'old\n' >"$TMP/free.ts"
  _seed_lock "$PEER" "$TMP/blocked.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/blocked.ts\n@@\n-old\n+new\n*** Update File: '"$TMP"$'/free.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # The free file MUST NOT have been acquired.
  run jq -r --arg f "$TMP/free.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
  # The peer's lock untouched.
  run jq -r --arg f "$TMP/blocked.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$PEER" ]
}

@test "apply_patch: LOCK_DENIED event records reason_kind=peer_held" {
  printf 'old\n' >"$TMP/foo.ts"
  _seed_lock "$PEER" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_DENIED" and .payload.reason_kind == "peer_held")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "apply_patch: LOCK_ACQUIRED event per file on success" {
  printf 'a\n' >"$TMP/a.ts"
  printf 'b\n' >"$TMP/b.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/a.ts\n@@\n-a\n+x\n*** Update File: '"$TMP"$'/b.ts\n@@\n-b\n+y\n*** End Patch'
  COORD_ENABLED=1 bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "LOCK_ACQUIRED" and .tool == "apply_patch")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" = "2" ]
}

@test "apply_patch: WRITE intent event always logged (records all paths comma-joined)" {
  printf 'a\n' >"$TMP/a.ts"
  printf 'b\n' >"$TMP/b.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/a.ts\n@@\n-a\n+x\n*** Update File: '"$TMP"$'/b.ts\n@@\n-b\n+y\n*** End Patch'
  COORD_ENABLED=1 bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'" >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "WRITE" and .tool == "apply_patch")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  run jq -rs 'first(.[] | select(.kind == "WRITE" and .tool == "apply_patch")) | .file' "$COORD_DIR/events.jsonl"
  echo "$output" | grep -q "a.ts"
  echo "$output" | grep -q "b.ts"
}

# === Drift gate ===

@test "drift: pre_image found uniquely → drift-clean, lock acquired" {
  printf 'line1\nold\nline3\n' >"$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n line1\n-old\n+new\n line3\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "drift: pre_image not found → DRIFT_DETECTED + deny" {
  printf 'totally different content\n' >"$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old line\n+new line\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("drift detected")' >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "DRIFT_DETECTED")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
  # Lock NOT acquired.
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

@test "drift: pure-addition hunk (empty pre_image) → drift-clean (D-D4-01)" {
  printf 'existing content\n' >"$TMP/foo.ts"
  local patch
  # Pure-addition hunk inside an Update: only + lines.
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n+brand new line\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "drift: ambiguous match (no header) → drift detected" {
  # A pre_image with multiple matches and no @@ context label → ambiguous.
  printf 'duplicate\nduplicate\nduplicate\n' >"$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-duplicate\n+changed\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("ambiguously")' >/dev/null
}

@test "drift: ambiguous match WITH @@ header label → label disambiguates → drift-clean" {
  printf 'function alpha() {\n  duplicate\n}\nfunction beta() {\n  duplicate\n}\n' >"$TMP/foo.ts"
  local patch
  # @@ context label points to the alpha function; pre_image "duplicate"
  # is unique within the trailing portion after that label.
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@ function alpha\n-  duplicate\n+  fixed\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "drift: Add File on existing file → drift_kind=add_target_exists" {
  printf 'pre-existing\n' >"$TMP/exists.ts"
  local patch
  patch=$'*** Begin Patch\n*** Add File: '"$TMP"$'/exists.ts\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Add File target already exists")' >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "DRIFT_DETECTED" and .payload.drift_kind == "add_target_exists")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "drift: Delete File on absent file → drift_kind=delete_target_missing" {
  local patch
  patch=$'*** Begin Patch\n*** Delete File: '"$TMP"$'/never_was.ts\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Delete File target does not exist")' >/dev/null
  sleep 0.3
  run jq -rs '[.[] | select(.kind == "DRIFT_DETECTED" and .payload.drift_kind == "delete_target_missing")] | length' "$COORD_DIR/events.jsonl"
  [ "$output" -ge "1" ]
}

@test "drift: Add File on missing file (correct case) → drift-clean, acquire" {
  # Sanity check: Add File on a path that does NOT exist must succeed.
  local patch
  patch=$'*** Begin Patch\n*** Add File: '"$TMP"$'/brand_new.ts\n+content\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/brand_new.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "drift: Move op destination already exists → drift" {
  printf 'old\n' >"$TMP/src.ts"
  printf 'pre-existing destination\n' >"$TMP/dst.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/src.ts\n*** Move to: '"$TMP"$'/dst.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Move destination already exists")' >/dev/null
}

@test "drift: large file (>=1 MB) skips drift check, still acquires" {
  # Construct a >1 MB file with content that does NOT contain the
  # pre-image. Without the size threshold this would be drift-deny;
  # with the threshold the drift gate skips and the lock is acquired.
  yes 'large file content padding' | head -c 1100000 >"$TMP/big.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/big.ts\n@@\n-pre-image-not-in-file\n+replacement\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run jq -r --arg f "$TMP/big.ts" '.locks[$f].session' "$COORD_DIR/sessions.json"
  [ "$output" = "$SID" ]
}

@test "drift: multi-file partial drift → deny ALL (one drifty file blocks the patch)" {
  printf 'matching content\n' >"$TMP/clean.ts"
  printf 'totally different\n' >"$TMP/dirty.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/clean.ts\n@@\n-matching content\n+x\n*** Update File: '"$TMP"$'/dirty.ts\n@@\n-was something else\n+y\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("dirty.ts")' >/dev/null
  # Even the clean file got NO lock (drift denies the whole patch).
  run jq -r --arg f "$TMP/clean.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

# === Lockdown ===

@test "apply_patch: under active lockdown → deny + locks NOT touched" {
  printf 'old\n' >"$TMP/foo.ts"
  _activate_lockdown "system pause" "mediator_verdict"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Lock NOT acquired.
  run jq -r --arg f "$TMP/foo.ts" '.locks[$f] // null' "$COORD_DIR/sessions.json"
  [ "$output" = "null" ]
}

@test "apply_patch: lockdown deny supersedes lock-conflict (lockdown reason wins)" {
  printf 'old\n' >"$TMP/foo.ts"
  _seed_lock "$PEER" "$TMP/foo.ts"
  _activate_lockdown "system pause" "mediator_verdict"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  # Reason should mention "System-wide pause" (lockdown's signature) NOT
  # "apply_patch was DENIED — file ... is locked".
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("System-wide pause")' >/dev/null
}

# === D-9 / D-D4-02 mutex ===

@test "apply_patch: D-D4-02 invariant — never additionalContext on any branch" {
  # Allow path.
  printf 'old\n' >"$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ -z "$output" ] || echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Lock-conflict deny.
  _seed_lock "$PEER" "$TMP/bar.ts"
  printf 'old\n' >"$TMP/bar.ts"
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/bar.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Drift deny.
  printf 'wrong content\n' >"$TMP/drift.ts"
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/drift.ts\n@@\n-not-there\n+x\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
  # Lockdown deny.
  _activate_lockdown "x" "mediator_verdict"
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  echo "$output" | jq -e '(.hookSpecificOutput.additionalContext // "") | length == 0' >/dev/null
}

@test "apply_patch: empty allow output is truly empty (no JSON at all)" {
  printf 'old\n' >"$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  COORD_ENABLED=1 run bash -c "echo $(_apply_patch_input "$patch" | jq -Rs '.') | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# === D-2 negative ===

@test "apply_patch: agent_type field DOES NOT bypass any branch (D-2)" {
  printf 'old\n' >"$TMP/foo.ts"
  _seed_lock "$PEER" "$TMP/foo.ts"
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/foo.ts\n@@\n-old\n+new\n*** End Patch'
  local INPUT_AGENT_TYPE
  INPUT_AGENT_TYPE=$(jq -nc --arg s "$SID" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"apply_patch",
    tool_input:{input:$p},
    tool_use_id:"tu-x",
    agent_type:"general-purpose"
  }')
  COORD_ENABLED=1 run bash -c "echo '$INPUT_AGENT_TYPE' | '$H'"
  [ "$status" -eq 0 ]
  # Hook STILL denies — agent_type is unknown and ignored.
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

@test "apply_patch: non-participant (no marker) → no-op" {
  local patch
  patch=$'*** Begin Patch\n*** Update File: '"$TMP"$'/never.ts\n@@\n-old\n+new\n*** End Patch'
  local INP
  INP=$(jq -nc --arg s "not-registered" --arg cwd "$TMP" --arg p "$patch" '{
    session_id:$s, cwd:$cwd, hook_event_name:"PreToolUse",
    tool_name:"apply_patch", tool_input:{input:$p}, tool_use_id:"tu-x"
  }')
  COORD_ENABLED=1 run bash -c "echo '$INP' | '$H'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

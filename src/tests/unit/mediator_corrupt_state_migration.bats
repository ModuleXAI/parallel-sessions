#!/usr/bin/env bats
# Tests for install.sh legacy pending.json migration (Phase 3 / T3.07 /
# PR-PHASE3-03 / Decision 4).
#
# Pre-Phase-3 installs used a single-file pending.json for corrupt_state.
# T3.07 install.sh migrates any active entry forward into the unified
# pending.jsonl queue, then deletes the legacy file. Idempotent.

load "../helpers/common"

INSTALL="$SRC_ROOT/install.sh"

setup() {
  TMP="$(mktemp -d -t coord-cs-mig-XXXX)"
  # Initialize a minimal git repo so install.sh can find the root.
  ( cd "$TMP" && git init -q && git config user.email a@b && git config user.name x \
    && git commit --allow-empty -m init -q ) >/dev/null 2>&1
  # Pre-stage a fake .coord/ with legacy pending.json so install --repair
  # exercises the migration path.
  mkdir -p "$TMP/.coord/mediator"
}

teardown() {
  rm -rf "$TMP"
}

@test "migration: legacy pending.json with active corrupt_state entry → migrated to pending.jsonl" {
  jq -nc --arg ts "2026-04-25T00:00:00Z" --arg file "/some/state.json" \
    '{kind:"corrupt_state", ts:$ts, file:$file, archived_to:"/some/archive.json"}' \
    >"$TMP/.coord/mediator/pending.json"
  # Run install --yes --repair against the prepared dir.
  ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$INSTALL" --yes --repair >/dev/null 2>&1 )
  # Legacy file gone.
  [ ! -f "$TMP/.coord/mediator/pending.json" ]
  # New JSONL has the migrated entry.
  run jq -rs '[.[] | select(.kind == "corrupt_state")] | length' "$TMP/.coord/mediator/pending.jsonl"
  [ "$output" -ge 1 ]
  run jq -rs '[.[] | select(.kind == "corrupt_state")][-1].source' "$TMP/.coord/mediator/pending.jsonl"
  [ "$output" = "install_migration" ]
  # Legacy fields land under .payload.
  run jq -rs '[.[] | select(.kind == "corrupt_state")][-1].payload.archived_to' "$TMP/.coord/mediator/pending.jsonl"
  [ "$output" = "/some/archive.json" ]
}

@test "migration: unparseable legacy pending.json is archived forensically + removed" {
  printf 'this is not json {{{\n' >"$TMP/.coord/mediator/pending.json"
  ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$INSTALL" --yes --repair >/dev/null 2>&1 )
  # Original is gone.
  [ ! -f "$TMP/.coord/mediator/pending.json" ]
  # A forensic copy exists with .legacy suffix.
  run bash -c "ls $TMP/.coord/mediator/pending.json.legacy.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "1" ]
  # JSONL is empty (no migration of garbage).
  run jq -rs '[.[] | select(.kind == "corrupt_state")] | length' "$TMP/.coord/mediator/pending.jsonl"
  [ "$output" = "0" ]
}

@test "migration: idempotent — second --repair after migration does not re-create legacy file" {
  jq -nc --arg ts "2026-04-25T00:00:00Z" '{kind:"corrupt_state", ts:$ts}' \
    >"$TMP/.coord/mediator/pending.json"
  ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$INSTALL" --yes --repair >/dev/null 2>&1 )
  ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$INSTALL" --yes --repair >/dev/null 2>&1 )
  [ ! -f "$TMP/.coord/mediator/pending.json" ]
  # Migration ran ONCE — JSONL has one corrupt_state entry, not two.
  run jq -rs '[.[] | select(.kind == "corrupt_state")] | length' "$TMP/.coord/mediator/pending.jsonl"
  [ "$output" = "1" ]
}

@test "migration: install with NO legacy file is a clean no-op" {
  # No pending.json present.
  ( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$INSTALL" --yes --repair >/dev/null 2>&1 )
  [ -f "$TMP/.coord/mediator/pending.jsonl" ]
  # Empty JSONL.
  run wc -l <"$TMP/.coord/mediator/pending.jsonl"
  [ "$output" -eq 0 ]
}

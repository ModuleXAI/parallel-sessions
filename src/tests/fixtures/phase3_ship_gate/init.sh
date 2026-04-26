#!/usr/bin/env bash
# init.sh — create an isolated workspace for phase3_ship_gate fixtures.
#
# Usage:
#   . init.sh                 # sourced by driver; sets WORKDIR + COORD_DIR
#
# Side effects (idempotent within a single scenario run):
#   - mktemp -d → WORKDIR
#   - git init at WORKDIR + initial commit (so install.sh resolves root)
#   - install.sh --yes --repair against WORKDIR (creates full .coord/
#     layout including watchdog/, mediator/, verdict/, lockdown_archive/)
#   - $WORKDIR/bin/claude — fake claude binary that scenarios can
#     re-write to script Mediator output
#   - PATH prepended with $WORKDIR/bin so coord_mediator_spawn picks it up
#
# Caller is responsible for cleanup via `rm -rf "$WORKDIR"` when done.

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"

coord_fixture_init() {
  WORKDIR="$(mktemp -d -t coord-fixture-p3sg-XXXX)"

  (
    cd "$WORKDIR"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'placeholder for fixture init commit\n' >.fixture-seed
    git add .fixture-seed
    git commit -q -m "fixture: initial seed" 2>/dev/null
  )

  ( cd "$WORKDIR" && "$SRC_ROOT/install.sh" --yes --repair >/dev/null )

  # Default fake claude binary: returns is_error=false + writes a benign
  # advice verdict. Scenarios overwrite this to script different behaviors.
  mkdir -p "$WORKDIR/bin"
  cat >"$WORKDIR/bin/claude" <<'CLAUDE_DEFAULT'
#!/bin/bash
ts="$(date -u +%Y-%m-%dT%H-%M-%S-%6NZ)"
verdict_dir="$COORD_DIR/mediator/verdict"
mkdir -p "$verdict_dir"
verdict_file="$verdict_dir/${ts}.json"
jq -nc --arg ts "$ts" \
  '{verdict_id:"fixture-default",
    ts:$ts,
    for_pending_entry:"fixture-pending",
    mediator_session_id:"fixture-spawn",
    depth:1,
    action_type:"advice",
    severity:null,
    confidence:"auto_apply",
    reasoning:"default fixture mock — no anomaly",
    actions:[],
    message_to_caller:"No action taken (default fixture mock).",
    message_to_others:null}' >"$verdict_file"
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"fixture-spawn","total_cost_usd":0,"duration_ms":50,"result":"ok"}'
CLAUDE_DEFAULT
  chmod +x "$WORKDIR/bin/claude"

  # Seed files used by scenarios.
  printf 'export const foo = "v1";\n' >"$WORKDIR/foo.ts"
  printf 'export const bar = "v1";\n' >"$WORKDIR/bar.ts"

  COORD_DIR="$WORKDIR/.coord"
  export WORKDIR COORD_DIR SRC_ROOT
  export PATH="$WORKDIR/bin:$PATH"
}

# Run when executed directly (printing WORKDIR for non-driver use).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_fixture_init
  printf '%s\n' "$WORKDIR"
fi

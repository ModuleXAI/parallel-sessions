#!/usr/bin/env bash
# init.sh — create an isolated workspace for the two_session_warn fixture.
#
# Usage:
#   . init.sh                 # in the driver's shell; sets WORKDIR + COORD_DIR
#   ./init.sh                 # standalone; prints WORKDIR on stdout
#
# Side effects:
#   - mktemp -d → WORKDIR
#   - git init at WORKDIR + initial commit
#   - install.sh --yes --repair against WORKDIR (creates .coord/, .claude/)
#   - seed files: foo.ts, bar.ts at WORKDIR root
#
# Designed to be called once per scenario run. Caller is responsible for
# cleanup via `rm -rf "$WORKDIR"` when done.

set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$FIXTURE_DIR/../../.." && pwd)"

coord_fixture_init() {
  WORKDIR="$(mktemp -d -t coord-fixture-2sw-XXXX)"

  (
    cd "$WORKDIR"
    git init -q
    git config user.email t@t
    git config user.name  T
    printf 'placeholder for fixture init commit\n' >.fixture-seed
    git add .fixture-seed
    git commit -q -m "fixture: initial seed"
  )

  # Install coord into the workspace.
  ( cd "$WORKDIR" && "$SRC_ROOT/install.sh" --yes --repair >/dev/null )

  # Seed files used by scenarios.
  printf 'export const foo = "v1";\n' >"$WORKDIR/foo.ts"
  printf 'export const bar = "v1";\n' >"$WORKDIR/bar.ts"

  COORD_DIR="$WORKDIR/.coord"
  export WORKDIR COORD_DIR
}

# Standalone usage prints WORKDIR for piping to other tooling.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  coord_fixture_init
  printf '%s\n' "$WORKDIR"
fi

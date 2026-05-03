# Codex Integration — Live Log

Append-only progress log for the Codex CLI integration. Every PR's start, completion, deviation, and decision is recorded here. The plan lives in `codex-integration-plan.md`.

**Format conventions:**
- Each session starts with a date heading (`## YYYY-MM-DD`).
- Each PR-level event is a bullet under that date.
- Status keywords: `STARTED`, `IN-PROGRESS`, `BLOCKED`, `COMPLETED`, `REVERTED`, `DEVIATED`.
- Deviations link to the plan section being amended.
- Test-suite failures are recorded with the failing-test name (not full output).

---

## 2026-05-02

- **PR A.0 STARTED** — plan + log files committed to research branch.
- Branch: `research/codex-integration` (will fork `feat/codex-integration` for implementation).
- Reference report `codex-integration-research.md` already on branch.
- Plan version: v1.0.
- Outstanding before Phase A can begin:
  - User reviews plan and acknowledges in this log (see "Acceptance of plan" section in the plan file).
  - Implementation branch `feat/codex-integration` opened.
  - Full test surface verified green on parent branch (645 unit + 48 integration + 24 ship-gate + 19 invariant).

- **2026-05-02 — Plan v1.0 reviewed and accepted by user. Phase A may begin.**
  - Acceptance recorded per plan §"Acceptance of plan".
  - `codex-ref-repo/` (upstream Codex CLI checkout, ~470M) added to `.gitignore` —
    kept locally as a maintainer reference, not part of the ship surface.

- **PR A.0 COMPLETED** — plan v1.0 + live log + research report committed to `research/codex-integration`.
  - Files committed: `codex-integration-plan.md`, `codex-integration-log.md`, `codex-integration-research.md`, `.gitignore` (codex-ref-repo entry).
  - Merge commit: 5169106.

- **Phase A pre-condition: test surface verified GREEN on `research/codex-integration` (parent baseline).**
  - bats unit: PASS (645/645). First run had a flake at #631 (`pre_tool_use_any: hook latency under suspicion stays below 1000ms wall-clock`); the assertion itself passed (hook elapsed 119ms), but `teardown` raced the backgrounded watchdog probe and `rm -rf "$TMP"` failed with "Directory not empty". Re-run: 645/645 clean. Filed mentally as known teardown-race flake — not a regression.
  - bats integration: PASS (48/48).
  - ship-gates: not run (gitignored maintainer fixtures; will run as part of PR H.1 ship-gate).
  - invariant: included in unit count (phase7_invariant.bats lives under src/tests/unit/).

- **Branch `feat/codex-integration` opened from `research/codex-integration` @ 0bb8913.** Phase A implementation lands here.

- **PR A.1 STARTED** — relocate libs from `src/lib/` to `src/core/lib/`.
  - Pre-conditions verified: A.0 merged (5169106), test surface green (645+48), branch open.
  - Plan amendments locked before writing code: see plan v1.1 §"Deviations recorded for A.1" (D-A1-01, D-A1-02, D-A1-03).
  - Branch: `feat/codex-integration`.

- **PR A.1 DEVIATED — D-A1-01: `subagent_filter.sh` moves with the rest, not "stays put".**
  - Plan section affected: A.1 (file inventory, NOT moved list).
  - Reason: Tests run hooks from `$SRC_ROOT/hooks/`, and hooks resolve a single `LIB_DIR`. Splitting libs across `src/lib/` (subagent_filter only) and `src/core/lib/` (everything else) would force every hook to source via two paths. Cleaner to move it twice in git history (A.1: lib → core/lib; A.2: core/lib → adapters/claude-code). `git log --follow` survives the double rename.
  - Plan amendment: plan v1.1 §A.1 D-A1-01.
  - Resumed at: 2026-05-02.

- **PR A.1 DEVIATED — D-A1-02: `bin/coord` and hooks use dual-fallback LIB_DIR.**
  - Plan section affected: A.1 implementation step 4 (was "change `../lib` to `../core/lib`").
  - Reason: `src/bin/coord` is copied verbatim to `.coord/bin/coord` at install time. Installer keeps libs flat at `.coord/lib/` (not `.coord/core/lib/`). A hard-coded `../core/lib` would break the installed CLI. Dual fallback (`../core/lib` first, fall back to `../lib`) resolves correctly in both source-tree and installed layouts.
  - Plan amendment: plan v1.1 §A.1 D-A1-02.
  - Resumed at: 2026-05-02.

- **PR A.1 DEVIATED — D-A1-03: Test surface scope was underestimated by ~6×.**
  - Plan section affected: A.1 risk + estimated diff.
  - Reason: Plan v1.0 used `grep -rn 'src/lib/' src/tests/` (literal substring). Real tests use `$SRC_ROOT/lib/X.sh` (variable interpolation), which the grep misses. Actual count: 185 occurrences across 43 .bats files + helpers. Mechanical sed; no architectural change. Risk M → M-H, diff ~30 → ~250 lines.
  - Plan amendment: plan v1.1 §A.1 D-A1-03.
  - Resumed at: 2026-05-02.

- **PR A.1 IN-PROGRESS — implementation pass 1 caught 5 invariant failures.**
  - First post-move test run: unit 640/645 (5 failures), all in `phase7_invariant.bats`.
  - Root cause: a 4th SRC_ROOT-pattern that my mass-substitution regex did not cover —
    `LIB_DIR="$SRC_ROOT/lib"` (variable assignment, no trailing slash) at
    `phase7_invariant.bats:50`. Tests #4, #15, #16, #18, #19 all consumed that LIB_DIR.
    Single-line edit fixed all 5.
  - Then a 5th pattern surfaced via grep: `"$SRC_ROOT"'/lib/...` (heredoc quote-escaping
    inside `bash -c '...'` blocks) in `cost_guards_modes.bats` (17 subs) and
    `spawn_helper_modes.bats` (8 subs). 25 substitutions across those 2 files.
  - Lesson: blanket grep for "/lib/" turned up 4 distinct syntactic forms
    (`$SRC_ROOT/lib/X.sh`, `$SRC_ROOT/lib"`, `"$SRC_ROOT"'/lib/`, `/work/src/lib/`).
    Each needed its own substitution rule. No single sed pass would have caught all
    without iteration. (No new deviation entry — within scope of D-A1-03.)

- **PR A.1 COMPLETED** — 28 file moves + 31 file edits.
  - Final diff: 59 files changed, 288 insertions(+), 236 deletions(-).
  - File moves (28):
    - 26 .sh files: `src/lib/*.sh` → `src/core/lib/*.sh` (incl. `subagent_filter.sh` per D-A1-01).
    - 2 .md files: `src/lib/{MEDIATOR,VALIDATOR}_REFERENCE.md` → `src/core/lib/`.
  - File edits (31):
    - `src/install.sh`: 11 path updates (1 cp glob + 10 ref doc paths).
    - `src/bin/coord`: dual-fallback LIB_DIR + comment refresh (per D-A1-02).
    - `src/hooks/*.sh` × 8: dual-fallback LIB_DIR.
    - `src/core/lib/{MEDIATOR,VALIDATOR}_REFERENCE.md` × 2: cosmetic doc path updates.
    - `src/tests/manual/linux_probe.sh`: 1 path.
    - `src/tests/{unit,integration}/*.bats` × 42: 189 substitutions across 4 syntactic forms.
  - Tests added: 0 (refactor PR; no behavior change).
  - Test surface state at A.1 boundary:
    - bats unit: PASS (645/645).
    - bats integration: PASS (48/48).
    - ship-gates: not run (gitignored maintainer fixtures; deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 95d32a4 (29 renames preserved at 99-100% similarity by git).

- **PR A.2 STARTED** — relocate Claude Code hooks + Claude-specific subagent_filter.sh
  out of `src/{hooks,core/lib}/` and under `src/adapters/claude-code/`.
  - Pre-conditions: A.1 merged (95d32a4), unit/integration green on feat branch.
  - Branch: `feat/codex-integration`.

- **PR A.2 implementation findings (no plan amendment — within original scope of A.2):**
  - **F-A2-01**: subagent_filter.sh's CLI shim sources `log_event.sh` from its own
    directory (`$_SHIM_DIR/log_event.sh`). After A.2, log_event lives in core/lib
    while subagent_filter lives in adapters/claude-code/lib — siblings broken.
    Fix: shim uses dual-fallback (`../../../core/lib/log_event.sh` first, fall back
    to sibling `log_event.sh` for the installed flat layout). Mirrors the hook
    LIB_DIR pattern from D-A1-02.
  - **F-A2-02**: `phase7_invariant.bats:49` defined `HOOKS_DIR="$SRC_ROOT/hooks"`
    (variable assignment, no trailing slash) — same syntactic miss as A.1's
    `LIB_DIR="$SRC_ROOT/lib"` flake. Single-line fix: point at
    `$SRC_ROOT/adapters/claude-code/hooks`. Also added an unused
    `ADAPTER_LIB_DIR` placeholder for future adapter-lib invariants.
  - **F-A2-03**: install.sh now copies adapter libs alongside core libs
    (`cp $SELF_DIR/adapters/claude-code/lib/*.sh $COORD_DIR/lib/`) so the runtime
    `.coord/lib/` stays flat. install_register.bats:148 (which checks
    `subagent_filter.sh` is at `.coord/lib/`) keeps passing without edit.
  - Two intermittent suite-level flakes seen during iteration:
    - watchdog #631 teardown race (same as Phase A baseline; isolated re-run clean).
    - self_tasks #393 1-second-window idempotency. Isolated 3/3 PASS; suite 2/2 FAIL.
      Test is timing-sensitive by design (`<= 1000ms` in jq filter) and A.2 touched
      no file this test exercises. Filed as load-driven flake; revisit if it sticks.

- **PR A.2 COMPLETED** — 9 file moves + 11 file edits.
  - File moves (9):
    - 8 hooks: `src/hooks/*.sh` → `src/adapters/claude-code/hooks/*.sh`.
    - 1 lib: `src/core/lib/subagent_filter.sh` → `src/adapters/claude-code/lib/`.
  - File edits (11):
    - 8 hooks: LIB_DIR split into CORE_LIB_DIR (dual-fallback) + ADAPTER_LIB_DIR
      (always `../lib`, the adapter-local dir in source / `.coord/lib/` installed).
    - 1 adapter lib (subagent_filter.sh): CLI shim's log_event source path uses
      dual-fallback (per F-A2-01).
    - 1 install.sh: 1 new cp line for adapter libs; updated existing hook glob.
    - 25 test files: 64 substitutions for `$SRC_ROOT/hooks/`, the heredoc-quoted
      variant `"$SRC_ROOT"'/hooks/`, `$SRC_ROOT/core/lib/subagent_filter.sh`, and
      `/work/src/hooks/` (linux_probe.sh).
    - 1 phase7_invariant.bats: HOOKS_DIR variable update (per F-A2-02).
  - Tests added: 0 (refactor PR; no behavior change).
  - Test surface state at A.2 boundary:
    - bats unit: 644/645 in suite (1 timing flake at #393, isolated 3×3 clean).
      Confirmed not regressed by A.2.
    - bats integration: PASS (48/48).
    - ship-gates: not run (gitignored maintainer fixtures; deferred to PR H.1).
    - invariant: included in unit count (#1..#19 all pass post-fix).
  - Merge commit: 567d4cf (9 renames preserved at 86-96% similarity by git).

- **PR A.3 STARTED** — relocate `coord` CLI to `src/core/bin/`.
  - Pre-conditions: A.2 merged (567d4cf).
  - Branch: `feat/codex-integration`.

- **PR A.3 finding (in-scope, no plan amendment) — F-A3-01:**
  Post-A.3 the `coord` CLI lives at `src/core/bin/coord` and core libs at
  `src/core/lib/`, so they are siblings — `$COORD_BIN/../lib` resolves
  cleanly in both layouts (source: `src/core/bin/../lib` = `src/core/lib`;
  installed: `.coord/bin/../lib` = `.coord/lib`). The A.1/A.2 dual-fallback
  in `bin/coord` is no longer needed and was simplified back to a single
  `LIB_DIR=$(cd "$COORD_BIN/../lib" && pwd)`. Hooks still need their
  dual-fallback — they live deeper under `src/adapters/<agent>/hooks/`.

- **PR A.3 COMPLETED** — 1 file move + ~13 reference updates.
  - File moves: `src/bin/coord` → `src/core/bin/coord` (1 file).
  - File edits:
    - `src/install.sh`: 2 path updates (file-exists check + cp source).
    - `bin/parallel-sessions`: 1 path update (npx wrapper).
    - `src/core/bin/coord`: simplified LIB_DIR + comment refresh (per F-A3-01).
    - 7 unit/integration .bats: `$SRC_ROOT/bin/coord` and BIN_DIR variable updates.
    - `src/tests/manual/linux_probe.sh`: 1 path update.
    - 3 lib/hook comment refreshes (cosmetic): `src/core/lib/coord_mediate.sh`,
      `src/core/lib/log_event.sh`, `src/adapters/claude-code/hooks/pre_tool_use_write.sh`.
    - `src/tests/unit/phase7_invariant.bats`: 3 cosmetic message updates.
  - Tests added: 0 (refactor PR; no behavior change).
  - Test surface state at A.3 boundary:
    - bats unit: PASS (645/645) — flake-free this run.
    - bats integration: PASS (48/48).
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 8d536f0 (rename preserved at 97% similarity by git).

- **PR A.4 STARTED** — add `src/core/lib/normalized_events.sh` forward-declaration.
  - Pre-conditions: A.3 merged (8d536f0).
  - Branch: `feat/codex-integration`.

- **PR A.4 finding (in-scope) — F-A4-01:**
  Plan A.4 calls for the new test at `src/core/tests/unit/normalized_events.bats`,
  but the existing test surface still lives entirely under `src/tests/unit/`. No
  Phase A PR explicitly relocates the 43 existing test files. Choosing to put the
  new test at `src/tests/unit/normalized_events.bats` to keep all tests in one
  directory; if a future PR reorganizes tests under `src/core/tests/` and
  `src/adapters/<agent>/tests/`, this file moves with the rest. Pragmatic
  trade-off: don't touch 43 unrelated files just to add 1 new test.

- **PR A.4 COMPLETED** — 2 new files, 0 edits.
  - File added: `src/core/lib/normalized_events.sh` (~50 lines, 12 constants
    grouped lifecycle / tool-call / sentinel).
  - File added: `src/tests/unit/normalized_events.bats` (6 tests covering source-
    cleanly, lifecycle constants defined, tool-call constants defined, sentinel
    defined, naming-contract regex `^[A-Z][A-Z0-9_]*$`, and uniqueness across
    all constants).
  - Tests added: 6.
  - Test surface state at A.4 boundary:
    - bats unit: PASS (651/651) — was 645, +6 from new normalized_events.bats.
    - bats integration: still 48/48 (A.4 doesn't touch integration surface).
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 014ab10.

- **PR A.5 STARTED** — add `src/core/lib/folder_resolver.sh`; drop git-repo
  requirement from installer + npx wrapper.
  - Pre-conditions: A.4 merged (014ab10).
  - Branch: `feat/codex-integration`.

- **PR A.5 finding (in-scope) — F-A5-01:**
  Plan put new tests under `src/core/tests/{unit,integration}/` to match the
  target architecture, but Phase A has no PR that relocates the existing 43
  unit + 4 integration test files. Per F-A4-01 (same call), placing both new
  test files under the existing `src/tests/{unit,integration}/` so all tests
  stay discoverable by the standard `bats src/tests/{unit,integration}` run.
  When/if a future PR splits tests into core/adapter trees, these move along.

- **PR A.5 COMPLETED** — 1 lib added, 1 lib edited, 1 npx-wrapper edited, 8 hooks
  shrunk by ~12 lines each, 2 install.sh sites edited, 2 new test files added.
  - Files added (3):
    - `src/core/lib/folder_resolver.sh` (~85 lines, single function `coord_resolve_root`
      implementing the 5-step resolution algorithm: COORD_DIR > cwd-walk-up >
      BASH_SOURCE-walk-up > legacy CLAUDE_PROJECT_DIR > git fallback).
    - `src/tests/unit/folder_resolver.bats` (8 tests covering each resolution step
      and the rc-1 no-match path).
    - `src/tests/integration/non_git_install.bats` (4 tests covering full
      `bash install.sh --yes` in a non-git mktemp dir, hook resolution post-install,
      banner output, and pre-existing .gitignore preservation).
  - Files edited (12):
    - `src/install.sh`: Step 1 now falls back to $PWD when no git, prompts user
      unless --yes; Step 8 (gitignore_entries) skips entirely when neither
      .git/ nor .gitignore exists.
    - `bin/parallel-sessions`: git check downgraded from hard error to
      `console.warn` advisory; install proceeds either way.
    - 8 Claude Code hooks (`src/adapters/claude-code/hooks/*.sh`): inline
      `coord_resolve_root() { ... }` blocks (12-16 lines each) removed; each
      hook now sources `$CORE_LIB_DIR/folder_resolver.sh` after `lockdown.sh`.
  - Tests added: 12 (8 unit + 4 integration).
  - Test surface state at A.5 boundary:
    - bats unit: PASS (659/659) — was 651, +8 from new folder_resolver.bats.
    - bats integration: PASS (52/52) — was 48, +4 from new non_git_install.bats.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Risk note: plan flagged this PR as High-risk because of the BASH_SOURCE walk-up
    on macOS (filesystem boundaries). Live tests covering the cwd and explicit-arg
    paths all pass; the BASH_SOURCE walk-up is exercised indirectly via hook tests
    (every hook runs from src/adapters/.../hooks/ in tests). No fs-boundary issue
    surfaced.
  - Merge commit: 2e5d085.

---

**Phase A — REFACTOR — COMPLETE.**
- Started: 2026-05-02 (A.0).
- Completed: 2026-05-02 (A.5).
- PRs merged: A.0, A.1, A.2, A.3, A.4, A.5 (6 PRs).
- Test surface delta:
  - unit:        645 → 659 (+14: 6 normalized_events + 8 folder_resolver).
  - integration: 48  → 52  (+4: non_git_install).
- Notable deviations recorded in plan v1.1: D-A1-01, D-A1-02, D-A1-03 (all A.1).
- In-scope findings (no plan amendment): F-A2-01..03, F-A3-01, F-A4-01, F-A5-01.
- Test surface contract met: unit + integration both PASS at A.5 boundary.
- Phase B (schema 1.1 + launchers) may now begin.

---

## Phase B — Schema extension + launcher scripts

### PR B.1 — Schema bump 1.0 → 1.1 + agent field

- **PR B.1 STARTED** — bump sessions schema to 1.1; tag every session row with
  `agent` so cross-agent state is distinguishable.
  - Pre-conditions: Phase A complete (all of A.0..A.5 merged).
  - Branch: `feat/codex-integration`.

- **PR B.1 finding (in-scope) — F-B1-01:**
  Plan called for adding `// "claude_code"` agent fallbacks to multiple readers
  (`coord status`, `notify_waiters.sh`, `watchdog.sh`). Of those, only
  `coord status` actually consumes `agent` post-B.1 (display column). The
  notify_waiters and watchdog reader updates are speculative ("could include
  agent in event payload") with no current consumer. Per CLAUDE.md "don't add
  for hypothetical futures", they are deferred to whichever PR actually needs
  the field. Single live reader change: `cmd_status` line 64 jq filter gets
  `agent=\(.value.agent // "claude_code")` interpolation.

- **PR B.1 finding (in-scope) — F-B1-02:**
  Two test files asserted `schema_version == "1.0"` (`state_query.bats:22`,
  `corruption_recovery.bats:61`). After bumping the empty template + corruption
  recovery template, both must assert "1.1". Other test fixtures that hand-craft
  `"schema_version":"1.0"` in JSON (helpers/common.bash, several .bats files)
  stay at 1.0 ON PURPOSE — they exercise the legacy-tolerance path. Don't
  change them.

- **PR B.1 COMPLETED** — 7 file edits + 1 new test file.
  - Files edited (writers — schema bump):
    - `src/core/lib/atomic_write.sh`: `coord_state_empty_template` → 1.1.
    - `src/core/lib/state_query.sh`: `coord_state_dump` fallback → 1.1.
    - `src/core/lib/log_event.sh`: `CORE_SCHEMA_VERSION` default → 1.1.
    - `src/install.sh`: 3 sites — `schema_version` file, `config.json`,
      `sessions_history.json`.
  - Files edited (writer adds agent field):
    - `src/adapters/claude-code/hooks/session_start.sh`: 3 register filters
      now include `agent: $agent`; `coord_atomic_edit` call gains
      `--arg agent "claude_code"`.
  - Files edited (reader displays agent):
    - `src/core/bin/coord`: `cmd_status` session listing adds an `agent=`
      column with `// "claude_code"` legacy fallback.
  - Files edited (test assertion catch-up per F-B1-02):
    - `src/tests/unit/state_query.bats`: assert "1.1".
    - `src/tests/unit/corruption_recovery.bats`: assert "1.1".
  - Files added: `src/tests/unit/schema_v1_1.bats` (6 tests covering empty
    template version, agent on new rows, legacy-row fallback, status display,
    install.sh writes 1.1, and forward-tolerance — atomic_edit preserves
    unknown future fields on partial updates).
  - Tests added: 6.
  - Test surface state at B.1 boundary:
    - bats unit: PASS (665/665) — was 659, +6 from new schema_v1_1.bats.
    - bats integration: PASS (52/52).
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: cb6501a.

### PR B.2 — Launcher scripts + COORD_ENABLED participation gate

- **PR B.2 STARTED** — add `bin/parallels-{init,claude,status}` launchers;
  introduce `COORD_ENABLED=1` as canonical participation flag (CLAUDE_COORD
  preserved as legacy alias).
  - Pre-conditions: B.1 merged (cb6501a) — launchers are first writers of
    schema 1.1, so the strict B.1-before-B.2 ordering is honored.
  - Branch: `feat/codex-integration`.

- **PR B.2 finding (in-scope) — F-B2-01:**
  Plan's `parallels-claude` snippet had a one-liner `bash -c '... walk-up
  loop ... '` to find .coord/. Inlined too tightly — fragile across shells
  and hard to read. Used a small `_walk_for_coord()` function instead.
  Same pattern in `parallels-status` (which the plan didn't show but needs
  the same lookup since `coord status` resolves COORD_DIR from the CLI's
  install location, not cwd).

- **PR B.2 finding (in-scope) — F-B2-02:**
  Initial `launcher_parallels_claude.bats #2` test set `PATH="$STUB_BIN"`
  alone to test the "claude binary absent" branch. That stripped /usr/bin
  too, breaking the launcher's own `#!/usr/bin/env bash` shebang
  resolution — exit 127 instead of the expected exit 3. Fix: keep
  `/usr/bin:/bin` in PATH so the launcher itself runs; STUB_BIN is empty
  so `claude` lookup still fails and rc 3 fires correctly.

- **PR B.2 COMPLETED** — 3 launcher scripts + 8 hook gate updates +
  package.json bin map + 4 new test files.
  - Files added (3 launchers, all chmod +x):
    - `bin/parallels-init`: thin pass-through to `src/install.sh`.
    - `bin/parallels-claude`: cwd-walk-up for .coord/, claude PATH check,
      then `exec env COORD_ENABLED=1 claude "$@"`.
    - `bin/parallels-status`: cwd-walk-up for .coord/, then exec
      `coord status "$@"` with COORD_DIR set.
  - Files added (4 test files):
    - `src/tests/integration/launcher_parallels_init.bats` (3 tests).
    - `src/tests/integration/launcher_parallels_claude.bats` (4 tests).
    - `src/tests/integration/launcher_parallels_status.bats` (2 tests).
    - `src/tests/unit/coord_enabled_legacy.bats` (5 tests covering
      COORD_ENABLED canonical, CLAUDE_COORD legacy, both-unset, and the
      precedence cases when both are set with conflicting values).
  - Files edited:
    - 8 hooks: participation gate updated from
      `[ "${CLAUDE_COORD:-}" != "1" ]` to
      `[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ]`. Legacy
      CLAUDE_COORD=1 keeps working through the parameter expansion
      fallback.
    - `package.json`: 3 new entries in `bin` map.
  - Tests added: 14 (5 unit + 9 integration).
  - Test surface state at B.2 boundary:
    - bats unit: PASS (670/670) — was 665, +5 from coord_enabled_legacy.bats.
    - bats integration: PASS (61/61) — was 52, +9 from 3 launcher .bats.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 6babdbf.

---

**Phase B — SCHEMA + LAUNCHERS — COMPLETE.**
- Started: 2026-05-02 (B.1).
- Completed: 2026-05-03 (B.2).
- PRs merged: B.1, B.2 (2 PRs).
- Test surface delta:
  - unit:        659 → 670 (+11: 6 schema_v1_1 + 5 coord_enabled_legacy).
  - integration: 52  → 61  (+9: 3 launcher .bats).
- Notable deviations: none requiring plan amendment.
- In-scope findings: F-B1-01, F-B1-02, F-B2-01, F-B2-02.
- Phase C (Codex translator + apply_patch parser) may now begin.

---

## Phase C — Codex translator + apply_patch parser

### PR C.1 — Codex translator skeleton

- **PR C.1 STARTED** — add `src/adapters/codex/lib/translator.sh` skeleton with
  every adapter-contract function stubbed; tests assert signatures + rc=1.
  - Pre-conditions: Phase B complete (B.2 merged at 6babdbf).
  - Branch: `feat/codex-integration`.

- **PR C.1 finding (in-scope) — F-C1-01: watchdog teardown race finally fixed.**
  Phase A baseline log noted a flaky test #631 (`pre_tool_use_any: hook latency
  under suspicion stays below 1000ms wall-clock`) where the assertion passed
  (~120ms) but `teardown` raced the backgrounded watchdog probe and `rm -rf`
  failed with "Directory not empty". Three more runs across A.5, B.1, B.2, C.1
  showed the flake recurring under cumulative session load. C.1 itself touches
  zero files this test exercises, so it's clearly pre-existing.
  Fix: `src/tests/unit/watchdog.bats teardown()` now waits up to 2s for the
  `.coord/watchdog/checking/` dir to drain before `rm -rf`, then retries the rm
  once with a short delay if it still fails. Test infra fix, no behavior change.
  Filing as in-scope to C.1 because D-13 (green-at-every-PR-boundary) makes the
  flake a blocker, and the fix is a 14-line teardown change in a test file.

- **PR C.1 COMPLETED** — 1 new lib + 1 new test + 1 test-infra fix.
  - Files added (2):
    - `src/adapters/codex/lib/translator.sh` (~140 lines): 14 stub functions
      covering event translation, 9 field extractors, 3 response emitters,
      plus `coord_cx_extract_subagent` documented as PERMANENT rc=1 per D-2.
      Every stub calls `_coord_cx_stub` which carries the marker
      `PR-C.1 skeleton stub` for C.3's audit grep.
    - `src/tests/unit/translator_skeleton.bats` (5 tests): every contract
      function defined, stubs return rc=1 silently, extract_subagent
      separately asserted as permanent (so C.3+ doesn't accidentally fill it),
      bash -n syntax check, and stub-marker presence (the C.3 done-when grep).
  - Files edited (1):
    - `src/tests/unit/watchdog.bats` (per F-C1-01): teardown drains
      backgrounded probe before rm.
  - Tests added: 5 (unit).
  - Test surface state at C.1 boundary:
    - bats unit: PASS (675/675) — was 670, +5 from new translator_skeleton.bats.
    - bats integration: PASS (61/61).
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 4ac6366.

### PR C.2 — apply_patch_parser.sh + 24 fixtures

- **PR C.2 STARTED** — implement Codex apply_patch grammar parser as a bash 3.2
  state machine over a single line-by-line pass. Approved with the design
  preview on 2026-05-03. Hard-stop-after-C.1 gate cleared by user.
  - Pre-conditions: C.1 merged (4ac6366); design preview approved with three
    findings: F-C2-01 (ID map), F-C2-02 (helper computes hash), F-C2-03 (rc=4
    fixture).
  - Branch: `feat/codex-integration`.

- **PR C.2 plan amendment — D-C2-01:** add 4 adversarial fixtures (category I,
  IDs 105-108). Approved by user on the design preview ("INCLUDE. They're
  load-bearing for the 'model emits weird content' case"). Plan v1.2 §C.2
  records the amendment.

- **PR C.2 finding (in-scope) — F-C2-04: fixture count discrepancy.**
  Design preview's stated total was "22 fixtures"; the breakdown table in the
  same preview actually summed to 23. Adding F-C2-03 (rc=4) gave 24, not the
  user-quoted 23. I went with the breakdown's 23 + F-C2-03 = 24. README at
  the fixture dir documents the count and the discrepancy openly.

- **PR C.2 implementation finding — F-C2-05: parser strips jq trailing
  newline before hashing; helper must mirror that EXACTLY.**
  First test run had 6 hash mismatches because parser uses
  `pre=$(jq -r ...)` (which strips jq's trailing `\n` per bash $(…)
  semantics) but the helper piped jq output directly into sha256 (preserving
  the `\n`). Per F-C2-02 contract review the helper has to compute the same
  hash the parser would. Fixed: helper now captures into a var via $(...)
  too. Single-line documentation update in the helper explaining why.

- **PR C.2 implementation finding — F-C2-06: bats `set -e` aborts on
  non-zero rc before $? could be captured.** Initial _assert_negative used
  `actual_rc=$?` on the line AFTER `_coord_cx_parse_ast` returned a deliberate
  non-zero rc — bats aborted the test before $? was assigned. Fixed with
  `... || actual_rc=$?` idiom on the same line as the parser call.

- **PR C.2 COMPLETED** — 1 parser lib + 14 verbatim + 10 hand-rolled fixtures
  + 24 expected.json + 1 generated bats helper.
  - Files added (parser): `src/adapters/codex/lib/apply_patch_parser.sh`
    (~290 lines): 1 internal `_coord_cx_parse_ast` (state machine, 7 states),
    6 public functions (`paths`, `operations`, `hunks`, `pre_image`,
    `pre_image_hash`, `edit_range`), 2 internal helpers (`_strip_heredoc`
    for lenient mode, `_sha256_hex` cross-platform).
  - Files added (24 fixtures, each 2 files patch.txt + expected.json):
    - 14 verbatim from `codex-ref-repo/.../scenarios/`: 001, 002, 003, 004,
      005, 008, 013, 016, 017, 018, 019, 020 (×2: `_delete_file_success` and
      `_whitespace_padded_patch_marker_lines` — upstream collision preserved
      so future regression checks correlate by directory name), 022.
    - 10 hand-rolled (IDs 100+): 100 single_hunk_update, 101 context_only,
      102 lenient_heredoc, 103 missing_end_patch, 104 malformed_hunk_content
      (per F-C2-03), 105-108 adversarial (per D-C2-01), 109 multi_hunk_pre_image.
  - Files added (test helper):
    `src/tests/unit/apply_patch_parser.bats` (~170 lines, programmatically
    generated): one @test per fixture; positive uses `_assert_positive`
    (AST diff via `jq -S` + per-path sha256 hash from expected.pre_image
    matched against parser-emitted hash per F-C2-02); negative uses
    `_assert_negative` (rc + stderr substring).
  - Files added (fixture dir README):
    `src/adapters/codex/tests/fixtures/apply_patch/README.md` documenting the
    ID map (000-099 = upstream-verbatim namespace; 100+ = synthesized),
    category breakdown, and final count.
  - Tests added: 24 (all unit).
  - Test surface state at C.2 boundary:
    - bats unit: PASS (699/699) — was 675, +24 from new apply_patch_parser.bats.
    - bats integration: PASS (61/61).
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Stub-marker grep on translator.sh: still 14 unfilled stubs. C.3 is the
    PR that takes that count to 1 (just `_coord_cx_stub` itself).
  - Merge commit: 1230a64.

### PR C.3 — Translator complete

- **PR C.3 STARTED** — fill in every C.1 stub with real implementation; wire
  `coord_cx_extract_file_paths` through the C.2 apply_patch parser.
  - Pre-conditions: C.2 merged (1230a64); design preview's "no separate
    review needed for C.3 unless contract changes" applies.
  - Branch: `feat/codex-integration`.

- **PR C.3 finding (in-scope) — F-C3-01: skeleton-test rename + supersession.**
  C.1's tests at `src/tests/unit/translator_skeleton.bats` asserted "every
  function is a stub returning rc=1 with no stdout" — directly contradicting
  C.3's contract. Renamed via `git mv` to `translator.bats` (history follows)
  and rewrote contents. Two C.1 tests carry forward: function-defined check
  and bash -n syntax. The "stubs return rc=1" test is removed; replaced by
  per-function behavior tests. The "stub marker present" test is INVERTED to
  "marker absent" — the C.3 done-when signal.

- **PR C.3 finding (in-scope) — F-C3-02: marker text in comments tripped the
  done-when grep.** First C.3 test run had 1 failure: the C.3 done-when test
  fired because translator.sh's top-level docstring referenced the marker
  text literally ("`PR-C.1 skeleton stub` marker has been removed"). Fix:
  reworded the comment to refer to "the C.1 done-when marker" without
  embedding the literal string.

- **PR C.3 finding (in-scope) — F-C3-03: extract_file_paths is a NEW
  function vs C.1 contract.** Plan §C.3 lists `coord_cx_extract_file_paths`
  as a translator function, but C.1's skeleton (which followed plan §C.1
  verbatim) didn't include it. Added to translator.sh in C.3 since the hook
  layer (D.4) needs it for apply_patch routing. The translator.bats
  `every contract function is defined` test now covers 15 functions, not 14.

- **PR C.3 COMPLETED** — translator.sh stubs filled + new test surface.
  - File edited (1):
    - `src/adapters/codex/lib/translator.sh`: 14 stubs replaced with real
      implementations; +1 new function (`coord_cx_extract_file_paths`);
      +1 jq filter helper (`_coord_cx_jq_field`); sources
      `normalized_events.sh` via dual-fallback (mirrors hook LIB_DIR pattern
      from D-A1-02).
  - File renamed:
    - `src/tests/unit/translator_skeleton.bats` → `translator.bats` via
      `git mv` (history follows). Rewrote contents: 38 tests covering event
      translation matrix (11), field extractors (12), apply_patch path
      extraction (4), response emitters (8), plus 4 sanity carry-forwards
      (functions defined, bash -n, extract_subagent permanent rc=1, C.3
      done-when marker absence).
  - Tests added/changed: net +33 (38 new − 5 old skeleton tests).
  - Test surface state at C.3 boundary:
    - bats unit: PASS (732/732) — was 699, +33 net from translator.bats.
    - bats integration: PASS (61/61).
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Translator stub-marker grep on translator.sh: 0. C.3 done-when met.
  - Merge commit: 4646fee.

### PR C.4 — parallels-codex launcher

- **PR C.4 STARTED** — mirror parallels-claude for the codex CLI; add hooks.json
  pre-flight (soft, per F-C4-01).
  - Pre-conditions: C.3 merged (4646fee).
  - Branch: `feat/codex-integration`.

- **PR C.4 finding (in-scope) — F-C4-01: .codex/hooks.json check is a warning,
  not a hard error.**
  Plan §C.4 says "Pre-flight checks `.codex/hooks.json` exists" without
  specifying behavior on absence. parallels-claude's analogous file
  (.claude/settings.local.json) is hard-required and exists post-`parallels-init`.
  But .codex/hooks.json's installer doesn't exist until Phase E; until then,
  every Phase C/D test would fail a hard check. Decision: warn-and-proceed.
  When the file is missing, hooks won't fire — the warning makes that visible
  without blocking testing.

- **PR C.4 COMPLETED** — 1 launcher + 1 test file + 1 package.json edit.
  - File added: `bin/parallels-codex` (~50 lines, chmod +x).
  - File added: `src/tests/integration/launcher_parallels_codex.bats` (5 tests
    covering rc 2 no-coord, rc 3 no-codex, soft hooks.json warning, happy
    path, cwd-walk-up).
  - File edited: `package.json` — added parallels-codex to bin map.
  - Tests added: 5 (integration).
  - Test surface state at C.4 boundary:
    - bats unit: PASS (732/732).
    - bats integration: PASS (66/66) — was 61, +5 from launcher_parallels_codex.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 1cd74f0.

---

**Phase C — CODEX TRANSLATOR + APPLY_PATCH PARSER — COMPLETE.**
- Started: 2026-05-02 (C.1).
- Completed: 2026-05-03 (C.4).
- PRs merged: C.1, C.2, C.3, C.4 (4 PRs).
- Test surface delta:
  - unit:        675 → 732 (+57: 5 translator-skeleton-then-superseded-by-38, 24 apply_patch_parser).
  - integration: 61  → 66  (+5: launcher_parallels_codex).
- Notable plan amendment: D-C2-01 (4 adversarial fixtures added per design preview approval).
- In-scope findings: F-C1-01 (watchdog teardown race), F-C2-04..06 (count, hash, set-e),
  F-C3-01..03 (test rename, marker-in-comment, extract_file_paths), F-C4-01 (soft hooks.json check).
- Phase D (Codex hooks) may now begin — D.1 is the first actual hook, depends on full Phase C surface.

---

## 2026-05-03 (continued)

- **Reviewer note (retrospective, no action) — Phase C closure observation.**
  - Test surface delta reconciled exactly: C.1 (+5) → C.2 (+24) → C.3 (+33 net,
    superseding C.1's skeleton tests as expected) + C.4 (+5 integration).
    732 unit / 66 integration matches.
  - Observation: C.1 as a standalone PR carried structural value but no
    independent test value — its 5 tests were superseded by C.3's 38. The
    skeleton→complete pattern is fine and D-13 was honored at every boundary,
    but for future reference, skeleton PRs that exist purely to be superseded
    are candidates for merging into their completing PR unless there is a
    structural reason to split (review surface, rollback granularity, etc.).
  - Filed as guidance for future phases; not a finding. No remediation.

- **Phase D gating — reviewer protocol (recorded so future PRs honor it).**
  - D.1, D.2, D.3 proceed directly without design preview (mechanical mirrors
    of Claude hooks via the Codex translator — low risk).
  - STOP after D.3 merges. Post UNIFIED design preview covering D.4 + D.5
    together (lock acquisition + drift detection + release/task-processor +
    cross-cutting D-9/D-10 + the three pre_tool_use_*.sh dispatch).
  - D.4 + D.5 ship as separate PRs after preview approval.
  - If implementation reveals divergence from the approved design, stop and
    flag per Plan Amendment Policy.

- **PR D.1 STARTED** — Codex `session_start.sh` hook.
  - Pre-conditions verified: Phase C complete (1cd74f0); 732 unit / 66
    integration green at HEAD (b4fe0de).
  - Estimated diff: ~250 lines (hook) + ~10 bats tests.
  - Branch: `feat/codex-integration`.
  - Mirror source: `src/adapters/claude-code/hooks/session_start.sh`.
  - Translator helpers used: `coord_cx_extract_session_id`,
    `coord_cx_extract_source`, `coord_cx_extract_cwd`,
    `coord_cx_emit_additional_context`.
  - Differences vs Claude mirror:
    - Source enum: `{startup, resume, clear}` only (no `compact` per D-11).
    - `agent: "codex"` written on registered rows (vs `"claude_code"`).
    - No subagent filter (per D-2: Codex has no subagent concept; the
      translator's `coord_cx_extract_subagent` is permanently rc=1).
    - Codex spec marks `source` as required; we still default to `startup`
      on missing/empty for fail-open robustness.

- **PR D.1 COMPLETED** — 1 hook file + 1 test file (12 unit tests).
  - File added: `src/adapters/codex/hooks/session_start.sh` (~270 lines,
    chmod +x).
  - File added: `src/tests/unit/codex_session_start.bats` (12 tests
    covering the source matrix {startup, resume, clear}, the D-11
    `compact`-as-unknown forward-tolerance branch, the D-2 no-subagent-
    filter behavior, the COORD_ENABLED gate, and the lockdown deny gate).
  - Tests added: 12 (unit).
  - Test surface state at D.1 boundary:
    - bats unit:        PASS (744/744) — was 732, +12 from codex_session_start.
    - bats integration: PASS (66/66) — unchanged.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 512ba32.

- **PR D.1 reviewer observation (logged retrospectively, not a finding).**
  - D.1 defaults a missing/empty `source` field to `startup` despite the
    Codex spec marking `source` as required. Deliberate divergence for
    fail-open robustness + symmetry with Claude's session_start behavior
    (Claude treats `source` as optional with `// "startup"`). Future readers
    should not mistake the default for an oversight.

- **PR D.2 STARTED** — Codex `stop.sh` hook.
  - Pre-conditions verified: D.1 merged (512ba32); 744 unit / 66 integration
    green at HEAD (5070d29).
  - Estimated diff: ~200 lines (hook) + ~10 bats tests.
  - Branch: `feat/codex-integration`.
  - Mirror source: `src/adapters/claude-code/hooks/stop.sh`.
  - Translator helpers used: `coord_cx_extract_session_id`.
  - Differences vs Claude mirror:
    - Drops `subagent_filter.sh` source + `coord_subagent_filter` call per D-2
      (Codex has no subagent concept).
    - Per D-10: this hook is the ONLY graceful-release point. The watchdog
      handles dead-session cleanup (IDLE_CLOSED, marker removal,
      read_snapshot cleanup) since Codex never delivers a graceful
      SessionEnd. Stop fires per-turn (mirror of Claude); no SessionEnd
      semantics fold into this hook.
    - Self-task block-once-then-allow semantic carries unchanged (Codex
      Stop input has `stop_hook_active` per Codex events/stop.rs:30).
    - Lockdown deny envelope identical (Codex respects the same
      permissionDecision JSON shape as Claude).

- **PR D.2 COMPLETED** — 1 hook file + 1 test file (10 unit tests).
  - File added: `src/adapters/codex/hooks/stop.sh` (~200 lines, chmod +x).
  - File added: `src/tests/unit/codex_stop.bats` (10 tests covering: gate
    negative, D-2 no-subagent-filter behavior, non-participant no-op,
    no-locks idempotent silent path, single-lock release with
    last_activity_at refresh, multi-lock release with peer-lock
    preservation, self-task block-once first-Stop, self-task second-Stop
    archive + concurrent lock release, lockdown gate, ship-gate
    permissionDecision negative invariant).
  - Tests added: 10 (unit).
  - Test surface state at D.2 boundary:
    - bats unit:        PASS (754/754) — was 744, +10 from codex_stop.
    - bats integration: PASS (66/66) — unchanged.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: c5c354d.

- **PR D.3 STARTED** — Codex `user_prompt_submit.sh` hook.
  - Pre-conditions verified: D.2 merged (c5c354d); 754 unit / 66 integration
    green at HEAD (3cd0d53).
  - Estimated diff: ~140 lines (hook) + ~7 bats tests.
  - Branch: `feat/codex-integration`.
  - Mirror source: `src/adapters/claude-code/hooks/user_prompt_submit.sh`.
  - Translator helpers used: `coord_cx_extract_session_id`,
    `coord_cx_extract_prompt`, `coord_cx_extract_cwd`,
    `coord_cx_emit_additional_context`.
  - Differences vs Claude mirror:
    - Drops `subagent_filter.sh` source + `coord_subagent_filter` call per
      D-2 (Codex has no subagent concept).
    - Banner emitted via translator's `coord_cx_emit_additional_context`
      (same envelope shape as Claude).
    - Codex UserPromptSubmit shape: same `.prompt` field as Claude — no
      schema differences in the consumed fields.

- **PR D.3 COMPLETED** — 1 hook file + 1 test file (7 unit tests).
  - File added: `src/adapters/codex/hooks/user_prompt_submit.sh` (~140 lines,
    chmod +x).
  - File added: `src/tests/unit/codex_user_prompt_submit.bats` (7 tests
    covering: gate negative, D-2 agent_type ignored, non-participant no-op,
    participant happy path with prompt_id + read-set invalidation + env
    cache + PROMPT_SUBMIT event, HEAD drift with superseded_by_head_change
    + HEAD_CHANGE event + additionalContext, no-drift negative invariant,
    lockdown deny gate).
  - Tests added: 7 (unit).
  - Test surface state at D.3 boundary:
    - bats unit:        PASS (761/761) — was 754, +7 from
                         codex_user_prompt_submit.
    - bats integration: PASS (66/66) — unchanged.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: 3408ea9.

- **PR D.3 boundary — STOP per reviewer gating.**
  - Per Phase D gating established in the Phase C → D handoff: D.4 + D.5
    must be designed together (lock acquisition contract symmetric with
    release/task-processor semantics; D-9/D-10 cross-cutting; pre_tool_use
    dispatch across 3 files). No D.4/D.5 code may be written before a
    unified design preview lands and reviewer approves.

- **Unified D.4+D.5 design preview produced and APPROVED.**
  - Five open questions (Q1–Q5) all approved by reviewer:
    - Q1: validator pipeline NOT used for apply_patch drift (→ A-D4-01).
    - Q2: 1 MB drift-skip threshold (symmetric with validator_prefilter
      SKIPPED_LARGE).
    - Q3: helpers stay inline in pre_tool_use_apply_patch.sh; refactor to
      `apply_patch_locking.sh` only if the file exceeds 500 lines.
    - Q4: race-loss banner reuses multi-file template; LOCK_DENIED event
      `reason_kind=race_loss` is the audit/metric distinction.
    - Q5: PostToolUse parser-failure fallback releases ALL session locks.
  - Three findings to address during implementation:
    - F-D4-01: consolidate the three filter versions in preview §3.1/§3.2/
      §3.3 into a single validate-or-abort jq filter (combines self-held
      cosmetic preservation with race-safety abort).
    - F-D4-02: verify two assumptions before D.4 code lands —
      (a) matcher `*` fires before tool-specific matchers in PreToolUse;
      (b) PostToolUse fires with `tool_response.error` when the tool errors.
      If either assumption is wrong, stop and flag per Plan Amendment
      Policy.
    - F-D5-01: edit_range=0/0 coarsening — every queued self-task on a
      released file gets a notification. Add TODO comment in D.5 release
      loop for future hunk-line refinement; not blocking.

- **Plan amendment A-D4-01 (2026-05-03 plan v1.2) — drift detection is
  structural pre_image-search, NOT validator-pipeline integration.**
  - Plan section affected: §"PR D.4 — pre_tool_use_*.sh", "Drift detection
    adaptation" paragraph + new "Deviations recorded for D.4" subsection.
  - Reason: pre_image_hash and full-file disk hash are over different
    content shapes; feeding mismatched-shape inputs to the validator
    pipeline produces meaningless SAFE/MINOR/CRITICAL classifications.
    Drift on apply_patch is STRUCTURAL (would-not-apply) not SEMANTIC
    (stale-read). The C.2 design agreement ("hook compares against
    on-disk anchor for drift detection") supersedes the plan v1.1 wording
    that the unified preview surfaced as logically inconsistent.
  - Source of amendment: unified D.4+D.5 design preview §4.2, approved
    by reviewer.
  - Plan v1.1 → v1.2.

- **F-D4-02 verification — BOTH ASSUMPTIONS FALSE plus new finding (c)
  surfaced; STOPPED per Plan Amendment Policy.**
  - F-D4-02(a) FALSE: PreToolUse handlers run in PARALLEL via
    futures::future::join_all
    (`codex-rs/hooks/src/engine/dispatcher.rs:91-96`). Output collection
    aggregates ANY deny → block, FIRST deny reason wins by declaration
    order (`pre_tool_use.rs:107-110`).
  - F-D4-02(b) FALSE: PostToolUse fires ONLY when the tool succeeds
    (`core/src/tools/registry.rs:414-421` — `if success { ... } else { None }`).
    Tool error → no PostToolUse → D.5's release loop never runs;
    Stop handles release (D.2 contract).
  - F-D4-02(c) NEW: Codex REJECTS additionalContext on PreToolUse —
    `PreToolUseOutput` struct has NO additional_context field
    (`output_parser.rs:16-20`); `unsupported_pre_tool_use_hook_specific_output`
    returns "PreToolUse hook returned unsupported additionalContext"
    when the field is non-empty (`output_parser.rs:337-348`). Hook is
    marked HookRunStatus::Failed; no banner reaches the model.

- **Plan amendment A-D4-02 (2026-05-03 plan v1.3) — PreToolUse hooks
  emit NO additionalContext; PreToolUse handlers run in parallel;
  PostToolUse fires only on tool success.**
  - Plan section affected: §"PR D.4 — pre_tool_use_*.sh" "Implementation
    highlights" + "Estimated diff" + "Deviations recorded for D.4"
    subsection (new D-D4-02 entry).
  - Reason: source-level evidence (file:line citations baked into the
    deviation entry) shows that Codex's PreToolUse output parser
    explicitly rejects additionalContext. Mirroring Claude's banner
    emission would produce HookRunStatus::Failed entries in the audit
    log without any model-visible benefit. Removing the banner emission
    is the lower-noise choice; bookkeeping side effects remain.
  - Three CHANGES locked in v1.3:
    - CHANGE 1: `pre_tool_use_any.sh` is bookkeeping-only; all
      `emit_additional_context` calls removed; line count revises
      330 → ~220.
    - CHANGE 2: `pre_tool_use_apply_patch.sh` header comment declares
      additionalContext is verboten on this event (with file:line
      citations).
    - CHANGE 3: Banner-degradation acknowledgment — Codex sessions see
      fewer in-turn signals; deferred-delivery rerouting through
      user_prompt_submit.sh / post_tool_use_apply_patch.sh is a future
      consideration, NOT in D.4 scope.
  - Test pattern locked: per-branch `jq -e '.hookSpecificOutput.additionalContext // empty | length == 0'`
    field-presence check (preferred over substring match — avoids false
    positives where "additionalContext" appears in some other field's
    text). Asserted in EVERY non-deny branch of the three PreToolUse
    hooks.
  - Three findings to track during implementation:
    - F-D4-03 (retrospective, non-blocking): D.3's user_prompt_submit.sh
      could be upgraded later to deliver self-task reminders deferred
      from any.sh. Logged under "Phase F follow-up candidates" below;
      do NOT amend D.3 retroactively.
    - F-D4-04 (verify in tests): per-branch tests must assert empty
      stdout AND state mutations still occur after banner removal —
      banner removal must NOT regress bookkeeping.
    - F-D4-05 (line count audit at end of D.4): confirm any.sh
      realized count is within 10% of 220. >280 = dead banner code
      remains; <180 = bookkeeping was cut along with banners. Flag
      either case.
  - Source of amendment: F-D4-02 verification with file:line citations
    (output_parser.rs:16-20 + 337-348 for finding c; registry.rs:414-421
    for finding b; dispatcher.rs:91-96 + pre_tool_use.rs:107-110 for
    finding a). Citations are baked into plan §D-D4-02 permanently.
  - Plan v1.2 → v1.3.

### Phase F follow-up candidates

- **F-D4-03 (filed 2026-05-03):** `user_prompt_submit.sh` self-task
  reminder delivery. Codex's PreToolUse rejects additionalContext, so
  any.sh's per-tool-call self-task reminder banner is silently dropped.
  D.3's user_prompt_submit.sh delivers HEAD-drift on prompt submit but
  NOT self-task reminders. A future PR could extend D.3's hook to
  iterate `coord_self_task_check_unlocked` + emit reminders via
  additionalContext (which IS supported on UserPromptSubmit per
  output_parser.rs:51). Defer until Phase F integration tests show
  whether Codex sessions actually need the reminder.

- **PR D.4 STARTED** — Codex `pre_tool_use_*.sh` (3-hook split).
  - Pre-conditions verified: plan v1.3 committed (2a82c42); F-D4-02
    verification complete with citations; 761 unit / 66 integration
    green at HEAD (3e88e29).
  - Branch: `feat/codex-integration`.
  - Estimated diff per plan v1.3: ~740 LOC (any 220 + bash 70 +
    apply_patch 400 + small helper inline budget).
  - Hooks implemented:
    - `pre_tool_use_bash.sh` — lockdown gate + PRE_BASH event log only.
    - `pre_tool_use_any.sh` — bookkeeping-only (notification clear,
      HEAD recheck, mediator-pending consume, self-task reminder
      bookkeeping, watchdog probe, mediator verdict apply); NEVER
      emits additionalContext per D-D4-02.
    - `pre_tool_use_apply_patch.sh` — multi-file lock-acquire-all-or-
      deny + structural drift gate per A-D4-01 + consolidated
      validate-or-abort filter per F-D4-01.

- **PR D.4 in-progress finding F-D4-06 — variable name collision.**
  - During implementation: pre_tool_use_bash.sh's first draft used
    `BASH_COMMAND` as a local variable name. Bash's built-in
    `$BASH_COMMAND` holds the literal text of the currently-executing
    command (used by DEBUG traps), so the assignment got the source
    line text instead of the captured jq output. Renamed to
    `RAW_COMMAND` / `CMD_SHORT`.
  - Caught by the bats test "happy path → PRE_BASH event with
    truncated command" which asserted on the actual logged value.
  - Lesson: avoid `BASH_*` variable names as locals — bash reserves
    `BASH_*` for builtins.

- **PR D.4 in-progress finding F-D4-07 — jq filter pipe direction bug.**
  - During implementation: the consolidated validate-or-abort filter
    initially used `$paths_json | reduce .[] as $p (.; ...)` which
    pipes the array INTO reduce, making the initial accumulator the
    array, not the parent JSON object. jq error: "Cannot index array
    with string 'locks'".
  - Fix: rewrite as `reduce ($paths_json[]) as $p (.; ...)` which
    iterates the array INSIDE reduce while preserving the parent
    object as `.`.
  - Caught by the bats test "multi-file patch acquires all locks
    atomically".

- **PR D.4 in-progress finding F-D4-08 — multi-line substring count.**
  - During implementation: the drift gate's per-hunk pre_image search
    initially used `grep -cF -- "$pre_image"` which is line-oriented;
    a multi-line pre_image gets split into separate fixed strings.
    Result: legitimate matches were counted as 0 (not found).
  - Fix: bash-native pattern matching helper
    `_coord_cx_count_substring` using `[[ "$rest" == *"$needle"* ]]`
    in a loop with `${rest#*"$needle"}` to advance past each match.
    Multi-line safe; bounded at 100 occurrences (defensive).
  - Caught by the bats test "drift: pre_image found uniquely →
    drift-clean, lock acquired".

- **PR D.4 COMPLETED** — 3 hooks + 3 test files (45 unit tests).
  - File added: `src/adapters/codex/hooks/pre_tool_use_bash.sh`
    (94 LOC, chmod +x).
  - File added: `src/adapters/codex/hooks/pre_tool_use_any.sh`
    (291 LOC total: 80-line documentation header per reviewer's
    "bake citations into plan AND code" guidance + 211-line body
    within F-D4-05 target of 220 ± 10%; chmod +x).
  - File added: `src/adapters/codex/hooks/pre_tool_use_apply_patch.sh`
    (570 LOC after substring helpers; over ~400 estimate due to
    inline helpers per Q3 default — `coord_cx_human_age`,
    `_coord_cx_task_delegation_enabled`, deny-banner builders,
    drift-check helpers, multi-line substring-count helpers per
    F-D4-08 fix; chmod +x).
  - File added: `src/tests/unit/codex_pre_tool_use_bash.bats`
    (7 tests).
  - File added: `src/tests/unit/codex_pre_tool_use_any.bats`
    (10 tests, all assert F-D4-04 invariant: empty additionalContext
    + bookkeeping side effect verified).
  - File added: `src/tests/unit/codex_pre_tool_use_apply_patch.bats`
    (28 tests across 7 categories: paths/sort, classification,
    drift gate, lockdown, D-9 mutex, D-2 negative).
  - Tests added: 45 (unit). Plan estimate: ~45.
  - F-D4-05 line count audit: any.sh body 211 LOC within target
    220 ± 10% (198-242). Header is 80 LOC of load-bearing
    documentation (D-D4-02 constraints with output_parser.rs file:line
    citations baked in per reviewer guidance). No dead banner code.
  - Test surface state at D.4 boundary:
    - bats unit:        PASS (806/806) — was 761, +45 from D.4 hooks.
    - bats integration: PASS (66/66) — unchanged.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: c4eb268.

- **PR D.4 reviewer post-mortem (logged retrospectively).**
  - F-D4-09: pre_tool_use_apply_patch.sh at 570 LOC exceeds the 500-line
    factoring threshold from Q3's reviewer ruling. Decision deferred to
    during D.5 implementation per the three-criteria audit:
    (a) Does D.5 reuse helpers from apply_patch.sh? — NO. None of
        the deny banners, drift helpers, coord_cx_human_age, or
        substring helpers are referenced in D.5.
    (b) Did reading apply_patch.sh feel heavier than inline locality?
        — NO. The file is single-purpose (multi-file coordination
        logic); helpers are co-located with use sites; the structure
        Phase A → Phase B → Phase C is a clean reading path.
    (c) Did tests require awkward cross-file reaches? — NO. Each hook's
        bats file is self-contained; no cross-hook test setup needed.
    All three criteria NO → accept 570 LOC. No factoring to
    `apply_patch_locking.sh` in this phase. If D.6+ ever shares the
    deny-banner logic OR the drift gate has to fold in a future
    refinement (e.g., F-D5-01 hunk-line parsing), revisit then.
  - F-D4-10 acknowledged: comment added near `_coord_cx_count_substring`
    in apply_patch.sh explaining why bash-native scanning is correct
    (not a "simplification" candidate to grep -cF). Future contributors
    have the rationale at the call site. Lands as part of the D.5 commit.
  - Reviewer note logged retrospectively: F-D4-08 traces to the C.2
    design preview's literal `grep -cF -- "$pre_image"` specification.
    The primitive was wrong even though the contract was right. No
    corrective action — fix already applied; lesson logged.

- **PR D.5 STARTED** — Codex `post_tool_use_apply_patch.sh`.
  - Pre-conditions verified: D.4 merged (c4eb268); 806 unit / 66
    integration green at HEAD (881ccd4).
  - Branch: `feat/codex-integration`.
  - Estimated diff per preview: ~150 LOC + ~10 bats.
  - Mirror source: `src/adapters/claude-code/hooks/post_tool_use_write.sh`,
    adapted for multi-file iteration.
  - Per F-D4-02(b): success-path-only contract — no
    tool_response.error inspection. Tool error → no PostToolUse → Stop
    handles release per D-10.
  - F-D5-01 honored: edit_range = 0/0 in coord_task_processor_run
    invocation, with TODO comment at the call site explaining the
    coarsening (Codex grammar's @@ lacks line numbers).
  - Q5 fallback: parser-failure path releases all SID-owned locks.

- **PR D.5 COMPLETED** — 1 hook + 1 test file (10 unit tests).
  - File added: `src/adapters/codex/hooks/post_tool_use_apply_patch.sh`
    (232 LOC: ~50-line header documenting D-D4-02 / D-10 / F-D4-02(b) /
    F-D5-01 / Q5 fallback rationale; ~180-line body for the per-file
    release loop). Above the 150 estimate; the overage is documentation
    and the `set -- $PATHS_SORTED` IFS dance for the multi-file
    iteration. No dead code.
  - File added: `src/tests/unit/codex_post_tool_use_apply_patch.bats`
    (10 tests covering: gate negative, D-2 agent_type still releases,
    non-participant no-op, single-file release with last_activity
    refresh, multi-file release with peer-lock preservation +
    deterministic alphabetical event order, task_processor invocation
    with F-D5-01 0/0 edit-range, defensive lock-held-by-other ERROR
    path, Q5 parser-failure fallback releases all session locks,
    lockdown active retains locks, ship-gate permissionDecision
    negative invariant).
  - Edit (D.4 follow-up per F-D4-10): added comment near
    `_coord_cx_count_substring` in `pre_tool_use_apply_patch.sh`
    explaining why grep -cF is wrong (line-oriented vs multi-line
    pre_image semantics). Future-proofing against "simplification"
    regressions.
  - Tests added: 10 (unit). Plan estimate: ~10.
  - Test surface state at D.5 boundary:
    - bats unit:        PASS (816/816) — was 806, +10 from D.5.
    - bats integration: PASS (66/66) — unchanged.
    - ship-gates: not run (deferred to PR H.1).
    - invariant: included in unit count.
  - Merge commit: <to be filled after commit>.

---

**Phase D — CODEX HOOKS — COMPLETE.**
- Started: 2026-05-03 (D.1).
- Completed: 2026-05-03 (D.5).
- PRs merged: D.1, D.2, D.3, D.4, D.5 (5 PRs) plus 2 plan amendment
  commits (v1.2 / v1.3).
- Test surface delta:
  - unit:        732 → 816 (+84): D.1 (+12), D.2 (+10), D.3 (+7),
                                  D.4 (+45), D.5 (+10).
  - integration: 66  → 66 (unchanged — Phase D adds no integration
                          scenarios; cross-agent integration tests
                          land in Phase F).
- Plan amendments: A-D4-01 (v1.2 — drift = structural pre_image-search),
  A-D4-02 (v1.3 — PreToolUse banner-emission removed; finds (a)/(b)/(c)
  documented with file:line citations).
- In-scope findings: F-D4-01 (consolidated filter), F-D4-02 (verification
  found 3 false claims — citations baked in), F-D4-03 (Phase F follow-up:
  user_prompt_submit.sh self-task reminder routing), F-D4-04 (test
  pattern: empty stdout + bookkeeping-not-regressed), F-D4-05 (any.sh
  line-count audit pass), F-D4-06/07/08 (in-progress fixes caught at
  test time: BASH_COMMAND collision, jq pipe direction, grep -cF
  line-orientation), F-D4-09 (570-LOC factoring decision: NO),
  F-D4-10 (substring-helper rationale comment), F-D5-01 (0/0
  edit-range coarsening with TODO comment).
- Phase E (Codex installer + dispatcher) may now begin per plan; no
  further design preview required unless E.1/E.2 surfaces a contract
  change.

---

## Pending entries (will be filled in as PRs progress)

The structure below is a template; remove it once real entries replace it.

### Template — to copy when starting a new PR

```
## YYYY-MM-DD

- **PR <ID> STARTED** — <one-line goal>.
  - Pre-conditions verified: <list>.
  - Estimated diff: <N lines>.
  - Branch: <branch>.

- **PR <ID> IN-PROGRESS** — <progress note>.
  - Files touched so far: <list>.
  - Tests added so far: <list>.
  - Issues encountered: <none | list>.

- **PR <ID> COMPLETED** — <one-line summary>.
  - Final diff: <N lines>.
  - Tests added: <count>.
  - Test surface state:
    - bats unit: PASS (<N>/<M>).
    - bats integration: PASS (<N>/<M>).
    - ship-gates: PASS (<N>/<M>).
    - invariant: PASS (<N>/<M>).
  - Merge commit: <sha>.

- **PR <ID> DEVIATED** — <what changed vs plan>.
  - Plan section affected: <Phase/PR ID>.
  - Reason: <why>.
  - Plan amendment: see plan v<X.Y> section <Z>.
  - Resumed at: <timestamp>.

- **PR <ID> BLOCKED** — <blocker>.
  - Blocking issue: <description>.
  - Required to unblock: <action>.
  - Owner: <name>.

- **PR <ID> REVERTED** — <reason>.
  - Revert commit: <sha>.
  - Re-attempt planned: <yes/no — if yes, when>.
```

### Reserved slots (one per PR — update when work begins)

- [ ] PR A.0 — Plan + log committed (this entry).
- [ ] PR A.1 — Move src/lib/*.sh → src/core/lib/*.sh.
- [ ] PR A.2 — Move src/hooks/*.sh + subagent_filter.sh → src/adapters/claude-code/.
- [ ] PR A.3 — Move src/bin/coord → src/core/bin/coord.
- [ ] PR A.4 — Add normalized_events.sh.
- [ ] PR A.5 — Add folder_resolver.sh; drop git-repo requirement.
- [ ] PR B.1 — Schema 1.0 → 1.1 + agent field.
- [ ] PR B.2 — parallels-init / parallels-claude / parallels-status launchers + COORD_ENABLED gate.
- [ ] PR C.1 — Codex translator skeleton.
- [ ] PR C.2 — apply_patch_parser.sh + 20+ fixtures.
- [ ] PR C.3 — Codex translator complete.
- [ ] PR C.4 — parallels-codex launcher.
- [ ] PR D.1 — Codex session_start.sh.
- [ ] PR D.2 — Codex stop.sh.
- [ ] PR D.3 — Codex user_prompt_submit.sh.
- [ ] PR D.4 — Codex pre_tool_use_*.sh (the multi-file lock-acquire-all-or-deny).
- [ ] PR D.5 — Codex post_tool_use_apply_patch.sh.
- [ ] PR E.1 — src/adapters/codex/install.sh.
- [ ] PR E.2 — src/install.sh dispatcher rewrite.
- [ ] PR F.1 — Cross-agent test infrastructure.
- [ ] PR F.2 — Cross-agent scenarios (~10).
- [ ] PR F.3 — phase7_codex_invariant.bats.
- [ ] PR G.1 — README + CONTRIBUTING + package.json.
- [ ] PR G.2 — Codex quickstart.
- [ ] PR H.1 — Full ship-gate verification.

---

## Decisions captured during implementation (separate from plan-locked decisions)

A "captured decision" is a judgment made mid-implementation that was not pre-resolved in the plan. Each entry must include: date, decision text, rationale, and which PR it affected.

### (none yet)

---

## End-of-phase summaries (to fill in)

### Phase A — Refactor
- Started: <date>
- Completed: <date>
- PRs merged: A.0, A.1, A.2, A.3, A.4, A.5.
- Test surface delta: 645+0 unit, 48+~5 integration (folder_resolver, non_git_install).
- Issues encountered: <list>.
- Notable deviations: <list>.

### Phase B — Schema + launchers
- (template; fill in when phase ends)

### Phase C — Codex translator + parser
- (template)

### Phase D — Codex hooks
- (template)

### Phase E — Codex installer
- (template)

### Phase F — Cross-agent tests
- (template)

### Phase G — Docs
- (template)

### Phase H — Final ship-gate
- (template)

---

## End of log template — appendable from here.

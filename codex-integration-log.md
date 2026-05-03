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
  - Merge commit: <to be filled after commit>.

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

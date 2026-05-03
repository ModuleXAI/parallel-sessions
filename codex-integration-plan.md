# Codex Integration — Implementation Plan

| Field | Value |
|---|---|
| Branch (current) | `research/codex-integration` |
| Implementation branch | TBD: `feat/codex-integration` (forked from this branch) |
| Plan version | 1.0 |
| Created | 2026-05-02 |
| Owner | SUY |
| Reference report | `codex-integration-research.md` (root) |
| Live log | `codex-integration-log.md` (root) |
| Codex source reference | `codex-ref-repo/codex/codex-rs/` |

---

## Mission

Add OpenAI Codex CLI as a second, first-class agent to the parallel-sessions coordination layer **without regressing the existing Claude Code single-agent v1 at any commit**. End state:

1. A user with only Claude Code installed gets the current v1 experience unchanged.
2. A user with only Codex CLI installed gets the same coordination capability for Codex sessions.
3. A user with both runs Claude Code sessions and Codex sessions simultaneously against the same repository folder; both register into the same `.coord/sessions.json` and arbitrate locks, drift, crashes, and cycles uniformly.
4. The system installs into any folder (git or non-git) and is invoked via dedicated launcher scripts (`parallels-claude`, `parallels-codex`); no env-var-export ritual is required from the user.

---

## Locked decisions (do not relitigate during implementation)

| ID | Decision | Source |
|---|---|---|
| D-1 | Mediator/Validator/Task-Processor backends ALWAYS spawn `claude -p`, regardless of which agent triggered them. `claude` binary is a hard dep. | OQ H8 |
| D-2 | Codex subagents are NOT filtered. Each subagent registers as its own coord session via SessionStart. No `subagent_filter` analogue for Codex. | OQ H1 + Codex source review |
| D-3 | Codex `apply_patch` payload is parsed via a custom-grammar state machine in pure bash. Pre-image extraction = ` ` + `-` lines per `@@` hunk. Multi-file patches use lock-acquire-all-or-deny atomicity. | OQ H2 + Codex source review |
| D-4 | Cost-guard counters stay per-site (mediator/validator/task_processor); NOT per-agent. Since all spawns target `claude -p`, per-site is the meaningful billing unit. | OQ H7 |
| D-5 | Folder-local install only. Drop git-repo requirement. Works in any folder. | User direction |
| D-6 | No env-var UX. Launcher scripts: `parallels-init`, `parallels-claude`, `parallels-codex`, `parallels-status`. Internally `COORD_ENABLED=1` is set by launcher; `CLAUDE_COORD=1` kept as legacy alias. | User direction |
| D-7 | Codex hook config target: `<folder>/.codex/hooks.json` (project-local). Never `~/.codex/`. The feature flag `[features] codex_hooks = true` requirement is handled at install with explicit user confirmation. | OQ H4 |
| D-8 | Schema bump 1.0 → 1.1 is purely additive. New `agent` field defaults to `"claude_code"` for legacy rows. No migration script. | OQ H6 (resolved) |
| D-9 | Codex's `permissionDecision` and `additionalContext` are MUTUALLY EXCLUSIVE in the same hook output JSON for `PreToolUse`. No emitter ever produces both in one JSON object. | Codex source `pre_tool_use.rs:396-423` |
| D-10 | Codex has no `SessionEnd`. Lock release for Codex relies on `Stop` + Watchdog. Codex SessionEnd hook is NOT registered. | Codex source `events/mod.rs` |
| D-11 | Codex `SessionStart` source enum is `Startup | Resume | Clear` (no `Compact`). Our session_start handles unknown sources via `*` fallback already; no special-case needed. | Codex source `session_start.rs:21-35` |
| D-12 | Multi-file `apply_patch` denies the entire call if ANY referenced file is held by another session. Files are locked in alphabetical order (deadlock prevention). PostToolUse releases all. | D-3 corollary |
| D-13 | The plan's PR boundaries are mandatory. Each PR leaves the v1 test surface (645 unit + 48 integration + 24 ship-gate + 19 invariant) green. CI gate enforces. | Project hygiene |

---

## Target architecture (post-refactor)

```
src/
├── core/                                       # AGENT-AGNOSTIC
│   ├── lib/                                    # 24 libs moved from src/lib/
│   │   ├── atomic_write.sh
│   │   ├── log_event.sh
│   │   ├── participant.sh
│   │   ├── lockdown.sh
│   │   ├── hash.sh
│   │   ├── head_tracking.sh
│   │   ├── state_query.sh
│   │   ├── wait_queue.sh
│   │   ├── wait_backend.sh
│   │   ├── notify_waiters.sh
│   │   ├── self_tasks.sh
│   │   ├── cycle_detection.sh
│   │   ├── critical_check.sh
│   │   ├── verdict_apply.sh
│   │   ├── watchdog.sh
│   │   ├── watchdog_cache.sh
│   │   ├── mediator_pending.sh
│   │   ├── mediator_spawn.sh
│   │   ├── validator_spawn.sh
│   │   ├── validator_cache.sh
│   │   ├── validator_prefilter.sh
│   │   ├── read_snapshots.sh
│   │   ├── task_processor.sh
│   │   ├── spawn_helper.sh
│   │   ├── cost_guards.sh
│   │   ├── coord_mediate.sh
│   │   ├── normalized_events.sh                # NEW (A.4)
│   │   ├── folder_resolver.sh                  # NEW (A.5) — replaces git-dependent coord_resolve_root
│   │   ├── MEDIATOR_REFERENCE.md
│   │   └── VALIDATOR_REFERENCE.md
│   ├── bin/
│   │   └── coord                               # moved from src/bin/coord
│   └── tests/
│       ├── unit/                               # ~24 agent-agnostic bats
│       └── helpers/
│           └── common.bash
│
├── adapters/
│   ├── claude-code/
│   │   ├── hooks/                              # 8 files moved from src/hooks/
│   │   │   ├── session_start.sh
│   │   │   ├── session_end.sh
│   │   │   ├── stop.sh
│   │   │   ├── user_prompt_submit.sh
│   │   │   ├── pre_tool_use_any.sh
│   │   │   ├── pre_tool_use_read.sh
│   │   │   ├── pre_tool_use_write.sh
│   │   │   └── post_tool_use_write.sh
│   │   ├── lib/
│   │   │   ├── translator.sh                   # NEW (A.2) — Claude → core normalized
│   │   │   └── subagent_filter.sh              # moved from src/lib/ (Claude-specific)
│   │   ├── install.sh                          # NEW (E.x) — writes .claude/settings.local.json
│   │   └── tests/
│   │       └── unit/                           # ~30 Claude-payload-coupled bats
│   │
│   └── codex/                                  # NEW (Phases C-D)
│       ├── hooks/
│       │   ├── session_start.sh                # NEW (D.1)
│       │   ├── stop.sh                         # NEW (D.2)
│       │   ├── user_prompt_submit.sh           # NEW (D.3)
│       │   ├── pre_tool_use_any.sh             # NEW (D.4) — matcher * for cross-cutting
│       │   ├── pre_tool_use_apply_patch.sh     # NEW (D.4) — matcher ^apply_patch$
│       │   ├── pre_tool_use_bash.sh            # NEW (D.4) — matcher ^Bash$
│       │   └── post_tool_use_apply_patch.sh    # NEW (D.5)
│       ├── lib/
│       │   ├── translator.sh                   # NEW (C.1, C.3)
│       │   └── apply_patch_parser.sh           # NEW (C.2) — Codex grammar parser
│       ├── install.sh                          # NEW (E.1) — writes .codex/hooks.json
│       └── tests/
│           ├── unit/                           # NEW
│           └── fixtures/
│               └── apply_patch/                # NEW — patch text fixtures
│
├── install.sh                                  # REWRITTEN (E.2) — dispatches to adapters
└── tests/
    └── integration/
        └── cross_agent/                        # NEW (F.x) — Claude+Codex e2e tests

bin/
├── parallel-sessions                           # existing Node wrapper (legacy npm)
├── parallels-init                              # NEW (B.2) — installer launcher
├── parallels-claude                            # NEW (B.2) — claude session launcher
├── parallels-codex                             # NEW (C.4) — codex session launcher
└── parallels-status                            # NEW (B.2) — alias for `coord status`
```

---

## Test surface contract (must stay green at every PR boundary)

| Suite | Count today | After Phase A | After Phase F |
|---|---|---|---|
| `bats src/tests/unit/` | 645 tests, 54 files | 645/54 (relocated) | 645 + ~80 Codex unit |
| `bats src/tests/integration/` | 48 tests, 4 files | 48/4 | 48 + ~30 cross-agent |
| `bash src/tests/manual/phase{3..7}_ship_gate.sh` | 24 scenarios | 24 | 24 + ~10 codex_ship_gate |
| `bats src/tests/unit/phase7_invariant.bats` | 19 guards | 19 | 19 + 5 codex-invariant |

**Hard rule:** No PR may merge unless ALL of the above pass. CI enforces. Each PR's acceptance criteria below restates this.

---

## Phase A — Refactor (no behavior change)

**Phase goal:** Move source tree to the `core/` + `adapters/` layout. Add the two new core libraries (`normalized_events.sh`, `folder_resolver.sh`). At the end of Phase A, the v1 Claude Code experience is functionally identical, but the file structure supports adding the Codex adapter without further core-touching.

**Phase pre-conditions:**
- Branch `feat/codex-integration` opened off `research/codex-integration`.
- All test suites green on the parent branch.
- The plan + log files exist and are committed.

**Phase exit criteria:**
- All PRs A.0 through A.5 merged.
- Test surface fully green: 645 unit + 48 integration + 24 ship-gate + 19 invariant.
- `git grep "src/lib/"` and `git grep "src/hooks/"` return zero matches outside legacy comments.
- A new test `src/core/tests/unit/folder_resolver.bats` covers non-git folder install.

### PR A.0 — Plan + log files committed (THIS PR)
- **Goal:** Land the implementation contract before any code moves.
- **Files:** `codex-integration-plan.md`, `codex-integration-log.md`.
- **Acceptance:** Files exist; log has its first entry "PR A.0: plan committed".
- **Rollback:** `git revert <commit>`.
- **Risk:** None.

### PR A.1 — Move `src/lib/*.sh` → `src/core/lib/`
- **Goal:** Relocate 24 library files to the core directory; update every consumer's `LIB_DIR` resolution.
- **Pre-conditions:** PR A.0 merged.
- **Files moved (24 .sh + 2 .md):**
  - `src/lib/atomic_write.sh` → `src/core/lib/atomic_write.sh`
  - `src/lib/log_event.sh` → `src/core/lib/log_event.sh`
  - `src/lib/participant.sh` → `src/core/lib/participant.sh`
  - `src/lib/lockdown.sh` → `src/core/lib/lockdown.sh`
  - `src/lib/hash.sh` → `src/core/lib/hash.sh`
  - `src/lib/head_tracking.sh` → `src/core/lib/head_tracking.sh`
  - `src/lib/state_query.sh` → `src/core/lib/state_query.sh`
  - `src/lib/wait_queue.sh` → `src/core/lib/wait_queue.sh`
  - `src/lib/wait_backend.sh` → `src/core/lib/wait_backend.sh`
  - `src/lib/notify_waiters.sh` → `src/core/lib/notify_waiters.sh`
  - `src/lib/self_tasks.sh` → `src/core/lib/self_tasks.sh`
  - `src/lib/cycle_detection.sh` → `src/core/lib/cycle_detection.sh`
  - `src/lib/critical_check.sh` → `src/core/lib/critical_check.sh`
  - `src/lib/verdict_apply.sh` → `src/core/lib/verdict_apply.sh`
  - `src/lib/watchdog.sh` → `src/core/lib/watchdog.sh`
  - `src/lib/watchdog_cache.sh` → `src/core/lib/watchdog_cache.sh`
  - `src/lib/mediator_pending.sh` → `src/core/lib/mediator_pending.sh`
  - `src/lib/mediator_spawn.sh` → `src/core/lib/mediator_spawn.sh`
  - `src/lib/validator_spawn.sh` → `src/core/lib/validator_spawn.sh`
  - `src/lib/validator_cache.sh` → `src/core/lib/validator_cache.sh`
  - `src/lib/validator_prefilter.sh` → `src/core/lib/validator_prefilter.sh`
  - `src/lib/read_snapshots.sh` → `src/core/lib/read_snapshots.sh`
  - `src/lib/task_processor.sh` → `src/core/lib/task_processor.sh`
  - `src/lib/spawn_helper.sh` → `src/core/lib/spawn_helper.sh`
  - `src/lib/cost_guards.sh` → `src/core/lib/cost_guards.sh`
  - `src/lib/coord_mediate.sh` → `src/core/lib/coord_mediate.sh`
  - `src/lib/MEDIATOR_REFERENCE.md` → `src/core/lib/MEDIATOR_REFERENCE.md`
  - `src/lib/VALIDATOR_REFERENCE.md` → `src/core/lib/VALIDATOR_REFERENCE.md`
- **AMENDED 2026-05-02 (plan v1.1):** Files moved now include `subagent_filter.sh`. See deviation D-A1-01 below.
- **NOT moved:** (none — see D-A1-01)
- **Files updated (consumer paths):**
  - `src/install.sh`:
    - Line 201: `cp -f "$SELF_DIR"/lib/*.sh "$COORD_DIR/lib/"` — change source to `"$SELF_DIR"/core/lib/*.sh`.
    - Lines 217-256: `MEDIATOR_REFERENCE.md` and `VALIDATOR_REFERENCE.md` source paths.
    - Note: do NOT change destination — `.coord/lib/` stays the flat runtime location; only the source path in the repo changes.
  - `src/hooks/*.sh`: LIB_DIR uses **dual-fallback resolution** (try `../core/lib` first; fall back to `../lib`). Source-tree tests find `../core/lib/`; installed `.coord/hooks/` finds `../lib/` (flat). See D-A1-02.
  - `src/bin/coord:27`: same dual-fallback resolution. Source: `src/bin/../core/lib/` exists. Installed: `.coord/bin/../lib/` exists. See D-A1-02.
  - `src/tests/**/*.bats` + `src/tests/manual/linux_probe.sh` + `src/tests/concurrent_smoke.sh` + fixture timeline scripts: any literal `$SRC_ROOT/lib/` or `/work/src/lib/` → `$SRC_ROOT/core/lib/` / `/work/src/core/lib/`. `$COORD_DIR/lib/` references are RUNTIME (installed location) and do NOT change.
- **Implementation steps:**
  1. Move every file in `src/lib/` to `src/core/lib/` via `git mv` (per-file, so directory deletion is clean).
  2. Update `src/install.sh:201` source glob to `"$SELF_DIR"/core/lib/*.sh`. Update MEDIATOR/VALIDATOR_REFERENCE.md source paths (lines 216-255 area).
  3. Update each `src/hooks/*.sh` LIB_DIR to dual-fallback resolution.
  4. Update `src/bin/coord:27` LIB_DIR to dual-fallback resolution; update comment at line 24.
  5. Update tests: sed `$SRC_ROOT/lib/` → `$SRC_ROOT/core/lib/` across all *.bats and helper scripts.
  6. Update `src/tests/manual/linux_probe.sh:186` `/work/src/lib/wait_backend.sh` → `/work/src/core/lib/wait_backend.sh`.
  7. Run `bash -n` syntax check on every moved file + every consumer touched.
  8. Run full test suite; expect ZERO failures.
- **Tests:** No new tests. Existing 645 unit + 48 integration must all still pass with new paths.
- **Verification commands:**
  ```bash
  bats src/tests/unit
  bats src/tests/integration
  ```
  (Ship-gates are gitignored maintainer fixtures; deferred to PR H.1.)
- **Acceptance criteria:** Both bats commands exit 0. `git grep -nE '\$SRC_ROOT/lib/|/work/src/lib/' src/tests/` returns nothing. `git grep -n 'src/lib/' src/` returns only the comment in `src/bin/coord` (now updated to read `src/core/lib/`) — i.e., zero executable refs to old path.
- **Rollback:** `git revert <commit-of-A.1>` restores `src/lib/`.
- **Risk:** Medium-High (revised). ~28 file moves + ~200 path updates across hooks/install/bin/tests.
- **Dependencies:** A.0.
- **Estimated diff:** ~250 lines of path-updates (revised from ~30; see D-A1-03).

#### Deviations recorded for A.1

**D-A1-01 (2026-05-02): `subagent_filter.sh` moves with the rest, not "stays put".**
*Rule changed:* From "subagent_filter.sh stays in src/lib/ until A.2" to "subagent_filter.sh moves to src/core/lib/ in A.1; A.2 moves it again to its final adapter location."
*Why:* Plan v1.0 left `subagent_filter.sh` in `src/lib/` to "stay put for now", but tests execute hooks directly from `$SRC_ROOT/hooks/`, and at runtime the hook resolves `LIB_DIR=$HOOK_DIR/../lib`. With the rest of libs at `src/core/lib/`, the hook would need TWO LIB_DIRs (one for subagent_filter.sh, one for everything else) — adding hacky environment-detection logic to every hook. Moving the file twice in git history (lib → core/lib in A.1, core/lib → adapters/claude-code in A.2) is preserved by `git log --follow` and is far cleaner than dual-LIB_DIR logic.
*Impact:* `src/lib/` directory is fully deleted in A.1. `src/tests/unit/subagent_filter.bats:7` updates to reference `$SRC_ROOT/core/lib/subagent_filter.sh`.

**D-A1-02 (2026-05-02): `bin/coord` and hooks use dual-fallback LIB_DIR resolution, not a single relative path.**
*Rule changed:* From "set LIB_DIR to `../core/lib`" to "try `../core/lib` first, fall back to `../lib`".
*Why:* `src/bin/coord` is `cp`'d to `.coord/bin/coord` at install time (install.sh:211). The installer flattens libs into `.coord/lib/` (NOT `.coord/core/lib/`). If we hard-code `../core/lib`, the installed CLI breaks because `.coord/bin/../core/lib/` does not exist. Dual fallback resolves correctly in both layouts: source tree (src/bin → src/core/lib exists), installed (.coord/bin → .coord/lib exists). Same logic applies to hooks (`src/hooks/` test execution vs `.coord/hooks/` installed).
*Impact:* Each hook + bin/coord changes one LIB_DIR= line.

**D-A1-03 (2026-05-02): Test surface scope underestimated by ~6×.**
*Rule changed:* From "~30 lines of path-updates" to "~250 lines across ~43 test files".
*Why:* Plan v1.0 prescribed `grep -rn 'src/lib/' src/tests/` to find updates, which catches only the literal `src/lib/` substring. Real tests use `$SRC_ROOT/lib/X.sh` (variable interpolation), which that grep misses. Actual count: 185 occurrences across 43 .bats files plus a few helpers. Mechanical sed; no architectural change.
*Impact:* Risk and diff-size estimates revised upward (Medium → Medium-High; 30 → 250 lines).

### PR A.2 — Move `src/hooks/*.sh` → `src/adapters/claude-code/hooks/`; move `subagent_filter.sh`
- **Goal:** Relocate 8 Claude hook scripts under `adapters/claude-code/`; move the Claude-specific `subagent_filter.sh` lib alongside them; update install.sh and tests.
- **Pre-conditions:** A.1 merged.
- **Files moved (8 hooks + 1 lib):**
  - `src/hooks/session_start.sh` → `src/adapters/claude-code/hooks/session_start.sh`
  - `src/hooks/session_end.sh` → `src/adapters/claude-code/hooks/session_end.sh`
  - `src/hooks/stop.sh` → `src/adapters/claude-code/hooks/stop.sh`
  - `src/hooks/user_prompt_submit.sh` → `src/adapters/claude-code/hooks/user_prompt_submit.sh`
  - `src/hooks/pre_tool_use_any.sh` → `src/adapters/claude-code/hooks/pre_tool_use_any.sh`
  - `src/hooks/pre_tool_use_read.sh` → `src/adapters/claude-code/hooks/pre_tool_use_read.sh`
  - `src/hooks/pre_tool_use_write.sh` → `src/adapters/claude-code/hooks/pre_tool_use_write.sh`
  - `src/hooks/post_tool_use_write.sh` → `src/adapters/claude-code/hooks/post_tool_use_write.sh`
  - `src/lib/subagent_filter.sh` → `src/adapters/claude-code/lib/subagent_filter.sh`
- **Files updated:**
  - Each moved hook's `LIB_DIR=` line:
    - From: `LIB_DIR="$(cd "$HOOK_DIR/../core/lib" && pwd)"`
    - To: `CORE_LIB_DIR="$(cd "$HOOK_DIR/../../../core/lib" && pwd)"` and `ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"`
    - Each `. "$LIB_DIR/<libname>"` becomes `. "$CORE_LIB_DIR/<libname>"` for core libs; `. "$ADAPTER_LIB_DIR/subagent_filter.sh"` for the adapter lib.
  - `src/install.sh:202` `cp -f "$SELF_DIR"/hooks/*.sh "$COORD_DIR/hooks/"` → `"$SELF_DIR"/adapters/claude-code/hooks/*.sh`.
  - Tests in `src/tests/unit/*.bats` that reference `$SRC_ROOT/hooks/...`: update to `$SRC_ROOT/adapters/claude-code/hooks/...`.
- **Implementation steps:**
  1. `git mv src/hooks src/adapters/claude-code/hooks` (after creating `src/adapters/claude-code/`).
  2. `git mv src/lib/subagent_filter.sh src/adapters/claude-code/lib/subagent_filter.sh` (create dir first).
  3. Edit each hook's lib resolution as above.
  4. Update `install.sh` cp paths.
  5. Update bats `SRC_ROOT` resolutions.
  6. Verify `bash -n` on every hook.
  7. Run full test suite.
- **Tests:** No new tests. All 645 unit + 48 integration + 24 ship-gate + 19 invariant must pass.
- **Acceptance criteria:** Same as A.1. `git grep -l 'src/hooks/'` returns only doc/comment files.
- **Rollback:** `git revert`.
- **Risk:** Medium-high. 9 file moves + ~30 reference updates + dual-LIB-DIR pattern in 8 hooks.
- **Dependencies:** A.1.
- **Estimated diff:** ~80 lines (mostly path updates).

### PR A.3 — Move `src/bin/coord` → `src/core/bin/coord`
- **Goal:** Relocate the coord CLI to `core/bin/`. CLI is agent-agnostic.
- **Pre-conditions:** A.2 merged.
- **Files moved:** `src/bin/coord` → `src/core/bin/coord`.
- **Files updated:**
  - `src/install.sh:210-212`: `[ -f "$SELF_DIR/bin/coord" ]` and `cp -f "$SELF_DIR/bin/coord" "$COORD_DIR/bin/coord"` — update both source paths to `"$SELF_DIR/core/bin/coord"`.
  - `bin/parallel-sessions:79`: `const coordPath = path.join(SRC_ROOT, 'bin', 'coord');` → `path.join(SRC_ROOT, 'core', 'bin', 'coord')`.
- **Implementation steps:**
  1. `git mv src/bin/coord src/core/bin/coord`.
  2. Update install.sh + bin/parallel-sessions paths.
  3. Run full test suite (specifically `coord_*` bats files).
- **Tests:** Existing `coord_status.bats`, `coord_health.bats`, `coord_mediate_cli.bats`, `coord_self_delegate.bats`, `coord_task_open.bats`, `coord_wait.bats` must still pass.
- **Acceptance criteria:** Full test suite green.
- **Rollback:** `git revert`.
- **Risk:** Low. 1 file move + 2 reference updates.
- **Dependencies:** A.1, A.2.
- **Estimated diff:** ~5 lines.

### PR A.4 — Add `src/core/lib/normalized_events.sh`
- **Goal:** Land the normalized-event constants without consumers. Acts as a forward-declaration that adapters will use in Phase C/D.
- **Pre-conditions:** A.3 merged.
- **Files added:** `src/core/lib/normalized_events.sh` (new file).
- **File contents (skeleton):**
  ```bash
  #!/usr/bin/env bash
  # normalized_events.sh — abstract event-type constants used by core lib
  # functions and produced by adapter translator.sh files.
  #
  # Adapters translate their agent's hook event names + tool names into one
  # of these constants and pass the value to core lib functions where
  # behavior depends on event type. This decouples core from agent-specific
  # vocabulary.
  
  # Lifecycle events
  COORD_EVENT_SESSION_START=SESSION_START
  COORD_EVENT_SESSION_END=SESSION_END           # Claude only; Codex emits no SessionEnd
  COORD_EVENT_STOP=STOP
  COORD_EVENT_PROMPT_SUBMIT=PROMPT_SUBMIT
  
  # Tool-call events
  COORD_EVENT_PRE_TOOL_ANY=PRE_TOOL_ANY         # cross-cutting (matcher *)
  COORD_EVENT_PRE_FILE_READ=PRE_FILE_READ        # Claude Read; Codex has no equivalent
  COORD_EVENT_PRE_FILE_WRITE=PRE_FILE_WRITE      # Claude Write|Edit|NotebookEdit OR Codex apply_patch
  COORD_EVENT_POST_FILE_WRITE=POST_FILE_WRITE
  COORD_EVENT_PRE_BASH=PRE_BASH
  COORD_EVENT_POST_BASH=POST_BASH
  COORD_EVENT_PERMISSION_REQUEST=PERMISSION_REQUEST  # Codex-only; future use
  
  # Sentinel for unknown / unmapped
  COORD_EVENT_UNKNOWN=UNKNOWN
  ```
- **Implementation steps:**
  1. Write the file.
  2. `bash -n src/core/lib/normalized_events.sh`.
  3. Add a unit test `src/core/tests/unit/normalized_events.bats` asserting all constants are defined.
- **Tests:** New `src/core/tests/unit/normalized_events.bats` (1-2 tests).
- **Acceptance criteria:** Full test suite + new test pass.
- **Rollback:** `git rm src/core/lib/normalized_events.sh && git rm src/core/tests/unit/normalized_events.bats`.
- **Risk:** None.
- **Dependencies:** A.3.
- **Estimated diff:** ~30 lines.

### PR A.5 — Add `src/core/lib/folder_resolver.sh`; replace `coord_resolve_root` everywhere
- **Goal:** Drop the git-repo requirement. Resolve `.coord/` from any folder.
- **Pre-conditions:** A.4 merged.
- **Files added:** `src/core/lib/folder_resolver.sh`.
- **Files updated (consumer sites — replace inline `coord_resolve_root`):**
  - `src/install.sh:73-76` (REPO_ROOT detection).
  - `src/adapters/claude-code/hooks/session_start.sh:47-62` (`coord_resolve_root` function).
  - `src/adapters/claude-code/hooks/session_end.sh:52-63`.
  - `src/adapters/claude-code/hooks/stop.sh:61-72`.
  - `src/adapters/claude-code/hooks/user_prompt_submit.sh:42-53`.
  - `src/adapters/claude-code/hooks/pre_tool_use_any.sh:57-68`.
  - `src/adapters/claude-code/hooks/pre_tool_use_read.sh:49-60`.
  - `src/adapters/claude-code/hooks/pre_tool_use_write.sh:82-93`.
  - `src/adapters/claude-code/hooks/post_tool_use_write.sh:63-74`.
  - `bin/parallel-sessions:55-69` (Node-side git check).
- **Resolution algorithm (per D-5):**
  ```bash
  coord_resolve_root() {
    # 1. COORD_DIR env (highest precedence)
    if [ -n "${COORD_DIR:-}" ] && [ -d "$COORD_DIR" ]; then
      printf '%s\n' "$COORD_DIR"; return 0
    fi
    # 2. Walk up from cwd looking for .coord/
    local cur="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      if [ -d "$cur/.coord" ]; then
        printf '%s/.coord\n' "$cur"; return 0
      fi
      cur=$(dirname "$cur")
    done
    # 3. Walk up from this script's location looking for .coord/
    local script_dir="${BASH_SOURCE[1]%/*}"
    cur="$script_dir"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      if [ -d "$cur/.coord" ]; then
        printf '%s/.coord\n' "$cur"; return 0
      fi
      cur=$(dirname "$cur")
    done
    # 4. Legacy CLAUDE_PROJECT_DIR
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}/.coord" ]; then
      printf '%s/.coord\n' "${CLAUDE_PROJECT_DIR}"; return 0
    fi
    # 5. git rev-parse (LAST resort, optional)
    local git_root
    git_root=$(git rev-parse --show-toplevel 2>/dev/null) || git_root=""
    if [ -n "$git_root" ] && [ -d "$git_root/.coord" ]; then
      printf '%s/.coord\n' "$git_root"; return 0
    fi
    return 1
  }
  ```
- **Installer change (`src/install.sh:73-76`):** replace `if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then die "..."; fi` with:
  ```bash
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="$PWD"
  say "install root: $REPO_ROOT"
  if [ ! -d "$REPO_ROOT/.git" ] && [ "$YES" != 1 ]; then
    say "Note: not in a git repo. Installing into '$REPO_ROOT'."
    say "      .coord/ state lives there. Re-run with --yes to skip this prompt."
    printf 'Continue? (y/n): '
    read -r ans
    [ "$ans" = "y" ] || die "install aborted"
  fi
  ```
- **`.gitignore` update (`src/install.sh:450-459`):** wrap in `if [ -f "$REPO_ROOT/.gitignore" ] || [ -d "$REPO_ROOT/.git" ]; then ... fi` so non-git folders skip the entries entirely.
- **Implementation steps:**
  1. Write `folder_resolver.sh` with `coord_resolve_root` function.
  2. Source it from every hook + remove inline definitions (8 hooks × ~16 lines removed each).
  3. Update install.sh REPO_ROOT detection.
  4. Update install.sh gitignore_entries with the conditional.
  5. Update `bin/parallel-sessions` to remove the git check (or downgrade to a warning).
  6. Add new test: `src/core/tests/unit/folder_resolver.bats` exercising:
     - cwd-walk-up finds `.coord/` in parent dir.
     - script-walk-up finds `.coord/` when invoked from outside.
     - non-git folder install + run works end-to-end (creates `.coord/`, registers, releases).
  7. Run full test surface.
- **Tests:**
  - New `src/core/tests/unit/folder_resolver.bats` (~5 tests).
  - New `src/core/tests/integration/non_git_install.bats` (~3 tests covering full install + smoke in a `mktemp -d` outside any git tree).
  - All existing 645 unit + 48 integration + 24 ship-gate + 19 invariant tests pass.
- **Verification commands:**
  ```bash
  # Existing surface
  bats src/tests/unit && bats src/tests/integration
  bash src/tests/manual/phase{3,4,5,6,7}_ship_gate.sh
  # New
  bats src/core/tests/unit/folder_resolver.bats
  bats src/core/tests/integration/non_git_install.bats
  ```
- **Acceptance criteria:** All commands exit 0. `git grep "git rev-parse --show-toplevel"` returns only the fallback site in `folder_resolver.sh` and `head_tracking.sh` (the latter still uses git for HEAD-detection — that stays).
- **Rollback:** Single `git revert`.
- **Risk:** High. Touches every hook + installer. The hidden risk is the script-location walk-up on macOS where `.coord/` may sit on a different filesystem than `BASH_SOURCE`.
- **Dependencies:** A.4.
- **Estimated diff:** ~150 lines (new file + replace inline blocks across 8 hooks).

---

## Phase B — Schema extension + launcher scripts

**Phase goal:** Bump schema to 1.1 with the additive `agent` field. Provide the four launcher scripts (`parallels-init`, `parallels-claude`, `parallels-status`; `parallels-codex` lands in C.4) so the user-facing UX is launcher-driven.

**Phase exit criteria:**
- `.coord/sessions.json` template includes `schema_version: "1.1"`.
- New session rows from claude-code adapter carry `agent: "claude_code"`.
- `parallels-init` works (replaces `bash src/install.sh`).
- `parallels-claude` works (replaces `export CLAUDE_COORD=1; claude`).
- `parallels-status` works (alias for `coord status`).
- All readers tolerate sessions without `agent` field (default to `"claude_code"`).
- Tests cover both new-style and legacy-style sessions.

### PR B.1 — Schema bump 1.0 → 1.1; add `agent` field
- **Goal:** Mark every session row with the agent that produced it. Keeps the door open for cross-agent metadata.
- **Pre-conditions:** Phase A complete.
- **Files updated:**
  - `src/core/lib/atomic_write.sh:56-69` (`coord_state_empty_template`): bump `schema_version` to `1.1`.
  - `src/core/lib/atomic_write.sh` line that determines schema_version in template (also `state_query.sh:26`).
  - `src/core/bin/coord:50` (status display): reading `.schema_version`.
  - `src/install.sh:263` `printf '1.0\n' > "$COORD_DIR/schema_version"` → `1.1`.
  - `src/install.sh:269` `"schema_version": "1.0"` (config.json) → `1.1`.
  - `src/adapters/claude-code/hooks/session_start.sh`: every FILTER jq template (lines 162-171, 177-186, 226-235) — add `agent: "claude_code"` to the `.sessions[$sid] = {...}` literal.
- **Reader-side changes (defaults):**
  - Anywhere that reads `.sessions[<sid>].agent`, use `// "claude_code"` fallback. Sites:
    - `src/core/bin/coord` `cmd_status` — when listing sessions, show agent.
    - `src/core/lib/watchdog.sh` ambient suspicion — could include agent in event payload.
    - `src/core/lib/notify_waiters.sh` deny banner — currently uses `${holder:0:8}`; add agent label.
- **Migration:** None. Legacy 1.0 rows without `agent` are read as `"claude_code"` via the fallback. New rows are written as 1.1.
- **Implementation steps:**
  1. Edit template + writer.
  2. Edit each session_start FILTER.
  3. Add `// "claude_code"` defaults at every reader.
  4. Add bats test asserting:
     - New SessionStart writes `agent: "claude_code"`.
     - A legacy-shaped sessions.json (without `agent`) can be read; defaults to `"claude_code"`.
     - `coord status` shows the agent column.
  5. Run full test surface.
- **Tests:**
  - New `src/core/tests/unit/schema_v1_1.bats` (~5 tests).
  - All existing tests pass.
- **Acceptance criteria:** Tests green. Manual smoke: `bash src/install.sh --repair` then start a coord session; `cat .coord/sessions.json | jq '.sessions[].agent'` shows `"claude_code"`.
- **Rollback:** `git revert`. The 1.1 sessions are still readable as 1.0 because `agent` is additive.
- **Risk:** Low. Additive field; legacy-tolerant readers.
- **Dependencies:** Phase A.
- **Estimated diff:** ~50 lines.

### PR B.2 — Launcher scripts: `parallels-init`, `parallels-claude`, `parallels-status`; introduce `COORD_ENABLED` participation gate
- **Goal:** Replace env-var-export UX with launcher scripts. Add `COORD_ENABLED=1` as canonical participation flag; keep `CLAUDE_COORD=1` as legacy.
- **Pre-conditions:** B.1 merged.
- **Files added:**
  - `bin/parallels-init` (new bash script).
  - `bin/parallels-claude` (new bash script).
  - `bin/parallels-status` (new bash script).
- **Files updated:**
  - Every hook's participation gate at the top:
    - From: `[ "${CLAUDE_COORD:-}" != "1" ] && exit 0`
    - To: `[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0`
  - `package.json:5-6`: add the three new bin entries.
- **`bin/parallels-init` content:**
  ```bash
  #!/usr/bin/env bash
  # parallels-init — install/repair/uninstall coord into the current folder.
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec bash "$SCRIPT_DIR/../src/install.sh" "$@"
  ```
- **`bin/parallels-claude` content:**
  ```bash
  #!/usr/bin/env bash
  # parallels-claude — start a Claude Code session with coord coordination active.
  set -euo pipefail
  if [ ! -d "$PWD/.coord" ] && ! coord_root=$(bash -c '
    cur="$PWD"; while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      [ -d "$cur/.coord" ] && { echo "$cur"; exit 0; }; cur=$(dirname "$cur");
    done; exit 1'); then
    printf 'parallels-claude: no .coord/ found from %s upward.\n' "$PWD" >&2
    printf '                  Run `parallels-init` first.\n' >&2
    exit 2
  fi
  if ! command -v claude >/dev/null 2>&1; then
    printf 'parallels-claude: `claude` binary not on PATH.\n' >&2
    exit 3
  fi
  exec env COORD_ENABLED=1 claude "$@"
  ```
- **`bin/parallels-status` content:**
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec bash "$SCRIPT_DIR/../src/core/bin/coord" status "$@"
  ```
- **Implementation steps:**
  1. Write the three scripts; `chmod +x bin/parallels-*`.
  2. Update each hook's participation gate (8 hooks × 1 line each).
  3. Update `package.json` `bin` map.
  4. Add tests:
     - `src/core/tests/integration/launcher_parallels_init.bats` — runs `bin/parallels-init` in a tempdir, verifies install.
     - `src/core/tests/integration/launcher_parallels_claude.bats` — verifies env passing (uses a fake claude binary on PATH that prints `COORD_ENABLED`).
     - `src/core/tests/integration/launcher_parallels_status.bats`.
     - `src/core/tests/unit/coord_enabled_legacy.bats` — verify `CLAUDE_COORD=1` still works as legacy alias.
  5. Run full test surface.
- **Tests:** ~8 new tests; all existing pass (existing tests still set `CLAUDE_COORD=1` — works via legacy alias).
- **Acceptance criteria:** Tests green; manual smoke: `bin/parallels-init` then `bin/parallels-claude` (with a stub claude binary).
- **Rollback:** `git revert` — reverting restores env-only flow but doesn't break tests (they use legacy var).
- **Risk:** Low-medium. Touches all hooks but additively (the new gate accepts both new and old env vars).
- **Dependencies:** B.1.
- **Estimated diff:** ~80 lines (3 new scripts + 8 one-line hook updates + tests).

---

## Phase C — Codex translator + apply_patch parser

**Phase goal:** Build the two new Codex-side libraries that hooks will use. No hooks fire yet; just the translator + parser ready to be consumed in Phase D.

**Phase exit criteria:**
- `src/adapters/codex/lib/translator.sh` provides the full adapter contract from the research report Section F.
- `src/adapters/codex/lib/apply_patch_parser.sh` parses every fixture under `codex-ref-repo/codex/codex-rs/apply-patch/tests/fixtures/scenarios/` correctly.
- ~20 fixture-driven unit tests cover the parser.
- `parallels-codex` launcher is wired (pre-flight checks for `codex` binary, `.codex/hooks.json` registration is checked, exec'd with `COORD_ENABLED=1`).

### PR C.1 — `src/adapters/codex/lib/translator.sh` skeleton
- **Goal:** Land the translator file with all function signatures + minimal implementations. Subsequent PRs fill in the logic.
- **Pre-conditions:** Phase B complete.
- **Files added:** `src/adapters/codex/lib/translator.sh`, `src/adapters/codex/tests/unit/translator_skeleton.bats`.
- **Functions defined (all stubs initially returning empty / rc=1):**
  - `coord_cx_translate_event <hook_event_name> <tool_name>` → core event constant
  - `coord_cx_extract_session_id <input_json>` → string
  - `coord_cx_extract_cwd <input_json>` → string
  - `coord_cx_extract_source <input_json>` → `startup|resume|clear`
  - `coord_cx_extract_prompt <input_json>` → string
  - `coord_cx_extract_tool_name <input_json>` → string
  - `coord_cx_extract_tool_input <input_json>` → JSON value
  - `coord_cx_extract_tool_use_id <input_json>` → string
  - `coord_cx_extract_turn_id <input_json>` → string
  - `coord_cx_extract_permission_mode <input_json>` → string
  - `coord_cx_extract_subagent <input_json>` → rc 1 (always; per D-2)
  - `coord_cx_emit_deny <reason> <hook_event_name>` → JSON to stdout
  - `coord_cx_emit_additional_context <text> <hook_event_name>` → JSON to stdout
  - `coord_cx_emit_permission_request_decision <allow|deny> [<message>]` → JSON to stdout
- **Test:** Each function defined; calling with no args returns rc=1 silently.
- **Acceptance:** File parses (`bash -n`); test passes.
- **Risk:** None.
- **Dependencies:** Phase B.
- **Estimated diff:** ~150 lines.

### PR C.2 — `src/adapters/codex/lib/apply_patch_parser.sh` (the big one)
- **Goal:** Implement Codex's apply_patch grammar parser per the grammar at `codex-rs/tools/src/apply_patch_tool.rs:50-72`. Pure bash 3.2 + jq state machine.
- **Pre-conditions:** C.1 merged.
- **Files added:**
  - `src/adapters/codex/lib/apply_patch_parser.sh`
  - `src/adapters/codex/tests/unit/apply_patch_parser.bats`
  - `src/adapters/codex/tests/fixtures/apply_patch/` (20+ patch text files copied verbatim from `codex-ref-repo/codex/codex-rs/apply-patch/tests/fixtures/scenarios/`).
- **Functions:**
  - `coord_cx_apply_patch_paths <patch_text>` → newline-separated absolute file paths (resolved against `cwd`).
  - `coord_cx_apply_patch_operations <patch_text>` → TSV: `<op>\t<path>\t<move_to_or_empty>` per line; op ∈ `add|delete|update`.
  - `coord_cx_apply_patch_hunks <patch_text> <path>` → JSON array of hunks for that path; each hunk has `header`, `pre_lines` (array), `post_lines` (array), `start_line` (best-effort), `end_line`.
  - `coord_cx_apply_patch_pre_image <patch_text> <path>` → reconstructed pre-image text (` ` + `-` lines, joined). Returns empty for Add/Delete operations.
  - `coord_cx_apply_patch_pre_image_hash <patch_text> <path>` → sha256 of pre_image (hex).
  - `coord_cx_apply_patch_edit_range <patch_text> <path>` → `<start>\t<end>` line range covered by the operation. Best-effort from `@@` headers; `0\t0` if not parseable.
- **Implementation strategy:** state machine with these states:
  - `OUTSIDE` — before `*** Begin Patch`
  - `INSIDE` — between Begin and End, looking for `*** {Add|Delete|Update} File:`
  - `IN_ADDFILE` — after `*** Add File:`, accumulating `+` lines
  - `IN_UPDATEFILE` — after `*** Update File:`, looking for `@@` or `*** Move to:` or new `*** ... File:` or `*** End Patch`
  - `IN_HUNK` — after `@@`, accumulating lines until next `@@` or `*** ... File:` or `*** End Patch` or `*** End of File`
  - `END` — after `*** End Patch`
- **Edge cases to test:**
  - Whitespace-padded begin/end markers (fixture 018).
  - Pure-addition update chunk (fixture 016) — only `+` lines, no `-` or context.
  - Empty hunk rejection (fixture 008).
  - Invalid hunk header rejection (fixture 013).
  - Multi-chunk in single file (fixture 003).
  - Multiple operations (Add + Delete + Update) in one patch (fixture 002).
  - Move with rename (fixture 004).
  - Whitespace-padded hunk header (fixture 017).
  - Unicode content (fixture 019).
  - File deletion (fixture 020).
  - Pure-addition (file creation) (fixture 001).
- **Tests (~20 fixture-driven bats tests):** Each test loads a fixture, runs the parser function, compares against an expected output file.
- **Acceptance:** All fixtures parse correctly. Negative fixtures (rejects_*) detect their syntactic error and return rc != 0.
- **Risk:** Medium. Parser correctness is critical. Mitigated by fixture coverage.
- **Dependencies:** C.1.
- **Estimated diff:** ~400 lines (parser) + ~200 lines (tests + fixtures).

#### Deviations recorded for C.2

**D-C2-01 (2026-05-03): Add 4 adversarial fixtures (category I) covering literal control-marker text in hunk bodies.**
*Rule changed:* From "fixtures 001-022 from codex-ref-repo" to "14 verbatim from upstream + 10 hand-rolled including 4 adversarial under fixtures 105-108".
*Why:* Without adversarial fixtures, the state machine's prefix-matching guarantee — that `*** ...` and `@@` are only recognized as control markers when at the start of a line in the right state — is documented but not tested. A model emitting `+@@ literal text` inside an Add File body would silently corrupt the parse. Approved by user verification on the C.2 design preview.
*Impact:* +4 fixtures (105 `at-in-add-line`, 106 `stars-in-add-line`, 107 `crlf`, 108 `trailing-whitespace-end-patch`). All 4 PASS.

### PR C.3 — Translator complete (uses parser + adapter contract)
- **Goal:** Fill in every translator function to its full contract.
- **Pre-conditions:** C.2 merged.
- **Files updated:** `src/adapters/codex/lib/translator.sh` (replace stubs with implementations).
- **Key implementations:**
  - `coord_cx_translate_event "PreToolUse" "Bash"` → `PRE_BASH`
  - `coord_cx_translate_event "PreToolUse" "apply_patch"` → `PRE_FILE_WRITE`
  - `coord_cx_translate_event "PreToolUse" "*"` (matcher *) → `PRE_TOOL_ANY`
  - `coord_cx_translate_event "PostToolUse" "apply_patch"` → `POST_FILE_WRITE`
  - `coord_cx_translate_event "PermissionRequest" *` → `PERMISSION_REQUEST`
  - `coord_cx_translate_event "SessionStart" *` → `SESSION_START`
  - `coord_cx_translate_event "Stop" *` → `STOP`
  - `coord_cx_translate_event "UserPromptSubmit" *` → `PROMPT_SUBMIT`
  - `coord_cx_extract_file_paths <input_json>` → for `apply_patch`, sources `tool_input.command` and runs through `apply_patch_parser.sh`. For `Bash`, returns empty (no file ops).
  - `coord_cx_emit_deny`: produces `{hookSpecificOutput: {hookEventName, permissionDecision: "deny", permissionDecisionReason: $reason}}` per D-9.
  - `coord_cx_emit_additional_context`: produces `{hookSpecificOutput: {hookEventName, additionalContext: $text}}` per D-9.
  - `coord_cx_emit_permission_request_decision`: produces `{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: { behavior: "allow|deny", message?: ... }}}`.
- **Tests:** Per-function bats with hand-crafted Codex stdin JSON fixtures. ~25 tests.
- **Acceptance:** All translator tests pass; all parser tests still pass; full v1 surface still green.
- **Risk:** Low (tests are hermetic).
- **Dependencies:** C.2.
- **Estimated diff:** ~250 lines.

### PR C.4 — `bin/parallels-codex` launcher
- **Goal:** Mirror `parallels-claude` for the codex binary.
- **Pre-conditions:** C.3 merged.
- **Files added:** `bin/parallels-codex`.
- **Content:** identical to `parallels-claude` except `claude` → `codex`. Pre-flight checks `.codex/hooks.json` exists.
- **Test:** `src/core/tests/integration/launcher_parallels_codex.bats` (uses a fake `codex` binary stub).
- **Acceptance:** Test green.
- **Risk:** None.
- **Dependencies:** C.3.
- **Estimated diff:** ~30 lines.

---

## Phase D — Codex hooks (the actual integration surface)

**Phase goal:** Implement every Codex hook entry point. End of Phase D: a Codex session can register, hold locks, detect drift via apply_patch pre-image, escalate to Mediator, recover from crashes via Watchdog. Cross-agent semantics work (a Codex session denies a Claude write and vice versa).

**Phase exit criteria:**
- All 7 Codex hooks under `src/adapters/codex/hooks/` are functional.
- A Codex session integration test fixture demonstrates: register → write → release → resume → end.
- A cross-agent test fixture demonstrates: Claude lock + Codex deny.

### PR D.1 — `src/adapters/codex/hooks/session_start.sh`
- **Goal:** Translate Codex SessionStart, register the session into `.coord/sessions.json` with `agent: "codex"`.
- **Pre-conditions:** Phase C complete.
- **Files added:** the hook + its bats unit test.
- **Implementation:** Mirror `src/adapters/claude-code/hooks/session_start.sh` but use the Codex translator. Source order:
  ```
  source $CORE_LIB_DIR/atomic_write.sh
  source $CORE_LIB_DIR/log_event.sh
  source $CORE_LIB_DIR/folder_resolver.sh
  source $CORE_LIB_DIR/head_tracking.sh
  source $CORE_LIB_DIR/lockdown.sh
  source $ADAPTER_LIB_DIR/translator.sh
  ```
  Then read stdin, translate via `coord_cx_extract_*` helpers, build sessions.json record with `agent: "codex"`.
- **Source enum mapping:** Codex `Startup|Resume|Clear` → same logic as Claude's branches; `Compact` does not exist for Codex (per D-11).
- **Tests:** ~10 bats covering each source variant + missing fields + lockdown gate.
- **Acceptance:** Tests green; full surface green.
- **Risk:** Medium (first end-to-end Codex hook).
- **Dependencies:** Phase C.
- **Estimated diff:** ~250 lines.

### PR D.2 — `src/adapters/codex/hooks/stop.sh`
- **Goal:** Codex Stop hook releases held locks (replaces SessionEnd, which Codex doesn't have).
- **Pre-conditions:** D.1 merged.
- **Implementation:** Mirror `claude-code/hooks/stop.sh`. The self-task block-once-then-allow behavior carries (Codex Stop input has `stop_hook_active` field per Codex source `events/stop.rs:30`).
- **Tests:** ~8 bats.
- **Risk:** Low.
- **Dependencies:** D.1.
- **Estimated diff:** ~150 lines.

### PR D.3 — `src/adapters/codex/hooks/user_prompt_submit.sh`
- **Goal:** Capture prompt_id, refresh activity, supersede read-set on new prompt.
- **Pre-conditions:** D.2 merged.
- **Implementation:** Mirror Claude's. Codex `UserPromptSubmit` has `.prompt` field same as Claude.
- **Tests:** ~5 bats.
- **Risk:** Low.
- **Dependencies:** D.2.
- **Estimated diff:** ~120 lines.

### PR D.4 — `src/adapters/codex/hooks/pre_tool_use_*.sh` (the BIG one)
- **Goal:** All three PreToolUse variants — `pre_tool_use_any.sh` (matcher *), `pre_tool_use_bash.sh` (matcher ^Bash$), `pre_tool_use_apply_patch.sh` (matcher ^apply_patch$). The apply_patch variant implements multi-file lock-acquire-all-or-deny atomicity.
- **Pre-conditions:** D.3 merged.
- **Implementation highlights:**
  - `pre_tool_use_any.sh`: cross-cutting consumer (notification consume, HEAD recheck, watchdog ambient probe, verdict pointer advance). Mostly a copy of Claude's variant with translator-driven extraction.
  - `pre_tool_use_bash.sh`: registers `Bash` invocations as `WRITE` events (no, wait — Bash is not a file write). Just logs intent + does lockdown gate. NOT a file-locking event.
  - `pre_tool_use_apply_patch.sh`: the multi-file write hook. Algorithm:
    1. Lockdown gate.
    2. Extract all paths via `coord_cx_apply_patch_paths`.
    3. Sort paths alphabetically (deadlock prevention per D-12).
    4. For each path, in order: check if locked by another → if yes, collect into `BLOCKED_FILES` array; if free or self-held, OK.
    5. If `BLOCKED_FILES` non-empty: emit deny with banner listing all blocked files + their holders.
    6. Otherwise: For each path, run drift detection (using Codex pre-image hash for each hunk's anchor; this replaces Claude's read_set hash check).
    7. If all drift-clean: acquire all locks atomically (one `coord_atomic_edit` with N `.locks[$path] = {...}` updates).
    8. Emit no-op (allow).
- **Drift detection adaptation:** for each `*** Update File: <path>` operation, parser yields hunks. For each hunk, compute the agent's pre-image hash and compare against the current file's content at the anchored location. The validator pipeline gets called per-file with `read_hash = pre_image_hash`, `current_hash = current_disk_hash`.
- **Tests:** ~30 bats covering: single-file allow, single-file deny, multi-file all-allow, multi-file partial-block (deny entire), multi-file with drift, lockdown gate, subagent-as-own-session.
- **Acceptance:** Tests green; full v1 + Codex unit surface green.
- **Risk:** High. This is the core Codex coordination logic.
- **Dependencies:** D.3, C.2 (parser), C.3 (translator complete).
- **Estimated diff:** ~600 lines across 3 files.

### PR D.5 — `src/adapters/codex/hooks/post_tool_use_apply_patch.sh`
- **Goal:** Release all locks held for the apply_patch's files; trigger task processor per-file; notify waiters.
- **Pre-conditions:** D.4 merged.
- **Implementation:** Mirror `post_tool_use_write.sh` but iterate over the path list extracted from `tool_input.command` (the parser produces this). For each path: run task_processor, atomic release, notify_waiters.
- **Tests:** ~10 bats.
- **Risk:** Medium.
- **Dependencies:** D.4.
- **Estimated diff:** ~200 lines.

---

## Phase E — Codex installer + dispatcher

**Phase goal:** Install Codex hooks into `.codex/hooks.json`. Update the top-level `src/install.sh` to dispatch to whichever adapter(s) the user requests.

**Phase exit criteria:**
- `bash src/install.sh --with-codex` writes `.codex/hooks.json` correctly + materializes shared `.coord/`.
- `bash src/install.sh` (no flags) installs Claude only (back-compat).
- `bash src/install.sh --with-claude-code --with-codex` installs both.
- Detection of `claude` and `codex` binaries works; smoke tests run for the requested agent(s).

### PR E.1 — `src/adapters/codex/install.sh`
- **Goal:** Adapter-specific installer for Codex. Writes `.codex/hooks.json` with all 6 hook entries (no SessionEnd). Verifies/asks-for-confirmation for `[features] codex_hooks = true` in `.codex/config.toml`.
- **Pre-conditions:** Phase D complete.
- **Files added:** `src/adapters/codex/install.sh`.
- **`.codex/hooks.json` shape produced:**
  ```json
  {
    "hooks": {
      "SessionStart": [{
        "matcher": "*",
        "hooks": [{"type": "command", "command": "<install_root>/.coord/hooks/codex/session_start.sh", "timeout": 10}]
      }],
      "Stop": [{
        "matcher": "*",
        "hooks": [{"type": "command", "command": "...stop.sh", "timeout": 10}]
      }],
      "UserPromptSubmit": [{
        "matcher": "*",
        "hooks": [{"type": "command", "command": "...user_prompt_submit.sh", "timeout": 10}]
      }],
      "PreToolUse": [
        {"matcher": "*",                "hooks": [{"type": "command", "command": "...pre_tool_use_any.sh",         "timeout": 10}]},
        {"matcher": "^Bash$",           "hooks": [{"type": "command", "command": "...pre_tool_use_bash.sh",        "timeout": 10}]},
        {"matcher": "^apply_patch$",    "hooks": [{"type": "command", "command": "...pre_tool_use_apply_patch.sh", "timeout": 10}]}
      ],
      "PostToolUse": [
        {"matcher": "^apply_patch$",    "hooks": [{"type": "command", "command": "...post_tool_use_apply_patch.sh","timeout": 10}]}
      ]
    }
  }
  ```
- **Feature flag handling:** Check `<repo>/.codex/config.toml` for `[features] codex_hooks = true`. If absent and `--enable-codex-feature` flag passed, set it. Otherwise warn user with copy-paste instructions.
- **Idempotency:** Strip prior coord-owned entries (commands containing `/.coord/hooks/codex/`) before appending — same pattern as Claude.
- **Smoke test:** Pipe canned Codex SessionStart JSON into `session_start.sh` against a tmpdir `.coord/`. Verify `.active` marker created.
- **Tests:** New `src/adapters/codex/tests/unit/install.bats` (~10 tests).
- **Acceptance:** Tests green.
- **Risk:** Medium. JSON merge correctness.
- **Dependencies:** Phase D.
- **Estimated diff:** ~300 lines.

### PR E.2 — Top-level `src/install.sh` becomes adapter dispatcher
- **Goal:** Detect installed agents; install hooks for each requested.
- **Pre-conditions:** E.1 merged.
- **Files updated:** `src/install.sh` heavily rewritten.
- **Behavior:**
  - `--with-claude-code` (default if neither flag given AND `claude` binary on PATH): run `src/adapters/claude-code/install.sh`.
  - `--with-codex` (auto-on if `codex` binary on PATH AND user did not explicitly opt-out): run `src/adapters/codex/install.sh`.
  - `--with-claude-code --with-codex`: run both.
  - `--with-claude-code --without-codex`: claude only (explicit override).
  - Materialize `.coord/` once (shared across adapters).
- **`bin/parallels-init`** content stays the same (it just calls `src/install.sh`).
- **Tests:**
  - `src/core/tests/integration/install_dispatcher_claude_only.bats`.
  - `src/core/tests/integration/install_dispatcher_codex_only.bats`.
  - `src/core/tests/integration/install_dispatcher_both.bats`.
- **Acceptance:** All tests green; full surface green.
- **Risk:** Medium.
- **Dependencies:** E.1.
- **Estimated diff:** ~150 lines (rewrite of register_hooks dispatch).

---

## Phase F — Cross-agent integration tests

**Phase goal:** Lock the cross-agent semantics with end-to-end tests. Each scenario boots a fake-Claude + fake-Codex pair and verifies coord arbitrates correctly.

### PR F.1 — Test infrastructure
- **Goal:** Helpers to spin up "fake Claude" and "fake Codex" sessions in bats. Each fake just pipes canned hook JSON inputs through the adapter hook scripts.
- **Pre-conditions:** Phase E complete.
- **Files added:** `src/tests/integration/cross_agent/helpers.bash`, fixture data.
- **Risk:** Low.
- **Dependencies:** Phase E.
- **Estimated diff:** ~200 lines.

### PR F.2 — Cross-agent scenarios
- **Goal:** ~10 scenarios covering: A locks → B (other agent) denied; A holds → B waits → A releases → B wakes; A crashes → B Watchdog recovers; cycle between Claude+Codex sessions; FIFO across agents; multi-file apply_patch denied because Claude holds one of the files.
- **Files added:** `src/tests/integration/cross_agent/*.bats` (~10 files).
- **Risk:** Medium-high. Real cross-agent semantic verification.
- **Dependencies:** F.1.
- **Estimated diff:** ~600 lines.

### PR F.3 — `phase7_codex_invariant.bats`
- **Goal:** Mirror the existing 19-guard invariant test for the Codex adapter. Asserts: deny only in 2 places (lock-held + lockdown), no surprise tool-name leaks, etc.
- **Files added:** `src/adapters/codex/tests/unit/phase7_codex_invariant.bats` (~5 guards specific to Codex shape).
- **Risk:** Low.
- **Dependencies:** F.2.
- **Estimated diff:** ~150 lines.

---

## Phase G — Documentation

### PR G.1 — README.md, CONTRIBUTING.md, package.json updates
- **Goal:** Public-facing docs reflect the cross-agent narrative.
- **Pre-conditions:** Phase F complete.
- **Files updated:** `README.md`, `CONTRIBUTING.md`, `package.json`, `bin/parallel-sessions` help text.
- **Headline change:** "Multi-session coordination for Claude Code" → "Multi-session coordination for AI coding agents (Claude Code + OpenAI Codex)".
- **New sections in README:**
  - "Supported agents" with feature parity matrix.
  - "Cross-agent coordination" with example.
  - "Installation" updated to use `parallels-init`.
- **Acceptance:** Docs accurate; manual review.
- **Risk:** None.
- **Dependencies:** Phase F.
- **Estimated diff:** ~150 lines.

### PR G.2 — Codex quickstart
- **Goal:** A new `docs/codex-quickstart.md` aimed at Codex users.
- **Risk:** None.
- **Dependencies:** G.1.
- **Estimated diff:** ~100 lines.

---

## Phase H — Final verification

### PR H.1 — Full ship-gate
- **Goal:** Run the entire test surface against a fresh install in a non-git folder + a git repo. Validate all promises.
- **Verification:**
  ```bash
  # Fresh tmpdir, non-git
  TMP=$(mktemp -d) && cd "$TMP"
  bash <repo>/bin/parallels-init --yes
  bash <repo>/bin/parallels-claude --version  # smoke
  bash <repo>/bin/parallels-codex --version   # smoke
  
  # Run ALL test surfaces
  cd <repo>
  bats src/tests/unit                                # 645 + new
  bats src/tests/integration                          # 48 + new
  bats src/tests/integration/cross_agent              # ~10 new
  bats src/adapters/claude-code/tests/unit            # claude-coupled
  bats src/adapters/codex/tests/unit                  # codex-coupled
  bash src/tests/manual/phase{3,4,5,6,7}_ship_gate.sh # 24 scenarios
  bats src/tests/unit/phase7_invariant.bats           # 19 guards
  bats src/adapters/codex/tests/unit/phase7_codex_invariant.bats  # ~5 guards
  ```
- **Acceptance:** All green.
- **Risk:** Last chance to catch regressions.
- **Dependencies:** All prior PRs.

---

## Risk register (rolled up)

| Risk | Phase | Mitigation |
|---|---|---|
| Refactor breaks v1 | A | Per-PR test surface gate; small reviewable moves |
| apply_patch parser wrong | C.2 | 20+ fixtures from Codex's own test suite |
| Multi-file lock atomicity buggy | D.4 | Alphabetical sort + single atomic_edit; cross-agent integration tests |
| Codex subagent state explosion | D.1 | Each subagent is its own session — natural limit via Stop+Watchdog |
| `permissionDecision` + `additionalContext` collision | D.4 | D-9 enforcement in translator emit functions |
| Folder-resolver edge cases | A.5 | Walk-up fallback chain + non-git integration test |
| Launcher script PATH issues | B.2 | Tests with stub binaries on PATH |
| Codex feature flag off | E.1 | Pre-install check + user prompt with copy-paste instructions |

---

## Glossary

- **Adapter** — agent-specific code under `src/adapters/<agent>/`. Translates the agent's hook input into core normalized events; emits agent-specific output JSON.
- **Core** — agent-agnostic code under `src/core/`. Owns state, locks, drift detection, mediator/validator/watchdog, etc.
- **Translator** — the `lib/translator.sh` inside each adapter. Functions named `coord_<adapter_prefix>_*`.
- **Pre-image** — agent's belief of file content before edit. Claude: stored from `Read` event. Codex: derived from `apply_patch` context lines.
- **Lock-acquire-all-or-deny** — multi-file atomicity rule for Codex apply_patch (D-12).
- **Participation gate** — `[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0` line at the top of every hook.
- **2-location deny invariant** — exactly two code paths emit `permissionDecision: "deny"`: (a) lock-held branch in pre_tool_use_write, (b) lockdown.sh global pause.

---

## Plan amendment policy

If implementation reveals a flaw in this plan:
1. **Don't deviate silently.** Stop the PR.
2. **Update this plan file** with the change. Include the date, the change, and the reason.
3. **Add a log entry** in `codex-integration-log.md` describing the deviation.
4. **Resume the PR** with the amended plan as the new contract.

The plan is a living document but every change is auditable.

---

## Acceptance of plan

This plan is accepted when the user confirms in the live log. The first log entry must be:

> 2026-MM-DD — Plan v1.0 reviewed and accepted by user. Phase A may begin.

End of plan v1.0.

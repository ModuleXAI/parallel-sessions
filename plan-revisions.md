# plan-revisions.md

Ledger of changes applied to `IMPLEMENTATION_PLAN.md` and `CLAUDE.md` after initial authoring. Entries are append-only. New revisions go at the bottom.

Each entry records: what changed, where, and why. Findings that drove a change should be linked by their `F-NNN` ID (from `FINDINGS.md`) once construction has started; pre-construction revisions cite user direction instead.

---

## PR-REV-01 — Add IMPLEMENTATION_LOG.md + FINDINGS.md; small cleanups

**Date:** 2026-04-24
**Author:** planner
**Driver:** user direction (revision round via `plan-revision-prompt.md`)
**Scope:** updates to `IMPLEMENTATION_PLAN.md` and `CLAUDE.md`; no source or Phase 1 research touched; no new future-work docs.

### Changes applied

1. **IMPLEMENTATION_PLAN.md §2 — added Decision 2.23 (IMPLEMENTATION_LOG.md).**
   *Why:* End-of-phase sign-offs alone cannot preserve mid-phase state across context-limited sessions or builder hand-offs. A live append-only log bridges that gap.

2. **IMPLEMENTATION_PLAN.md §2 — added Decision 2.24 (FINDINGS.md).**
   *Why:* Observations, plan inaccuracies, and deferred questions need a dedicated home so they are not lost inside the progress log or conflated with formal plan-change decisions.

3. **IMPLEMENTATION_PLAN.md §4 — added component specs for `IMPLEMENTATION_LOG.md` and `FINDINGS.md` (project root).**
   *Why:* Every load-bearing artifact in the plan has a component spec; these two are now load-bearing for construction discipline.

4. **IMPLEMENTATION_PLAN.md §10.2 — expanded phase-start checklist.**
   *Why:* Phase-start now requires reading `IMPLEMENTATION_LOG.md` and `FINDINGS.md` and creating the new phase's log section before work begins.

5. **IMPLEMENTATION_PLAN.md §10.4 — rewrote "when the plan turns out to be wrong" protocol.**
   *Why:* Observation (goes to `FINDINGS.md`) and decision-to-change (goes to `plan-revisions.md`) are now distinguished explicitly; order of operations is observation first, revision second.

6. **IMPLEMENTATION_PLAN.md §10.5 — replaced end-of-phase sign-off format.**
   *Why:* Sign-off now references task ID range from `IMPLEMENTATION_LOG.md` and disposition status of every FINDINGS entry raised in the phase; ship gate items require explicit evidence pointers.

7. **IMPLEMENTATION_PLAN.md §4 CLI component — made `coord mediate --retry` explicit; split `coord install` / `coord uninstall`; added `coord uninstall --purge`.**
   *Why:* `--retry` was referenced in R23 but not listed. Uninstall behavior was ambiguous about what remains on disk; now specified — hooks removed from `.claude/settings.local.json`, `.coord/` left in place, construction-time logs (`IMPLEMENTATION_LOG.md`, `FINDINGS.md`) never touched. `--purge` added for the complete-wipe case with confirmation guard.

8. **IMPLEMENTATION_PLAN.md Decision 2.20 — added tunable minimum bounds.**
   *Why:* Prevents misconfigured installs from inverting the ordering (`confirm < suspicion < TTL`), which would cause spurious evictions. Installer and `coord health` now validate.

9. **IMPLEMENTATION_PLAN.md §5 Phase 0 — added Experiment #9 (Bash tool timeout) and updated "Done when" to reference 9 experiments.**
   *Why:* Resolves OI-2 inside Phase 0 rather than punting to Phase 2; the Bash tool cutoff is a prerequisite for picking the default `wait_max_seconds`.

10. **IMPLEMENTATION_PLAN.md §8 OI-2 — updated to depend on Phase 0 Experiment #9.**
    *Why:* Parallel to change #9; deadline moves earlier and the resolution path becomes concrete.

11. **IMPLEMENTATION_PLAN.md Decision 2.12 — added Phase 7 revisit note for `task_delegation` default.**
    *Why:* Formalizes the data-driven flip criterion already informally captured in OI-6 (>10% TASK_FAILED + TASK_CONFLICT rate flips the default to `false`).

12. **CLAUDE.md Part A — added §A.11 (Construction Progress Discipline).**
    *Why:* Encodes the IMPLEMENTATION_LOG.md protocol as a mandatory construction rule, including the resume-after-context-loss ordering.

13. **CLAUDE.md Part A — added §A.12 (Discovery Logging Discipline).**
    *Why:* Encodes the FINDINGS.md protocol, entry format, ID rules, and the FINDINGS-vs-plan-revisions distinction.

14. **CLAUDE.md Part C — added §C.6 (IMPLEMENTATION_LOG.md and FINDINGS.md lifecycle).**
    *Why:* Clarifies both files outlive construction, survive `coord uninstall`, and may be manually archived after v1 ships.

### Non-changes (deliberate)

- No Phase 1 research document was modified — they are historical record.
- No future-work document was added or revised.
- No new architectural mechanism was introduced beyond the two progress-tracking files.
- `IMPLEMENTATION_LOG.md` and `FINDINGS.md` themselves are NOT created here; they are Phase 3 construction artifacts, born with the first Phase 0 task.
- `planning-scratch.md` received an appended "Revision 1" section (historical trail), not a rewrite.

### Cross-references

- Components added: `IMPLEMENTATION_LOG.md`, `FINDINGS.md` (both §4).
- Open Items affected: OI-2 (now Phase 0 bound), OI-6 (formalized via Decision 2.12 note).
- Risks affected: R23 (Mediator retry now explicitly surfaced in CLI list).

---

---

## PR-CLEANUP-01 — Relocate FUTURE_WORK docs + archive historical artifacts

**Date:** 2026-04-24
**Author:** planner
**Driver:** user direction (pre-Phase-3 workspace cleanup)
**Scope:** filesystem reorganization + reference integrity updates; no content edits beyond path fixes and two short orientation notes.

### Files moved

**Into `future-work/` (8 files, `git mv`):**
- `FUTURE_WORK_daemon_architecture.md`
- `FUTURE_WORK_go_native_implementation.md`
- `FUTURE_WORK_multi_user_shared_machine.md`
- `FUTURE_WORK_remote_sessions.md`
- `FUTURE_WORK_sqlite_state_storage.md`
- `FUTURE_WORK_team_shared_repos.md`
- `FUTURE_WORK_visualization_ui.md`
- `FUTURE_WORK_windows_native_support.md`

**Into `archive/` (15 files, `git mv`):**
- `01-comprehension-summary.md`
- `02-critical-questions.md`
- `03-claude-code-capabilities-research.md`
- `04-design-stress-test.md`
- `05-assumptions-and-risks.md`
- `06-alternative-approaches.md`
- `07-implementation-considerations.md`
- `08-phasing-critique.md`
- `09-open-questions-for-human.md`
- `09-user-answers.md`
- `10-working-notes.md`
- `multi-session-coordination-system-en.md`
- `PLANNING_INSTRUCTIONS.md`
- `plan-revision-prompt.md`
- `planning-scratch.md`

The user will relocate `archive/` out of the project folder to a personal backup location after this commit. The empty-or-otherwise `archive/` directory will remain at root until then.

### Reference updates applied

All updates are direct string replacements in the specified files. Before/after lines:

**Action 1 — FUTURE_WORK path prefix (6 updates):**

1. `CLAUDE.md:26` (path line is now line 28 after orientation note was inserted)
   - Before: `` - `FUTURE_WORK_*.md` — **out of scope.** Do not read during Phase 3 implementation unless revisiting a deferred decision. ``
   - After: `` - `future-work/FUTURE_WORK_*.md` — **out of scope.** Do not read during Phase 3 implementation unless revisiting a deferred decision. ``

2. `IMPLEMENTATION_PLAN.md:28`
   - Before: `` - **Windows native.** WSL2 works (presents as Linux). Windows native gets `FUTURE_WORK_windows_native_support.md`. ``
   - After: `` - **Windows native.** WSL2 works (presents as Linux). Windows native gets `future-work/FUTURE_WORK_windows_native_support.md`. ``

3. `IMPLEMENTATION_PLAN.md:30`
   - Before: `` - **Remote sessions / multi-machine.** `FUTURE_WORK_remote_sessions.md`. ``
   - After: `` - **Remote sessions / multi-machine.** `future-work/FUTURE_WORK_remote_sessions.md`. ``

4. `IMPLEMENTATION_PLAN.md:31`
   - Before: `` - **Multi-user on the same machine.** `FUTURE_WORK_multi_user_shared_machine.md`. ``
   - After: `` - **Multi-user on the same machine.** `future-work/FUTURE_WORK_multi_user_shared_machine.md`. ``

5. `IMPLEMENTATION_PLAN.md:32`
   - Before: `` - **Team-shared coordination state (checked into git).** Everything is gitignored; the system is per-developer opt-in. `FUTURE_WORK_team_shared_repos.md`. ``
   - After: `` - **Team-shared coordination state (checked into git).** Everything is gitignored; the system is per-developer opt-in. `future-work/FUTURE_WORK_team_shared_repos.md`. ``

6. `IMPLEMENTATION_PLAN.md:1111`
   - Before: `` | R3 | `flock` not present on exotic Unix | LOW | BLOCKING | Installer refuses if `flock` missing; `FUTURE_WORK_windows_native_support.md` covers the Unix-fringe case | `install.sh` dep check | ``
   - After: `` | R3 | `flock` not present on exotic Unix | LOW | BLOCKING | Installer refuses if `flock` missing; `future-work/FUTURE_WORK_windows_native_support.md` covers the Unix-fringe case | `install.sh` dep check | ``

**Action 2 — Read-me-now archive refs (5 lines, 7 filename replacements):**

7. `CLAUDE.md §A.2` (former line 21, now line 23)
   - Before: `` - `PLANNING_INSTRUCTIONS.md` — user's authoritative direction. Read first. ``
   - After: `` - `archive/PLANNING_INSTRUCTIONS.md` — user's authoritative direction. Read first. ``

8. `CLAUDE.md §A.2` (former line 23, now line 25)
   - Before: `` - `09-user-answers.md` — raw user answers (historical context). ``
   - After: `` - `archive/09-user-answers.md` — raw user answers (historical context). ``

9. `CLAUDE.md §A.2` (former line 24, now line 26)
   - Before: `` - `01-comprehension-summary.md` through `10-working-notes.md` — Phase 1 research. ``
   - After: `` - `archive/01-comprehension-summary.md` through `archive/10-working-notes.md` — Phase 1 research. ``

10. `CLAUDE.md §A.2` (former line 25, now line 27)
    - Before: `` - `planning-scratch.md` — planner's synthesis notes (historical). ``
    - After: `` - `archive/planning-scratch.md` — planner's synthesis notes (historical). ``

11. `IMPLEMENTATION_PLAN.md §10.3` (former line 1246, now line 1248)
    - Before: `` 1. **User direction** (PLANNING_INSTRUCTIONS.md → "User's Finalized Direction" or `09-user-answers.md`). ``
    - After: `` 1. **User direction** (`archive/PLANNING_INSTRUCTIONS.md` → "User's Finalized Direction" or `archive/09-user-answers.md`). ``

**Attributional references deliberately left unchanged (7 lines):**
- `CLAUDE.md` precedence clause at top (line 9)
- `CLAUDE.md` commit discipline list (line 106)
- `CLAUDE.md` Part C authority clause (line 365)
- `IMPLEMENTATION_PLAN.md` Decision 2.2 source attribution (line 57)
- `IMPLEMENTATION_PLAN.md` Section 7 E1 abandonment trigger row (line 1135)
- `plan-revisions.md` PR-REV-01 driver line (line 13) — historical trail
- `plan-revisions.md` PR-REV-01 non-change note (line 66) — historical trail

Under the blanket policy, these are source citations / historical mentions; the reader is not expected to follow them as read-me-now instructions. No "(archived)" suffix appended.

### Orientation notes added

**CLAUDE.md §A.2** — single italic sentence inserted directly under the `### A.2` heading, before the path list:

> `*Files under `archive/` are historical artifacts consulted only when explicitly directed (per §10.3's decision tree in the plan), not routinely.*`

**IMPLEMENTATION_PLAN.md §10.1** — single italic sentence appended at the end of the section (after item 5):

> `*Most Phase 1 research documents now live under `archive/` (e.g., `archive/03-claude-code-capabilities-research.md`); consult them per §10.3's decision tree rather than routinely.*`

### Non-changes (deliberate)

- Cross-references between `FUTURE_WORK_*` docs are unchanged; they all moved together and relative naming stays valid.
- No source or Phase 1 research file content modified (only their paths).
- `IMPLEMENTATION_PLAN.md`, `CLAUDE.md`, `plan-revisions.md`, `skills-lock.json`, `.claude/` left at root untouched.
- `IMPLEMENTATION_LOG.md` and `FINDINGS.md` are still Phase 3 construction artifacts; not created here.

### Cross-references

- Supersedes nothing; augments PR-REV-01.
- Affects component list in PLAN §4 only indirectly (file paths for `IMPLEMENTATION_LOG.md` and `FINDINGS.md` described as "project root" remain accurate; the archive/ and future-work/ subdirectories do not alter root for those files).

---

*Future entries append below.*

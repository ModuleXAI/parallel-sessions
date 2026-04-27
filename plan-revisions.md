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

## PR-PHASE0-01 — Subagent filter relocation + `wait_max_seconds` bounds + subagent observability

**Date:** 2026-04-24
**Author:** Phase 3 builder (proposal); user-acknowledged with three clarifications.
**Status:** APPROVED. Applied to `IMPLEMENTATION_PLAN.md` and `CLAUDE.md` in this revision.
**Driver:** Phase 0 verification experiments #5 and #9. Findings F-006 (OPEN),
F-008 (OPEN). User's acknowledgement message adds clarifications C-rationale,
D-lower-bound, and an additional MUST-log requirement for subagent activity.

### Observed facts requiring change

1. **Subagents do not fire `SessionStart`.** Decision 2.17 filters subagents
   by "SessionStart input includes a populated `agent_type` field." Experiment
   #5 (T0.07) shows this never happens: subagent tool calls share the parent's
   `session_id` and the `agent_type` field is populated on `PreToolUse`,
   `PostToolUse`, and `SubagentStop` — never on `SessionStart`.
2. **Bash-tool 10-minute ceiling.** Claude Code's Bash tool caps at 600 s
   configurable timeout (default 120 s). `coord wait` is a Bash-tool call.
   Plan §3.6 sets `wait_max_seconds: 1800` (30 min), which is unreachable.

### Proposed edits

**A. Decision 2.17 amendment (subagent filter location).**

Replace:
> "Subagent session participation: sessions where `SessionStart` input includes a populated `agent_type` field are **filtered out** of coordination. ..."

With:
> "Subagent session participation: Claude Code does **not** issue a separate
> `SessionStart` for subagents spawned via the Task tool; subagent tool calls
> carry the parent session's `session_id`. The coordination layer filters
> subagent activity at the **tool-call hook layer**: when any `PreToolUse`,
> `PostToolUse`, or `SubagentStop` input contains a non-empty `agent_type`
> field, coordination hooks exit 0 without mutating state (they may still
> emit an observability event). Subagent tool calls therefore inherit the
> parent session's locks and read-set passively — the parent's lock covers
> the parent's turn, including any tool calls its subagents make."
> **Source:** Phase 0 Experiment #5 (documented in `.coord/phase0-verification.md`).

**B. §B.10 anti-pattern addition.**

Add to CLAUDE.md Part B §B.10:
> "- **Do not spawn a subagent as a workaround to evade coordination.**
>   Subagent tool calls are invisible to the coord layer by design (filtered
>   out in `pre_tool_use_*`, `post_tool_use_*`, `stop.sh`), which means a
>   subagent writing a file not locked by its parent can race silently with
>   another session. If you need a bounded deferral, prefer `coord
>   self-delegate` (which IS tracked) over a subagent."

**C. §3.6 config defaults (with rationale per user clarification).**

Change:
```json
"wait_max_seconds": 1800
```
to:
```json
"wait_max_seconds": 570
```

Add rationale sentence to Decision 2.20's bounds list (see change D below):
> "570 s = 600 s Bash-tool ceiling − 30 s safety margin to avoid hitting the
> tool timeout before coord's own timeout fires and logs a clean
> WAIT_TIMEOUT event."

**D. §3.6 / §4 tunable bounds (upper AND lower; alongside Decision 2.20's
existing bounds).**

Add: *`wait_max_seconds` bounds are `30 ≤ wait_max_seconds < 600`. Upper
bound: 600 s is the Claude Code Bash-tool configurable maximum (F-008).
Lower bound: 30 s prevents accidental misconfiguration to near-zero values
that would make passive wait unusable. Installer and `coord health` refuse
configurations outside these bounds.*

**E. §B.2 option (c) lock-deny prompt text.**

Change:
> "(c) Passively wait: `Bash: coord wait foo.ts --timeout 600` (blocks your Bash call until unlocked or timeout)."

to:
> "(c) Passively wait: `Bash: coord wait foo.ts --timeout 570` (blocks your
> Bash call until unlocked or timeout; 570 s is the max — it sits just below
> Claude Code's 600 s Bash-tool ceiling)."

**F. §4 `coord wait` CLI test criteria.**

Add: *requested `--timeout` is clamped to the range `[30, 570]`; a clamped
request logs a `WAIT_CLAMPED` event with the requested and applied values.*

**G. Subagent-activity observability (user-requested addition).**

The amended Decision 2.17 (change A) says the coord layer "filters subagent
activity at the tool-call hook layer." Make the observability commitment
explicit, not optional:

> "When `pre_tool_use_*`, `post_tool_use_*`, or `stop.sh` (and by extension
> any hook whose stdin may carry a populated `agent_type`) detects a
> non-empty `agent_type` and exits without mutating state, it MUST emit a
> single event-log entry of `kind: "SUBAGENT_ACTIVITY_SKIPPED"` with payload
> `{parent_session, tool, agent_type, file: <file_path when applicable>}`."

Rationale: FUTURE_WORK_visualization_ui must be able to show subagent
activity even though coord doesn't coordinate it. Logging is cheap;
reconstructing history later if we didn't log is impossible.

Plan edit: **§3.5** events.jsonl kind-list — add
`SUBAGENT_ACTIVITY_SKIPPED` to the enumerated `kind` set.

### Cross-references

- FINDINGS.md F-006 → RESOLVED upon landing this revision.
- FINDINGS.md F-008 → RESOLVED upon landing this revision.
- Open Item OI-2 ("Bash tool cutoff TBD") — closed by F-008 + this PR.
- IMPLEMENTATION_LOG.md T0.07, T0.11 cited as evidence for A + C-F.

### Non-changes

- Plan's overall design unaffected; these are localized corrections.
- No change to Mediator, validator, task-graph, or lib module contracts.
- FUTURE_WORK files untouched.

### Acknowledgement

Approved 2026-04-24 with clarifications C-rationale, D-lower-bound, and
addition G (subagent activity logging). Plan documents edited to match;
downstream code (config default already = 570 since initial install;
`coord health` bounds check + subagent logging) implemented alongside.

---

## PR-PHASE1-01 — Decision 2.5 augmented with `SessionStart.source` behavior matrix

**Date:** 2026-04-24
**Author:** Phase 3 builder (proposal); user-approved with two clarifications
folded in (see "Clarifications from user" below).
**Status:** APPROVED. Applied to `IMPLEMENTATION_PLAN.md` Decision 2.5 in this
revision.
**Driver:** FINDINGS F-004 (OPEN → RESOLVED by this revision). Phase 0
Experiment #1 (T0.03) captured the observation that `SessionStart` stdin
carries a `source` field with values `startup | resume | clear | compact`;
original Decision 2.5 spoke only to "registration happens in SessionStart
when CLAUDE_COORD=1 is set" and was silent on the other three source
values. Phase 1 adds read-set tracking (`pre_tool_use_read.sh`) and prompt
handling (`user_prompt_submit.sh`); read-set preservation/invalidation
semantics across resume/clear/compact must be nailed down before those
hooks are written.

### Observed facts requiring change

1. **SessionStart fires for all four source values** — not just `startup`.
   Phase 0 Experiment #1 confirmed `source=startup` on fresh launch; Claude
   Code documentation (v2.1.119) enumerates the other three values. Resumed
   sessions keep the same `session_id`, so naive "insert new row on
   SessionStart" behavior would fail an uniqueness invariant.
2. **PID + lstart change across resume** (the old process is dead; the new
   process has a fresh pid and a fresh `ps -p PID -o lstart=` string). Our
   watchdog primitives (F-005) key off `$PPID` and `lstart`; resume must
   refresh both.
3. **`source=resume` can occur after SIGKILL of the prior process** (Phase 0
   Experiment #6: SIGKILL does not fire SessionEnd, so prior locks / marker
   files may still be present in state keyed by this same `session_id`).
4. **Git HEAD may have changed during the resume gap** (user checked out a
   branch; previous process died; user returned). Decision 2.22 already
   covers "HEAD change invalidates read-set" for the UserPromptSubmit path;
   the resume path needs the same logic explicitly.

### Proposed edit to Decision 2.5

Replace:

> "Decision 2.5: Session identity scheme: Claude Code provides a UUID
> `session_id` in every hook's stdin JSON. That UUID is the coordination
> session ID. Session registration happens in `SessionStart` when
> `CLAUDE_COORD=1` is set in the environment. Non-participant sessions
> (env var unset) are ignored."

With:

> "Decision 2.5: Session identity scheme: Claude Code provides a UUID
> `session_id` in every hook's stdin JSON. That UUID is the coordination
> session ID. SessionStart is invoked with a `source` field whose value
> distinguishes four lifecycle events; the hook's behavior depends on
> `source` as follows:
>
> | `source`  | Registration action                                                  | Read-set action                                                         | PID / lstart / git_head              | Event                 |
> |-----------|-----------------------------------------------------------------------|-------------------------------------------------------------------------|--------------------------------------|-----------------------|
> | `startup` | Insert new row (schema per §3.3); reject if a row already exists for this `session_id` as anomaly. | Initialize empty read-set.                                              | Capture fresh (`$PPID` + lstart + git_head). | `SESSION_REGISTER`    |
> | `resume`  | Idempotent refresh of the existing row (matched by `session_id`); if no prior row exists, fall back to `startup` semantics and emit `SESSION_REGISTER` with `reason:"resume_without_prior_row"`. | **Preserve read-set intact** — the `session_id` is stable across resume and prior reads semantically still belong to this session. Then: compare stored `git_head` to current; if different, set `superseded_by_head_change: true` on every entry in `read_sets[<id>].reads[]` before proceeding (per Decision 2.22). | Refresh (new `$PPID`, new lstart, new git_head). | `SESSION_RESUME`. Additionally, if lock records keyed to this `session_id` exist with the prior PID/lstart stamp, emit a `RESUME_ORPHAN_LOCK_DETECTED` event per affected lock but do **not** release it in Phase 1 — orphan-lock eviction is deferred to Phase 3's peer-watchdog (Phase 2 introduces locks but the watchdog doesn't arrive until Phase 3). |
> | `clear`  | Refresh the existing row (idempotent). | Mark prompt-scoped entries `superseded_by: "new_prompt"`. Semantically identical to the invalidation `user_prompt_submit.sh` performs; `source=clear` is the independent "fresh start" channel when the user explicitly clears context. | Refresh git_head only (pid/lstart unchanged — same process). | `SESSION_CLEAR`. |
> | `compact` | Refresh `last_activity_at` on the existing row. | **No change** — context compression preserves read history semantically; the hashes stored in `read_sets` are still the truth about "what this session last observed on disk." | No change. | `SESSION_COMPACTED` (informational). |
>
> Non-participant sessions (env var `CLAUDE_COORD` unset) are ignored
> regardless of `source`. Subagent sessions do not fire SessionStart at all
> (Decision 2.17 per PR-PHASE0-01); the source-branching above applies
> only to primary coordinated sessions."
>
> **Rationale:** UUID is already stable and unique; env-var gate is a clean
> opt-in that doesn't require a wrapper script and can be toggled per-launch.
> Source-matrix was added after Phase 0 Experiment #1 exposed the gap; the
> matrix preserves read-set semantics across the full session lifecycle.
>
> **Source:** User direction (Session Identity and System Boundary);
> Phase 1 `03` §9; planner chose env var over wrapper command; PR-PHASE1-01
> augmented the matrix post-Phase-0 (FINDINGS F-004).

### Clarifications from user (2026-04-24)

Folded into the matrix above exactly as the user worded them:

- **(a) Orphaned locks from a SIGKILL-ed prior process.** Policy per user:
  "orphaned-lock eviction deferred to Phase 2 peer-watchdog; Phase 1 flags
  the condition in events.jsonl." Implementation per the matrix: on
  `source=resume`, if any lock record exists in `sessions.json` keyed to
  this `session_id` AND the stored PID/lstart do not match `$PPID` +
  current lstart, emit a `RESUME_ORPHAN_LOCK_DETECTED` event per lock with
  payload `{session_id, file, old_pid, old_pid_lstart, new_pid,
  new_pid_lstart}`. Do NOT release the lock in Phase 1 (locks are
  out-of-scope for Phase 1). Phase 3's peer-watchdog will own eviction
  once PID + lstack consensus logic exists. Clarification from user:
  "Phase 2 peer-watchdog"; corrected here to Phase 3 since the plan's
  §5 Phase 2 scope is "write coordination" (locks added, no watchdog),
  and Phase 3 is where the watchdog lands. This is a pure phasing
  correction — no substantive behavior change.

- **(b) Git HEAD change during the resume gap.** Policy per user: "compare
  stored vs current git_head; if different, mark read_set entries
  `superseded_by_head_change: true`." Implementation per the matrix: on
  `source=resume`, after preserving the read-set, compute current
  `git rev-parse HEAD` and compare to the row's stored `git_head`; if
  they differ, iterate `read_sets[<id>].reads[]` and set
  `superseded_by_head_change: true` on every entry, then update the row's
  `git_head` to the new value. Emit a single `HEAD_CHANGE` event with
  payload `{session_id, old_head, new_head, source:"resume",
  reads_marked:<count>}`. This reuses the existing Decision 2.22 mechanism
  already used on `UserPromptSubmit`.

### §3.5 events.jsonl kind-list addition

Three new event kinds enter the enumerated set:

- `SESSION_RESUME` — emitted on `source=resume` registration refresh.
- `SESSION_CLEAR` — emitted on `source=clear`.
- `SESSION_COMPACTED` — emitted on `source=compact`.
- `RESUME_ORPHAN_LOCK_DETECTED` — emitted per orphaned-lock-on-resume (see
  clarification (a)).

`HEAD_CHANGE` was already in the kind list from Decision 2.22.

### Cross-references

- FINDINGS F-004 → RESOLVED by this revision.
- Decision 2.22 (HEAD change invalidates read-set) — mechanism reused for
  the resume path per clarification (b).
- Decision 2.17 / PR-PHASE0-01 — subagents don't fire SessionStart at all,
  so the source-matrix only governs primary coordinated sessions.
- `session_start.sh` (component spec §4) — will implement the matrix in
  Phase 1 tasks T1.04–T1.05 (the source-branching lives in session_start;
  user_prompt_submit reuses the HEAD-change mechanism but does not need
  source-awareness).

### Non-changes (deliberate)

- Watchdog / lock-eviction logic still arrives in Phase 3 per the phase
  table — this revision only defines the FLAG (`RESUME_ORPHAN_LOCK_DETECTED`
  event) that Phase 3 will consume.
- `session_end.sh`, `pre_tool_use_*.sh`, and `post_tool_use_*.sh` are
  unchanged.
- No change to the schema JSON-Schema text in §3.3 — the matrix governs
  transitions on the already-defined schema fields
  (`superseded_by`, `superseded_by_head_change`, `pid`, `pid_lstart`,
  `git_head`).

### Acknowledgement

Approved 2026-04-24 with clarifications (a) and (b) folded in as above.

---

## PR-PHASE2-01 — `read_sets[].reads[]` schema-text correction (`file` → `path`)

**Date:** 2026-04-25
**Author:** Phase 3 builder (proposal); user-approved on T2.01 close.
**Status:** APPROVED-on-proposal. Applied to `IMPLEMENTATION_PLAN.md`
§3.3 in this revision.
**Driver:** FINDINGS F-013 (OPEN → RESOLVED by this revision).

### Observed fact requiring change

`IMPLEMENTATION_PLAN.md` §3.3 (sessions.json JSON Schema) documents
the read-set entry shape as `{file, ts, hash, is_latest,
superseded_by, superseded_by_head_change}`. Every Phase 1 production
implementation site uses the field name `path` instead:
`pre_tool_use_read.sh` (writer), `pre_tool_use_write.sh` (reader),
`head_tracking.sh` (reader), `coord_status` (renderer). Producer and
consumer have always agreed on `path`, so behavior is correct on disk
and in tests; the discrepancy is plan-text-vs-code only and was not
caught during Phase 1 because no bats assertion compared §3.3 schema
text against actual on-disk shape.

### Edit applied

`IMPLEMENTATION_PLAN.md` §3.3 — within `read_sets.additionalProperties.
properties.reads.items`:

- `"required": ["file","ts","hash","is_latest"]`
  → `"required": ["path","ts","hash","is_latest"]`
- `"file": { "type": "string" }`
  → `"path": { "type": "string" }`

No other field changed. Code authority preserved (Phase 1 production
shape on disk is `path`).

### Cross-references

- FINDINGS F-013 → RESOLVED.
- Discovered during T2.01 (lock acquire/release implementation) when
  the new pre_tool_use_write.sh lock-check branch reused the existing
  read-set-walk jq filter from Phase 1.

### Non-changes

- No code change. Production data shape is unchanged; tests unchanged.
- No other §3.3 field touched. Other shape decisions (e.g., locks
  schema, read_set top-level keys) remain as documented.

---

*Future entries append below.*

---

## PR-PHASE3-01 — Mediator agent design contract (Decision 1)

**Date:** 2026-04-26
**Author:** Phase 3 builder (draft per user-resolved Decision 1; ambiguity
dispositions applied 2026-04-26 post-T3.02).
**Status:** APPROVED (DRAFT → APPROVED on T3.02 close + ambiguity
disposition; gates T3.07 (Mediator agent hook implementation) and T3.03
(lockdown flag mechanism, which is the deny side of this PR). Final
merge into IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-3-signoff.md per CLAUDE.md §A.4 pattern.
**Driver:** User direction (Phase 3 resume prompt, Decision 1 verbatim).

### Observed gap requiring change

Plan §5 Phase 3 names the Mediator's scope as "full agent-type hook +
remediations: reset state, evict dead session, cancel stuck task" but
does not specify the Mediator's decision contract, confidence model,
escalation hierarchy, or the lockdown mechanism that breaks the
Phase 2 deny-source invariant. CLAUDE.md §B.6 describes Mediator
invocation but predates the four-action contract. The implementation
needs the contract pinned before T3.03 (lockdown) and T3.07 (agent
hook) land.

### User-resolved decision (verbatim)

The Mediator inspects the caller's brief, the current state, the
events log, and the pending queue, then takes one of four action
types:

- (A) **Advice** — verdict tells the caller "proceed this way." No
  state change. Other sessions unaffected. Caller retries with the
  advice.
- (B) **Caller-blocking surgical fix** — Mediator instructs caller to
  wait, applies a localized state change (e.g., release orphan lock,
  clear stale read-set entry), then signals caller to proceed. Other
  sessions unaffected.
- (C) **Caller-blocking longer fix** — same category as (B) but larger
  scope. Multiple orphan locks, partial state corruption. Caller waits
  longer; others continue. Treat as severity gradient of (B), not a
  separate branch in code.
- (D) **System-wide lockdown** — Mediator writes
  `.coord/mediator/lockdown.json` with `active=true`. Every hook on
  every tool call reads this file; if active, hook emits
  `permissionDecision: "deny"` with reason "System-wide pause:
  Mediator is resolving <reason>. Wait, do not retry until lockdown is
  cleared." Mediator performs comprehensive fix, clears lockdown flag.
  All sessions resume.

The Mediator chooses among these autonomously based on the problem's
scope: caller-only impact → (A) or (B); system-wide impact → (D).

**Confidence model — 2-state (NOT a 4-level enum):**
- `auto-apply` → verdict is executed immediately.
- `needs-review` → triggers escalation (peer Mediator).

**Escalation hierarchy (max depth 2):**
1. First Mediator runs. If `verdict.confidence == auto-apply`, apply
   and end.
2. If `verdict.confidence == needs-review`, spawn a SECOND Mediator
   instance with the same context plus the first Mediator's verdict
   ("the previous Mediator suggested X; you are an independent
   reviewer; do you agree?").
3. If both Mediators agree on action → apply (agreement is defined as
   same `action_type` regardless of confidence variance — second
   Mediator is more cautious by design when reviewing; per user
   clarification, P3).
4. If they disagree (different `action_type`) → escalate to user (no
   third Mediator).
5. Maximum recursion depth is 2. After that, automatic user
   escalation. NO Mediator-spawning-Mediator beyond depth 2.

**User escalation mechanism — scope-dependent:**
- Caller-only scope (e.g., evict orphan lock for one session) → emit
  banner in caller's `additionalContext` with explicit
  `coord mediate --approve <action>` commands. Other sessions
  unaffected.
- System-wide scope → trigger lockdown (action D), block all
  sessions, surface to user via the next interactive context.

**Lockdown is a NEW deny source — Phase 3 invariant supersedes
Phase 2's:**
`permissionDecision: "deny"` is now allowed in EXACTLY two locations:
1. `pre_tool_use_write.sh` lock-held-by-other branch (existing
   Phase 2).
2. ANY hook reading `.coord/mediator/lockdown.json` with
   `active=true` (new Phase 3).
Update `phase2_invariant.bats` → `phase3_invariant.bats` with the
expanded scope.

**Critical conditions that bypass Mediator entirely:**
If system state is so degraded that even Mediator analysis is risky
(corrupt schema, impossible state — e.g., two sessions sharing a PID,
sessions.json fails jq parse repeatedly), skip Mediator entirely.
Trigger lockdown directly + emit user escalation banner.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §5 Phase 3 Scope.** Replace the
"hooks/mediator_agent.md full agent-type hook" bullet with an
expanded specification covering: 3-action contract
(`action_type ∈ {advice, surgical_fix, lockdown}` with
`severity ∈ {brief, extended}` for `surgical_fix` only); 2-state
confidence; max-depth-2 escalation hierarchy with peer Mediator
review; scope-dependent user escalation; lockdown flag mechanism;
critical-conditions bypass.

**B. `IMPLEMENTATION_PLAN.md` §5 Phase 3 "Done when"** — extend with:
- "`permissionDecision: deny` confined to exactly 2 locations
  (lock-held-by-other + lockdown active); asserted by
  `phase3_invariant.bats`."
- "Lockdown active causes every hook on every tool call to emit
  deny with the system-wide-pause reason; verified via fixture."
- "Needs-review verdict triggers a second Mediator with the first
  verdict in context; agreement applies, disagreement escalates to
  user."
- "Critical-condition bypass triggers lockdown directly without
  Mediator analysis."

**C. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `MEDIATOR_VERDICT` (payload: `action_type` ∈
  {advice, surgical_fix, lockdown}, `severity` (surgical_fix-only)
  ∈ {brief, extended}, `confidence` ∈ {auto-apply, needs-review},
  `scope` ∈ {caller-only, system-wide}, `mediator_depth` ∈
  {1, 2}, `verdict_path` pointing at
  `.coord/mediator/verdict/<ts>.json`).
- `MEDIATOR_ESCALATED_TO_PEER` (payload: `from_verdict_path`,
  `peer_invocation_reason: "needs-review"`).
- `MEDIATOR_PEER_AGREED` / `MEDIATOR_PEER_DISAGREED` (payload:
  `first_verdict_path`, `second_verdict_path`, `agreed_action`
  or `first_action`/`second_action`; for AGREED, `applied_severity`
  reflects the more-conservative-of-two per disposition #5).
- `MEDIATOR_ESCALATED_TO_USER` (payload: `scope`, `reason`,
  `caller_session` (caller-only only), `lockdown_active` (bool)).
- `LOCKDOWN_ACTIVATED` / `LOCKDOWN_CLEARED` (payload: `reason`,
  `reason_source` ∈ {mediator_verdict, critical_bypass},
  `mediator_verdict_path` (null for critical_bypass),
  `archived_to` (CLEARED only; path under
  `.coord/mediator/lockdown_archive/`)).
- `HOOK_DENIED_BY_LOCKDOWN` (payload: `hook_name`, `tool_name`,
  `session_id`).
- `CRITICAL_CONDITION_DETECTED` (payload: `condition` ∈
  {corrupt_schema, impossible_state, repeated_jq_failure,
  pid_collision}, `triggering_observation`).
- `MEDIATOR_USER_APPROVED` (payload: `verdict_path`, `approved_action`,
  `approving_session`).

**D. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** — add:
- `mediator_enabled: true` (existing per CLAUDE.md §C.2 emergency
  override; promote to formal config schema).
- `mediator_max_depth: 2` (hard ceiling; bounds [1, 2] enforced by
  `coord health`).
- `mediator_critical_bypass_enabled: true` (emergency disable for
  debugging only; default true).

**E. `IMPLEMENTATION_PLAN.md` §3.3 sessions.json schema** — no change
(lockdown.json is a sibling file under `.coord/mediator/`, not part
of sessions.json).

**F. `IMPLEMENTATION_PLAN.md` §4 component specs** — add:
- `.coord/mediator/lockdown.json` schema (per disposition #2 + #3):
  ```
  {
    "active": true,
    "reason": "<human-readable text for user display>",
    "reason_source": "critical_bypass" | "mediator_verdict",
    "started_at": "<ISO timestamp>"
  }
  ```
  Existence-based check: `coord_lockdown_check` simply tests
  whether the file exists (no field parsing for the gate). Cleared
  lockdowns archive to
  `.coord/mediator/lockdown_archive/<ts>.cleared.json` for audit.
- `.coord/mediator/verdict/<ts>.json` schema:
  `{ts, mediator_id (UUID for the spawned subagent), depth ∈ {1,2}, action_type ∈ {advice, surgical_fix, lockdown}, severity (surgical_fix-only) ∈ {brief, extended}, confidence ∈ {auto-apply, needs-review}, scope ∈ {caller-only, system-wide}, summary (string), detailed_reasoning (string), proposed_state_changes (array), input_pending_entry (object), referenced_events (array of event_id), referenced_sessions (array of session_id)}`.
- `lib/lockdown.sh` helper:
  - `coord_lockdown_check` (returns 0 if `lockdown.json` exists,
    1 otherwise; existence-based gate per disposition #2; no flock
    needed for the gate read since file is atomic-renamed in/out).
  - `coord_lockdown_activate <reason> <reason_source>` (writes
    lockdown.json atomically via temp+rename; emits
    `LOCKDOWN_ACTIVATED` event).
  - `coord_lockdown_clear` (atomic rename of lockdown.json →
    `lockdown_archive/<ts>.cleared.json`; emits `LOCKDOWN_CLEARED`
    event with `archived_to` payload).
  - `coord_lockdown_emit_deny` (reads `reason` from lockdown.json;
    formats the deny JSON with reason text mirroring §B.2 lock-held
    deny shape; sourced by every coord hook at top).
- `coord mediate` CLI extensions:
  - `coord mediate` — manual primitive (writes
    `.coord/mediator/pending.jsonl` entry with `kind:"manual"`).
  - `coord mediate --approve <action>` — consume user-escalation
    banner choice; reads pending verdict, applies the approved
    action, logs `MEDIATOR_USER_APPROVED` event.
  - `coord mediate status` — show active lockdown / recent verdicts /
    pending entries (operator visibility).
- `hooks/mediator_agent.md` full spec: agent prompt structure
  (context bundle per P5; rules-of-the-game restated explicitly;
  state-mutation must use Bash + atomic_write helpers, NOT Edit/
  Write/NotebookEdit).

**G. `CLAUDE.md` §B.6 (Mediator invocation protocol)** — rewrite to
reflect:
- 4-action contract (A/B/D in code; C as severity gradient on B).
- 2-state confidence (auto-apply | needs-review).
- Max-depth-2 escalation with peer Mediator review.
- Scope-dependent user escalation: caller-only banner with
  `coord mediate --approve <action>` commands; system-wide
  lockdown.
- Critical-conditions bypass.

**H. `CLAUDE.md` §B.10 anti-patterns** — add two entries:
- "**Do not ignore a lockdown banner.** During lockdown every hook
  emits deny; retrying immediately wastes turns and may delay
  Mediator's fix. Wait until the next operation succeeds (lockdown
  cleared) before resuming work."
- "**Do not use Edit/Write/NotebookEdit to mutate coord state.**
  Subagent_filter no-ops these for the Mediator subagent (per
  Decision 2.17). Mediator MUST use Bash + `lib/atomic_write.sh`
  helpers for state mutations."

**I. `CLAUDE.md` §B.11 quick-reference table** — new row:
- Situation: "Lockdown active." You do: "Wait; retry on next prompt
  after operation succeeds." Hook does: "Emits deny on every tool
  call until lockdown cleared." Enforcement: "[HOOK-ENFORCED]."

**J. `CLAUDE.md` §C.2 emergency override** — affirm
`coord config set mediator_enabled false` still works; add affirmation
that disabling Mediator does NOT disable lockdown (lockdown can be set
by critical-conditions bypass even if mediator is disabled, since the
bypass is the safety mechanism for cases Mediator cannot handle).

### Implementation-task dependencies

- T3.03 (lockdown flag mechanism) implements §F lockdown.json schema +
  §F lib/lockdown.sh + every-hook lockdown check, plus the rename
  `phase2_invariant.bats → phase3_invariant.bats` per §B done-when
  expansion. **Gated on this PR approval.**
- T3.06 (Mediator spawn POC) precedes T3.07; POC may surface
  implementation constraints worth folding into this PR before final
  approval. **POC is investigative; PR approval can be conditional on
  POC findings.**
- T3.07 (Mediator agent hook) implements §F hooks/mediator_agent.md +
  §F coord mediate CLI extensions + the verdict-write pass. **Gated on
  this PR approval AND T3.06 POC closure.**
- T3.09 (ship-gate fixtures) verifies §B done-when criteria
  end-to-end.

### Ambiguity dispositions (resolved 2026-04-26 by user)

1. **Verdict-log schema specificity (§F).** **DEFERRED to T3.07
   design checkpoint** per user direction. T3.06 POC may discover
   additional fields needed; final schema confirmed at T3.07
   pre-implementation user checkpoint.

2. **Lockdown clearing protocol.** **RESOLVED — atomic-deletion-
   with-rename-for-audit (option A).** Hooks check existence
   ("does lockdown.json exist?") which is simpler than parsing a
   field. Cleared lockdowns archive to
   `.coord/mediator/lockdown_archive/<ts>.cleared.json` for audit.
   During lockdown, Mediator's own state mutations go through Bash
   + atomic_write helpers (which do NOT route through Edit/Write/
   NotebookEdit hooks per install.sh hook matchers); once mutation
   done, Mediator deletes lockdown.json (rename-to-archive); next
   hook on any session sees no lockdown → resumes.

3. **Lockdown reason text structure.** **RESOLVED — both sources
   tracked via `reason_source` field.** Schema for lockdown.json:
   ```
   {
     "active": true,
     "reason": "<human-readable text for user display>",
     "reason_source": "critical_bypass" | "mediator_verdict",
     "started_at": "<ISO timestamp>"
   }
   ```
   Hooks read `reason` for the deny banner shown to Claude;
   `reason_source` is for audit (events.jsonl payload + archive).
   For Mediator-path lockdowns: `reason` is `mediator_verdict.summary`,
   `reason_source` = `"mediator_verdict"`. For critical-bypass
   lockdowns: `reason` is the condition name (e.g., "corrupt schema
   detected"), `reason_source` = `"critical_bypass"`.

4. **Action C as severity gradient on B.** **RESOLVED — confirmed.**
   Verdicts emit `action_type ∈ {advice, surgical_fix, lockdown}`
   (three values; user prompt's A/B/D map to advice/surgical_fix/
   lockdown). For `surgical_fix`, additional field
   `severity ∈ {brief, extended}` distinguishes user-prompt
   action types B (brief = surgical) and C (extended = longer).
   Three action types; severity is a secondary axis on
   `surgical_fix` only. The §C events kind list and §F verdict
   schema below are updated to use these exact enum values.

5. **Confidence variance during agreement.** **RESOLVED — confirmed.**
   Final algorithm:
   ```
   verdict_1 = mediator_invocation(brief, depth=1)
   if verdict_1.confidence == "auto-apply":
       apply(verdict_1.action_type, verdict_1.severity); end
   else:  # needs-review
       verdict_2 = mediator_invocation(brief, depth=2,
                                       prior_verdict=verdict_1)
       if verdict_2.action_type == verdict_1.action_type:
           # agreement on action_type — apply with MORE
           # CONSERVATIVE severity (defensive default).
           # severity ranking: extended > brief; for action_type
           # other than surgical_fix, severity is N/A.
           sev = max(verdict_1.severity, verdict_2.severity)
           apply(verdict_2.action_type, sev); end
       else:
           escalate_to_user(verdict_1, verdict_2); end
   ```
   Severity disagreement → apply with more conservative severity
   (defensive default). Action_type disagreement → escalate to
   user (no third Mediator).

6. **CLAUDE_COORD env var semantics for spawned Mediator
   subagents.** **DEFERRED to T3.06 POC** per user direction.
   This PR's approval is conditional: if POC reveals constraints
   requiring PR amendment, amendment lands before T3.07 design
   checkpoint.

### Cross-references

- T3.06 POC findings will be cited in this PR's resolution before
  approval.
- PR-PHASE3-02 (watchdog) feeds into Mediator via `kind=stale_active`
  and `kind=pid_recycled` pending entries — the kind list in §C
  partially duplicates kinds proposed in PR-PHASE3-02; the two PRs
  must land together to keep the kind list consistent.
- PR-PHASE3-03 (pending.jsonl unification) is independent; this PR
  assumes unified pending.jsonl exists.
- PR-PHASE3-04 (GC) bundles into Mediator runs; this PR's verdict-
  write pass is the trigger point for GC.
- FINDINGS — none currently OPEN against this PR; T3.06 POC may
  surface new findings.

### Non-changes (deliberate)

- `permissionDecisionReason` text format unchanged for the
  lock-held-by-other branch (existing Phase 2). Only the new lockdown
  branch adds a different reason text.
- Validator agent (Phase 4) untouched.
- Task delegation (Phase 6) untouched.
- Subagent_filter (PR-PHASE0-01) extends naturally to Mediator
  subagents — no modification needed; Mediator's tool calls fall in
  the existing subagent-skip path.

### Acknowledgement

APPROVED 2026-04-26 (user dispositioned ambiguities 1-5 inline; #1 +
#6 explicitly deferred to T3.06/T3.07 checkpoints per user
direction). Status DRAFT → APPROVED. Final merge into
IMPLEMENTATION_PLAN.md / CLAUDE.md folds into phase-3-signoff.md.

---

## PR-PHASE3-02 — Peer watchdog design contract (Decision 2)

**Date:** 2026-04-26
**Author:** Phase 3 builder (draft per user-resolved Decision 2 + P4
threshold values; ambiguity dispositions applied 2026-04-26 post-T3.02).
**Status:** APPROVED — gates T3.04 (cache infra) and T3.05 (probe
logic). Final merge folds into phase-3-signoff.md.
**Driver:** User direction (Phase 3 resume prompt, Decision 2 verbatim;
P4 threshold preferences).

### Observed gap requiring change

Plan §5 Phase 3 names the watchdog as "lib/watchdog.sh: sampled from
SessionStart + PreToolUse; PID+lstart liveness; 2-voter consensus
requiring PID-absent/recycled" but does not specify the trigger model
(when ambient suspicion fires a probe), the duplicate-prevention
mechanism (multiple sessions noticing the same anomaly), the
recent-checks cache (avoiding repeat probes), or the relationship to
Mediator (watchdog as triage layer, not direct decision-maker).
Implementation needs the contract pinned before T3.04/T3.05 land.

### User-resolved decision (verbatim)

Watchdog is the Mediator's lightweight pre-filter. Runs FAST (bash,
milliseconds) and answers ONE question: "is this anomaly real, or
false alarm?"

**Trigger model:**
- Calling session itself has a problem (e.g., lock denied with
  unresponsive holder) → invoke Mediator directly. NOT watchdog.
- Calling session observes suspicion ABOUT another session (e.g.,
  notices session X's last_activity is 10 min old, notices X's lock
  acquired 30 min ago and never refreshed) → invoke watchdog.

Watchdog's role is reception/triage for ambient suspicion, not crisis
response.

**Caller does NOT block:** Watchdog is invoked fire-and-forget. The
calling session continues its own work. If watchdog confirms real
problem, watchdog invokes Mediator on behalf of the caller. Caller is
signaled later via notifications if its work depended on the
resolution.

**Duplicate watchdog prevention:** When 5+ sessions notice the same
anomaly simultaneously, only ONE watchdog runs.
- File: `.coord/watchdog/checking/<target_session_id>.lock`
- Created atomically via `flock + temp + rename`.
- Second invoker exits no-op immediately if file exists.
- Lock file deleted when watchdog completes.
- Lock file has TTL (e.g., 30 sec); stale lock from crashed watchdog
  auto-cleared by next observer via age check.

**Recent-checks cache:** After watchdog completes, verdict cached.
- File: `.coord/watchdog/recent_checks.jsonl` (append-only).
- Each entry: `{ts, target, verdict, reason, valid_until}`.
- TTL by verdict type:
  - `alive` → 60 seconds.
  - `dead` → until next session_start of any session.
  - `uncertain` → 30 seconds.
- Before invoking watchdog, sessions check recent_checks.jsonl. If a
  non-expired verdict exists for the target, skip invocation.

**Watchdog's output (3 outcomes):**
- "target alive — false alarm" → write verdict to recent_checks; do
  NOT invoke Mediator; signal caller (if waiting) "no action needed."
- "target dead — Mediator needed" → write verdict; invoke Mediator
  with `kind=stale_active` or `kind=pid_recycled` (Mediator decides
  specific kind based on observation).
- "uncertain" → write verdict; invoke Mediator (Mediator handles
  ambiguity).

Watchdog NEVER writes a verdict directly. Triage layer only.

**Watchdog vs direct Mediator invocation flowchart:**
```
Session encounters something:
├── Self: I am blocked / I am waiting / I have a concrete problem
│   → invoke Mediator directly (skip watchdog)
└── Other: I notice another session looks suspicious
    → invoke watchdog
        ├── alive → no-op, log
        ├── dead → watchdog invokes Mediator
        └── uncertain → watchdog invokes Mediator
```

### Pre-loaded ambient-suspicion thresholds (per user P4 preferences)

These are STARTING values; Phase 7 stress-test data may revise them.
Document each as a tunable in `config.json` (similar to
`lock_ttl_seconds`, Decision 2.20):

1. `last_activity > 10 minutes` (sessions[<id>].last_activity_at older
   than 600 s) → suspicious; trigger watchdog probe.
2. `lock acquired_at > 30 minutes AND last_refresh_at == acquired_at`
   (lock taken 30 min ago and never refreshed since) → suspicious;
   trigger watchdog probe.
3. `RESUME_ORPHAN_LOCK_DETECTED` event in recent events.jsonl tail
   (within last 60 s of probe-evaluation time) → deterministic
   trigger; bypass cache lookup (this is a known anomaly signal from
   the resume path, not ambient).
4. PID listed in `sessions.json` but `ps -p <pid>` returns empty (or
   `lstart` mismatch) → deterministic trigger; bypass cache lookup.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §5 Phase 3 Scope.** Replace the
"lib/watchdog.sh: sampled from SessionStart + PreToolUse; PID+lstart
liveness; 2-voter consensus requiring PID-absent/recycled" bullet
with (note: 2-voter consensus retired per disposition #3 in favor of
single-watchdog model + dedupe lock):
- "lib/watchdog.sh: invoked from PreToolUse paths (specifically
  pre_tool_use_any.sh, the existing cross-cutting concern site) when
  ambient-suspicion checks fire. Fire-and-forget caller; triage-only
  (3-outcome verdict: alive | dead | uncertain). Never decides — only
  invokes Mediator on dead/uncertain."
- "lib/watchdog_cache.sh: recent_checks.jsonl producer/consumer with
  verdict-typed TTL (alive 60 s, dead until next session_start,
  uncertain 30 s); cache-hit lookup gates probe invocation."
- "Single-watchdog-per-anomaly via dedupe lock:
  `.coord/watchdog/checking/<target>.lock` created via atomic
  temp+rename; second observer no-ops; 30 s stale-TTL auto-cleared
  by next observer."
- "PID+lstart liveness probing within watchdog: `ps -p <pid> -o lstart=`
  comparison; PID-absent OR PID-recycled (lstart mismatch) → dead;
  PID-present with matching lstart → alive."
- "Eviction triggered on watchdog verdict 'dead' + Mediator
  confirmation. NO 2-voter consensus mechanic — single watchdog +
  Mediator review is the chain. anomaly_votes field in sessions.json
  schema is reserved (inactive in Phase 3)."

**B. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `WATCHDOG_PROBED` (payload: `target_session`, `trigger_reason` ∈
  {last_activity, lock_unrefreshed, resume_orphan_lock,
  pid_absent}, `verdict` ∈ {alive, dead, uncertain},
  `probe_latency_ms`).
- `WATCHDOG_CACHE_HIT` (payload: `target_session`, `cached_verdict`,
  `cached_at`, `valid_until`; emitted when probe is skipped).
- `WATCHDOG_DUPLICATE_SKIPPED` (payload: `target_session`,
  `existing_lock_age_seconds`; emitted when concurrent observer hits
  existing checking lock).
- `WATCHDOG_ESCALATED_TO_MEDIATOR` (payload: `target_session`,
  `verdict` ∈ {dead, uncertain}, `mediator_pending_kind` ∈
  {stale_active, pid_recycled, ambiguous_state}).
- `WATCHDOG_STALE_LOCK_CLEARED` (payload: `target_session`,
  `stale_lock_age_seconds`; when an observer auto-clears a crashed-
  watchdog's leftover checking lock).

**C. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** — add:
- `watchdog_enabled: true` (per plan §5 risk row "rollback:
  watchdog_enabled: false").
- `watchdog_suspicion_last_activity_seconds: 600` (10 min; bounds
  [60, 3600]).
- `watchdog_suspicion_lock_unrefreshed_seconds: 1800` (30 min; bounds
  [300, 7200]).
- `watchdog_recent_checks_ttl_alive_seconds: 60` (bounds [10, 600]).
- `watchdog_recent_checks_ttl_uncertain_seconds: 30` (bounds [10, 300]).
- `watchdog_dedupe_lock_ttl_seconds: 30` (bounds [10, 120]).

`coord health` validates all bounds.

**D. `IMPLEMENTATION_PLAN.md` §3.3 sessions.json schema** — no new
field (anomaly_votes already exists). Per disposition #3, document
anomaly_votes as **reserved for future cross-validation; inactive
in Phase 3**:
- Schema annotation: "anomaly_votes — reserved field for future
  cross-watchdog validation. Phase 3 uses a single-watchdog-per-
  anomaly model (dedupe lock); this field remains an empty object
  in Phase 3 and is not written or read by any Phase 3 component.
  Future phases may activate."
- No watchdog writes; no Mediator reads.

**E. `IMPLEMENTATION_PLAN.md` §4 component specs** — add:
- `lib/watchdog.sh`:
  - `coord_watchdog_check_ambient_suspicion <sessions_snapshot>` — scans
    sessions for the 4 triggers; returns target_id + reason for each
    suspicious target found; cheap (single jq filter); called from
    pre_tool_use_any.sh.
  - `coord_watchdog_probe <target_id> <reason>` — full probe: check
    cache → check dedupe lock → run PID/lstart probe → write verdict
    to recent_checks → invoke Mediator if dead/uncertain → release
    dedupe lock; backgrounded by caller (`coord_watchdog_probe ... &`)
    so caller is fire-and-forget. NO anomaly_votes write
    (per disposition #3).
- `lib/watchdog_cache.sh`:
  - `coord_watchdog_cache_lookup <target_id>` — returns cached verdict
    if non-expired, else "miss".
  - `coord_watchdog_cache_write <target_id> <verdict> <reason>` —
    appends to recent_checks.jsonl with TTL-typed valid_until.
  - `coord_watchdog_cache_invalidate_dead_on_session_start` — called
    from session_start.sh; expires all "dead" entries.
- `.coord/watchdog/checking/<target>.lock` — empty file used as
  dedupe sentinel; created via temp+rename.
- `.coord/watchdog/recent_checks.jsonl` — append-only verdict cache.

**F. `CLAUDE.md` §B.7-§B.8 (Mediator vs watchdog flow)** — adjust to
clarify:
- §B.7 amended: "you do not invoke the Mediator directly except when
  YOUR session has a concrete problem (blocked write, unresolvable
  state). Ambient suspicion about ANOTHER session goes through the
  watchdog (fire-and-forget) which triages and invokes Mediator only
  if the suspicion is real."
- §B.8 amended: passive wait remains; watchdog is orthogonal (watchdog
  is for cross-session triage, not self-blocking).

### Implementation-task dependencies

- T3.04 (cache infra) implements §E lib/watchdog_cache.sh +
  recent_checks.jsonl + checking/ dedupe lock files. **Gated on this
  PR approval.**
- T3.05 (probe logic) implements §E lib/watchdog.sh probe heuristics,
  PID/lstart liveness, anomaly_votes write, Mediator escalation.
  **Gated on this PR approval AND T3.04 close.**
- Watchdog → Mediator handoff (§B WATCHDOG_ESCALATED_TO_MEDIATOR)
  requires PR-PHASE3-01 Mediator pending kinds (`stale_active`,
  `pid_recycled`, `ambiguous_state`) to exist. **Cross-PR
  dependency: PR-PHASE3-01 + PR-PHASE3-02 land together; T3.04 can
  start as soon as both are approved.**

### Ambiguity dispositions (resolved 2026-04-26 by user)

1. **Watchdog invocation site (specifically which hook).**
   **RESOLVED — pre_tool_use_any.sh confirmed.** Cross-cutting
   concern site; watchdog called only when ambient-suspicion
   signals are present (not on every tool call — the
   suspicion-detection scan is the gate, the probe invocation is
   conditional). Existing notification + corruption + mediator-
   pending consumers in pre_tool_use_any.sh share the same
   pattern.

2. **Hook latency budget impact.** **RESOLVED — <50 ms p99
   acceptable target; <2 s is the hard ceiling.** Phase 0
   Experiment #7 baseline (60 ms avg / 435 ms p99 for full
   flock+jq RMW) leaves ample headroom. T3.04 close report MUST
   include actual measurement; flag for user review if real
   measurement exceeds 100 ms p99.

3. **anomaly_votes schema.** **RESOLVED — keep field reserved
   in §3.3 schema, do NOT activate in Phase 3.** Watchdog acts as
   single-instance triage layer per Decision 2 (duplicate-
   prevention via `.coord/watchdog/checking/<target>.lock` ensures
   only one watchdog runs per anomaly observation). Multi-voter
   consensus is retired in favor of the single-watchdog model.
   Document anomaly_votes in §3.3 as "reserved for future
   cross-validation; inactive in Phase 3." This simplifies §A
   (no anomaly_votes write), §B (no anomaly_votes events), and
   §E (no per-voter logic in lib/watchdog.sh). Plan §5 Phase 3
   "2-voter consensus" line in scope edits to remove the
   2-voter requirement; eviction triggers on Watchdog verdict
   "dead" + Mediator confirmation.

4. **PID-recycled detection portability.** **RESOLVED — verify
   in T3.05 close report.** Phase 0 already established
   `ps -p <pid> -o lstart=` works on both BSD (macOS) and GNU
   (Linux); the new watchdog use must respect the same idiom.
   T3.05 close report MUST include explicit Linux probe
   confirming the comparison is portable; flag if any divergence
   surfaces.

### Cross-references

- PR-PHASE3-01 (Mediator) consumes WATCHDOG_ESCALATED_TO_MEDIATOR
  events and the `stale_active` / `pid_recycled` / `ambiguous_state`
  pending kinds.
- PR-PHASE3-03 (pending.jsonl unification) is independent.
- FINDINGS — none currently OPEN against this PR.

### Non-changes (deliberate)

- Existing `last_activity_at` / `last_refresh_at` / `pid` / `pid_lstart`
  fields in sessions.json schema unchanged.
- Existing `RESUME_ORPHAN_LOCK_DETECTED` event (PR-PHASE1-01) is
  reused as a watchdog deterministic trigger; no change to its
  payload.
- Mediator's eviction algorithm itself (when to actually delete a
  session row + its locks) is in PR-PHASE3-01 scope, not here.

### Acknowledgement

APPROVED 2026-04-26 (user dispositioned all 4 ambiguities inline;
anomaly_votes simplification removes one source of complexity from
T3.05; cross-PR dependency with PR-PHASE3-01 noted).

---

## PR-PHASE3-03 — pending.json/jsonl unification (Decision 4)

**Date:** 2026-04-26
**Author:** Phase 3 builder (draft per user-resolved Decision 4;
ambiguity dispositions applied 2026-04-26 post-T3.02).
**Status:** APPROVED — bundles into T3.07 (Mediator agent hook).
**Driver:** User direction (Phase 3 resume prompt, Decision 4 verbatim).

### Observed gap requiring change

Phase 1 shipped `pending.json` for Mediator's `corrupt_state` flag
(single-entry semantics, atomic-write/rename). Phase 2 (T2.04)
shipped `pending.jsonl` for `flock_timeout` (append-only, multi-
entry, HWM consumer). The two coexist by historical accident; the
plan §5 Phase 3 Mediator thread implies a unified queue ("multiple
pending kinds: corrupt_state, flock_timeout, plus Phase 3 new kinds")
but does not formalize the migration. Without unification, Phase 3's
Mediator agent has to consume from two distinct files with different
semantics — duplicating logic and risking missed entries.

### User-resolved decision (verbatim)

Migrate `corrupt_state` from legacy `pending.json` to `pending.jsonl`.
Specifically:
- All Mediator pending kinds (`corrupt_state`, `flock_timeout`, plus
  Phase 3 new kinds) write to `pending.jsonl`.
- Single consumer pattern: `pre_tool_use_any.sh` + `session_start.sh`
  consume from `pending.jsonl` uniformly.
- Legacy `pending.json` file is removed at install time. Install
  migrates: if pending.json exists with active corrupt_state entry,
  append to pending.jsonl, delete pending.json.
- `coord_consume_corrupt_state_flag` function is updated to consume
  from JSONL queue.
- Existing bats tests for corrupt_state are updated to assert the new
  flow.

This work bundles into the Mediator implementation task (T3.07), not
standalone.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §5 Phase 3 Mediator thread** — extend
the bullet "flag file infrastructure appears here" (currently scoped
to Phase 2 corrupt_state + flock_timeout) with:
- "Phase 3: pending.json → pending.jsonl unification. corrupt_state
  migrates to JSONL form; legacy pending.json removed at install
  time. Single consumer at pre_tool_use_any.sh + session_start.sh."

**B. `IMPLEMENTATION_PLAN.md` §4 component specs** — extend:
- `install.sh` migration step (idempotent):
  - If `.coord/mediator/pending.json` exists and parses as JSON with
    `kind == "corrupt_state"`: extract fields → format as JSONL line
    matching pending.jsonl schema (top-level `ts/kind/session/source`
    + `.payload`) → append to `.coord/mediator/pending.jsonl` (under
    flock on pending.lock) → delete pending.json.
  - If pending.json exists but does not parse: archive to
    `pending.legacy.<ISO>.json` for forensic; delete pending.json;
    log INSTALL_MIGRATE_FAILED event.
  - If pending.json absent: no-op.
  - Migration runs on `install.sh --repair` for existing installs and
    on first install (pending.json never exists on first install, so
    no-op there).
- `install.sh --uninstall` cleanup: removes both pending.jsonl and
  pending.consumed (HWM) along with the rest of `.coord/mediator/`
  (existing behavior; no new cleanup needed).
- `lib/atomic_write.sh` `coord_consume_corrupt_state_flag` rewrite:
  reads from pending.jsonl HWM consumer (existing
  `coord_mediator_consume_pending` from lib/mediator_pending.sh,
  T2.04). Filters pending entries with `kind == "corrupt_state"` for
  banner emission; non-corrupt kinds are passed through to the
  generic mediator-pending banner consumer.
- Defensive consumer fallback (NOT in user direction; recommended for
  robustness): the consumer code reads BOTH pending.jsonl AND
  pending.json on every invocation. If pending.json is found (e.g.,
  T3.07-deployed coord runs against an install that pre-dates T3.07),
  drains pending.json into pending.jsonl on first read and then
  ignores pending.json forever. This decouples migration from strict
  install-order coupling. **Optional; flagged for confirmation.**

**C. `CLAUDE.md` §B.9.2 (corrupted state file)** — update step 3 from
"writes Mediator flag (kind: 'corrupt_state')" to:
"appends a `pending.jsonl` entry with `kind: 'corrupt_state'`,
preserving the existing semantics (banner emission via the unified
mediator-pending consumer; non-repetition via HWM advance)."

### Implementation-task dependencies

- T3.07 (Mediator agent hook) bundles this PR as part of its
  delivery: corrupt_state migration + install.sh changes + consumer
  rewrite all land in the T3.07 commit (per Decision 4: "bundles into
  Mediator implementation task, not standalone").
- T2.04 already shipped pending.jsonl producer + consumer for
  flock_timeout; this PR extends to corrupt_state. **No dependency on
  T2.04 changes.**
- bats updates: `corruption_recovery.bats` rewritten to assert JSONL
  flow; `mediator_flock_timeout.bats` unchanged (already JSONL).

### Ambiguity dispositions (resolved 2026-04-26 by user)

1. **Defensive consumer fallback.** **RESOLVED — strict mode
   (option A); no defensive fallback.** Migration is
   deterministic; defensive read-both adds complexity for a
   no-real-scenario edge case. If post-install pending.json
   appears, that is unsupported state — log a warning, do NOT
   auto-merge. Implementation: install.sh migration is the only
   transition path; consumer reads only pending.jsonl.

2. **Schema delta in pending.jsonl entries for corrupt_state.**
   **RESOLVED — confirmed as drafted.** Migration mapping:
   ```
   legacy pending.json:                                  pending.jsonl entry:
   {kind:"corrupt_state",                                {ts: <ts>,
    ts: <ts>,                                             kind:"corrupt_state",
    archived_to: ".coord/sessions.corrupt.<ts>.json",     session: null,
    detected_by: "atomic_write.sh"}                       source:"install_migration",
                                                          payload: {
                                                            archived_to: "...",
                                                            detected_by: "atomic_write.sh"
                                                          }}
   ```
   `session` field is null because corrupt_state is not
   session-specific.

### Cross-references

- PR-PHASE3-01 (Mediator) — Mediator agent consumes the unified
  pending.jsonl; this PR makes corrupt_state visible to the agent.
- PR-PHASE3-04 (GC) — GC operates on pending.jsonl; this PR ensures
  all kinds live there.
- T2.04 (existing code) — `lib/mediator_pending.sh` helpers reused.
- FINDINGS — none currently OPEN against this PR.

### Non-changes (deliberate)

- pending.consumed (HWM file) shape unchanged; existing single-
  integer-line format continues.
- pending.lock unchanged; flock-on-pending.lock guards all writes.
- Phase 1 corruption-recovery banner format unchanged (consumer
  produces same text; only the underlying queue shape changes).

### Acknowledgement

APPROVED 2026-04-26 (strict-mode migration confirmed; schema
mapping confirmed). Bundles into T3.07; no separate
implementation task.

---

## PR-PHASE3-04 — pending.jsonl GC bundled with Mediator runs (Decision 6)

**Date:** 2026-04-26
**Author:** Phase 3 builder (draft per user-resolved Decision 6;
ambiguity dispositions applied 2026-04-26 post-T3.02).
**Status:** APPROVED — bundles into T3.07 (Mediator agent hook).
**Driver:** User direction (Phase 3 resume prompt, Decision 6 verbatim).

### Observed gap requiring change

T2.04 shipped pending.jsonl as append-only with a HWM consumer
(pending.consumed). Without garbage collection, pending.jsonl grows
unboundedly across the system's lifetime — every flock_timeout,
corrupt_state, watchdog escalation, and manual coord mediate adds a
line. Plan §5 Phase 3 implies the Mediator agent owns this state but
does not specify GC. Phase 2 signoff flagged "pending.jsonl GC" as a
Phase 3 Open Question.

### User-resolved decision (verbatim)

Garbage collection bundled with Mediator agent runs. Specifically:
- When Mediator finishes a verdict-write pass, it ALSO truncates
  consumed entries from pending.jsonl.
- Truncation rule: any entry with index <= pending.consumed
  high-water-mark AND age > 24 hours is removed.
- Single combined operation: rewrite pending.jsonl atomically (via
  atomic_write), keeping only un-consumed entries plus
  recently-consumed ones (< 24h).
- No separate `coord mediator gc` CLI; GC is implicit in agent runs.

24-hour retention preserves recent-history visibility for debugging
(operator can inspect "what happened last hour" via coord events)
without unbounded growth.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §5 Phase 3 Mediator thread** — extend
to include:
- "GC of pending.jsonl bundled with verdict-write pass: 24h
  retention; atomic rewrite via lib/atomic_write.sh primitives;
  implicit (no separate CLI)."

**B. `IMPLEMENTATION_PLAN.md` §4 component spec** — `hooks/mediator_agent.md`
post-verdict step:
- After Mediator writes its verdict to
  `.coord/mediator/verdict/<ts>.json` (per PR-PHASE3-01), it also
  performs pending.jsonl GC.
- Algorithm:
  ```
  1. Read pending.consumed → HWM (integer index, line-count).
  2. Read pending.jsonl line-by-line; keep lines where:
     (line_index > HWM) OR (now - line.ts < retention_hours * 3600).
  3. Atomically rewrite pending.jsonl with kept lines (temp +
     rename under flock on pending.lock).
  4. After rewrite, advance pending.consumed to (HWM -
     removed_count) so that the HWM still points at the
     "last-consumed" entry in the new file.
  5. Emit PENDING_GC_RUN event with kept_count, removed_count,
     before_size_bytes, after_size_bytes.
  ```
- HWM rebasing (step 4) is critical: removing N lines from before HWM
  shifts every subsequent index by -N; HWM must adjust accordingly so
  the consumer continues from the correct position.

**C. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `PENDING_GC_RUN` (payload: `kept_count`, `removed_count`,
  `before_size_bytes`, `after_size_bytes`, `retention_hours`,
  `triggered_by_verdict_path`).

**D. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** — add:
- `mediator_pending_retention_hours: 24` (bounds [1, 168] i.e. 1
  hour minimum, 1 week maximum).

`coord health` validates the bound.

**E. `IMPLEMENTATION_PLAN.md` §4 lib/mediator_pending.sh** — extend
(this file shipped in T2.04):
- New function `coord_mediator_gc_pending <retention_hours>`:
  implements the algorithm in §B. Called only by Mediator agent
  hook (no external callers in v1).
- Atomic rewrite uses lib/atomic_write.sh primitives extended for
  non-state-file targets — pending.jsonl is not sessions.json but
  uses the same temp + rename + flock idiom. Add a generic helper
  `coord_atomic_rewrite_jsonl <path> <lock_path> <filter_fn>` to
  lib/atomic_write.sh for this and future similar use.

### Implementation-task dependencies

- T3.07 (Mediator agent hook) bundles this PR as part of its
  delivery: GC trigger, rewrite, HWM rebase all land in the T3.07
  commit (per Decision 6: "bundles into Mediator implementation
  task, not standalone").
- T2.04 (existing) — pending.consumed HWM file is the index source.
- PR-PHASE3-03 (pending.jsonl unification) — must land first so all
  pending kinds live in pending.jsonl before GC operates.

### Ambiguity dispositions (resolved 2026-04-26 by user)

1. **GC frequency on healthy systems.** **RESOLVED — no
   periodic trigger.** Mediator-bundled GC suffices;
   pending.jsonl growth on healthy systems is negligible (only
   flock_timeout entries, rare). Revisit if Phase 7 stress test
   reveals user-visible bloat.

2. **HWM atomicity vs GC atomicity.** **RESOLVED — two-phase
   confirmed.** HWM advance (existing T2.04 mechanism on consumer
   side) is separate from GC truncation. Two-phase: HWM advances
   during banner emission; GC reads stable HWM during rewrite.
   No new atomicity needed beyond what atomic_write.sh already
   provides.

3. **Crash recovery during GC.** **RESOLVED — single flock
   encloses both rewrite + HWM update.** The GC critical section
   holds flock on pending.lock for the entirety of: read HWM →
   read pending.jsonl → compute kept lines → atomic temp+rename
   for pending.jsonl → atomic temp+rename for pending.consumed.
   If Mediator crashes mid-section, the flock releases on fd
   close; either both files are pre-state or both are post-state
   (no partial application).

4. **pending.consumed format after GC.** **RESOLVED — HWM
   rebases to "lines 1..N are consumed in the new file".** The
   HWM is a single integer line; semantics continue to mean
   "lines 1..HWM are consumed" — but interpreted relative to the
   POST-GC file. Example: if pre-GC file had 10 lines with HWM=7
   (lines 1-7 consumed) and GC removes 5 entries (lines 1-5
   were >24h old; lines 6-7 were <24h, so kept; lines 8-10 were
   un-consumed), post-GC file has 5 lines (old lines 6-10) and
   HWM=2 (the first 2 lines of the new file = old lines 6-7,
   which were consumed).

### Cross-references

- PR-PHASE3-01 (Mediator) — verdict-write pass triggers GC.
- PR-PHASE3-03 (pending.jsonl unification) — must land first.
- T2.04 (existing) — HWM mechanism reused.
- FINDINGS — none currently OPEN against this PR.

### Non-changes (deliberate)

- T2.04 producer (`coord_mediator_emit_pending`) and consumer
  (`coord_mediator_consume_pending`) function signatures unchanged.
- pending.lock semantics unchanged.
- No separate `coord mediator gc` CLI (per Decision 6 explicit).

### Acknowledgement

APPROVED 2026-04-26 (all 4 ambiguities dispositioned; HWM-rebase
algorithm clarified with worked example). Bundles into T3.07;
PR-PHASE3-03 cross-PR dependency noted.

---

## PR-PHASE4-01 — Validator agent design contract (Decision 2)

**Date:** 2026-04-26
**Author:** Phase 4 builder (draft per user-resolved Decision 2 +
Concern A/E/F dispositions from Phase 4 startup halt-report).
**Status:** APPROVED 2026-04-26 at T4.01 close — gates T4.02 (pre-filter), T4.04 (validator
spawn), T4.05 (VALIDATOR_REFERENCE.md + install.sh extension), and
T4.06 (pipeline integration). Final merge into IMPLEMENTATION_PLAN.md
/ CLAUDE.md folds into phase-4-signoff.md per CLAUDE.md §A.4 pattern.
**Driver:** User direction (Phase 4 resume prompt, Decision 2
verbatim; Concern A/E/F dispositions confirmed at T4.01 go-ahead).

### Observed gap requiring change

Plan §5 Phase 4 names the Validator scope as "validator_agent.md
agent hook + flag file `.coord/validation/<session_id>.json` written
by `pre_tool_use_write.sh` when hash mismatch found" but does not
specify the agent's prompt structure, verdict JSON schema, spawn
flags, recursion-guard mechanism, or relationship to the Mediator
spawn pattern (which evolved during Phase 3). Plan §3.2 places
Validator state at `.coord/validation/`; user Decision 2 mirrors the
Mediator namespace at `.coord/validator/`. Plan §5 also implies a
flag-file pattern (write a flag, agent hook reads + classifies);
user Decision 2 supersedes with an inline-call pattern (pre-filter
+ validator spawn called directly from `pre_tool_use_write.sh`'s
stale-read branch). Implementation needs the contract pinned before
T4.02/T4.04/T4.05/T4.06 land.

### User-resolved decision (verbatim distillation)

Validator is a subagent that classifies file drift between two
versions of a file: the version a session read, and the current
state. Returns ONE of three verdicts: SAFE / MINOR / CRITICAL.

**Two-stage pipeline (Phase 4 design):**

Stage 1 — Pre-filter (`lib/validator_prefilter.sh`):
- Lightweight Bash + diff analysis
- Triggered when stale-read detected in `pre_tool_use_write.sh`
  (the stale-read walk at lines 195–241; NOT the `# PHASE-4
  UPGRADE POINT` comment at lines 304–312, which is a marker
  block to be removed during T4.06 — see Concern A disposition)
- Returns: SAFE | ESCALATE_TO_AGENT
- Heuristics for SAFE:
  - Whitespace-only changes (`diff -w` produces empty)
  - Comment-only changes (every changed line matches comment
    syntax: `^[\s]*(#|//|/\*|\*|<!--|"""|''')`) AND no
    multi-line-string ambiguity in the surrounding context
    (Concern C disposition — when in doubt, ESCALATE)
  - Blank-line-only changes (every changed line empty)
- Always-ESCALATE conditions:
  - File >1 MB
  - Pre-filter elapsed time exceeds 5 s
  - Any uncertainty about multi-line-string context for
    comment-classification
- Doctrine: "false-negative SAFE on real drift is dangerous;
  false-positive ESCALATE on trivial drift is acceptable" —
  confirmed at T4.01 go-ahead per Concern F disposition.

Stage 2 — Validator agent (`lib/validator_spawn.sh`):
- Spawns `claude -p` with validator prompt + 3-section context
- Mirrors the Phase 3 Mediator spawn paradigm (subscription
  mode, no-bare; T3.06/T3.07 lessons captured in CLAUDE.md
  §A.13 lesson #4 apply)
- Tool restrictions: `--allowedTools "Bash Read"`,
  `--disallowedTools "Write Edit NotebookEdit Task"`
- Recursion guard: `CLAUDE_CODE_VALIDATOR=<depth>` env marker
  (parallel to Phase 3's `CLAUDE_CODE_MEDIATOR`). Spawn helper
  refuses to spawn from within a session that already has this
  marker set. Phase 4 uses depth=1 only (validator does not
  spawn peer validators); the depth field is reserved for
  Phase 5+ extensibility, not exercised in Phase 4.
- Wall-clock estimate: ~30–60 s subscription mode; 120 s
  hard timeout per CLAUDE.md §A.13 lesson #4
- Mock-binary support for Phase 4 unit tests per Decision 1.1
  (real `claude -p` spawn exercised at Phase 7 integration
  harness)

**Validator prompt structure (3-section, mirrors Mediator):**

Section 1 — Identity (~80 words, fixed text):

> You are a Validator agent in a Claude Code coordination system.
> Your role is to classify file drift between two versions: the
> version a session read, and the current state. You return ONE
> of three verdicts: SAFE / MINOR / CRITICAL. Your judgment
> determines whether a session's pending Write should proceed
> silently, with a warning, or be escalated to the Mediator. You
> do not take actions; you classify.

Section 2 — System Constraints (HYBRID — short core rules + pointer
to `VALIDATOR_REFERENCE.md`):

The prompt contains 5 core rules:
1. Use `Bash` and `Read` tools only. NEVER use `Edit`, `Write`,
   or `NotebookEdit`.
2. You are not a tracked session. You operate as a temporary
   classifier.
3. Write your verdict to `.coord/validator/verdict/<ts>.json`.
4. If `CLAUDE_CODE_VALIDATOR=1` in env, you are nested. Do NOT
   spawn another Validator. (Recursion guard.)
5. You DO NOT take actions on state. You only classify.
   Mediator handles CRITICAL escalation actions.

For detailed mechanics (verdict schema, drift classification
heuristics, diff-summary format), the prompt instructs the
Validator to read `.coord/validator/VALIDATOR_REFERENCE.md` when
needed.

Section 3 — Drift Context (HYBRID — embedded snapshot + live read
allowed):

The prompt embeds:
- (a) File path
- (b) Read snapshot: `sha256` + file content as the session saw it
  at read time (truncated with marker if file >100 KB)
- (c) Current state: `sha256` + current file content from disk
  (truncated with marker if file >100 KB)
- (d) Diff between (b) and (c) (unified diff format, truncated
  with marker if diff >50 KB)
- (e) Verdict contract restated (SAFE/MINOR/CRITICAL definitions
  + JSON output instruction)

The Validator may use `Bash` + `Read` to inspect related files
(imports, dependencies) when context-aware classification is
needed. The embedded snapshot/current is initial context; live
read is permitted within the spawned session's `cwd`.

**Verdict JSON schema:**

```json
{
  "verdict_id": "<UUID v4>",
  "ts": "<ISO 8601 UTC>",
  "for_pending_entry": null,
  "validator_session_id": "<spawn session UUID from claude -p>",

  "file": "<path>",
  "session": "<caller session_id>",
  "verdict": "SAFE" | "MINOR" | "CRITICAL",

  "reasoning": "<Validator explanation, 1-3 sentences, plain text, no apostrophes per F-014 lesson>",
  "diff_summary": "<concise drift description, 1-3 sentences, plain text, no apostrophes>",

  "spawn_metadata": {
    "duration_ms": <int>,
    "model": "<model_name>",
    "spawn_mode": "no_bare"
  }
}
```

Field constraints:
- `for_pending_entry` is always `null` for Validator verdicts
  (this field is reserved for Mediator verdicts whose
  `for_pending_entry` references the triggering pending entry).
- Validator does NOT include `actions[]`, `confidence`,
  `severity`, `message_to_caller`, or `message_to_others`
  fields — those are Mediator-specific (Decision 2 verbatim).
  Validator classifies; Mediator decides actions.
- `verdict` enum is exactly `{SAFE, MINOR, CRITICAL}`. No other
  values permitted.
- `validator_session_id` is the UUID assigned by `claude -p` to
  the spawned process (captured from raw output JSON's
  `.session_id` field per CLAUDE.md §A.13 lesson #4).

**`VALIDATOR_REFERENCE.md` content (drafted in T4.05; lives in
`src/lib/VALIDATOR_REFERENCE.md`; copied to
`.coord/validator/VALIDATOR_REFERENCE.md` by `install.sh` per
Concern G disposition):**

Sections to include:
1. Verdict JSON schema with full field reference
2. Drift classification heuristics (when SAFE / MINOR / CRITICAL)
3. Diff-summary format conventions (1–3 sentences, plain text,
   no apostrophes per F-014 lesson)
4. Examples of SAFE drifts (formatter, comments, blank lines,
   unused imports reordered, license header updates)
5. Examples of MINOR drifts (new function added elsewhere, string
   literal changed, test added, typo fixed)
6. Examples of CRITICAL drifts (function signature changed,
   exported variable removed, type definition changed, database
   schema migrated)
7. Hand-off to Mediator: Validator writes pending entry
   `kind=critical_drift`; Mediator picks up via existing
   `pre_tool_use_any.sh` consumer (cross-references PR-PHASE4-03)

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.1 (layer list)** — update layer 7
"Validation subagent" description: replace "Agent-type hook guarded
by `.coord/validation/<session_id>.json` flag file" with "Pre-filter
+ agent-spawn pipeline guarded by an inline call from
`pre_tool_use_write.sh`'s stale-read branch. Pre-filter
(`lib/validator_prefilter.sh`) classifies trivial drifts
(whitespace/comment/blank-line-only) as SAFE without spawning;
non-trivial drifts escalate to a `claude -p` spawn
(`lib/validator_spawn.sh`) following the Phase 3 Mediator pattern.
Verdicts are SAFE/MINOR/CRITICAL; CRITICAL produces a
`kind=critical_drift` pending entry consumed by the existing
Mediator pipeline."

**B. `IMPLEMENTATION_PLAN.md` §3.2 (file structure on disk)** —
revise the `validation/` block:

```
├── validator/                       # Phase 4 Validator state
│   ├── VALIDATOR_REFERENCE.md       # technical reference (copied from src/lib by install.sh)
│   ├── verdict/<ts>.json            # historical Validator decisions
│   └── cache.json                   # SAFE/MINOR verdict cache (PR-PHASE4-04)
```

The legacy `validation/<session_id>.json` flag-file path is
removed from §3.2 entirely — Phase 4 deviates from the original
flag-file pattern in favor of inline-call (Concern E disposition).

**C. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `VALIDATOR_PREFILTER_SAFE` (payload: `file`, `session`,
  `read_hash`, `current_hash`, `prefilter_reason` ∈
  {whitespace_only, comment_only, blank_only}, `elapsed_ms`).
- `VALIDATOR_PREFILTER_ESCALATED` (payload: `file`, `session`,
  `read_hash`, `current_hash`, `escalation_reason` ∈
  {non_trivial_diff, file_too_large, prefilter_timeout,
  multiline_string_ambiguity}, `elapsed_ms`).
- `VALIDATOR_SPAWN_STARTED` (payload: `file`, `session`,
  `model`, `spawn_mode`, `budget_usd`, `timeout_sec`).
- `VALIDATOR_VERDICT_SAFE` / `VALIDATOR_VERDICT_MINOR` /
  `VALIDATOR_VERDICT_CRITICAL` (payload: `file`, `session`,
  `verdict_path`, `validator_session_id`, `duration_ms`,
  `total_cost_usd`, `diff_summary`).
- `VALIDATOR_SPAWN_FAILED` (payload: `file`, `session`,
  `reason` ∈ {empty_output, is_error_true, no_verdict_written,
  recursion_guard, claude_binary_missing, timeout},
  `spawn_session_id` (nullable), `duration_ms`).
- `VALIDATOR_SPAWN_REFUSED` (payload: `file`, `session`,
  `reason` ∈ {recursion_guard, critical_bypass_active,
  claude_binary_missing}).

**D. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** — add:
- `validator_enabled: true` (emergency override mirroring
  `mediator_enabled`; falls back to Phase 1 stale-read warning
  text when false).
- `validator_prefilter_max_file_kb: 1024` (1 MB ceiling for
  pre-filter; bounds [16, 65536]).
- `validator_prefilter_timeout_seconds: 5` (bounds [1, 30]).
- `validator_spawn_budget_usd: 0.50` (matches Mediator default;
  bounds [0.05, 5.00]).
- `validator_spawn_timeout_seconds: 120` (matches Mediator
  default; bounds [30, 300]).
- `validator_model: "claude-haiku-4-5-20251001"` (matches
  Mediator default; install-time tunable, no enforced bounds).

`coord health` validates the bounds.

**E. `IMPLEMENTATION_PLAN.md` §4 component specs** — add:

- `lib/validator_prefilter.sh`:
  - `coord_validator_prefilter <file> <read_content_path> <current_content_path>`:
    returns 0 on SAFE, 1 on ESCALATE_TO_AGENT, 2 on internal
    error (treated as ESCALATE by caller).
    Stdout on SAFE: `safe:<reason>` where reason ∈
    {whitespace_only, comment_only, blank_only}.
    Stdout on ESCALATE: `escalate:<reason>` where reason ∈
    {non_trivial_diff, file_too_large, prefilter_timeout,
    multiline_string_ambiguity}.
- `lib/validator_spawn.sh`:
  - `coord_validator_spawn <file> <session_id> <read_content_path> <current_content_path>`:
    returns 0 on completion (verdict written, path on stdout),
    1 on refusal (recursion guard, critical bypass) or failure.
    Mirrors `coord_mediator_spawn` structure.
  - Internal helpers: `_coord_validator_build_identity_section`,
    `_coord_validator_build_constraints_section <ref_path>`,
    `_coord_validator_build_context_section <file> <read_content_path> <current_content_path>`,
    `_coord_validator_assemble_prompt <file> <read_path> <current_path> <depth>`.
- `lib/VALIDATOR_REFERENCE.md`: technical reference per the
  content outline above. T4.05 deliverable.
- `install.sh` extension (T4.05 sub-task per Concern G):
  - Create `.coord/validator/` and `.coord/validator/verdict/`
    directories.
  - Copy `src/lib/VALIDATOR_REFERENCE.md` →
    `.coord/validator/VALIDATOR_REFERENCE.md` (idempotent;
    overwrites if existing copy is older than source).
  - `install.sh --uninstall` cleanup removes `.coord/validator/`
    along with the rest of `.coord/`.

**F. `IMPLEMENTATION_PLAN.md` §5 Phase 4 Scope** — replace
"`validator_agent.md` agent hook" with the pre-filter + spawn
pattern; replace "Flag file `.coord/validation/<session_id>.json`
written by `pre_tool_use_write.sh` when hash mismatch found" with
"Inline call from `pre_tool_use_write.sh`'s stale-read walk:
pre-filter classifies trivial drifts to SAFE; non-trivial drifts
escalate to `claude -p` spawn"; update CRITICAL bullet to
reference `kind=critical_drift` pending entry per PR-PHASE4-03.

**G. `IMPLEMENTATION_PLAN.md` §5 Phase 4 Done-when** — preserve
the four ship-gate items as listed; the cache item (#4) is
implemented per PR-PHASE4-04 (Concern D disposition;
not deferred).

**H. `CLAUDE.md` §B.6 (Mediator invocation protocol)** — add a
runtime sub-rule for Validator spawn behavior (the §B.6 section
covers anomaly invocation generally; Phase 4 adds Validator as a
sibling layer):
- "Validator runs synchronously inside the
  `pre_tool_use_write.sh` hook on stale-read drift; you do not
  invoke it directly. The spawn paradigm matches the Mediator's
  (subscription mode, `claude -p`, restricted tools, recursion
  guard via `CLAUDE_CODE_VALIDATOR=1`)."
- Phase 4 updates §B.11 quick-reference table to include
  Validator rows.

**I. `CLAUDE.md` §B.10 anti-patterns** — add:
- "**Do not invoke `coord` validator/mediator/lockdown CLIs by
  reading the verdict files yourself.** Verdict files are an
  audit record consumed by the hook layer; reading them directly
  is fine for inspection, but don't try to act on a verdict by
  hand — the hook layer handles routing."

### Implementation-task dependencies

- T4.02 (`lib/validator_prefilter.sh`) implements §E pre-filter
  spec. **Gated on this PR approval.**
- T4.03 (validator spawn POC) is a 15 min uncommitted POC to
  verify spawn flag compatibility (mock claude binary) and
  CLAUDE_CODE_VALIDATOR env propagation. **Gated on this PR
  approval.**
- T4.04 (`lib/validator_spawn.sh`) implements §E spawn helper
  spec, with mock-binary support per Decision 1.1. **Gated on
  this PR approval AND T4.03 POC closure.**
- T4.05 (`lib/VALIDATOR_REFERENCE.md` + `install.sh` extension)
  delivers the reference doc + install integration. **Gated on
  this PR approval; can run parallel to T4.04 if useful.**
- T4.06 (pipeline integration in `pre_tool_use_write.sh`) is
  gated on this PR + PR-PHASE4-02 + PR-PHASE4-04.
- T4.07 (ship-gate fixtures) verifies §G done-when criteria
  end-to-end.

### Ambiguity dispositions (resolved 2026-04-26 at T4.01 go-ahead)

1. **PHASE-4 UPGRADE POINT actual location.** **RESOLVED —
   stale-read walk at lines 195–241 of pre_tool_use_write.sh.**
   The comment block at lines 304–312 (post-acquire) is a
   marker, not the integration site. T4.06 relocates the
   integration into the stale-read walk and removes the
   marker block. Per Concern A disposition.

2. **`.coord/validator/` vs `.coord/validation/` namespace.**
   **RESOLVED — `.coord/validator/`** mirroring `.coord/mediator/`
   per Decision 2. Plan §3.2 deviation documented in §B above.
   The legacy `validation/` path is removed from the file-
   structure spec entirely. Per Concern E disposition.

3. **Pre-filter heuristic conservatism level.** **RESOLVED —
   conservative**: SAFE only when every changed line matches the
   comment regex AND no multi-line-string ambiguity in the
   surrounding context (3 lines above/below). Any uncertainty
   → ESCALATE_TO_AGENT. Per Concern C disposition. T4.02
   implements with bats coverage for dangerous patterns
   (multi-line string with `#` inside, markdown heading change,
   heredoc embedding).

4. **Validator depth field exercise in Phase 4.** **RESOLVED —
   depth=1 only.** The depth field is reserved for Phase 5+
   extensibility but not exercised in Phase 4 (Validator does
   not spawn peer validators; if peer-review-equivalent logic
   is later wanted, it would be a Phase 5+ addition with its
   own PR).

### Cross-references

- PR-PHASE4-02 (pipeline behavior + synchronous CRITICAL) — sibling
  PR; this PR defines the validator interface, PR-PHASE4-02
  defines the caller-side routing.
- PR-PHASE4-03 (Mediator-Validator integration) — sibling PR;
  this PR's CRITICAL pathway produces the `critical_drift`
  pending entry that PR-PHASE4-03 documents the Mediator
  consumption of.
- PR-PHASE4-04 (Validator cache) — sibling PR; cache lookup
  precedes pre-filter + spawn in the pipeline (Concern D
  disposition).
- PR-PHASE3-01 (Mediator) — Validator's spawn mechanics mirror
  Mediator's; CLAUDE.md §A.13 lesson #4 spawn discipline applies.
- FINDINGS — F-014 (apostrophe-fragility) is RESOLVED but its
  doctrine (no apostrophes in user-facing text) applies to
  Validator's `reasoning` and `diff_summary` fields.

### Non-changes (deliberate)

- Mediator code (`lib/mediator_spawn.sh`,
  `lib/mediator_pending.sh`, `lib/lockdown.sh`,
  `hooks/pre_tool_use_any.sh` Mediator-consumption branch)
  unchanged. Per Decision 4 / PR-PHASE4-03.
- `subagent_filter.sh` extends naturally to Validator subagent
  tool calls (Validator's `claude -p` spawn gets a fresh
  session_id; its tool calls' `agent_type` field will not
  collide with the parent's coordination).
- Phase 3 invariant (two-location deny: lock-held + lockdown)
  unchanged. Validator does not introduce a third deny location.
- `coord_consume_corrupt_state_flag` unchanged; pending.jsonl
  consumer reads `kind=critical_drift` naturally per
  PR-PHASE3-03's pending-kind-agnostic design.

### Acknowledgement

APPROVED 2026-04-26 at T4.01 close (user sign-off after halt-report).
Status DRAFT → APPROVED. Final merge
into IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-4-signoff.md.

---

## PR-PHASE4-02 — Pipeline behavior + synchronous CRITICAL semantics (Decision 3 + Concern B)

**Date:** 2026-04-26
**Author:** Phase 4 builder (draft per user-resolved Decision 3 +
Concern B disposition: synchronous mode, Interpretation B).
**Status:** APPROVED 2026-04-26 at T4.01 close — gates T4.06 (pipeline integration) and T4.07
(ship-gate fixtures, particularly the critical-drift-escalated
scenario). Final merge into IMPLEMENTATION_PLAN.md / CLAUDE.md
folds into phase-4-signoff.md.
**Driver:** User direction (Phase 4 resume prompt, Decision 3
verbatim + Concern B disposition at T4.01 go-ahead).

### Observed gap requiring change

Plan §5 Phase 4 specifies the Validator's verdict outcomes
(SAFE/MINOR/CRITICAL → silent / context / deny) but predates the
Phase 3 Mediator pipeline (pending entry, three action types,
lockdown). The interaction between Validator CRITICAL verdict and
Mediator's intervention path is not specified by the plan; user
Decision 3 fills the gap. Concern B (raised at Phase 4 startup)
identified a semantic ambiguity: "Hook caller's Write BLOCKS
(synchronous wait for Mediator)" admits two interpretations
(event-driven vs synchronous-inline). User dispositioned to
synchronous-inline (Interpretation B). This PR pins both Decision 3
and the synchronous-mode disposition.

### User-resolved decision (verbatim distillation)

**Pipeline behavior post-verdict (Decision 3):**

SAFE:
- Verdict logged to `.coord/validator/verdict/<ts>.json`
- Hook caller proceeds with Write (no banner, no escalation)
- Phase 1+2+3 stale-read warning suppressed for THIS file
  (other files in the same Write may still produce a stale
  banner — suppression is per-file, not per-Write)
- Event: `VALIDATOR_VERDICT_SAFE`

MINOR:
- Verdict logged
- Hook caller's `additionalContext` gets banner: "Drift on
  `<file>`: `<diff_summary>`. Validator classified as MINOR.
  Proceeding."
- Write proceeds immediately (lock acquired, exit 0)
- Event: `VALIDATOR_VERDICT_MINOR`

CRITICAL:
- Verdict logged
- Validator writes pending entry `kind=critical_drift` to
  `.coord/mediator/pending.jsonl` (per PR-PHASE4-03 schema)
- Hook caller's `additionalContext` gets banner: "Critical
  drift on `<file>`: `<diff_summary>`. Mediator analyzing..."
- **Hook synchronously invokes Mediator INLINE** (per Concern B
  disposition; see "Synchronous mode" section below)
- Mediator decides advice / surgical_fix / lockdown per
  PR-PHASE3-01's existing 3-action contract
- Hook routes per Mediator verdict:
  - Mediator chose `advice` → caller gets advice banner +
    Write proceeds (lock acquired)
  - Mediator chose `surgical_fix` → applied via existing
    `verdict_apply.sh`; if applied actions cleared the stale
    read (e.g., evicted the drift-causing session and updated
    file state), hook re-validates the read-set; if read-set
    is now consistent, Write proceeds; if still stale, hook
    re-runs Validator (capped at depth=2 to prevent loops)
  - Mediator chose `lockdown` → `lockdown.json` is now active;
    existing lockdown gate at `pre_tool_use_write.sh` line 188
    (`coord_lockdown_check && coord_lockdown_emit_deny`) fires
    on the SAME hook invocation's downstream code path,
    emitting deny via the existing two-location deny invariant
    (Phase 3 invariant preserved)
- Event chain: `VALIDATOR_VERDICT_CRITICAL` →
  `MEDIATOR_PENDING_DELIVERED` (or equivalent Phase 3 event) →
  `MEDIATOR_VERDICT` → (one of `LOCKDOWN_ACTIVATED` |
  `LOCK_RELEASED`/`SESSION_EVICTED`/`READ_SET_CLEARED` |
  `MEDIATOR_VERDICT` advice-only) → optionally
  `HOOK_DENIED_BY_LOCKDOWN`

**Synchronous mode (Concern B disposition):**

> "Synchronous mode is intentional, not a deferred optimization.
> Validator agent's purpose is to gate Write decisions; if Write
> proceeds before Mediator can intervene, validator serves no
> protective function. CRITICAL verdict explicitly means
> 'intervention needed' — intervention after Write is meaningless."

**Latency budgets (Concern B disposition):**

| Stage | Latency budget | Frequency (estimated) |
|---|---|---|
| Cache hit (PR-PHASE4-04) | <50 ms | Recurring same-drift events |
| Pre-filter SAFE | <100 ms | 50–70% of stale-read events |
| Validator MINOR | ~30–60 s | 25–45% of stale-read events |
| Validator CRITICAL → Mediator advice/surgical_fix | ~60–90 s | 5–10% of stale-read events |
| Validator CRITICAL → Mediator lockdown | ~60–100 s + deny | <5% of stale-read events |

The CRITICAL latency budget (~60–100 s) intentionally exceeds
CLAUDE.md §A.6's 2-second p99 hook target. This is bounded to
CRITICAL drift events (5–10% of stale-read attempts; stale-read
attempts are themselves a small fraction of all writes), and
justified by the safety contract: a CRITICAL verdict means the
validator believes intervention is needed before the Write
proceeds. Letting the Write land while Mediator deliberates
would defeat the validator's purpose.

The Bash-tool 600 s ceiling (per PR-PHASE0-01 / F-008) provides
ample margin: 100 s worst case is well under the 600 s ceiling
and well under the 570 s `wait_max_seconds` default.

**`validator_spawn` caller contract (Concern B disposition):**

> "validator_spawn captures claude -p output, parses verdict,
> returns to pre_tool_use_write.sh which then routes per
> Decision 3."

`coord_validator_spawn` is synchronous: it blocks until the
spawned `claude -p` completes (within the 120 s timeout from
PR-PHASE4-01 §D), reads the verdict file written by the
spawned process, and returns the verdict path on stdout (rc=0)
or an empty stdout (rc=1) on failure. Caller (`pre_tool_use_write.sh`'s
T4.06 integration) parses the verdict and routes per Decision 3.

NOT fire-and-forget. NOT async. NOT background.

**Phase 3 two-location deny invariant preservation:**

Phase 4 introduces NO new deny location. The CRITICAL pathway:
1. Validator returns CRITICAL → no deny.
2. Validator writes `critical_drift` pending entry → no deny.
3. Hook synchronously invokes Mediator → Mediator may write
   lockdown.json.
4. Hook's downstream path checks `coord_lockdown_check` (existing
   line 188 gate) → deny via existing lockdown gate IF lockdown
   is now active.
5. Otherwise (advice / surgical_fix), the hook proceeds normally
   and either acquires the lock or denies via the existing
   lock-held gate (existing line 263 branch).

Two deny locations remain: (1) `pre_tool_use_write.sh`
lock-held-by-other branch, (2) any hook reading
`.coord/mediator/lockdown.json` with `active=true`. Phase 4
invariant guard #7 + #8 (per IMPLEMENTATION_LOG.md Phase 4
section) assert `validator_spawn.sh` and
`validator_prefilter.sh` do NOT emit `permissionDecision: "deny"`
in any code path.

**Hook re-entry and recursion considerations:**

The synchronous CRITICAL pathway calls the Mediator from
inside `pre_tool_use_write.sh`. Mediator's spawn helper
(`coord_mediator_spawn`) is itself synchronous (Phase 3 design).
Both spawns set `CLAUDE_COORD=0` in their child env per
CLAUDE.md §A.13 lesson #4, so the spawned `claude -p` processes
do not register as participants and do not re-enter coord hooks.
The recursion guards (`CLAUDE_CODE_VALIDATOR=<depth>`,
`CLAUDE_CODE_MEDIATOR=<depth>`) prevent nested spawns.

A subtle case: if Mediator's surgical_fix completes and the
hook re-validates the read-set, finds it's STILL stale, and
re-runs Validator → that's a Validator-at-depth-2 invocation.
The recursion guard refuses depth>1 in Phase 4 (Validator
does not exercise peer review). The hook treats a refused
re-spawn as MINOR (proceed with banner) to break the loop.
This is documented in §B.6 of CLAUDE.md updates.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §5 Phase 4 Scope** — extend with the
synchronous-CRITICAL pipeline description (cross-reference this PR).
Update the existing bullet "CRITICAL verdict → enforced deny on
next write attempt until session re-reads" to reflect the new
synchronous semantics: "CRITICAL verdict → synchronous Mediator
invocation in the same hook; Mediator decides advice /
surgical_fix / lockdown; deny (if any) routes through the existing
lockdown gate, preserving Phase 3 invariant."

**B. `IMPLEMENTATION_PLAN.md` §5 Phase 4 "Done when"** — add:
- "Validator SAFE verdict on a stale-read drift suppresses the
  per-file stale-read banner; other files' banners (if any)
  preserved."
- "Validator MINOR verdict produces banner with diff summary;
  Write proceeds without escalation."
- "Validator CRITICAL verdict triggers synchronous Mediator
  invocation in the same hook; Mediator's verdict routes per
  PR-PHASE3-01's 3-action contract (advice / surgical_fix /
  lockdown)."
- "Validator CRITICAL → Mediator lockdown produces deny via
  existing lockdown gate; Phase 4 invariant (8 architectural
  guards) holds."

**C. `IMPLEMENTATION_PLAN.md` §3.7 sequence diagrams** — add a
new sequence diagram §3.7.X "Validator CRITICAL synchronous
escalation":
```
Session A reads foo.ts (sha=abc123)
[Other session writes foo.ts; current sha=def456]
Session A → Write foo.ts
  pre_tool_use_write.sh hook fires:
    stale-read walk detects drift on foo.ts (abc123 != def456)
    cache lookup (PR-PHASE4-04): MISS
    pre-filter: ESCALATE (non-trivial diff)
    spawn Validator (claude -p, ~45s)
    Validator returns: CRITICAL
    Validator writes verdict file
    Hook writes pending entry kind=critical_drift
    Hook synchronously invokes Mediator (claude -p, ~25s)
    Mediator returns: surgical_fix (clear A's read-set entry for foo.ts)
    Hook applies via verdict_apply.sh
    Hook re-validates read-set: now consistent (entry cleared)
    Hook proceeds with lock acquisition
    Lock acquired; banner: "Drift on foo.ts resolved by Mediator. Re-read recommended."
    exit 0 (allow)
Total hook latency: ~75s
```

**D. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `MEDIATOR_INVOKED_INLINE` (payload: `triggered_by` ∈
  {validator_critical, manual, watchdog}, `caller_session`,
  `caller_hook`, `pending_entry_id`).
- (The existing `MEDIATOR_VERDICT` event applies; no new kind
  needed for the verdict itself.)

**E. `CLAUDE.md` §B.2 (write coordination)** — extend the rule
text to reflect the Validator pathway. Currently §B.2 describes
the lock-held-by-other deny + read-set validation flow. Add:
- "On stale-read drift: hook runs Validator pipeline (cache →
  pre-filter → agent spawn). Verdict drives behavior:
  SAFE proceeds silently, MINOR proceeds with banner,
  CRITICAL invokes Mediator inline. Deny (if any) routes
  through the existing lockdown gate; Phase 3 two-location
  deny invariant preserved."
- "Validator pipeline latency: SAFE <100 ms, MINOR ~30–60 s,
  CRITICAL ~60–100 s. The latency budget exceptions are
  bounded to drift events (5–10% of stale-read attempts;
  stale-read attempts are themselves a small fraction of
  writes)."

**F. `CLAUDE.md` §B.6 (Mediator invocation protocol)** — add:
- "Mediator may also be invoked inline by `pre_tool_use_write.sh`'s
  Validator-CRITICAL pathway (Phase 4). The mechanics are
  identical to ambient-suspicion-triggered invocation: pending
  entry written, Mediator spawned synchronously, verdict
  applied. The only difference is the trigger (Validator
  classification vs watchdog observation)."
- "If a Validator-CRITICAL → Mediator surgical_fix → re-validate
  → still-stale loop is detected (depth>1), Validator
  re-spawn is refused by the recursion guard
  (`CLAUDE_CODE_VALIDATOR=1`), and the hook treats the residual
  drift as MINOR (proceed with banner). This bounds the
  worst-case latency at ~75 s + ~30 s = ~105 s, well under
  the 600 s Bash-tool ceiling."

**G. `CLAUDE.md` §B.11 quick-reference table** — add rows:
- Situation: "Stale read; Validator → SAFE." You do: "Proceed
  normally; no banner." Hook does: "Suppresses per-file stale
  banner; logs SAFE verdict." Enforcement: `[HOOK-ENFORCED]`.
- Situation: "Stale read; Validator → MINOR." You do: "Proceed
  with banner context." Hook does: "Emits MINOR banner; allows
  write." Enforcement: `[HOOK-ENFORCED]`.
- Situation: "Stale read; Validator → CRITICAL." You do: "Wait
  through ~60–100 s synchronous escalation; act on Mediator's
  verdict if surfaced." Hook does: "Synchronously invokes
  Mediator; routes per Mediator verdict (advice /
  surgical_fix / lockdown)." Enforcement: `[HOOK-ENFORCED]`.

### Implementation-task dependencies

- T4.06 (pipeline integration in `pre_tool_use_write.sh`)
  implements the synchronous-CRITICAL routing per this PR.
  **Gated on this PR approval AND PR-PHASE4-01 + PR-PHASE4-04
  approval.**
- T4.07 (ship-gate fixture 03_critical_drift_escalated)
  exercises the synchronous-CRITICAL pathway end-to-end with
  mock Validator + mock Mediator. **Gated on T4.06.**

### Ambiguity dispositions (resolved 2026-04-26 at T4.01 go-ahead)

1. **CRITICAL semantic — synchronous vs event-driven.**
   **RESOLVED — synchronous (Interpretation B).** Per Concern B
   disposition. validator_spawn returns verdict synchronously;
   pre_tool_use_write.sh routes per verdict; Mediator (when
   triggered for CRITICAL) is also called synchronously. Latency
   budgets documented in §C above.

2. **Re-validate loop bound on Mediator surgical_fix → still-stale.**
   **RESOLVED — depth=1 ceiling for Validator re-spawn.** The
   hook re-validates after Mediator surgical_fix; if still
   stale, Validator re-spawn is refused by the recursion guard,
   and the residual drift is treated as MINOR (proceed with
   banner). Bounds worst-case latency at ~105 s.

3. **Per-file vs per-Write SAFE-banner suppression.**
   **RESOLVED — per-file.** SAFE verdict on `foo.ts`
   suppresses ONLY foo.ts from the stale-read banner; other
   files (e.g., `bar.ts` in the same Write request, also stale)
   produce their own per-file Validator runs and contribute
   their own banner entries (if MINOR) or are silenced
   independently (if SAFE).

4. **Mediator advice for CRITICAL drift outcome.**
   **RESOLVED — caller proceeds with advice banner; lock
   acquired.** Mediator advice for `critical_drift` means
   "Validator's CRITICAL was overruled by Mediator with strong
   evidence; the Write is safe to proceed." The advice text is
   surfaced as `additionalContext`, the Write acquires the
   lock, and the stale banner for that file is suppressed.

### Cross-references

- PR-PHASE4-01 (Validator agent design contract) — defines the
  validator interface; this PR defines the caller-side routing.
- PR-PHASE4-03 (Mediator-Validator integration) — defines the
  `critical_drift` pending entry payload that this PR's CRITICAL
  pathway produces.
- PR-PHASE4-04 (Validator cache) — cache lookup precedes
  pre-filter + spawn; cache hits return verdict immediately
  (latency budget <50 ms) and route per Decision 3 without
  spawning.
- PR-PHASE3-01 (Mediator) — Mediator's 3-action contract is
  the consumer of CRITICAL escalations; lockdown gate at
  `pre_tool_use_write.sh` line 188 is the deny mechanism.
- PR-PHASE3-03 (pending.jsonl unification) — `critical_drift`
  joins the unified pending queue.
- FINDINGS — F-014 doctrine (no apostrophes in user-facing
  text) applies to banner text.

### Non-changes (deliberate)

- Phase 3 two-location deny invariant unchanged (lock-held +
  lockdown). Phase 4 introduces NO third deny location.
- Mediator spawn mechanics (`lib/mediator_spawn.sh`) unchanged.
- Existing `pre_tool_use_any.sh` Mediator-pending consumer
  unchanged; Phase 4's CRITICAL pathway invokes Mediator
  inline from `pre_tool_use_write.sh`, BUT also writes the
  pending entry so that subsequent operations see the audit
  record. The pending consumer is idempotent: if the pending
  entry's verdict has already been applied, consumer is a
  no-op (consumer checks for an existing verdict matching
  `for_pending_entry`).
- Watchdog ambient-suspicion pathway unchanged.
- Existing lock-held-by-other deny text (CLAUDE.md §B.2
  three-options) unchanged.

### Acknowledgement

APPROVED 2026-04-26 at T4.01 close (user sign-off after halt-report).
Status DRAFT → APPROVED. Concern B
disposition (synchronous mode) is the load-bearing decision
this PR pins.

---

## PR-PHASE4-03 — Mediator-Validator integration (Decision 4)

**Date:** 2026-04-26
**Author:** Phase 4 builder (draft per user-resolved Decision 4).
**Status:** APPROVED 2026-04-26 at T4.01 close — informational + plan-deltas only; gates no
code change in Phase 3 components, but must precede T4.06 so the
expected Mediator behavior on `critical_drift` pending entries is
documented. Bundles into T4.06 verification (no separate
implementation task).
**Driver:** User direction (Phase 4 resume prompt, Decision 4
verbatim).

### Observed gap requiring change

PR-PHASE3-01 defined the Mediator's 3-action contract (advice /
surgical_fix / lockdown) but predates the Validator. PR-PHASE3-03
unified `pending.jsonl` such that any pending `kind` is consumed
uniformly. Phase 4 introduces a new pending `kind=critical_drift`
emitted by the Validator. The plan needs to document (a) the
`critical_drift` payload schema, (b) that Mediator code paths
require NO modification, and (c) the expected Mediator-action
mapping for `critical_drift` so the spawned Mediator's prompt
context is sufficient to produce the right verdict.

### User-resolved decision (verbatim distillation)

When Validator emits CRITICAL → `critical_drift` pending entry:

The pending entry's payload includes:
- `file` (the drifted file)
- `validator_verdict` ("CRITICAL")
- `validator_reasoning` (Validator's explanation, 1–3 sentences)
- `your_read_hash` (the hash the caller stored in
  `read_sets[<caller>].reads[]`)
- `current_hash` (the file's current sha256)
- `diff_summary` (Validator's concise drift description)
- `validator_session_id` (audit; the spawn UUID for the
  Validator that produced the verdict)

Mediator's existing 3-action contract handles `critical_drift`:
- **advice** — Mediator inspects, judges drift safe to proceed
  despite Validator's CRITICAL → caller gets advice banner,
  proceeds. (RARE — Mediator overrules Validator only with
  strong evidence: e.g., Mediator can prove the drift is
  semantically equivalent via deeper inspection that
  Validator's snapshot lacked.)
- **surgical_fix** — Mediator clears caller's read-set entry
  for the drifted file (forcing re-read), or evicts a session
  causing the drift, or releases an orphaned lock holding back
  the actual current state, etc. The hook re-validates the
  read-set after applying; if still stale, treats residual as
  MINOR per PR-PHASE4-02 §B.2 disposition.
- **lockdown** — system-wide drift incident (e.g., schema
  migration in progress, infrastructure change underway) →
  Mediator pauses everyone via existing lockdown gate.

Mediator's existing peer-review hierarchy applies:
needs_review verdicts trigger second Mediator at depth=2;
same depth-2 ceiling per PR-PHASE3-01.

NO NEW Mediator code paths. Mediator's existing pending entry
consumer reads `kind=critical_drift` naturally; Mediator's
prompt is pending-kind-agnostic (it analyzes whatever payload
arrives, formatted as JSON in Section 3 — Incident Context of
the prompt).

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** —
extend the existing `MEDIATOR_VERDICT` event documentation: the
`pending_entry_kind` payload field already includes the kind name
of the triggering pending entry; document that `critical_drift`
is a valid value alongside `corrupt_state`, `flock_timeout`,
`stale_active`, `pid_recycled`, `manual`.

**B. `IMPLEMENTATION_PLAN.md` §4 component spec — `lib/mediator_pending.sh`** —
extend the pending entry schema documentation with the
`critical_drift` kind and its payload shape:

```json
{
  "ts": "<ISO 8601 UTC>",
  "kind": "critical_drift",
  "session": "<caller session_id>",
  "source": "validator",
  "payload": {
    "file": "<path>",
    "validator_verdict": "CRITICAL",
    "validator_reasoning": "<text>",
    "your_read_hash": "<sha256>",
    "current_hash": "<sha256>",
    "diff_summary": "<text>",
    "validator_session_id": "<spawn UUID>"
  }
}
```

The payload's `file` field is the canonical pivot for downstream
Mediator action selection (e.g., release_lock targets this file;
clear_read_set targets the `session` field's read-set entry for
this file).

**C. `lib/MEDIATOR_REFERENCE.md` cross-link extension** — add a
new subsection under §4 "Pending queue (read + GC)":

> ### Pending kind: `critical_drift` (Phase 4)
>
> Emitted by the Validator (Phase 4) when it classifies a
> stale-read drift as CRITICAL. Payload schema documented in
> IMPLEMENTATION_PLAN.md §4 lib/mediator_pending.sh.
>
> Action mapping (your decision; pending-kind-agnostic but
> conventional):
> - `advice`: drift is semantically safe despite CRITICAL
>   classification (use only with strong evidence; Validator's
>   snapshot was truncated, or deeper inspection reveals
>   equivalence).
> - `surgical_fix` (severity=brief): clear caller's read-set
>   entry for the drifted file via `clear_read_set` action;
>   caller will re-read and re-validate.
> - `surgical_fix` (severity=extended): evict a drift-causing
>   session via `evict_session`; release any locks blocking
>   the actual current state via `release_lock`.
> - `lockdown`: system-wide drift incident; pause everyone.

This is purely documentation; no code change to Mediator.

**D. `IMPLEMENTATION_PLAN.md` §5 Phase 4 Out-of-scope** — affirm
explicitly:

> "Mediator code (`lib/mediator_spawn.sh`,
> `lib/mediator_pending.sh`, `lib/lockdown.sh`,
> `hooks/pre_tool_use_any.sh` Mediator-consumption branch,
> `hooks/session_start.sh` Mediator-consumption branch,
> `lib/coord_mediate.sh`, `lib/verdict_apply.sh`,
> `lib/critical_check.sh`) is unchanged in Phase 4. Mediator's
> existing pending consumer reads `critical_drift` naturally;
> the prompt is pending-kind-agnostic; the 3-action contract
> handles all kinds."

**E. `CLAUDE.md` §B.6** — extend the "Mediator inspects … and
takes one of four action types" rule with a sub-bullet for
Phase 4's contribution:

> "When Mediator's pending entry has `kind=critical_drift`, the
> payload contains `file`, `validator_verdict`,
> `validator_reasoning`, `your_read_hash`, `current_hash`,
> `diff_summary`, and `validator_session_id`. Mediator's
> standard 3-action contract applies (advice / surgical_fix /
> lockdown); the `file` field is the canonical pivot for
> action targeting (e.g., `release_lock target=<file>`,
> `clear_read_set session=<caller>`)."

### Implementation-task dependencies

- T4.04 (`lib/validator_spawn.sh`) emits the `critical_drift`
  pending entry with the payload schema in §B above. **Gated on
  this PR approval (along with PR-PHASE4-01).**
- T4.05 (`lib/VALIDATOR_REFERENCE.md`) documents the hand-off
  to Mediator with cross-references to this PR. **Gated on
  this PR approval.**
- T4.06 (pipeline integration) writes the pending entry +
  invokes Mediator inline. **Gated on this PR approval (along
  with PR-PHASE4-01 + PR-PHASE4-02 + PR-PHASE4-04).**
- T4.07 (ship-gate fixture 03_critical_drift_escalated) verifies
  the end-to-end flow with mock Validator + mock Mediator.
  **Gated on T4.06.**

NO separate implementation task in Phase 4 for this PR. The
work is documentation only (plan section deltas + the
MEDIATOR_REFERENCE.md subsection). T4.05 and T4.06 carry the
implementation references.

### Ambiguity dispositions (resolved 2026-04-26 at T4.01 go-ahead)

1. **`critical_drift` payload schema field naming.**
   **RESOLVED — verbatim per Decision 1.3.** Field names are
   `file`, `validator_verdict`, `validator_reasoning`,
   `your_read_hash`, `current_hash`, `diff_summary`,
   `validator_session_id`. The "your_read_hash" naming
   intentionally mirrors the second-person prompt voice used
   in caller-facing banner text (e.g., "your earlier plan may
   be based on outdated content").

2. **Mediator's response to needs_review on `critical_drift`.**
   **RESOLVED — depth=2 peer review applies normally.**
   PR-PHASE3-01's max-depth-2 escalation hierarchy applies
   without modification. If the depth=1 Mediator returns
   needs_review, depth=2 Mediator is spawned with the
   `critical_drift` pending entry + depth=1 verdict in
   context. Action_type agreement → apply with more
   conservative severity; disagreement → escalate to user.

3. **Idempotency of inline Mediator + pending consumer.**
   **RESOLVED — pending consumer is idempotent.** Per
   PR-PHASE4-02 §"Non-changes": when `pre_tool_use_write.sh`
   invokes Mediator inline (Phase 4) AND writes the pending
   entry, the subsequent `pre_tool_use_any.sh` consumer firing
   on the next tool call sees the pending entry but ALSO sees
   that a verdict already exists matching `for_pending_entry`;
   the consumer treats this as already-handled and does not
   re-spawn. Implementation note for T4.06: ensure
   `for_pending_entry` is set in the verdict file when invoked
   from the inline Phase 4 pathway.

### Cross-references

- PR-PHASE4-01 (Validator agent design contract) — defines the
  validator that produces `critical_drift`.
- PR-PHASE4-02 (Pipeline behavior + synchronous CRITICAL) —
  defines the inline Mediator invocation triggered by
  `critical_drift`.
- PR-PHASE3-01 (Mediator) — defines the 3-action contract that
  consumes `critical_drift`.
- PR-PHASE3-03 (pending.jsonl unification) — defines the unified
  queue that `critical_drift` joins.
- PR-PHASE3-04 (pending.jsonl GC) — `critical_drift` entries
  participate in the same 24 h GC retention window.
- FINDINGS — none currently OPEN against this PR.

### Non-changes (deliberate)

- Mediator code unchanged (per Decision 4 verbatim).
- Mediator's `lib/MEDIATOR_REFERENCE.md` only gets a new
  documentation subsection (no API change).
- Mediator's prompt structure (Identity / Constraints / Context
  three-section) unchanged. The Context section's pending entry
  block naturally includes `critical_drift` payload as JSON.
- `lib/verdict_apply.sh` unchanged; its action verbs
  (release_lock / evict_session / clear_read_set) cover all
  `critical_drift` action mappings.

### Acknowledgement

APPROVED 2026-04-26 at T4.01 close (user sign-off after halt-report).
Status DRAFT → APPROVED. Documentation-
only PR; no Mediator code change in Phase 4.

---

## PR-PHASE4-04 — Validator cache (Concern D disposition; ship-gate item 4)

**Date:** 2026-04-26
**Author:** Phase 4 builder (draft per Concern D disposition: in-
scope for Phase 4; plan §5 ship-gate item 4 implemented, not
deferred).
**Status:** APPROVED 2026-04-26 at T4.01 close — gates T4.02 (pre-filter; cache lookup precedes
pre-filter logic) and T4.04 (validator spawn; cache write follows
spawn-completion). Final merge into IMPLEMENTATION_PLAN.md /
CLAUDE.md folds into phase-4-signoff.md.
**Driver:** Plan §5 Phase 4 ship-gate item 4 verbatim ("Repeated
SAFE verdicts for the same file+diff are cached … to avoid token
churn") + user direction at T4.01 go-ahead (Concern D
disposition: in-scope, not deferred).

### Observed gap requiring change

Plan §5 Phase 4 ship-gate item 4 specifies a verdict cache to
avoid token churn on repeated same-file+diff drift events, but
the plan does not specify the cache schema, key, TTL, placement
in the pipeline, or GC behavior. User Decision 2 (Validator
contract) does not address the cache. At Phase 4 startup, the
question of whether to keep the cache in scope vs. defer to
Phase 7 measurement-driven tuning was raised as Concern D and
dispositioned by the user as in-scope for Phase 4. This PR pins
the design.

### User-resolved decision (verbatim)

> "In-scope for Phase 4. Plan §5 ship-gate item 4 implemented,
> not deferred."

> Cache design:
>
> Path: `.coord/validator/cache.json` (mirroring validator/
> namespace per Decision 2; NOT plan §3.2's validation/).
>
> Schema:
> ```
> {
>   "entries": [
>     {
>       "file": "<path>",
>       "read_hash": "<sha256>",
>       "current_hash": "<sha256>",
>       "verdict": "SAFE" | "MINOR",
>       "verdict_source": "prefilter" | "validator_agent",
>       "cached_at": "<ISO>",
>       "ttl_until": "<ISO>"
>     }
>   ]
> }
> ```
>
> Cache key: `(file, read_hash, current_hash)` triple. Same
> drift recurring → cache hit.
>
> TTL: 1 hour for SAFE and MINOR. CRITICAL is NOT cached —
> every CRITICAL spawn must trigger fresh Mediator escalation.
>
> Cache placement in pipeline: BEFORE pre-filter, BEFORE
> validator agent.
>
> stale_read detected
>   → cache_lookup(file, read_hash, current_hash)
>     → cache HIT: return cached verdict (SAFE/MINOR), apply
>       pipeline behavior per Decision 3
>     → cache MISS: continue
>   → pre_filter
>     → SAFE: cache_write + return
>     → ESCALATE: continue
>   → validator agent (spawn)
>     → verdict captured
>     → cache_write (only if SAFE or MINOR)
>     → return
>
> Cache GC: bundled with validator agent runs (mirrors
> PR-PHASE3-04 pattern for pending.jsonl GC). Or simpler:
> cache_lookup expires entries on read; cache_write
> opportunistically purges expired entries.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.2 file structure on disk** —
update PR-PHASE4-01 §B's `validator/` block to include
`cache.json`:

```
├── validator/                       # Phase 4 Validator state
│   ├── VALIDATOR_REFERENCE.md       # technical reference (copied from src/lib by install.sh)
│   ├── cache.json                   # SAFE/MINOR verdict cache (PR-PHASE4-04)
│   ├── cache.lock                   # flock sentinel for cache.json
│   └── verdict/<ts>.json            # historical Validator decisions
```

**B. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `VALIDATOR_CACHE_HIT` (payload: `file`, `session`,
  `read_hash`, `current_hash`, `cached_verdict` ∈ {SAFE,
  MINOR}, `verdict_source` ∈ {prefilter, validator_agent},
  `cache_age_seconds`).
- `VALIDATOR_CACHE_WRITE` (payload: `file`, `session`,
  `read_hash`, `current_hash`, `verdict`, `verdict_source`,
  `ttl_seconds`).
- `VALIDATOR_CACHE_GC_RUN` (payload: `kept_count`,
  `removed_count`, `before_size_bytes`, `after_size_bytes`,
  `triggered_by` ∈ {validator_run_opportunistic,
  validator_run_explicit}).

**C. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** — add:
- `validator_cache_enabled: true` (emergency override; falls
  back to spawn-every-time when false).
- `validator_cache_ttl_seconds: 3600` (1 hour; bounds [60,
  86400] — 1 minute minimum, 24 hours maximum).
- `validator_cache_max_entries: 1000` (soft cap to bound
  cache.json size; bounds [10, 100000]). When the cap is
  exceeded, GC removes oldest expired entries first; if no
  expired entries remain and cap is still exceeded, the oldest
  unexpired entry is evicted (LRU).

`coord health` validates the bounds.

**D. `IMPLEMENTATION_PLAN.md` §4 component specs** — add:

`lib/validator_cache.sh`:
- `coord_validator_cache_lookup <file> <read_hash> <current_hash>`:
  returns 0 on HIT (stdout: cached verdict JSON), 1 on MISS,
  2 on cache file unreadable (treated as MISS by caller; logs
  warning).
  Implementation: `flock` on `cache.lock`; read `cache.json`;
  filter entries matching the key triple AND `ttl_until > now`;
  return first match (most recent if multiple).
- `coord_validator_cache_write <file> <read_hash> <current_hash> <verdict> <verdict_source>`:
  returns 0 on success, non-zero on failure (logs warning;
  caller proceeds).
  Implementation: `flock` on `cache.lock`; read `cache.json`;
  remove any existing entry with same key; append new entry
  with `cached_at = now`, `ttl_until = now + ttl_seconds`;
  call `_coord_validator_cache_gc_opportunistic` (purges
  expired entries during the same flock window); atomic
  temp+rename to write `cache.json`.
- `_coord_validator_cache_gc_opportunistic` (internal):
  removes entries with `ttl_until < now`; if entry count still
  exceeds `validator_cache_max_entries`, removes oldest
  entries (by `cached_at`) until cap is met; emits
  `VALIDATOR_CACHE_GC_RUN` event with counts. Called from
  `coord_validator_cache_write` and on every
  `coord_validator_cache_lookup` MISS (cheap because flock
  is already held during the read).
- `coord_validator_cache_clear`: removes all cache entries
  (useful for `coord health --reset` or manual operator
  intervention; not exposed as a CLI in Phase 4).

**E. `IMPLEMENTATION_PLAN.md` §5 Phase 4 Scope** — add to the
in-scope list:
- "`lib/validator_cache.sh`: SAFE/MINOR verdict cache. Key
  `(file, read_hash, current_hash)`. TTL 1 h. CRITICAL NOT
  cached. Pipeline placement: cache lookup BEFORE pre-filter
  + spawn. Cache write on SAFE/MINOR verdict completion. GC
  opportunistic on read/write."

**F. `IMPLEMENTATION_PLAN.md` §5 Phase 4 "Done when"** — keep
ship-gate item 4 as listed; this PR makes it satisfiable.
Add evidence pointer: "fixture 02_minor_drift_warned and
01_safe_drift_silent both verify cache hit on second
invocation with same file+drift."

**G. `install.sh` extension** — fold into T4.05 along with
the VALIDATOR_REFERENCE.md install (Concern G). Specifically:
- Create `.coord/validator/cache.lock` (empty file for flock).
- `cache.json` is created lazily on first cache_write
  (no install-time creation needed; cache_lookup handles
  the missing-file case as MISS).

### Implementation-task dependencies

- T4.02 (`lib/validator_prefilter.sh`) is gated on this PR
  approval since the cache lookup precedes the pre-filter
  call. Note: the cache lookup itself is implemented in
  `lib/validator_cache.sh` (delivered alongside T4.02 or in a
  preceding sub-task — sequencing decision is for T4.01 close).
- T4.04 (`lib/validator_spawn.sh`) is gated on this PR approval
  since cache write follows spawn-completion.
- T4.05 (`install.sh` extension) creates the cache lock file.
- T4.06 (pipeline integration) wires the cache lookup as the
  first step in the stale-read handling block.
- T4.07 (ship-gate fixtures) verifies cache hit on the second
  identical drift event (no spawn fired).

**Recommended sequencing:** T4.02 expands to deliver
`lib/validator_cache.sh` + `lib/validator_prefilter.sh` as a
single task (cache + pre-filter together; both are pre-spawn
filtering layers). Alternatively, split into T4.02a (cache)
and T4.02b (pre-filter). Decision deferred to T4.02 design
checkpoint per the user's "halt at T4.01 close" instruction.

### Ambiguity dispositions (resolved 2026-04-26 at T4.01 go-ahead)

1. **GC trigger model: opportunistic vs bundled with validator runs.**
   **RESOLVED — opportunistic (option B from user disposition).**
   Cache GC fires on every cache_write and on every
   cache_lookup MISS (under the same flock window — cheap).
   This is simpler than the PR-PHASE3-04-style bundled GC:
   cache writes are infrequent (only when validator produces
   a verdict, which is itself rate-limited by the spawn cost
   and the pre-filter), so opportunistic GC keeps cache.json
   small without a separate trigger.

2. **Cache eviction policy when `validator_cache_max_entries`
   exceeded.**
   **RESOLVED — TTL-first, then LRU.** GC first removes
   expired entries (TTL elapsed); if the cap is still
   exceeded, evicts oldest by `cached_at` (LRU). Prevents
   pathological growth from a flood of unique drifts within
   the TTL window.

3. **Cache key collision: same file path with different content
   versions across git checkouts.**
   **RESOLVED — non-issue.** The key is
   `(file, read_hash, current_hash)`. If git HEAD changes and
   the file's current_hash changes, the cache key triple is
   different, so the previous entry is not returned (it sits
   in the cache until TTL expiry or GC eviction). Stale
   cache entries cannot affect a different content state.

4. **Cache lookup on MINOR verdict — does the cached banner
   text still apply?**
   **RESOLVED — banner regenerated on every hit.** The cache
   stores the verdict (SAFE | MINOR) and verdict_source, but
   NOT the diff_summary text (since `diff_summary` was
   computed against a specific `(read_hash, current_hash)`
   pair that matches the cache key — so the same drift
   produces the same `diff_summary`). On MINOR cache hit, the
   banner is regenerated from a stored `diff_summary` field
   in the cache entry. (Schema addition: `diff_summary`
   field added to cache entry — not in the original Concern D
   schema but necessary for MINOR banner consistency.)
   **Schema correction:** add `diff_summary` field to cache
   entry schema:
   ```json
   {
     "file": "<path>",
     "read_hash": "<sha256>",
     "current_hash": "<sha256>",
     "verdict": "SAFE" | "MINOR",
     "verdict_source": "prefilter" | "validator_agent",
     "diff_summary": "<text — for MINOR banner regeneration; null for SAFE>",
     "cached_at": "<ISO>",
     "ttl_until": "<ISO>"
   }
   ```

5. **Cache invalidation on git HEAD change.**
   **RESOLVED — no explicit invalidation.** Per disposition
   3, cache key includes both hashes; HEAD-change-driven
   hash divergence naturally produces cache misses for the
   new hashes. Old entries expire via TTL or LRU. NOT relying
   on explicit `git_head` field in cache entries — the hashes
   are sufficient.

### Cross-references

- PR-PHASE4-01 (Validator agent design contract) — defines
  the validator that this PR caches the verdicts of.
- PR-PHASE4-02 (Pipeline behavior + synchronous CRITICAL) —
  defines the routing this PR's cache lookups feed into.
- PR-PHASE4-03 (Mediator-Validator integration) — CRITICAL
  is NOT cached, so this PR's cache does not interact with
  the Mediator pathway directly.
- PR-PHASE3-04 (pending.jsonl GC) — analogous GC pattern,
  but this PR uses opportunistic GC instead of bundled.
- FINDINGS — F-014 doctrine (no apostrophes) applies to
  cached `diff_summary` text (already enforced at validator
  output time; cache stores the text as-is).

### Non-changes (deliberate)

- Validator agent code (`lib/validator_spawn.sh`) is not
  changed by this PR; the spawn helper writes the verdict
  file as before, and the caller (`pre_tool_use_write.sh`)
  is responsible for cache_write after capturing the verdict.
  This keeps `validator_spawn.sh` cache-agnostic and easier
  to test.
- Pre-filter (`lib/validator_prefilter.sh`) is not changed by
  this PR; the cache lookup is a separate code path called
  before pre-filter.
- Mediator code unchanged.
- The CRITICAL pathway (PR-PHASE4-02) is unchanged: CRITICAL
  is not cached, so every CRITICAL drift triggers fresh
  Mediator escalation.

### Acknowledgement

APPROVED 2026-04-26 at T4.01 close (user sign-off after halt-report).
Status DRAFT → APPROVED. Concern D
disposition (in-scope for Phase 4) is the load-bearing
decision; Schema-correction disposition #4 (adding
`diff_summary` to cache entry) is a clarification of the
user's verbatim schema.

---

## PR-PHASE4-05 — Read-snapshot capture for validator pipeline

**Date:** 2026-04-26
**Author:** Phase 4 builder (T4.01 amendment; surfaced at T4.02
pre-implementation halt — read-snapshot content gap not addressed
in Decision 2 / PR-PHASE4-01).
**Status:** APPROVED 2026-04-26 at T4.01-amendment close — gates
T4.02a (snapshot capture in `pre_tool_use_read.sh`), T4.02b
(validator cache + pre-filter consuming snapshots), T4.04
(validator spawn whose Section 3 prompt embeds the read snapshot
content).
**Driver:** User direction at T4.02 halt-report (Option A
disposition; standalone PR per disposition (ii); T4.02 split into
T4.02a + T4.02b per disposition (3)).

### Observed gap requiring change

The Phase 4 validator pipeline (per Decision 2 + PR-PHASE4-01 +
PR-PHASE4-04) needs the *content* of the file as the session read
it (the "read snapshot"), not just the hash:
- **Pre-filter** (`lib/validator_prefilter.sh`) computes the diff
  between read snapshot and current state for whitespace-only /
  comment-only / blank-line-only heuristics. This requires both
  contents.
- **Validator agent prompt Section 3 (b)** (per PR-PHASE4-01)
  embeds "Read snapshot: sha256 + file content as session saw it
  at read time."

The Phase 1 read-set (per Decision 2.18 / `pre_tool_use_read.sh`)
stores only `{path, hash, at, is_latest}` — no content. There is
no content-addressable cache. When stale-read is detected in
`pre_tool_use_write.sh`, the on-disk file is the *current* state;
the read snapshot's content is unrecoverable from existing data
(non-git edits between Reads, the dominant multi-session
coordination case, cannot be reconstructed via `git show`).

T4.02 implementation cannot proceed without resolving this. T4.01
documentation work did not surface the gap because PR-PHASE4-01 §E
specifies `coord_validator_prefilter <file> <read_content_path>
<current_content_path>` (content paths) without specifying where
`<read_content_path>` comes from.

### User-resolved decision

**Option A — Snapshot at Read time, content-addressable storage:**

`pre_tool_use_read.sh` writes the file content to
`.coord/read_snapshots/<sid>/<hash>.txt` immediately after
recording the hash in `read_sets`. Subsequent validator pipeline
invocations resolve the read content via
`.coord/read_snapshots/<sid>/<read_hash>.txt`.

**Sizing + skip handling:**
- Files >10 MB (existing Phase 1 hash cap; `coord_hash_file`
  returns `SKIPPED_LARGE`) → no snapshot is written. Pre-filter
  unconditionally ESCALATEs in this case (consistent with the
  existing `>1 MB` rule from PR-PHASE4-01 — at the 10 MB
  hash-cap level, Phase 1's `SKIPPED_LARGE` already masks the
  read entry as un-comparable).
- Snapshot file is exactly the read-time bytes; no transformation.
  The on-disk filename uses the hash as-is (64 hex chars + `.txt`).
- Phase 7 may revisit with size-bounded variant (Option C from
  T4.02 halt-report) if storage pressure surfaces; mechanical
  refinement only.

**GC semantics:**
- **On supersede** (next Read of same file with a different hash):
  the prior snapshot is deleted in the same atomic edit that
  supersedes the read-set entry. Idempotent.
- **On supersede with same hash** (Read of an unchanged file):
  no-op. Snapshot already correct.
- **On `superseded_by_head_change` flag** (git HEAD change per
  Decision 2.22): no snapshot deletion. The flag marks the
  read-set entry as invalidated by HEAD, but the snapshot
  content remains valid for diff computation if needed.
- **On session end** (`session_end.sh`): `.coord/read_snapshots/
  <sid>/` directory is removed entirely. Idempotent.
- **On orphaned snapshots** (session crashed before
  `session_end.sh` fired): cleaned up by the watchdog/Mediator
  pathway when the session is evicted (action verb extension —
  see §F below).

**Concurrency:**
- Per-session subdirectory (`<sid>/`) avoids cross-session
  collisions; no flock needed for write because each session
  owns its directory.
- WITHIN a session, two simultaneous Reads of the same file with
  different hashes (e.g., file changed between two PreToolUse
  hooks firing on subagent activity) would race. Existing
  Phase 1 design already excludes subagents from coord (Decision
  2.17), so the race is bounded to one Read per session per file
  per turn. `mv` from temp + atomic rename pattern handles any
  residual race.
- Per-snapshot atomic rename (temp + `mv`) ensures no partial
  files visible to concurrent readers.

**Failure modes:**
- Snapshot write fails (disk full, permission) → log
  `READ_SNAPSHOT_WRITE_FAILED` event; allow Read to proceed
  (fail-open per CLAUDE.md §A.5). Pre-filter / validator agent
  will see missing snapshot at consume time and ESCALATE
  defensively.
- Snapshot lookup at consume time finds missing file → pre-filter
  ESCALATEs `escalate:read_snapshot_missing`; validator agent's
  prompt notes "read snapshot unavailable; current content only"
  in Section 3.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.1 layer 3 (Read-set tracking)** —
extend description: "`PreToolUse(Read)` hook computes file
sha256, appends entry to `read_sets[<session_id>].reads[]`,
deduplicates (latest supersedes older). Phase 4 addition: also
captures file content to `.coord/read_snapshots/<sid>/<hash>.txt`
for the validator pipeline (Phase 4) to consume during stale-read
classification. Files exceeding the 10 MB hash cap are recorded
as `SKIPPED_LARGE` in the read-set with no snapshot written;
validator pre-filter unconditionally ESCALATEs in that case."

**B. `IMPLEMENTATION_PLAN.md` §3.2 file structure on disk** — add
`read_snapshots/` block alongside `validator/` (the Phase 4
container) and `validation/` (legacy stub-flag-file path,
removed per PR-PHASE4-01 §B):

```
├── read_snapshots/                  # Phase 4 read-snapshot store
│   └── <session_id>/
│       └── <sha256>.txt             # exact read-time bytes; gone on session_end
```

**C. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** — add:
- `READ_SNAPSHOT_WRITTEN` (payload: `file`, `session`, `hash`,
  `bytes`, `path`).
- `READ_SNAPSHOT_SKIPPED_LARGE` (payload: `file`, `session`,
  `hash="SKIPPED_LARGE"`, `bytes`).
- `READ_SNAPSHOT_WRITE_FAILED` (payload: `file`, `session`,
  `hash`, `reason` ∈ {disk_full, permission_denied,
  rename_failed, unknown}).
- `READ_SNAPSHOT_SUPERSEDED` (payload: `file`, `session`,
  `prior_hash`, `new_hash`).
- `READ_SNAPSHOT_SESSION_CLEANUP` (payload: `session`,
  `removed_count`, `bytes_freed`).

**D. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** — add:
- `read_snapshots_enabled: true` (emergency override; falls
  back to no-snapshot mode + validator pipeline ESCALATEs for
  every stale-read).
- `read_snapshots_max_per_session_mb: 100` (soft cap; bounds
  [1, 1024] — 1 MB minimum, 1 GB maximum). When exceeded, oldest
  snapshots are GCed via LRU on the snapshot-write path. (Phase 7
  may relax this if measurement shows the cap is rarely hit; for
  v1, defensive against runaway storage.)

`coord health` validates the bounds.

**E. `IMPLEMENTATION_PLAN.md` §4 component specs** — add:

`lib/read_snapshots.sh`:
- `coord_read_snapshot_path <sid> <hash>` — returns the canonical
  filesystem path for a snapshot (string only; no I/O). Used by
  consumers (validator pre-filter, validator spawn) to resolve
  `<read_content_path>`.
- `coord_read_snapshot_write <sid> <hash> <source_file>` —
  copies `<source_file>` to `coord_read_snapshot_path <sid>
  <hash>` via temp + atomic rename. Returns 0 on success, 1 on
  failure (logs `READ_SNAPSHOT_WRITE_FAILED` event). Idempotent:
  if the destination exists, no-op (re-Read of unchanged file).
  Skips silently when `hash == "SKIPPED_LARGE"` (logs
  `READ_SNAPSHOT_SKIPPED_LARGE` and returns 0).
- `coord_read_snapshot_supersede <sid> <prior_hash>` — deletes
  the prior snapshot file. Returns 0 on success or no-op (file
  absent). Logs `READ_SNAPSHOT_SUPERSEDED` when a file was
  actually removed.
- `coord_read_snapshot_cleanup_session <sid>` — recursively
  removes `.coord/read_snapshots/<sid>/`. Returns 0 idempotent.
  Logs `READ_SNAPSHOT_SESSION_CLEANUP` with counts.
- `coord_read_snapshot_lookup <sid> <hash>` — returns 0 if the
  snapshot file exists and is readable; 1 otherwise. Used by
  consumers to detect missing-snapshot fallback path.

`pre_tool_use_read.sh` extension (T4.02a):
- After existing atomic_edit recording the read-set entry, call
  `coord_read_snapshot_write "$SESSION_ID" "$HASH" "$FILE_PATH"`.
- The supersede behavior (deleting prior snapshot when the
  read-set entry's `is_latest` flips to false) is handled inline
  in the same atomic-edit step: detect prior hash via jq during
  the supersede walk, then call
  `coord_read_snapshot_supersede` after the atomic_edit returns.

`session_end.sh` extension (T4.02a):
- After existing session-row archive logic, call
  `coord_read_snapshot_cleanup_session "$SESSION_ID"`.

`install.sh` extension (T4.02a):
- Create `.coord/read_snapshots/` (empty directory; per-session
  subdirectories created lazily on first Read).
- `install.sh --uninstall` cleanup removes the directory along
  with the rest of `.coord/`.

**F. `IMPLEMENTATION_PLAN.md` §4 `lib/verdict_apply.sh` (existing
Mediator action helper)** — extend the `evict_session` action to
ALSO call `coord_read_snapshot_cleanup_session <sid>` for the
evicted session. Bundles snapshot GC into Mediator's
session-eviction path (handles "session crashed before
session_end.sh fired" case via watchdog → Mediator → eviction
flow).

**G. `IMPLEMENTATION_PLAN.md` §5 Phase 4 Scope** — add:

> "`lib/read_snapshots.sh` and `pre_tool_use_read.sh` /
> `session_end.sh` extensions: capture file content at Read
> time to `.coord/read_snapshots/<sid>/<hash>.txt` for validator
> pipeline consumption. Snapshots are GCed on read-set supersede,
> session end, and Mediator session-eviction. Files >10 MB
> (existing `SKIPPED_LARGE` handling) are not snapshotted;
> validator pre-filter ESCALATEs unconditionally for those."

**H. `CLAUDE.md` §B.1 (before reading any file)** — add a
non-binding note (no rule change for the user; this is purely
internal mechanism):

> "Phase 4 addition: the hook ALSO captures the file content to
> `.coord/read_snapshots/<sid>/<hash>.txt` for the validator
> pipeline to consume on stale-read classification. This is
> internal storage; you do not interact with it. Snapshots are
> GCed automatically (on read-set supersede, on session end, on
> Mediator session-eviction)."

### Implementation-task dependencies

- T4.02a (read-snapshot capture) implements §E + §F + §G. **Gated
  on this PR approval.**
- T4.02b (validator cache + pre-filter) consumes
  `coord_read_snapshot_path` / `coord_read_snapshot_lookup`.
  **Gated on T4.02a close.**
- T4.04 (validator spawn) consumes the read snapshot file in
  Section 3 prompt assembly. **Gated on T4.02a close (along with
  PR-PHASE4-01 + PR-PHASE4-03 approval).**
- T4.06 (pipeline integration) wires the consume side; not
  affected directly by this PR (consumes via T4.02b's pre-filter
  + T4.04's spawn helper).

### Ambiguity dispositions (resolved 2026-04-26 at T4.01-amendment close)

1. **Snapshot file naming.** **RESOLVED — `<hash>.txt`** with
   hash being the full 64-hex sha256. The `.txt` suffix is
   purely cosmetic (signals plaintext to operators inspecting
   the directory); content is exact bytes from the source file
   regardless of whether the source is text or binary. Binary
   files would not normally be Read-tracked at v1 anyway, but
   if they are, the snapshot stores their bytes faithfully.

2. **Snapshot directory permission model.** **RESOLVED — inherit
   from `.coord/`.** `mkdir` defaults apply. Explicit chmod
   not specified; if shared-host permission concerns surface,
   raise as a finding and revisit.

3. **Storage cap behavior when exceeded.** **RESOLVED — LRU
   eviction on snapshot-write path.** When a session's
   `read_snapshots/<sid>/` directory exceeds
   `read_snapshots_max_per_session_mb`, the oldest snapshots
   (by `cached_at` mtime equivalent) are evicted until the cap
   is met. Eviction logs `READ_SNAPSHOT_LRU_EVICTED` event
   (added to §C event list). Consumer-side pre-filter ESCALATEs
   defensively if a needed snapshot is evicted (rare; recent
   reads stay in cache).

4. **Snapshot encoding for non-UTF-8 files.** **RESOLVED — raw
   bytes.** The snapshot is a byte-identical copy of the source
   file. Validator agent's prompt (Section 3) MAY truncate the
   embedded content if it exceeds 100 KB or contains
   non-printable bytes (per PR-PHASE4-01 §"Validator prompt
   structure" Section 3 truncation marker). The truncation is
   the validator spawn helper's responsibility, not the
   snapshot-write path's.

5. **Race between snapshot write and stale-read detection in
   another session.** **RESOLVED — accepted as-designed.**
   When session A reads `foo.ts` and writes its snapshot, then
   session B writes `foo.ts` (changing on-disk content), then
   session A's `pre_tool_use_write.sh` detects stale-read on
   `foo.ts`, the validator pipeline:
   (a) Looks up A's snapshot at
       `.coord/read_snapshots/<A>/<read_hash>.txt` (still
       present — only A's own next-Read or session-end would
       remove it).
   (b) Compares against on-disk current content.
   (c) Computes diff/heuristics correctly.
   The snapshot is "frozen at A's read time," which is exactly
   what we want for stale-read classification. No race here.

6. **Handling of `SKIPPED_LARGE` reads in pre-filter consume
   path.** **RESOLVED — pre-filter ESCALATEs unconditionally.**
   When `read_set` entry's hash is `SKIPPED_LARGE`, no snapshot
   exists. Pre-filter returns `escalate:read_snapshot_missing`
   (or a more specific `escalate:source_skipped_large`).
   Validator agent's prompt notes "the file was too large to
   snapshot at read time; classify based on current content
   alone." Validator agent's classification quality on these
   files is degraded, but consistent with existing Phase 1
   behavior (large files were already SKIPPED_LARGE).

### Cross-references

- PR-PHASE4-01 (Validator agent design contract) — defines the
  consumer; this PR provides the read-snapshot resource. Update
  PR-PHASE4-01 §E `coord_validator_prefilter` signature to
  reference `coord_read_snapshot_path` for resolving
  `<read_content_path>`.
- PR-PHASE4-04 (Validator cache) — cache key is `(file,
  read_hash, current_hash)`; this PR doesn't affect cache but
  notes that on cache miss the pre-filter consume path
  delegates to snapshot lookup.
- PR-PHASE3-01 (Mediator) — `verdict_apply.sh` action verb
  `evict_session` extends to call
  `coord_read_snapshot_cleanup_session`. Documentation-level
  extension; no Mediator code rewrite.
- Decision 2.18 (read-set scope) — extended in spirit: the
  read-set's "reads" entries now have a parallel content
  store. The Decision text itself doesn't change; §3.1 layer 3
  description is the canonical update site (per §A above).
- Decision 2.22 (git HEAD tracking) — orthogonal.
  `superseded_by_head_change` does NOT trigger snapshot
  deletion (snapshot remains valid for diff use; only the
  read-set entry's `is_latest` is invalidated).
- FINDINGS — none currently OPEN against this PR.

### Non-changes (deliberate)

- `read_sets[<sid>].reads[]` schema unchanged — snapshots are a
  parallel content store, not a schema field. Keeping the schema
  unchanged means Phase 1 / Phase 2 / Phase 3 read-set logic is
  byte-identical; Phase 4 only adds a side-effect.
- `coord_hash_file` (`lib/hash.sh`) unchanged — the existing 10
  MB cap + `SKIPPED_LARGE` handling apply to snapshot decisions
  via `pre_tool_use_read.sh`'s call site.
- Phase 3 invariant unchanged: `pre_tool_use_read.sh` still
  emits no `permissionDecision: "deny"` (Phase 1 invariant
  preserved through Phase 3 + 4).
- Subagent filter unchanged — subagent Reads still no-op
  (Decision 2.17 / `subagent_filter.sh`); their snapshots
  would not be written either, since the filter exits 0
  before the hook reaches snapshot capture.
- Validator agent prompt (Section 3) format unchanged from
  PR-PHASE4-01 §"Validator prompt structure" — this PR fills
  the gap of WHERE the read snapshot content comes from
  (`coord_read_snapshot_path`), not the prompt structure.

### Acknowledgement

APPROVED 2026-04-26 at T4.01-amendment close. Status
DRAFT → APPROVED. Surfaced via T4.02 pre-implementation halt;
discipline of halting before code-touch on ambiguity is what
F-011 + the user's "halt and report" direction codify. Final
merge into IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-4-signoff.md.

---

## PR-PHASE5-01 — Wait queue lock semantics + data structure + schema rename (Decision 1)

**Date:** 2026-04-27
**Author:** Phase 5 builder (T5.01).
**Status:** APPROVED 2026-04-27 at T5.01 close. Gates T5.02 (wait queue infrastructure).
**Driver:** User-resolved Decision 1 from Phase 5 resume prompt
("Wait queue lock semantics" — per-file lock pattern, no global
wait_queues.lock, wait_queues[<path>][] data structure, six public
functions in `lib/wait_queue.sh`) plus pin-points (a-1) and (c-1)
from T5.01 startup approval.

### Observed gap requiring change

Plan §5 Phase 5 scope says "wait_queue[<file>] FIFO with explicit
`waiting_since` ordering" but does not specify:
1. Whether the FIFO state lives in `sessions.json` or in a
   separate file.
2. The locking granularity for queue mutations (single global
   lock vs per-file lock).
3. The directory layout of per-file locks (path sanitization
   convention).
4. The set of CLI/library operations exposed.
5. Whether the existing `sessions.json` schema slot is named
   `wait_queue` (singular, as currently encoded in 4 sites) or
   `wait_queues` (plural, as Decision 1 wording specifies).

T5.02 implementation cannot proceed without resolving these.

### User-resolved decision

**Per-file lock pattern with plural schema slot.**

#### 1. Storage location and schema rename

Wait queue state lives in `sessions.json` under a top-level
`wait_queues` slot. This **renames** the existing schema slot
(currently `wait_queue` singular, present-but-empty in 4 code
sites listed below).

**Pre-rename precondition (verified 2026-04-27 at T5.01 open):**
the existing `wait_queue` slot is empty in installed state
(`jq '.wait_queue|keys' .coord/sessions.json` → `[]`,
`[.wait_queue[]?|length]|add` → `0`). No data migration is
needed; the rename is mechanical text substitution.

**4 code sites updated by T5.02:**
- `src/lib/atomic_write.sh:62` — template `wait_queue: {}` →
  `wait_queues: {}`.
- `src/lib/state_query.sh:28` — fallback empty-state line
  `wait_queue: {}` → `wait_queues: {}`.
- `src/tests/helpers/common.bash:53` — bats helper
  `"wait_queue": {}` → `"wait_queues": {}`.
- `src/bin/coord:52` + `src/bin/coord:65` — `coord status`
  reads `.wait_queue[]` (line 52) and prints
  `"wait_queue: …"` label (line 65); both rename to
  `wait_queues`.

**T5.02 pre-rename gate:** the implementer MUST re-verify the
empty-slot precondition immediately before performing the
rename (run the same `jq` probe against `.coord/sessions.json`).
If non-empty data is found, halt and report — a migration
script would be needed. Empty slot expected; rename
straightforward.

#### 2. Wait queue data structure

```json
{
  "wait_queues": {
    "/path/foo.ts": [
      {
        "session_id": "<sid>",
        "waiting_since": "<ISO8601 with ms>",
        "wake_file": ".coord/wakers/<sid>-<sanitized_path>.wake",
        "queue_position": 0
      }
    ]
  }
}
```

- Keys are absolute file paths (the same shape `locks` uses).
- Values are FIFO arrays; index 0 is the head (next to be
  woken).
- `queue_position` is 0-indexed and recomputed on every queue
  mutation (enqueue / dequeue / cleanup_session). Stale
  positions are not tolerated; the queue is the source of
  truth, position is a convenience field.
- `waiting_since` uses millisecond precision per F-009
  (perl `Time::HiRes` via `coord_now_iso8601`).

#### 3. Per-file lock semantics

Each tracked file has its own wait-queue lock at
`.coord/wait_queues/<sanitized_path>.lock`. No global
`wait_queues.lock` is created.

**Path sanitization (pin-point a-1, binding):**
literal `tr / __` form. The leading `/` of an absolute path
becomes a leading `__`. Examples:
- `/src/api.ts` → `__src__api.ts`
- `/Users/x/Desktop/foo/bar.md` → `__Users__x__Desktop__foo__bar.md`
- `relative/path.ts` (no leading slash) → `relative__path.ts`

Reverse mapping is unambiguous: every `__` in the sanitized
form was a `/` in the original. (No real path component
contains `__` in practice; if a future regression surfaces such
a path, raise a finding and revisit.) The lock-filename helper
sets the working file for the
subshell-redirected-fd-form per F-003:

```
(
  flock -x -w "$timeout" 9
  # critical section: read/mutate sessions.json wait_queues[$file]
) 9>".coord/wait_queues/<sanitized_path>.lock"
```

The lock file is created lazily on first enqueue for a given
file path; it persists across the session lifetime and is
cleaned up only by `install.sh --uninstall` (the `.coord/`
purge). Empty lock files are byte-identical and cheap; no
runtime sweep is needed.

**Rationale for per-file (vs global) granularity:** under a
heavy multi-file coordinated workload with N waiters across M
files, per-file locks yield up to M concurrent flock operations
versus 1 global serialization point. Cycle detection (which
needs a consistent snapshot across multiple files) does NOT
hold the per-file locks; it reads `sessions.json` directly
under the existing `sessions.lock` (the cycle detector's read
is a point-in-time snapshot, not a transactional barrier across
files — see PR-PHASE5-03 for cycle-detection isolation
semantics).

#### 4. Public API: `lib/wait_queue.sh`

Six public functions:

- `coord_wait_queue_enqueue <sid> <file_path>`
  Acquires per-file flock; appends an entry to
  `wait_queues[<file_path>]` with the current ISO timestamp,
  pre-computed wake_file path, and queue_position derived
  from the post-append array length. Recomputes positions on
  ALL entries for the file (defensive against partial state).
  Idempotent: if `<sid>` is already in the queue for
  `<file_path>`, returns its existing wake_file path without
  re-appending. Logs `WAIT_QUEUE_ENQUEUE` event.
  **Returns:** wake_file path on stdout; rc=0 on success, rc=1
  on flock timeout, rc=2 on atomic_edit failure.
  **Cycle-detection trigger:** when post-append queue depth ≥
  2, enqueue invokes `coord_cycle_detect <sid>` (PR-PHASE5-03)
  before returning. Cycle detection is in-process; if a cycle
  is found, the `cycle_detected` pending entry is written
  before enqueue returns. The enqueue itself still succeeds
  (rc=0); the caller sees the wake_file path normally and the
  Mediator handles the cycle on the consumer side.

- `coord_wait_queue_dequeue <sid> <file_path>`
  Acquires per-file flock; removes the entry where
  `session_id == <sid>`. Recomputes queue_positions on
  remaining entries. Logs `WAIT_QUEUE_DEQUEUE` event.
  Idempotent: if `<sid>` is not in the queue, no-op (rc=0).
  **Returns:** rc=0 on success or no-op, rc=1 on flock
  timeout, rc=2 on atomic_edit failure.

- `coord_wait_queue_head <file_path>`
  Acquires per-file flock briefly (read-only critical
  section). Returns the head entry's session_id and wake_file
  as TSV on stdout (`<sid>\t<wake_file>`). Empty stdout if
  queue is empty.
  **Returns:** rc=0 on success (including empty), rc=1 on
  flock timeout.

- `coord_wait_queue_size <file_path>`
  Acquires per-file flock briefly. Returns queue length on
  stdout. Empty queue → "0".
  **Returns:** rc=0 always (defensive; callers that need
  authoritative answers should hold the per-file lock around
  their own jq query instead).

- `coord_wait_queue_position <sid> <file_path>`
  Acquires per-file flock briefly. Returns 0-indexed position
  on stdout, or "-1" if `<sid>` is not in the queue.
  **Returns:** rc=0 always.

- `coord_wait_queue_cleanup_session <sid>`
  Walks ALL `wait_queues` entries (under `sessions.lock`, NOT
  per-file locks — this is a global cleanup), removes every
  entry with `session_id == <sid>`. Recomputes queue_positions
  on each affected file's queue. Removes corresponding
  wake_files from `.coord/wakers/<sid>-*.wake`. Logs
  `WAIT_QUEUE_SESSION_CLEANUP` event with affected-file count.
  Called from: `session_end.sh` (graceful exit), watchdog
  eviction path (via `verdict_apply.sh::evict_session`), and
  `install.sh --repair` (defensive sweep for orphaned waiters
  after a crash).

All operations under `set -euo pipefail` per CLAUDE.md §A.5;
all state-file mutations go through `coord_atomic_edit` per the
same rule.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.1 layer 5 (Wait queue)** —
new paragraph: "Phase 5 implementation: per-file FIFO at
`wait_queues[<file_path>]` in sessions.json, with per-file
flock at `.coord/wait_queues/<sanitized_path>.lock` (path
sanitization: `tr / __`). Queue mutations via
`lib/wait_queue.sh` six-function API
(enqueue/dequeue/head/size/position/cleanup_session). Cycle
detection triggered on post-enqueue depth ≥ 2 (see
PR-PHASE5-03)."

**B. `IMPLEMENTATION_PLAN.md` §3.2 file structure on disk** —
add `wait_queues/` and `wakers/` blocks alongside `validator/`
and `read_snapshots/`:

```
├── wait_queues/                      # Phase 5 per-file flock locks
│   └── <sanitized_path>.lock         # tr / __ from absolute file path
├── wakers/                           # Phase 5 per-(session, file) wake files
│   └── <session_id>-<sanitized_path>.wake
```

**C. `IMPLEMENTATION_PLAN.md` §3.3 sessions.json schema** —
rename top-level slot `wait_queue` → `wait_queues`. Update
the schema text for the value type:

```json
{
  "wait_queues": {
    "<file_path>": [
      {
        "session_id": "<uuid>",
        "waiting_since": "<ISO8601 with ms>",
        "wake_file": "<relative path>",
        "queue_position": 0
      }
    ]
  }
}
```

The plural form is the canonical name; the singular
`wait_queue` is a Phase-0/1/2/3/4 vestige of the empty slot
template and is removed.

**D. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** —
add:
- `WAIT_QUEUE_ENQUEUE` (payload: `file`, `session`,
  `queue_position`, `wake_file`).
- `WAIT_QUEUE_DEQUEUE` (payload: `file`, `session`,
  `removed_position`, `remaining_size`).
- `WAIT_QUEUE_SESSION_CLEANUP` (payload: `session`,
  `affected_files`, `removed_count`, `wake_files_removed`).

**E. `IMPLEMENTATION_PLAN.md` §4 component specs** — add
`lib/wait_queue.sh` with the 6-function contract above. Note
the per-file flock convention and cite F-003 (subshell +
redirected fd) as the lock-form reference.

**F. `CLAUDE.md` §B.7 (Wait queue / passive wait)** — non-
binding update: add a short note that Phase 5 makes the
wait queue authoritative (vs Phase 2's events.jsonl scan) and
that operators should never edit `wait_queues/<…>.lock` files
or `wakers/<…>.wake` files directly. Wire-protocol details
do not appear in user-facing CLAUDE.md text; they live in
this PR.

### Implementation-task dependencies

- T5.02 (wait queue infrastructure) implements §A through §E
  + the 4-site rename (verified empty slot first). **Gated
  on this PR approval.**
- T5.03 (wake file mechanism + event-driven coord wait)
  consumes `coord_wait_queue_enqueue` and the wake_file path
  it returns. **Gated on T5.02 close.**
- T5.04 (notification diff_summary integration) does NOT
  touch `wait_queue.sh` directly; it modifies
  `notify_waiters.sh` to write to wake_file content. **Not
  gated by this PR.**
- T5.05 (cycle detection) extends `coord_wait_queue_enqueue`
  to call `coord_cycle_detect` post-append. **Gated on T5.02
  close + PR-PHASE5-03 approval.**
- T5.07 (Phase 5 invariant) adds the
  `wait_queue.sh-zero-permissionDecision` bonus guard.
  **Gated on T5.02 close.**

### Ambiguity dispositions (resolved 2026-04-27 at T5.01 open)

1. **Sanitization form** (pin-point a-1). **RESOLVED — literal
   `tr / __`.** Leading underscore preserved. `/src/api.ts` →
   `__src__api.ts`.
2. **Schema slot naming** (pin-point c-1). **RESOLVED —
   plural `wait_queues`.** 4-site rename in T5.02 with empty-
   slot precondition verified at T5.01 open and to be re-
   verified by T5.02 implementer immediately before rename.
3. **Locking granularity.** **RESOLVED — per-file flock at
   `.coord/wait_queues/<sanitized_path>.lock`.** No global
   wait_queues.lock. Cycle detection reads `sessions.json`
   under `sessions.lock` for its bipartite traversal; does
   not hold per-file locks (snapshot read).
4. **`waiting_since` precision.** **RESOLVED — ms-precision
   ISO8601 via `coord_now_iso8601`** (perl Time::HiRes per
   F-009). Same precision as Phase 3 watchdog activity
   timestamps.
5. **Idempotent enqueue.** **RESOLVED — yes.** If `<sid>` is
   already queued for `<file>`, return its existing wake_file
   path without appending a duplicate. Defensive against hook
   double-fire scenarios.
6. **`coord_wait_queue_cleanup_session` global walk vs per-
   file.** **RESOLVED — global walk under `sessions.lock`.**
   Per-file locks are for the FIFO ordering invariant on a
   single file; cleanup is a cross-file orthogonal concern
   that the global lock already covers via atomic_edit.

### Cross-references

- **Decision 1** (verbatim from Phase 5 resume prompt) — this
  PR encodes the per-file lock pattern, sanitization, data
  structure, and 6-function API.
- **PR-PHASE5-02** — wake_file mechanism + event-driven
  coord wait + notify_waiters.sh extension. Consumes the
  wake_file path produced by `coord_wait_queue_enqueue`.
- **PR-PHASE5-03** — cycle detection. `coord_cycle_detect`
  invoked from `coord_wait_queue_enqueue` on post-append
  depth ≥ 2.
- **PR-PHASE5-05** — Phase 5 architectural invariant.
  `lib/wait_queue.sh` is bonus guard #10 (zero
  permissionDecision).
- **F-003** (flock subshell + redirected-fd convention) —
  applies to per-file wait-queue locks.
- **F-009** (perl Time::HiRes ms timestamps) — applies to
  `waiting_since` field.
- **F-010** (branch policy) — Phase 5 lands on
  `phase-5/wait-queue-cycle-detection`; merge to main on
  user approval at signoff.
- **F-014** (apostrophe-fragile bats) — ensure
  `wait_queue.bats` test scaffolding uses
  `_grep_output_for` helper, not `bash -c "echo '$output'"`.

### Non-changes (deliberate)

- `notifications[<sid>][<path>]` schema unchanged (Phase 1
  established; Phase 2 producer; Phase 5 keeps it as a
  parallel notification channel for non-wait-queue waiters
  e.g., sessions denied a write but not currently in the
  queue).
- `locks[<file>]` schema unchanged in this PR (PR-PHASE5-02
  adds the `latest_validator_verdict_ts` field; orthogonal
  to wait queue).
- `sessions.lock` / `events.lock` / `cache.lock` / etc.
  unchanged. Per-file wait-queue locks are a new lock family,
  not a substitute.
- Phase 2's `coord wait` polling (30s/60s/120s cadence)
  remains in the codebase as the fallback path for the
  fswatch/inotifywait-absent case; PR-PHASE5-02 specifies the
  fallback contract.

### Acknowledgement

DRAFT. Pending user approval at T5.01 close. Pin-points (a-1)
and (c-1) from T5.01 startup approval are binding. Final merge
into IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-5-signoff.md.

---

## PR-PHASE5-02 — Notification diff_summary + wake_file content protocol + platform abstraction + locks schema field (Decision 2)

**Date:** 2026-04-27
**Author:** Phase 5 builder (T5.01).
**Status:** APPROVED 2026-04-27 at T5.01 close. Gates
T5.03 (wake file mechanism + event-driven coord wait) and T5.04
(notify_waiters diff_summary integration).
**Driver:** User-resolved Decision 2 from Phase 5 resume prompt
("Notification diff_summary attachment point" — extend
notify_waiters.sh; compute via Phase 4 pipeline reuse) plus
pin-points (c-2), (c-3), (d), and (e) from T5.01 startup
approval.

### Observed gap requiring change

Plan §5 Phase 5 scope says "Notification emission on lock-
release includes content summary" and "additionalContext for
passive-waiters when they wake up: 'You waited for foo.ts; it
was released after N seconds. Changes since you last read it:
…'" but does not specify:
1. WHERE in the lock-release path the diff_summary attaches.
2. HOW it is computed (validator agent re-spawn? cache
   lookup? events.jsonl scrape?).
3. HOW it propagates from producer (lock-release hook) to
   consumer (waiting `coord wait` process).
4. WHAT replaces Phase 2's events.jsonl LOCK_DENIED-scan
   notification mechanism.
5. WHAT happens when no validator pipeline ran for the
   release (no stale-read drift was detected during the
   write).
6. WHICH event-watcher backend the consumer uses
   (`fswatch`/`inotifywait`/polling) and what fallback policy
   applies when neither is installed.
7. HOW the producer/consumer race on wake_file content is
   prevented.

T5.03 and T5.04 cannot proceed without resolving these.

### User-resolved decision

**Six sub-dispositions, all binding.**

#### 1. diff_summary attachment point: lock-release moment, inline

`lib/notify_waiters.sh` is extended (NOT replaced) so that
`coord_notify_lock_release_waiters` computes the diff_summary
synchronously during the lock-release atomic_edit and writes
it to the wake_file content of every queued waiter on the
released file.

The compute happens inside the existing function, after
`waiters_json` is collected and BEFORE the per-waiter
notification append. The new branch operates on
`wait_queues[<file>]` (the Phase 5 source of truth) instead of
the events.jsonl scan (see §2 below).

#### 2. Pivot to wait_queues authoritative source (pin-point c-2)

Phase 2's events.jsonl LOCK_DENIED scan (lines 88-105 of
`notify_waiters.sh`) is **deleted** in T5.04 and replaced
with a `wait_queues[<file>]` enumeration:

```bash
waiters_json=$(jq -sc \
    --arg path "$path" \
    '[.wait_queues[$path][]?
      | {session: .session_id, wake_file: .wake_file}]' \
    "$state" 2>/dev/null || printf '[]')
```

Every entry in the queue is woken in FIFO order; the head
session is responsible for retrying the write next, the tail
sessions are surfaced via `additionalContext` on their next
PreToolUse hook.

**Single source of truth principle:** `wait_queues` is now the
authoritative waiter list. events.jsonl remains read-only for
audit trail; LOCK_DENIED events still fire (PreToolUse hook on
denied write) but are no longer scanned by the producer.

The `notifications[<sid>][<path>]` consumer side (Phase 1
dormant consumer in pre_tool_use_read.sh +
pre_tool_use_any.sh) is **kept** as a complementary channel:
sessions that were denied but later moved on (cleared queue,
self-delegated, etc.) still get a "lock_released:..." string
appended for surface on next read or PreToolUse. The
producer-side change is purely the source-of-truth pivot.

#### 3. Wake_file content protocol (pin-point c-3)

**Producer** (extended `notify_waiters.sh`, executed in the
release-side hook context — `post_tool_use_write.sh` or
`stop.sh`):

```bash
for waiter in $waiter_list; do
    wake_file="$(get_wake_file "$waiter" "$path")"
    printf "%s\n" "$diff_summary" > "$wake_file"
done
```

Atomic single-write `>`; the `printf "%s\n"` ensures a trailing
newline so the consumer can distinguish "written" from
"truncated". Permission inherits from `.coord/` (no explicit
chmod). Empty `diff_summary` is permitted (rare; see fallback
in §6 below) and the consumer handles it.

**Consumer** (`coord wait` wrapper, see §4 backend abstraction):

```bash
content=$(cat "$wake_file")
if [ -z "$content" ]; then
    sleep 0.05                       # 50 ms grace
    content=$(cat "$wake_file")
fi
if [ -z "$content" ]; then
    content="modified by $releaser_session_id"
fi
printf "%s" "$content"
```

The 50 ms grace handles the create-vs-write race: fswatch /
inotifywait may fire on the empty `touch` (file-create event)
before the producer's `printf` lands. After 50 ms (well above
the typical 1-5 ms producer write latency), if content is
still empty, the empty-fallback "modified by <session>" is
semantically correct (waiter knows the file changed but does
not have a richer summary).

The waiter does NOT delete the wake_file on read; cleanup is
handled by `coord_wait_queue_dequeue` (which removes both the
queue entry and the wake_file) once the waiter exits its
`coord wait` invocation.

#### 4. Platform abstraction (pin-point d)

**Backend selection at install time:**

`install.sh` extends `materialize_coord` with a deps-check that
records the wake-event backend in `.coord/config.json`:

```json
{
  "wait_event_backend": "fswatch|inotifywait|polling",
  "wait_event_backend_reason": "auto-detected"
}
```

Detection order:
1. `command -v fswatch` succeeds → `fswatch` (preferred on
   macOS).
2. `command -v inotifywait` succeeds → `inotifywait`
   (preferred on Linux).
3. Neither → `polling` fallback (250 ms wake_file mtime
   poll).

The user can override via env var `COORD_WAIT_EVENT_BACKEND`
or `coord config set wait_event_backend …`; bounds checked by
`coord health`. **Reasoning:** F-001 precedent (flock optional
deps) — the system gracefully degrades but emits a SessionStart
banner when the polling fallback is active.

**SessionStart additionalContext warning:**
`session_start.sh` reads `.config.json::wait_event_backend`
and, if value is `polling`, appends to `additionalContext`:

> Polling-mode wait-queue active. Install `fswatch` (macOS:
> `brew install fswatch`) or `inotify-tools` (Linux:
> `apt install inotify-tools`) for sub-100 ms wake-up
> latency.

**WAIT_BACKEND event:**
First `coord wait` invocation per session emits one
`WAIT_BACKEND` event:

```json
{
  "kind": "WAIT_BACKEND",
  "backend": "fswatch|inotifywait|polling",
  "reason": "auto-detected"
}
```

Subsequent `coord wait` calls in the same session do NOT re-
emit (idempotent at session scope; tracked via in-process
flag, not persisted across sessions).

**`coord wait` wrapper:** consumes `wait_event_backend` and
dispatches:

- `fswatch -1 "$wake_file"` (single-event mode; exits when
  the watched file is modified).
- `inotifywait -e modify -e create "$wake_file"` (modify
  event; exits on the producer's `>` write).
- Polling fallback: `while [ ! -s "$wake_file" ]; do sleep
  0.25; done` (250 ms cadence; replaces Phase 2's
  30s/60s/120s when polling backend is selected).

All three branches converge on the §3 consumer read protocol
(50 ms grace + empty-fallback) before printing
diff_summary to stdout.

#### 5. locks schema field: `latest_validator_verdict_ts` (pin-point e)

The Phase 4 pipeline writes a verdict file at
`.coord/validator/verdict/<ts>.json` whenever the validator
agent runs (or whenever a CRITICAL Mediator inline runs).
Phase 5 needs to bridge from "this lock was acquired" to
"the most recent verdict for this file" without re-running
the validator.

**Schema addition** (T5.04 modifies `lib/atomic_write.sh`
template + `pre_tool_use_write.sh` lock-acquire path):

```json
{
  "locks": {
    "/path/foo.ts": {
      "session_id": "<sid>",
      "acquired_at": "<ISO>",
      "last_refresh_at": "<ISO>",
      "tasks": [],
      "latest_validator_verdict_ts": "<ts>" | null
    }
  }
}
```

**Population:** the Phase 4 pipeline
(`_coord_phase4_run_pipeline` in `pre_tool_use_write.sh`)
already writes verdict files. T5.04 extends the post-write
flow so that when a validator pipeline run completes (any
disposition: SAFE / MINOR / CRITICAL / pipeline-failure), the
verdict_ts is captured. On lock acquisition, this ts is set
on the lock record. The field is `null` when the lock was
acquired without any validator pipeline run (no stale-read
drift detected — the common case).

**Consumption** (extended `notify_waiters.sh`):

```bash
verdict_ts=$(jq -r --arg f "$path" \
    '.locks[$f].latest_validator_verdict_ts // empty' "$state")
if [ -n "$verdict_ts" ]; then
    diff_summary=$(jq -r '.diff_summary // empty' \
        "$COORD_DIR/validator/verdict/$verdict_ts.json")
fi
if [ -z "$diff_summary" ]; then
    diff_summary="modified by ${holder:0:8}"
fi
```

**Fallback path:** when `latest_validator_verdict_ts` is null
(common case — most writes don't trigger the validator
pipeline), the diff_summary is `"modified by <session_id_8>"`.
This is semantically correct (waiter knows the file changed)
and matches the §3 consumer empty-fallback string.

**Edge case: pipeline ran but produced no diff_summary**
(e.g., spawn-failure path → Phase 1 fallback line). In this
case, the verdict file may not exist, or may have an empty
`diff_summary`. Either way, `notify_waiters.sh`'s jq lookup
returns empty and the fallback string is used. NOT an error
condition; documented as expected behavior.

#### 6. Edge cases and explicit non-changes

- **Lock release without queued waiters:** `wait_queues[<file>]`
  is empty → `notify_waiters.sh` collects empty `waiters_json`
  → existing early-return (line 110 of current
  notify_waiters.sh) fires; no wake_file write attempted.
  This is the path-of-least-surprise; no diff_summary
  computation either (cheap fast path).
- **Stop hook multi-lock release:** `stop.sh` releases all
  locks held by the exiting session. For each released lock,
  `notify_waiters.sh` is called once. Each call independently
  fetches its own `latest_validator_verdict_ts` and writes
  diff_summary to its file's waiters' wake_files. No batch
  optimization in v1.
- **Watchdog eviction:** `verdict_apply.sh::evict_session`
  releases the evicted session's locks via the same path as
  graceful exit. Notify-waiters fires, wake_files updated.
  Phase 7 stress test will verify this end-to-end.
- **Phase 2 polling cadence in non-fallback mode:** Phase 2's
  `cmd_wait` polling at 30s/60s/120s is **superseded** when
  `wait_event_backend != "polling"`. The `cmd_wait`
  implementation is rewritten in T5.03 to dispatch on backend;
  the polling cadence is preserved ONLY in the fallback
  branch (and tightened from 30s to 250 ms — much faster
  because the fallback's only purpose is wake_file detection,
  not arbitrary state polling).

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.2 file structure on disk** —
clarify `.coord/wakers/` is the wake_file directory (already
added by PR-PHASE5-01 §B); document content protocol:
"Wake files contain the diff_summary text written by
notify_waiters.sh on lock release. Empty file = waiter still
waiting; non-empty file = woken with context. Permission
inherits from `.coord/`."

**B. `IMPLEMENTATION_PLAN.md` §3.3 sessions.json schema** —
extend `locks[<file>]` value type with
`latest_validator_verdict_ts: string | null` field.

**C. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** —
add:
- `WAIT_WAKE` (payload: `file`, `session`, `backend`,
  `latency_ms`, `diff_summary_source` ∈ {`validator_verdict`,
  `fallback`}).
- `WAIT_BACKEND` (payload: `backend`, `reason`).
- `NOTIFICATION_PRODUCED` already exists from Phase 2 — extend
  payload to include `diff_summary_present` (boolean).

**D. `IMPLEMENTATION_PLAN.md` §3.6 config.json defaults** —
add:
- `wait_event_backend: "auto"` (auto-detected at install;
  override values: `fswatch`, `inotifywait`, `polling`).
- `wait_event_backend_reason: "auto-detected"` (informational;
  surfaced in `coord status`).

`coord health` validates the enum; rejects unknown values.

**E. `IMPLEMENTATION_PLAN.md` §4 component specs** — modify:

`lib/notify_waiters.sh`:
- DELETE the events.jsonl LOCK_DENIED scan (lines 88-105).
- ADD `wait_queues[$path]` enumeration as the waiter source.
- ADD `latest_validator_verdict_ts` lookup.
- ADD `.coord/validator/verdict/<ts>.json` content read for
  diff_summary extraction (fallback to "modified by
  <session_id_8>" on missing/empty).
- ADD wake_file content write (`printf "%s\n" "$diff_summary"
  > "$wake_file"`) per queued waiter.
- KEEP `notifications[<sid>][<path>]` append (for non-queue
  waiters) — complementary channel.
- KEEP `NOTIFICATION_PRODUCED` event emission; add
  `diff_summary_present` payload field.

`pre_tool_use_write.sh` (extended in T5.04):
- After successful lock acquisition, if the validator
  pipeline produced a verdict during the same hook turn,
  populate `locks[<target>].latest_validator_verdict_ts`
  in the same atomic_edit.

`bin/coord` (extended in T5.03):
- `cmd_wait` dispatches on `config.wait_event_backend`:
  fswatch / inotifywait / polling branches with shared
  consume protocol (§3).
- First `cmd_wait` per session emits `WAIT_BACKEND` event.

`install.sh` (extended in T5.03):
- `materialize_coord`: detect `fswatch` / `inotifywait`;
  write `wait_event_backend` + `wait_event_backend_reason`
  to config.json defaults block.
- `--repair`: re-detect and update config (idempotent).

**F. `CLAUDE.md` §B.7 (Wait queue / passive wait)** — extend
to describe the wake_file content protocol (one or two
sentences only; no detailed mechanics): "On lock release, the
holder writes a diff_summary line to the waiter's wake_file
which `coord wait` reads on wake-up and prints to stdout for
your additionalContext."

**G. `CLAUDE.md` §B.8 (passive waiting cadence)** — replace
30s/60s/120s cadence narrative with backend-aware narrative:
"Wake-up is event-driven via fswatch (macOS), inotifywait
(Linux), or 250 ms wake_file mtime polling fallback. Cadence
is sub-100 ms in the event-driven case, ≤250 ms in fallback."

### Implementation-task dependencies

- T5.03 (wake file mechanism + event-driven coord wait)
  implements §A + §D (config) + §E `bin/coord` + `install.sh`.
  **Gated on this PR + PR-PHASE5-01 approval.**
- T5.04 (notification diff_summary integration) implements
  §B (locks schema field) + §E `notify_waiters.sh` +
  `pre_tool_use_write.sh` extension. **Gated on this PR
  approval.**
- T5.07 (Phase 5 invariant) — no new bonus guards from this
  PR (`notify_waiters.sh` already emits zero
  permissionDecision; existing Phase 3 invariant covers the
  `verdict_apply.sh` extension PR-PHASE5-03 introduces).
- T5.08 (pipeline integration) wires the lock-release end-to-
  end. **Gated on T5.03 + T5.04 close.**
- T5.09 (ship-gate fixtures) — scenario `02_wake_file_event_
  driven` and `03_diff_summary_on_release` exercise this PR.

### Ambiguity dispositions (resolved 2026-04-27 at T5.01 open)

1. **Where diff_summary attaches.** **RESOLVED — lock-release
   moment, inline in `notify_waiters.sh`** (Decision 2 + this
   PR §1). The release hook is the only deterministic moment
   where before/after content is known.
2. **Source-of-truth pivot from events.jsonl scan to
   wait_queues** (pin-point c-2). **RESOLVED — full pivot.**
   Phase 2's events.jsonl scan deleted in T5.04. Single source
   of truth.
3. **Producer/consumer race mitigation** (pin-point c-3).
   **RESOLVED — 50 ms grace re-read with empty-fallback to
   "modified by <session_id_8>".**
4. **Backend auto-detection + fallback** (pin-point d).
   **RESOLVED — install.sh deps-check writes
   `wait_event_backend` to config; SessionStart warning when
   polling; 250 ms polling cadence in fallback.** F-001
   precedent.
5. **diff_summary computation source** (pin-point e).
   **RESOLVED — `locks[<file>].latest_validator_verdict_ts`
   schema field bridges Phase 4 verdict files to Phase 5
   notify_waiters; fallback string when null.**
6. **Cache lookup vs verdict-file read.** **RESOLVED — verdict-
   file read.** The cache (PR-PHASE4-04) is keyed on (file,
   read_hash, current_hash) and has 1-hour TTL; the verdict
   file is keyed on ts and is permanent (within 24-hour GC
   per PR-PHASE3-04). For diff_summary attachment at lock-
   release, the verdict-file path is more direct (the lock
   record stores verdict_ts; the verdict file is a single jq
   `.diff_summary` away). The cache is consulted earlier in
   the pipeline (validator-pipeline cache short-circuit) and
   not re-consulted at notify time.

### Cross-references

- **Decision 2** (verbatim from Phase 5 resume prompt) — this
  PR encodes the inline-attachment rule and Phase 4 pipeline
  reuse.
- **PR-PHASE5-01** — wait_queues schema + per-file lock
  semantics. This PR consumes
  `coord_wait_queue_enqueue`'s wake_file path.
- **PR-PHASE4-04** (validator cache) — orthogonal; cache is
  used for pipeline short-circuit, not for notify-time
  diff_summary lookup.
- **PR-PHASE3-04** (pending.jsonl GC) — same 24-hour
  retention applies to verdict files; T5.04 must verify
  verdict-file freshness before consuming.
- **F-001** (optional deps install model) — applies to
  fswatch / inotifywait detection.
- **F-014** (apostrophe-fragile bats) — `wait_wake.bats` and
  `notify_waiters.bats` extension MUST use `_grep_output_for`
  helper; diff_summary text contains user-content that may
  have apostrophes.

### Non-changes (deliberate)

- `notifications[<sid>][<path>]` consumer side (Phase 1
  dormant consumer) unchanged. It remains a complementary
  notification channel.
- `events.jsonl` LOCK_DENIED event unchanged; only the
  notify_waiters.sh SCAN of it is removed.
- `wait_queues` schema (PR-PHASE5-01) unchanged by this PR.
- `cache.json` (PR-PHASE4-04) unchanged; not consulted at
  notify time.
- Phase 2's `coord wait` polling cadence preserved ONLY in
  the polling-fallback branch (tightened to 250 ms).
- Phase 4 invariant (8 architectural + 1 bonus guard)
  preserved; `notify_waiters.sh` continues to emit zero
  permissionDecision.

### Acknowledgement

DRAFT. Pending user approval at T5.01 close. Pin-points (c-2),
(c-3), (d), and (e) from T5.01 startup approval are binding.
Final merge into IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-5-signoff.md.

---

## PR-PHASE5-03 — Cycle detection algorithm + cycle_detected pending kind (Decision 3)

**Date:** 2026-04-27
**Author:** Phase 5 builder (T5.01).
**Status:** APPROVED 2026-04-27 at T5.01 close. Gates
T5.05 (cycle detection library) and T5.06 (Mediator pending
kind extension).
**Driver:** User-resolved Decision 3 from Phase 5 resume prompt
("Cycle detection" — DFS bipartite traversal, depth ≥ 2
trigger, <50 ms budget, cycle_detected pending kind, Mediator
inline) plus pin-point (a-2) from T5.01 startup approval.

### Observed gap requiring change

Plan §5 Phase 5 done-when says "Cycle introduced artificially
triggers Mediator verdict that breaks the cycle" but does not
specify:
1. The graph topology (session-only vs bipartite session/file).
2. The trigger threshold (depth ≥ 2 vs depth ≥ 3 vs every
   enqueue).
3. The detection algorithm (DFS, BFS, Tarjan SCC).
4. The cycle-path payload schema for the Mediator.
5. The Mediator escalation pathway (synchronous inline vs
   async pending-consumer).
6. The recursion-guard relationship to Phase 4's
   CRITICAL-drift Mediator inline pattern.

T5.05 and T5.06 cannot proceed without resolving these.

### User-resolved decision

**Bipartite session/file DFS, triggered on enqueue depth ≥ 2,
synchronous Mediator inline.**

#### 1. Graph topology (pin-point a-2): bipartite

The graph has two node types:
- **Session nodes:** one per ACTIVE session in `sessions` map.
- **File nodes:** one per file appearing in `locks` or
  `wait_queues`.

Edges are directed:
- For each `locks[<file>] = {session: S}`: edge `file → S`
  (file is held by session S).
- For each `wait_queues[<file>][i] = {session_id: S}`: edge
  `S → file` (session S waits for file).

A cycle is a directed path that returns to the starting node.
In this bipartite graph, every cycle alternates session →
file → session → file → … and has even length (number of
edges = 2 * number of distinct sessions in the cycle).

**Example 2-cycle (deadlock):**
- Session A holds `foo.ts`, waits for `bar.ts`.
- Session B holds `bar.ts`, waits for `foo.ts`.
- Edges: `A → bar.ts`, `bar.ts → B`, `B → foo.ts`,
  `foo.ts → A`.
- Cycle path: `A → bar.ts → B → foo.ts → A`.

**Why bipartite (not session-only):** the bipartite encoding
matches the on-disk data structure
(`wait_queues[file]` + `locks[file]`) directly. A session-only
graph (edge `S_a → S_b` when S_a waits on a file held by S_b)
is mathematically equivalent for cycle detection but requires
synthesizing the edges from two data sources, adding a
transformation step that's redundant with the natural
representation. Cycle paths in the bipartite form retain file
identity, which is useful for the Mediator's payload (it can
see which files are involved without a separate lookup).

#### 2. Trigger threshold: post-enqueue depth ≥ 2

`coord_wait_queue_enqueue` (PR-PHASE5-01) calls
`coord_cycle_detect <sid>` after the atomic_edit completes,
when `wait_queues[<file>]` length ≥ 2.

**Rationale for depth ≥ 2:** depth 0 (empty queue before
enqueue) and depth 1 (just-added single waiter) cannot form a
cycle by themselves — at least 2 sessions must be in `wait
state` for a cycle to exist. Depth ≥ 2 is the smallest
threshold where cycle detection is non-trivially worth
running. It also matches the simplest deadlock (2-cycle, the
"A waits for B, B waits for A" case).

**Cost:** detection runs ≤ 50 ms (target) or ≤ 100 ms (worst
case, 100 sessions). Below CLAUDE.md §A.6's 2-second hook-
latency ceiling. Bipartite DFS is O(V + E) where V = sessions
+ files and E = locks + queued-waiters-total; for typical
fleet (10-50 sessions, similar locks) this is negligible.

**False-positive avoidance:** the trigger fires on every
post-enqueue depth-2-or-more event, including queues that
grow to depth 5 + 6 + 7 etc. without any cycle. The DFS is
cheap; the false-positive cost is one O(V+E) walk per
enqueue. Acceptable.

#### 3. DFS algorithm

`coord_cycle_detect <session_id_just_added>`:

```
Inputs:
  S_new = session_id that just enqueued
  state = sessions.json snapshot (read once under sessions.lock)

build_graph(state):
  edges = {}
  for sid, session in state.sessions:
    if session.status == "ACTIVE":
      add session node sid
  for file, lock in state.locks:
    add file node file
    edges[file].add(lock.session)        # file → session
  for file, queue in state.wait_queues:
    add file node file
    for entry in queue:
      edges[entry.session_id].add(file)  # session → file
  return edges

DFS(start):
  stack = [(start, [start])]
  visited = {start}
  while stack:
    node, path = stack.pop()
    for next_node in edges[node]:
      if next_node == start:
        return path + [next_node]       # cycle found
      if next_node not in visited:
        visited.add(next_node)
        stack.append((next_node, path + [next_node]))
  return null

cycle = DFS(S_new)
return cycle
```

**Implementation note:** Bash 3.2 cannot do real recursion
cleanly; the algorithm uses an iterative stack-based DFS.
Bash arrays + parallel-indexed dictionaries replace the
hashmap (per CLAUDE.md §A.5 — no associative arrays in
Bash 3.2). The state read happens ONCE at function entry
under `sessions.lock` (snapshot semantics); cycle detection
operates on the snapshot in-memory. Subsequent state
mutations during the walk do not invalidate the result;
the cycle either exists at snapshot time or it does not.

**Returned cycle path:** an array of alternating session/file
node identifiers, starting and ending with `S_new`. Output
format (for `coord_cycle_describe` and Mediator payload): a
JSON array.

```json
[
  {"type": "session", "id": "<sid_A>"},
  {"type": "file",    "id": "/path/foo.ts"},
  {"type": "session", "id": "<sid_B>"},
  {"type": "file",    "id": "/path/bar.ts"},
  {"type": "session", "id": "<sid_A>"}
]
```

#### 4. `coord_cycle_describe <cycle_path_json>`

Translates the cycle JSON into a human-readable string for the
Mediator's prompt context:

```
Deadlock detected:
  Session A (a1b2c3d4) holds /path/foo.ts and waits for /path/bar.ts
  Session B (e5f6g7h8) holds /path/bar.ts and waits for /path/foo.ts
  Cycle: A -> bar.ts -> B -> foo.ts -> A
```

Logic:
- Walk the cycle path; for each session node, lookup its held
  files (`locks[*].session == sid`) AND the next file in the
  path (`wait_queues[next_file]`).
- Render one line per session: "Session X (prefix...) holds
  <held_file_or_files> and waits for <next_file_in_path>".
- Final line: arrow-joined cycle path with truncated session
  IDs (8-char prefixes per existing notify_waiters convention).

#### 5. cycle_detected pending kind

When `coord_cycle_detect` returns a non-null cycle path:
1. Write a `kind=cycle_detected` entry to
   `.coord/mediator/pending.jsonl` (existing JSONL append-
   only via `lib/mediator_pending.sh`):

```json
{
  "kind": "cycle_detected",
  "ts": "<ISO8601 with ms>",
  "for_pending_entry": null,
  "payload": {
    "trigger_session_id": "<S_new>",
    "trigger_file": "<file_S_new_just_enqueued_for>",
    "cycle_path": [<bipartite path JSON>],
    "cycle_description": "<coord_cycle_describe output>",
    "queue_depth_at_detection": <int>,
    "involved_sessions": ["<sid_A>", "<sid_B>", ...],
    "involved_files": ["/path/foo.ts", "/path/bar.ts", ...]
  }
}
```

2. Spawn Mediator inline (synchronous, mirroring Phase 4
   critical_drift pattern per PR-PHASE4-02 + Concern B):
```
coord_mediator_spawn --pending-ts <pending_ts>
```
3. Mediator's prompt is pending-kind-agnostic per PR-PHASE4-03;
   it reads the payload, analyzes the cycle, and emits a
   verdict in the existing 3-action contract (advice /
   surgical_fix / lockdown). Mediator decides which session
   to evict for surgical_fix based on Decision 4's heuristics
   (session age, lock count, activity recency — encoded in
   prompt context, not deterministic code).
4. Mediator's verdict is applied via existing
   `coord_verdict_apply_actions` (which already handles
   `release_lock` / `evict_session` / `clear_read_set`).
5. Per-session `last_consumed_verdict` pointer advanced;
   Mediator-action banner composed; pre_tool_use_write.sh
   call returns.

**No new Mediator code paths.** The cycle_detected kind is
purely a payload variation; the existing Mediator+verdict-
apply pipeline handles it kind-agnostically.

#### 6. Recursion guard relationship

`coord_cycle_detect` itself is pure-Bash (no `claude -p`
spawn); it has no recursion-guard concerns. The Mediator
spawn it triggers IS subject to the existing
`CLAUDE_CODE_MEDIATOR=<depth>` recursion guard
(PR-PHASE3-01). Depth-2 ceiling unchanged.

The trigger session (S_new) does NOT itself spawn the
Mediator — `coord_wait_queue_enqueue` does, in the parent
hook context. The Mediator's spawn env propagates
`CLAUDE_CODE_MEDIATOR=1` (or 2 if escalated peer review);
Mediator's verdict apply runs back in the parent context,
not in a recursive shell.

**Latency budget:**
- `coord_cycle_detect` itself: <50 ms target, <100 ms worst
  case (100 sessions / 100 files).
- Mediator inline spawn: 20-35 s typical (subscription mode).
- Total post-enqueue worst case: ~50-100 s for deadlock
  recovery, well under Bash-tool 600 s ceiling.

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §3.5 events.jsonl kind list** —
add:
- `CYCLE_DETECTED` (payload: `trigger_session`,
  `trigger_file`, `involved_sessions[]`,
  `involved_files[]`, `queue_depth`).
- `CYCLE_DETECTION_RAN` (payload: `trigger_session`,
  `result` ∈ {`cycle_found`, `no_cycle`}, `duration_ms`).

**B. `IMPLEMENTATION_PLAN.md` §3.5 mediator pending kinds**
— extend `pending.jsonl` kind enum:
- `cycle_detected` (new) joins the existing kinds
  (`corrupt_state`, `flock_timeout`, `stale_active`,
  `pid_recycled`, `consensus_dead`, `manual`,
  `critical_drift`).

**C. `IMPLEMENTATION_PLAN.md` §4 component specs** — add:

`lib/cycle_detection.sh`:
- `coord_cycle_detect <session_id>` — bipartite DFS
  from `<session_id>` over the snapshot of sessions.json
  (read once under sessions.lock). Returns JSON cycle path
  on stdout, or empty stdout if no cycle. Logs
  `CYCLE_DETECTION_RAN` event.
- `coord_cycle_describe <cycle_json>` — translates cycle
  path to human-readable string for Mediator prompt context
  embedding. Pure-text; no I/O beyond reading sessions.json
  for held-files lookup.

`lib/wait_queue.sh` (extends PR-PHASE5-01):
- `coord_wait_queue_enqueue` post-append: when queue depth ≥ 2,
  call `coord_cycle_detect <sid>`. On non-empty result, write
  `cycle_detected` pending entry + spawn Mediator inline.

`lib/mediator_pending.sh` (extends Phase 3):
- Documentation only: kind enum extended with
  `cycle_detected`. Existing producer/consumer flow handles
  the new kind without code change.

`MEDIATOR_REFERENCE.md` §4 (extends Phase 3):
- New subsection 4.X: `cycle_detected` payload schema +
  example + recommended action mapping (advice for shallow
  cycles, surgical_fix for typical deadlock, lockdown for
  global deadlock — see PR-PHASE5-04).

**D. `IMPLEMENTATION_PLAN.md` §5 Phase 5 Scope** — add:
> "Cycle detection (`lib/cycle_detection.sh`): bipartite
> session/file DFS triggered on `coord_wait_queue_enqueue`
> post-append depth ≥ 2. Cycle path written as
> `cycle_detected` pending entry to pending.jsonl;
> synchronous Mediator inline spawn (mirroring Phase 4
> critical_drift pattern). Mediator's existing 3-action
> contract handles cycle_detected kind-agnostically (no new
> Mediator code paths)."

**E. `CLAUDE.md` §B.6 (Mediator invocation protocol)** —
non-binding update: add a one-line note that
"`cycle_detected` pending entries are automatically
generated when wait-queue cycle detection finds a deadlock;
you do not invoke Mediator yourself."

### Implementation-task dependencies

- T5.05 (cycle detection) implements §A + §C
  `cycle_detection.sh`. **Gated on this PR + PR-PHASE5-01
  approval.**
- T5.06 (Mediator integration) implements §B + §C
  `mediator_pending.sh` documentation extension + §C
  MEDIATOR_REFERENCE.md extension. **Gated on this PR +
  PR-PHASE5-04 approval (PR-PHASE5-04 documents the action-
  mapping heuristic).**
- T5.07 (Phase 5 invariant) — `lib/cycle_detection.sh` is
  bonus guard #11 (zero permissionDecision).
- T5.09 (ship-gate fixtures) — scenario
  `04_cycle_detected_mediator_evict` exercises this PR end-
  to-end.

### Ambiguity dispositions (resolved 2026-04-27 at T5.01 open)

1. **Graph topology** (pin-point a-2). **RESOLVED —
   bipartite session/file.** Direct mapping to on-disk data
   structures.
2. **Trigger threshold.** **RESOLVED — post-enqueue depth ≥
   2.** Smallest non-trivial threshold; matches 2-cycle
   deadlock minimum.
3. **Algorithm.** **RESOLVED — iterative stack-based DFS.**
   Bash 3.2 compat (no recursion); O(V+E) cost; matches
   <50 ms target.
4. **Cycle-path payload format.** **RESOLVED — bipartite
   JSON array** alternating `{type: "session"|"file", id}`.
   Round-trips cleanly through jq.
5. **Mediator escalation.** **RESOLVED — synchronous inline
   spawn** mirroring Phase 4 critical_drift pattern.
6. **Recursion guard.** **RESOLVED — existing depth-2 ceiling
   unchanged.** `coord_cycle_detect` is pure-Bash; only the
   spawned Mediator counts against the depth budget.
7. **Snapshot vs transactional consistency.** **RESOLVED —
   snapshot.** Read sessions.json once under sessions.lock;
   operate on snapshot in-memory; subsequent mutations
   during the walk do not invalidate the result.

### Cross-references

- **Decision 3** (verbatim from Phase 5 resume prompt) — this
  PR encodes the bipartite DFS, depth-2 trigger,
  cycle_detected pending kind, Mediator inline pattern.
- **Decision 4** — PR-PHASE5-04 documents Mediator's action
  mapping for cycle_detected payloads (advice / surgical_fix
  / lockdown choice). This PR provides the payload; that PR
  documents the consumer.
- **PR-PHASE5-01** — wait_queue infrastructure.
  `coord_wait_queue_enqueue` is the trigger point for
  `coord_cycle_detect`.
- **PR-PHASE4-02** + **Concern B** — synchronous Mediator
  inline pattern. cycle_detected reuses the same pathway.
- **PR-PHASE4-03** — Mediator pending-kind-agnostic prompt
  contract. cycle_detected is a new kind that fits the
  existing contract.
- **PR-PHASE3-01** — existing 3-action contract +
  CLAUDE_CODE_MEDIATOR depth-2 recursion guard.
- **PR-PHASE3-04** — pending.jsonl 24-hour GC; cycle_detected
  entries are GCed on the same schedule.
- **R17 / R18** (plan §7 risks) — task-graph cycle / wait_
  queue deadlock. This PR's cycle detection is the planned
  mitigation per the risk table.

### Non-changes (deliberate)

- Mediator code paths unchanged. `coord_mediator_spawn` does
  not branch on `kind`; the prompt assembly is kind-
  agnostic (per PR-PHASE4-03).
- `coord_verdict_apply_actions` unchanged. The 3-action
  contract handles cycle_detected verdicts naturally.
- Phase 4 invariant unchanged. `lib/cycle_detection.sh` is a
  new bonus guard (#11 in Phase 5 invariant per
  PR-PHASE5-05).
- `task_graph` cycle detection (Phase 6 task delegation)
  is OUT OF SCOPE for this PR. Phase 5's cycle detection is
  wait-queue-only. Phase 6 will add task-chain cycle
  detection in `coord task-open`.

### Acknowledgement

DRAFT. Pending user approval at T5.01 close. Pin-point (a-2)
from T5.01 startup approval is binding. Final merge into
IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-5-signoff.md.

---

## PR-PHASE5-04 — Mediator deadlock-breaking via existing 3-action contract (Decision 4; documentation-only)

**Date:** 2026-04-27
**Author:** Phase 5 builder (T5.01).
**Status:** APPROVED 2026-04-27 at T5.01 close. Gates
T5.06 documentation only (no code change).
**Driver:** User-resolved Decision 4 from Phase 5 resume
prompt ("Mediator deadlock-breaking heuristic" — existing
3-action contract sufficient; NO new action verbs; judgment
encoded in Mediator's prompt context, not deterministic code).

### Observed gap requiring change

PR-PHASE5-03 establishes the `cycle_detected` pending kind and
hands off to the existing Mediator pipeline. But the
Mediator's prompt context (per `MEDIATOR_REFERENCE.md` §4)
documents action mappings for `corrupt_state`, `flock_timeout`,
`stale_active`, `pid_recycled`, `consensus_dead`, `manual`,
and `critical_drift` (the latter from PR-PHASE4-03). It does
NOT yet document expected action mappings for
`cycle_detected`.

Without this documentation, the spawned Mediator has no
guidance on how to choose advice vs surgical_fix vs lockdown
for cycle_detected payloads. The result would be inconsistent
verdicts across cycle scenarios — sometimes advice, sometimes
lockdown, with no principled basis. The decision-matrix
encoding in the prompt context (NOT in deterministic code) is
the canonical site for this guidance.

This PR is **documentation-only**: no Mediator code change, no
new lib/ file, no test changes. It extends
`MEDIATOR_REFERENCE.md` and (informationally)
`IMPLEMENTATION_PLAN.md` §3.7 / §5.

### User-resolved decision

**Existing 3-action contract sufficient. NO new action verbs.
Judgment encoded in Mediator's prompt context.**

#### 1. Decision matrix for cycle_detected payloads

Mediator's `MEDIATOR_REFERENCE.md` §4 (extended) carries the
following decision matrix as guidance to the spawned agent.
The Mediator is free to deviate based on the specific
payload, but these are the expected default mappings:

**Action: `advice`**
Used when:
- Cycle is shallow (2 sessions, single file each) AND
- Both sessions show recent activity (`last_activity_at`
  within last 60 s) AND
- Neither session has held its lock for >5 minutes (so manual
  release is likely).

Mediator emits `action_type=advice` with
`message_to_caller` containing the cycle description and a
recommendation:
> "Cycle detected with session B (prefix...): you hold
> /path/foo.ts, B holds /path/bar.ts, you both want each
> other's lock. Recommend: release /path/foo.ts manually
> (post_tool_use_write.sh on a no-op) or coordinate with B
> via your operator. No action taken."

The trigger session continues; no eviction; the cycle persists
until manually broken.

**Action: `surgical_fix` (typical case)**
Used when:
- Cycle has ≥ 2 sessions OR
- At least one session has held its lock for >5 minutes
  (`acquired_at` older than threshold) OR
- Activity is unbalanced (some sessions idle, others active).

Mediator chooses ONE session to evict (`evict_session` action
in `actions[]`), based on (in priority order):
1. **Activity recency:** evict the session with oldest
   `last_activity_at` (most likely idle / abandoned).
2. **Lock count:** if activity is similar, evict the session
   holding the FEWEST locks (least disruption).
3. **Session age:** if both prior tied, evict the YOUNGEST
   session (preserve older accumulated work).

Mediator emits:
```json
{
  "action_type": "surgical_fix",
  "actions": [
    {"verb": "evict_session", "session_id": "<chosen_sid>"}
  ],
  "message_to_caller": "Deadlock detected. Evicting session
    B (prefix...) which has been idle for 8 minutes and holds
    1 lock. You should now be able to acquire /path/bar.ts."
}
```

The eviction path (existing
`coord_verdict_apply_actions::evict_session`) releases the
evicted session's locks, removes it from `wait_queues`,
clears its read-set, removes its read-snapshots
(`coord_read_snapshot_cleanup_session`), and removes its
wake_files (`coord_wait_queue_cleanup_session`). The cycle
breaks. Other waiters in the cycle proceed via the standard
lock-release notification path.

**Action: `lockdown`**
Used when:
- Cycle spans ALL active sessions (global deadlock) OR
- Cycle includes ≥ 4 sessions (extended deadlock; eviction
  may not break all entanglements) OR
- Two consecutive cycle_detected events in the last 60 s
  (recurrent deadlock; surgical_fix is not converging).

Mediator emits:
```json
{
  "action_type": "lockdown",
  "actions": [
    {"verb": "lockdown", "reason_source": "cycle_detected"}
  ],
  "message_to_caller": "System-wide deadlock detected (4 of
    5 active sessions in cycle). Lockdown active. Operator
    intervention required: run `coord mediate --resume` after
    investigating."
}
```

Lockdown routes through the existing
`lib/lockdown.sh::coord_lockdown_activate` → every hook reads
`.coord/mediator/lockdown.json` and emits the deny banner.
This is the **second architectural deny location** — the
Phase 3+4 invariant is preserved (cycle_detected does NOT
introduce a third deny site).

#### 2. Lowest-priority eviction heuristic encoding

Mediator's prompt context for cycle_detected includes:

```
You are deciding which session to evict to break a deadlock.
The candidates are listed below with the following metrics:

- session_id (uuid)
- last_activity_at (ISO8601)
- locks_held (count)
- session_age (seconds since registered_at)

Choose the session to evict by this priority:
1. Oldest last_activity_at (most likely idle/abandoned).
2. If activity within 60s window, fewest locks_held.
3. If both tied, youngest session_age (preserve older work).

Output your choice as actions[].session_id with verb
'evict_session'. Justify in message_to_caller.
```

This guidance is **encoded in Mediator's prompt**, not in
`coord_verdict_apply_actions` or `coord_mediator_spawn`. The
Mediator is the judgment layer; the verdict-apply layer is
mechanical.

#### 3. Mediator pending payload extension

PR-PHASE5-03 §5 specifies the cycle_detected payload schema.
This PR adds context fields that the Mediator needs for the
heuristic application:

```json
{
  "kind": "cycle_detected",
  "payload": {
    "trigger_session_id": "<S_new>",
    "trigger_file": "<file_S_new_just_enqueued_for>",
    "cycle_path": [...],
    "cycle_description": "...",
    "queue_depth_at_detection": <int>,
    "involved_sessions": ["<sid>", ...],
    "involved_files": ["/path/foo.ts", ...],

    // Heuristic context (added by this PR):
    "session_metadata": {
      "<sid>": {
        "last_activity_at": "<ISO>",
        "locks_held": <int>,
        "session_age_seconds": <int>,
        "registered_at": "<ISO>"
      }
    },
    "recent_cycle_count": <int>  // count of cycle_detected
                                  // events in last 60s; 1+
                                  // means recurring deadlock
  }
}
```

`coord_wait_queue_enqueue` populates `session_metadata` and
`recent_cycle_count` from sessions.json + events.jsonl scan
at pending-write time. The events.jsonl scan for
`recent_cycle_count` is bounded (last 60 s only) and runs
inside the same enqueue critical section.

### Plan section deltas required

**A. `MEDIATOR_REFERENCE.md` §4 (action mapping for pending
kinds)** — new subsection 4.X (after critical_drift §4.Y):

```
### 4.X cycle_detected payloads

The cycle_detected pending kind indicates that the wait-queue
cycle detector found a deadlock during a coord_wait_queue_enqueue.
Your task is to choose between advice / surgical_fix /
lockdown:

[decision matrix from §1 above, full text]

Worked example:
  Payload:
    cycle_path: A -> bar.ts -> B -> foo.ts -> A
    session_metadata:
      A: last_activity_at=2026-04-27T10:00:00Z, locks_held=1,
         session_age_seconds=300
      B: last_activity_at=2026-04-27T09:50:00Z, locks_held=1,
         session_age_seconds=600
  Reasoning: 2-cycle, B is older but less active (10 min idle
  vs A's 0 min). Evict B (oldest last_activity_at wins per
  priority 1).
  Verdict: action_type=surgical_fix, actions=[{verb:
  evict_session, session_id: B}]
```

**B. `IMPLEMENTATION_PLAN.md` §3.7 sequence diagrams** —
add cycle-detection sequence diagram showing:
1. Session C calls coord_wait_queue_enqueue (post-append
   depth=2).
2. coord_cycle_detect runs, finds cycle path.
3. cycle_detected pending entry written to pending.jsonl.
4. Mediator inline spawned (synchronous).
5. Mediator reads payload, applies decision matrix, emits
   verdict with surgical_fix evict_session action.
6. coord_verdict_apply_actions evicts the chosen session
   (release_locks, remove from wait_queues, clear read-set,
   etc.).
7. Cycle broken; remaining sessions proceed via lock-release
   notifications.

**C. `IMPLEMENTATION_PLAN.md` §5 Phase 5 Scope** — note:
> "Mediator's response to cycle_detected payloads uses the
> existing 3-action contract (advice / surgical_fix /
> lockdown). NO new action verbs. Decision heuristic
> (oldest activity > fewest locks > youngest session)
> encoded in Mediator prompt context per PR-PHASE5-04
> documentation."

**D. `CLAUDE.md` §B.6 (Mediator invocation protocol)** —
non-binding extension: add note that "cycle_detected
verdicts surface as standard Mediator action banners; the
heuristic for eviction choice is documented in
MEDIATOR_REFERENCE.md §4.X."

### Implementation-task dependencies

- T5.06 (Mediator integration) implements §A
  MEDIATOR_REFERENCE.md extension only — no Mediator code
  change. **Gated on this PR + PR-PHASE5-03 approval.**
- T5.05 (cycle detection) populates the
  `session_metadata` + `recent_cycle_count` payload fields
  added by this PR's §3. **Gated on this PR + PR-PHASE5-03
  approval.**

### Ambiguity dispositions (resolved 2026-04-27 at T5.01 open)

1. **New action verbs?** **RESOLVED — NO.** Existing
   advice / surgical_fix / lockdown contract sufficient.
2. **Eviction priority encoding (deterministic code vs
   prompt).** **RESOLVED — prompt context only.** Mediator
   is the judgment layer.
3. **Lowest-priority definition.** **RESOLVED —
   (1) oldest last_activity_at, (2) fewest locks_held,
   (3) youngest session_age.** Three-tier priority,
   tiebreakers in order.
4. **Lockdown trigger threshold.** **RESOLVED —
   global-cycle OR ≥4 sessions OR recurrent (2+ in 60s).**
   Conservative thresholds; falls into lockdown only when
   surgical_fix has clearly insufficient leverage.
5. **session_metadata fields.** **RESOLVED — last_activity_at,
   locks_held, session_age_seconds, registered_at.** Four
   fields cover the priority logic + enable the Mediator to
   reason about additional context.
6. **recent_cycle_count window.** **RESOLVED — 60 seconds.**
   Empirically aligned with typical hook-pulse cadence;
   shorter windows would miss recurrent patterns;
   longer would overcount unrelated incidents.

### Cross-references

- **Decision 4** (verbatim from Phase 5 resume prompt) — this
  PR encodes the existing-contract sufficiency.
- **PR-PHASE5-03** — cycle_detected pending kind. This PR
  documents the consumer side; that PR documents the
  producer.
- **PR-PHASE3-01** — existing 3-action contract definition
  (advice / surgical_fix / lockdown). This PR is a
  documentation extension within that contract.
- **PR-PHASE4-03** — Mediator pending-kind-agnostic prompt
  contract. cycle_detected fits the same pattern.
- **MEDIATOR_REFERENCE.md** — §4 already documents action
  mappings for prior kinds; this PR adds §4.X for
  cycle_detected.

### Non-changes (deliberate)

- `lib/mediator_spawn.sh` unchanged.
- `lib/verdict_apply.sh` unchanged.
- `lib/mediator_pending.sh` unchanged.
- `coord_verdict_apply_actions` unchanged.
- No new lib/ file added.
- No code-level test changes; the action mapping is
  documentation, not deterministic code. Phase 7 stress
  test will verify Mediator's compliance with the heuristic
  on real `claude -p` runs.

### Acknowledgement

DRAFT. Pending user approval at T5.01 close. Documentation-
only; no code changes proposed. Final merge into
IMPLEMENTATION_PLAN.md + MEDIATOR_REFERENCE.md folds into
phase-5-signoff.md.

---

## PR-PHASE5-05 — Phase 5 architectural invariant preservation (Decision 5)

**Date:** 2026-04-27
**Author:** Phase 5 builder (T5.01).
**Status:** APPROVED 2026-04-27 at T5.01 close. Gates
T5.07 (Phase 5 invariant test).
**Driver:** User-resolved Decision 5 from Phase 5 resume
prompt ("Phase 5 architectural invariant" — preserves 2-
location deny invariant; cycle_detection routes through
Mediator → lockdown gate; 8 architectural + 3 bonus = 11
guards; phase4_invariant.bats deleted).

### Observed gap requiring change

The Phase 4 sign-off STATE_OF_SYSTEM noted that Phase 5
might introduce a third architectural deny location for
wait-queue management or cycle-detection escalation. After
deeper consideration during Phase 5 resume-prompt drafting,
the user determined that:
1. Wait queue management has no deny use case (queue
   operations are advisory; lock acquisition denial happens
   at the existing pre_tool_use_write.sh location).
2. Cycle detection escalates via Mediator → which routes
   through the existing lockdown.json gate when scope is
   global. No new deny site needed.

The 2-location deny invariant from Phase 3 (preserved
through Phase 4) is preserved through Phase 5 unchanged.

This PR formally documents the invariant preservation,
extends the bats invariant test, and deletes the superseded
Phase 4 invariant test.

### User-resolved decision

**Phase 5 invariant: 8 architectural guards + 3 bonus = 11
guards in `phase5_invariant.bats`.**

#### 1. Two architectural deny locations (UNCHANGED from Phase 3+4)

1. **`pre_tool_use_write.sh` lock-held-by-other branch**
   (existing Phase 2). Emits `permissionDecision: "deny"`
   when the target file is locked by another session.
2. **`lib/lockdown.sh` `coord_lockdown_emit_deny`**
   (existing Phase 3). Invoked by every hook when
   `coord_lockdown_check` returns 0 (lockdown active).

These two are the ONLY architectural deny sites. Cycle
detection routes through site #2 when Mediator chooses
lockdown for global deadlock (per PR-PHASE5-04 §1).
Wait-queue management uses neither.

#### 2. Six Phase 3 carry-forward architectural guards (UNCHANGED)

Per `phase4_invariant.bats` (and originally Phase 3):

1. `pre_tool_use_write.sh` contains EXACTLY ONE
   `permissionDecision: "deny"` emit (the lock-held-by-other
   branch).
2. `lib/lockdown.sh` contains EXACTLY ONE
   `permissionDecision: "deny"` emit
   (`coord_lockdown_emit_deny`).
3. No other hook script in `src/hooks/` emits
   `permissionDecision: "deny"` directly.
4. No other lib/ script in `src/lib/` emits
   `permissionDecision: "deny"` directly.
5. Every hook in `src/hooks/` sources `lib/lockdown.sh` and
   calls `coord_lockdown_check` + `coord_lockdown_emit_deny`
   in its top-level flow.
6. Every hook fail-open exits 0 in non-deny code paths.

#### 3. Two Phase 4 carry-forward guards (UNCHANGED)

7. `lib/validator_spawn.sh` contains zero
   `permissionDecision` strings (the Validator classifies
   but does not deny).
8. `lib/validator_prefilter.sh` contains zero
   `permissionDecision` strings (the deterministic pre-
   filter never denies).

#### 4. One Phase 4 carry-forward bonus guard (UNCHANGED)

9. `lib/validator_cache.sh` contains zero
   `permissionDecision` strings (the cache is a validator
   component and must not deny).

#### 5. Two NEW Phase 5 bonus guards

10. `lib/wait_queue.sh` contains zero `permissionDecision`
    strings (queue operations are advisory; deny happens at
    the existing lock-acquire path).
11. `lib/cycle_detection.sh` contains zero
    `permissionDecision` strings (cycle detection routes
    through Mediator pending pipeline; lockdown is the deny
    mechanism if scope is global).

**Total: 8 architectural + 3 bonus = 11 guards in
`phase5_invariant.bats`.**

#### 6. phase4_invariant.bats deletion

`src/tests/unit/phase4_invariant.bats` is **deleted** in T5.07
(superseded by `phase5_invariant.bats`, which carries forward
all Phase 4 guards verbatim plus the 2 new Phase 5 bonus
guards). Mirrors the Phase 3 → Phase 4 transition (per T4.06
where `phase3_invariant.bats` was deleted upon
`phase4_invariant.bats` landing).

### Plan section deltas required

**A. `IMPLEMENTATION_PLAN.md` §5 Phase 5 Scope** — add:
> "Phase 5 invariant: 8 architectural deny guards + 3 bonus
> guards = 11 total in `phase5_invariant.bats`. The 2-
> location deny invariant (lock-held-by-other +
> lockdown.json gate) is preserved unchanged from Phase 3+4.
> `phase4_invariant.bats` deleted (superseded)."

**B. `IMPLEMENTATION_PLAN.md` §5 Phase 5 Done-when criteria**
— add:
- [ ] `phase5_invariant.bats` 11/11 PASS (8 architectural +
      3 bonus).
- [ ] `phase4_invariant.bats` deleted from
      `src/tests/unit/`.

**C. `CLAUDE.md` §C.4a (Phase 4 architectural invariant
carry-forward section)** — extend / rename to "Phase 5
architectural invariant (carry-forward from Phase 3+4)".
Replace the 8-guard + 1-bonus enumeration with the 11-guard
list. Update the future-phase enumeration requirement to
include `lib/wait_queue.sh` + `lib/cycle_detection.sh`.

### Implementation-task dependencies

- T5.07 (Phase 5 invariant test) implements §A + §B.
  **Gated on T5.02 close (so wait_queue.sh exists for
  guard #10) + T5.05 close (so cycle_detection.sh exists
  for guard #11).**
- T5.07 also DELETES `phase4_invariant.bats` per §C.6.
- T5.10 (Linux re-probe) verifies all 11 guards PASS on
  Linux Docker.

### Ambiguity dispositions (resolved 2026-04-27 at T5.01 open)

1. **Cycle detection adds a deny site?** **RESOLVED — NO.**
   Routes through existing lockdown gate.
2. **Wait queue adds a deny site?** **RESOLVED — NO.**
   Queue operations are advisory; lock-acquire denial is at
   the existing site.
3. **Bonus vs architectural classification of new guards.**
   **RESOLVED — both bonus.** Guards #10 and #11 are not
   on the deny path itself; they are zero-deny content
   audits of new lib/ files. Classified as bonus per
   precedent (Phase 4's `validator_cache.sh` is also bonus).
4. **phase4_invariant.bats fate.** **RESOLVED — DELETE.**
   Superseded by phase5_invariant.bats which carries
   forward all 9 prior guards verbatim. Mirrors Phase 3 →
   Phase 4 transition.
5. **Future-phase guard enumeration.** **RESOLVED — Phase 6
   onward must add new lib/ files to the invariant
   enumeration.** Documented in CLAUDE.md §C.4a.

### Cross-references

- **Decision 5** (verbatim from Phase 5 resume prompt) — this
  PR encodes the invariant preservation.
- **PR-PHASE3-01** — Mediator design contract; established
  the deny-via-lockdown pathway.
- **PR-PHASE4-02** — Phase 4 invariant 2-location preservation
  (Concern B disposition). This PR extends the same
  invariant through Phase 5.
- **CLAUDE.md §C.4a** — currently documents Phase 4
  invariant; extended by this PR to Phase 5.

### Non-changes (deliberate)

- `pre_tool_use_write.sh` deny site unchanged.
- `lib/lockdown.sh` `coord_lockdown_emit_deny` unchanged.
- No new architectural deny location added.
- No new hook scripts (`src/hooks/`) added in Phase 5;
  hook modifications are extensions to existing hooks
  (`pre_tool_use_write.sh`, `post_tool_use_write.sh`) which
  remain bound by the existing guard.
- `verdict_apply.sh` unchanged in Phase 5; its
  `evict_session` action handles the wait-queue cleanup
  (`coord_wait_queue_cleanup_session`) and snapshot cleanup
  (already wired in Phase 4) but emits no
  permissionDecision.

### Acknowledgement

DRAFT. Pending user approval at T5.01 close. Final merge into
IMPLEMENTATION_PLAN.md / CLAUDE.md folds into
phase-5-signoff.md.

---

*Future entries append below.*



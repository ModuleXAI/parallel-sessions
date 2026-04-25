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

*Future entries append below.*

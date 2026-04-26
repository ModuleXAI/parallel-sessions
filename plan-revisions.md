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

*Future entries append below.*



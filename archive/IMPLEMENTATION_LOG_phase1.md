## Phase 1 — Stale-read warning only (never worse than no coord)
Started: 2026-04-24T18:12:31Z
Closed:  2026-04-25T19:42:06Z
Status:  COMPLETE (user approved phase-1-signoff.md; branch
         `phase-1/stale-read-warnings` merged to main as commit
         629b1fb "Phase 1: Stale-read warnings (T1.00-T1.13)"
         on 2026-04-25T19:42:06Z UTC).

Phase goal (plan §5): ship the stale-read detector. Two real Claude sessions
with one modifying a file the other read produces a visible warning in the
second session's context. No write blocking yet. Phase 1 is **never worse**
than no coordination: no code path may block a tool call.

In-scope components (plan §5):
- `hooks/pre_tool_use_read.sh`   — record Read → read_set with sha256.
- `hooks/pre_tool_use_write.sh`  — validate read_set; on mismatch emit
                                    `additionalContext` warning (**no deny**).
- `hooks/pre_tool_use_any.sh`    — minimal notification delivery.
- `hooks/user_prompt_submit.sh`  — capture prompt + HEAD; invalidate prior
                                    read-set on new prompt / HEAD change.
- Corruption recovery (detect + reset + log) — already partly in
  `lib/atomic_write.sh`; verify end-to-end in Phase 1 hooks.
- `coord status` extended to show per-session read-sets.

Out-of-scope (plan §5): locks / write-write prevention, validation subagent
(text warnings only), watchdog, tasks, wait queue, Mediator (stub only for
corruption recovery).

Applicable OPEN findings at phase start: **F-004** (SessionStart `source`
registration semantics) — deferred to Phase 1 from Phase 0 signoff.

### Tasks
- [x] T1.00  Open Phase 1 section + cut `phase-1/stale-read-warnings` branch + log F-010 (Phase 0 branch policy WONTFIX) (2026-04-24T18:12:31Z)
             Result: Phase 1 section opened IN_PROGRESS with ship-gate checklist
             from §5. Branch `phase-1/stale-read-warnings` cut from main's HEAD
             (a6af808 + staged Phase 0 artefacts travel with the branch;
             Phase 0 finalization commit deferred to user authorization).
             F-010 logged as WONTFIX per user direction.
- [x] T1.01  Resolve F-004 via PR-PHASE1-01 (augment Decision 2.5 with SessionStart `source` behavior matrix) (2026-04-24T18:13Z → 2026-04-24T18:14Z)
             Result: PR-PHASE1-01 drafted + APPROVED-in-line in
             plan-revisions.md. IMPLEMENTATION_PLAN.md Decision 2.5
             rewritten with 4-row source matrix; §3.5 event-kind list
             extended (SESSION_RESUME, SESSION_CLEAR, SESSION_COMPACTED,
             RESUME_ORPHAN_LOCK_DETECTED). User clarifications (a) orphan-lock
             flag → Phase 3 eviction, and (b) HEAD-change propagation on
             resume folded in verbatim (Phase-2→Phase-3 phasing correction
             noted transparently). FINDINGS F-004 → RESOLVED. Code impact
             lands in later Phase 1 tasks: session_start.sh source-branching
             in T1.04 (session hooks refactor + source matrix implementation).
- [x] T1.02  Author `lib/subagent_filter.sh` shared helper + bats suite (2026-04-24T18:14Z → 2026-04-24T18:27Z)
             Result: helper implemented as sourceable function
             `coord_subagent_filter <hook_event_name> <stdin_json>` returning
             0 for subagent (caller should exit 0) / 1 for primary session.
             Best-effort SUBAGENT_ACTIVITY_SKIPPED event emitted when
             COORD_DIR is set and coord_log_event is sourced; otherwise
             silently skips logging (detection still correct). Extracts
             tool and file_path (supports both `tool_input.file_path` and
             `tool_input.notebook_path`) for observability payload.
             Bash 3.2 compat; no `set -euo pipefail` (caller governs); no
             `exit` (return-only); CLI shim provided for ad-hoc probes.
             bats: 12/12 passing; covers empty/absent/populated agent_type,
             NotebookEdit path, missing COORD_DIR, missing log_event.
- [x] T1.04  Decision 2.5 source-matrix implementation + user_prompt_submit.sh + lib/head_tracking.sh + CLAUDE.md §B.9.7 resume-trust rule + bats (2026-04-24T18:38Z → 2026-04-24T18:55Z)
             Result: session_start.sh now dispatches on source ∈ {startup,
             resume, clear, compact} with per-source jq filters; HEAD-drift
             compare-and-mark is composed INTO the resume atomic_edit for
             single-pass atomicity. Orphan-lock flagging emits
             RESUME_ORPHAN_LOCK_DETECTED events per lock (no eviction —
             deferred to Phase 3 watchdog). resume_without_prior_row
             fallback emits SESSION_REGISTER with reason payload.
             user_prompt_submit.sh authored: hashes prompt → prompt_id via
             shasum; HEAD-drift detected via coord_head_drifted; marks
             read-set with superseded_by:"new_prompt" plus
             superseded_by_head_change on drift; emits additionalContext
             per §B.9.6 on drift; caches COORD_PROMPT_ID to
             .coord/sessions/<id>.env. lib/head_tracking.sh provides
             coord_current_head / coord_stored_head / coord_head_drifted
             as thin read-only helpers (the mutation is intentionally
             NOT extracted — callers compose it into their atomic_edit
             filters). CLAUDE.md §B.9.7 added with [HOOK-ENFORCED]
             preservation/invalidation + [BEST-EFFORT] "do not re-read
             prophylactically" tag; §B.11 quick-reference table row
             appended. bats: 83/83 (6 new session_start matrix, 11 new
             head_tracking, 9 new user_prompt_submit, 57 pre-existing
             green).
- [x] T1.05  Implement `hooks/pre_tool_use_read.sh` + bats (2026-04-24T18:55Z → 2026-04-24T19:05Z)
             Result: hook sources atomic_write, log_event, subagent_filter,
             participant, hash libs; records (path, hash, at, is_latest)
             entries; supersedes prior is_latest entries for the same
             path with {is_latest:false, superseded_by:<new_hash>}; consumes
             any pending notifications[sid][path] into additionalContext
             (read-before-write captured outside the atomic_edit so the
             emitted text matches the cleared state). Fail-open on every
             path: missing file logs ERROR but allows the Read; >10MB
             records SKIPPED_LARGE; atomic_edit failure logs + exits 0.
             Phase 1 NEVER emits permissionDecision on Read. bats: 10/10
             (unset env, subagent skip, non-participant no-op, first read,
             supersede-on-second-read, two distinct files both is_latest,
             missing-file log-ERROR-and-allow, SKIPPED_LARGE, notification
             deliver+clear, READ event fields).
- [x] T1.07  Implement `hooks/pre_tool_use_any.sh` (minimal: cross-cutting notification delivery + HEAD-change recheck per §B.9.6) + bats (2026-04-25T00:01Z → 2026-04-25T00:11Z)
             Result: hook scans notifications[$sid][*] for pending entries
             across all files, captures the text BEFORE the atomic clear
             (so emitted banner matches post-clear state), then composes a
             single atomic_edit that (a) zeroes every file's notifications
             array AND (b) on HEAD drift marks every read_set entry with
             superseded_by_head_change + updates sessions[$sid].git_head.
             Combined banner segments notifications + HEAD-change in one
             additionalContext when both apply. PHASE-3 / PHASE-6 upgrade
             points (Mediator pending banner; self-task reminders) marked
             with plan-pointer comment blocks. bats: 8/8 covering
             unset-env, subagent, non-participant, quiet pass, multi-file
             notification delivery + clear, HEAD-drift mark + banner +
             event, combined banner, ship-gate-no-permissionDecision.
- [x] T1.08  Corruption-recovery end-to-end verify + corruption banner emission (CLAUDE.md §B.9.2 step 4) + bats (2026-04-25T00:11Z → 2026-04-25T00:23Z)
             Result: §B.9.2 step 4 (banner emission) was the only piece
             missing — atomic_write.sh already handled archive + reset +
             Mediator flag write. Added `coord_consume_corrupt_state_flag`
             helper to lib/atomic_write.sh: prints the banner text on
             stdout if `.coord/mediator/pending.json` has kind:"corrupt_state",
             then renames the flag to pending.delivered.<ts>.json so the
             same banner cannot fire twice. Wired the consumer into
             session_start.sh (composes into the existing "Coord v1.0
             active" banner) and pre_tool_use_any.sh (composes alongside
             notifications + HEAD-change segments). bats: 7/7 covering
             SessionStart-against-corrupt-state full chain, banner
             surfacing via pre_tool_use_any when flag is present,
             non-repetition on second firing, end-to-end (SessionStart
             reset → next pre_tool_use_any does not re-emit), fail-open
             exit-0 invariant, helper-with-no-flag returns 1 silently,
             helper ignores non-corrupt kinds (Phase 3 Mediator owns
             those). Full suite: 119/119.
- [x] T1.09  Extend `coord status` to show per-session read-sets (2026-04-25T00:23Z → 2026-04-25T00:32Z)
             Result: cmd_status now emits a per-session read_sets summary
             line with total / is_latest / head_invalidated /
             prompt_invalidated counts; `coord status --reads` adds a
             detail block listing the most recent 20 reads per session
             with flags (HEAD!, NEW_PROMPT!) for at-a-glance triage.
             Empty read_sets renders as "(none)". Usage line in --help
             updated. bats: 5/5 (sessions section, summary counts,
             empty-state line, --reads detail with flag markers,
             unknown-flag rejection).
- [x] T1.10  Installer wiring: register 4 new Phase-1 hooks in `.claude/settings.local.json` + ensure `--repair` updates existing installs (2026-04-25T00:32Z → 2026-04-25T00:48Z)
             Result: install.sh `register_hooks` rewritten to use a single
             jq pipeline that (a) strips ANY prior coord-owned hook entries
             (commands containing `/.coord/hooks/`) across ALL events
             before (b) appending the current Phase-1 set: SessionStart,
             SessionEnd, UserPromptSubmit (matcher *), and PreToolUse
             with three matchers — `*` (pre_tool_use_any.sh),
             `Read` (pre_tool_use_read.sh), and
             `Write|Edit|NotebookEdit` (pre_tool_use_write.sh). User-
             authored hooks for ANY event are preserved alongside ours.
             install.sh now refuses to overwrite an invalid-JSON
             settings.local.json (fail-loud rather than silent clobber).
             The same generic strip is mirrored in install.sh
             --uninstall and src/bin/coord cmd_uninstall so a single
             rule governs cleanup across all events. bats: 7/7 covering
             clean install, matcher correctness, idempotent --repair,
             user-entry preservation, --uninstall full strip, on-disk
             hook+lib presence + executable bit, invalid-JSON refusal.
             Full suite: 131/131.
- [x] T1.11  Two-session stale-read smoke (ship-gate done-when #1) as Phase-7-extensible fixture (2026-04-25T00:55Z → 2026-04-25T01:11Z)
             Result: built fixture seed at
             src/tests/fixtures/two_session_warn/ (README + init.sh +
             scenarios/01_basic_warn/{description.md, timeline.sh}) and
             driver at src/tests/manual/two_session_warn.sh. Driver
             discovers scenarios in lex order, fresh isolated workspace
             per scenario via init.sh (mktemp + git init + install.sh
             --yes --repair + seed foo.ts/bar.ts), supports
             --mode={hook-sim|real} (real exits 77 SKIP per Phase 1
             scope; Phase 7 fills in), --scenario=<name> filter, --keep
             for diagnostic. PASS on hook-sim mode for 01_basic_warn:
             6 assertions verified — exit-0, foo.ts cited, "stale-read
             warning" cited, NO permissionDecision (ship-gate),
             STALE_READ_WARNED event for SID_A in events.jsonl, B's
             write produced no spurious warning. Exit codes: 0 PASS,
             1 FAIL with diagnostics, 2 driver/usage error, 77 skip
             (real-mode without API key). Phase 7 extends by dropping
             new directories under scenarios/.
- [x] T1.12  Linux parity smoke via Phase 0 Docker harness extension (2026-04-25T01:11Z → 2026-04-25T01:18Z)
             Result: extended `.coord/experiments/linux-parity/linux_probe.sh`
             with a single line invoking the new
             src/tests/manual/two_session_warn.sh driver. The pre-existing
             `bats /work/src/tests/unit` step automatically picked up
             every Phase-1 test file (subagent_filter, head_tracking,
             user_prompt_submit, pre_tool_use_read, pre_tool_use_write,
             pre_tool_use_any, corruption_recovery, install_register,
             coord_status). Run output shows: install.sh --yes clean;
             coord health post-install OK; concurrent_smoke clean;
             bats 131/131 (no skips on Linux this round); two_session_warn
             PASS on hook-sim mode; LINUX_PARITY_COMPLETE marker emitted.
             Phase-1 cross-platform parity confirmed.
- [x] T1.06  Implement `hooks/pre_tool_use_write.sh` (warning-only, no deny, no validator flag) + bats (2026-04-24T19:05Z → 2026-04-24T19:16Z)
             Result: Phase-1 warning-only hook walks
             read_sets[$sid].reads[] for entries with is_latest:true AND
             superseded_by_head_change:!true; recomputes sha256 per entry
             and compares to stored hash; treats SKIPPED_LARGE as always
             stale (conservative per plan §4); treats file-deleted-since-read
             as stale. On any drift, emits `additionalContext` listing the
             stale files + STALE_READ_WARNED event. Every code path is
             allow (no permissionDecision anywhere — Phase 2/4 upgrade
             sites marked with explicit comment headers for when those
             phases land). Handles Write / Edit (file_path) and
             NotebookEdit (notebook_path). WRITE event always logged
             regardless of outcome so downstream observability has the
             full tool-invocation record.
             bats: 11/11 including a dedicated "ship gate: NO code path
             ever sets permissionDecision" invariant test. Full suite:
             104/104.
- [x] T1.13a Linux re-probe per user signoff condition + signoff update (2026-04-25T01:55Z → 2026-04-25T02:05Z)
             Result: ran `.coord/experiments/linux-parity/run.sh`
             end-to-end on `ubuntu:24.04`. Output:
             - `install.sh --yes` clean
             - `coord health` (pre + post): exit 0
             - `concurrent_smoke`: clean
             - `bats /work/src/tests/unit`: 137/137 (no skips), the
               6 new coord_health tests passing as `ok 9` through
               `ok 14` in run.log
             - `two_session_warn.sh`: 1/1 PASS on hook-sim
             - `LINUX_PARITY_COMPLETE` marker emitted
             Updated phase-1-signoff.md: bats Linux row now reads
             "137/137" with cross-reference to run.log lines
             102-107 + 231; Open Question 4 (Linux re-probe) closed
             with parenthetical note inline; "Recommended next step"
             item 3 collapsed to T2.00 (item 4 was Linux probe →
             now closed). Phase 1 ship gate fully closed.
- [x] T1.13  Draft `phase-1-signoff.md` per CLAUDE.md §A.9 (2026-04-25T01:40Z → 2026-04-25T01:55Z)
             Result: signoff written. Sections: done-when (5/5
             checked with evidence), implemented-but-dormant scan
             (10 entries spanning pre_tool_use_read/any/write,
             session_start, atomic_write, state_query, CLI stubs,
             two_session_warn real-mode, corrupt-state consumer),
             risks realized (none materially), new risks (none
             warranting §7 row), plan revisions (PR-PHASE1-01 only),
             FINDINGS rollup (F-004/F-010/F-011/F-012), open questions
             for Phase 2 (4 items including Linux re-probe of new
             coord_health.bats), artifact index, recommended next
             step. Ship-gate criteria 1-5 all carry explicit evidence
             pointers to specific bats tests + commit SHAs +
             experiment harness paths. Awaits user review per
             phase-3-implementation-prompt.md "Do NOT start the next
             phase in the same session without explicit user
             approval."
- [x] T1.12a Cleanup pass — F-003 audit + coord health extension + stray `/9` deletion + F-011/F-012 finding entries (2026-04-25T01:30Z → 2026-04-25T01:40Z)
             Result: audited every flock invocation across src/ +
             install.sh (5 production sites: install.sh:151,
             atomic_write.sh:63 + 124, log_event.sh:104,
             atomic_write.bats:76); all use the F-003 subshell + 9>"<lock>"
             form. No code-path origin found for the 0-byte `/9` file —
             one-off shell typo from early Phase 0 dev. Deleted +
             unstaged the file. Extended cmd_health in src/bin/coord
             with a stray-digit-named-root-file scan emitting BAD with
             F-012 cross-reference and rc=1. Added
             src/tests/unit/coord_health.bats (6 tests covering clean
             repo, single-digit, multi-digit, alphanumeric exclusion,
             subdir exclusion, deletion-clears-warning). Full bats
             suite: 137/137 (was 131; +6). FINDINGS.md gains F-011
             (prior session checkpoint-skip, WONTFIX) and F-012 (stray
             `/9` w/ retroactive F-003 citation, RESOLVED). Awaits
             user review before commit.
- [x] T1.03  Refactor `hooks/session_start.sh` + `hooks/session_end.sh` to use the shared filter; regression tests (2026-04-24T18:27Z → 2026-04-24T18:34Z)
             Result: both hooks now source `lib/subagent_filter.sh` and
             call `coord_subagent_filter "<event>" "$INPUT"` in place of the
             previously inlined ~18-line agent_type / SUBAGENT_ACTIVITY_SKIPPED
             blocks. COORD_DIR is pre-resolved before the filter call so
             the helper's best-effort logging can reach events.jsonl.
             Full bats suite: 57/57 green (45 pre-existing + 12 new). The
             6 session_start and 5 session_end tests — including the
             subagent-skip SUBAGENT_ACTIVITY_SKIPPED event assertions —
             all pass unchanged post-refactor; no behavior regression.
             Three hooks now share the single subagent filter pattern:
             session_start, session_end, subagent_filter.sh shim; the
             four Phase 1 PreToolUse/UserPromptSubmit hooks will follow
             the same pattern when they land (T1.04–T1.07).

### Phase 1 Ship Gate Checklist (from plan §5)
- [x] Two-session scenario: Session B modifies foo.ts; Session A's next
      Write (on any file) sees a warning in `additionalContext` citing foo.ts.
      Evidence: `src/tests/manual/two_session_warn.sh` scenario
      `01_basic_warn` PASS on macOS + Linux (six assertions per
      phase-1-signoff.md §Done-when criteria).
- [x] No false negative in the direct scenario.
      Evidence: `pre_tool_use_write` bats — stale-read mismatch / SKIPPED_LARGE
      / missing-since-read all emit STALE_READ_WARNED.
- [x] Phase 1 is **never worse** than no coordination: the hook cannot block
      a tool call in any code path (assert every hook exit path is allow /
      no-op / fail-open).
      Evidence: dedicated invariant test
      `pre_tool_use_write: ship gate — NO code path ever sets permissionDecision`
      + `grep -rn permissionDecision src/hooks/` returns zero matches.
- [x] bats suite green on macOS + Linux for all new/changed components.
      Evidence: 137/137 macOS host; 137/137 Linux Docker `ubuntu:24.04`
      via `.coord/experiments/linux-parity/run.sh` (T1.13a re-probe).
- [x] Every Phase-1-raised FINDINGS entry has a disposition (F-004 resolved
      or explicitly DEFERRED with reason).
      Evidence: F-004 RESOLVED via PR-PHASE1-01; F-010, F-011 WONTFIX;
      F-012 RESOLVED.

### Notes
- Phase 0 signoff question #1 (F-004 source-field semantics) and question
  #2 (shared subagent-filter helper authored early) drive the first two
  Phase 1 tasks.
- Phase 0 signoff question #3 (IDLE_CLOSED accumulation) is acknowledged
  non-blocking; Phase 3 watchdog owns it.


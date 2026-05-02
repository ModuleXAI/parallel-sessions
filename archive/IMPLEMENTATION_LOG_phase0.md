## Phase 0 — Ground truth and scaffolding
Started: 2026-04-24T16:18:02Z
Closed:  2026-04-24T18:12:31Z
Status:  COMPLETE (user approved Phase 0 signoff and granted explicit approval to
         begin Phase 1; see `phase-0-signoff.md`).

### Tasks
- [x] T0.00  Create IMPLEMENTATION_LOG.md                        (2026-04-24T16:18:02Z)
             Result: file created per CLAUDE.md §A.11 template.
- [x] T0.00b Create FINDINGS.md                                  (2026-04-24T16:18:02Z)
             Result: file created per CLAUDE.md §A.12 template; seeded F-001
             (flock missing) OPEN and F-002 (archive/ relocated) RESOLVED.
- [x] T0.01  Seed .gitignore + .coord/ workspace                 (2026-04-24T16:19:00Z)
             Result: `.gitignore` created at repo root covering .coord/,
             .claude/settings.local.json, IMPLEMENTATION_LOG.md, FINDINGS.md,
             phase-*-signoff.md, phase0-verification.md, and OS cruft per
             Decision 2.21 / PR-REV-01 change #1. `.coord/` directory created
             empty (installer will populate in T0.20).
- [x] T0.02  Surface flock availability to user (blocker check)  (2026-04-24T16:22Z)
             Result: user installed `flock 0.4.0` (discoteq) via Homebrew.
             Semantics spot-checked (mutex, nonblock, timeout, fd-close
             auto-release). F-001 → RESOLVED; F-003 (no `--` separator in
             discoteq flock) raised + RESOLVED with subshell+fd convention.
- [x] T0.03  Run Phase 0 verification Experiment #1 — two-terminal session IDs (2026-04-24T16:32Z)
             Result: PASS. Two sessions → two distinct UUIDs. SessionStart stdin
             includes session_id / transcript_path / cwd / hook_event_name /
             source. No pid in stdin (hook uses $PPID). Findings raised: F-004
             (source field registration semantics, OPEN), F-005 ($PPID convention,
             RESOLVED).
- [x] T0.04  Run Phase 0 verification Experiment #2 — write-race ordering  (2026-04-24T16:33Z)
             Result: PASS. Concurrent writes → independent hooks, no
             Claude-Code-level serialization across sessions. LLM-latency
             typically > hook-latency so overlap is rare but the lock layer
             is required for correctness. Pre→Post hook gap for trivial
             Write: 50–300 ms. Justifies Decision 2.3 flock-based locking.
- [x] T0.05  Run Phase 0 verification Experiment #3 — `permissionDecision: deny` reaches Claude (2026-04-24T16:36Z)
             Result: PASS. Reason text reaches Claude verbatim; tool blocked.
             Aside: Write/Edit have a Claude-Code precondition (must Read
             first) that fires before our hook — test fixtures need priming.
- [x] T0.06  Run Phase 0 verification Experiment #4 — `updatedInput` semantics (2026-04-24T16:36Z)
             Result: PASS. Mutation to tool_input.command is applied; Claude
             sees the mutated output. Not used in v1 plan but confirmed as
             available primitive.
- [x] T0.07  Run Phase 0 verification Experiment #5 — subagent `agent_type` firing (2026-04-24T16:37Z)
             Result: PASS on data, plan ASSUMPTION INVALIDATED. Subagents
             share parent's session_id; SessionStart does not fire for them.
             `agent_type` appears on PreToolUse/PostToolUse/SubagentStop in
             subagent context. F-006 OPEN → plan-revisions entry needed to
             correct Decision 2.17 subagent-filter location. F-007 RESOLVED
             (full stdin field catalogue captured).
- [x] T0.08  Run Phase 0 verification Experiment #6 — SIGKILL vs SessionEnd  (2026-04-24T16:40Z)
             Result: PASS. Graceful exit fires SessionStart→Stop→SessionEnd
             (reason=other). SIGKILL fires SessionStart only — no Stop, no
             SessionEnd. Confirms Decision 2.19 (peer watchdog necessity).
             Stop carries `stop_hook_active` enabling block-once-then-allow.
- [x] T0.09  Run Phase 0 verification Experiment #7 — hook latency baseline  (2026-04-24T16:45Z)
             Result: PASS. Realistic flock+jq RMW hook: N=300 avg=60ms,
             p50=45ms, p95=131ms, p99=435ms, max=633ms. Plan's p99<2s budget
             met with ~4× headroom. Bench script at
             `.coord/experiments/harness/bench_latency.sh`.
- [x] T0.10  Run Phase 0 verification Experiment #8 — `flock` on representative filesystems (2026-04-24T16:48Z)
             Result: PASS on APFS. 5 concurrent writers strictly interleaved;
             invariant OK; all 5 edits survived. Local mounts on this machine
             are all apfs/devfs/autofs. Installer refusal list (nfs, fuse,
             smbfs, cifs, etc.) still to be exercised in T0.20 smoke test.
- [x] T0.11  Run Phase 0 verification Experiment #9 — Bash tool timeout  (2026-04-24T16:49Z)
             Result: PASS on data. Claude Code Bash-tool default=120s,
             max=600s (10 min). Plan's `wait_max_seconds: 1800` EXCEEDS
             this ceiling. F-008 OPEN → plan-revisions entry required.
- [x] T0.12  Implement `lib/hash.sh` + bats tests                      (2026-04-24T16:54Z)
             Result: portable shasum wrapper with 10MB size guard and
             override. Smoke-tested for same-content equality, missing-file
             exit 1, SKIPPED_LARGE on oversized files. bats suite written
             (pending bats-core install).
- [x] T0.13  Implement `lib/log_event.sh` + bats tests                 (2026-04-24T16:57Z)
             Result: non-blocking events.jsonl appender with flock on
             events.lock, perl-based ms timestamp (F-009 RESOLVED). 5
             concurrent writers produce valid JSONL. bats suite written.
- [x] T0.14  Implement `lib/atomic_write.sh` + bats tests              (2026-04-24T17:00Z)
             Result: flock-guarded read-modify-write via temp+rename; exit
             codes 42 (timeout), 43 (jq err), 44 (write err). Corrupt state
             → archive + reset + Mediator flag. 10 concurrent edits all
             persist without lost writes. bats suite written.
- [x] T0.15  Implement `lib/participant.sh` + bats tests               (2026-04-24T17:01Z)
             Result: O(1) .active marker check. bats suite written.
- [x] T0.16  Implement `lib/state_query.sh` + bats tests               (2026-04-24T17:01Z)
             Result: lock-holder / is-locked / notifications-for /
             active-sessions / locks / self-tasks-for — all read-only, no
             flock. bats suite written.
- [x] T0.17  Implement `hooks/session_start.sh` + bats tests           (2026-04-24T17:02Z)
             Result: SessionStart handler registers session row with
             pid/pid_lstart/git_head, creates .active marker, emits banner
             via additionalContext, logs SESSION_REGISTER. Filters subagents
             per F-006 (defensive). Smoke tests: non-participant/participant/
             subagent all behave correctly. bats suite written.
- [x] T0.18  Implement `hooks/session_end.sh` + bats tests             (2026-04-24T17:03Z)
             Result: IDLE_CLOSED transition, release of this-session locks,
             .active marker cleanup, SESSION_END event with reason. Smoke
             tested. bats suite written.
- [x] T0.20  Implement `install.sh` (deps check, fs refusal, init, hook registration, smoke test)  (2026-04-24T17:07Z)
             Result: Runs end-to-end: deps OK, APFS detected, `.coord/`
             materialized, hooks copied from `src/`, settings.local.json
             merged (preserves user entries), `.gitignore` updated,
             session_start→session_end smoke test passes. --repair and
             --uninstall modes implemented. Discovered + fixed: macOS BSD
             awk lacks 3-arg `match()`; no-commits repo makes `git rev-parse
             HEAD` print "HEAD" literally — guarded with `--verify`.
- [x] T0.21  Implement `.coord/bin/coord` CLI entry                   (2026-04-24T17:08Z)
             Result: Phase 0 slice covers status, health, log, events,
             reset, install, uninstall, help. Stubs Phase 1+ subcommands
             (wait, task-open, self-delegate, tasks, locks, mediate) with
             clean "not in Phase 0" error messages. `coord health`
             validates config bounds per Decision 2.20 + F-008 (wait_max <
             600).
- [x] T0.19  Establish `bats` test harness skeleton                    (2026-04-24T17:44Z)
             Result: user installed `bats-core 1.13.0`; the full suite
             (45 tests across 7 files: hash, log_event, atomic_write,
             participant, state_query, session_start, session_end — the
             last two now include subagent-skip SUBAGENT_ACTIVITY_SKIPPED
             assertions) passes on first run. Helpers at
             `src/tests/helpers/common.bash`.
- [x] T0.23.1 Land PR-PHASE0-01 (plan + CLAUDE.md edits, code updates) (2026-04-24T17:43Z)
             Result: Decision 2.17 rewritten; Decision 2.20 gains
             wait_max_seconds bounds (30..600) + 570-default rationale;
             §3.5 kind list adds SUBAGENT_ACTIVITY_SKIPPED / WAIT_CLAMPED
             / WAIT_TIMEOUT; §3.6 default 570; §4 coord wait --timeout
             clamp + WAIT_CLAMPED; CLAUDE.md §B.2 option (c) + §B.10
             anti-pattern for subagent-workaround. coord health bound
             check + subagent-skip logging implemented; bats updated.
             F-006 / F-008 → RESOLVED. OI-2 closed.
- [x] T0.22  5-session concurrent `events.jsonl` smoke test            (2026-04-24T17:09Z)
             Result: PASS. 5 sessions × 50 events = 260 events.jsonl
             lines, 0 invalid JSON; all sessions IDLE_CLOSED; 0 locks
             retained; 0 markers leaked. Each session emitted exactly
             1 REGISTER + 50 mid + 1 END. Ship-gate criterion met.
             Discovered + fixed: bash 3.2 `set -euo pipefail` + glob
             with no match in command substitution killed the script;
             rewrote as `for .. in glob; [ -e ]`.
- [x] T0.23  Lock `schema_version = "1.0"` + validate initial `sessions.json` template  (2026-04-24T17:06Z)
             Result: `.coord/schema_version` file contains "1.0"; initial
             sessions.json written via `atomic_write.sh template` has
             `"schema_version":"1.0"` and all required top-level keys.
- [x] T0.24  Draft `phase-0-signoff.md`                                (2026-04-24T17:45Z)
             Result: sign-off written per CLAUDE.md §A.9 structure —
             done-when evidence, risks realized (R3 fired cleanly; R1
             avoided), 2 new risks recorded + already-addressed in
             PR-PHASE0-01, plan revisions applied, OI-2 closed, 4 open
             questions for Phase 1 (F-004 source handling, Linux install
             parity, shared subagent-filter helper, IDLE_CLOSED
             accumulation), full artefact index. Awaits user approval
             per Phase 3 prompt.
- [x] T0.25  Linux parity smoke test (Experiment #10)                  (2026-04-24T18:05Z)
             Result: PASS. `ubuntu:24.04` Docker probe runs full Phase 0
             stack (install + direct smoke + concurrent_smoke + bats).
             44/45 bats pass + 1 skip (chmod 000 no-op as root);
             concurrent_smoke 260/260 clean; install.sh detects
             filesystem as overlay (after inline awk fix). Three
             portability issues found + fixed inline without plan
             change: (a) BSD vs GNU mount(8) output format parser;
             (b) chmod 000 under root uid; (c) harness env leak
             (CLAUDE_COORD exported before bats). Harness:
             `.coord/experiments/linux-parity/` (driver + probe).
             Ship-gate Linux row now ✓; phase-0-signoff.md updated;
             question #2 from signoff removed as closed.

### Phase 0 Ship Gate Checklist (from plan §5)
- [x] All **10** verification experiments have written results in `.coord/phase0-verification.md` (9 canonical + Linux parity #10)
- [x] `coord install` works end-to-end on macOS (host) AND Linux (ubuntu:24.04 container)
- [x] `bats` harness passes for Phase 0 components (45/45 on macOS, 44 pass + 1 skip on Linux root)
- [x] `events.jsonl` is valid JSONL under 5-session concurrent load on both platforms (260 lines, 0 invalid)
- [x] Every OPEN finding relevant to Phase 0 scope has a disposition (8 RESOLVED + 1 DEFERRED to Phase 1)

### Notes
- The task list above is a working estimate; new tasks may be inserted with
  sub-sequence IDs (e.g., T0.12a) as discoveries arise. Reordering is permitted
  when the plan's scope is preserved. Any scope change triggers a FINDINGS
  entry and potentially a plan-revisions entry.
- Linux coverage in the ship gate is best-effort on this workstation; the plan
  permits use of a Linux VM / container or CI to satisfy the cross-platform bar.


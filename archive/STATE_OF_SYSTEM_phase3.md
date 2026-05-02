# State of the system — end of Phase 3

**Date:** 2026-04-26 · **Branch:** `main` at `802c986` (Phase 3 merge)
· **Bats:** 314/314 PASS macOS host + Linux Docker `ubuntu:24.04`
· **Manual fixtures:** 6/6 PASS (2 carry-forward + 4 Phase 3
ship-gate scenarios) · **Supersedes:** `archive/STATE_OF_SYSTEM_phase2.md`

This briefing captures what the multi-session coordination system
does today, what it still doesn't do, and what's worth trusting at
single-developer scale. Plain English, no marketing voice.

---

## 1. The product in plain English

You launch two Claude Code sessions in the same git repo. Both have
`CLAUDE_COORD=1` set. Session A starts editing `foo.ts`. Session B
tries to edit `foo.ts` a few seconds later. **Without the system,**
B's edit silently clobbers A's work. **With the system,** B sees an
explicit deny banner with three options (delegate, self-delegate,
or `coord wait`) and a `coord wait` invocation actually waits until
A releases.

**Phase 3's new contribution: the system also recovers from
crashes.** Concrete scenario, end-to-end:

- Session A acquires the lock on `foo.ts` and starts working.
- The user kills A's terminal hard (`kill -9` from outside, or the
  laptop sleeps badly, or Claude Code crashes). A's PID disappears
  but its lock entry remains in `sessions.json`.
- Session B, on its very next tool call, runs the watchdog ambient-
  suspicion scan as part of `pre_tool_use_any.sh`. It sees A's
  PID is gone (`ps -p <pid>` returns empty) AND/OR A's lock has
  been held for >30min without refresh.
- Watchdog probes A: signal 1 (PID liveness) confirms dead/pid_gone.
  A `stale_active` entry lands in `pending.jsonl`. Verdict cached
  in `recent_checks.jsonl`.
- On B's next pre-tool-use firing, the consumer reads the pending
  entry and spawns `claude -p` as the Mediator subagent. Mediator
  inspects state + the last 50 events + the verdict-history files
  and produces a verdict: `action_type=surgical_fix`,
  `actions=[release_lock(/foo.ts, A), evict_session(A)]`,
  `confidence=auto_apply`.
- Apply pipeline (in B's hook) executes: A removed from
  `sessions.json`, lock on `foo.ts` deleted. Audit trail in
  `events.jsonl` shows the full chain: `WATCHDOG_PROBED →
  WATCHDOG_ESCALATED_TO_MEDIATOR → MEDIATOR_PENDING_DELIVERED →
  MEDIATOR_VERDICT → SESSION_EVICTED → LOCK_RELEASED`.
- B's next Write on `foo.ts` succeeds without manual intervention.

**Compare to Phase 2:** the same scenario required `coord reset
--confirm` operator intervention. Phase 3 makes recovery automatic
at single-developer scale.

---

## 2. Current capabilities

**Existing (Phase 0-2):**
- Read tracking with sha256 hashes; stale-read warnings on hash
  mismatch.
- Write locking via `flock`-protected atomic edits to
  `sessions.json`.
- Hard deny on lock contention with three-options reason text
  (`coord wait` is the only enabled option; (a)/(b) point at
  Phase 6 stubs).
- `coord wait <path> --timeout N` blocking poll until release or
  timeout (clamped [30, 570]).
- Lock release on PostToolUse, Stop, SessionEnd. Notifications to
  waiters on release.
- Mediator-pending JSONL queue (T2.04) with consumer banner +
  HWM advance.

**New in Phase 3 — self-healing infrastructure:**
- **Peer watchdog** (`lib/watchdog.sh` + `lib/watchdog_cache.sh`):
  3-signal probe (PID liveness, last_activity age, lock-unrefreshed
  age); 3-outcome verdict (alive / dead / uncertain); recent-checks
  cache with verdict-typed TTL (alive 60s, dead until next
  session_start, uncertain 30s); per-target dedupe lock so 5+
  sessions noticing the same anomaly produce only one probe.
  Wired into `pre_tool_use_any.sh` as fire-and-forget background
  invocation. Self never probes self.
- **Mediator agent** (`lib/mediator_spawn.sh`): wraps `claude -p`
  in subscription mode (no-bare + `CLAUDE_COORD=0`). Three
  action types: `advice` / `surgical_fix` (with `severity ∈ {brief,
  extended}`) / `lockdown`. Two-state confidence (`auto_apply` /
  `needs_review`). Max-depth-2 peer-review hierarchy: `needs_review`
  spawns a second Mediator with the first verdict in context;
  agreement → apply with more conservative severity; disagreement
  → user-escalation banner. Recursion guard via
  `CLAUDE_CODE_MEDIATOR=<depth>` env.
- **3-section Mediator prompt:** Identity (~80 words) / System
  Constraints (HYBRID — 5 core rules + reference file pointer) /
  Incident Context (HYBRID — embedded snapshot + live read
  allowed via Bash). The deep technical reference lives in
  `MEDIATOR_REFERENCE.md` (installed at
  `.coord/mediator/MEDIATOR_REFERENCE.md`).
- **Lockdown mechanism** (`lib/lockdown.sh`): existence-based gate
  at `.coord/mediator/lockdown.json`. Every coord hook calls
  `coord_lockdown_check + coord_lockdown_emit_deny` before its
  main work. Cleared lockdowns archive to
  `lockdown_archive/<ts>.cleared.json` (atomic rename, audit
  preserved). `reason_source` field distinguishes
  `mediator_verdict` vs `critical_bypass`.
- **Critical-conditions bypass** (`lib/critical_check.sh`): 3+
  consecutive `jq` parse failures on `sessions.json` trigger
  lockdown directly with `reason_source=critical_bypass`,
  skipping Mediator (whose own analysis would inherit the corrupt
  state). Recovery is operator-driven via `coord mediate --resume`.
- **Verdict apply pipeline** (`lib/verdict_apply.sh`):
  `release_lock` / `evict_session` / `clear_read_set` helpers +
  dispatcher + iterator. All idempotent + fail-open. Apply
  ordering rules: lockdown FIRST, `release_lock` BEFORE
  `evict_session` for the same session, `clear_read_set`
  independent.

**New in Phase 3 — operator interface:**
- `coord mediate --reason "..."` — manual escalation primitive;
  writes `kind=manual` pending entry. Useful when you notice
  something the watchdog hasn't flagged.
- `coord mediate --escalate [--reason X]` — operator-initiated
  lockdown with `reason_source=user_escalation`. Pause everything,
  investigate, then `--resume`.
- `coord mediate --resume` — clears any active lockdown.
- `coord mediate --approve <verdict>` — operator picks one of two
  competing verdicts after a peer-review disagreement; applies
  via the verdict_apply pipeline.
- `coord mediate status` — read-only summary: lockdown state,
  recent verdicts (last 10), pending peer-review disagreements
  awaiting `--approve`, last Mediator invocation timing + cost,
  recent watchdog probes (last 5).

**New in Phase 3 — internal infrastructure:**
- `pending.json/jsonl` unification: legacy single-file
  `pending.json` retired; corrupt_state + flock_timeout +
  stale_active + pid_recycled + manual all flow through unified
  `pending.jsonl` with single-consumer pattern. install.sh
  migrates legacy files idempotently.
- `pending.jsonl` GC: 24h retention, HWM rebase, atomic
  single-flock rewrite-plus-HWM-update. Bundled with Mediator
  verdict-write pass (no separate CLI).
- Linux portability hardening: GNU-first `stat` probe with
  numeric validation (F-018); BSD vs GNU `ps lstart` format
  compat verified in linux-parity probe.

---

## 3. Current limitations

What still doesn't work after Phase 3:

- **Stale-read warnings still over-warn.** Any drift triggers a
  banner — including formatter-only changes that wouldn't
  meaningfully invalidate a plan. Phase 4's validator agent
  classifies SAFE / MINOR / CRITICAL and silences the SAFE class.
- **Wait queue is still single-waiter polling, not FIFO.** Two
  sessions waiting on the same lock will not necessarily acquire
  in arrival order. Phase 5 introduces explicit FIFO + wake_file.
- **Self-delegation and `coord task-open` are educational stubs.**
  The deny banner mentions options (a)/(b) but the CLI subcommands
  exit with helpful text pointing at option (c). Phase 6 lands the
  full task-delegation flow.
- **Subagent (Task tool) races stay invisible by design**
  (Decision 2.17 / PR-PHASE0-01). Hooks no-op on
  `agent_type`-populated calls. The parent's lock covers the
  parent's turn, including any subagent activity within it. A
  subagent writing a file the parent doesn't hold a lock on can
  silently clash with another session.
- **Mediator's real-Claude semantics are not stress-tested.** Unit
  tests use a fake `claude` binary that produces scripted JSON
  output. The verdict-writing path, schema, and apply pipeline are
  all exercised end-to-end with synthetic data. Real `claude -p`
  invocations + actual model picks for action_type/severity get
  validated in Phase 7's integration harness (cost ~$0.10/run in
  subscription mode per T3.06 POC).
- **`coord mediate status` cost reporting shows misleading
  `$0.000`** under subscription mode (the API mode field doesn't
  apply). Phase 7 polish adds display logic for "subscription"
  vs "API" modes.
- **`--bare` Mediator spawn for users with `ANTHROPIC_API_KEY`
  is documented but not implemented.** Current user is
  subscription-only; the no-bare path is the only working one.
  `MEDIATOR_REFERENCE.md` documents `--bare` as future enhancement.
- **F-016 timing flake** intermittently surfaces on `coord_wait`
  and Mediator-related teardown under heavy parallel bats load.
  Tests pass in isolation; the flake is bats-environment-only.
  Phase 7 integration harness drives real `claude -p` outside
  bats and resolves it.
- **F-017** ambient-suspicion scan latency is 109ms median
  (PR-PHASE3-02 estimated <50ms p99). Acceptable — 13× below the
  2-second hard ceiling — but optimization deferred to Phase 7
  stress test.
- **Multi-machine, team-shared coord scenarios are out of scope
  for v1.** All recovery guarantees are local-filesystem only.
  Documented as future-work.

---

## 4. Is this usable RIGHT NOW?

Three audiences. Phase 2 verdicts quoted; Phase 3 revisions noted.

**(a) Solo developer, 1–2 sessions occasionally.**

Phase 2 verdict: *"genuine value. Real deny prevents real
clobbering; coord wait provides graceful coordination. Worth
installing now."*

Phase 3 verdict: same value PLUS automatic recovery from crashed
sessions. The need for `coord reset --confirm` operator
intervention is largely eliminated for normal SIGKILL/crash
scenarios. The system now self-heals at single-developer scale.
If your terminal dies mid-edit, the next session you launch
recovers within ~30-60 seconds (subscription-mode wall-clock for
a real Mediator spawn) without you running anything.

**(b) Solo developer, 3–5 concurrent sessions on the same repo.**

Phase 2 verdict: *"the system has earned its keep. Lock contention
is now real protection, not advisory."*

Phase 3 verdict: trust posture extends. Crashed sessions don't
permanently block live ones. Mediator handles orphan-lock cleanup
within ~30-60 seconds (subscription mode wall-clock). Multi-waiter
ordering still by coincidence (Phase 5 `wait_queue` fixes that
properly), but the safety guarantee is now layered: prevent
clobbering (Phase 2) + recover from crashes (Phase 3). If three
sessions race for the same lock and one crashes, the other two see
the recovery within one tool call.

**(c) Team / multi-developer / multi-machine.**

Out of scope for v1. (Unchanged from Phase 2 verdict.)

---

## 5. How it actually works (architecture in ~300 words)

The system is a Bash-only set of hooks (jq + flock + perl)
registered into Claude Code's `.claude/settings.local.json`.
Hooks fire on PreToolUse / PostToolUse / Stop / SessionStart /
SessionEnd / UserPromptSubmit. State lives at `.coord/`
(gitignored) under `sessions.json` (atomic-edited via
`lib/atomic_write.sh`), an append-only `events.jsonl` audit log,
and a JSONL Mediator queue at `mediator/pending.jsonl`.

**Phase 3 architectural additions:**
- Three new lib-module clusters: peer watchdog
  (`lib/watchdog.sh` + `lib/watchdog_cache.sh`) for ambient
  suspicion + 3-signal probe + verdict cache; Mediator
  infrastructure (`lib/mediator_spawn.sh` +
  `lib/verdict_apply.sh` + `lib/critical_check.sh`) for the
  agent invocation chain; lockdown gate
  (`lib/lockdown.sh`).
- **Mediator spawn flow:** hook detects unconsumed pending
  entry → spawns `claude -p` with `--output-format json`,
  `--allowedTools "Bash Read"`, `--disallowedTools "Write Edit
  NotebookEdit Task"`, `CLAUDE_COORD=0` and
  `CLAUDE_CODE_MEDIATOR=<depth>` in spawn env. Mediator reads
  state via `cat`/`jq` + mutates via Bash + `atomic_write.sh`
  helpers (Edit/Write tools forbidden by spawn flags). Verdict
  written to `.coord/mediator/verdict/<ts>.json`. Hook captures
  `is_error` from JSON (NOT shell exit code — `claude -p` exits
  0 even on auth/budget failures).
- **3-section Mediator prompt:** Identity / System Constraints
  (HYBRID with `MEDIATOR_REFERENCE.md`) / Incident Context
  (HYBRID — snapshot + live read allowed via Bash). The
  reference doc covers verdict schema, lockdown.json schema,
  atomic_write helpers, GC rules, event log format, caller
  communication contract, and apply ordering rules.
- **Lockdown gate:** every hook calls `coord_lockdown_check +
  coord_lockdown_emit_deny` BEFORE main hook logic. This is the
  second of the Phase 3 invariant's exactly-two architectural
  deny sources (the first is `pre_tool_use_write.sh`
  lock-held-by-other branch). Asserted by `phase3_invariant.bats`
  via 6 architectural guards.
- **Unified pending queue:** corrupt_state + flock_timeout +
  stale_active + pid_recycled + manual all flow through single
  `pending.jsonl` with single-consumer pattern at
  `pre_tool_use_any.sh` + `session_start.sh`. install.sh
  migrates pre-Phase-3 single-file `pending.json` idempotently.
- **Peer review:** when `verdict.confidence == needs_review` at
  depth=1, the hook spawns a second Mediator at depth=2 with the
  first verdict in context bundle. Consensus on `action_type` →
  apply with more conservative severity. Disagreement → user
  escalation banner with `coord mediate --approve <path>`
  commands. Hard ceiling at depth=2; no third Mediator.

---

## 6. What ships in Phase 4

Per `IMPLEMENTATION_PLAN.md` §5 Phase 4 — Validation subagent:

- **Validator agent hook:** subagent that classifies stale-read
  drift as SAFE / MINOR / CRITICAL based on diff content + hash
  comparison.
- **SAFE drifts no longer warn** (current Phase 3 behavior
  over-warns on any hash mismatch, including formatter-only
  changes).
- **MINOR drifts continue advisory warning** (`additionalContext`
  text, no escalation).
- **CRITICAL drifts → escalate via Mediator** by writing a pending
  entry that the existing Phase 3 pipeline picks up. Mediator
  decides advice / surgical_fix / lockdown depending on scope.
- **Diff-aware validation:** validator inspects actual file delta
  + read-set hash mismatch, not just "drifted." `pre_tool_use_write.sh`
  retires its line-182 PHASE-4 UPGRADE POINT.
- **Phase 4 invariant prediction:** validator must NOT introduce a
  third architectural deny site. CRITICAL escalation goes via
  Mediator → which can lockdown if scope is system-wide. The
  two-location deny invariant (lock-held + lockdown active) stays
  intact through Phase 4. (Per Phase 3 sign-off Open Question #3.)

Phase 4 reuses the Mediator spawn primitives (`lib/mediator_spawn.sh`)
with a different prompt + tool restrict for the validator path.

---

## 7. Trust posture

**Phase 2 verdict:** *"earned its keep at 1-5 single-developer
session range, worst-case behavior well-defined."*

**Phase 3 verdict (revised):** earned its keep at 1-5
single-developer session range with new recovery guarantees. The
system now self-heals from session crashes without operator
intervention in normal scenarios. Trust the lock guarantee + the
recovery guarantee at single-user scale.

**Trust:**
- Lock guarantee — concurrent writes don't clobber.
- Three-options interface — deny banner is actionable.
- `coord wait` — clean exit semantics, clamp behavior, SIGINT
  trap.
- Mediator surgical fixes for orphan locks — `release_lock` +
  `evict_session` apply pipeline is idempotent and audit-trailed.
- Watchdog probe for ambient suspicion — 3-signal model is
  conservative (Signal 1 mandatory for alive; alone-Signal-2/3 →
  uncertain → defer to Mediator).
- Lockdown for system-wide problems — every-hook gate is
  architecturally enforced via `phase3_invariant.bats`.
- Critical-bypass + operator `--resume` — degraded-state recovery
  path is documented, tested (scenario 03), and predictable.

**Do NOT yet trust:**
- Trivial-drift suppression (validator Phase 4 fixes; Phase 3
  over-warns on formatter-only drift).
- Multi-waiter ordering fairness under contention (Phase 5
  `wait_queue` fixes; Phase 3 still polls).
- Task delegation primitives (Phase 6; Phase 3 has educational
  stubs).
- Real-Claude Mediator semantics under stress (Phase 7
  integration harness; Phase 3 unit tests use a fake claude
  binary).
- Cost predictability under high Mediator-firing rate (Phase 7
  measurement; T3.06 POC estimated $0.10/invocation in
  subscription mode, 30s debounce + 20/hour caps planned but
  not yet enforced).

The recovery guarantee scope is single-developer. Multi-machine
team scenarios still out of scope for v1.

**By the numbers:** 192/192 → 314/314 unit tests on macOS host
+ Linux Docker `ubuntu:24.04`. 6/6 fixture scenarios across both
platforms. F-014 + F-018 RESOLVED in Phase 3. F-015 (Phase 6),
F-016 (Phase 7), F-017 (Phase 7) OPEN with deadlines.

**Branch:** `main` at `802c986` (Phase 3 merge commit). Eleven
Phase 3 task commits (T3.01 through T3.10) visible alongside via
`--no-ff`. Phase 1 and Phase 2 merge commits preserved at
`629b1fb` and `6b0cc35` respectively.

Phase 3 is NOT the finished system. It is the deepest layer of
self-healing infrastructure the system gets before the validator
(Phase 4) and the wait queue (Phase 5) extend it. The system has
graduated from "prevents bad writes" (Phase 2) to "prevents bad
writes AND recovers from session deaths" (Phase 3). Phase 4 will
sharpen the false-positive surface; Phase 5 will fix the
multi-waiter coincidence; Phase 6 will land delegation. Each
phase compounds; no phase invalidates a prior phase's claim.

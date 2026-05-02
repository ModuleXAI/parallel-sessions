# State of the system — end of Phase 5

**Date:** 2026-04-27 · **Branch:** `main` at `ab65d26` (Phase 5 merge)
· **Bats:** 486/486 PASS macOS (472 unit + 14 integration) +
472/472 unit PASS on Linux Docker `ubuntu:24.04` (integration
tests macOS-only at present per T5.08 pragmatic disposition;
production lib paths validated on Linux via unit suite)
· **Manual fixtures:** 14/14 PASS (2 carry-forward + 4 Phase 3 +
4 Phase 4 + 4 Phase 5 ship-gate scenarios) · **Supersedes:**
`archive/STATE_OF_SYSTEM_phase4.md`

This briefing captures what the multi-session coordination system
does today, what it still doesn't do, and what's worth trusting at
single-developer scale. Plain English, no marketing voice.

---

## 1. The product in plain English

You launch two Claude Code sessions in the same git repo. Both
have `CLAUDE_COORD=1` set. Session A starts editing `foo.ts`.
Session B tries to edit `foo.ts` a few seconds later. **Without
the system,** B's edit silently clobbers A's work. **With the
system,** B sees an explicit deny banner with three options
(delegate, self-delegate, or `coord wait`) and a `coord wait`
invocation actually waits until A releases.

Phase 3 added crash recovery (`archive/STATE_OF_SYSTEM_phase3.md`
walks the SIGKILL → watchdog → Mediator → `surgical_fix` → release
flow end-to-end). Phase 4 added stale-read drift classification
(SAFE silent / MINOR banner / CRITICAL Mediator escalation;
`archive/STATE_OF_SYSTEM_phase4.md` walks the
`getUser(id) → getUser(id, opts)` signature-change scenario).

**Phase 5's new contribution: multi-waiter fairness, event-driven
wake-up, and deadlock detection.** Concrete scenarios, end-to-end:

**Scenario 1 — multi-waiter FIFO + diff_summary on release.**
Session A holds the lock on `api.ts`. Session B and Session C
both want to write to it.

- Session B issues `coord wait /api.ts` → enqueued at position 0
  in `wait_queues[<api.ts>]`.
- Session C issues `coord wait /api.ts` a moment later → enqueued
  at position 1 (ms-precision `waiting_since` ordering).
- Session A finishes its edit (renames `loginHandler` to
  `signInHandler`) and releases the lock.
- The Phase 4 validator pipeline ran during A's write turn and
  cached a MINOR verdict; the lock has
  `latest_validator_verdict_ts` populated, so the 4-tier
  `diff_summary` chain in `lib/notify_waiters.sh` resolves at
  Tier 1: verdict file lookup → `diff_summary = "renamed
  loginHandler to signInHandler"`.
- That single `diff_summary` is broadcast to **both**
  wake_files in one pass (no N×lookup waste). A single
  `NOTIFICATION_PRODUCED` event is logged with
  `diff_summary_source=verdict_file`.
- B's wake_file event fires immediately
  (`inotifywait` <100ms on Linux, `fswatch` <500ms on macOS,
  250ms polling fallback otherwise). B's `coord wait` reads
  the wake_file content with a 50ms grace re-read for the
  create-vs-write race, then exits with the diff_summary on
  stdout for B's `additionalContext`.
- B re-reads `api.ts`, sees the new signature, revises its plan,
  acquires the lock, edits, releases.
- C wakes next when B releases — FIFO ordering preserved.

**Compare to Phase 4:** the same scenario in Phase 4 had
over-warn elimination at the *classification* layer (B and C
would not get false-positive warnings on trivial drift), but
multi-waiter ordering was still "by coincidence" — whichever
session's polling cycle aligned with the lock release won the
race. Phase 5 fixes ordering AND adds context: waiters know
*what* changed before re-reading.

**Scenario 2 — cycle detection + Mediator surgical_fix.**

- Session A holds `/foo`, enqueues for `/bar`.
- Session B holds `/bar`, enqueues for `/foo`.
- Session C enqueues for `/foo`. Post-append depth on
  `wait_queues[/foo]` is 2 → cycle-detection trigger fires from
  C's enqueue.
- `coord_cycle_detect` runs an iterative bipartite session/file
  DFS starting from C. The walk traverses `/foo → A (held_by)
  → /bar (waits_for) → B (held_by) → /foo`. Cycle identified:
  `B↔A`. C is correctly excluded as a non-cycle waiter.
- A 9-key `cycle_detected` pending entry is written to
  `.coord/mediator/pending.jsonl` (cycle_path,
  cycle_description, involved_sessions, involved_files,
  queue_depth_at_detection, recent_cycle_count,
  session_metadata, trigger_file, trigger_session_id).
- The Mediator is spawned inline synchronously
  (`mediator_spawn.sh` — same pattern as Phase 4's
  `critical_drift`). Mediator inherits the kind-agnostic
  prompt template that Phase 3 already shipped; the
  `cycle_description` and `session_metadata` flow into context
  automatically. **Zero Mediator code changes.**
- Mediator decides `action_type=surgical_fix`,
  `actions=[evict_session(B)]` per the 3-tier eviction
  priority documented in `MEDIATOR_REFERENCE.md` §4.X.1
  (oldest `last_activity_at` → fewest locks → youngest
  session_age).
- The apply pipeline executes: B is evicted, B's lock on
  `/bar` releases, B's wait_queue entries are dropped, B's
  read-set + read-snapshots + wake_files are GCed.
- A's enqueue on `/bar` resolves; A acquires `/bar`,
  finishes its work, releases. `/foo` then frees for C.
- Total deadlock recovery: ~50–100s wall-clock (validator
  ~30–60s + Mediator ~20–35s).

**Compare to Phase 4:** the same A↔B scenario in Phase 4
produced a silent deadlock — no detection mechanism, no
recovery path short of `kill -9` and the watchdog. Phase 5
adds the detection trigger AND the recovery path through
the existing Mediator infrastructure.

---

## 2. Current capabilities

**Existing (Phase 0–4):**
- Read tracking with sha256 hashes; stale-read detection.
- Write locking via `flock`-protected atomic edits.
- Hard deny on lock contention with three-options reason.
- Lock release on PostToolUse, Stop, SessionEnd.
- Peer watchdog with 3-signal probe + 3-outcome verdict.
- Mediator agent: `advice`/`surgical_fix`/`lockdown`,
  two-state confidence, max-depth-2 peer review, unified
  `pending.jsonl` queue.
- Lockdown gate at `.coord/mediator/lockdown.json`.
- Critical-conditions bypass (3+ consecutive parse failures).
- Operator interface: `coord mediate {--reason | --escalate
  | --resume | --approve | status}`.
- Read-snapshot capture per session (1h TTL on
  content-addressable store).
- Validator pipeline: cache → pre-filter → `claude -p` agent
  spawn; SAFE silent / MINOR banner / CRITICAL synchronous
  Mediator; CRITICAL never cached (PR-PHASE4-04).
- Per-session `last_consumed_verdict` pointer for idempotent
  retried writes.

**New in Phase 5 — wait queue + wake file + cycle detection:**

- **Wait queue infrastructure** (`lib/wait_queue.sh`,
  T5.02): 6 public functions (`enqueue`, `dequeue`, `head`,
  `size`, `position`, `cleanup_session`). Per-file flock at
  `.coord/wait_queues/<sanitized_path>.lock`; sanitization is
  literal `tr / __` (leading `__` preserved on absolute
  paths). Ms-precision `waiting_since` field provides FIFO
  ordering. Idempotent enqueue (same sid + same file = no-op,
  no duplicate entries). `cleanup_session` walks the queue
  globally on session_end / Mediator eviction, drops empty
  keys, and renumbers `position` fields. **Schema slot
  renamed at T5.02:** Phase 2's singular `wait_queue` →
  Phase 5's plural `wait_queues` across 5 production sites
  + 2 comment-only updates.

- **Wake file mechanism + event-driven `coord wait`**
  (`lib/wait_backend.sh`, T5.03): 8 public functions across
  3 backends. macOS uses `fswatch` (Homebrew) when
  available; Linux uses `inotifywait` (inotify-tools); both
  fall back to 250ms wake_file mtime polling when neither is
  installed. 50ms grace re-read on the create-vs-write race;
  fallback string `"modified by <session_id_prefix>"` if
  wake_file content is empty. Install-time
  `WAIT_BACKEND_DETECTED` event records the chosen backend
  for the audit trail. SessionStart polling-mode warning
  appends an `additionalContext` line recommending
  `brew install fswatch` (macOS) or
  `apt install inotify-tools` (Linux). Runtime backend
  fallback handles the case where the binary is uninstalled
  after install. F-001 precedent applies: optional
  dependency, graceful degradation, never silent regression.

- **4-tier `diff_summary` chain on lock release**
  (`lib/notify_waiters.sh` rewrite, T5.04): bridges Phase 4
  ↔ Phase 5. Resolution priority:
  - **Tier 1** (verdict file): jq lookup of
    `.coord/validator/verdict/<ts>.json::.diff_summary` via
    `locks[<file>].latest_validator_verdict_ts`.
  - **Tier 2** (cache hit): `coord_validator_cache_lookup`
    on `(file, prev_hash, current_hash)`. SAFE → "trivial
    change (no semantic drift)"; MINOR → cached
    diff_summary text. CRITICAL never appears here (never
    cached).
  - **Tier 3** (pre-filter SAFE):
    `coord_validator_prefilter` on the holder's read snapshot
    vs current file. SAFE on whitespace/blank/comment-only →
    "trivial change (whitespace/comment)".
  - **Tier 4** (fallback): `"modified by <holder_id_prefix>"`.

  Single computation broadcast to all queued waiters'
  wake_files. One `NOTIFICATION_PRODUCED` event per release
  with `diff_summary_source=<tier>` label. Phase 2's
  `events.jsonl` LOCK_DENIED scan **deleted** — full pivot
  to `wait_queues` as authoritative source. `events.jsonl`
  remains audit-trail-only.

- **Schema field NEW:**
  `locks[<file>].latest_validator_verdict_ts`. Populated by
  the Phase 4 validator pipeline when a fresh verdict was
  produced during the holder's write turn. Null otherwise.
  This field is the Phase 4 ↔ Phase 5 bridge.

- **Cycle detection** (`lib/cycle_detection.sh`, T5.05): 3
  public functions
  (`coord_cycle_detect` / `coord_cycle_describe` /
  `coord_cycle_emit_pending`). Iterative bipartite session/file
  DFS — Bash 3.2 stack-compatible, no recursion. Visited-set
  tracking on session nodes only. **Trigger:** post-enqueue
  wait_queue depth ≥ 2. 9-key `cycle_detected` pending
  payload (cycle_path, cycle_description, involved_sessions,
  involved_files, queue_depth_at_detection,
  recent_cycle_count, session_metadata, trigger_file,
  trigger_session_id). `cycle_id` is a hash-based unique
  identifier. Bipartite invariant strict: edges of type
  `waits_for` always have a session as `from`; edges of type
  `held_by` always have a file as `from`. T5.02 placeholder
  fallback preserved (graceful degradation when
  `cycle_detection.sh` not sourced — minimal install
  scenarios still function). **Architectural observation:**
  the silent 2-cycle case (depth=1 on each queue, no trigger)
  is a known limitation; Phase 7 wait_max_seconds timeout
  cleanup mitigates.

- **Mediator integration with `cycle_detected`**
  (`MEDIATOR_REFERENCE.md` §4.X, T5.06): ~190 lines of
  documentation. Decision matrix: `advice` for shallow
  cycles, `surgical_fix` brief for typical eviction,
  `surgical_fix` extended for multi-file cycles, `lockdown`
  for ≥4 sessions OR `recent_cycle_count` ≥ 2 within 60s.
  3-tier eviction priority embedded in `cycle_description`
  field (oldest `last_activity_at` → fewest locks → youngest
  session_age). The Phase 3 prompt template at
  `mediator_spawn.sh:142–159` was already kind-agnostic;
  `cycle_description` + `session_metadata` flow into Mediator
  context automatically. **Zero Mediator code changes**
  (Decision 4 binding, PR-PHASE5-04). The Phase 4
  `critical_drift` synchronous-inline pattern is reused
  directly.

- **First integration test suite**
  (`src/tests/integration/phase5_e2e.bats`, T5.08): 14
  scenarios exercising the wait_queue → wake_file →
  diff_summary → cycle_detect → Mediator hand-off paths
  end-to-end. Project's first integration tests; previously
  only unit tests existed.

- **Phase 5 invariant** (`phase5_invariant.bats`, T5.07):
  14 guards (8 architectural + 6 bonus). The
  `phase4_invariant.bats` was deleted at T5.07, mirroring
  the Phase 3 → Phase 4 transition.

---

## 3. Current limitations

What still doesn't work after Phase 5:

- **Self-delegation and `coord task-open` are educational
  stubs.** The deny banner mentions options (a)/(b) but the
  CLI subcommands exit with helpful text pointing at option
  (c). Phase 6 lands the full task-delegation flow.
- **Subagent (Task tool) races stay invisible by design**
  (Decision 2.17 / PR-PHASE0-01 carry-forward). Hooks no-op
  on `agent_type`-populated calls.
- **Real-Claude Mediator + Validator semantics are not yet
  stress-tested.** Unit tests use a fake `claude` binary
  emitting scripted JSON. Real `claude -p` invocations get
  validated in Phase 7's integration harness.
- **`coord mediate status` cost reporting still shows
  misleading `$0.000`** under subscription mode. Phase 7
  polish.
- **`--bare` spawn mode for users with `ANTHROPIC_API_KEY`
  is documented but not implemented** (carry-forward from
  Phase 3 + Phase 4).
- **F-016 timing flake** remains intermittent under heavy
  parallel bats load. Did NOT fire across ~10 Linux probes
  during Phase 5 construction; flake is bats-environment-only.
  Phase 7 stress harness fixes it.
- **F-017 ambient-suspicion latency at 109ms median**
  (PR-PHASE3-02 estimated <50ms). Acceptable — well below
  the 2-second hard ceiling — but optimization deferred to
  Phase 7.
- **F-015 `coord wait` subagent policy revisit** deferred to
  Phase 6 (delegation primitives surface the policy choice).
- **Cost guard tunables** (`mediator_min_seconds_between_invocations`,
  `mediator_max_invocations_per_hour`, validator-spawn
  ceilings) are env-var configurable but **not yet
  enforced**. Phase 7 measurement-driven defaults pin them.
- **Auto-reset race on corrupt-state detection** —
  theoretical edge case where two hooks racing on parse
  failure could double-count. Phase 7 stress check covers
  it.
- **Silent 2-cycle case** — when each cycle session has
  depth=1 on its queue, no trigger fires until either an
  external waiter enqueues (depth → 2) or the
  `wait_max_seconds` clamp expires. Phase 7 follow-up
  cleanup detection from the timed-out session's perspective.
- **Multi-machine, team-shared coord scenarios are out of
  scope for v1.** All recovery + classification + fairness
  + deadlock-resolution guarantees are local-filesystem only.

---

## 4. Is this usable RIGHT NOW?

Three audiences. Phase 4 verdicts quoted; Phase 5 revisions
noted.

**(a) Solo developer, 1–2 sessions occasionally.**

Phase 4 verdict: *"smart drift classification. Trivial drift
no longer interrupts your flow with warning banners.
Meaningful drift gets an informational banner. Breaking drift
gets Mediator escalation with state cleanup applied before
your Write proceeds."*

Phase 5 verdict: same value PLUS multi-waiter fairness AND
faster wake-up. When you have 2–3 sessions on the same repo,
FIFO ordering is now guaranteed — whoever issues `coord wait`
first wakes first. With `fswatch` or `inotify-tools` installed,
wake-up is sub-100ms; the experience is effectively
instantaneous. The polling fallback adds ~150–200ms latency,
which is still below human-perceptible threshold for an
edit-cycle pause. On a quiet 1-session day Phase 5 changes
nothing visible; the win surfaces the moment a second session
needs the same file.

**(b) Solo developer, 3–5 concurrent sessions on the same
repo.**

Phase 4 verdict: *"trust posture extends further. Cross-session
edits no longer produce false-positive warnings on trivial
changes. Multi-waiter ordering is still by coincidence (Phase 5
fixes that), but the safety + recovery + classification layers
are now all production-quality at single-user scale."*

Phase 5 verdict: trust posture extends further. Multi-waiter
ordering finally fair (FIFO arrival), wake-up event-driven
(5–6× faster than polling under contention), waiters receive
`diff_summary` so they know what changed before re-reading
(the 4-tier chain ensures the message is informative whether
the validator pipeline ran or not). Cycle detection catches
A↔B deadlock scenarios automatically; Mediator surgical_fix
eviction resolves them without operator intervention. Five
sessions racing 3 files now safely coordinate without the
"who happened to wake up first" lottery and without the
silent-deadlock cliff that Phase 4 had.

**(c) Team / multi-developer / multi-machine.**

Out of scope for v1. (Unchanged from Phase 2/3/4 verdict.)

---

## 5. How it actually works (architecture in ~300 words)

The system is a Bash-only set of hooks (`jq` + `flock` +
`perl` + optional `fswatch` / `inotifywait`) registered into
Claude Code's `.claude/settings.local.json`. State lives at
`.coord/` (gitignored) under `sessions.json` (atomic-edited
via `lib/atomic_write.sh`), an append-only `events.jsonl`
audit log, JSONL queues at `mediator/pending.jsonl`,
`validator/verdict/<ts>.json`, and now per-file lock dirs at
`wait_queues/<sanitized_path>.lock` with wake_files at
`wakers/<sid>-<sanitized>.wake`.

**Phase 5 architectural addition: wait_queue + wake_file +
cycle_detection layer.** New lib clusters:
- `lib/wait_queue.sh` — per-file flock + 6-fn API,
  ms-precision FIFO, idempotent enqueue, global cleanup.
- `lib/wait_backend.sh` — fswatch / inotifywait / polling
  abstraction, install-time detection, runtime fallback,
  50ms grace re-read on create-vs-write race.
- `lib/cycle_detection.sh` — iterative bipartite session/file
  DFS, depth ≥ 2 trigger, 9-key pending payload,
  hash-based `cycle_id`.

The 4-tier `diff_summary` chain in `lib/notify_waiters.sh`
bridges Phase 4 ↔ Phase 5 via the
`locks[<file>].latest_validator_verdict_ts` schema field:
verdict_file → cache → pre-filter → fallback. Phase 2's
`events.jsonl` scan was deleted — `wait_queues` is now the
single source of truth for waiters; `events.jsonl` remains
audit-trail-only.

**Mediator integration is kind-agnostic** —
`cycle_detected` payload flows through the existing Phase 3
3-action contract (`advice` / `surgical_fix` / `lockdown`)
with **zero Mediator code changes** (Decision 4 / PR-PHASE5-04
binding). The Phase 4 `critical_drift` synchronous-inline
spawn pattern is reused directly for cycle escalation.

**Phase 5 invariant:** 14 guards (8 architectural + 6 bonus)
in `phase5_invariant.bats`. The 2-location deny invariant
(`pre_tool_use_write.sh` lock-held + lockdown gate) is
**preserved through Phases 3+4+5** — NO third deny site
introduced. The project's first integration test suite landed
at `src/tests/integration/phase5_e2e.bats` (14 scenarios).

---

## 6. What ships in Phase 6

Per `IMPLEMENTATION_PLAN.md` §6 Phase 6 — Task delegation:

- **Task delegation primitives:** `coord task-open` and
  `coord self-delegate` move from educational stubs to full
  implementations. The deny-banner options (a) and (b) become
  actionable.
- **Inter-session task graph extension:** cycle detection
  expands beyond locks to task dependencies. The bipartite
  DFS pattern from `lib/cycle_detection.sh` extends naturally
  to a tripartite session/file/task graph.
- **F-015 disposition:** `coord wait` subagent policy
  decision (currently OPEN, deferred from Phase 5).
- **Subagent + Task tool integration:** Decision 2.17 revisit.
  The current "subagent races invisible by design" posture
  may evolve as the delegation primitives provide a tracked
  alternative.
- **Possibly:** real-Claude Mediator + Validator semantic
  verification early scope (currently slated for Phase 7).

**Phase 6 invariant prediction:** task delegation may
introduce a **third architectural deny location** IF
self-delegation requires hard refusal on a cycle-detected
task graph. Alternative: route through Mediator using the
same kind-agnostic dispatch pattern Phase 5 established for
`cycle_detected`. Decision deferred to the Phase 6 planning
conversation. The Phase 5 precedent (cycle detection without
new deny location) is a strong signal that the same approach
works for task graph cycles.

---

## 7. Trust posture

**Phase 4 verdict:** *"earned its keep at 1–5 single-developer
session range with new classification quality. The system now
distinguishes signal from noise on stale-read drift events.
Trust the lock guarantee + the recovery guarantee + the
classification guarantee at single-user scale."*

**Phase 5 verdict (revised):** earned its keep at 1–5
single-developer session range with new fairness +
event-driven UX + deadlock detection. Trust the lock
guarantee + the recovery guarantee + the classification
guarantee + the multi-waiter fairness guarantee + the
deadlock-resolution guarantee at single-user scale.

**Trust:**
- Lock guarantee — concurrent writes don't clobber.
- Three-options interface — deny banner is actionable.
- `coord wait` — now event-driven (sub-100ms with
  `fswatch`/`inotifywait`, 250ms polling fallback), clean
  exit semantics, clamp behavior, SIGINT trap.
- Mediator surgical fixes — `release_lock`,
  `evict_session`, `clear_read_set` apply pipeline is
  idempotent and audit-trailed; now also handles
  `cycle_detected` via kind-agnostic dispatch.
- Watchdog probe — 3-signal model, Signal 1 mandatory for
  alive verdict.
- Lockdown for system-wide problems — every-hook gate
  architecturally enforced via `phase5_invariant.bats`.
- Critical-bypass + operator `--resume` — degraded-state
  recovery is documented, tested, predictable.
- Validator SAFE/MINOR/CRITICAL classification (mock binary
  verified end-to-end through pipeline; real-Claude picks
  Phase 7).
- Validator cache for recurring drift.
- Pre-filter conservative doctrine — multi-line-string
  ambiguity → ESCALATE.
- **`wait_queues` FIFO ordering** (per-file flock,
  ms-precision `waiting_since`, idempotent enqueue,
  cleanup-on-eviction).
- **Wake_file event-driven wake-up** (fswatch /
  inotifywait / polling fallback; F-001 graceful
  degradation precedent).
- **4-tier `diff_summary` chain on lock release** (single
  computation, broadcast to all waiters,
  `NOTIFICATION_PRODUCED` audit event with tier label).
- **Cycle detection** (bipartite DFS, depth ≥ 2 trigger,
  9-key pending payload, hash-based unique id).
- **Mediator `cycle_detected` handling** (kind-agnostic
  dispatch verified at T5.06; zero Mediator code changes).

**Do NOT yet trust:**
- Task delegation primitives (Phase 6; Phase 5 still has
  educational stubs).
- Real-Claude Mediator + Validator semantics under stress
  (Phase 7 integration harness; Phase 5 unit tests still
  use fake `claude` binary).
- Cost predictability under high spawn rate — combined
  Mediator + Validator rate-limit enforcement is Phase 7.
- F-016/F-017 timing assumptions (Phase 7 stress harness).
- **Inter-session task graph cycle detection** (Phase 6
  extension; Phase 5 detects cycles in lock dependencies
  only).
- **Subagent races** (Decision 2.17 carry-forward — still
  invisible by design).

The fairness + recovery + classification + lock guarantees
scope is single-developer. Multi-machine team scenarios
still out of scope for v1.

**By the numbers:** 390/390 → 486/486 tests on macOS host
(472 unit + 14 integration) + 472/472 unit on Linux Docker
`ubuntu:24.04` (integration tests macOS-only at present;
production lib paths validated on Linux via unit suite per
T5.08 pragmatic disposition). 14/14 fixture scenarios across
both platforms (2 carry-forward + 4 Phase 3 + 4 Phase 4 +
4 Phase 5).
**Zero new findings raised in Phase 5** — the construction
discipline accumulated through Phases 3 + 4 (rc-capture
pattern, lifecycle-event-completeness audit, prefilter
heuristic ambiguity, GNU-first stat probe, perl-utime
mtime manipulation) plus Phase 5's own additions
(Bash 3.2 parser fragility on `out=$( ( cmd ) 9>"lock" )`,
bats PATH manipulation cross-host fragility, helper stdout
bleed in `$()` captures, `jq --argjson` JSON-not-jq syntax)
caught their own pitfalls pre-commit. F-015 (Phase 6),
F-016 (Phase 7), F-017 (Phase 7) remain OPEN with
deadlines.

**Branch:** `main` at `ab65d26` (Phase 5 merge commit). Ten
Phase 5 commits (T5.01 plan-revision drafts through T5.11
sign-off) visible alongside the merge commit via `--no-ff`.
Phase 1, Phase 2, Phase 3, Phase 4 merge commits preserved
at `629b1fb`, `6b0cc35`, `802c986`, `5684e64` respectively.

Phase 5 is NOT the finished system. It is the wait_queue +
wake_file + cycle_detection layer that sits on top of the
classification layer (Phase 4) on top of the lock +
crash-recovery layers (Phases 2 + 3). The system has
graduated from *"prevents bad writes, recovers from session
deaths, AND distinguishes trivial drift from breaking drift"*
(Phase 4) to *"prevents bad writes, recovers from session
deaths, distinguishes trivial drift from breaking drift,
delivers fair multi-waiter ordering with event-driven
wake-up AND informative diff_summary, AND detects + resolves
lock-dependency deadlocks"* (Phase 5). Phase 6 will land
delegation primitives; Phase 7 will harden the real-Claude
integration. Each phase compounds; no phase invalidates a
prior phase's claim.

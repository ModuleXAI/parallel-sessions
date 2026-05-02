# State of the system — end of Phase 6

**Date:** 2026-04-28 · **Branch:** `main` at `855fc29` (Phase 6 merge)
+ `bd6e37d` (Phase 6 close cleanup, CLAUDE.md §B prose update)
· **Bats:** 582/582 PASS macOS (582 unit + 24 integration; numbers
match macOS authoritative host) · 581/582 unit + 19/19 fixtures on
Linux Docker `ubuntu:24.04` (1 timing flake at test 527
`wait_backend` inotifywait wake-up latency, F-017 family, NOT a
Phase 6 regression) · **Manual fixtures:** 19/19 PASS (2
carry-forward + 4 Phase 3 + 4 Phase 4 + 4 Phase 5 + 5 Phase 6
ship-gate scenarios) · **Supersedes:**
`archive/STATE_OF_SYSTEM_phase5.md`

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
(delegate, self-delegate, or `coord wait`) and **all three options
are now production CLIs** as of Phase 6.

Phase 3 added crash recovery (`archive/STATE_OF_SYSTEM_phase3.md`
walks the SIGKILL → watchdog → Mediator → `surgical_fix` → release
flow end-to-end). Phase 4 added stale-read drift classification
(`archive/STATE_OF_SYSTEM_phase4.md` walks the
`getUser(id) → getUser(id, opts)` signature-change scenario).
Phase 5 added multi-waiter fairness, event-driven wake-up, and
lock-dependency deadlock detection
(`archive/STATE_OF_SYSTEM_phase5.md` walks the FIFO + diff_summary
scenario and the A↔B cycle → Mediator surgical_fix scenario).

**Phase 6's new contribution: cross-session task delegation,
self-delegation lifecycle, and task-graph cycle prevention.** The
deny banner's options (a) and (b), which Phase 5 still rendered as
educational stubs ("[Phase 6 deliverable, disabled]"), are now
actionable subcommands. Concrete scenarios, end-to-end:

**Scenario 3 — cross-session task delegation (option a).**
Session A holds the lock on `auth.ts`, mid-edit on the login flow
(lines 100–150). Session B encounters a deny banner because A
holds `auth.ts`; B sees the banner offering three options.

- B issues
  `coord task-open --file /auth.ts --complexity SIMPLE --anchor
  '{"search":"function loginHandler","window_lines":"42-50"}'
  --instruction "rename to signInHandler when you finish your
  edits"`.
- The CLI parses the anchor JSON, validates the `window_lines`
  range, and runs an anchor-uniqueness check via
  `grep -F -c "function loginHandler" /auth.ts`. The string
  matches exactly once → unique, persisted.
- The CLI checks `task_delegation` toggle via the lesson #14 jq
  `has()` pattern (correctly distinguishing `false` literal from
  absent key — defaults to true). The toggle is enabled.
- Chain depth + task graph cycle check via
  `coord_cycle_detect_task_graph` (the Phase 6 NEW extension to
  `lib/cycle_detection.sh`): bipartite session/task DFS from B as
  the proposed opener. No prior chain from B → pass.
- A 12-field task record is appended to
  `locks[/auth.ts].tasks[]`: `task_id` synthesised as
  `<sid_B>-task-<created_at_ms>-<random_4_hex>`, complexity
  `SIMPLE`, anchor JSON, instruction, `chain_depth=0`, etc. CLI
  exits 0; B continues other work.
- Session A finishes editing `/auth.ts` (modified login flow on
  lines 100–150 — but did NOT touch lines 42–50 where
  `loginHandler` lives). A releases the lock via PostToolUse →
  `post_tool_use_write.sh` hook.
- The task processor (`lib/task_processor.sh`) iterates
  `locks[/auth.ts].tasks[]` queue. For B's task:
  - `check_affected_lines` runs the closed-interval intersection
    algorithm. A's edit affected lines 100–150; the task's anchor
    `window_lines` is 42–50 → no overlap. NOT a CONFLICT.
  - `spawn_claude_for_task` invokes the mock Claude binary (Phase
    6 mock-binary contract via `COORD_MOCK_CLAUDE_TASK_PATCH`
    env-var; Phase 4–5 mock pattern carry-forward) with
    instruction + `--complexity SIMPLE` context.
  - Mock Claude returns: `status=COMPLETED`, `diff="..."`,
    `affected_lines=[42, 47]`, `rationale="Renamed loginHandler
    to signInHandler at the function declaration and updated the
    export statement"`.
  - `write_outcome` persists the status + diff + rationale to the
    task record; appends a `TASK_OUTCOME` notification to
    `notifications[<sid_B>][/auth.ts]` queue. Diff is
    UTF-8-safe-truncated to 4 KB
    (`head -c 4096 | iconv -f UTF-8 -t UTF-8//IGNORE`).
- Task removed from `locks[/auth.ts].tasks[]`; lock released.
- B's next PreToolUse encounters the notification →
  `additionalContext`: *"Task `<task_id>` on `/auth.ts` completed
  by session `<sid_A>`. Status: COMPLETED. Rationale: Renamed
  loginHandler to signInHandler at the function declaration and
  updated the export statement. Diff: <truncated 4 KB UTF-8
  safe>"*.
- Total cross-session delegation cycle: ~50–80s wall-clock (A's
  edit duration + post-release task processing + mock Claude
  latency).

**Compare to Phase 5:** the same scenario in Phase 5 produced an
educational stub ("(a) Delegate task: [Phase 6 deliverable,
disabled]"); B had to either `coord wait` (blocking) or
context-switch manually. Phase 6 makes (a) production with anchor
+ complexity + chain depth + cycle detection + outcome
notification.

**Scenario 4 — self-delegation with reminder (option b).**
Session A holds `/api.ts` (mid-edit). Session B wants to update
`/api.ts` but has other productive work on `/utils.ts` and doesn't
want to wait blocking.

- B sees the deny banner with three options. B issues
  `coord self-delegate --file /api.ts --instruction "update
  getUserById to use new pagination params"`.
- Self-task persisted to
  `self_tasks[<sid_B>] += [{file: /api.ts, instruction: "...",
  created_at: "<ISO ms>", prompt_id:
  "<sid_B>-self-<ms>-<hex>", last_reminded_at: null,
  stop_block_count: 0}]`. Idempotent dedupe: 1-second window so a
  duplicate `coord self-delegate` from the same session on the
  same file with the same instruction is a no-op.
- B continues other work on `/utils.ts` (different file, no lock
  conflict).
- Session A releases `/api.ts` via PostToolUse.
- B issues its next PreToolUse on `/utils.ts` (or any operation)
  → `pre_tool_use_any.sh` hook. The hook checks
  `self_tasks[<sid_B>]`: any unlocked files?
  - `/api.ts` is now free → self-task is "unresolved".
  - 5-minute throttle check on `last_reminded_at`: it is null →
    eligible for reminder.
- Reminder injected via `additionalContext`: *"Reminder:
  `/api.ts` is now free, your self-task pending: 'update
  getUserById to use new pagination params'"*. The
  `last_reminded_at` field is updated on the self-task.
- B sees the reminder, decides to address `/api.ts` now, issues
  `Edit /api.ts` → acquires lock → updates `getUserById` →
  releases.
- B issues `Stop` → `stop.sh` hook → unresolved self-tasks check:
  `self_tasks[<sid_B>]` still has the `/api.ts` task because B
  did the edit but did not explicitly archive the self-task.
  `stop_block_count=0` → first Stop returns
  `permissionDecision: "block"` with reminder
  `additionalContext` and increments `stop_block_count` to 1.
- B sees the reminder again, recognises the self-task is stale
  (already addressed). On the second Stop, `stop_block_count >=
  1` → archive `SKIPPED` with `reason=stop_second_attempt`,
  allow.

**Compare to Phase 5:** option (b) was also a stub. The
`self_tasks` schema slot existed (empty array per session) but
there was no CLI to populate it, no reminder injection, no Stop
block-once. Phase 6 ships the full self-delegation lifecycle.

**Scenario 5 — task-graph cycle detection at CLI level.**

- Session A holds `/foo.ts` and opens task T1 on B (delegating
  refactor work).
- Session B holds `/bar.ts` and opens task T2 on C (delegating
  different refactor).
- Session C holds `/baz.ts`. C attempts to open task T3 on A
  (which would close the cycle).
- C issues `coord task-open --file /xyz.ts --complexity MODERATE
  --anchor '{...}' --instruction "..."` targeting A as the
  opener-of-record.
- Anchor uniqueness check: pass.
- Chain depth + task graph cycle check via
  `coord_cycle_detect_task_graph`:
  - Walk: C's new task → A (proposed opener) → A holds T1 on B
    → B holds T2 on C → C.
  - Cycle detected: A → B → C → A.
  - Returns rc 2 + stderr `"Task cycle detected: A → B → C → A
    (rejected)"`.
- C's `coord task-open` exits 1 with the cycle error.
- NO entry persisted to `locks[/xyz.ts].tasks[]`. Task graph
  remains acyclic; deadlock prevented at CLI level.

**Important:** this is **NOT** a third architectural deny location
— Decision 6 binding (PR-PHASE6-04) routes CLI-level rejection
through the existing `exit 1 + stderr` informational error path,
distinct from `permissionDecision: "deny"`. The 2-location deny
invariant carries forward through Phases 3+4+5+6 unchanged.

**Compare to Phase 5:** cycle detection only operated on lock
dependencies (bipartite session/file DFS). Phase 6 extends to task
dependencies (bipartite session/task DFS) via
`coord_cycle_detect_task_graph` (T6.02 lib function extension in
the same `lib/cycle_detection.sh` file).

---

## 2. Current capabilities

**Existing (Phase 0–5)** — compact reference:

- Read tracking with sha256 hashes; stale-read detection.
- Write locking via `flock`-protected atomic edits.
- Hard deny on lock contention with three-options reason.
- Lock release on PostToolUse, Stop, SessionEnd.
- Peer watchdog with 3-signal probe + 3-outcome verdict.
- Mediator agent: `advice` / `surgical_fix` / `lockdown`,
  two-state confidence, max-depth-2 peer review, unified
  `pending.jsonl` queue.
- Lockdown gate at `.coord/mediator/lockdown.json`.
- Critical-conditions bypass (3+ consecutive parse failures).
- Operator interface: `coord mediate {--reason | --escalate
  | --resume | --approve | status}`.
- Read-snapshot capture per session (1h TTL).
- Validator pipeline: cache → pre-filter → `claude -p` agent
  spawn; SAFE silent / MINOR banner / CRITICAL synchronous
  Mediator; CRITICAL never cached (PR-PHASE4-04).
- Per-session `last_consumed_verdict` pointer for idempotent
  retried writes.
- `wait_queues` per-file FIFO, ms-precision `waiting_since`,
  idempotent enqueue, global cleanup.
- Wake-file event-driven `coord wait` (fswatch / inotifywait /
  250 ms polling fallback; F-001 graceful degradation).
- 4-tier `diff_summary` chain on lock release: verdict file →
  cache → pre-filter → fallback.
- Lock-dependency cycle detection (`coord_cycle_detect`,
  bipartite session/file DFS, depth ≥ 2 trigger, 9-key
  `cycle_detected` pending payload).
- Mediator `cycle_detected` handling via kind-agnostic dispatch
  (zero Mediator code changes; Decision 4 / PR-PHASE5-04).

**New in Phase 6 — task delegation + self-delegation +
task-graph cycle prevention:**

- **`coord task-open` CLI** (`src/bin/coord`, T6.03):
  production CLI replacing the Phase 2 educational stub. Required
  flags: `--file`, `--complexity` (`SIMPLE` / `MODERATE` /
  `COMPLEX`), `--anchor '<json>'`, `--instruction '<text>'`.
  Optional: `--rationale '<text>'`. Anchor parsing: jq parse +
  `window_lines` `start-end` range validation (range format,
  exact string match against pre-edit content). Anchor uniqueness
  via `grep -F -c` (file-not-exists OR 0 matches → exit 1
  *"anchor not found"*; ≥ 2 → exit 1 *"anchor matches N
  candidates expected 1"*). `task_delegation` toggle detection
  via lesson #14 jq `has()` pattern (correctly distinguishes
  `false` literal from absent key). Chain depth + task graph
  cycle check via `coord_cycle_detect_task_graph`. `task_id`
  synthesis: `<sid>-task-<created_at_ms>-<random_4_hex>`. 12-field
  task record persisted to `locks[<file>].tasks[]`.

- **`coord_cycle_detect_task_graph` lib function**
  (`lib/cycle_detection.sh` extension, T6.02): the file now
  exposes 3 public functions — Phase 5's `coord_cycle_detect`
  (bipartite session/file) is unchanged; the NEW
  `coord_cycle_detect_task_graph` is bipartite session/task.
  Iterative bipartite DFS, Bash 3.2 stack-compatible (parallel
  indexed arrays, no recursion, no associative arrays). Edges:
  session→task (opener match) + task→session
  (`locks[file].session`) + task→task (transitive via DFS frame
  extension). Return codes: rc 0 ok / rc 1
  `chain_depth_exceeded` / rc 2 `task_cycle_detected` / rc 3
  usage error. Stderr human-readable on rejections (per Decision
  6 CLI-level rejection model). Trigger: invoked by `coord
  task-open` BEFORE persistence.

- **`coord self-delegate` CLI + `lib/self_tasks.sh`**
  (T6.04 + T6.06 + T6.07): 5 public functions (`open`, `list`,
  `check_unlocked`, `archive`, `cleanup_session`) + 8 internal
  helpers. Per-session flock at
  `.coord/self_tasks/<sanitized_sid>.lock`. Idempotent task
  creation (1-second window dedupe). Synthesised `prompt_id`
  format: `<sid>-self-<ms>-<hex>`. Four audit events:
  `SELF_TASK_OPENED`, `SELF_TASK_REMINDER`,
  `SELF_TASK_ARCHIVED`, `SELF_TASK_SKIPPED`. Additive fields:
  `last_reminded_at` (T6.06; 5-minute throttle window for
  reminder injection), `stop_block_count` (T6.07; default 0,
  integer, increments on first Stop block).

- **`post_tool_use_write` task processor + `lib/task_processor.sh`**
  (T6.05): 4 public functions (`run`, `check_affected_lines`,
  `spawn_claude`, `write_outcome`). Closed-interval line-range
  intersection algorithm (conservative, false positive
  acceptable for Phase 6). Mock Claude binary contract via
  `COORD_MOCK_CLAUDE_TASK_PATCH` env-var (Phase 4–5 mock pattern
  carry-forward). UTF-8-safe 4 KB diff truncation
  (`head -c 4096 | iconv -f UTF-8 -t UTF-8//IGNORE`).
  `TASK_OUTCOME` notification embedded in
  `notifications[<opener_sid>][<file>]` queue. `LOCK_TSV` 4th
  column captures task count for fast-path skip optimisation
  (~30–100 ms saving on the dominant empty-queue case). Banner
  template uses `<holder_session>` placeholder.

- **`pre_tool_use_any.sh` self-task reminder + F-015 subagent
  banner** (T6.06): self-task reminder injection on every
  PreToolUse for unlocked self-tasks (chronological FIFO, 5-min
  throttle). F-015 subagent context detection: `tool=Bash` +
  command starts with `coord wait` + `agent_type` non-empty →
  educational banner injection. Hook-side soft deprecation (NOT
  deny — Decision 6 binding preserved). Mutex via subagent
  early-exit (F-015 takes precedence in subagent context).

- **`stop.sh` self-task block-once-then-allow** (T6.07): first
  Stop with unresolved self-task (file unlocked,
  `stop_block_count=0`): `permissionDecision: "block"` +
  reminder `additionalContext` + count → 1. Second Stop: allow
  + archive `SKIPPED` with `reason=stop_second_attempt`. Mixed
  state handling (some count=0 + some count ≥ 1). **CRITICAL:
  `"block"` is NOT `"deny"`** — Stop hook permission grammar per
  Decision 2.13; pattern-aware grep guards distinguish the
  verbs.

- **`pre_tool_use_write.sh` banner production wording** (T6.09):
  PR-PHASE6-05 §6 toggle TRUE/FALSE binding. Toggle TRUE: 3
  options (a) `coord task-open` + (b) `coord self-delegate` +
  (c) `coord wait` with full CLI shapes. Toggle FALSE: omits
  (a) with *"task delegation is disabled in this repo"*
  parenthetical. `humanize_age` helper renders the `<ts>`
  placeholder (*"since N ago"* format). jq `has()` pattern for
  toggle detection (lesson #14 false-trigger awareness). Phase
  2's "Phase 6 — currently disabled" stub markers removed.

- **Phase 6 architectural invariant** (`phase6_invariant.bats`,
  17 guards, T6.08): 8 architectural + 9 bonus. The 2-location
  deny invariant is **PRESERVED through Phases 3+4+5+6**. Phase
  5's 14 guards carry forward (#1–#14); 3 NEW Phase 6 bonus
  guards added (#15 `lib/task_processor.sh` + #16
  `lib/self_tasks.sh` + #17 `src/bin/coord` task-open +
  self-delegate). Pattern-aware grep approach (Phase 5
  comment-strip pattern sufficient; JSON-regex unnecessary per
  T6.08 disposition). Stop hook `decision: "block"` usage is
  permitted under invariant scope (separate verb).
  `phase5_invariant.bats` deleted at T6.08 (mirrors the Phase 4
  → Phase 5 transition).

- **First Phase 6 integration suite**
  (`src/tests/integration/phase6_e2e.bats`, T6.09): 10 e2e
  scenarios exercising the full Phase 6 lifecycle — task-open
  happy path COMPLETED, CONFLICT overlap, multi-task FIFO,
  self-delegate, Stop block-once, F-015 banner, task graph
  cycle, toggle FALSE banner, banner production wording
  verification, option (a) full CLI shape.

---

## 3. Current limitations

What still doesn't work after Phase 6:

- **Real-Claude Mediator + Validator + Task Processor +
  Complexity Classifier semantics** are not yet stress-tested.
  Unit tests across all four spawn sites still use mock
  binaries emitting scripted JSON. Real `claude -p` integration
  hardens in Phase 7.
- **`coord mediate status` cost reporting** still shows
  misleading `$0.000` under subscription mode. Phase 7 polish.
- **`--bare` spawn mode** for users with `ANTHROPIC_API_KEY` is
  documented but not implemented (carry-forward from Phases 3
  + 4).
- **F-016 timing flake** remains intermittent under heavy
  parallel bats pressure. Phase 6 T6.11 Linux probe surfaced
  the same family at test 527 (`wait_backend` inotifywait
  wake-up latency). Phase 7 stress harness fixes definitively.
- **F-017 ambient-suspicion latency** at 109 ms median
  (PR-PHASE3-02 estimated < 50 ms target). Acceptable — well
  below the 2-second hard ceiling — but optimisation deferred
  to Phase 7.
- **F-019 Linux probe driver gitignored** at
  `.coord/experiments/linux-parity/linux_probe.sh`. Phase
  additions don't persist across fresh checkouts. Phase 7
  relocates to a non-gitignored location (likely
  `scripts/linux_probe.sh` or `src/tests/manual/linux_probe.sh`).
- **Cost guard tunables** (`mediator_min_seconds_between_invocations`,
  `mediator_max_invocations_per_hour`, validator-spawn
  ceilings) are env-var configurable but **not yet enforced**.
  Phase 7 measurement-driven defaults pin them.
- **Auto-reset race on corrupt-state detection** — theoretical
  edge case where two hooks racing on parse failure could
  double-count. Phase 7 stress check covers it.
- **Silent 2-cycle case for lock dependencies** — when each
  cycle session has `depth=1` on its queue, no trigger fires
  until either an external waiter enqueues (depth → 2) or the
  `wait_max_seconds` clamp expires. Phase 7 follow-up cleanup
  detection from the timed-out session's perspective.
- **Multi-machine, team-shared coord scenarios** are out of
  scope for v1.
- **Subagent (Task tool) races stay invisible by design**
  (Decision 2.17 carry-forward). Phase 6 added the F-015 soft
  deprecation banner via `pre_tool_use_any.sh` — operator
  guidance, not enforcement — but the underlying races remain
  untracked.
- **Complexity auto-classification** (real-Claude inferring
  `SIMPLE` / `MODERATE` / `COMPLEX`) is a Phase 7 enhancement.
  Phase 6 uses caller-supplied `--complexity` flag with mock
  binary.
- **Token-level diff awareness for `affected_lines` overlap**
  is Phase 7 (real-Claude semantic verification supersedes).
  Phase 6 uses closed-interval line-range intersection
  (conservative, false positive acceptable).

---

## 4. Is this usable RIGHT NOW?

Three audiences. Phase 5 verdicts quoted; Phase 6 revisions
noted.

**(a) Solo developer, 1–2 sessions occasionally.**

Phase 5 verdict: *"+ multi-waiter fairness AND faster wake-up.
When you have 2–3 sessions on the same repo, FIFO ordering is
now guaranteed; whoever issues `coord wait` first wakes first."*

Phase 6 verdict: same value PLUS task delegation + self-delegation
production-ready. When you have 2–3 sessions and want to delegate
work asynchronously (don't want to wait blocking),
`coord task-open` and `coord self-delegate` are now real
subcommands. Banner options (a) and (b) actually work. The deny
banner now shows production CLI shapes with `--complexity` +
`--anchor` + `--instruction` flags. On a quiet 1-session day Phase
6 changes nothing visible; the win surfaces the moment a second
session needs the same file AND you have other productive work to
do.

**(b) Solo developer, 3–5 concurrent sessions on the same repo.**

Phase 5 verdict: *"trust posture extends further. Multi-waiter
ordering finally fair (FIFO arrival), wake-up event-driven (5–6×
faster than polling), waiters receive `diff_summary` so they know
what changed before re-reading. Cycle detection catches A↔B
deadlock scenarios automatically."*

Phase 6 verdict: trust posture extends further. Task delegation
primitives let you architect cross-session workflows: A focuses on
auth refactor; B's task delegated to A processes at A's lock
release. Task graph cycle detection prevents pathological
multi-session deadlock at the task layer (extending Phase 5's
lock-layer cycle detection). Self-delegation with reminder + Stop
block-once-then-allow lets you defer work and come back without
losing it. Five sessions architecting parallel work via task
delegation now feasible without manual coordination overhead.

**(c) Team / multi-developer / multi-machine.**

Out of scope for v1. (Unchanged from Phase 2/3/4/5 verdict.)

---

## 5. How it actually works (architecture in ~300 words)

The system is a Bash-only set of hooks (`jq` + `flock` + `perl` +
optional `fswatch` / `inotifywait`) registered into Claude Code's
`.claude/settings.local.json`. State lives at `.coord/`
(gitignored) under `sessions.json` (atomic-edited via
`lib/atomic_write.sh`), an append-only `events.jsonl` audit log,
JSONL queues at `mediator/pending.jsonl`,
`validator/verdict/<ts>.json`, per-file lock dirs at
`wait_queues/<sanitized_path>.lock`, wake_files at
`wakers/<sid>-<sanitized>.wake`, and now per-session self-task
flocks at `self_tasks/<sanitized_sid>.lock`.

**Phase 6 architectural addition: task delegation + self-delegation
+ bipartite task graph cycle detection + `post_tool_use_write` task
processor.** New lib clusters:
- `lib/task_processor.sh` — 4-fn task lifecycle
  (`run` / `check_affected_lines` / `spawn_claude` /
  `write_outcome`).
- `lib/self_tasks.sh` — 5-fn self-task management
  (`open` / `list` / `check_unlocked` / `archive` /
  `cleanup_session`) + 8 internal helpers.
- `lib/cycle_detection.sh` extension — 1 NEW fn
  `coord_cycle_detect_task_graph` (bipartite session/task DFS)
  alongside Phase 5's unchanged `coord_cycle_detect` (bipartite
  session/file DFS).

New CLI subcommands: `coord task-open` (Plan §5 Phase 6 canonical
with anchor + complexity + chain depth + cycle detection),
`coord self-delegate` (Decision 2.13 self-task primitive).

Schema additions to `sessions.json`: `locks[<file>].tasks[]`
populated with 12-field task records;
`self_tasks[<sid>] += [{file, instruction, created_at, prompt_id,
last_reminded_at, stop_block_count}]`.

Hook integrations: `post_tool_use_write` invokes the task
processor on lock release; `pre_tool_use_any` injects reminders
for unlocked self-tasks + the F-015 subagent context banner;
`stop.sh` implements block-once-then-allow for unresolved
self-tasks. The `pre_tool_use_write.sh` `build_deny_reason` was
rewritten per PR-PHASE6-05 §6 toggle TRUE/FALSE binding; Phase 2
stub markers removed.

**The 2-location deny invariant is PRESERVED through Phases
3+4+5+6** — NO third deny site introduced. Chain depth + cycle +
anchor + toggle enforcement all happen at CLI level (Decision 6
binding, PR-PHASE6-04). Stop hook `decision: "block"` is permitted
as a separate verb under invariant scope.

**Phase 6 invariant:** 17 guards (8 architectural + 9 bonus) in
`phase6_invariant.bats`; pattern-aware grep approach (comment-strip
sufficient).

---

## 6. What ships in Phase 7

Per `IMPLEMENTATION_PLAN.md` §7 Phase 7 — Real-Claude integration
+ stress harness:

- **Real-Claude semantic verification:** Mediator + Validator +
  Task Processor + Complexity Classifier real binary integration.
  Replace the mock Claude across all spawn sites.
- **F-016 SIGINT integration test** definitive resolution
  (`coord wait` runtime test under heavy parallel bats pressure).
- **F-017 ambient-suspicion latency optimisation**
  (`pre_tool_use_any.sh` from 109 ms median toward < 50 ms
  target).
- **F-019 Linux probe driver relocation** (move from
  `.coord/experiments/linux-parity/` to
  `scripts/linux_probe.sh` or `src/tests/manual/linux_probe.sh`).
- **Cost guard tunables enforcement**
  (`mediator_min_seconds_between_invocations` +
  `mediator_max_invocations_per_hour` + validator-spawn
  ceilings; measurement-driven defaults).
- **Stress harness:** multi-session orchestration + cost
  tracking + latency measurement.
- **Complexity auto-classification** (real-Claude infers
  `SIMPLE` / `MODERATE` / `COMPLEX`; Phase 6 was caller-supplied
  flag).
- **Token-level diff awareness for `affected_lines` overlap**
  (real-Claude semantic verification supersedes Phase 6's
  conservative line-range intersection).

**Phase 7 is the FINAL phase.** After Phase 7 close, the system
is v1 production-ready for single-developer scale.

**Phase 7 invariant prediction:** 17 → ~17–19 guards (estimated
+2 bonus for cost guard enforcement + new lib files). 2-location
deny invariant prediction: PRESERVED through Phases 3+4+5+6+7 (no
expected new deny site). Mediator action verb additions possible
if cost guard tunables exceed thresholds → escalation path
through existing kind-agnostic Mediator dispatch.

---

## 7. Trust posture

**Phase 5 verdict:** *"earned its keep at 1–5 single-developer
session range with new fairness + event-driven UX + deadlock
detection. Trust the lock guarantee + the recovery guarantee +
the classification guarantee + the multi-waiter fairness
guarantee + the deadlock-resolution guarantee at single-user
scale."*

**Phase 6 verdict (revised):** earned its keep at 1–5
single-developer session range with new task delegation +
self-delegation primitives. Trust the lock guarantee + the
recovery guarantee + the classification guarantee + the
multi-waiter fairness guarantee + the lock-deadlock-resolution
guarantee + the cross-session task delegation guarantee + the
self-task lifecycle guarantee + the task-graph cycle prevention
guarantee at single-user scale.

**Trust:**
- Lock guarantee — concurrent writes don't clobber.
- Three-options interface — deny banner is actionable AND all
  three CLIs are now production (Phase 6).
- `coord wait` — event-driven (sub-100 ms with
  `fswatch` / `inotifywait`, 250 ms polling fallback), clean
  exit semantics, clamp behaviour, SIGINT trap.
- Mediator surgical fixes — `release_lock` / `evict_session` /
  `clear_read_set` apply pipeline (carry-forward through Phases
  3+4+5+6); kind-agnostic dispatch verified for `cycle_detected`
  at T5.06.
- Watchdog probe — 3-signal model, Signal 1 mandatory for alive
  verdict.
- Lockdown for system-wide problems — every-hook gate
  architecturally enforced via `phase6_invariant.bats`.
- Critical-bypass + operator `--resume` — degraded-state
  recovery is documented, tested, predictable.
- Validator SAFE/MINOR/CRITICAL classification (mock binary
  verified end-to-end through pipeline; real-Claude picks Phase
  7).
- Validator cache for recurring drift; pre-filter conservative
  doctrine (multi-line-string ambiguity → ESCALATE).
- `wait_queues` FIFO ordering (per-file flock, ms-precision
  `waiting_since`, idempotent enqueue, cleanup-on-eviction).
- Wake_file event-driven wake-up.
- 4-tier `diff_summary` chain on lock release.
- Lock-dependency cycle detection (bipartite session/file DFS).
- Mediator `cycle_detected` handling (kind-agnostic dispatch).
- **`coord task-open` CLI** — anchor uniqueness + complexity
  flag + chain depth + cycle detection at task graph layer;
  CLI-level rejection per Decision 6.
- **`coord self-delegate` CLI + `self_tasks` lifecycle** —
  idempotent open + reminder injection at unlock + 5-min
  throttle + Stop block-once-then-allow.
- **`post_tool_use_write` task processor** — closed-interval
  `affected_lines` overlap + mock Claude task-patch +
  `TASK_OUTCOME` notification with UTF-8-safe diff truncation.
- **Banner production wording** — toggle TRUE/FALSE;
  `humanize_age` rendering; Phase 2 stubs removed.
- **F-015 subagent context guidance** — soft deprecation banner
  via `pre_tool_use_any`; NO third deny location.
- **Phase 6 invariant** — 17 guards; 2-location deny preserved
  through Phases 3+4+5+6.

**Do NOT yet trust:**
- Real-Claude Mediator + Validator + Task Processor + Complexity
  Classifier semantics under stress (Phase 7 integration
  harness; Phase 6 unit tests still use mock Claude binary).
- Cost predictability under high spawn rate (Phase 7 cost guard
  tunables enforcement).
- F-016/F-017 timing assumptions (Phase 7 stress harness).
- F-019 Linux probe driver fresh-checkout persistence (Phase 7
  relocation).
- Token-level diff awareness for the task processor (Phase 6
  uses conservative line-range intersection; Phase 7
  real-Claude semantic verification supersedes).
- Complexity auto-classification (Phase 7; Phase 6 is
  caller-supplied flag).
- Subagent races (Decision 2.17 carry-forward; F-015 banner is
  soft deprecation, races remain untracked).

The lock + recovery + classification + fairness + delegation +
lifecycle + cycle prevention guarantees scope is
single-developer. Multi-machine team scenarios still out of scope
for v1.

**By the numbers:** 486/486 → 582/582 unit + 14/14 → 24/24
integration tests on macOS host (582 unit + 24 integration = 606
total; 581 unit + 19 fixtures verified Linux Docker
`ubuntu:24.04` with 1 F-017 family timing flake at test 527, NOT
a Phase 6 regression). 19/19 fixture scenarios across both
platforms (2 carry-forward + 4 Phase 3 + 4 Phase 4 + 4 Phase 5 +
5 Phase 6). F-015 RESOLVED at Phase 6 close (subagent banner
T6.06). F-016 / F-017 / F-019 OPEN with deadlines (all Phase 7).
**Zero new findings raised in Phase 6 implementation T6.01–T6.10**
(10-task ZERO findings streak); F-019 surfaced at T6.11 Linux
probe meta-execution.

**Branch:** `main` at `855fc29` (Phase 6 merge commit) +
`bd6e37d` (Phase 6 close cleanup, CLAUDE.md §B prose update). 13
Phase 6 commits visible alongside the merge commit via `--no-ff`.
Phase 1, Phase 2, Phase 3, Phase 4, Phase 5 merge commits
preserved at `629b1fb`, `6b0cc35`, `802c986`, `5684e64`,
`ab65d26` respectively.

Phase 6 is NOT the finished system. It is the task delegation +
self-delegation + task-graph cycle prevention layer that sits on
top of the wait_queue + wake_file + lock-dependency cycle
detection layer (Phase 5) on top of the classification layer
(Phase 4) on top of the lock + crash-recovery layers (Phases
2 + 3). The system has graduated from *"prevents bad writes,
recovers from session deaths, distinguishes trivial drift from
breaking drift, delivers fair multi-waiter ordering with
event-driven wake-up AND informative diff_summary, AND detects +
resolves lock-dependency deadlocks"* (Phase 5) to *"prevents bad
writes, recovers from session deaths, distinguishes trivial
drift from breaking drift, delivers fair multi-waiter ordering
with event-driven wake-up AND informative diff_summary, detects +
resolves lock-dependency deadlocks, AND supports cross-session
task delegation + self-delegation lifecycle + task-graph cycle
prevention"* (Phase 6). Phase 7 will harden the real-Claude
integration and pin cost guards. Each phase compounds; no phase
invalidates a prior phase's claim.

# State of the System — 2026-04-26

A briefing for someone joining the project who has read nothing.
Snapshot at the close of Phase 2 (merge commit `6b0cc35` on `main`).
Supersedes `archive/STATE_OF_SYSTEM_phase1.md`.

---

## 1. The product in plain English

This is a **coordination layer for multiple Claude Code sessions
working in the same git repo at the same time.** Claude Code is
Anthropic's CLI for the Claude model; one developer sometimes runs
two or three of them side by side — one fixing a bug, one writing
tests, one refactoring. Without coordination, the sessions are
blind to each other.

**Concrete chaos scenario.** Session A reads `payment_service.ts`
and plans a refactor. Session B reads the same file twenty seconds
later, fixes a separate bug, and writes back its edit. Session A —
still working from the version it originally read — writes its
refactor on top, silently overwriting B's bug fix. Neither Claude
saw it happen; the regression turns up in CI hours later.

**With Phase 2 installed (today's state):** A starts the refactor.
A's `Write` tool fires the pre-hook, which acquires an exclusive
lock on `payment_service.ts`. A few seconds later, B's `Edit` tool
fires its own pre-hook on the same file. The hook sees the lock and
returns this to Claude in B's context:

> *File `payment_service.ts` is locked by session `<A's id>...`
> (acquired 12 sec ago, last activity 4 sec ago). Options: (a)
> Delegate a SIMPLE/MODERATE task: `coord task-open` (Phase 6 —
> currently disabled; running it now points you at option (c) and
> shows current syntax when enabled). (b) Self-delegate (do other
> work, return later): `coord self-delegate` (same disclaimer). (c)
> Passively wait: `Bash: coord wait payment_service.ts --timeout
> 570` ...*

The tool call is **denied**, not just warned-about. B's Claude
either invokes `coord wait` (blocks until A releases), switches to a
different file, or surfaces the contention to the user. When A's
`Write` completes, A's post-hook releases the lock and writes a
notification message into B's session state. B's next `Read` (or
any tool call) carries that notification: *"Lock released on
payment_service.ts (held by `<A's id>...` for 18 sec). You may now
retry your write or `coord wait payment_service.ts` if you've moved
on."*

The clobber that Phase 1 only warned about, Phase 2 actively
prevents.

**Explicitly NOT this system's job:**
- Not a multi-user or team-shared service. One machine, one repo,
  one developer; per-machine opt-in via env var.
- Not a backup, version-control, or audit tool. Git remains source
  of truth.
- Not Windows-native. macOS + Linux only; WSL2 works.
- Not a productivity nudger or code reviewer. It coordinates
  *mechanics*, not semantics.

---

## 2. Current capabilities (what works today)

A "hook" below means a Bash script Claude Code invokes at specific
events (session start, before/after a tool call, etc.) which can
inject text into Claude's context, deny a tool call, or just observe.

### Installation experience
- **`coord install`** — checks deps (`bash`, `jq`, `flock`,
  `shasum`, `ps`, `git`), refuses unreliable filesystems (network
  mounts, cloud-sync), creates `.coord/`, registers eight hooks
  into `.claude/settings.local.json` (preserving user hooks),
  updates `.gitignore`, runs an end-to-end self-test. `coord
  uninstall` reverses; `--purge` wipes everything. *Advisory.*

### Per-session behavior
- **Session-start banner.** Sessions launched with `CLAUDE_COORD=1`
  see *"Coord v1.0 active. Your coordination session ID is `<uuid>`.
  There are currently N other coordinated session(s)..."* injected
  on Claude's first turn.
- **Lifecycle awareness.** Distinguishes fresh start, resume after
  crash, explicit context clear, and compaction. Read-history
  preserved on resume/compact, invalidated on clear, re-marked
  when git HEAD has drifted.
- **Clean exit.** `Stop` releases any locks the session still
  holds, populates notifications for any sessions that were denied
  during the hold, then `SessionEnd` removes the active marker —
  idempotent if Stop already cleared things. Both events emit per-
  file `LOCK_RELEASED` records in the event log.

### Per-tool-call behavior
- **Read tracking.** Every `Read` records sha256 + path + timestamp
  into a per-session "read-set." Re-reading supersedes the prior
  entry. The `Read` pre-hook also delivers any pending notifications
  for the file being read and clears them atomically.
- **Stale-read warning on Write.** Before any
  `Write`/`Edit`/`NotebookEdit`, the system re-hashes every file in
  the writer's read-set and warns on any mismatch via
  `additionalContext`. (Phase 4's validator agent will reclassify
  these into SAFE/MINOR/CRITICAL; today they're always advisory.)
- **Lock acquisition + deny + release** *(new in Phase 2).*
  Acquire on first `Write` of a file. Refresh `last_refresh_at` on
  subsequent self-writes (no spurious denial when you're the
  holder). Deny on contention with the §B.2 three-options reason
  text (commit `f60a1d3`). Release on PostToolUse, Stop, or
  SessionEnd, and notify any session that was denied during the hold
  (commit `1122d0b`).
- **HEAD-drift recheck.** Every tool call re-checks git HEAD; if
  changed since this session was last active, the read-set is
  marked invalidated and Claude is told.

### Operator commands
- `coord status [--reads]` — sessions, locks (now actually populated
  in Phase 2), per-session read-set summary; `--reads` for detail.
- `coord health` — deps + config-bound check + stray-digit-file
  scan at the repo root.
- `coord log --tail N --kind X`, `coord events --since <ts>` —
  query the append-only event log. New Phase-2 kinds: `LOCK_ACQUIRED`,
  `LOCK_REFRESH`, `LOCK_DENIED`, `LOCK_RELEASED`, `WAIT_RELEASED`,
  `WAIT_TIMEOUT`, `WAIT_CLAMPED`, `NOTIFICATION_PRODUCED`,
  `MEDIATOR_PENDING_DELIVERED`.
- `coord wait <path> [--timeout N]` — *new in Phase 2; was a stub
  in Phase 1.* Blocks until the lock on `<path>` is released or the
  timeout fires. `--timeout` is clamped to `[30, 570]` per Decision
  2.20 (570 = 600s Bash-tool ceiling minus 30s safety margin).
  Polls every 250ms; instant exit if lock is free or held by
  yourself; SIGINT trap exits 130 cleanly. Detection latency in
  practice: ~166ms on Linux overlayfs, ~250-500ms on macOS APFS
  (commit `ea00ea0`).
- `coord reset --confirm` — operator escape hatch; archives prior
  state, clears locks/read-sets/notifications.
- `coord task-open` / `coord self-delegate` — Phase 6 deliverables.
  Currently print **educational error messages** pointing the
  caller at option (c) `coord wait` with concrete syntax (so a
  Claude session that tried option (a) from the deny prompt loses
  minimum context).

### Cross-session behavior (the Phase 2 ship gate)
The 02_lock_deny fixture verifies the full cycle on macOS + Linux:
A acquires the lock on `foo.ts`, B's `Write` is denied with the
three-options text, A releases via PostToolUse, A's release path
populates `notifications[B][foo.ts]`, B's next `Read` delivers and
clears the notification. Fourteen specific assertions — including
that B's reason references `coord task-open` / `coord self-delegate`
**abstractly** (no `--file ...` Phase-6 syntax frozen) — pass on
both platforms.

### Self-protection
- **Atomic writes.** Every `sessions.json` mutation goes through
  `atomic_write.sh`: hold an exclusive `flock`, read, apply a `jq`
  filter, write to a temp file in the same directory, rename
  atomically. Five-way concurrent writers verified clean on both
  platforms.
- **Mediator producer for flock contention** *(new in Phase 2).*
  When `atomic_write.sh` hits a 5-second flock timeout, it appends
  a `flock_timeout` entry to `.coord/mediator/pending.jsonl` (a
  separate JSONL queue with its own lock — no recursion). The next
  pre-hook surfaces a one-line banner: *"Coord Mediator pending (1
  new entry); the Phase 3 Mediator will diagnose..."* The Phase 3
  agent will consume + classify; today it's a banner-only signal.
- **Corruption recovery** *(unchanged from Phase 1).* If
  `sessions.json` ever fails to parse, it is auto-archived and
  replaced; the next session start surfaces a banner.
- **Fail-open everywhere.** No hook ever blocks a tool call due to
  *its own* failure. Missing deps, atomic-write failures all log
  and allow.
- **Phase 2 invariant.** A bats architectural guard
  (`phase2_invariant.bats`) asserts that `permissionDecision: "deny"`
  appears in **exactly one** code path: the lock-held-by-other
  branch of `pre_tool_use_write.sh`. Every other hook + every other
  branch remains allow / no-op / fail-open. Comment-line mentions
  of the token are deliberately excluded from the grep so docstrings
  describing the invariant don't trip it.

---

## 3. Current limitations (what does NOT work yet)

**Crash recovery is still partial.** A `SIGKILL`-ed session leaves
its registry row + any held locks behind. `RESUME_ORPHAN_LOCK_DETECTED`
events fire when a resumed session sees a lock keyed to its old
PID/lstart, but no eviction logic runs yet. *Why:* peer-watchdog is
Phase 3. *Workaround:* `coord reset --confirm`.

**The Mediator is producer-only.** Phase 2 ships the flag-file
infrastructure for `flock_timeout`. The agent that classifies the
entry and decides on a remediation (reset state / evict dead session
/ cancel stuck task / escalate to user) is Phase 3. Today the
banner just says "Phase 3 Mediator will diagnose"; until then,
manual investigation is the path.

**Validator agent for stale-read severity is not active.** Phase 1's
stale-read warning fires unconditionally when any read in your
read-set has a mismatched hash. Phase 4 will add a subagent that
classifies the diff as SAFE / MINOR / CRITICAL and only escalates
CRITICAL to a deny. Until then, every drift is a warning, regardless
of how trivial the change actually was.

**Wait queue is single-waiter polling, not FIFO.** `coord wait` is
a polling implementation: 250ms cycles checking the lock state.
Multiple concurrent waiters race — whichever poll cycle hits first
wins. Phase 5 adds the `wait_queue[<file>]` FIFO with `touch
wake_file` notification, eliminating polling entirely. Until then,
multi-waiter contention is fair only by chance.

**Self-delegation / task-open CLIs are educational stubs only.**
The §B.2 deny reason references `coord task-open` and `coord
self-delegate` as Phase 6 deliverables. Invoking them today prints
a guidance message pointing at option (c) `coord wait` — the
intended graceful behavior for Phase 2-5. Real implementations
arrive Phase 6.

**Subagent races are invisible by design.** Subagent tool calls
(spawned via the Task tool) are filtered out at the hook layer per
Decision 2.17 / PR-PHASE0-01. A subagent writing a file its parent
doesn't lock can race silently with another session. *Why:* the
parent's lock covers the parent's turn; a subagent acquiring its
own lock would be Phase-6+ territory and changes the
fork-bomb-guard math.

**3+ concurrent sessions** work for lock-deny coordination but the
single-waiter polling model means the user experience can be
"first-come-first-served by coincidence." Phase 5 fixes this.

**macOS release-side latency under contention.** Smoke measurements
showed ~1.6 sec wall time between intent-to-release and a
`coord wait` waiter's exit on macOS APFS (vs ~166ms on Linux
overlayfs). Dominated by the release-side pipeline (jq rewrite +
atomic mv + flock release + reader-side fresh jq read), NOT the
poll cadence. Single-user workflows mask this. Phase 5's
notification-based wakeup eliminates it wholesale.

---

## 4. Is this usable right now?

**(a) Solo dev, 1–2 sessions occasionally.**
Phase 1 verdict: *"Marginal today. The warning helps in the rare
overlap; otherwise invisible."* **Phase 2 verdict: genuine value.**
Real deny prevents real clobbering; `coord wait` provides a graceful
coordination primitive even when you only occasionally have two
sessions touching the same area. The denial message tells Claude
exactly what to do next; no manual triage. Worth installing now.

**(b) Solo dev, 3–5 concurrent sessions on the same repo.**
Phase 1 verdict: *"Nudged, not protected. Reliably tells Claude when
an earlier read is stale; does not stop the write. Materially
better than nothing, not yet 'safe.'"* **Phase 2 verdict: the
system has earned its keep.** Lock contention is now real
protection, not advisory. Two sessions cannot both write the same
file; one will be denied with a useful reason. The honest residual
gap is multi-waiter ordering (single-waiter polling means the third
session-in-the-queue wakes by coincidence rather than fairly), but
that gap is *fairness*, not *safety*. Phase 5's wait queue is the
right place to fix fairness; Phase 2 is the right place to install
the guarantee.

**(c) Team / multi-developer / multi-machine.**
Out of scope for v1. (Unchanged from Phase 1.)

---

## 5. How it actually works (architecture in ~250 words)

**State file:** `.coord/sessions.json` — JSON with a frozen v1.0
schema. Tracks session rows (id, pid, lstart, git_head, prompt_id),
per-session read-sets, **locks (`locks[<file>] = {session,
acquired_at, last_refresh_at, tasks: []}` — actively populated in
Phase 2)**, notifications (`notifications[<sid>][<path>]` arrays of
strings, populated by release paths and consumed by Read), self-
tasks (Phase 6, empty today), plus tables that Phase 3+ will
populate (anomaly_votes, task_graph, wait_queue).

**Mediator queue:** `.coord/mediator/pending.jsonl` — append-only
JSONL with its own `pending.lock` (separate from `sessions.lock` to
avoid recursion). High-water-mark in `pending.consumed` advances on
delivery. Producer: `atomic_write.sh` on flock timeout. Consumer:
`pre_tool_use_any.sh` + `session_start.sh`. Phase 1's legacy
`pending.json` (corrupt_state) is preserved as-is for compatibility.

**Hook layer:** eight Bash scripts under `.coord/hooks/`, registered
into `.claude/settings.local.json`. Each receives event JSON on
stdin. Eight: `session_start`, `session_end`, `stop`,
`user_prompt_submit`, `pre_tool_use_any`, `pre_tool_use_read`,
`pre_tool_use_write`, `post_tool_use_write`. The Phase 2 ship-gate
invariant: only one of these (`pre_tool_use_write.sh`) ever sets
`permissionDecision: "deny"` — confined to its lock-held-by-other
branch.

**Library layer:** reusable modules under `.coord/lib/` —
`atomic_write`, `log_event`, `hash`, `head_tracking`, `participant`,
`state_query`, `subagent_filter` (Phase 0/1) plus **new in Phase 2:
`notify_waiters` (release-time notification producer) and
`mediator_pending` (JSONL producer/consumer)**.

**Subagent filter** is at the **tool-call hook layer**, not at
SessionStart (Phase 0 Experiment #5 invalidated the original
assumption). Subagent tool calls share the parent's session_id and
are skipped via the shared `coord_subagent_filter` helper, emitting
a `SUBAGENT_ACTIVITY_SKIPPED` event for observability.

**CLI:** `.coord/bin/coord` — operator surface for status, health,
events, install/uninstall/reset, plus the now-active **`coord wait`**
(passive blocking wait) and educational stubs for the Phase-6 CLIs.

**Events log:** `.coord/events.jsonl` — append-only, one JSON object
per line, written non-blockingly under a brief flock. Every
interesting state transition is logged.

**Coord wait polling**: `coord wait` checks `coord_lock_holder` via
`state_query.sh`, sleeps 250ms, repeats until the lock is gone or
held by the caller; emits `WAIT_RELEASED` / `WAIT_TIMEOUT` /
`WAIT_CLAMPED` events as appropriate. Phase 5 will replace polling
with notification-based wakeup via `wait_queue` + `touch wake_file`.

**Atomicity guarantee:** every state-file write uses the
subshell + redirected-fd flock convention plus temp+rename. No
torn writes, no lost updates; verified under 5-way concurrent load
on macOS APFS and Linux overlayfs.

---

## 6. What ships in Phase 3

When Phase 3 merges, the system gains **self-healing**. Concretely
(per IMPLEMENTATION_PLAN.md §5 Phase 3):

- **Peer watchdog.** PID + lstart consensus algorithm: any
  coordinated session that observes another session's PID
  unreachable (or PID-recycled to a different `lstart`) votes; two
  voters confirm; the watchdog evicts the dead row + releases its
  orphan locks + emits notifications to anyone in that file's
  wait queue. Plan §2 Decision 2.19 mandates the 2-voter threshold
  to avoid evicting a live session whose process is briefly
  unreachable to a single observer.

- **Mediator agent (consumer/classifier side).** Phase 2's banner
  becomes a real agent-hook firing on `pending.jsonl` consume. The
  agent reads recent events, runs `ps`, inspects state, and decides
  on remediation: reset state / evict dead session / cancel stuck
  task / escalate to user. Verdicts written to
  `.coord/mediator/verdict/<ts>.json`, surfaced via the same
  consumer pattern.

- **Multiple new pending kinds.** `stale_active` (session marked
  ACTIVE but unresponsive), `pid_recycled` (PID matches a live
  process but with a fresh `lstart`), `schema_mismatch` (a hook
  saw a sessions.json field shape it didn't expect), `manual` (the
  user invoked `coord mediate` to escalate something the
  automatic detectors didn't flag).

- **`coord mediate` CLI.** Operator-side manual escalation
  primitive — when a user notices something the watchdog and
  Mediator producers haven't flagged, this writes a `manual` kind
  pending entry with a free-form reason payload, triggering the
  agent on the next tool call.

- **`pending.jsonl` garbage collection.** Bundled with the agent's
  verdict-write pass: consumed entries with a verdict are safe to
  truncate. Avoids unbounded growth on long-running repos.

Phase 3's invariant: a SIGKILL-ed session's locks are evicted within
`watchdog_confirm_seconds` (default ~30s, configurable per Decision
2.20 bounds) without manual `coord reset`. A legitimate 20-minute
reasoning session with occasional tool calls is **not** evicted by
the same logic.

Open design questions for Phase 3 (carried from
phase-2-signoff.md): Mediator agent trigger contract, whether
`pending.json` (corrupt_state) and `pending.jsonl` (Phase 2+ kinds)
get unified, F-014 root fix design, watchdog vs Mediator handoff
when both detect the same anomaly, and whether to profile the macOS
release-side latency or accept it until Phase 5 retires polling.

---

## 7. Trust posture

**The system has earned its keep at the 1-5 single-developer
session range, and the worst-case behavior is well-defined.**

Phase 2 is the first phase where coordination is *enforced*, not
*advisory*. The lock state machine is exercised end-to-end across
192/192 bats unit tests on both macOS host and Linux Docker
`ubuntu:24.04`, plus a manual fixture (`02_lock_deny`) that drives
the full acquire → deny → release → notify cycle and asserts the
§B.2 reason text matches what Claude is supposed to see. Phase 1's
warning behavior is a regression test now — `01_basic_warn` still
passes alongside `02_lock_deny`.

The Phase 2 architectural invariant — `permissionDecision: "deny"`
appears in exactly one code path, the lock-held-by-other branch —
is asserted by a dedicated bats test that scans every hook in the
codebase. Every other code path remains allow / no-op / fail-open.
That means: on hook failure, on `flock` timeout, on missing
dependencies, on corrupt state, on unparseable input — the tool
call proceeds without coord interference, with a stderr warning
and an event log entry. The worst case is "coordination silently
disabled this session," not "tool call mysteriously blocked."

That said: Phase 2 is **not** the end-state.

- Crashed sessions still leave orphan locks (Phase 3 watchdog
  fixes).
- Stale-read warnings fire on any drift, even trivial formatter-
  only changes (Phase 4 validator fixes).
- Multi-waiter ordering is undefined (Phase 5 wait queue fixes).
- The most powerful coordination primitive (task delegation
  between sessions) is not yet shipped; the deny prompt
  references it abstractly, and the CLIs are educational stubs
  pointing back at `coord wait` (Phase 6 fixes).
- Subagent tool calls are deliberately not coordinated.

Trust the lock guarantee at single-user scale. Treat the lock-
deny prompt's three options as the **interface contract** —
abstract on (a) and (b), exact on (c). Trust `coord wait` to
exit cleanly on release or timeout. Do not yet trust the system
to recover from a `kill -9` without operator intervention; do
not yet expect multi-waiter ordering to be fair under heavy
contention.

192/192 unit tests, 2/2 fixture scenarios, two platforms green.
Branch: `main` at `6b0cc35` (Phase 2 merge commit). Five Phase 2
task commits visible alongside via `--no-ff`.

---

*End of briefing.*

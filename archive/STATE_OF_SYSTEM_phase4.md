# State of the system — end of Phase 4

**Date:** 2026-04-26 · **Branch:** `main` at `5684e64` (Phase 4 merge)
· **Bats:** 390/390 PASS macOS host + Linux Docker `ubuntu:24.04`
· **Manual fixtures:** 10/10 PASS (2 carry-forward + 4 Phase 3 +
4 Phase 4 ship-gate scenarios) · **Supersedes:**
`archive/STATE_OF_SYSTEM_phase3.md`

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

Phase 3 added crash recovery: if A is `kill -9`'d mid-edit, the
watchdog probes A on B's next tool call, signal-1 PID-liveness
returns dead/pid_gone, and the Mediator agent spawns inline,
returns a `surgical_fix` verdict, and the apply pipeline removes
A and frees its lock. B's next Write succeeds without manual
intervention. (`archive/STATE_OF_SYSTEM_phase3.md` carries the
end-to-end audit-trail walkthrough.)

**Phase 4's new contribution: the system also distinguishes
trivial drift from breaking drift on stale-read events.**
Concrete scenario, end-to-end:

- Session A reads `api.ts` and stores its sha256 in its read-set.
  The function `getUser(id: string): Promise<User>` is the
  signature A is reasoning about.
- Session B independently changes the signature to
  `getUser(id: string, opts: FetchOptions): Promise<User | null>`.
  B holds no lock on `api.ts` longer than its own write turn;
  the file is now committed at the new content.
- Session A attempts `Write` to `api.ts`. Hash mismatch detected
  on A's read-set entry.
- The 3-stage validator pipeline fires inside
  `pre_tool_use_write.sh` (no separate hook):
  1. **Cache lookup** (`lib/validator_cache.sh`): keyed by
     `(file, read_hash, current_hash)`. MISS — first observation.
  2. **Pre-filter** (`lib/validator_prefilter.sh`): pure-bash
     deterministic classifier. The diff is not whitespace-only,
     not blank-only, not comment-only → ESCALATE_TO_AGENT.
  3. **Validator agent spawn** (`lib/validator_spawn.sh`):
     `claude -p` subprocess in subscription mode, scoped to
     `Bash` + `Read` only, given the read-snapshot from
     `.coord/read_snapshots/<sid>/<hash>.txt` plus the current
     file content as drift context. Validator returns
     `verdict.classification = CRITICAL` with
     `diff_summary = "Function signature changed; callers will
     break"`.
- The hook writes a `kind=critical_drift` entry to
  `.coord/mediator/pending.jsonl` and **synchronously** spawns
  the Mediator inline (the same Phase 3 spawn flow).
- Mediator inspects state + the verdict + the last 50 events and
  decides `action_type=surgical_fix`,
  `actions=[clear_read_set(A)]`. The apply pipeline executes.
  A's read-set is wiped.
- A's retry of `Write` finds no read-set entry for `api.ts`,
  triggers the Read-first reminder, A re-reads, sees the new
  signature, and revises its plan before writing.

**Compare to Phase 3:** the same scenario produced an
over-warning banner on *any* drift — the user got the same
banner whether B added a comment, renamed a variable, or
deleted the function. Phase 4 distinguishes:

- **Trivial drift** (formatter-only, blank-line-only,
  comment-only) → SAFE → silent, no banner, cached for 1h.
- **Meaningful drift** (variable rename, string change, body
  edit) → MINOR → informational banner ("Drift on `<file>`:
  `<diff_summary>`. Validator classified as MINOR. Proceeding."),
  cached for 1h.
- **Breaking drift** (signature change, deletion, semantic
  rewrite) → CRITICAL → synchronous Mediator inline, never
  cached, state cleanup applied before the Write proceeds.

The signal-from-noise problem at the stale-read surface is now
addressed at the same architectural quality as the lock + crash
layers below it.

---

## 2. Current capabilities

**Existing (Phase 0–3):**
- Read tracking with sha256 hashes; stale-read detection on
  hash mismatch.
- Write locking via `flock`-protected atomic edits to
  `sessions.json`.
- Hard deny on lock contention with three-options reason text
  (`coord wait` is the only enabled option; (a)/(b) point at
  Phase 6 stubs).
- `coord wait <path> --timeout N` blocking poll until release
  or timeout (clamped [30, 570]).
- Lock release on PostToolUse, Stop, SessionEnd. Notifications
  to waiters on release.
- Peer watchdog with 3-signal probe (PID liveness, last_activity
  age, lock-unrefreshed age) and 3-outcome verdict
  (alive / dead / uncertain) wired into `pre_tool_use_any.sh`.
- Mediator agent (`lib/mediator_spawn.sh`): three action types
  (`advice` / `surgical_fix` / `lockdown`), two-state confidence
  (`auto_apply` / `needs_review`), max-depth-2 peer review,
  unified `pending.jsonl` queue.
- Lockdown gate at `.coord/mediator/lockdown.json` — every coord
  hook calls `coord_lockdown_check + coord_lockdown_emit_deny`
  before its main work.
- Critical-conditions bypass: 3+ consecutive `jq` parse failures
  on `sessions.json` trigger lockdown directly with
  `reason_source=critical_bypass`. Recovery via
  `coord mediate --resume`.
- Operator interface: `coord mediate {--reason | --escalate |
  --resume | --approve | status}`.

**New in Phase 4 — validator pipeline:**

- **Read-snapshot capture** (`lib/read_snapshots.sh` /
  PR-PHASE4-05): `pre_tool_use_read.sh` writes the file content
  observed at Read time to
  `.coord/read_snapshots/<sid>/<hash>.txt`. Per-session,
  content-addressable. Files >10MB skip snapshot (existing
  `SKIPPED_LARGE` cap reused). Snapshots GC on supersede /
  `session_end` / Mediator `evict_session` action.

- **Validator cache** (`lib/validator_cache.sh`): JSON store at
  `.coord/validator/cache.json` keyed by
  `(file, read_hash, current_hash)`. TTL 1h for SAFE and
  MINOR. **CRITICAL is never cached** (PR-PHASE4-04 — every
  CRITICAL drift must trigger fresh Mediator escalation;
  cache-hit shortcuts skip the safety mechanism). Opportunistic
  GC drops expired entries on each write under flock. LRU
  eviction at the configured cap.

- **Validator pre-filter** (`lib/validator_prefilter.sh`):
  pure-bash + `diff(1)` deterministic classifier. Three SAFE
  heuristics: `whitespace_only`, `blank_only`, `comment_only`
  (the last requires the file contains no `"""`, `'''`, or
  triple-backtick markers — conservative doctrine guards
  against false-SAFE on a comment-shaped line that's actually
  inside a multi-line string). Files >1MB or pre-filter
  wall-time >5s → ESCALATE_TO_AGENT unconditionally. The
  doctrine: false-positive ESCALATE on trivial drift is
  acceptable cost; false-negative SAFE on real drift is
  dangerous.

- **Validator agent spawn** (`lib/validator_spawn.sh`):
  `claude -p` subprocess in subscription mode (no `--bare`),
  mirroring the Mediator's spawn pattern. Tool restrictions:
  `--allowedTools "Bash" "Read"` plus
  `--disallowedTools "Write" "Edit" "NotebookEdit" "Task"`.
  Spawn env: `CLAUDE_COORD=0` (coord hooks early-exit on the
  spawned session) plus `CLAUDE_CODE_VALIDATOR=1` (recursion
  guard; depth-1 only — Phase 4 does not exercise peer review
  at the Validator layer; if disagreement surfaces, Mediator's
  depth-2 mechanism handles it). Three-section prompt:
  Identity (~80 words) / System Constraints (HYBRID with
  `VALIDATOR_REFERENCE.md`) / Drift Context (HYBRID — embedded
  read-snapshot + current file content; live `Read` allowed via
  Bash). 9-field verdict schema written to
  `.coord/validator/verdict/<ts>.json`:
  `verdict_id`, `ts`, `for_pending_entry`,
  `validator_session_id`, `file`, `session`,
  `verdict` (SAFE | MINOR | CRITICAL), `reasoning`,
  `diff_summary`, `spawn_metadata` (nested:
  `duration_ms`, `model`, `spawn_mode`). The hook captures
  `is_error` from JSON (NOT shell exit code) per the discipline
  established in Phase 3.

**Pipeline behavior (per-file disposition):**
- **SAFE** → silent: no banner, no event flag on the user's
  output. Cached for 1h.
- **MINOR** → banner + proceed: the
  `additionalContext` carries an informational line, the
  `Write` proceeds, cached for 1h.
- **CRITICAL** → synchronous Mediator inline (~60–100s
  worst-case wall-clock). Never cached. Mediator emits
  `advice` / `surgical_fix` / `lockdown` per its existing
  Phase 3 contract. The pending entry's `kind=critical_drift`
  is the Validator → Mediator hand-off contract.
- **Pipeline failure** (cache error, validator spawn fail,
  Mediator spawn fail) → fail-open Phase 1 fallback banner
  ("Drift on `<file>` (modified since read; pipeline failed).
  Pipeline unavailable; consider re-reading before
  proceeding."). Per CLAUDE.md §A.5.

**Smart classification benefits:**
- Trivial drift (formatter, comments, blank lines) no longer
  warns. The Phase 3 over-warn problem is solved.
- Recurring same-file/same-drift events hit the cache and
  avoid repeated `claude -p` spawns. Token-efficient on
  repeated edits to the same file from different sessions.
- CRITICAL escalation rides on the existing Phase 3 Mediator
  infrastructure — **no new architectural deny location**.

**Internal infrastructure:**
- `pre_tool_use_write.sh` lines 195–241 host the 3-stage
  pipeline. The Phase 3 PHASE-4 UPGRADE POINT comment is
  retired.
- Per-session `last_consumed_verdict` pointer mechanism
  preserves idempotency under retried Writes (PR-PHASE4-02).
- `VALIDATOR_REFERENCE.md` (545 lines, 9 sections) installed at
  `.coord/validator/VALIDATOR_REFERENCE.md`. Documents verdict
  JSON schema, classification heuristics with worked examples,
  diff-summary conventions (no apostrophes per F-014), Mediator
  hand-off contract, tool restrictions, and recursion-guard
  rationale.
- `install.sh` extended (T4.05): provisions
  `.coord/validator/{verdict,cache.json}`, copies
  `VALIDATOR_REFERENCE.md`, and gitignores
  `.coord/read_snapshots/` + `.coord/validator/`.
- `phase4_invariant.bats` adds 2 new architectural guards
  (validator_spawn.sh + validator_prefilter.sh contain zero
  `permissionDecision` strings) plus 1 bonus guard for
  validator_cache.sh; total 8 guards from Phase 3's 6.

---

## 3. Current limitations

What still doesn't work after Phase 4:

- **Wait queue is still single-waiter polling, not FIFO.** Two
  sessions waiting on the same lock will not necessarily
  acquire in arrival order. Phase 5 introduces explicit FIFO +
  `wake_file`.
- **Self-delegation and `coord task-open` are educational
  stubs.** The deny banner mentions options (a)/(b) but the CLI
  subcommands exit with helpful text pointing at option (c).
  Phase 6 lands the full task-delegation flow.
- **Subagent (Task tool) races stay invisible by design**
  (Decision 2.17 / PR-PHASE0-01 carry-forward). Hooks no-op on
  `agent_type`-populated calls. A subagent writing a file the
  parent doesn't hold a lock on can silently clash with another
  session.
- **Mediator's real-Claude semantics are not yet
  stress-tested.** Unit tests use a fake `claude` binary
  emitting scripted JSON. Real `claude -p` invocations get
  validated in Phase 7's integration harness (cost ~$0.10/run
  in subscription mode per T3.06 POC).
- **Validator's real-Claude semantics are not yet
  stress-tested either.** Same disposition as Mediator: the
  end-to-end pipeline (cache → pre-filter → spawn → verdict
  schema → hand-off) is exercised with a fake `claude` binary;
  real-model picks for SAFE/MINOR/CRITICAL classification get
  validated in Phase 7.
- **`coord mediate status` cost reporting still shows
  misleading `$0.000`** under subscription mode. The display
  logic for "subscription" vs "API" modes is Phase 7 polish.
- **`--bare` spawn mode for users with `ANTHROPIC_API_KEY` is
  documented but not implemented** (carry-forward from Phase 3;
  the Validator inherits the same posture as the Mediator).
  Both reference docs describe `--bare` as future enhancement.
- **F-016 timing flake** intermittently surfaces on `coord_wait`
  and Mediator-related teardown under heavy parallel bats load.
  Tests pass in isolation; the flake is bats-environment-only.
  Phase 7 stress harness fixes it.
- **F-017** ambient-suspicion scan latency at 109ms median
  (PR-PHASE3-02 estimated <50ms). Acceptable — 13× below the
  2-second hard ceiling — but optimization deferred to Phase 7.
- **F-015** `coord wait` subagent policy revisit deferred to
  Phase 6 (delegation primitives surface the policy choice).
- **Cost guard tunables** —
  `mediator_min_seconds_between_invocations`,
  `mediator_max_invocations_per_hour`, and the equivalent
  Validator-spawn ceilings — are env-var configurable but **not
  yet enforced**. Phase 7 measurement-driven defaults pin them.
- **Auto-reset race on corrupt-state detection** — the
  parse-fail counter at `.coord/mediator/critical_counters.json`
  has a theoretical edge case where two hooks racing on parse
  failure could double-count. Phase 7 stress check covers it.
- **Multi-machine, team-shared coord scenarios are out of scope
  for v1.** All recovery + classification guarantees are
  local-filesystem only. Documented as future-work.

---

## 4. Is this usable RIGHT NOW?

Three audiences. Phase 3 verdicts quoted; Phase 4 revisions
noted.

**(a) Solo developer, 1–2 sessions occasionally.**

Phase 3 verdict: *"same value PLUS automatic recovery from
crashed sessions. The need for `coord reset --confirm` operator
intervention is largely eliminated for normal SIGKILL/crash
scenarios."*

Phase 4 verdict: same value PLUS smart drift classification.
Trivial drift (formatter changes, comments, blank lines) no
longer interrupts your flow with warning banners. Meaningful
drift (variable renames, string changes) gets an informational
banner so you know without being blocked. Breaking drift
(signature changes, deletions) gets Mediator escalation with
state cleanup applied before your Write proceeds. The system
now distinguishes signal from noise at single-developer scale.
On a quiet edit session you'll see substantially fewer banners
than under Phase 3.

**(b) Solo developer, 3–5 concurrent sessions on the same
repo.**

Phase 3 verdict: *"trust posture extends. Crashed sessions
don't permanently block live ones. Mediator handles orphan-lock
cleanup within ~30–60 seconds (subscription mode wall-clock).
Multi-waiter ordering still by coincidence (Phase 5 wait_queue
fixes that properly), but the safety guarantee is now layered:
prevent clobbering (Phase 2) + recover from crashes (Phase 3)."*

Phase 4 verdict: trust posture extends further. Cross-session
edits no longer produce false-positive warnings on trivial
changes. When a real conflict surfaces (CRITICAL drift),
Mediator surgical_fix clears your read-set so the retried Write
forces a re-read and you re-acquaint with the new file content
before deciding. Multi-waiter ordering is still by coincidence
(Phase 5 fixes that), but the safety + recovery + classification
layers are now all production-quality at single-user scale.
Three sessions racing the same file with one of them adding a
comment will now see exactly zero warning noise from the comment
add — only the real conflicts surface.

**(c) Team / multi-developer / multi-machine.**

Out of scope for v1. (Unchanged from Phase 2/3 verdict.)

---

## 5. How it actually works (architecture in ~300 words)

The system is a Bash-only set of hooks (`jq` + `flock` + `perl`)
registered into Claude Code's `.claude/settings.local.json`.
Hooks fire on PreToolUse / PostToolUse / Stop / SessionStart /
SessionEnd / UserPromptSubmit. State lives at `.coord/`
(gitignored) under `sessions.json` (atomic-edited via
`lib/atomic_write.sh`), an append-only `events.jsonl` audit
log, and JSONL queues at `mediator/pending.jsonl` and
`validator/verdict/<ts>.json`.

**Phase 4 architectural addition: 3-stage validator pipeline in
`pre_tool_use_write.sh`.** When a stale-read hash mismatch is
detected on the read-set walk, the pipeline fires per-drifted
file: cache lookup → deterministic pre-filter → `claude -p`
agent spawn → 9-field verdict. Per-file disposition (SAFE silent
/ MINOR banner / CRITICAL Mediator) is the unit of observation
and action.

**New lib clusters:**
- `lib/read_snapshots.sh` — per-session content-addressable
  snapshot store; consumes Read-time content so the Validator
  has the exact bytes the session reasoned about.
- `lib/validator_cache.sh` — TTL+LRU JSON cache;
  `(file, read_hash, current_hash)` key; CRITICAL refused at
  write.
- `lib/validator_prefilter.sh` — pure-bash heuristic; only
  emits SAFE on the three trivial categories; ESCALATE
  unconditionally on file-size + timeout limits.
- `lib/validator_spawn.sh` — `claude -p` wrapper mirroring the
  Mediator's spawn pattern; recursion-guarded via
  `CLAUDE_CODE_VALIDATOR=1`; depth-1 only.

**Validator vs Mediator distinction:** the Validator
**classifies**, the Mediator **acts**. The Validator's CRITICAL
classification routes through the Mediator via a
`kind=critical_drift` pending entry; the Mediator decides
`advice` / `surgical_fix` / `lockdown` per its existing Phase 3
contract.

**Synchronous CRITICAL pathway:** total wall-clock 60–100s
worst case (Validator ~30–60s + Mediator ~20–35s). The
CLAUDE.md §A.6 2-second hook-latency target and §A.5
fail-open posture are intentionally bypassed for CRITICAL
drift events (~5–10% of stale-read attempts). Justification:
a CRITICAL verdict means intervention is needed before the
Write proceeds; allowing it to land defeats the validator's
purpose. The Bash-tool 600s ceiling provides the hard margin.

**Phase 4 invariant:** 8 architectural guards + 1 bonus in
`phase4_invariant.bats`. Validator components
(`validator_spawn.sh`, `validator_prefilter.sh`,
`validator_cache.sh`) contain zero `permissionDecision`
strings. The Phase 3 two-location deny invariant
(`pre_tool_use_write.sh` lock-held + lockdown gate) is
preserved.

---

## 6. What ships in Phase 5

Per `IMPLEMENTATION_PLAN.md` §5 Phase 5 — Wait queue + cycle
detection:

- **`wait_queue[<file>]` FIFO data structure** replaces
  Phase 2's single-waiter polling. Lock release walks the
  queue in arrival order.
- **`wake_file` mechanism** — event-driven instead of polling;
  the lock-releasing hook `touch`es the head waiter's wake
  file; `coord wait` blocks on `inotifywait` / `fswatch`-
  equivalent and exits cleanly on touch.
- **Notification semantics with `diff_summary` on lock
  release** — waiters receive an `additionalContext` summary
  of what changed under the lock so they can adjust their
  plan before retrying.
- **Cycle detection in `task_graph`** — explicit deadlock
  prevention. When a task graph would induce a cycle, the
  request is denied with an actionable banner.
- **Mediator deadlock-breaking heuristic** — extends the
  Phase 3 3-action contract: when global deadlock is detected
  by ambient watchdog + cycle detection consensus, Mediator
  picks the lowest-priority session to evict.

**Phase 5 invariant prediction:** wait_queue introduces a
**third architectural deny location** (cycle-detected requests
deny inline, before the lock-acquisition branch fires). Cycle
detection escalation routes through Mediator → which can
lockdown if global deadlock. The lockdown deny location is
unchanged. Phase 5 will need to expand the invariant test
allowlist by exactly one site.

---

## 7. Trust posture

**Phase 3 verdict:** *"earned its keep at 1-5 single-developer
session range with new recovery guarantees. The system now
self-heals from session crashes without operator intervention
in normal scenarios. Trust the lock guarantee + the recovery
guarantee at single-user scale."*

**Phase 4 verdict (revised):** earned its keep at 1–5
single-developer session range with new classification
quality. The system now distinguishes signal from noise on
stale-read drift events. Trust the lock guarantee + the
recovery guarantee + the classification guarantee at
single-user scale.

**Trust:**
- Lock guarantee — concurrent writes don't clobber.
- Three-options interface — deny banner is actionable.
- `coord wait` — clean exit semantics, clamp behavior, SIGINT
  trap.
- Mediator surgical fixes for orphan locks — `release_lock`,
  `evict_session`, `clear_read_set` apply pipeline is
  idempotent and audit-trailed.
- Watchdog probe for ambient suspicion — 3-signal model is
  conservative (Signal 1 mandatory for alive; alone-Signal-2/3
  → uncertain → defer to Mediator).
- Lockdown for system-wide problems — every-hook gate is
  architecturally enforced via `phase4_invariant.bats`.
- Critical-bypass + operator `--resume` — degraded-state
  recovery is documented, tested (Phase 3 scenario 03), and
  predictable.
- **Validator SAFE/MINOR/CRITICAL classification** (mock
  binary verified end-to-end through pipeline; real-Claude
  picks Phase 7).
- **Validator cache** for recurring drift — token-efficient on
  repeated cross-session edits to the same file.
- **Pre-filter conservative doctrine** — multi-line-string
  ambiguity → ESCALATE. False-positive ESCALATE accepted as
  cost; false-negative SAFE refused.

**Do NOT yet trust:**
- Multi-waiter ordering fairness under contention (Phase 5
  `wait_queue` fixes; Phase 4 still polls).
- Task delegation primitives (Phase 6; Phase 4 has educational
  stubs).
- Real-Claude Mediator + Validator semantics under stress
  (Phase 7 integration harness; Phase 4 unit tests use fake
  `claude` binary).
- Cost predictability under high spawn rate — Mediator + new
  Validator both spawn `claude -p`; combined rate-limit
  enforcement is Phase 7 (T3.06 POC measured ~$0.10 per
  invocation in subscription mode).
- F-016/F-017 timing assumptions (Phase 7 stress harness).

The classification + recovery + lock guarantees scope is
single-developer. Multi-machine team scenarios still out of
scope for v1.

**By the numbers:** 314/314 → 390/390 unit tests on macOS host
+ Linux Docker `ubuntu:24.04`. 10/10 fixture scenarios across
both platforms (2 carry-forward + 4 Phase 3 + 4 Phase 4).
F-014 + F-018 RESOLVED in Phase 3. **Zero new findings raised
in Phase 4** — the construction discipline accumulated through
Phase 3 (the `if var=$(cmd); then ...; else ...; fi` rc-capture
pattern, lifecycle-event-completeness audit, prefilter
heuristic ambiguity in test assertions, GNU-first stat probe,
perl-utime mtime manipulation) caught its own pitfalls
pre-commit. F-015 (Phase 6), F-016 (Phase 7), F-017 (Phase 7)
remain OPEN with deadlines.

**Branch:** `main` at `5684e64` (Phase 4 merge commit). Nine
Phase 4 commits (T4.01 plan-revision drafts through T4.09
sign-off) visible along the merge commit via `--no-ff`. Phase 1,
Phase 2, Phase 3 merge commits preserved at `629b1fb`,
`6b0cc35`, `802c986` respectively.

Phase 4 is NOT the finished system. It is the smart-
classification layer that sits on top of the lock + crash-
recovery layers from Phases 2 + 3. The system has graduated
from "prevents bad writes AND recovers from session deaths"
(Phase 3) to "prevents bad writes, recovers from session
deaths, AND distinguishes trivial drift from breaking drift
on the stale-read surface" (Phase 4). Phase 5 will fix the
multi-waiter coincidence; Phase 6 will land delegation;
Phase 7 will harden the real-Claude integration. Each phase
compounds; no phase invalidates a prior phase's claim.

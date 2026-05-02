## Phase 2 — Write coordination
Started: 2026-04-25T22:18:07Z
Closed:  2026-04-26T01:35:58Z
Status:  COMPLETE (user approved phase-2-signoff.md; branch
         `phase-2/write-coordination` merged to main as commit
         6b0cc35 "Phase 2: Write coordination (T2.00-T2.06)" prior
         to Phase 3 branch cut. STATE_OF_SYSTEM.md updated for
         Phase 2 end-state. All Phase 0/1/2 findings dispositioned;
         carry-forward into Phase 3: F-014 OPEN (deadline this
         phase), F-015 OPEN (deadline Phase 6), F-016 OPEN
         (deadline Phase 7).)

Phase goal (plan §5): prevent write-write conflicts with hook-enforced
deny. Reuse Phase 1's read-set gate. The ship-gate invariant inverts:
Phase 1 forbade `permissionDecision` in any code path; Phase 2
introduces `permissionDecision: "deny"` specifically in the
"lock-held-by-other" branch of `pre_tool_use_write.sh`, with the
CLAUDE.md §B.2 three-options reason text. Every other code path must
remain allow / no-op / fail-open.

In-scope components (plan §5):
- Lock acquisition in `pre_tool_use_write.sh` (flock-protected; updates
  `locks[<file>] = {session, acquired_at, last_refresh_at, tasks:[]}`).
- `permissionDecision: "deny"` when another session holds the lock; the
  `permissionDecisionReason` carries CLAUDE.md §B.2 three-options text
  (delegate / self-delegate / passive wait). Per §A.4: `coord task-open`
  and `coord self-delegate` remain Phase-6 stubs that exit "disabled in
  Phase 2"; only option (c) actually works in Phase 2.
- Lock release in `post_tool_use_write.sh` (NEW hook). Populates the
  notifications[] producer side that Phase 1 wired dormantly on the
  consumer side.
- Lock release on Stop + SessionEnd (graceful). Phase 0's
  `session_end.sh` already releases this-session locks; Phase 2 adds
  the new `stop.sh` hook for the Stop event path and verifies
  `session_end.sh`'s release path now that Phase 2 actually populates
  `locks`.
- `coord wait <file>` CLI: passive blocking wait until lock release or
  timeout, clamped to [30, 570] per Decision 2.20 / PR-PHASE0-01.
  WAIT_CLAMPED + WAIT_TIMEOUT events. Polling cadence per CLAUDE.md
  §B.8 (30s → 60s → 120s).
- Lock TTL refresh on any tool call by the holder (self-write path:
  refresh, not contend, per CLAUDE.md §B.2 case 3).
- Mediator flock-timeout producer (plan §5 Phase 2 mediator thread):
  flock timeouts in atomic_write / log_event write `pending.json
  {kind:"flock_timeout", ...}`. Phase 1 already shipped the
  corrupt-state producer + consumer; Phase 2 adds flock-timeout as a
  second producer kind. Full Mediator agent is Phase 3.

Out-of-scope (plan §5):
- Task delegation implementation — `coord task-open` machinery deferred
  to Phase 6. Phase 2's deny message MAY mention option (a); the CLI
  subcommand exits "disabled" until Phase 6.
- Self-delegation — `coord self-delegate` machinery deferred to Phase 6.
- Peer watchdog — orphan locks accumulate after SIGKILL; `coord reset
  --confirm` is the operator escape hatch. Phase 3 fixes.
- Validation subagent (still text warnings; Phase 4 lands SAFE/MINOR/
  CRITICAL agent classification).
- Wait-queue FIFO ordering / multi-waiter semantics — Phase 2's
  `coord wait` supports a single waiter cleanly; Phase 5 formalizes
  FIFO + diff-summary on wake-up + deadlock detection.
- Mediator agent — Phase 2 only adds the flock_timeout flag-file
  producer; the full agent hook is Phase 3.

Applicable carry-forwards from phase-1-signoff.md "Open questions for
Phase 2":
1. **Phase 2 ship-gate fixture extension.** Phase 1's smoke-driver
   pattern (`src/tests/fixtures/two_session_warn/scenarios/01_basic_warn/`
   + `src/tests/manual/two_session_warn.sh`) supports a new
   `02_lock_deny/` scenario directly; no driver restructuring required.
   Ship-gate scenario shape: A acquires lock on foo.ts, B's Write on
   foo.ts is denied with the §B.2 three-options reason. Possibly also
   a `03_self_write_refresh/` for the holder-refresh path.
2. **Lock TTL refresh granularity.** Default per-write per phase-1-signoff
   recommendation. Revisit if `events.jsonl` growth from
   LOCK_REFRESH-per-write becomes material under burst-edit sequences;
   no Phase 2 implementation cost to defer the rate-limit decision.
3. **`additionalContext` three-options text validation.** Phase 0
   Experiment #3 confirmed `permissionDecisionReason` reaches Claude
   verbatim (single-line); the §B.2 three-options structure is wider
   (multi-line `Bash:` invocations including JSON args). Phase 2
   should verify the multi-line text round-trips intact when the deny
   actually fires — could combine with the ship-gate fixture.

Applicable OPEN findings at phase start: **none.** All Phase 0 + Phase 1
findings are disposed (RESOLVED / WONTFIX / RESOLVED with retroactive
fix). Phase 2 starts with a clean FINDINGS slate.

### Tasks
- [x] T2.00  Open Phase 2 section + cut `phase-2/write-coordination` branch + close-out Phase 1 log lag (2026-04-25T22:18:07Z)
             Result: branch cut from main HEAD `629b1fb` (Phase 1 merge);
             user approved + committed the staged `.gitignore`
             addition on main (`199bb93` "Add STATE_OF_SYSTEM.md to
             gitignore (briefing artifact)"); phase-2 rebased onto
             main; worktree clean. IMPLEMENTATION_LOG.md Phase 1
             section updated to COMPLETE with merge timestamp +
             checked ship-gate items (the log had lagged the actual
             signoff). Phase 2 section opened IN_PROGRESS with full
             ship-gate checklist + scope notes + carry-forward items
             1-3 from phase-1-signoff.md.
- [x] T2.01  pre_tool_use_write.sh lock acquisition + deny-three-options + self-write refresh, paired with NEW post_tool_use_write.sh lock release; bats coverage including new ship-gate invariant test (2026-04-25T22:30Z → 2026-04-25T22:42Z)
             Result: pre_tool_use_write.sh extended past the
             PHASE-2 UPGRADE POINT marker with three new branches:
             (a) lock-held-by-other → emit_deny + LOCK_DENIED event
             (the only emit_deny call site in the codebase),
             (b) lock-held-by-self → atomic refresh of last_refresh_at
             + LOCK_REFRESH event (per-write granularity per
             phase-1-signoff Q2 default; observe-first per user
             direction), (c) unheld → atomic acquire setting
             {session, acquired_at, last_refresh_at, tasks:[]} +
             LOCK_ACQUIRED event. Stale-read warning preserved as
             additionalContext compose-on-success (does NOT escalate
             to deny in Phase 2; Phase 4 validator owns that). Deny
             reason text built per CLAUDE.md §B.2 with all three
             options + acquired/last-activity humane ages + first-8
             holder-id prefix; multi-line via jq --arg JSON
             encoding; copy-paste-runnable `coord wait` syntax
             verified by bats. NEW post_tool_use_write.sh hook:
             releases own lock + LOCK_RELEASED event; defensive
             ERROR-log-only when target lock is held by another
             session (never deletes another session's lock).
             install.sh extended with PostToolUse Write|Edit|
             NotebookEdit registration (now 7 hooks total). coord
             CLI `task-open` and `self-delegate` stubs rewritten
             from terse die() to educational error pointing at
             option (c) `coord wait` with concrete syntax (per
             user concern #1). bats: 151/151 (was 137; +4 new
             pre_tool_use_write tests, +7 post_tool_use_write tests,
             +3 phase2_invariant tests; install_register Phase-2
             additions absorbed into existing tests). Smoke
             confirms acquire→refresh→deny→release sequence with
             clean events.jsonl. Phase 1 regression
             two_session_warn.sh still PASS on hook-sim. Pre-commit
             adjustments per user direction: (1) abstracted (a)/(b)
             CLI references in deny reason text — `coord task-open`
             / `coord self-delegate` named without freezing Phase 6
             argument shape; option (c) `coord wait` kept verbatim
             (active Phase 2 deliverable); bats updated with positive
             abstract-name assertions + negative regressions guarding
             against accidental `--file ...` syntax leakage; (2)
             phase2_invariant grep tightened to skip pure-comment
             lines so docstring mentions of `permissionDecision`
             don't trip the architectural guard; (3) F-013 closed
             via PR-PHASE2-01 (plan §3.3 schema text `file` → `path`
             — no code change). New finding F-014 OPEN logged for
             bats apostrophe-fragility (DEFERRED to Phase 3
             test-harness work; phrasing-avoidance workaround
             documented).

- [x] T2.02  Stop + SessionEnd graceful lock release; new stop.sh hook; idempotent (handles Stop-then-SessionEnd dual-fire); notification activation on release (Phase 1 dormant consumer becomes producer-coupled); multi-lock iteration; SubagentStop filter; bats coverage (2026-04-25T22:55Z → 2026-04-25T23:18Z)
             Result: NEW lib/notify_waiters.sh shared helper —
             scans events.jsonl for LOCK_DENIED entries on path P
             with ts in [acquired_at, released_at) and session !=
             holder, dedupes waiter session IDs, then in ONE
             atomic_edit appends "lock_released: <path> released
             by <holder-prefix>... at <released_at>" to
             notifications[<waiter>][<path>] for each (preserving
             Phase 1's string-array shape that pre_tool_use_read.sh
             and pre_tool_use_any.sh already consume). Emits ONE
             NOTIFICATION_PRODUCED event per release-with-waiters
             (not per waiter). Best-effort throughout: missing
             events.jsonl, malformed lines, atomic_edit failures
             all return 0 silently with stderr warning.
             NEW src/hooks/stop.sh — Stop event handler with: (a)
             non-participant gate, (b) subagent_filter (SubagentStop
             and Stop-with-agent_type both → SUBAGENT_ACTIVITY_SKIPPED
             since subagents do NOT hold locks per Decision 2.17;
             parent's lock covers parent's turn), (c) read all locks
             held by $SESSION_ID first, (d) for each: per-file
             atomic delete + LOCK_RELEASED event with
             source=stop + acquired_at preserved + notify_waiters
             call. Empty-locks path is silent no-op (idempotency
             basis for Stop+SessionEnd dual-fire).
             UPDATED session_end.sh — replaced the Phase-1
             single-jq-filter `with_entries(select())` lock sweep
             with the same per-file iteration as stop.sh, including
             notify_waiters call. The Phase-1 filter is retained as
             a defensive guard between snapshot-and-edit (cheap
             no-op when stop.sh already cleaned up). Multi-lock
             iteration emits one LOCK_RELEASED per file with
             source=session_end. The Phase-1 invariant "release
             this-session locks only" is preserved — verified by
             retained Phase-1 bats test.
             UPDATED post_tool_use_write.sh — capture acquired_at
             before lock deletion, then call notify_waiters on
             release. LOCK_RELEASED event payload now includes
             acquired_at + source=post_tool_use_write to
             distinguish from stop/session_end release sources in
             events.jsonl.
             UPDATED install.sh — register Stop event with matcher
             `*` pointing at stop.sh; idempotent strip+add pattern
             unchanged. Total Phase-2 hook count: 8 (was 7 at T2.01).
             UPDATED uninstall mirror in coord CLI is automatic —
             the generic `commands containing /.coord/hooks/` strip
             pattern in install.sh --uninstall and src/bin/coord
             cmd_uninstall already covers any new hook registered
             via the same convention. No code change needed.
             bats: 167/167 (was 151 at T2.01 close; +16 new across
             stop.bats (10), session_end.bats (3 new), post_tool_use
             _write.bats (2 new), install_register.bats (Phase-2
             additions). Ship-gate invariants confirmed: phase2_
             invariant.bats (3/3) — stop.sh auto-included via the
             `for f in HOOKS_DIR/*.sh` scan, no permissionDecision
             violations across any new code. End-to-end smoke
             confirms: A acquires foo.ts+bar.ts; B denied on foo.ts;
             A's Stop releases both with one LOCK_RELEASED per file
             + populates notifications[B][foo.ts]; A's SessionEnd
             then runs against zero held locks → no spurious
             LOCK_RELEASED events (idempotent), still transitions
             A.state=IDLE_CLOSED + emits SESSION_END. Phase 1
             regression two_session_warn.sh hook-sim 1/1 PASS.

- [x] T2.03  coord wait <path> [--timeout N] CLI implementation; blocking poll until lock release / timeout; clamp [30, 570] per Decision 2.20; events WAIT_CLAMPED / WAIT_TIMEOUT / WAIT_RELEASED; SIGINT trap; subagent policy = (A) allow (2026-04-25T23:30Z → 2026-04-25T23:58Z)
             Result: cmd_wait function added to src/bin/coord
             between cmd_install and the dispatcher; full
             wait subcommand now active in usage and case dispatch.
             Behavior: parses path + --timeout (with --timeout=N
             form supported); rejects non-integer timeouts;
             clamps [30, 570] per Decision 2.20 + PR-PHASE0-01;
             WAIT_CLAMPED event when clamp applied. Sources
             log_event.sh + state_query.sh from
             $LIB_DIR (resolved relative to script location, NOT
             COORD_DIR — fixed bug where bats overrides COORD_DIR
             to a per-test workspace whose lib/ is empty).
             SESSION_ID defaults to "unknown" if unset (CLI may run
             outside hook context). Trap on INT/TERM emits
             WAIT_TIMEOUT(reason=interrupted) + exit 130. Instant
             exits: lock free → "lock free" stdout + return 0; lock
             held by self → "held by you" + return 0. Poll loop:
             250ms cadence using sleep 0.25 (4 polls/sec); each
             iteration calls coord_lock_holder via state_query.sh.
             On release detected → WAIT_RELEASED event with
             waited_for + started_at + released_at + applied
             timeout payload. On deadline → WAIT_TIMEOUT event
             with requested + applied + reason=deadline.
             Subagent policy: (A) allow — CLI is not gated by
             agent_type; F-015 OPEN/DEFERRED to Phase 6 captures
             the alternative for review when self-delegate lands.
             Educational stubs for `coord task-open` /
             `coord self-delegate` retained from T2.01.
             coord usage updated: removed `wait` from "coming in
             later phases" list; added under "Available subcommands"
             with --timeout description.
             bats: 179/179 (was 167 at T2.02 close; +12 new in
             coord_wait.bats covering usage error, non-integer
             timeout rejection, instant-free-exit, instant-self-exit,
             clamp-low, clamp-high, in-bounds-no-clamp,
             release-detection (with timing assertion ≤2s),
             timeout-fires (full 30s wait), SIGINT-trap-static-check
             (F-016 OPEN/DEFERRED to Phase 7 for runtime delivery
             test in real claude -p harness — see findings note),
             subagent-policy-A, ship-gate). One bug discovered + fixed
             during bats: CLI's LIB_DIR was computed against
             $COORD_DIR/lib (which tests override to empty); changed
             to $COORD_BIN/../lib so the CLI works both installed
             and from the source tree. End-to-end smoke verified all
             three event kinds (RELEASED, CLAMPED, TIMEOUT) with
             correct payloads; polling responsiveness measured
             ~250-500ms detection latency from actual release.
             F-015 OPEN/DEFERRED + F-016 OPEN/DEFERRED logged.

- [x] T2.04  Mediator flock_timeout producer + consumer; storage approach (B) — JSONL append-only `.coord/mediator/pending.jsonl`; consumer at pre_tool_use_any.sh + session_start.sh; high-water-mark sibling file for delivered entries; legacy `pending.json` (corrupt_state) kept as-is to avoid breaking the Phase-1 corruption-recovery contract (2026-04-25T23:58Z → 2026-04-26T00:18Z)
             Result: NEW lib/mediator_pending.sh — JSONL-based
             producer/consumer pair. Producer
             coord_mediator_emit_pending appends one JSON object per
             call to .coord/mediator/pending.jsonl under flock on
             pending.lock (separate from sessions.lock — no
             "lock-to-log-a-lock-failure" recursion). Reserved keys
             (ts/kind/session/source) at top-level; remaining
             key=value pairs land under .payload. Consumer
             coord_mediator_consume_pending tails new entries since
             the high-water-mark in pending.consumed (single integer
             line count), formats a "Coord Mediator pending (N new
             entries) ..." banner without apostrophes (F-014 lesson),
             advances HWM atomically (temp+rename). Best-effort:
             missing COORD_DIR, lock timeout, disk full all return
             0/1 silently with stderr warning.
             UPDATED lib/atomic_write.sh — sources mediator_pending.sh
             at top (cycle-safe: mediator_pending has no dependency
             on atomic_write). After the flock-acquire subshell
             returns rc=42, emit a flock_timeout entry with
             source=atomic_write, file, lock, timeout_sec=5,
             attempted_op=atomic_edit. Best-effort `|| true` so
             this never alters the original rc.
             UPDATED hooks/pre_tool_use_any.sh — added
             coord_mediator_consume_pending call after the
             corruption-banner consumer; result composes into the
             same additionalContext block alongside notifications +
             HEAD-drift segments. Emits MEDIATOR_PENDING_DELIVERED
             event with source=pre_tool_use_any when banner fires.
             PHASE-3 UPGRADE POINT comment partially retired
             (consumer scaffolding shipped; agent-hook + verdict
             surface remain Phase 3).
             UPDATED hooks/session_start.sh — parallel consumer
             call after the corruption-banner consumer in the
             "Coord v1.0 active" banner composition. Banners
             ordered: corruption (if any), Coord v1.0, mediator
             pending. Emits MEDIATOR_PENDING_DELIVERED with
             source=session_start.
             UPDATED install_register.bats — verifies
             lib/mediator_pending.sh is installed.
             NEW src/tests/unit/mediator_flock_timeout.bats —
             13 tests covering: producer one-emit field shape,
             producer multi-append, producer empty-kind silent,
             producer concurrency (5 simultaneous emits all land
             with no lost writes), consumer-empty-returns-1,
             consumer-after-emit advances HWM and emits banner,
             consumer-twice second-call returns 1, consumer
             second-emit picks up only new, atomic_write timeout
             triggers producer (uses sessions.json.lock — caught
             a test-bug where I'd been holding sessions.lock, the
             wrong file, manually verified atomic rc=42 + pending
             entry), pre_tool_use_any banner delivery + event,
             pre_tool_use_any subagent-filtered (no banner +
             HWM not advanced), session_start banner composed
             alongside Coord v1.0, T2.04-surface phase2 invariant
             regression. Subagent policy: producer fires for any
             caller (subagents can hit atomic_edit contention
             too); consumer is gated by the existing subagent_filter
             at the hook layer, so subagent contexts skip the
             banner display while the entries remain pending for
             the parent's next non-subagent tool call.
             bats: 192/192 (was 179 at T2.03 close; +13 new). Phase 1
             regression two_session_warn.sh hook-sim 1/1 PASS.
             E2E smoke confirms: hold sessions.json.lock for 8s
             → atomic_edit rc=42 + pending.jsonl gets one
             flock_timeout entry → next pre_tool_use_any consumer
             emits banner with correct payload + advances HWM →
             second pre_tool_use_any sees no new entries (silent).
             No new findings (F-014, F-015, F-016 still OPEN/
             DEFERRED with prior deadlines).

- [x] T2.05  02_lock_deny scenario fixture + driver extension + Linux re-probe via Docker ubuntu:24.04 (2026-04-26T00:20Z → 2026-04-26T00:32Z)
             Result: NEW src/tests/fixtures/two_session_warn/scenarios
             /02_lock_deny/{description.md, timeline.sh}. Driver
             auto-discovers in lex order so two_session_warn.sh
             picks it up without code change. Scenario timeline:
             A registers, B registers, A acquires foo.ts via Write
             pre-hook, sleep 1s (so deny ts > acquired ts), B's
             Write attempts → captures the deny stdout, sleep 0.3
             for events flush, A's PostToolUse releases (populates
             notifications[B][foo.ts]), sleep 0.3, B's Read
             delivers the notification via additionalContext.
             14 explicit assertions (B.1-B.14 in description.md):
             exit-code, permissionDecision==deny, reason cites
             foo.ts + 'locked by session', all three (a)/(b)/(c)
             markers, abstract Phase-6 references, no-frozen-syntax
             negative regression, exact `coord wait` invocation
             with --timeout 570, both acquired+last-activity ages,
             LOCK_ACQUIRED→LOCK_DENIED→LOCK_RELEASED event
             sequence, NOTIFICATION_PRODUCED with waiter_count=1,
             B's Read additionalContext carries 'Lock released on'
             + cites the path, B's notification bucket cleared
             post-Read, B's Read stdout is permissionDecision-free
             (Phase 2 invariant for non-deny paths preserved).
             Both 01_basic_warn + 02_lock_deny PASS on macOS.
             EXTENDED .coord/experiments/linux-parity/linux_probe.sh
             with: (a) Phase-2 lock event sanity check that drives
             a minimal acquire→deny→release directly and counts
             LOCK_*/NOTIFICATION_PRODUCED events, (b) coord wait
             polling latency measurement (release at t=1000ms, time
             from wait start to wait exit). Linux Docker run
             results: bats 192/192 PASS (matches macOS exactly,
             zero regression); two_session_warn 2/2 PASS;
             concurrent_smoke clean; Phase 2 event counts on
             overlay/ext4: LOCK_ACQUIRED=1, LOCK_DENIED=1,
             LOCK_RELEASED=1, NOTIFICATION_PRODUCED=1; coord wait
             latency on Linux = 1166ms (release at t=1000ms,
             detection slop ~166ms — actually slightly tighter
             than macOS's ~250-500ms, likely due to lower jq
             read overhead on overlayfs vs APFS); LINUX_PARITY_
             COMPLETE marker emitted; coord health post-run exit 0.
             No new findings raised. Phase 2 verification gate
             closed: macOS + Linux both green, both fixture
             scenarios green, polling latency acceptable on both
             platforms.

- [x] T2.06  Draft phase-2-signoff.md per CLAUDE.md §A.9 (2026-04-26T00:35Z → 2026-04-26T00:42Z)
             Result: phase-2-signoff.md drafted at repo root
             (gitignored per `phase-*-signoff.md` rule). 8 sections
             per CLAUDE.md §A.9 + Phase 1 precedent: done-when
             (3/3 with cross-platform evidence pointers + commit
             SHAs + bats test names + smoke driver paths), Phase 2
             invariant with the 3 architectural guards from
             phase2_invariant.bats, implemented-but-dormant scan
             split into "newly activated in Phase 2" (5 paths
             previously listed dormant in Phase 1 signoff —
             notification delivery in pre_tool_use_read.sh + any,
             mediator-pending banner in pre_tool_use_any.sh +
             session_start.sh, session_end per-file release path)
             and "still dormant in Phase 2" (8 paths deferred to
             Phase 3-7), risks realized (none materially fired),
             new risks discovered (2 candidates documented as
             Phase 3 Open Questions rather than promoted to §7
             rows: macOS release-side pipeline latency,
             pending.jsonl GC), plan revisions applied
             (PR-PHASE2-01 only), FINDINGS rollup table (4
             entries: F-013 RESOLVED, F-014 OPEN/Phase-3,
             F-015 OPEN/Phase-6, F-016 OPEN/Phase-7), 6 Phase 3
             Open Questions (Mediator agent contract, peer
             watchdog details, F-014 root fix design,
             pending.json/jsonl unification, macOS pipeline
             latency profile-vs-accept, JSONL GC placement),
             artifact index, recommended next step naming the
             three separate approvals (signoff content / merge /
             Phase 3 start). 360 lines — within the 200-400
             target. Awaits user review.

### Phase 2 Ship Gate Checklist (from plan §5)
- [x] Concurrent writes by two sessions on the same file: one acquires
      the lock and succeeds; the other sees `permissionDecision: "deny"`
      with actionable reason (CLAUDE.md §B.2 three-options text).
      Evidence: `src/tests/fixtures/two_session_warn/scenarios/
      02_lock_deny/` (14 explicit assertions B.1–B.14) PASS on
      macOS + Linux Docker `ubuntu:24.04` (T2.05); phase2_invariant
      .bats 3/3 confirms deny is confined to the lock-held-by-other
      branch.
- [x] `coord wait foo.ts` sleeps, receives wake via lock-release, and
      exits 0 with the unlocked status.
      Evidence: `coord_wait.bats` 12/12 (T2.03), incl. release-detection
      (timing assertion ≤ 2 s); Linux re-probe latency 1166 ms
      after release at t=1000 ms (T2.05).
- [x] Read-set warnings from Phase 1 continue working (regression).
      Evidence: `two_session_warn.sh` scenario `01_basic_warn` PASS
      end-of-phase on macOS + Linux; full bats suite 192/192 across
      both platforms.

### Notes
- The Phase 1 ship-gate invariant ("no `permissionDecision` in any
  code path") inverts in Phase 2. The Phase 2 invariant test must
  assert `permissionDecision: "deny"` appears ONLY in the
  lock-held-by-other branch of `pre_tool_use_write.sh`, and remains
  absent from every other hook (`pre_tool_use_read`, `pre_tool_use_any`,
  `user_prompt_submit`, `session_start`, `session_end`, the new
  `stop.sh` and `post_tool_use_write.sh`).
- Plan §5 Phase 2 Mediator thread says "flag file infrastructure
  appears here." Phase 1 already shipped the flag-file infrastructure
  for `corrupt_state`; Phase 2 extends with `flock_timeout` as a new
  `kind`. The full Mediator agent is Phase 3.
- Existing upgrade-point markers to retire in Phase 2:
  `src/hooks/pre_tool_use_write.sh:169` (PHASE-2 UPGRADE POINT).
  Other markers (`pre_tool_use_write.sh:182` PHASE-4,
  `pre_tool_use_any.sh:173` PHASE-3, `pre_tool_use_any.sh:184`
  PHASE-6) remain for their respective phases.
- Branch policy reconfirmed (per F-010 RESOLVED-as-WONTFIX +
  Phase 1 convention): all Phase 2 work lands on
  `phase-2/write-coordination`; merge to main on user approval at
  signoff time.


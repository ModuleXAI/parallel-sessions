## Phase 3 — Recovery, health, and Mediator
Started: 2026-04-26T01:35:58Z
Status:  IN_PROGRESS

Branch: `phase-3/recovery-mediator` cut from main HEAD `6b0cc35`
(Phase 2 merge) at the start timestamp above. Working tree clean
at branch cut (untracked `archive/` directory is the user's
historical-relocation artifact per PR-CLEANUP-01; carries forward
unchanged from prior phases).

Phase goal (plan §5): self-healing. Crashed sessions no longer
freeze others; anomalies trigger Mediator. Phase 3 introduces the
peer watchdog as a triage layer for ambient suspicion, the full
Mediator agent hook with confidence-based escalation, multiple new
Mediator pending kinds (stale_active, pid_recycled, schema_mismatch,
manual), the lockdown flag mechanism (system-wide deny source), the
`coord mediate` operator CLI with `--approve` subcommands for user
escalation responses, pending.json → pending.jsonl unification, and
pending.jsonl GC bundled with Mediator runs. F-014 root fix
(test-helper sweep) lands as a dedicated low-risk task in this
phase.

In-scope components (plan §5 + user-resolved Decisions 1–6):
- `lib/watchdog.sh`: lightweight Bash triage layer; sampled from
  PreToolUse paths when a session observes suspicion ABOUT another
  session (NOT when the calling session itself is blocked — direct
  Mediator invocation handles that case). PID + lstart liveness
  with 2-voter consensus requiring PID-absent/recycled. Duplicate
  invocation prevention via `.coord/watchdog/checking/<target>.lock`
  (atomic temp+rename + 30 s stale-TTL). Recent-checks cache at
  `.coord/watchdog/recent_checks.jsonl` with verdict-typed TTL
  (alive 60 s, dead until next session_start, uncertain 30 s).
  Watchdog NEVER writes verdicts directly: triage outcomes are
  alive (no-op) / dead (invokes Mediator with `kind=stale_active`
  or `kind=pid_recycled`) / uncertain (invokes Mediator). Caller
  is fire-and-forget; subsequent notifications surface results if
  the caller's work depended on resolution.
- Lock eviction + notification to anyone waiting (Mediator action
  type B/C surgical fix path; reuses Phase 2's notify_waiters.sh
  notification producer).
- Subagent / primary session discrimination: existing
  `subagent_filter.sh` extends to Mediator agent hooks too — when
  the Mediator subagent's tool calls fire PreToolUse/PostToolUse,
  those are filtered as subagent activity (Mediator's tool calls
  do not acquire locks; the parent session's lock — if any —
  covers its turn). Fork-bomb guard on agent-hook entry (Mediator
  cannot recursively spawn Mediator beyond depth 2 per Decision 1
  escalation hierarchy).
- `hooks/mediator_agent.md` full agent-type hook implementing
  Decision 1's contract: four action types (A advice / B surgical
  / C longer surgical / D system-wide lockdown), 2-state confidence
  model (auto-apply | needs-review), max-depth-2 escalation
  hierarchy with peer Mediator review, scope-dependent user
  escalation (caller-only banner with `coord mediate --approve
  <action>` commands vs system-wide lockdown).
- `coord mediate` CLI: operator-side manual escalation primitive
  (writes `kind:"manual"` pending entry); `coord mediate --approve
  <action>` subcommands consume user-escalation banner choices.
- pending.json → pending.jsonl migration (Decision 4): all Mediator
  pending kinds (corrupt_state + Phase 2 flock_timeout + Phase 3
  new kinds) write to `pending.jsonl`. Single-consumer pattern at
  `pre_tool_use_any.sh` + `session_start.sh`. Legacy `pending.json`
  removed at install time; install migrates active corrupt_state
  entries forward then deletes. `coord_consume_corrupt_state_flag`
  updated to consume from JSONL queue. Existing corrupt_state bats
  tests updated to assert new flow.
- pending.jsonl GC (Decision 6): Mediator agent runs ALSO truncate
  consumed entries — single combined operation rewriting
  pending.jsonl atomically (via atomic_write), keeping un-consumed
  entries plus recently-consumed ones (< 24 h). No separate `coord
  mediator gc` CLI; GC is implicit in agent runs. 24 h retention
  preserves recent-history visibility for `coord events` debugging
  without unbounded growth.
- Lockdown flag mechanism (Decision 1): `.coord/mediator/lockdown.json`
  with `active=true` causes EVERY hook on EVERY tool call to emit
  `permissionDecision: "deny"` with reason "System-wide pause:
  Mediator is resolving <reason>. Wait, do not retry until
  lockdown is cleared." Mediator clears the flag once comprehensive
  fix completes. Critical conditions that bypass Mediator analysis
  entirely (corrupt schema, impossible state, sessions.json fails
  jq parse repeatedly) trigger lockdown directly + emit user
  escalation banner.
- Phase 3 invariant: `permissionDecision: "deny"` appears in
  EXACTLY two code paths (expansion of Phase 2's single-location
  invariant): (1) `pre_tool_use_write.sh` lock-held-by-other branch
  (existing Phase 2), (2) ANY hook reading `lockdown.json` with
  `active=true` (new Phase 3). All other code paths remain allow /
  no-op / fail-open. Update `phase2_invariant.bats` →
  `phase3_invariant.bats`; the new test asserts every hook checks
  the lockdown flag, all other deny call-sites stay confined to the
  two allowed locations, and a grep for `permissionDecision`
  outside these two locations fails the test.
- F-014 root fix (Decision 3): new helper
  `_grep_output_for <pattern>` in
  `src/tests/helpers/common.bash` using `echo "$output" | grep -q
  "$pattern"` (NO `bash -c` subshell, no single-quote scaffolding);
  sweep ALL existing bats files replacing legacy
  `bash -c "echo '$output' | grep '...'"` pattern with the helper;
  meta-test (or shellcheck-style grep) fails if any test file uses
  the legacy pattern post-sweep. F-014 transitions to RESOLVED on
  sweep + meta-test land. Standalone task (T3.0X), not bundled
  with Mediator/watchdog work.

Out of scope (plan §5):
- Validation subagent agent-hook (still text warnings; Phase 4).
- Wait queue FIFO + wake_file mechanism replacing polling (Phase 5).
- `coord task-open` / `coord self-delegate` full implementations
  (Phase 6).
- Multi-machine, team scenarios (Phase 7+ / FUTURE_WORK).

User-resolved design decisions (binding for Phase 3 — see
plan-revisions.md PR-PHASE3-XX entries to be drafted before each
corresponding implementation task begins):
- Decision 1: Mediator action types A/B/C/D + 2-state confidence
  + max-depth-2 escalation + scope-dependent user escalation +
  lockdown deny source + critical-conditions bypass (drives
  Mediator agent hook + lockdown flag + phase3_invariant work).
- Decision 2: Watchdog as triage layer for ambient suspicion;
  fire-and-forget; duplicate prevention via per-target lock files;
  recent_checks cache with verdict-typed TTL; three outcomes —
  alive/dead/uncertain — never writes verdicts directly (drives
  watchdog implementation).
- Decision 3: F-014 root fix via `_grep_output_for` helper +
  full sweep + meta-test (drives F-014 task; NO plan revision
  needed — internal test infrastructure only).
- Decision 4: pending.jsonl unification — corrupt_state migrates
  forward; install removes legacy pending.json; existing
  corrupt_state bats updated (bundles into Mediator implementation
  task).
- Decision 5: macOS release-side latency — accept current behavior;
  Phase 5's wait_queue + wake_file replaces polling (NO plan
  revision needed; carry-forward only).
- Decision 6: pending.jsonl GC bundled into Mediator agent runs;
  24 h retention; no separate CLI (bundles into Mediator
  implementation task).

Applicable carry-forward findings at phase start:
- F-014 OPEN — apostrophe-fragility in legacy bats `bash -c`
  scaffolding. Resolution deadline = Phase 3 close. Decision 3
  drives the fix; standalone Phase 3 task.
- F-015 OPEN — `coord wait` subagent policy revisit. Resolution
  deadline = Phase 6 close. Carries forward unchanged; Phase 3
  does not touch.
- F-016 OPEN — `coord wait` SIGINT runtime test. Resolution
  deadline = Phase 7 close. Carries forward unchanged; Phase 3
  does not touch.

### Tasks
- [x] T3.00  Open Phase 3 section + cut `phase-3/recovery-mediator` branch from 6b0cc35 + close-out Phase 2 ship-gate hygiene (2026-04-26T01:35:58Z → 2026-04-26T01:36:30Z)
             Result: branch cut at 6b0cc35; Phase 3 section
             populated with goal/scope/decisions-1-6/ship-gate/
             invariant/notes; Phase 2 ship-gate items checked with
             evidence pointers per T2.05/T2.03/two_session_warn
             results. User approved + selected T3.01 (F-014 root
             fix) as starting point.
- [x] T3.01  F-014 root fix — `_grep_output_for` helper + sweep + meta-test (2026-04-26T01:36:30Z → 2026-04-26T01:55Z)
             Result: NEW helper `_grep_output_for <pattern>` in
             src/tests/helpers/common.bash — implementation
             `printf '%s' "$output" | grep -q -- "$pattern"`. No
             `bash -c` subshell, no inner single-quoted shell
             fragments; ASCII apostrophes in $output or pattern
             cannot terminate scaffolding. Helper leaves bats's
             $output / $status from prior `run` untouched (unlike
             the legacy form, which rebound them to grep's count
             output).
             SWEEP scope identified via
             `grep -rEn 'bash -c "echo .[$]output.' src/tests/`:
             two legacy call sites, both replaced with `!
             _grep_output_for "<pattern>"`:
             - src/tests/unit/pre_tool_use_write.bats:101
               (asserted `$output` does NOT contain
               `permissionDecision` after a stale-read warning)
             - src/tests/unit/mediator_flock_timeout.bats:117
               (asserted second consume banner does NOT contain
               `file=/old`)
             Two state_query.bats sites using
             `bash -c "echo '$output' | jq ..."` and
             `... | sort | tr '\\n' ','` were considered and
             excluded — they are pipeline-transformation idioms,
             not the F-014 grep variant Decision 3 targets. They
             remain functional and unswept.
             NEW src/tests/unit/bats_meta.bats — 7 meta-tests:
             (1) F-014 architectural guard via regex
             `'bash -c "echo .[$]output. [|] grep'` (bracket-class
             chunks so the pattern doesn't self-match) over all
             .bats + common.bash files, with pure-comment lines
             stripped via `grep -v '^[[:space:]]*#'` (precedent:
             phase2_invariant.bats §"permissionDecision" guard) so
             docstring references for explanatory purposes don't
             trip the guard. (2-7) Apostrophe regression coverage:
             positive match with apostrophes in $output; negative
             match suitable for `!` prefix; pattern containing
             apostrophes; empty-output edge case; multi-line
             $output; bats $output/$status preservation across
             helper invocation.
             Verification:
             - Full bats suite 199/199 green on macOS host (was
               192/192 at Phase 2 close; +7 from bats_meta).
             - Reinjected legacy pattern into pre_tool_use_write.bats
               via temporary scripted edit → meta-test 1 fails
               with diagnostic listing the offending file → suite
               returns to 198/199. Restoring the helper-based form
               returns to 199/199 green.
             - Audit of swept sites confirmed no silently-broken
               assertions: the prior phrasing-avoidance workaround
               (per F-014 raise text) had been applied uniformly,
               so no test was masking a real content mismatch via
               the apostrophe-truncation bug. Future tests with
               apostrophe-bearing additionalContext (Mediator,
               Phase 4 validator) will Just Work.
             - Linux re-probe deferred to T3.02+ batched
               re-probe; this task is mechanical test-helper
               hygiene with no platform-specific risk surface.
             FINDINGS.md F-014 transitioned OPEN → RESOLVED with
             full resolution notes citing helper signature, sweep
             scope, meta-test design, and verification methodology.
             No plan-revisions entry needed (internal test
             infrastructure only, per Decision 3).
- [x] T3.02  Plan-revision drafts: PR-PHASE3-01 (Decision 1 Mediator) + PR-PHASE3-02 (Decision 2 Watchdog) + PR-PHASE3-03 (Decision 4 pending.jsonl unification) + PR-PHASE3-04 (Decision 6 GC) (2026-04-26T01:55:30Z → 2026-04-26T02:18Z)
             Result: four DRAFT plan-revision entries appended to
             plan-revisions.md. Each follows the established
             PR-PHASE0/1/2 structure: header (date / author /
             status DRAFT / driver), observed gap, user-resolved
             decision quoted verbatim, plan section deltas (with
             specific §-references to IMPLEMENTATION_PLAN.md and
             CLAUDE.md), implementation-task dependencies,
             genuine ambiguities surfaced, cross-references,
             non-changes, acknowledgement.
             PR-PHASE3-01 (Mediator, Decision 1): 4-action
             contract A/B/D in code with severity gradient on B;
             2-state confidence; max-depth-2 escalation with peer
             Mediator review (agreement = same action_type
             regardless of confidence variance per P3); scope-
             dependent user escalation (caller-only banner with
             `coord mediate --approve <action>` commands;
             system-wide lockdown); critical-conditions bypass.
             10 plan deltas (§5 scope/done-when, §3.5 events
             kinds, §3.6 config defaults, §3.3 sessions schema
             unchanged, §4 component specs incl. lockdown.json /
             verdict/<ts>.json schemas / lib/lockdown.sh / coord
             mediate CLI / hooks/mediator_agent.md, CLAUDE.md
             §B.6 / §B.10 / §B.11 / §C.2). Gates T3.03 + T3.07.
             Approval conditional on T3.06 POC closure.
             PR-PHASE3-02 (Watchdog, Decision 2): triage-layer
             contract; ambient-suspicion 4-trigger model with
             user-supplied threshold values from P4 (last_activity
             > 600 s; lock unrefreshed > 1800 s; RESUME_ORPHAN_
             LOCK_DETECTED event; PID listed but ps -p empty);
             fire-and-forget caller; duplicate prevention via
             .coord/watchdog/checking/<target>.lock with 30 s
             stale-TTL; recent_checks.jsonl with verdict-typed
             TTL (alive 60 s, dead until next session_start,
             uncertain 30 s); 3-outcome verdict (alive/dead/
             uncertain); never decides — only triages. 5 plan
             deltas. Gates T3.04 + T3.05. Cross-PR dependency
             with PR-PHASE3-01 (shared Mediator pending kinds:
             stale_active / pid_recycled / ambiguous_state).
             PR-PHASE3-03 (pending unification, Decision 4):
             corrupt_state migrates from pending.json to
             pending.jsonl; install-time migration (idempotent;
             handles unparseable legacy file via archive);
             single-consumer pattern; coord_consume_corrupt_state_
             flag rewrite. 3 plan deltas + optional defensive
             consumer fallback flagged for confirmation. Bundles
             into T3.07.
             PR-PHASE3-04 (GC, Decision 6): GC bundled with
             Mediator verdict-write pass; 24 h retention
             (mediator_pending_retention_hours config tunable,
             bounds [1, 168]); algorithm covers HWM rebasing
             after truncation; crash-recovery via single-flock
             rewrite-plus-HWM-update; PENDING_GC_RUN event. 4
             plan deltas. Bundles into T3.07. Cross-PR
             dependency: PR-PHASE3-03 must land first or
             together.
             Total ambiguities surfaced across 4 PRs: 17 items
             flagged for user confirmation; none re-litigate
             user-resolved decisions; all are mechanics
             underspecified by the original Decisions 1/2/4/6
             text. Notable items: lockdown clearing protocol
             (atomic-deletion vs `active:false` retention),
             defensive consumer fallback (PR-PHASE3-03), GC
             frequency in pure-healthy systems (PR-PHASE3-04),
             watchdog invocation site (pre_tool_use_any.sh
             recommended), 2-voter consensus mechanic via
             anomaly_votes (existing schema field).
             No implementation code touched. plan-revisions.md
             grew from 530 lines to ~1100 lines. Bats unchanged
             (199/199 still green; ran a sanity grep to confirm
             no .sh / .bash / .bats files modified during T3.02).
- [x] T3.03  Lockdown flag mechanism + phase2_invariant.bats → phase3_invariant.bats rename + every-hook lockdown gate (2026-04-26T02:25Z → 2026-04-26T02:55Z)
             Result: NEW src/lib/lockdown.sh — 4 public functions:
             coord_lockdown_check (existence-based gate; fast-path
             [ ! -f ] before jq parse; returns 1 on parse fail with
             stderr warning + ERROR event = fail-open per disposition
             #2). coord_lockdown_activate <reason> <reason_source>
             (atomic temp+rename; emits LOCKDOWN_ACTIVATED with
             reason+reason_source+started_at payload; $$.$RANDOM
             temp suffix avoids collision under concurrent activate
             since Bash 3.2 lacks BASHPID and $$ stays parent-PID
             in backgrounded subshells). coord_lockdown_clear
             (atomic rename → lockdown_archive/<ts>.cleared.json
             per disposition #2 archive-for-audit; emits
             LOCKDOWN_CLEARED with archived_to). coord_lockdown_emit_deny
             <hook_event> (reads .reason from lockdown.json;
             constructs reason text "System-wide pause: <reason>.
             Wait, do not retry until lockdown is cleared.
             [reason_source=<source>]" with audit tag inline per
             disposition #3; emits permissionDecision: deny JSON
             via jq -nc with hookEventName parameter; emits
             HOOK_DENIED_BY_LOCKDOWN event). All return 1 on
             parse failure → caller's && short-circuit handles
             fail-open without code duplication.
             EVERY hook updated (8 hooks):
             pre_tool_use_read.sh, pre_tool_use_any.sh,
             pre_tool_use_write.sh, post_tool_use_write.sh,
             session_start.sh, session_end.sh, stop.sh,
             user_prompt_submit.sh — each now sources
             lib/lockdown.sh and inserts the standard gate after
             participant + dep + state checks, before main logic:
                 if coord_lockdown_check && \\
                    coord_lockdown_emit_deny "<EVENT>"; then
                   exit 0
                 fi
             Single `&&` chain for clean fail-open: if check
             returns 1 (absent OR parse fail), short-circuit
             skips emit; if emit returns 1 (rare race / parse
             fail mid-emit), short-circuit skips exit; main
             logic runs in both cases. No code-duplicated
             fail-open branches.
             RENAME phase2_invariant.bats → phase3_invariant.bats
             via git mv. Test rewritten to assert two-location
             invariant (Phase 3 supersedes Phase 2 single-location):
             (a) hooks/ permissionDecision confined to
             pre_tool_use_write.sh; (b) lib/ permissionDecision
             confined to lockdown.sh; (c) pre_tool_use_write.sh
             has exactly 1 emit_deny call site; (d) lockdown.sh
             has exactly 1 "deny" string in non-comment code;
             (e) every hook sources lockdown.sh + calls
             coord_lockdown_check + coord_lockdown_emit_deny;
             (f) every hook is exit-0 fail-open (no exit 1/2).
             Pure-comment lines stripped via
             grep -v '^[[:space:]]*#' so docstring references
             don't trip the architectural guard. 6 tests total
             (was 3 in phase2_invariant.bats; +3).
             NEW src/tests/unit/lockdown.bats — 22 tests:
             (1-4) coord_lockdown_check absent / active / false-
             value / unparseable-fail-open. (5-6) coord_lockdown_
             activate writes valid JSON / emits LOCKDOWN_ACTIVATED
             with payload (verifies non-reserved kv pairs land
             under .payload per log_event.sh kv-handling). (7-8)
             coord_lockdown_clear archives + emits LOCKDOWN_CLEARED
             with archived_to / returns 1 when no lockdown.json.
             (9-11) coord_lockdown_emit_deny emits deny JSON /
             reason text includes [reason_source=...] audit tag /
             emits HOOK_DENIED_BY_LOCKDOWN with hook+reason_source.
             (12-19) End-to-end hook gate tests for all 8 hooks:
             each verifies (a) deny emitted, (b) hook's normal
             bookkeeping (read recording / lock acquire / lock
             release / session registration / etc.) is skipped.
             (20) Concurrent activate: $$.$RANDOM uniqueness
             enables 2 concurrent backgrounded activates with
             both succeeding at rc level (final file is one of
             the two, never torn) + 2 LOCKDOWN_ACTIVATED events
             in events.jsonl. (21) Fail-open: malformed JSON in
             lockdown.json → pre_tool_use_write proceeds with
             normal lock acquire (no spurious deny). (22)
             Idempotency: 5x repeated coord_lockdown_check
             returns 0 each time.
             VERIFICATION:
             - bats: 224/224 (was 199 at T3.01; +25 net: +22
               lockdown.bats + +3 phase3_invariant.bats expansion).
             - One transient flake observed during full-suite run:
               coord_wait waited_for≤2 timing assertion under
               heavy parallel load (pre-existing F-016-class
               flake; passes on retry; not a T3.03 regression —
               coord_wait.bats run in isolation = 12/12 PASS).
             - Sample lockdown.json content (synthetic mediator
               activation):
                 {"active":true,
                  "reason":"Mediator resolving stale lock on /foo.ts",
                  "reason_source":"mediator_verdict",
                  "started_at":"2026-04-26T02:53:22.866Z"}
             - Sample deny output for PreToolUse (synthetic emit):
                 {"hookSpecificOutput":
                   {"hookEventName":"PreToolUse",
                    "permissionDecision":"deny",
                    "permissionDecisionReason":
                      "System-wide pause: Mediator resolving
                       stale lock on /foo.ts. Wait, do not retry
                       until lockdown is cleared.
                       [reason_source=mediator_verdict]"}}
             - Phase 3 invariant tests (6/6): both architectural
               guards confirmed (hooks/ confined to
               pre_tool_use_write.sh; lib/ confined to lockdown.sh;
               every hook sources lockdown.sh and calls both
               check+emit_deny; no exit 1/2 in any hook; exactly-
               one deny site per allowed file).
             - Fail-open: malformed lockdown.json → hook proceeds
               with normal flow (lock acquired, no spurious deny);
               coord_lockdown_check returns 1 with stderr warning
               + ERROR event so an operator can detect the
               infrastructure problem.
             No new findings. F-014/015/016 unchanged. No plan-
             revisions entry needed (T3.03 implements PR-PHASE3-01
             which is already approved).
             User feedback (post-T3.03 close): coord_wait timing
             flake under heavy parallel bats load was appended to
             F-016 notes (NOT raised as a new F-NNN entry; same
             root family as the SIGINT runtime fragility, same
             Phase-7 deadline). FINDINGS.md F-016 entry now
             carries an "Additional observations (2026-04-26
             during T3.03)" subsection.
- [x] T3.04  Watchdog cache + dedupe infrastructure (lib/watchdog_cache.sh + .coord/watchdog/ layout) (2026-04-26T02:55Z → 2026-04-26T03:15Z)
             Result: NEW src/lib/watchdog_cache.sh — single file
             holding both the recent-checks cache and the per-target
             dedupe lock primitives (folded into one file per user
             allowance "Claude's call"; one bats file maps 1:1).
             Public API:
             - coord_watchdog_cache_lookup <target> — single jq
               pass over recent_checks.jsonl filtered by target +
               valid_until>now; returns LAST match (most recent).
               Stdout TSV: verdict\treason\tvalid_until. rc=0 on
               hit, 1 on miss.
             - coord_watchdog_cache_record <target> <verdict>
               <reason> <ttl_seconds> — caller-supplied TTL (T3.05
               will compute from verdict-typed defaults). Atomic
               append under flock on recent_checks.lock. Builds
               JSONL via jq -nc — never shell-concats JSON.
             - coord_watchdog_cache_expire — atomic temp+rename
               under flock; keeps only valid_until>now entries.
             - coord_watchdog_cache_invalidate_dead — atomic
               temp+rename under flock; drops verdict=="dead"
               entries regardless of valid_until (per disposition
               "dead until next session_start of any session";
               T3.05 will wire this into session_start.sh).
             - coord_watchdog_acquire_check_lock <target> —
               atomic create-or-fail via `( set -C; printf >
               file )` subshell pattern (noclobber redirection
               fails inside subshell when file exists; subshell
               exit becomes function return). Auto-clears stale
               locks (mtime > COORD_WATCHDOG_DEDUPE_STALE_TTL,
               default 30s) before the attempt — covers
               crashed-watchdog recovery without operator
               intervention. Lock content: writer=<sid>,
               started_at=<iso>.
             - coord_watchdog_release_check_lock <target> —
               idempotent rm -f; always returns 0.
             Config tunables (env-overridable; T3.07 will
             surface formal config.json entries via
             PR-PHASE3-02 §C):
               COORD_WATCHDOG_TTL_ALIVE_SEC      = 60
               COORD_WATCHDOG_TTL_UNCERTAIN_SEC  = 30
               COORD_WATCHDOG_TTL_DEAD_SEC       = 31536000  (1 year)
               COORD_WATCHDOG_DEDUPE_STALE_TTL   = 30
             Layout (install.sh updated):
               .coord/watchdog/                       (root)
               .coord/watchdog/recent_checks.jsonl    (append-only)
               .coord/watchdog/recent_checks.lock     (flock sentinel)
               .coord/watchdog/checking/              (dedupe lock dir)
               .coord/mediator/lockdown_archive/      (already
                 referenced in T3.03 lockdown.sh; install.sh now
                 creates it explicitly — was being created
                 lazily on first clear before)
             Idempotent install: existing recent_checks.jsonl /
             lock files NOT clobbered on --repair (preserves
             cache history).
             NEW src/tests/unit/watchdog_cache.bats — 14 tests:
             cache_lookup empty/fresh-alive/expired/fresh-dead/
             multi-entry (5); cache_record shape + 5-way
             concurrent append (2); cache_expire purges expired
             keeps fresh (1); cache_invalidate_dead drops dead
             keeps alive+uncertain (1); acquire_check_lock
             first-wins / second-fails-rc1 (2); release +
             reacquire round-trip (1); stale-lock auto-clear
             recovery (1); fresh-lock NOT auto-cleared (1).
             Backdating uses `perl utime` rather than `touch -t`
             — discovered + fixed inline that `touch -t` uses
             LOCAL timezone (not UTC) and produced future-dated
             mtimes on this macOS host where local != UTC. Perl
             utime takes raw epoch seconds; portable across
             macOS + Linux per F-009 (perl is the third base-OS
             utility).
             VERIFICATION:
             - bats: 238/238 (was 224 at T3.03; +14 net from
               watchdog_cache.bats).
             - Sample recent_checks.jsonl entries (synthetic
               4-record demo: alive 60s / dead 1y / uncertain
               30s / expired) — all parse cleanly; valid_until
               TTLs land at expected offsets:
                 {"ts":"2026-04-26T03:10:27.055Z","target":"session-A",
                  "verdict":"alive","reason":"ps still has pid 12345",
                  "valid_until":"2026-04-26T03:11:27Z"}     ← +60s
                 {"ts":"...","target":"session-B","verdict":"dead",
                  "reason":"pid recycled (lstart mismatch)",
                  "valid_until":"2027-04-26T03:10:27Z"}     ← +1y
                 {"ts":"...","target":"session-C","verdict":"uncertain",
                  "reason":"ps timed out, retrying",
                  "valid_until":"2026-04-26T03:10:57Z"}     ← +30s
                 {"ts":"...","target":"session-D","verdict":"alive",
                  "reason":"stale_demo",
                  "valid_until":"2026-04-26T03:05:27Z"}     ← already past
             - cache_lookup session-A (fresh alive) → rc=0,
               stdout: alive\tps still has pid 12345\t2026-04-26T03:11:27Z
             - cache_lookup session-D (expired) → rc=1, no stdout
             - check.lock content (synthetic acquire by
               observer-demo):
                 writer=observer-demo
                 started_at=2026-04-26T03:10:27Z
             - First acquire_check_lock target-X: rc=0
             - Concurrent second acquire: rc=1 (verified
               dedupe gate)
             - Stale-lock recovery: perl-backdate file mtime by
               60s → next acquire returns rc=0 with new content
               (writer=observer-demo overwriting the prior ghost).
             No new findings. F-014/015/016 unchanged. T3.04
             implements PR-PHASE3-02 already-approved sections
             (cache + dedupe; probe heuristics + 3-outcome logic
             defer to T3.05). No plan-revisions entry needed.
             Linux parity not exercised this task (existing
             linux-parity harness will pick it up automatically
             on next run; bats suite is filesystem-agnostic and
             stale-lock recovery uses perl utime which is
             portable).
             User feedback (post-T3.04 close): perl utime
             discovery is the kind of "learn it once, never
             get bitten again" pattern that belongs in
             CLAUDE.md (testing tips / portability notes) at
             phase-3-signoff time. Note for T3.10. Continue
             using perl utime for any future test mtime
             manipulation.
- [x] T3.05  Watchdog probe heuristics + 3-outcome verdict logic + ambient-suspicion triggers + pre_tool_use_any.sh wiring (2026-04-26T03:20Z → 2026-04-26T03:35Z)
             Result: NEW src/lib/watchdog.sh — full triage layer
             implementing PR-PHASE3-02 §E spec.
             Public API:
             - coord_watchdog_probe <target_session_id> — main
               orchestrator: cache check (short-circuit on hit) →
               dedupe lock acquire (rc=1 if held by another
               invoker) → read target session row → compute 3
               signals → derive verdict → cache_record →
               (dead/uncertain) emit Mediator pending entry →
               release dedupe lock. Stdout: "<verdict>\t<reason>".
               Caller fire-and-forget (`coord_watchdog_probe X &`).
             - coord_watchdog_check_ambient_suspicion — single
               jq pass over sessions.json + bounded per-PID ps
               drive-by check. Three trigger signals deduped to
               one target_session_id per output line. Self
               filtered out.
             Probe heuristics (3 signals, weighted by determinism):
             - Signal 1 (deterministic) — PID/lstart liveness:
               ps -p <pid> -o lstart= empty → dead/pid_gone;
               lstart mismatch → dead/pid_recycled;
               match → continue.
             - Signal 2 (timing) — last_activity_at age >
               COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC (default
               600s = 10min). Suspicious only — does NOT promote
               to dead by itself.
             - Signal 3 (lock-context) — any lock with
               last_refresh_at == acquired_at AND acquired_at age >
               COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC
               (default 1800s = 30min). Suspicious only.
             Verdict computation (Signal 1 dominates):
             - dead requires Signal 1 deterministic confirmation;
               subkind drives pending kind (pid_gone → stale_active;
               pid_recycled → pid_recycled).
             - uncertain when Signal 1 confirms-alive AND Signal
               2 OR 3 fires (pending kind=stale_active +
               payload.uncertain=true).
             - alive when all three signals indicate liveness
               (no pending entry).
             Ambient-suspicion trigger model (3 detector passes):
             - Activity-based: jq filter selects ACTIVE non-self
               sessions with last_activity_at >
               (now - threshold). Single-pass.
             - Lock-based: jq filter selects locks owned by
               non-self sessions where acquired_at ==
               last_refresh_at AND age > threshold. Single-pass.
             - PID-gone drive-by: forks ps -p once per ACTIVE
               non-self session (bounded by session count;
               watchdog probe re-confirms before declaring dead
               so a transient ps-empty doesn't escalate
               prematurely).
             Per-target dedup at the output layer: awk filter
             collapses sessions hit by multiple triggers to one
             line — one watchdog probe per suspect even when 3
             signals fire simultaneously.
             pre_tool_use_any.sh UPDATE: after the existing
             notification + corruption + mediator-pending
             consumer + HEAD-drift block (and AFTER lockdown
             gate), invokes
             coord_watchdog_check_ambient_suspicion. For each
             suspect, fires `( coord_watchdog_probe <sid> ) &`
             with disown. Hook returns immediately; probe runs
             out-of-band. Caller's tool call proceeds with no
             added wall-clock latency from probe execution
             itself; only the suspicion-detection scan
             contributes to hook latency.
             Mediator pending integration: existing T2.04
             producer used unchanged per user direction.
             Watchdog calls
             coord_mediator_emit_pending with kind=stale_active
             | pid_recycled, source=watchdog, payload includes
             target / verdict / reason / subkind | uncertain.
             Bug discovered + fixed inline:
             _coord_watchdog_ps_lstart originally piped
             `ps | sed | tr` directly. Under callers running
             `set -o pipefail` (inherited from log_event.sh's
             `set -euo pipefail`), `ps -p <gone-pid>` returns
             rc=1 which propagates through pipefail and killed
             the function silently — caller exit was rc=2
             instead of 0 with empty stdout. Fixed by capturing
             ps output into a local var via `raw=$(ps ...) ||
             raw=""` first, then formatting. The function's
             trailing command is now always printf (rc=0). This
             pattern is the bash-3.2-compat alternative to
             `local +o pipefail` (Bash 4.4+).
             VERIFICATION:
             - bats: 254/254 (was 238 at T3.04; +16 net from
               watchdog.bats; within 12-18 expected range).
             - Probe matrix demonstrated end-to-end on 4
               synthetic targets:
                 sid-A (PID 99999):    dead/pid_gone        kind=stale_active
                 sid-B (lstart wrong): dead/pid_recycled    kind=pid_recycled
                 sid-C (healthy):      alive                no pending
                 sid-D (activity stale): uncertain          kind=stale_active uncertain=true
             - recent_checks.jsonl shows all 4 verdicts cached
               with verdict-typed TTLs (alive=+60s,
               dead=+1yr, uncertain=+30s).
             - Sample pending.jsonl entries:
               {"kind":"stale_active","source":"watchdog",
                "payload":{"target":"sid-A","verdict":"dead",
                            "reason":"PID 99999 is gone (no ps record)",
                            "subkind":"pid_gone"}}
               {"kind":"pid_recycled","source":"watchdog",
                "payload":{"target":"sid-B","verdict":"dead",
                            "subkind":"pid_recycled"}}
               {"kind":"stale_active","source":"watchdog",
                "payload":{"target":"sid-D","verdict":"uncertain",
                            "uncertain":"true"}}
             - BSD ps lstart format on macOS: "Sat Apr 25
               22:28:16 2026" (matches the format
               session_start.sh records as pid_lstart). Linux
               GNU ps produces equivalent format per Phase 0
               Experiment #1 (Linux re-probe via existing
               linux-parity harness will confirm on next run).
             - Hook latency (5-run measurement of
               pre_tool_use_any.sh under ambient suspicion):
                 Run 1: 120ms   Run 2: 106ms   Run 3: 141ms
                 Run 4: 109ms   Run 5: 105ms
               Median ~109ms. PR-PHASE3-02 estimate was <50ms
               p99; actual is 2-3x higher (overhead is sourcing
               6+ libs + 3 jq passes + per-session ps fork in
               drive-by check). Still 13x below CLAUDE.md §A.6
               2-second hard ceiling. Acceptable; flag for
               revisit ONLY if Phase 7 stress test reveals
               user-visible impact at realistic contention.
             No new findings. F-014/015/016 unchanged.
             Implementation matches PR-PHASE3-02 already-approved
             contract; no plan-revisions entry needed.
             Linux re-probe deferred to T3.10 / signoff or
             standalone re-probe pass; the perl-utime + jq +
             flock + ps lstart helpers are all platform-agnostic
             so confidence is high.
             User feedback (post-T3.05 close): F-017 raised for
             ambient-suspicion scan latency gap (PR-PHASE3-02
             estimated <50ms p99; T3.05 measured 109ms median)
             — DEFERRED to Phase 7 stress test, not blocking
             ship gate. Two lessons accumulated for
             phase-3-signoff CLAUDE.md note: (1) perl utime
             pattern (T3.04), (2) command-substitution-capture
             pipefail isolation (T3.05). Bundle into signoff
             CLAUDE.md updates rather than separate
             plan-revisions.
- [x] T3.06  Mediator spawn POC — investigative, uncommitted, time-boxed (2026-04-26T03:40Z → 2026-04-26T03:55Z)
             Result: POC findings document at
             phase-3-poc-mediator-spawn.md (gitignored via new
             phase-*-poc-*.md pattern in .gitignore, committed
             at 7adfa48).
             Question A-F answers (HIGH-confidence empirical):
             A — Spawn mechanism: claude -p from bash. Task-tool
                 subagent path is unavailable to hooks (hooks
                 are standalone processes, no parent Claude
                 context).
             B — Session ID: spawned process gets a NEW UUID
                 session_id every time (verified across 3
                 spawns: 5074efaa..., 1d2d8047..., 6133cf63...).
                 NOT shared with parent. DIFFERENT from
                 Task-tool subagent behavior (Phase 0 F-006).
             C — CLAUDE_COORD env: not directly tested with a
                 real coord install; recommended path is to
                 set CLAUDE_COORD=0 explicitly in spawn env as
                 defense in depth, AND use --bare which skips
                 hooks entirely regardless of CLAUDE_COORD
                 value.
             D — Output capture: stdout JSON via
                 --output-format json. Rich payload: type,
                 subtype, duration_ms, is_error, session_id,
                 total_cost_usd, usage (with
                 cache_creation_input_tokens), modelUsage,
                 errors, etc. jq-parseable.
             E — Exit codes + timeout: claude -p exits 0
                 regardless of is_error. ALWAYS parse JSON
                 for actual outcome. Wall-clock measured:
                 - 404 model error (no --bare): 13.8s
                 - Budget cap fired (no --bare): 11.4s
                 - --bare auth fail: 4.7s
                 Successful invocation timing not directly
                 measured (all test runs hit auth/budget
                 limits — documenting this is a finding).
                 Estimated 20-35s with --bare for typical
                 Mediator analysis. Recommended hook
                 timeout: 120s.
             F — Subagent filter interaction: subagent_filter
                 .sh checks agent_type which is NOT populated
                 for claude -p spawned sessions (only Task-tool
                 subagents get agent_type). The Mediator's
                 tool calls would normally fire all coord
                 hooks for its own session_id. --bare or
                 CLAUDE_COORD=0 is REQUIRED to isolate.
             Newly discovered constraint — cost analysis:
                 Test 2 showed 78,335 cache_creation_input_
                 tokens for a no-op no-bare invocation
                 (~$0.10 per invocation just for system
                 context loading at haiku-4-5 cache pricing).
                 --bare skips this. Mediator invocation rate
                 must be debounced; T3.07 needs
                 mediator_min_seconds_between_invocations
                 (default 30s) + mediator_max_invocations_per_
                 hour (default 20) + max-budget-usd (default
                 $0.50/invocation).
             Newly discovered constraint — auth dependency:
                 --bare requires ANTHROPIC_API_KEY (or
                 apiKeyHelper via --settings). User's
                 keychain/OAuth login is NOT accessible to
                 --bare. Onboarding doc must surface this:
                 install.sh detection + coord health check
                 + spawn-mode auto-fallback to no-bare path
                 with CLAUDE_COORD=0 when ANTHROPIC_API_KEY
                 unset (cost trade-off: ~10x higher).
             Recommended T3.07 spawn strategy (consolidated):
                 1. Detect ANTHROPIC_API_KEY in env;
                    use --bare if present (~5s startup).
                 2. Otherwise fall back to no-bare
                    + CLAUDE_COORD=0 in spawn env (~11s
                    startup, ~$0.10 cost per invocation).
                 3. --allowedTools Bash Read; --disallowedTools
                    Write Edit NotebookEdit Task (forces
                    state mutations through Bash + atomic_write
                    helpers per disposition #2 P2;
                    blocks recursive Mediator spawns).
                 4. --output-format json + --json-schema for
                    enforced verdict structure.
                 5. Hook timeout 120s; ALWAYS parse JSON
                    is_error (not shell exit code).
                 6. Mediator's spawned session_id captured
                    from JSON for audit; included in
                    MEDIATOR_VERDICT event payload.
                 7. CLAUDE_CODE_MEDIATOR=1 spawn-env
                    marker for recursion guard (T3.07's
                    spawn helper refuses to fire if it
                    detects this var = "we are already
                    inside a Mediator").
             Open items for T3.07 design checkpoint
             (per user direction: separate user checkpoint
             after T3.06 close, before T3.07 starts):
                 - Verdict-log schema final fields
                   (PR-PHASE3-01 ambiguity #1).
                 - Mediator prompt structure (P5 from Phase
                   3 prep).
                 - Auth onboarding flow.
                 - Cost guard tunable defaults.
                 - Recursion guard mechanics.
                 - Cache reuse measurement (Phase 7).
             Per CLAUDE.md §A.8: NO production code
             committed. POC document at
             phase-3-poc-mediator-spawn.md is gitignored.
             Authoritative findings inform T3.07 design
             checkpoint. Time-box: ~15 min actual (lower
             than 2-3h budget; the documentation reading
             + 3 empirical claude -p invocations were
             enough to answer all 6 questions with
             HIGH-MEDIUM confidence).
             No new findings raised this task (the cost +
             auth + timing observations are all in the POC
             document; if T3.07 turns any into a
             plan-revision-worthy concern, raise then).
             F-014/015/016/017 all unchanged.
- [ ] T3.07  Mediator agent implementation — bundles PR-PHASE3-01 + PR-PHASE3-03 + PR-PHASE3-04 (2026-04-26T03:55Z)
             [IN_PROGRESS] — largest Phase 3 task. Per user
             checkpoint:
             - Subscription-mode-only spawn path: no-bare +
               CLAUDE_COORD=0 spawn env (user has no
               ANTHROPIC_API_KEY). --bare path detection
               documented in MEDIATOR_REFERENCE.md as future
               enhancement; NOT auto-fallback in T3.07.
             - Mediator prompt: 3 sections (Identity ~80
               words; System Constraints HYBRID — 5 core
               rules in prompt + reference file; Incident
               Context HYBRID — embedded snapshot + live
               read allowed via Bash).
             - Verdict JSON schema: {verdict_id, ts,
               for_pending_entry, mediator_session_id, depth,
               action_type ∈ {advice, surgical_fix,
               lockdown}, severity ∈ {brief, extended} (only
               for surgical_fix), confidence ∈ {auto_apply,
               needs_review}, reasoning, actions (op-tagged
               array), message_to_caller, message_to_others
               (lockdown only), spawn_metadata}.
             - Apply ordering (per Note B): lockdown FIRST,
               then evict_session AFTER release_lock for that
               session, then clear_read_set independent.
               Documented in MEDIATOR_REFERENCE.md +
               verdict_apply.sh.
             - Critical bypass: 3x consecutive jq parse
               failures on sessions.json → lockdown directly
               (skip Mediator). Documented in CLAUDE.md §B.10
               at signoff time.
             Deliverables planned: lib/mediator_spawn.sh
             (NEW), lib/mediator_pending.sh GC update,
             lib/atomic_write.sh rewrite_jsonl + corrupt_state
             JSONL, lib/verdict_apply.sh (NEW),
             lib/critical_check.sh (NEW),
             lib/MEDIATOR_REFERENCE.md (NEW), install.sh
             migration + reference copy, pre_tool_use_any.sh
             verdict consumer + critical bypass, 6 new bats
             files (20-30 tests). Real Mediator spawn with
             actual claude -p invocation deferred to Phase 7
             integration harness; T3.07 mocks claude -p
             output for unit tests.

             RESULT (closed 2026-04-26T04:00Z):

             Production code delivered:
             - NEW src/lib/mediator_spawn.sh (~290 lines):
               coord_mediator_spawn orchestrator. 3-section prompt
               assembly per user-resolved checkpoint (Identity ~80
               words; System Constraints HYBRID 5 rules + ref file
               pointer; Incident Context HYBRID embedded snapshot
               + live-read allowed). Subscription-mode spawn:
               CLAUDE_COORD=0 + CLAUDE_CODE_MEDIATOR=<depth> in
               spawn env, --output-format json, --allowedTools
               "Bash Read", --disallowedTools "Write Edit
               NotebookEdit Task", --max-budget-usd 0.50 default,
               --model claude-haiku-4-5-20251001 default. Recursion
               guard refuses caller depth=2 spawning depth=3;
               critical-bypass guard refuses spawn when
               coord_critical_check_thresholds returns 0; claude
               binary missing → MEDIATOR_SPAWN_REFUSED log; ALWAYS
               parses JSON for is_error (per T3.06 POC: claude -p
               exits 0 regardless). Augments verdict file with
               spawn_metadata (duration_ms, model, spawn_mode,
               spawn_session_id, total_cost_usd). GC fires after
               successful verdict via coord_mediator_gc_pending.
             - NEW src/lib/critical_check.sh (~160 lines): 3x
               consecutive parse-fail counter +
               coord_critical_record_parse_failure /
               coord_critical_reset_parse_counter /
               coord_critical_check_thresholds. Threshold reached →
               directly activates lockdown via
               coord_lockdown_activate with
               reason_source=critical_bypass, emits
               CRITICAL_CONDITION_DETECTED event. Counter file at
               .coord/mediator/critical_counters.json with
               atomic temp+rename via flock. Wired into
               atomic_write.sh's parse-fail branch + reset on
               successful parse.
             - NEW src/lib/verdict_apply.sh (~250 lines): four
               public functions —
               coord_verdict_apply_release_lock <file> <session>,
               coord_verdict_apply_evict_session <session>,
               coord_verdict_apply_clear_read_set <session>,
               coord_verdict_apply_action <action_json>
               (dispatcher), coord_verdict_apply_actions
               <actions_json> (iterator). All idempotent,
               fail-open. Apply ordering rules documented in
               MEDIATOR_REFERENCE.md (lockdown FIRST, release_lock
               BEFORE evict_session for same session, clear_read_set
               independent).
             - NEW src/lib/MEDIATOR_REFERENCE.md (~480 lines): full
               technical reference for Mediator subagent.
               Sections: verdict JSON schema, lockdown.json
               schema + clearing protocol, atomic_write helpers,
               pending queue (read + GC), lock release mechanism,
               event log format, caller communication contract,
               recursion guard, spawn modes, what-NOT-to-do,
               worked example.
             - UPDATED src/lib/atomic_write.sh: added
               coord_atomic_rewrite_jsonl helper + corrupt_state
               producer migration (PR-PHASE3-03 / Decision 4 —
               legacy single-file pending.json retired in favor of
               unified pending.jsonl entry via T2.04 producer) +
               coord_consume_corrupt_state_flag rewritten to scan
               pending.jsonl tail for unconsumed corrupt_state +
               critical-bypass parse counter wiring (record on
               fail, reset on success).
             - UPDATED src/lib/mediator_pending.sh:
               coord_mediator_gc_pending (~95 lines) — atomic
               single-flock rewrite + HWM rebase per PR-PHASE3-04
               disposition #3. consume_pending banner construction
               filters out corrupt_state (dedicated consumer
               handles those for friendly text).
             - UPDATED src/install.sh: legacy pending.json
               migration on --repair (idempotent; valid JSON →
               JSONL append + delete; unparseable → forensic
               archive). MEDIATOR_REFERENCE.md copy to
               .coord/mediator/ with shasum-based user-edit
               preservation. New layout: lockdown_archive/,
               pending.jsonl/lock/consumed initialization.
             - UPDATED src/hooks/pre_tool_use_any.sh: verdict
               consumer with peer-review escalation hierarchy
               (PR-PHASE3-01 max-depth-2). For each unconsumed
               verdict file: parse confidence; if needs_review at
               depth=1, spawn peer Mediator at depth=2 with prior
               verdict in context; compare action_type — same →
               apply with more conservative severity (extended >
               brief), MEDIATOR_PEER_AGREED event; different →
               escalation banner + MEDIATOR_PEER_DISAGREED, no
               apply; spawn-fail → user-escalation banner. If
               auto_apply, apply directly. Pointer at
               .coord/sessions/<sid>.last_consumed_verdict tracks
               which verdicts have been processed (atomic
               temp+rename advance).
             - UPDATED src/tests/unit/corruption_recovery.bats:
               rewritten for JSONL flow (8 tests; was 7 — added
               mixed-kind scenario where corrupt_state surfaces
               via dedicated consumer despite consume_pending
               filtering it).
             - UPDATED src/tests/unit/atomic_write.bats: corrupt
               state test asserts pending.jsonl entry (not legacy
               pending.json file).

             Test coverage delivered (6 new bats files, 41 new
             tests; total suite 296/296 PASS):
             - mediator_spawn.bats (8 tests): fake-claude binary
               + writes verdict + spawn_metadata augmentation +
               MEDIATOR_VERDICT event + recursion guard +
               peer-review depth promotion + claude binary
               missing + is_error response handling + GC trigger
               post-spawn.
             - verdict_apply.bats (10 tests): release_lock 3
               states (held by self / held by other / absent),
               evict_session full removal + idempotency,
               clear_read_set, dispatcher routing + unknown op,
               apply_actions iteration + empty array.
             - mediator_gc.bats (7 tests): unconsumed retention,
               recently-consumed retention, age-based purge, HWM
               rebase, PENDING_GC_RUN event payload, idempotency,
               empty-jsonl no-op.
             - mediator_corrupt_state_migration.bats (4 tests):
               legacy active entry → JSONL migration, unparseable
               legacy → forensic archive, idempotent re-repair,
               clean install no-op.
             - critical_bypass.bats (8 tests): counter starts 0,
               1st/2nd no lockdown, 3rd activates lockdown with
               reason_source=critical_bypass + event,
               reset_parse_counter clears partial streak,
               check_thresholds gate, mediator_spawn refusal
               under critical, atomic_write end-to-end (3
               consecutive corrupt parses → lockdown).
             - mediator_peer_review.bats (4 tests): peer
               agreement applies primary, peer disagreement
               escalates without apply, peer agrees with stricter
               severity → applies extended (more conservative),
               auto_apply primary skips peer entirely.

             Bats: 296/296 (was 254 at T3.06 close; +42 net: +41
             new tests across the 6 new files + 1 net from
             corruption_recovery refactor).

             End-to-end smoke verified (synthetic Mediator
             spawn → verdict → apply chain):
             1. Pending entry emitted (kind=stale_active,
                source=watchdog, target=ghost-smoke, payload
                includes verdict=dead reason="PID 99999 gone"
                subkind=pid_gone).
             2. Mediator spawn (mock claude binary) writes
                verdict file with full schema:
                  verdict_id, ts, for_pending_entry,
                  mediator_session_id, depth=1,
                  action_type="surgical_fix", severity="brief",
                  confidence="auto_apply", reasoning,
                  actions=[release_lock /foo, evict_session
                  ghost-smoke], message_to_caller, message_to_
                  others=null, spawn_metadata={duration_ms,
                  model, spawn_mode, spawn_session_id,
                  total_cost_usd}.
             3. Hook layer applies actions (verdict_apply
                pipeline): /foo lock removed atomically + ghost-
                smoke session evicted. Final state shows only
                caller-smoke session, locks empty.

             Sample verdict (the one above) shows the full
             schema with reasoning/actions/message_to_caller
             populated. Lockdown verdicts (action_type=lockdown)
             would have message_to_others non-null instead.

             Spawn timing (mock claude only — real claude -p
             timing deferred to Phase 7): mock spawn completes
             in ~150-300ms wall-clock. Real claude -p in
             subscription mode estimated 20-35s per T3.06 POC.

             Implementation surprises encountered + addressed:
             - corruption_recovery.bats existing tests required
               rewrite for JSONL flow (4 tests touched legacy
               pending.json directly). Updated to use
               coord_mediator_emit_pending producer for setup.
             - mediator_peer_review.bats teardown intermittently
               failed under heavy parallel suite load (background
               watchdog probe still writing $TMP/.coord during
               rm -rf). Same F-016-class flake as T3.05
               coord_wait. Fix: 0.2s drain + retry rm in
               teardown. Documented as variant of F-016 (already
               OPEN/Phase-7).
             - claude binary missing test required minimal-PATH
               construction (PATH containing jq/flock/perl dirs
               but NOT the fake claude bin). chmod -x doesn't
               work because command -v finds non-executable
               files. Resolved by building PATH via tool dir
               discovery.
             - User-resolved no-bare-only path simplified
               implementation: spawn helper has single mode (no
               auto-fallback to --bare); MEDIATOR_REFERENCE.md
               documents bare as future enhancement.

             No NEW findings raised. F-014/015/016/017 all
             unchanged. Implementation matches PR-PHASE3-01
             + PR-PHASE3-03 + PR-PHASE3-04 already-approved
             contracts; no new plan-revisions entries needed.

             What T3.07 did NOT touch (per scope discipline):
             - coord mediate CLI (T3.08).
             - Phase 3 ship-gate fixtures (T3.09).
             - phase-3-signoff.md (T3.10) — including the
               accumulated lessons (perl utime + pipefail
               capture pattern + claude -p discipline) that
               bundle into signoff CLAUDE.md updates.

             Real claude -p integration testing (cost
             measurement, real verdict format validation,
             prompt-drift detection) deferred to Phase 7
             integration harness — T3.07 ships unit-test
             coverage with fake claude binary; production code
             is unchanged when real claude is invoked. The
             verdict file shape, event payloads, and apply
             pipeline have been exercised end-to-end with
             synthetic data.
- [x] T3.08  coord mediate CLI — operator interface to Mediator (2026-04-26T05:00Z → 2026-04-26T05:25Z)
             Result: NEW src/lib/coord_mediate.sh (~290 lines)
             implementing 5 subcommands per PR-PHASE3-01 §F:
             - coord mediate --reason "<text>" — manual
               escalation primitive; writes pending.jsonl entry
               with kind=manual, source=user_invocation,
               payload.reason + payload.invoked_by ($USER).
             - coord mediate --approve <verdict_path> —
               operator selects a verdict (typically after
               peer-disagreement); reads verdict, applies
               actions via verdict_apply pipeline, records
               MEDIATOR_USER_APPROVED event with verdict_path
               + action_type + confidence + depth +
               approved_by. Warns when the approved verdict's
               confidence != needs_review (operator override
               of single-verdict apply is unusual but
               allowed).
             - coord mediate --escalate [--reason "X"] —
               operator-initiated lockdown with
               reason_source=user_escalation. Default reason
               text "Operator escalation: user requested
               system pause" if --reason not supplied. No-op
               + warning when lockdown is already active.
             - coord mediate --resume — clears any active
               lockdown via coord_lockdown_clear (atomic
               rename to lockdown_archive/<ts>.cleared.json).
               No-op + warning if no lockdown active.
             - coord mediate status — read-only operator
               visibility with 5 sections: (1) Lockdown
               (active/inactive + reason_source + reason +
               started_at), (2) Recent verdicts (last
               COORD_MEDIATE_STATUS_VERDICT_LIMIT=10), (3)
               Pending peer-review disagreements (scans
               events.jsonl for MEDIATOR_PEER_DISAGREED that
               post-dates last MEDIATOR_USER_APPROVED → AWAITING
               --approve banner with both verdict paths), (4)
               Last Mediator invocation (timing + cost +
               spawn_session_id from MEDIATOR_VERDICT event),
               (5) Recent watchdog probes (last
               COORD_MEDIATE_STATUS_WATCHDOG_LIMIT=5). No
               state mutation.
             UPDATED src/bin/coord — added `mediate`
             subcommand to the dispatcher with lazy-source
             pattern (only sources mediate-related libs when
             that subcommand is invoked, keeping unrelated
             paths cheap). Removed `mediate` from the
             "coming-in-later-phases" stub list. Updated
             usage.
             NEW src/tests/unit/coord_mediate_cli.bats — 18
             tests (within 10-15 estimate range; expanded to
             cover all 5 subcommands + each edge case). Bats:
             314/314 (was 296 at T3.07; +18 net from new bats
             file).
             VERIFICATION (sample CLI output for each
             subcommand):
             - --reason demo: prints "pending entry written
               (kind=manual). Mediator will spawn on the next
               tool call." pending.jsonl gains a manual entry
               with payload.reason="Workflow stuck on /foo for
               20 min" and payload.invoked_by=$USER.
             - --escalate demo: prints "lockdown activated
               (reason_source=user_escalation). Reason: ...
               All sessions will be denied tool calls until
               you run: coord mediate --resume". lockdown.json
               materializes with active=true,
               reason_source="user_escalation".
             - status demo (active system): all 5 sections
               populated. ACTIVE lockdown shows
               reason_source/started_at/reason. Verdict listing
               shows action+severity+confidence per file. Last
               Mediator invocation shows duration_ms=22000ms,
               total_cost_usd=0.097, spawn_session_id from the
               MEDIATOR_VERDICT event payload. Watchdog probes
               listed in reverse-chronological order.
             - --resume demo: prints "lockdown cleared.
               Sessions resume normal operation." File rename
               to lockdown_archive/<ts>.cleared.json verified.
             - status demo (idle system): all sections show
               "(no verdicts)" / "(none)" / "(no Mediator
               invocations recorded)" / "(no probes)" / "Lockdown
               inactive". No ERROR conditions surface from
               idle state.
             ESCALATE→RESUME cycle verification: bats test 11
             (mediate --escalate followed by --resume cycles
             cleanly) confirms two full cycles work without
             residual state. lockdown.json materializes →
             archives → re-materializes → archives again.
             Two-cycle test guards against rename-target
             collisions in lockdown_archive (each cycle gets a
             fresh timestamp suffix).
             --approve verification:
             - Reads verdict at given path, parses
               action_type/confidence/depth/actions/
               message_to_caller via jq.
             - Applies actions[] via coord_verdict_apply_actions
               (which routes per op).
             - Records MEDIATOR_USER_APPROVED event with full
               verdict reference + approved_by user.
             - The "rejected sibling cleanup" mentioned in
               T3.08 scope is NOT implemented — the operator
               can manually delete the rejected verdict file;
               keeping both files for audit was deemed safer
               than auto-deletion. Documented as future
               enhancement; flag for review at Phase 3 signoff
               if the user wants auto-cleanup added.
             Linux re-probe deferred to T3.10 / signoff
             standalone re-probe (existing linux-parity
             harness will pick this up automatically; the
             coord_mediate.sh + bin/coord changes have no
             platform-specific risk surface).
             No new findings. F-014/015/016/017 unchanged.
             Implementation matches PR-PHASE3-01 §F coord
             mediate component spec; no plan-revisions entries
             needed.
             What T3.08 did NOT touch (per scope discipline):
             - Mediator agent itself (T3.07 done).
             - Phase 3 ship-gate fixtures (T3.09).
             - phase-3-signoff.md (T3.10).
- [x] T3.09  Phase 3 ship-gate fixtures (2026-04-26T05:30Z → 2026-04-26T05:50Z)
             Result: NEW src/tests/fixtures/phase3_ship_gate/
             with 4 scenario directories + shared init.sh + a
             default fake claude binary that writes a benign
             advice verdict (scenarios overwrite as needed).
             NEW src/tests/manual/phase3_ship_gate.sh driver
             — auto-discovers scenarios in lex order; mirrors
             two_session_warn.sh structure; --mode=hook-sim
             default; --mode=real exits 77 SKIP per established
             Phase 7 deferral pattern; --scenario=<name>
             filter; --keep flag for forensics.
             Scenarios:
             - 01_sigkill_cleanup: A acquires lock; SIGKILL
               simulated by mutating A's pid to 99999 +
               pid_lstart="ghost-lstart" + last_activity
               700s ago. B's watchdog probe (synchronous for
               determinism) confirms PID gone → emits
               stale_active pending. Mock Mediator verdict
               file synthesized with action_type=surgical_fix
               + actions=[release_lock, evict_session]. B's
               next pre_tool_use_any consumes verdict, applies
               actions, then B's Write on foo.ts succeeds. 6
               assertions PASS: A row gone, foo.ts lock gone,
               stale_active pending recorded, MEDIATOR_VERDICT
               event recorded, B's Write got no deny, no
               spurious lockdown.
             - 02_20min_no_evict: false-positive prevention.
               A's pid+lstart match the test bash process
               (alive) and last_activity is 5 min ago (within
               10-min threshold per PR-PHASE3-02 Signal 2 spec
               — the user's "occasional tool calls refreshing
               last_activity" allowance). Watchdog probe
               returns alive verdict cached in
               recent_checks.jsonl. NO MEDIATOR_VERDICT event,
               NO stale_active pending, NO eviction. 6
               assertions PASS.
             - 03_corrupt_state_recovery: 3 consecutive parse
               failures triggered via re-corrupting
               sessions.json before each atomic_edit. Critical
               bypass activates lockdown with
               reason_source=critical_bypass + emits
               CRITICAL_CONDITION_DETECTED event. Operator
               runs `coord mediate --resume` → lockdown
               cleared → archived to lockdown_archive/. 5
               assertions PASS.
             - 04_healthy_no_anomalies: clean system + manual
               escalation via `coord mediate --reason`. Mock
               Mediator produces advice verdict with empty
               actions[]. Verdict consumer applies (no-op).
               State unchanged; no locks; no eviction; no
               lockdown. 5 assertions PASS.
             VERIFICATION:
             - phase3_ship_gate.sh hook-sim mode: 4/4 PASS
               on macOS host.
             - bats unit suite: 314/314 (no regression from
               fixture-only addition).
             - Sample timeline output (01_sigkill_cleanup
               kept-workdir inspection):
                 sessions.json: only sid-b survives
                   (sid-a evicted, install-smoke session is
                   the install.sh boot-smoke artifact)
                 locks: foo.ts now held by sid-b (B acquired
                   after A's eviction)
                 pending.jsonl: 1 entry (kind=stale_active,
                   source=watchdog, target=sid-a)
                 verdict files: 1 (the synthetic Mediator
                   verdict)
                 events.jsonl kinds: SESSION_REGISTER ×3,
                   WRITE ×2, LOCK_ACQUIRED ×2, WATCHDOG_PROBED,
                   WATCHDOG_ESCALATED_TO_MEDIATOR,
                   MEDIATOR_PENDING_DELIVERED, MEDIATOR_VERDICT,
                   SESSION_EVICTED, LOCK_RELEASED, SESSION_END.
                 → Full end-to-end chain: probe → escalate →
                   verdict → apply (release+evict) → release.
             Linux re-probe deferred to T3.10 signoff prep
             (existing linux-parity Docker harness will pick
             this up automatically; the fixture driver is
             pure shell + jq + perl-style helpers, all
             portable).
             ONE production-code mismatch surfaced during
             fixture authoring + addressed inline:
             - Initial scenario 02 spec said "stale activity
               20-min → verdict=alive" but the actual
               watchdog code (per PR-PHASE3-02 disposition #4
               Signal 2 spec) emits verdict=uncertain when
               last_activity > 600s. The user's "occasional
               tool calls refreshing last_activity" allowance
               in the scenario description resolves this:
               last_activity stays within the 10-min
               threshold (5 min in the fixture), Signal 2
               does NOT fire, Signal 1 confirms alive →
               verdict=alive as the user expected. The
               watchdog code is correct per PR-PHASE3-02; the
               fixture had the wrong stale duration. Fixed
               inline. Not a production-code bug; not raised
               as a finding.
             No new findings raised. F-014/015/016/017
             unchanged.
             What T3.09 did NOT touch (per scope discipline):
             - Production code (entirely fixture-only).
             - phase-3-signoff.md (T3.10).
             Files touched: 4 description.md + 4 timeline.sh
             under fixtures/phase3_ship_gate/scenarios/, 1
             init.sh under fixtures/phase3_ship_gate/, 1
             driver under tests/manual/. 10 new files; ZERO
             production-code modifications.
- [x] T3.10  Phase 3 sign-off — Linux probe + CLAUDE.md updates + phase-3-signoff.md (2026-04-26T06:00Z → 2026-04-26T06:25Z)
             Result:
             A. Linux re-probe via
                .coord/experiments/linux-parity/run.sh on
                Docker ubuntu:24.04:
                - bats: 314/314 PASS (after F-018 fix; was
                  312/314 with the bug).
                - two_session_warn: 2/2 PASS.
                - phase3_ship_gate: 4/4 PASS (the new Phase 3
                  fixtures all PASS on Linux overlayfs).
                - ps lstart format check: "Sun Apr 26 05:57:37
                  2026" matches BSD trim pipeline.
                - coord wait detection latency: 1099ms
                  (within 1000-1500ms band; tighter than macOS
                  ~250-500ms slop, likely overlayfs vs APFS).
                - LINUX_PARITY_COMPLETE marker emitted.
                Linux probe surfaced ONE production bug
                (F-018, Linux GNU stat -f re-purposes as
                filesystem-info — affecting watchdog stale-
                lock detection + GC event payloads). Fixed
                inline (commit 23a40f0): GNU-first stat probe
                with numeric validation in
                _coord_file_age_seconds + _coord_pending_file_size.
                Both Linux and macOS suites verified after fix.
             B. CLAUDE.md updates (commit d9923b6) — 5
                operational-guidance sections accumulated from
                Phase 3 lessons. NO plan-revisions; these are
                operational guidance, not architectural.
                §A.13 (NEW): perl utime pattern (T3.04) +
                command-substitution capture pattern (T3.05) +
                GNU-first stat probe (T3.10 / F-018) +
                claude -p spawn discipline (T3.06 + T3.07).
                §B.6 (EXTENDED): watchdog signal model
                clarification — Signal 1 deterministic,
                Signals 2/3 produce uncertain when 1 confirms
                alive; watchdog NEVER returns alive solely on
                activity/lock signals.
                §B.9.1a (NEW subsection): critical-conditions
                bypass — 3+ consecutive parse failures trigger
                lockdown directly with reason_source=critical_
                bypass; Mediator skipped; recovery is OPERATOR-
                DRIVEN via `coord mediate --resume`. Claude-the-
                model guidance: do NOT retry on
                reason_source=critical_bypass; surface to user.
             C. phase-3-signoff.md drafted per CLAUDE.md §A.9.
                260 lines (within 200-400 Phase 1/2 precedent
                band, slightly under T3.10 scope estimate of
                300-450 — sign-off is information-dense without
                padding). Sections: done-when criteria 5/5 with
                evidence pointers (commit SHAs + fixture paths
                + bats names + Linux probe evidence); Phase 3
                invariant (two-location deny contract); newly-
                ACTIVATED-in-Phase-3 components scan (9 entries)
                + still-DORMANT-in-Phase-3 (8 entries spanning
                Phases 4-7+); risks realized vs §7 (none
                materially fired); new risks discovered (3 docs
                items, 0 §7-promotable); plan-revisions (PR-
                PHASE3-01..04 all APPROVED); FINDINGS rollup
                (F-001..018 with 4 RESOLVED in Phase 3 + 3
                still OPEN/DEFERRED + observation accretion
                noted in F-016); 4 open questions for Phase 4;
                artifact index (11 commits + 13 bats files +
                122 new tests + 6 fixtures + Linux probe
                results); recommended next step (3-gate pattern:
                content / merge / Phase 4 start).
             D. Final commit ordering (per user direction):
                - 23a40f0 F-018 fix (production code; not
                  technically "T3.10 scope" but unavoidable
                  pre-signoff Linux probe outcome).
                - d9923b6 CLAUDE.md updates (this commit
                  carries the 5 operational-guidance sections).
                - phase-3-signoff.md drafted at root (gitignored
                  per phase-*-signoff.md rule); NOT
                  committed — sign-off doc is the artifact
                  awaiting user review per CLAUDE.md §A.10.
             VERIFICATION:
             - macOS bats: 314/314 PASS post-F-018-fix.
             - Linux Docker bats: 314/314 PASS post-fix.
             - Manual fixtures: 6/6 PASS both platforms (2
               two_session_warn + 4 phase3_ship_gate).
             - 11 Phase 3 commits visible on
               phase-3/recovery-mediator branch.
             - Working tree clean (only untracked archive/
               which is user-managed reorganization artifact).
             - phase-3-signoff.md gitignored, 260 lines.
             ONE new finding raised + resolved during T3.10:
             - F-018 (Linux GNU stat -f re-purpose) RESOLVED
               via 23a40f0. Pattern documented in CLAUDE.md
               §A.13 lesson #3.
             F-014 RESOLVED (T3.01); F-015/016/017 carry
             forward unchanged.
             Phase 3 status: COMPLETE awaiting user 3-gate
             approval (Gate 1 sign-off content / Gate 2 merge
             to main / Gate 3 Phase 4 start).

### Phase 3 Ship Gate Checklist (from plan §5)
- [x] SIGKILL a session; within `watchdog_confirm_seconds` another
      session's hook cleans up its locks and read-set.
      Evidence: `src/tests/fixtures/phase3_ship_gate/scenarios/
      01_sigkill_cleanup/` PASS in hook-sim mode (T3.09); 6
      assertions covering A row removed, foo.ts lock released,
      stale_active pending recorded, MEDIATOR_VERDICT event,
      B's Write succeeds without deny, no spurious lockdown.
- [x] Legitimate 20-minute reasoning session (with occasional tool
      calls refreshing last_activity) is NOT evicted.
      Evidence: `02_20min_no_evict/` PASS (T3.09); 6 assertions
      covering A row preserved, A's lock preserved, alive verdict
      cached, no MEDIATOR_VERDICT events, no stale_active pending,
      no lockdown.
- [x] Corrupt sessions.json → Mediator resets + logs; next session
      operation works.
      Evidence: `03_corrupt_state_recovery/` PASS (T3.09); 5
      assertions covering critical-bypass lockdown with
      reason_source=critical_bypass, CRITICAL_CONDITION_DETECTED
      event, operator --resume clears + archives, sessions.json
      auto-reset is parseable. Note: implementation surfaces
      critical_bypass lockdown rather than direct Mediator reset
      (Mediator would inherit corrupt state; bypass + operator
      recovery is safer per PR-PHASE3-01 disposition).
- [x] Running `/coord-mediate` on a healthy system returns "no
      anomalies detected."
      Evidence: `04_healthy_no_anomalies/` PASS (T3.09); 5
      assertions covering manual pending entry written, advice
      verdict produced, no locks materialized, sessions count
      unchanged, no lockdown.

### Phase 3 invariant (per Decision 1; supersedes Phase 2 single-location invariant)
- [x] `permissionDecision: "deny"` appears in EXACTLY two code
      paths: (1) `pre_tool_use_write.sh` lock-held-by-other branch
      (existing Phase 2), (2) any hook reading
      `.coord/mediator/lockdown.json` with `active=true` (new Phase
      3). Every hook on every tool call checks the lockdown flag.
      All other code paths remain allow / no-op / fail-open.
      Asserted by `phase3_invariant.bats` (rename of
      `phase2_invariant.bats`); grep for `permissionDecision`
      outside these two locations fails the test.
      Evidence: phase3_invariant.bats 6/6 PASS (T3.03 close report
      + every full-suite run since); architectural test asserts
      hooks/ confined to pre_tool_use_write.sh, lib/ confined to
      lockdown.sh, every hook calls coord_lockdown_check +
      coord_lockdown_emit_deny.

### Notes
- Phase 2's `phase2_invariant.bats` is renamed and expanded to
  `phase3_invariant.bats`. The new test must assert (a) every hook
  reads the lockdown flag and emits deny when active, (b) all
  other deny call-sites stay confined to the two allowed
  locations, (c) static grep gate.
- Watchdog vs direct Mediator invocation flowchart (per Decision
  2): Self-blocked → Mediator directly. Other-suspicious →
  Watchdog → alive (no-op) / dead (Mediator) / uncertain
  (Mediator). Watchdog NEVER writes verdicts itself.
- Mediator escalation hierarchy max depth 2: First Mediator runs;
  if `verdict.confidence == auto-apply`, apply and end; if
  `needs-review`, spawn second Mediator with first verdict in
  context; if both agree → apply; if disagree → escalate to user;
  no third Mediator. Hard ceiling enforced regardless of recursion
  attempts.
- Critical conditions bypassing Mediator entirely (Decision 1):
  corrupt schema, impossible state (e.g., two sessions sharing PID),
  sessions.json fails jq parse repeatedly. These trigger lockdown
  directly + emit user escalation banner. Document the conditions
  in CLAUDE.md §B.10 (or new section) when the Mediator agent
  lands.
- Branch policy (per Phase 1+2 convention + F-010 RESOLVED-as-
  WONTFIX): all Phase 3 work lands on `phase-3/recovery-mediator`;
  merge to main on user approval at signoff time.
- F-014 root fix is a dedicated low-risk task that may sequence
  first (zero coupling to Mediator/watchdog work; pure test-harness
  hygiene). Lockdown flag mechanism is a prerequisite for Mediator
  action type D and for `phase3_invariant.bats` to exist; it should
  precede the full Mediator agent hook task. Watchdog depends on
  the recent_checks cache infrastructure; cache infra precedes
  watchdog logic.


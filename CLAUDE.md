# CLAUDE.md — Multi-Session Coordination System

This file has three audiences, clearly separated.

- **Part A** is for Claude (the Phase 3 builder) during construction. It governs how the system gets built.
- **Part B** is shipped as part of the coordination system and read by every coordinated session at runtime. It governs how registered sessions respond to hook signals.
- **Part C** is meta — rules about this file itself.

**Precedence at all times:** User direction (PLANNING_INSTRUCTIONS.md / `09-user-answers.md`) > `IMPLEMENTATION_PLAN.md` > this file's runtime rules > Phase 1 research.

---

## Part A — Rules for the Phase 3 Builder (Construction-Time)

### A.1 What this project is

A coordination layer for multiple Claude Code sessions operating in the same repository. Built in Bash + `jq` + `flock`, targeting macOS + Linux native. It interposes hooks that track reads, enforce write locks, delegate tasks, detect stale reads, and heal from crashes.

### A.2 Where the plan, research, and user direction live

*Files under `archive/` are historical artifacts consulted only when explicitly directed (per §10.3's decision tree in the plan), not routinely.*

- `archive/PLANNING_INSTRUCTIONS.md` — user's authoritative direction. Read first.
- `IMPLEMENTATION_PLAN.md` — single source of truth for what to build and in what order.
- `archive/09-user-answers.md` — raw user answers (historical context).
- `archive/01-comprehension-summary.md` through `archive/10-working-notes.md` — Phase 1 research.
- `archive/planning-scratch.md` — planner's synthesis notes (historical).
- `future-work/FUTURE_WORK_*.md` — **out of scope.** Do not read during Phase 3 implementation unless revisiting a deferred decision.

### A.3 Document precedence

User direction > IMPLEMENTATION_PLAN.md > this CLAUDE.md runtime rules (Part B) > Phase 1 research.

If documents conflict, the higher-precedence wins. If the higher-precedence is silent on a point, descend the list.

### A.4 Phase-by-phase execution discipline

- Never build outside the current phase's scope, even if "obvious."
- Phases 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 in order. Each phase's "Done when" criteria must be met before starting the next.
- Mediator capability grows across phases per the plan's Mediator thread. Do not ship all Mediator features in one phase.
- Task delegation and self-delegation are Phase 6 only. Do not implement `coord task-open` or `coord self-delegate` machinery in earlier phases. Earlier phases' deny messages may mention the option for future use; the CLI subcommand must exit "disabled" until Phase 6.

### A.5 Quality standards (mandatory)

- **All Bash scripts begin with `set -euo pipefail`.** No exceptions.
- **All state-file writes go through `lib/atomic_write.sh`.** Never `>` or `jq -i` directly on `sessions.json`, `sessions_history.json`, or `config.json`. Never use `tee` without `flock`. Event log writes go through `lib/log_event.sh`, which holds its own lock on `events.lock`.
- **All hooks handle their own crash gracefully.** Trap SIGINT/SIGTERM where meaningful; write to `.tmp` then `mv`; never leave a half-written state file.
- **All shell scripts use `#!/usr/bin/env bash`** and **must run on macOS's default Bash 3.2**. Forbidden: associative arrays (`declare -A`), `readarray`/`mapfile`, `${var,,}`, `${var^^}`, `&>>` (use `>> ... 2>&1`), Bash 4+ parameter expansion (`${var@Q}`, etc.). Portable alternatives: parallel indexed arrays with a key-to-index helper, `tr '[:upper:]' '[:lower:]'`.
- **No Python, Node.js, Go, or Rust code** in v1. If something appears to need a feature Bash cannot handle cleanly, stop and open `plan-revisions.md` with the tension. Do not silently reach for another runtime.
- **Every new component has a test** before "done." `bats` test suite must pass.
- **Event logging is non-blocking.** Use `log_event ... &` to background the append so hook latency is not increased by log writes.
- **No Windows-specific code paths.** Forbidden: `if [[ "$OSTYPE" == "msys"|"cygwin"|"win32" ]]`, `cmd.exe`, `powershell`, PowerShell-compatible path handling. If you find yourself writing one, stop — Windows is out of scope for v1 and has a dedicated future-work document.
- **Do not silently deviate from the plan.** Write to `plan-revisions.md` and surface to the user.
- **Prefer `shasum -a 256` over `sha256sum`** (macOS ships the former, Linux ships both). Use a small wrapper in `lib/hash.sh`.
- **Never shell-construct JSON by string concatenation.** Always use `jq -n --arg ... --arg ...` to build.
- **Gitignore hygiene.** Every artifact created by the system (state, logs, hook scripts under `.coord/`, `.claude/settings.local.json`) must be gitignored by the installer.

### A.6 Hook specification rigor

Every hook script must:
- Exit 0 for "allow" paths (or emit JSON with `permissionDecision: "allow"`).
- Exit 0 with JSON `permissionDecision: "deny"` + `permissionDecisionReason` for hard-enforced denials. Do not use exit 2 unless the hook genuinely wants the generic blocking-error treatment.
- Exit 0 without side effects if the current session is not a participant (`$CLAUDE_COORD` unset or no `.active` marker).
- Write event log entries in the background, not on the critical path.
- Complete within 2 seconds p99 in the no-contention case. Measure this in `bats`.
- Never spawn subshells inside critical (`flock`-held) sections.

### A.7 Communication & escalation

- Surface blockers immediately; do not guess. The user's trust depends on honest reporting.
- Before making a choice this plan does not cover, consult user direction, then IMPLEMENTATION_PLAN.md (§10.3 decision tree).
- Every phase ends with `phase-N-signoff.md` (local, not committed) summarizing what got built, what didn't, and which risks materialized.

### A.8 Proof-of-concept allowance

If you need a tiny POC to verify a Claude Code capability assumption before committing to a design decision, that is allowed. Do NOT commit the POC. Capture only the finding: update `phase0-verification.md` (Phase 0 artifact) or open a `plan-revisions.md` entry.

### A.9 End-of-phase completion report format

`phase-N-signoff.md` (local, not committed) structure:

```
# Phase N Sign-off — <date>

## Done-when criteria
- [x] criterion 1 — evidence: <test path or observation>
- [x] criterion 2 — evidence: ...

## Risks realized
- R<n>: <what happened, how mitigated>

## New risks discovered
- (added to Section 7 via plan-revisions.md)

## Open questions for next phase
- ...

## Artifacts
- bats tests: <path>
- build notes: <path>
```

### A.10 Commit discipline

- Never commit `.coord/` (it is gitignored).
- Never commit state snapshots to the research files (`01`–`10`, `multi-session-coordination-system-en.md`, `09-user-answers.md`, `PLANNING_INSTRUCTIONS.md`). They are historical record.
- Phase branches merge back via PR; commit messages reference phase number and done-when criteria satisfied.

### A.11 Construction Progress Discipline

You MUST maintain `IMPLEMENTATION_LOG.md` at the project root throughout Phase 3 construction. This file is your primary artifact for "where are we."

**Protocol:**

- **Before starting any task** (component, experiment, test suite, or install script), append an unchecked entry with task ID `T<phase>.<seq>` and start timestamp.
- **After completing any task**, check it off with completion timestamp and a one-line result note including test outcomes.
- **If paused mid-task**, leave it as `[IN_PROGRESS]`; never delete entries.
- **When starting a phase**, add a new phase section with header, start timestamp, and status; copy the phase's "Done when" criteria from the plan §5 as the ship gate checklist at the end of that section.
- **When closing a phase**, every task entry in the phase section must be checked (or explicitly ABANDONED with a plan-revisions reference), and every ship gate item must be checked with evidence.

**When resuming after context loss or a session break:**

- FIRST read `IMPLEMENTATION_LOG.md` end to end.
- THEN read `FINDINGS.md` for anything flagged OPEN.
- THEN return to the last `[IN_PROGRESS]` task or the first unchecked one.

**IMPLEMENTATION_LOG.md is gitignored.** It is for the builder and the user, not git history.

### A.12 Discovery Logging Discipline

You MUST maintain `FINDINGS.md` at the project root. This file captures everything the plan didn't anticipate: observations, plan inaccuracies, environment quirks, deferred questions.

**When to add an entry:**

- The plan says X, you observe Y. → Entry with status OPEN and a proposed action path.
- You notice something non-blocking but worth remembering (e.g., "this would be cleaner if refactored later"). → Entry with status DEFERRED.
- You hit a macOS vs Linux quirk, a Bash version issue, a jq edge case. → Entry with status RESOLVED once handled.
- You realize a Phase 1 document was wrong or ambiguous. → Entry with OPEN; may trigger a plan-revisions.md entry.

**Entry format:**

```
## F-<NNN> — <short title>
**Status:** OPEN | RESOLVED | WONTFIX | DEFERRED
**Raised:** <ISO timestamp> during T<phase>.<seq>
**Summary:** 2-4 sentences describing the observation.
**Action:** what happens next (resolution plan, plan-revisions reference, or "accept as deferred").
**Resolution:** (filled in when status becomes RESOLVED or WONTFIX)
```

**Rules:**

- IDs are monotonically assigned: F-001, F-002, F-003 …
- IDs are **never reused**, even if an entry becomes WONTFIX.
- **Before declaring a phase done**, every OPEN finding relevant to that phase's scope must have a disposition (RESOLVED, WONTFIX, or explicitly DEFERRED with a decision deadline).
- FINDINGS.md and plan-revisions.md are distinct: FINDINGS captures *observations*; plan-revisions captures *decisions to change the plan*. Many findings do not require plan changes.

**FINDINGS.md is gitignored.**

---

## Part B — Runtime Rules for Coordinated Sessions

> **Framing (read before the rules).** These rules describe the behavior of sessions running under the coordination system. **Wherever possible, hooks enforce these rules deterministically.** Every rule below is tagged `[HOOK-ENFORCED]` (the hook makes the rule true regardless of what Claude tries to do) or `[BEST-EFFORT]` (the rule depends on Claude-the-model cooperating; the hook cannot make it true on its own). Treat `[BEST-EFFORT]` rules as probabilistic — the system is designed so that no safety-critical behavior depends solely on them.

### B.0 You will know you are in a coordinated session because

At SessionStart, if `CLAUDE_COORD=1` was set in the environment that launched you, the `session_start.sh` hook injects an `additionalContext` line stating:

> **Coord v1.0 active.** Your coordination session ID is `<uuid>`. There are currently `<N>` other coordinated sessions in this repository. See `coord status` for live state.

If this banner is absent, you are not in a coordinated session and none of the rules below apply.

### B.1 Before reading any file

**Rule:** Read the file directly; the `PreToolUse(Read)` hook handles the coordination work (hash recording, notification delivery). You do not need to consult `sessions.json` yourself.

**Enforcement:** `[HOOK-ENFORCED]` — the `pre_tool_use_read.sh` hook:
1. Computes `sha256` of the target file via `lib/hash.sh`.
2. Emits `hookSpecificOutput.additionalContext` with any relevant notifications addressed to your session about this file (e.g., "File modified by session X since your last read").
3. Under `flock sessions.lock`, appends an entry to `read_sets[<your_session_id>].reads[]`, supersedes any prior entry for the same file (`is_latest: false, superseded_by: <new_hash>`).
4. Logs event `READ`.
5. Exits 0 (allow).

**What you do:** If `additionalContext` contained a notification, internalize it. If the notification says "File modified by X since your last read," consider whether your current plan is still valid.

### B.2 Before writing any file (branching tree)

**Rule:** Attempt the Write/Edit. The `PreToolUse(Write|Edit|NotebookEdit)` hook evaluates lock state and read-set freshness and either allows, denies, or flags for Mediator.

**Enforcement:** `[HOOK-ENFORCED]` throughout. The `pre_tool_use_write.sh` hook under `flock sessions.lock`:

1. **No lock on the target file:**
   - Validate your `read_sets[<self>].reads[]` for any file where `is_latest: true` and `superseded_by_head_change: false`: compute current `sha256`, compare to stored hash.
     - **All match** → acquire lock (`locks[target] = {session:self, acquired_at, last_refresh_at, tasks:[]}`), update `sessions[self].last_activity_at`, exit 0 (allow).
     - **Some mismatch** → write `.coord/validation/<self>.json` payload; exit with `permissionDecision: "deny"` + reason `"stale-read-suspected: <files>"`. The validator agent hook runs on the next PreToolUse and sets verdict SAFE/MINOR/CRITICAL:
       - SAFE/MINOR → remove validation flag; next write attempt proceeds normally.
       - CRITICAL → remains denied until you `Read` the listed files again (which resets the hash).

2. **Lock held by another session:**
   - Exit with `permissionDecision: "deny"` and a `permissionDecisionReason` like:
     > File `foo.ts` is locked by session `<holder_id>` since `<ts>` (~<mins> min). Options:
     > (a) Delegate a SIMPLE/MODERATE task: `Bash: coord task-open --file foo.ts --complexity SIMPLE --anchor '{"search":"...","window_lines":"..."}' --instruction '...' [--rationale '...']`.
     > (b) Self-delegate (do other work, return later): `Bash: coord self-delegate --file foo.ts --instruction '...'`.
     > (c) Passively wait: `Bash: coord wait foo.ts --timeout 570` (blocks your Bash call until unlocked or timeout; 570 s is the max — it sits just below Claude Code's 600 s Bash-tool ceiling).
     > Pick (a) for small, self-contained edits; (b) if you have other productive work; (c) only if the change is too complex to delegate AND you have no other work.

3. **Lock held by yourself:**
   - Refresh `last_refresh_at`; exit 0 (allow).

**What you do:** On deny, read the reason, pick an option, issue the appropriate Bash command. On allow, proceed with the Write/Edit.

### B.3 Before taking final action (stale-read validation)

**Rule:** There is no separate "before final action" hook. Stale-read validation runs at every write. If you intend to produce a final answer that does not involve a write but is nonetheless consequential (e.g., a report whose content implies file contents unchanged), you may invoke `coord validate-reads` explicitly (Phase 4+).

**Enforcement:** `[HOOK-ENFORCED]` on writes (see B.2). `[BEST-EFFORT]` on non-write final answers — the hook cannot intercept a plain text response.

### B.4 Before releasing a lock (task processing + wait-queue notification)

**Rule:** You do not manually release locks. The `PostToolUse(Write|Edit)` hook does it.

**Enforcement:** `[HOOK-ENFORCED]`. The `post_tool_use_write.sh` hook under `flock sessions.lock`:
1. For each entry in `locks[<file>].tasks[]` in order:
   - Inject `additionalContext` describing the task (`from`, `instruction`, `anchor`, plus `affected_lines` of any previously-applied tasks under the same lock so Claude can reason about conflicts).
   - **This is the one place `[BEST-EFFORT]` enters the lock-release flow:** Claude-the-model applies the task using `Edit`. If the task is inapplicable (anchor gone, target changed), Claude marks the outcome `CONFLICT` and moves on.
2. Record `status`, `diff`, `affected_lines`, `outcome` per task.
3. Remove `locks[<file>]`; archive to `sessions_history.json`.
4. For each `wait_queue[<file>]` entry, `touch` the `wake_file` and emit `lock_released` notification with the final diff summary.
5. Update task_graph edges, delete processed ones.
6. Log `LOCK_RELEASE` + per-task `TASK_OUTCOME` events.

### B.5 Before finishing a prompt (cleanup, unresolved tasks)

**Rule:** On `Stop`, the hook checks for unresolved self-tasks. If any, the first `Stop` returns `decision: "block"` with a reminder; the second `Stop` allows exit.

**Enforcement:** `[HOOK-ENFORCED]` for the block-once-then-allow mechanics. `[BEST-EFFORT]` for whether you act on the reminder.

**What you do on reminder:** If your self-task's file is now unlocked and you can sensibly apply the deferred work, do so. If not, the next `Stop` allows exit and the self-task is archived as `SKIPPED`.

### B.6 On encountering anomalies (Mediator invocation protocol)

**Rule:** You do not invoke the Mediator directly in the common case. Command hooks detect anomalies (corrupt state, flock timeout, PID/lstart consensus, schema mismatch, fork-bomb suspicion) and write `.coord/mediator/pending.json`. The next `PreToolUse` triggers the `mediator_agent.md` agent-hook, which reads the flag, analyzes, remediates, and injects a verdict summary as `additionalContext`.

**Enforcement:** `[HOOK-ENFORCED]` via flag file + agent hook.

**Manual invocation (rare):** If you suspect a coordination problem not flagged automatically, `Bash: coord mediate` writes a manual pending flag with `kind:"manual"` and your supplied context. The next tool call fires the Mediator.

**When Mediator cannot decide:** It writes `kind:"escalate_to_user"` in its verdict and emits `additionalContext` asking you to surface the situation to the user in your response.

### B.7 On self-delegation (a session deferring its own work until a lock clears)

**Rule:** When you choose option (b) from the lock-denied prompt (§B.2), issue:
> `Bash: coord self-delegate --file <path> --instruction "<self-note>"`

**Enforcement:** `[HOOK-ENFORCED]` for the record keeping, injection of reminders, and block-on-Stop.

**What happens after:**
1. An entry is appended to `self_tasks[<you>][]` with status `PENDING`.
2. On every subsequent `PreToolUse` (any tool) during your turn, `pre_tool_use_any.sh` checks whether any of your self-tasks' files are now unlocked. If yes, it injects:
   > REMINDER: You deferred `<file>` earlier ("<instruction>"). It is now unlocked. Consider returning to it before finishing.
3. On `Stop`, self-tasks drive the block-once behavior (§B.5).

**Passive reliability:** `[BEST-EFFORT]` — you must notice and act on the reminder. The hook will surface it, but whether you return to the file is your decision. Archive as `SKIPPED` is the fallback.

### B.8 On passive waiting (polling cadence)

**Rule:** Passive wait is the fallback when delegation and self-delegation are not appropriate (e.g., the blocked edit is complex, you have no other productive work). Issue:
> `Bash: coord wait <file> --timeout 600`

**Enforcement:** `[HOOK-ENFORCED]` for the polling cadence (30s → 60s → 120s), the wake semantics (lock-release touches the wake file; `coord wait` exits), and the timeout.

**What happens on timeout:** `coord wait` exits non-zero; you receive "timeout after Ns" on stdout. Next step is usually to ask the user (the coordination system has done everything it can; the problem is human-scale).

**Cadence rationale:** Starts at 30s to avoid tight polling; doubles at 5 min (wait counter ≥ 10), doubles again at 15 min (counter ≥ 20) to be nice to other work. Max wait defaults to 30 min (`wait_max_seconds`).

### B.9 Edge-case rules

#### B.9.1 Missing state file

**Rule:** If `sessions.json` is missing when a hook runs, the hook creates an empty initialized file under `flock` and emits `additionalContext: "Coordination state initialized (was missing)."`

**Enforcement:** `[HOOK-ENFORCED]` in `atomic_write.sh`.

#### B.9.2 Corrupted state file

**Rule:** If `sessions.json` fails to parse (`jq` non-zero), the current hook:
1. Moves the file to `.coord/sessions.corrupt.<ISO-ts>.json`.
2. Creates a fresh empty `sessions.json`.
3. Writes Mediator flag (`kind: "corrupt_state"`).
4. Emits `additionalContext` banner warning: "Coordination state was reset due to corruption. Mediator will diagnose; prior locks are lost. Retry your operation."
5. Fail-open: allow the current tool call to proceed.

**Enforcement:** `[HOOK-ENFORCED]`.

#### B.9.3 Hook script failure

**Rule:** If a hook script errors in an unhandled way, the Claude Code default kicks in: non-zero exit is non-blocking, tool proceeds. This is fail-open by Claude Code's contract. The `events.jsonl` records `ERROR` if the hook got that far; otherwise the failure is silent.

**Enforcement:** `[BEST-EFFORT]` — we cannot enforce recovery from a hook that itself is broken. Mitigation: `bats` tests + code review.

#### B.9.4 Missing dependencies (`jq` or `flock`)

**Rule:** The installer refuses to install without them. If somehow a session runs with them missing (e.g., `jq` uninstalled after install), every hook:
1. Detects the missing dependency at top-of-script.
2. Emits a loud `additionalContext` warning: "Coordination dependency missing: <name>. Operating uncoordinated. Install with `<cmd>` and re-register with `coord install --repair`."
3. Exits 0 without state change.

**Enforcement:** `[HOOK-ENFORCED]` for the warning; coordination itself is disabled (documented degradation).

#### B.9.5 Non-participant session

**Rule:** If `CLAUDE_COORD` is unset or `.coord/sessions/<self>.active` is absent, every coordination hook exits 0 without side effects. Your session operates as if the coordination layer were not installed.

**Enforcement:** `[HOOK-ENFORCED]` via `lib/participant.sh` check at the top of every hook.

#### B.9.6 Git HEAD changed mid-session

**Rule:** On `UserPromptSubmit` or at the start of any `PreToolUse` if git HEAD differs from the session's recorded `git_head`:
1. Mark all `read_sets[<self>].reads[].superseded_by_head_change = true`.
2. Update `sessions[<self>].git_head`.
3. Emit `additionalContext`: "Git HEAD changed since your last activity. Your read-set is invalidated; re-read any files you depend on."
4. Log `HEAD_CHANGE` event.

**Enforcement:** `[HOOK-ENFORCED]`.

#### B.9.7 Session resumed, cleared, or compacted

**Rule:** On a `SessionStart` event with `source ∈ {resume, clear, compact}`, the coordination layer preserves or selectively invalidates your read-set according to Decision 2.5's source-matrix (per PR-PHASE1-01):
- `resume`: your prior read-set is **preserved intact**. If git HEAD drifted during the gap, read-set entries are automatically marked `superseded_by_head_change: true` and the relevant files will trigger stale-read warnings when you next read or write them.
- `clear`: read-set entries are marked `superseded_by: "new_prompt"` — treated as a fresh-start boundary.
- `compact`: read-set is **preserved intact** (context compression preserves read history semantically; the stored hashes are still the truth about what the session last observed on disk).

You do **not** need to re-read files prophylactically after any of these events. The hooks will flag staleness when it actually matters (on the next write, or via `additionalContext` on HEAD drift). Prophylactic re-reads waste tokens and reset the read-set to state the coord layer has already carefully curated.

**Enforcement:** `[HOOK-ENFORCED]` for the state-preservation and invalidation-marking actions. `[BEST-EFFORT]` for the "do not re-read prophylactically" guidance — Claude is expected to cooperate; if it re-reads anyway, the system still works correctly (just slightly more expensively).

### B.10 What NOT to do (anti-patterns)

These are cases where Claude sometimes tries to "help" in ways that undermine coordination:

- **Do not read, parse, or write `sessions.json` directly.** Use the `coord` CLI. The hooks coordinate writes; direct edits will be overwritten or will corrupt the file.
- **Do not bypass lock denials by using `Bash` to write the file (`echo > foo.ts`, `sed -i`, etc.).** Bash-mediated writes are not tracked and will silently clash with the coordinated lock-holder. The deny message explicitly warns against this.
- **Do not `rm`, `mv`, or `cp` over a file that is locked by another session.** The coordination system does not hook these. The result is a silent conflict.
- **Do not invoke `coord reset` reflexively** when a coordination message is confusing. `coord reset` is destructive (clears locks, read-sets). The right response to confusion is `coord status` first, then `coord mediate` if the situation truly is anomalous.
- **Do not spawn your own validation subagent via the Agent tool to bypass the validator agent hook.** The validator hook runs automatically on hash mismatch; calling your own subagent duplicates cost.
- **Do not store session state in your own memory across turns as a substitute for `sessions.json`.** Your memory is advisory; `sessions.json` is authoritative.
- **Do not spawn a subagent as a workaround to evade coordination.** Subagent tool calls are invisible to the coord layer by design (Decision 2.17: the `agent_type` filter in `pre_tool_use_*`, `post_tool_use_*`, and `stop.sh` causes those hooks to exit 0 without mutating state, emitting only a `SUBAGENT_ACTIVITY_SKIPPED` observability event). A subagent writing a file not locked by its parent can race silently with another session. If you need a bounded deferral, prefer `coord self-delegate` (which IS tracked) over a subagent.

### B.11 Quick-reference table

| Situation | You do | Hook does | Enforcement |
|---|---|---|---|
| Read a file | Invoke `Read` | Record hash, deliver notifications | [HOOK-ENFORCED] |
| Write, no lock | Invoke `Write`/`Edit` | Validate read-set + acquire lock | [HOOK-ENFORCED] |
| Write, locked by other | See deny reason; pick (a) task / (b) self-delegate / (c) wait | Deny with actionable reason | [HOOK-ENFORCED] |
| Write, lock by self | Invoke normally | Refresh TTL | [HOOK-ENFORCED] |
| Stale read detected | Re-read the file | Deny until re-read OR validator verdict allows | [HOOK-ENFORCED] |
| Other session dead | Nothing | Watchdog evicts after consensus | [HOOK-ENFORCED] |
| Corrupt state | Retry the op | Hook resets + flags Mediator | [HOOK-ENFORCED] |
| Anomaly | Report to user if Mediator escalates | Mediator remediates or escalates | [HOOK-ENFORCED] + [BEST-EFFORT] on escalation acknowledgment |
| Self-task reminder | Consider returning to the file | Inject reminder | [BEST-EFFORT] |
| Stop with self-tasks | Address or ignore | Block once, allow on second Stop | [HOOK-ENFORCED] on block; [BEST-EFFORT] on your action |
| Session resumed / cleared / compacted | Continue your work normally; do NOT re-read files prophylactically | Preserve or selectively invalidate read-set per Decision 2.5 source-matrix; flag HEAD drift automatically | [HOOK-ENFORCED] on invalidation; [BEST-EFFORT] on "do not re-read prophylactically" |

---

## Part C — Meta-Rules

### C.1 How this CLAUDE.md gets updated

- **Part A changes** only when the IMPLEMENTATION_PLAN.md changes in a way that affects construction discipline. Edits land via `plan-revisions.md` + user acknowledgment, not by the Phase 3 builder's unilateral choice.
- **Part B changes** when hook behavior changes. The hook's behavior is the law; Part B must always reflect what the hook actually does. If they diverge, Part B is wrong and must be fixed — not the hook (unless the hook was also wrong).
- **Part C changes** only rarely; the protocol for changing it is itself described here.

### C.2 Authority

- **Scope, philosophy, platform, language:** the user. Changes come via updating `PLANNING_INSTRUCTIONS.md` or via explicit user-in-the-loop during a session.
- **Implementation detail within a phase:** the Phase 3 executor. Changes must be recorded in `plan-revisions.md`.
- **Runtime behavior for end users:** this file (Part B) + the hooks.
- **Emergency override (e.g., Mediator behaving destructively):** any user may disable Mediator via `coord config set mediator_enabled false`; must be logged.

### C.3 Advisory vs mandatory distinction within this file

- **Part A** rules are **mandatory** during construction. Violations are bugs.
- **Part B** rules tagged `[HOOK-ENFORCED]` are deterministic — the hook makes them true regardless of what Claude does.
- **Part B** rules tagged `[BEST-EFFORT]` are advisory — Claude is expected to cooperate, but the system is designed such that no safety-critical behavior depends solely on compliance.
- **Part C** rules are process norms; violations should be rare and always surface to the user.

### C.4 What to do when this file is silent

If Part A is silent on a construction question: follow the Section 10 decision tree in `IMPLEMENTATION_PLAN.md`. If Part B is silent on a runtime question: act conservatively (do not write; ask the user; prefer `coord status` over guessing).

### C.5 Version

This CLAUDE.md is versioned alongside the schema. Current: **v1.0** — aligns with `schema_version: "1.0"`. Any schema-version bump requires a CLAUDE.md review (at minimum a changelog entry in `plan-revisions.md`).

### C.6 IMPLEMENTATION_LOG.md and FINDINGS.md lifecycle

Both files are born with Phase 0's first task and grow through Phase 7. They are not deleted when construction ends; they become historical artifacts that future maintainers of the system consult. They are gitignored but may be manually archived (`archive/`) after v1 ships if desired.

If the system is uninstalled via `coord uninstall`, these files remain untouched. They belong to the builder, not the tool.

---

*End of CLAUDE.md*

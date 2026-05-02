# IMPLEMENTATION_PLAN.md

**Project:** Multi-Session Claude Code Coordination System (v1)
**Audience:** Phase 3 implementer
**Status:** Authoritative plan. Deviations recorded in `plan-revisions.md`.
**Precedence:** User direction > this plan > `CLAUDE.md` runtime > Phase 1 research.

---

## Section 1 — Context & Scope

### 1.1 What is being built and why

Claude Code allows multiple sessions to operate in the same repository without any native coordination. Two failure modes result: **write-write conflict** (one session silently overwrites another) and **stale read** (a session acts on a file snapshot that another session has since changed). The system built by this plan interposes a coordination layer on top of Claude Code's hooks mechanism, using a shared JSON state file protected by `flock`, so that explicitly-registered sessions observe each other's work in progress, hard-deny unsafe concurrent writes, detect stale reads before action, and (optionally) delegate small tasks between each other instead of blocking.

### 1.2 In scope (v1)

- Multi-session coordination for **explicitly-registered** sessions on **macOS and Linux** (native, Unix semantics assumed).
- **Bash + `jq` + `flock`** as the implementation stack. No daemon. No long-running services.
- Full architecture: atomic state, session registry, write locks, task delegation (including **self-delegation**), peer watchdog, read-set tracking, validation subagent (agent-type hook), wait queue, **Mediator component**.
- Structured activity log (`events.jsonl`, one JSON object per line) for every read/write/tool-call/lock/task/notification.
- CLI inspection tool (`coord`).
- Installation / init script.
- Four-configuration test harness (Phase 7).

### 1.3 Out of scope (v1) — must be documented as limitations

- **Windows native.** WSL2 works (presents as Linux). Windows native gets `future-work/FUTURE_WORK_windows_native_support.md`.
- **Network filesystems.** NFS, iCloud Drive, Dropbox. `flock` semantics are unreliable. Installer refuses to run here; Mediator surfaces the cause.
- **Remote sessions / multi-machine.** `future-work/FUTURE_WORK_remote_sessions.md`.
- **Multi-user on the same machine.** `future-work/FUTURE_WORK_multi_user_shared_machine.md`.
- **Team-shared coordination state (checked into git).** Everything is gitignored; the system is per-developer opt-in. `future-work/FUTURE_WORK_team_shared_repos.md`.
- **Non-participating sessions.** Any Claude Code session started without `CLAUDE_COORD=1` operates normally; the coordination system does not see it and makes no guarantees about its behavior. Documented limitation, not defended.
- **Bash-mediated reads/writes** (`cat`, `sed -i`, `rm`, `> file`). Not tracked; Bash is intractable to parse statically. Documented limitation.
- **Grep with `output_mode: "content"`** as a "read" source. Tracked? **No in v1.** Only the `Read` tool is tracked for read-set purposes. Documented limitation.
- **Subagent tool calls.** Subagents (Claude-spawned via the Task/Agent tool) do not participate in coordination; they operate under their parent session's registration. Hooks filter by `agent_type`. Documented limitation: a subagent writing a file not locked by the parent can race.
- **Schema downgrade.** A session running older scripts that encounters a newer `schema_version` refuses to participate. No auto-migration of state forward-then-back.

### 1.4 Non-goals (things the system deliberately will not do)

- Replace git. Coordination is in-process; merge is still git.
- Prevent users from disabling coordination. `CLAUDE_COORD=0` or omitted → no coordination. Deliberate.
- Protect against malicious actors on the same machine. Threat model is cooperative.
- Enforce correctness of Claude's reasoning. We enforce the **mechanics** around read/write; the semantic correctness of any given task is outside scope.
- Intercept every possible way a file can change on disk. We cover `Read`/`Write`/`Edit` via hooks and accept that formatters, editors, and Bash operations can change files silently (validation subagent absorbs false positives).

---

## Section 2 — Consolidated Design Decisions

> **Decision 2.1:** Implementation language is **Bash 3.2-compatible shell scripts** using `jq` for JSON and `flock` for atomic state writes.
> **Rationale:** Zero runtime dependencies beyond a single `brew install jq` / `apt install jq`; lowest hook-call latency (typically 20–50ms); standard Unix composition; simplicity for community adoption.
> **Source:** User direction (Platform Support, Implementation Language); Phase 1 `07` §1 discussed Python but user overrode.

> **Decision 2.2:** Minimum Bash version is **3.2** (the macOS default). No associative arrays, no `${var,,}`, no `readarray`/`mapfile`. Homebrew Bash 5 is **not** required.
> **Rationale:** Frictionless install on vanilla macOS. Linux ships Bash 4+; everything 3.2-compatible runs there unchanged.
> **Source:** Planner-originated. PLANNING_INSTRUCTIONS.md Section 2 explicitly flagged the choice.

> **Decision 2.3:** Atomicity mechanism is **`flock -x` on a dedicated sentinel file, read sessions.json, transform with `jq`, write to `.tmp`, `mv` over sessions.json**. The `mv` is atomic on POSIX.
> **Rationale:** OS-level file lock; simplest correct primitive; survives process death (flock auto-released on fd close); temp-then-rename guarantees sessions.json is never half-written.
> **Source:** Source design §4.5; Phase 1 `03` §15 verified; `04` Scenario 11.

> **Decision 2.4:** Hash algorithm is **SHA-256** computed via `shasum -a 256` (portable across macOS and Linux). Full 64-hex-char digest stored; no truncation.
> **Rationale:** Negligible cost delta over md5; avoids md5's reputation liability; truncation risks aliasing (source design showed 6-char examples which are unsafe).
> **Source:** Phase 1 `02` D1, `04` Scenario 16, `10` working notes; `05` assumption D.

> **Decision 2.5:** Session identity scheme: Claude Code provides a UUID `session_id` in every hook's stdin JSON. That UUID is the coordination session ID. SessionStart is invoked with a `source` field whose value distinguishes four lifecycle events; the hook's behavior depends on `source` as follows:
>
> | `source`  | Registration action | Read-set action | PID / lstart / git_head | Event |
> |-----------|---------------------|-----------------|-------------------------|-------|
> | `startup` | Insert new row (schema per §3.3); reject if a row already exists for this `session_id` as anomaly. | Initialize empty read-set. | Capture fresh (`$PPID` + lstart + git_head). | `SESSION_REGISTER` |
> | `resume`  | Idempotent refresh of the existing row (matched by `session_id`); if no prior row exists, fall back to `startup` semantics and emit `SESSION_REGISTER` with `reason:"resume_without_prior_row"`. | **Preserve read-set intact** — the `session_id` is stable across resume and prior reads semantically still belong to this session. Then: compare stored `git_head` to current; if different, set `superseded_by_head_change: true` on every entry in `read_sets[<id>].reads[]` before proceeding (per Decision 2.22). | Refresh (new `$PPID`, new lstart, new git_head). | `SESSION_RESUME`. Additionally, if lock records keyed to this `session_id` exist with the prior PID/lstart stamp, emit a `RESUME_ORPHAN_LOCK_DETECTED` event per affected lock but do **not** release it in Phase 1 — orphan-lock eviction is deferred to Phase 3's peer-watchdog (Phase 2 introduces locks but the watchdog doesn't arrive until Phase 3). |
> | `clear`   | Refresh the existing row (idempotent). | Mark prompt-scoped entries `superseded_by: "new_prompt"`. Semantically identical to the invalidation `user_prompt_submit.sh` performs; `source=clear` is the independent "fresh start" channel when the user explicitly clears context. | Refresh git_head only (pid/lstart unchanged — same process). | `SESSION_CLEAR` |
> | `compact` | Refresh `last_activity_at` on the existing row. | **No change** — context compression preserves read history semantically; the hashes stored in `read_sets` are still the truth about "what this session last observed on disk." | No change. | `SESSION_COMPACTED` (informational) |
>
> Non-participant sessions (env var `CLAUDE_COORD` unset) are ignored regardless of `source`. Subagent sessions do not fire SessionStart at all (Decision 2.17 per PR-PHASE0-01); the source-branching above applies only to primary coordinated sessions.
> **Rationale:** UUID is already stable and unique; env-var gate is a clean opt-in that doesn't require a wrapper script and can be toggled per-launch. Source-matrix was added after Phase 0 Experiment #1 exposed the gap; the matrix preserves read-set semantics across the full session lifecycle.
> **Source:** User direction (Session Identity and System Boundary); Phase 1 `03` §9; planner chose env var over wrapper command; PR-PHASE1-01 augmented the matrix post-Phase-0 (FINDINGS F-004).

> **Decision 2.6:** Error-handling philosophy: **fail-open with loud, visible warning** for non-critical failures; **hard-deny** for load-bearing writes on locked files or with CRITICAL stale-read verdict; **Mediator invocation** for anomalies (stuck locks, corrupt state, consensus disputes, fork-bomb suspicion).
> **Rationale:** Matches user direction. Fail-open on parse errors or log failures keeps sessions working; hard-deny on the two situations where corruption would be silent keeps the system honest; Mediator absorbs the gray-zone cases humans would otherwise debug by hand.
> **Source:** User direction (Error Handling Philosophy); Phase 1 `07` §3, `04` Scenario 12, Scenario 15.

> **Decision 2.7:** Platform scope is **macOS + Linux native only**. Windows is deferred. WSL2 is documented as the Windows workaround (it presents as Linux; the system works unmodified under it). Network filesystems (NFS, iCloud, Dropbox) are unsupported; the installer detects and refuses.
> **Rationale:** User direction. Avoids cross-platform abstraction complexity that would bloat the hooks.
> **Source:** User direction (Platform Support).

> **Decision 2.8:** Observability: every read, write, tool call, lock acquisition/release, task lifecycle event, notification, Mediator invocation, and error is appended to **`events.jsonl`** (JSON lines, one event per line, UTC ISO-8601 timestamps). `sessions_history.json` is a **curated** archive containing only significant events (session end, lock release with task outcomes, Mediator interventions). The raw stream (`events.jsonl`) is the future UI data source.
> **Rationale:** User direction. Dual-stream separates debug firehose from audit trail.
> **Source:** User direction (Activity Logging); Phase 1 `07` §4.

> **Decision 2.9:** Schema versioning: `sessions.json` carries a top-level `"schema_version": "1.0"` field. Scripts check on read; higher major version → refuse to participate with a human-readable error. A separate `.coord/schema_version` file records the installed scripts' version for operator visibility.
> **Rationale:** Prevents a mismatched-script deployment from corrupting newer state.
> **Source:** Phase 1 `07` §9, `05` assumption H.

> **Decision 2.10:** CLAUDE.md vs hook enforcement split: **hooks are the enforcement layer.** CLAUDE.md Part B (runtime rules) teaches Claude how to *respond* to hook signals. Every runtime rule is explicitly tagged `[HOOK-ENFORCED]` or `[BEST-EFFORT]`. The plan treats `[BEST-EFFORT]` rules as probabilistic — any behavior whose correctness depends on it is marked as such in risk register.
> **Rationale:** Phase 1 finding; CLAUDE.md compliance is LLM behavior, not determinism.
> **Source:** Phase 1 `02` C1, `04` Scenario 15, `05` assumption B; user direction aligned.

> **Decision 2.11:** Cross-session awareness injection: via `hookSpecificOutput.additionalContext` on the hook events that support it (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`). Injection is **relevance-filtered**: the hook injects only what pertains to the current operation (e.g., lock state for this file, notifications addressed to this session). The hook never dumps `sessions.json` wholesale.
> **Rationale:** User direction; keeps context noise manageable.
> **Source:** User direction (Cross-Session Awareness Injection); Phase 1 `03` §8.

> **Decision 2.12:** Task delegation is **required** in v1 (final phase) and **toggleable per repo** via `.coord/config.json` key `"task_delegation": true|false`. Default: `true`. Developers can disable per-repo. **Default revisited at Phase 7 sign-off; flip to `false` if TASK_FAILED + TASK_CONFLICT rate > 10% in Phase 7 benchmarks** (see OI-6).
> **Rationale:** User direction requires task delegation; Phase 1 research flags it as the riskiest feature and recommends a toggle so developers can opt out. The Phase 7 revisit turns the toggle default into a data-driven decision rather than an assumption.
> **Source:** User direction (Task Delegation); Phase 1 `02` E, `04` scenarios 1/7/10/14/20, `08` Phase 6.

> **Decision 2.13:** Self-delegation mechanism (new, planner-designed): a session that encounters a locked file and does not wish to delegate to the lock-holder writes a **self-task** record `self_tasks[session_id] += [{file, instruction, created_at, prompt_id}]`. On any subsequent `PreToolUse` for that session, the hook checks whether any self-task's file is now unlocked; if yes, it injects a reminder via `additionalContext`. On `Stop`, unresolved self-tasks trigger `decision: "block"` once with a reminder; second `Stop` lets the session end and archives the self-task as SKIPPED.
> **Rationale:** User explicitly required this. Existing source design has no analogue.
> **Source:** User direction (Task Delegation); planner-originated mechanism.

> **Decision 2.14:** Wait semantics: the hook **never blocks** waiting for a lock. On write attempt against a locked file, `PreToolUse(Write|Edit)` returns `permissionDecision: "deny"` with a `permissionDecisionReason` including the lock-holder's session ID, file, duration held, and instructions for Claude to choose among (a) delegate task to lock-holder, (b) self-delegate and continue other work, (c) enter passive wait via the `coord wait` CLI. The passive wait path is implemented by a CLI tool that sleeps with bounded cadence (30s → 60s → 120s) and returns when notified by the lock-release hook (via a wake file).
> **Rationale:** User direction explicitly specifies this pessimistic-then-Claude-driven model.
> **Source:** User direction (Pessimistic vs Optimistic Waiting); planner-originated CLI-based passive-wait implementation.

> **Decision 2.15:** Mediator is implemented as an **agent-type hook** installed on a generic `PreToolUse` matcher, guarded by a flag file at `.coord/mediator/pending.json`. It is supplemented by a user-invocable skill `/coord-mediate` that runs the same diagnostic on demand.
> **Rationale:** Agent-type hook has tool access (can read state, inspect PIDs via Bash, edit sessions.json), runs in Claude Code natively (no external API key), and can be invoked implicitly without Claude-the-model having to remember. A skill gives the user a manual escape hatch. User direction said pick the best fit after evaluating capabilities.
> **Source:** User direction (Error Handling Philosophy — Mediator role); Phase 1 `03` §7 (agent hook type); planner-originated implementation pattern.

> **Decision 2.16:** Validation subagent (Layer 6 of source design) is implemented as a separate **agent-type hook** on `PreToolUse(Write|Edit)` guarded by a flag file at `.coord/validation/<session_id>.json` written by the read-set check in `pre_tool_use_write.sh` when a hash mismatch is found. The agent reads the flag, classifies the diff as SAFE/MINOR/CRITICAL, writes the verdict back, and injects guidance as `additionalContext`. CRITICAL verdicts cause the command-hook on the next `PreToolUse(Write|Edit)` attempt to deny until the session re-reads.
> **Rationale:** User confirmed agent-type hook for validation subagent. Flag-file pattern makes the hook idempotent and guards against fork-bomb.
> **Source:** User direction (Validation Subagent Choice); Phase 1 `03` §7.

> **Decision 2.17:** Subagent session participation: Claude Code does **not** issue a separate `SessionStart` for subagents spawned via the Task tool; subagent tool calls carry the parent session's `session_id`. The coordination layer filters subagent activity at the **tool-call hook layer**: when any `PreToolUse`, `PostToolUse`, or `SubagentStop` input contains a non-empty `agent_type` field, coordination hooks exit 0 without mutating state AND **MUST** emit a single `events.jsonl` entry of `kind: "SUBAGENT_ACTIVITY_SKIPPED"` with payload `{parent_session, tool, agent_type, file: <file_path if applicable>}` so downstream tooling (e.g. the visualization-UI future-work deliverable) can reconstruct subagent activity even though coord does not coordinate it. Subagent tool calls therefore inherit the parent session's locks and read-set passively — the parent's lock covers the parent's turn, including any tool calls its subagents make.
> **Rationale:** Phase 0 Experiment #5 (T0.07) proved `agent_type` never appears on `SessionStart`; the prior filter placement was unreachable. Tool-call-layer filtering is the actually-enforceable version. Mandatory logging preserves history for future UI work (logging is cheap; reconstructing without logs is impossible).
> **Source:** Phase 0 Experiment #5 (see `.coord/phase0-verification.md`); Phase 1 `02` A7, `04` Scenario 23, `05` assumption B; plan-revisions PR-PHASE0-01.

> **Decision 2.18:** Read-set validation scope: **all Read tool invocations** are tracked with sha256 hashes in `read_sets[session_id].reads[]`. Grep-with-content, Bash reads, and MCP-tool reads are **not** tracked in v1.
> **Rationale:** Simplest reliable boundary. `Read` tool is the dominant path; Grep/Bash coverage increases complexity without proportional safety gain.
> **Source:** Phase 1 `02` D2, `03` §14.

> **Decision 2.19:** Peer watchdog liveness check uses **PID + process start-time (`lstart`)**. A session is "truly dead" only when `ps -p <pid> -o lstart=` returns empty OR returns a different `lstart` than recorded (PID recycled). Consensus is reached only when a **second session confirms the PID-absent/recycled state**, not merely that the age threshold is exceeded.
> **Rationale:** Prevents false-positive eviction of legitimately slow sessions (Scenario 6) and catches PID recycling (Scenario 8).
> **Source:** Phase 1 `04` scenarios 6 & 8, `05` assumption F.

> **Decision 2.20:** Lock TTL default is **15 minutes** of no activity (lock-holder making any tool call on that file refreshes the TTL). Watchdog suspicion threshold: **20 minutes** with no activity. Confirmation (PID check): **25 minutes** with PID-absent/recycled. **Tunable bounds (enforced by installer + `coord health`):**
> - `lock_ttl_seconds` minimum 300 (5 min);
> - `watchdog_suspicion_seconds` must be `> lock_ttl_seconds`;
> - `watchdog_confirm_seconds` must be `> watchdog_suspicion_seconds`;
> - `wait_max_seconds` must satisfy `30 ≤ wait_max_seconds < 600`. Upper bound: 600 s is the Claude Code Bash-tool configurable maximum (F-008). Lower bound: 30 s prevents accidental misconfiguration to near-zero values that would make passive wait unusable. Default `570` = 600 s Bash-tool ceiling − 30 s safety margin to avoid hitting the tool timeout before coord's own timeout fires and logs a clean `WAIT_TIMEOUT` event.
>
> The installer validates `config.json` on load and refuses to start with invalid combinations; `coord health` surfaces the same check for ongoing installs.
> **Rationale:** Balances Scenario 19 (too-long locks deadlock others) with Scenario 6 (legit long sessions not evicted). Tunable in `.coord/config.json`. Bounds prevent misconfigured installs from inverting the ordering (confirm < suspicion < TTL) which would cause spurious evictions. `wait_max_seconds` bounds enforce the Bash-tool 10-min ceiling discovered in Phase 0 Experiment #9.
> **Source:** Phase 1 `04` Scenario 19, `05` assumption F; Phase 0 Experiment #9 (T0.11) for `wait_max_seconds` bounds; plan-revisions PR-PHASE0-01; planner-selected defaults.

> **Decision 2.21:** All coordination files (hook scripts, state, logs, config) live under `.coord/` at the **git toplevel** (`git rev-parse --show-toplevel`). Everything is gitignored. The installer appends `.coord/` to `.gitignore` if missing. The installer also writes hook entries to `.claude/settings.local.json`, which is also gitignored by convention.
> **Rationale:** User direction (everything gitignored). Repo-root anchoring solves Scenario 17 (sessions in subdirectories still coordinate).
> **Source:** User direction (Config Placement); Phase 1 `04` Scenario 17.

> **Decision 2.22:** Git HEAD is recorded in each session's registration record at `SessionStart` and on every `UserPromptSubmit`. On any `PreToolUse`, if current HEAD differs from recorded HEAD, all of this session's `read_sets` entries are marked `superseded_by_head_change: true`, and subsequent writes trigger validation subagent.
> **Rationale:** Phase 1 `04` Scenario 22 showed git branch switches cause a cascade of false-positive hash mismatches; explicit HEAD tracking sidesteps the cascade.
> **Source:** Phase 1 `04` Scenario 22; planner-originated.

> **Decision 2.23:** A root-level, gitignored file `IMPLEMENTATION_LOG.md` is maintained by the Phase 3 builder as an append-only construction progress record. Updated before starting and after completing each task. Structure defined in CLAUDE.md §A.11.
> **Rationale:** End-of-phase sign-offs are insufficient for multi-week construction spanning context-limited Claude sessions. A live log preserves state for resumption.
> **Source:** User direction (revision round), planner-originated structural detail.

> **Decision 2.24:** A root-level, gitignored file `FINDINGS.md` is maintained alongside `IMPLEMENTATION_LOG.md`, capturing observations, plan inaccuracies, environment quirks, and deferred questions that emerge during construction. Entries transition through states OPEN → RESOLVED / WONTFIX / DEFERRED. Structure defined in CLAUDE.md §A.12.
> **Rationale:** The plan cannot anticipate every detail; a dedicated location for "things the plan didn't say" prevents them from being lost or mixed into the progress log.
> **Source:** User direction (revision round).

---

## Section 3 — Final Architecture

### 3.1 Layer list (nine components)

The source design had eight layers; this plan adds the **Mediator** as its own component, making nine. Every layer is described hook-first.

1. **Atomic state primitive.** `flock`-guarded read-modify-write on `sessions.json` via temp-file-then-rename. All mutations go through `lib/atomic_write.sh`. Underpins everything.
2. **Session registry.** `SessionStart` hook registers participating sessions (UUID, PID, PID start-time, git HEAD, coord schema version) in `sessions.sessions[<session_id>]`. `SessionEnd` deregisters best-effort. Non-participants (no `CLAUDE_COORD=1`) skipped.
3. **Read-set tracking.** `PreToolUse(Read)` hook computes file sha256, appends entry to `read_sets[<session_id>].reads[]`, deduplicates (latest supersedes older).
4. **Write locks + stale-read gate.** `PreToolUse(Write|Edit)` hook: (a) if another session holds lock on the target → `permissionDecision: "deny"` with delegation guidance; (b) if read-set hash mismatch on any file this session read → set validation flag, deny pending validator verdict, then re-evaluate; (c) otherwise acquire lock atomically and allow.
5. **Lock release & task processing.** `PostToolUse(Write|Edit)` hook: process pending delegated tasks on the lock (if any), release lock, wake any sessions waiting on the file, emit notifications.
6. **Peer watchdog.** Runs opportunistically inside every participant's `SessionStart` hook and every `PreToolUse` hook at a sampled cadence (1-in-N to amortize cost). Scans `sessions.sessions` for ACTIVE entries older than threshold, verifies PID + lstart, records suspicion, reaches consensus, cleans up dead sessions.
7. **Validation subagent.** Agent-type hook guarded by `.coord/validation/<session_id>.json` flag file. Classifies stale-read diffs as SAFE/MINOR/CRITICAL.
8. **Wait queue + notification inbox.** `wait_queue[<file>]` holds sessions passively waiting (via `coord wait` CLI); `notifications[<session_id>]` holds async messages; `PreToolUse` hooks inject relevant notifications via `additionalContext`.
9. **Mediator.** Agent-type hook guarded by `.coord/mediator/pending.json`. Invoked when any command hook detects an anomaly (corrupt state, stuck lock, fork-bomb suspicion, consensus dispute, schema mismatch). Analyzes, remediates, clears the flag, injects summary. Also callable via `/coord-mediate` skill.

### 3.2 File structure on disk

```
<git-toplevel>/
├── .claude/
│   └── settings.local.json          # gitignored; hook registrations
├── .coord/                          # gitignored; all coordination state
│   ├── sessions.json                # live state (see §3.3)
│   ├── sessions_history.json        # curated archive of significant events
│   ├── events.jsonl                 # append-only structured event stream
│   ├── sessions.lock                # flock sentinel for sessions.json
│   ├── events.lock                  # flock sentinel for events.jsonl
│   ├── history.lock                 # flock sentinel for sessions_history.json
│   ├── config.json                  # tunables (see §3.7)
│   ├── schema_version               # single-line version string
│   ├── sessions/
│   │   ├── <session_id>.active      # participant marker file
│   │   ├── <session_id>.wait        # wake-file for passive-wait semaphore
│   │   └── <session_id>.env         # per-session cached values (prompt, HEAD)
│   ├── validation/
│   │   └── <session_id>.json        # pending stale-read validation payload
│   ├── mediator/
│   │   ├── pending.json             # anomaly payload for Mediator
│   │   └── verdict/<timestamp>.json # historical Mediator decisions
│   ├── hooks/
│   │   ├── session_start.sh
│   │   ├── session_end.sh
│   │   ├── user_prompt_submit.sh
│   │   ├── pre_tool_use_read.sh
│   │   ├── pre_tool_use_write.sh
│   │   ├── pre_tool_use_any.sh
│   │   ├── post_tool_use_write.sh
│   │   ├── stop.sh
│   │   ├── mediator_agent.md
│   │   └── validator_agent.md
│   ├── lib/
│   │   ├── atomic_write.sh
│   │   ├── hash.sh
│   │   ├── log_event.sh
│   │   ├── state_query.sh
│   │   ├── participant.sh
│   │   └── watchdog.sh
│   └── bin/
│       └── coord                    # CLI entry point
└── .gitignore                        # .coord/ and .claude/settings.local.json appended
```

### 3.3 `sessions.json` schema (strict JSON Schema, v1.0)

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "CoordSessionsV1",
  "type": "object",
  "required": ["schema_version", "sessions", "locks", "wait_queue", "read_sets", "notifications", "self_tasks", "anomaly_votes", "task_graph"],
  "additionalProperties": false,
  "properties": {
    "schema_version": { "const": "1.0" },
    "sessions": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "required": ["state", "pid", "pid_lstart", "registered_at", "last_activity_at", "git_head"],
        "properties": {
          "state":           { "enum": ["ACTIVE", "IDLE_ALIVE", "IDLE_CLOSED"] },
          "pid":             { "type": "integer" },
          "pid_lstart":      { "type": "string" },
          "registered_at":   { "type": "string", "format": "date-time" },
          "last_activity_at":{ "type": "string", "format": "date-time" },
          "git_head":        { "type": "string" },
          "prompt_id":       { "type": ["string","null"] },
          "script_version":  { "type": "string" }
        }
      }
    },
    "locks": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "required": ["session", "acquired_at", "last_refresh_at", "tasks"],
        "properties": {
          "session":         { "type": "string" },
          "acquired_at":     { "type": "string", "format": "date-time" },
          "last_refresh_at": { "type": "string", "format": "date-time" },
          "tasks": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["id", "from", "instruction", "complexity", "anchor", "status", "created_at"],
              "properties": {
                "id":             { "type": "string" },
                "from":           { "type": "string" },
                "instruction":    { "type": "string", "maxLength": 4000 },
                "rationale":      { "type": "string" },
                "complexity":     { "enum": ["SIMPLE","MODERATE","COMPLEX"] },
                "anchor": {
                  "type": "object",
                  "required": ["search","window_lines"],
                  "properties": {
                    "search":       { "type": "string" },
                    "context":      { "type": "string" },
                    "window_lines": { "type": "string" },
                    "window_hash":  { "type": "string" }
                  }
                },
                "status":         { "enum": ["PENDING","ACCEPTED","IN_PROGRESS","COMPLETED","FAILED","CONFLICT","SKIPPED"] },
                "created_at":     { "type": "string", "format": "date-time" },
                "applied_at":     { "type": ["string","null"], "format": "date-time" },
                "affected_lines": { "type": ["array","null"], "items": { "type":"integer" } },
                "diff":           { "type": ["string","null"] },
                "outcome":        { "type": ["string","null"] },
                "chain_depth":    { "type": "integer", "minimum": 0, "maximum": 3 },
                "parent_task_id": { "type": ["string","null"] }
              }
            }
          }
        }
      }
    },
    "wait_queue": {
      "type": "object",
      "additionalProperties": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["session","waiting_since","wake_file"],
          "properties": {
            "session":       { "type": "string" },
            "waiting_since": { "type": "string", "format": "date-time" },
            "wake_file":     { "type": "string" },
            "reason":        { "type": "string" }
          }
        }
      }
    },
    "read_sets": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "required": ["reads"],
        "properties": {
          "prompt_id":    { "type": ["string","null"] },
          "validated_at": { "type": ["string","null"], "format": "date-time" },
          "reads": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["path","ts","hash","is_latest"],
              "properties": {
                "path":                       { "type": "string" },
                "ts":                         { "type": "string", "format": "date-time" },
                "hash":                       { "type": "string", "pattern": "^[0-9a-f]{64}$" },
                "is_latest":                  { "type": "boolean" },
                "superseded_by":              { "type": ["string","null"] },
                "superseded_by_head_change":  { "type": "boolean", "default": false }
              }
            }
          }
        }
      }
    },
    "notifications": {
      "type": "object",
      "additionalProperties": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["type","created_at","payload"],
          "properties": {
            "type":       { "enum": ["stale_read","lock_released","task_outcome","head_change","mediator_verdict","watchdog_eviction"] },
            "created_at": { "type": "string", "format": "date-time" },
            "expires_at": { "type": "string", "format": "date-time" },
            "delivered":  { "type": "boolean", "default": false },
            "payload":    { "type": "object" }
          }
        }
      }
    },
    "self_tasks": {
      "type": "object",
      "additionalProperties": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["file","instruction","created_at","prompt_id","status"],
          "properties": {
            "file":        { "type": "string" },
            "instruction": { "type": "string", "maxLength": 4000 },
            "created_at":  { "type": "string", "format": "date-time" },
            "prompt_id":   { "type": "string" },
            "status":      { "enum": ["PENDING","RETURNED","SKIPPED"] }
          }
        }
      }
    },
    "anomaly_votes": {
      "type": "object",
      "additionalProperties": {
        "type": "array",
        "items": {
          "type": "object",
          "required": ["voter","observed_at","kind"],
          "properties": {
            "voter":       { "type": "string" },
            "observed_at": { "type": "string", "format": "date-time" },
            "kind":        { "enum": ["stale_active","pid_absent","pid_recycled","corrupt_state"] },
            "evidence":    { "type": "string" }
          }
        }
      }
    },
    "task_graph": {
      "type": "object",
      "description": "Adjacency list of delegation edges for cycle detection.",
      "additionalProperties": {
        "type": "array",
        "items": { "type": "string" }
      }
    }
  }
}
```

### 3.4 `sessions_history.json` schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "CoordHistoryV1",
  "type": "object",
  "required": ["schema_version", "events"],
  "properties": {
    "schema_version": { "const": "1.0" },
    "events": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["ts","event","session"],
        "properties": {
          "ts":      { "type": "string", "format": "date-time" },
          "event":   { "enum": [
                        "SESSION_REGISTERED","SESSION_ENDED",
                        "LOCK_ACQUIRED","LOCK_RELEASED","LOCK_EVICTED",
                        "TASK_COMPLETED","TASK_FAILED","TASK_CONFLICT","TASK_SKIPPED",
                        "MEDIATOR_VERDICT","WATCHDOG_EVICTION",
                        "SCHEMA_MIGRATION","STATE_RESET"
                      ] },
          "session": { "type": "string" },
          "payload": { "type": "object" }
        }
      }
    }
  }
}
```

### 3.5 `events.jsonl` event schema (one per line)

```json
{
  "ts":        "2026-04-24T09:14:22.481Z",
  "session":   "2d6a8f9e-...",
  "kind":      "READ|WRITE|LOCK_ACQUIRE|LOCK_RELEASE|LOCK_DENY|TASK_OPEN|TASK_APPLY|TASK_OUTCOME|SELF_TASK_OPEN|SELF_TASK_TRIGGER|NOTIFICATION_EMIT|NOTIFICATION_DELIVER|WATCHDOG_CHECK|WATCHDOG_VOTE|MEDIATOR_INVOKE|MEDIATOR_VERDICT|VALIDATOR_INVOKE|VALIDATOR_VERDICT|ERROR|INFO|HEAD_CHANGE|PROMPT_SUBMIT|SESSION_REGISTER|SESSION_RESUME|SESSION_CLEAR|SESSION_COMPACTED|SESSION_END|RESUME_ORPHAN_LOCK_DETECTED|SUBAGENT_ACTIVITY_SKIPPED|WAIT_CLAMPED|WAIT_TIMEOUT",
  "tool":      "Read|Write|Edit|Bash|...",
  "file":      "...",
  "hash":      "...",
  "payload":   {}
}
```

Every hook appends exactly one event per meaningful action. The `log_event.sh` helper backgrounds the append via `&` to keep the critical path fast.

### 3.6 Config file `.coord/config.json`

```json
{
  "schema_version": "1.0",
  "task_delegation": true,
  "lock_ttl_seconds": 900,
  "watchdog_suspicion_seconds": 1200,
  "watchdog_confirm_seconds": 1500,
  "read_set_cap_per_session": 200,
  "wait_poll_schedule_seconds": [30, 60, 120],
  "wait_max_seconds": 570,
  "max_task_chain_depth": 3,
  "max_tasks_per_lock": 5,
  "max_anchor_window_lines": 10,
  "validator_enabled": true,
  "mediator_enabled": true
}
```

### 3.7 Sequence diagrams (prose + ASCII)

#### 3.7.1 Representative read

```
Claude (Session A) → Read foo.ts
   │
   ▼
PreToolUse(Read) hook (pre_tool_use_read.sh)
   1. Check .coord/sessions/<A>.active — if absent → noop exit 0
   2. Read $CLAUDE_PROJECT_DIR's .coord/sessions.json (no flock needed for read)
   3. Check notifications for A about foo.ts → inject via additionalContext if any
   4. Compute sha256 of foo.ts
   5. atomic_write.sh: flock sessions.lock → append/supersede in read_sets[A].reads
   6. log_event READ
   7. exit 0 (allow)
   │
   ▼
Claude reads foo.ts; sees additionalContext (if injected)
```

#### 3.7.2 Representative write (uncontested)

```
Claude (Session A) → Edit foo.ts
   │
   ▼
PreToolUse(Write|Edit) hook (pre_tool_use_write.sh)
   1. Participant check → passes
   2. Flock sessions.lock
   3. Read sessions.json
   4. Is foo.ts in locks? No.
   5. Validate read-set: foreach read in read_sets[A].reads where file==foo.ts:
        current_hash = sha256(foo.ts)
        if current_hash != entry.hash:
          → write validation pending flag; deny with "stale read suspected"
   6. No mismatch. Acquire lock: locks[foo.ts] = {session:A, acquired_at, last_refresh_at, tasks:[]}
   7. Update sessions[A].last_activity_at
   8. Flush jq → temp → rename; release flock
   9. log_event LOCK_ACQUIRE
   10. exit 0 (allow)
   │
   ▼
Tool executes: foo.ts is written
   │
   ▼
PostToolUse(Write|Edit) hook (post_tool_use_write.sh)
   1. Flock sessions.lock
   2. Process locks[foo.ts].tasks[] in order
       for each task: apply, record outcome+diff, mark status
   3. Release lock: delete locks[foo.ts] → archive to sessions_history
   4. Wake wait_queue[foo.ts]: touch each wake_file, emit lock_released notifications
   5. Release flock
   6. log_event LOCK_RELEASE + TASK_OUTCOME (per task)
```

#### 3.7.3 Contested lock — **task delegation path**

```
Claude (Session B) → Edit foo.ts while Session A holds lock
   │
   ▼
PreToolUse(Write|Edit) hook
   1. Flock, read sessions.json
   2. locks[foo.ts].session == A ≠ B
   3. Build additionalContext:
        "foo.ts is locked by session A since 10:12:07 (~4 min).
         Your options:
         (a) delegate a SIMPLE/MODERATE task by outputting a `coord task-open ...` invocation.
         (b) self-delegate: note this for later, continue other work.
         (c) passively wait: run `coord wait foo.ts --timeout 600`.
         Pick based on change complexity."
   4. permissionDecision: "deny", reason = additionalContext
   5. log_event LOCK_DENY
   │
   ▼
Claude reasons, decides the change is SIMPLE, issues:
   Bash: coord task-open --file foo.ts --complexity SIMPLE --anchor '...' --instruction '...'
   │
   ▼
coord task-open CLI
   1. Validates anchor uniqueness against current foo.ts (fails → CONFLICT reported immediately)
   2. Validates chain depth via task_graph (fails if >3 or cycle → reported)
   3. Flock → append to locks[foo.ts].tasks, update task_graph edge A→B
   4. log_event TASK_OPEN
   │
   ▼
Claude continues other work. Later, A releases lock → A's post_tool_use_write.sh processes the task.
```

#### 3.7.4 Contested lock — **self-delegation path**

```
Claude (Session B) → Edit foo.ts while Session A holds lock; change is COMPLEX
   │
   ▼
PreToolUse(Write|Edit) hook denies with options as above.
   │
   ▼
Claude issues:
   Bash: coord self-delegate --file foo.ts --instruction "do the X refactor once unlocked"
   │
   ▼
coord self-delegate CLI
   1. Flock, append to self_tasks[B]
   2. log_event SELF_TASK_OPEN
   │
   ▼
Claude continues with other subtasks in the same prompt.
   │
   ▼
Every subsequent PreToolUse(any tool) by B:
   pre_tool_use_any.sh checks self_tasks[B] for entries whose file is now unlocked
   If any → additionalContext: "REMINDER: foo.ts is now unlocked; you deferred work on it earlier."
   │
   ▼
Claude (seeing reminder) may at its discretion return to foo.ts, which flows through the normal write path.
   │
   ▼
On Stop: if self_tasks[B] non-empty, first Stop returns decision:"block" with a summary reminder.
   Second Stop (Claude ignored/dismissed) allows exit and archives self-tasks as SKIPPED.
```

#### 3.7.5 Contested lock — **passive wait path**

```
Claude → Edit foo.ts while locked; Claude chose passive wait.
   │
   ▼
Claude issues:
   Bash: coord wait foo.ts --timeout 600
   │
   ▼
coord wait CLI
   1. Flock, append wait_queue[foo.ts] += {session:B, waiting_since, wake_file: .coord/sessions/B.wait}
   2. Release flock
   3. Sleep schedule: 30, 60, 120, 120... up to timeout
        After each sleep: check if wake_file is newer than waiting_since; check lock presence.
        If wake_file touched OR lock gone → exit 0 with stdout "foo.ts released"
   4. On timeout → exit 1 with stdout "timeout after Ns"
   │
   ▼
Post-release hook (A's post_tool_use_write.sh):
   For each wait entry, `touch` the wake_file. coord wait sees it and exits.
   │
   ▼
Claude sees the coord wait output, retries Edit foo.ts, now succeeds.
```

#### 3.7.6 Mediator invocation for stuck/anomalous state

```
Command hook detects anomaly (example: corrupt sessions.json)
   │
   ▼
Hook writes .coord/mediator/pending.json = {kind:"corrupt_state", detected_at, evidence, reporter:session_id}
Hook logs ERROR, returns additionalContext: "Coordination state anomaly detected; Mediator will diagnose on next tool call."
Hook exits 0 (fail-open) so the session can continue.
   │
   ▼
Next PreToolUse fires all registered hooks for the matcher. The mediator agent-hook runs.
mediator_agent.md prompt:
   "Read .coord/mediator/pending.json. If absent, output {} and exit.
    Otherwise investigate: read events.jsonl tail, run ps on any sessions, inspect sessions.json,
    decide on remediation (reset state / evict dead session / cancel stuck task / escalate to user).
    Apply remediation using Edit/Bash tools (restricted to .coord/). Write verdict to
    .coord/mediator/verdict/<ts>.json. Clear pending.json. Output additionalContext summarizing."
   │
   ▼
Mediator verdict is injected back into the session's context. The calling session now knows what was done.
```

### 3.8 Every mechanism is hook-first

Example anti-pattern to avoid:
> ~~"Before reading any file, Session A reads sessions.json and checks for notifications."~~

Correct pattern:
> On `Read`, the `PreToolUse(Read)` hook reads sessions.json (read-side, no flock needed), filters `notifications[<A>]` for entries referring to the target file, and emits them via `hookSpecificOutput.additionalContext`. Delivered entries are marked `delivered: true` via an atomic write.

This pattern applies uniformly across the architecture: enforcement lives in the hook; CLAUDE.md explains what the hook outputs mean.

---

## Section 4 — Component Breakdown

> **Component:** `.coord/hooks/session_start.sh`
> **Purpose:** Register a coordinated session, initialize per-session files, inject session_id + coord banner into context.
> **Type:** command hook (event: `SessionStart`).
> **Inputs:** stdin JSON (`session_id`, `source`, `agent_type` optional, `cwd`).
> **Outputs:** `additionalContext` with "Coord v1.0 active. Your session ID is <uuid>." and current participant count; creates `.coord/sessions/<id>.active`, writes session row in `sessions.json`.
> **Dependencies:** `lib/atomic_write.sh`, `lib/participant.sh`, `lib/log_event.sh`, `git`, `ps`.
> **Failure modes:** If `$CLAUDE_COORD` unset → exit 0, no registration, no injection. If `agent_type` populated → exit 0, no registration. If `jq`/`flock` missing → print human-readable error to stderr + exit 0 (fail-open). If sessions.json corrupt → Mediator flag + reset → register fresh.
> **Test criteria:** Given unset env, hook exits 0 with no state change. Given set env, `.coord/sessions/<id>.active` exists and `sessions.sessions[<id>]` is populated with `pid`, `pid_lstart`, `git_head`. Given `agent_type` populated in input, hook exits 0 without registering.

> **Component:** `.coord/hooks/session_end.sh`
> **Purpose:** Deregister best-effort on graceful session end.
> **Type:** command hook (event: `SessionEnd`).
> **Inputs:** stdin JSON (`session_id`, `end_reason`).
> **Outputs:** moves session record to IDLE_CLOSED, archives read-set summary to history, releases any still-held locks, deletes `.coord/sessions/<id>.active`, emits lock_released notifications.
> **Dependencies:** `lib/atomic_write.sh`, `lib/log_event.sh`.
> **Failure modes:** Not invoked on SIGKILL; relies on peer watchdog fallback. If `sessions.json` missing, no-op.
> **Test criteria:** After graceful end, no `locks[f].session == <id>` remains; `.active` file removed; `sessions_history` has SESSION_ENDED entry.

> **Component:** `.coord/hooks/user_prompt_submit.sh`
> **Purpose:** Capture the current prompt text and git HEAD snapshot for the session; refresh `last_activity_at`.
> **Type:** command hook (event: `UserPromptSubmit`).
> **Inputs:** stdin JSON (`session_id`, `prompt`).
> **Outputs:** updates `sessions.sessions[<id>].prompt_id` (hash of prompt), `git_head`; caches prompt digest to `.coord/sessions/<id>.env`. Invalidates read-set from previous prompt (marks `superseded_by: "new_prompt"`). If HEAD changed since last prompt, marks all read-set entries `superseded_by_head_change: true`.
> **Dependencies:** `lib/atomic_write.sh`, `git rev-parse`.
> **Failure modes:** Not a participant → no-op.
> **Test criteria:** New prompt zeroes out prior read-set (logically); changing git HEAD between prompts triggers head_change notification.

> **Component:** `.coord/hooks/pre_tool_use_read.sh`
> **Purpose:** Record a file read (sha256 + path) in the session's read-set; deliver pending notifications about the file.
> **Type:** command hook (event: `PreToolUse`, matcher: `Read`).
> **Inputs:** stdin JSON (`session_id`, `tool_input.file_path`).
> **Outputs:** appends read entry; emits `additionalContext` if relevant notifications exist (e.g., "File has been modified by session X since your last read").
> **Dependencies:** `lib/atomic_write.sh`, `lib/hash.sh`, `lib/participant.sh`, `lib/log_event.sh`, `shasum -a 256`.
> **Failure modes:** Non-participant → no-op. File missing → log ERROR, allow (Read will surface the error itself). File >10MB → record entry with `hash: "SKIPPED_LARGE"` and an event note; validation subagent treats as "changed" in future (conservative).
> **Test criteria:** After read, `read_sets[<id>].reads` includes the file with correct sha256. Second read of same file supersedes first entry. Notifications about the file are emitted and marked delivered.

> **Component:** `.coord/hooks/pre_tool_use_write.sh`
> **Purpose:** Enforce write locks; enforce stale-read gate; trigger validation subagent flag on mismatch.
> **Type:** command hook (event: `PreToolUse`, matcher: `Write|Edit|NotebookEdit`).
> **Inputs:** stdin JSON (`session_id`, `tool_input.file_path` or `tool_input.notebook_path`).
> **Outputs:** `hookSpecificOutput.permissionDecision: "deny"` with `permissionDecisionReason` (when locked by another or stale read) OR `"allow"` (acquires lock atomically, sets `additionalContext` with brief "lock acquired" note).
> **Dependencies:** `lib/atomic_write.sh`, `lib/hash.sh`, `lib/state_query.sh`, `lib/participant.sh`, `lib/log_event.sh`.
> **Failure modes:**
>  - Non-participant → allow.
>  - flock timeout → Mediator flag + fail-open allow with warning.
>  - sessions.json parse error → Mediator flag + reset to empty + allow with warning.
>  - sha256 compute failure on a read-set file → **fail-closed** deny (Decision 2.6 matrix).
> **Test criteria:** Locked-by-other → deny with actionable reason. Stale read detected → deny with "re-read required" reason and validation flag written. Unlocked + no stale read → lock acquired and allow.

> **Component:** `.coord/hooks/pre_tool_use_any.sh`
> **Purpose:** Cross-cutting context injection: notifications, self-task reminders, HEAD-change alerts, Mediator-pending notices.
> **Type:** command hook (event: `PreToolUse`, matcher: `.*` — runs first).
> **Inputs:** stdin JSON.
> **Outputs:** `additionalContext` aggregating relevant, per-operation signals.
> **Dependencies:** `lib/state_query.sh`, `lib/participant.sh`.
> **Failure modes:** Non-participant → no-op. If sessions.json corrupt → Mediator flag; inject "coordination degraded" banner; continue.
> **Test criteria:** With pending self-task on a now-unlocked file → reminder injected. With pending notification → delivered text injected + marked delivered.

> **Component:** `.coord/hooks/post_tool_use_write.sh`
> **Purpose:** Process pending delegated tasks on the lock, release lock, wake waiters.
> **Type:** command hook (event: `PostToolUse`, matcher: `Write|Edit|NotebookEdit`).
> **Inputs:** stdin JSON (`session_id`, `tool_input`, `tool_response`).
> **Outputs:** task outcomes written to history; lock removed; wake files touched; lock_released notifications emitted to any wait_queue members.
> **Dependencies:** `lib/atomic_write.sh`, `lib/log_event.sh`.
> **Failure modes:** If tool_response indicates failure, do not release lock (wait for next write or timeout). If task processing throws, record TASK_FAILED outcome with reason and continue releasing lock.
> **Test criteria:** Lock removed in sessions.json after successful write. Each pending task ends in one of COMPLETED/FAILED/CONFLICT/SKIPPED with a diff string. wake_files are newer-than the waiters' waiting_since.

> **Component:** `.coord/hooks/stop.sh`
> **Purpose:** End-of-turn cleanup; surface unresolved self-tasks; block-once-then-allow if reminders outstanding.
> **Type:** command hook (event: `Stop`).
> **Inputs:** stdin JSON (`session_id`).
> **Outputs:** `decision: "block"` on first invocation with outstanding self-tasks + reminder context. `decision: "allow"` on second invocation (archive self-tasks as SKIPPED). Release any still-held locks (graceful end).
> **Dependencies:** `lib/atomic_write.sh`, `lib/log_event.sh`.
> **Failure modes:** If Claude has been configured to bypass Stop, hook just logs SESSION_END and cleans up.
> **Test criteria:** Pending self-task → first Stop blocks; second Stop allows. No pending work → allows immediately.

> **Component:** `.coord/hooks/mediator_agent.md`
> **Purpose:** On-demand anomaly diagnosis and remediation using Claude-Code-internal subagent.
> **Type:** agent hook (event: `PreToolUse`, matcher: `.*`, runs only when `.coord/mediator/pending.json` exists).
> **Inputs:** reads `.coord/mediator/pending.json`, `events.jsonl` tail, `sessions.json`, may run `ps`.
> **Outputs:** writes `.coord/mediator/verdict/<ts>.json`; may apply remediation via Edit/Bash restricted to `.coord/` and state files (NOT project files); clears pending.json; emits `additionalContext` summary.
> **Dependencies:** Claude Code agent hook infrastructure; read/write on `.coord/`.
> **Failure modes:** Mediator itself fails → fallback command hook logs MEDIATOR_INVOKE_FAILED, surfaces to user via `additionalContext`, sets `mediator_enabled: false` in session-local config to prevent loop. User can re-enable via `coord mediate --retry`.
> **Test criteria:** Given corrupt sessions.json flag, Mediator resets state and logs verdict. Given stuck-lock flag with confirmed dead PID, Mediator evicts. Given ambiguous situation, Mediator escalates to user via additionalContext (no state change).

> **Component:** `.coord/hooks/validator_agent.md`
> **Purpose:** Classify a single stale-read diff as SAFE / MINOR / CRITICAL.
> **Type:** agent hook (event: `PreToolUse`, matcher: `Write|Edit`, runs only when `.coord/validation/<session_id>.json` exists).
> **Inputs:** reads the validation payload (task prompt, file, old_hash, current_hash, diff).
> **Outputs:** writes verdict to same payload (`{verdict:"SAFE|MINOR|CRITICAL", reason:"..."}`); emits `additionalContext` with verdict; if CRITICAL, the next pre_tool_use_write run denies the write until the session re-reads the file.
> **Dependencies:** agent hook infrastructure; git-style diff via Bash (`diff` command on snapshotted content).
> **Failure modes:** Validator errors → default to MINOR (conservative) with a "validator degraded" note.
> **Test criteria:** Whitespace-only diff → SAFE. Unrelated addition → SAFE. Semantically related change → CRITICAL. Deleted file → CRITICAL.

> **Component:** `.coord/lib/atomic_write.sh`
> **Purpose:** Single-source-of-truth for read-modify-write on sessions.json.
> **Type:** library module (sourced).
> **Inputs:** a jq filter string passed as $1 (transformation to apply to current state).
> **Outputs:** updated sessions.json on disk (atomic via temp + rename).
> **Dependencies:** `flock`, `jq`, `mktemp`, `mv`.
> **Failure modes:** flock timeout (>5s) → exit non-zero with code 42, caller decides (pre-tool hooks fail-open with Mediator flag; post-tool hooks escalate). jq non-zero → exit 43. Write failure → exit 44.
> **Test criteria:** Concurrent calls serialize. Interruption mid-call (SIGKILL on the script) leaves sessions.json intact via temp-then-rename invariant.

> **Component:** `.coord/lib/hash.sh`
> **Purpose:** Portable sha256 computation; size guard; cache by (path, mtime, size).
> **Type:** library module.
> **Inputs:** $1 = file path.
> **Outputs:** prints 64-hex-char sha256 on stdout; "SKIPPED_LARGE" if >10MB; exit non-zero if file missing.
> **Dependencies:** `shasum -a 256` (preferred) or `sha256sum` (Linux) as fallback.
> **Failure modes:** Missing tool → installer refused earlier. File missing → exit 1, caller logs as "file deleted between operations."
> **Test criteria:** Same file content gives same hash on macOS and Linux. 11MB file returns SKIPPED_LARGE.

> **Component:** `.coord/lib/participant.sh`
> **Purpose:** Cheap O(1) check that the current session is a coord participant.
> **Type:** library module.
> **Inputs:** $1 = session_id.
> **Outputs:** exit 0 if `.coord/sessions/<id>.active` exists; exit 1 otherwise.
> **Dependencies:** test.
> **Test criteria:** Presence/absence of marker file reflected in exit code with no other side effects.

> **Component:** `.coord/lib/log_event.sh`
> **Purpose:** Append a structured event to `.coord/events.jsonl` without blocking the critical path.
> **Type:** library module.
> **Inputs:** $@ = key=value pairs, serialized into JSON by jq.
> **Outputs:** single JSON line appended to events.jsonl. Implementation backgrounds the append with `&` and a subshell that holds `flock` on `events.lock` briefly.
> **Dependencies:** `flock`, `jq`, `date -u`.
> **Failure modes:** events.jsonl disk full → log to stderr + drop; never fail the hook.
> **Test criteria:** Concurrent log_event calls from 5 sessions produce valid JSONL with no interleaved bytes.

> **Component:** `.coord/lib/state_query.sh`
> **Purpose:** Read-only helpers that answer "is file X locked?", "what notifications for session Y?", etc., without acquiring flock (reads are safe; writes never cross mid-write thanks to temp+rename).
> **Type:** library module.
> **Test criteria:** Returns correct answers matching atomic_write expectations; never blocks.

> **Component:** `.coord/lib/watchdog.sh`
> **Purpose:** Peer watchdog logic. Runs opportunistically inside SessionStart and every PreToolUse (sampled 1-in-10 via `$RANDOM`).
> **Type:** library module.
> **Inputs:** none (reads state).
> **Outputs:** writes `anomaly_votes` entries; if consensus reached (2 distinct voters + PID-absent/recycled), evicts the session (move locks to history, set state to IDLE_CLOSED, clear read_set).
> **Dependencies:** `ps -p <pid> -o lstart=`, `atomic_write.sh`.
> **Failure modes:** `ps` output varies → rely only on the `lstart=` suffix trick; if format unparseable, treat as "unknown" and do not vote.
> **Test criteria:** Legit slow session with alive PID is not evicted. Killed session with lstart mismatch is evicted after 2 voters within threshold.

> **Component:** `.coord/bin/coord` (CLI)
> **Purpose:** Operator + Claude-usable entry point for subcommands.
> **Type:** command-line tool (Bash script).
> **Subcommands:**
>   - `coord status` — print active sessions, locks, wait queue, pending tasks, self-tasks, pending validations.
>   - `coord locks [--file <path>]` — list locks; optionally for one file.
>   - `coord tasks [--session <id>] [--file <path>]` — list tasks with filters.
>   - `coord wait <file> [--timeout 570]` — block until file unlocked or timeout. The requested `--timeout` is clamped to `[30, 570]`; a clamped request logs a `WAIT_CLAMPED` event with `{requested, applied}`. On timeout, emits a `WAIT_TIMEOUT` event before exiting non-zero.
>   - `coord task-open --file <path> --complexity <SIMPLE|MODERATE|COMPLEX> --anchor <json> --instruction <text> [--rationale <text>] [--parent <task_id>]` — open a delegated task on a locked file.
>   - `coord self-delegate --file <path> --instruction <text>` — add a self-task.
>   - `coord log [--tail N] [--kind K]` — print recent events.
>   - `coord events --since <iso8601>` — dump events after timestamp.
>   - `coord mediate` — invoke the Mediator on demand (writes pending.json with kind="manual").
>   - `coord mediate --retry` — clear a session-local `mediator_enabled: false` flag (set after a Mediator loop failure per R23) and re-enable Mediator; invokes the Mediator once to confirm recovery.
>   - `coord reset [--confirm]` — reset sessions.json (destructive; archives old state).
>   - `coord health` — run installer-level checks (flock, jq, shasum, filesystem).
>   - `coord install` — install hook entries and initialize `.coord/`.
>   - `coord uninstall` — remove hook entries from `.claude/settings.local.json`. Leaves `.coord/` directory on disk (state, history, logs) untouched. Does NOT remove `IMPLEMENTATION_LOG.md` or `FINDINGS.md`. Idempotent.
>   - `coord uninstall --purge` — as above, plus remove the `.coord/` directory entirely. Prompts for confirmation unless `--yes` is also passed. Never deletes `IMPLEMENTATION_LOG.md` or `FINDINGS.md`.
> **Test criteria:** Each subcommand has a bats test covering happy-path + one failure mode.

> **Component:** `install.sh` (root of repo after install, temporarily)
> **Purpose:** One-shot installer.
> **Type:** CLI tool.
> **Inputs:** none; interactive or non-interactive via `--yes`. Optional flags: `--repair`, `--uninstall`, `--bypass-permissions`.
> **Outputs:**
>   1. Locate repo root via `git rev-parse --show-toplevel`.
>   2. Check for `bash >= 3.2`, `jq`, `shasum -a 256`, `flock`, `ps`, `git`. Refuse + list missing.
>   3. Detect filesystem (parse `mount` for the project path) — refuse on NFS/FUSE/iCloud/Dropbox (listed patterns); print rationale; suggest local filesystem.
>   4. Create `.coord/`, `.coord/sessions/`, `.coord/validation/`, `.coord/mediator/`, `.coord/mediator/verdict/`.
>   5. Write hook scripts from this project into `.coord/hooks/`.
>   6. Write initial `sessions.json` (empty template), `config.json` (defaults), `schema_version`.
>   7. Append hook entries to `.claude/settings.local.json` (create if missing). The hook-registration jq pipeline only mutates the `.hooks` subtree by default; user-authored `.permissions`, env, and other top-level keys are preserved verbatim. **Opt-in `--bypass-permissions` flag**: when passed, the same pipeline additionally sets `.permissions.defaultMode = "bypassPermissions"` (DANGEROUS — disables every Claude Code tool-permission prompt in this repo). Off by default. Idempotent on re-run: with the flag, re-asserts the bypass mode; without the flag, leaves any existing `defaultMode` value alone (never silently demotes the user's chosen mode). `--bypass-permissions` is ignored under `--uninstall` (uninstall does not modify permissions; users revert manually).
>   8. Append `.coord/` and `.claude/settings.local.json` to `.gitignore` (create if missing).
>   9. Smoke test: spawn a throwaway session that runs the hooks on a no-op.
>   10. Print next steps: "Set CLAUDE_COORD=1 in the shell that launches Claude Code. Verify with `coord status`." Additionally, when `--bypass-permissions` was passed, surface a banner reminding the operator that defaultMode is now `"bypassPermissions"` and how to revert.
> **Test criteria:** Runs cleanly on fresh macOS + Linux systems; refuses on NFS test mount; idempotent (re-run does not corrupt existing install). `--bypass-permissions` opt-in path: setting present after install, user-authored `.permissions` keys (allow/deny lists, etc.) preserved alongside the new `defaultMode`, and re-running install WITHOUT the flag does not strip the previously-set `defaultMode`.

> **Component:** `IMPLEMENTATION_LOG.md` (project root)
> **Purpose:** Append-only construction progress record; primary source of "where are we" state.
> **Type:** hand-maintained markdown file.
> **Inputs:** builder-authored entries at task boundaries.
> **Outputs:** human-readable log consulted at phase start and by any resuming session.
> **Dependencies:** convention only.
> **Failure modes:** builder forgets to update → ship gate enforces consistency (no phase closes with `[IN_PROGRESS]` entries in its section).
> **Test criteria:** at end of any phase, every task in that phase has a checked entry with timestamp and result note; ship gate checklist fully checked.

> **Component:** `FINDINGS.md` (project root)
> **Purpose:** Live record of construction-time observations, surprises, and deferred questions.
> **Type:** hand-maintained markdown file.
> **Inputs:** builder-authored entries whenever an unplanned observation arises.
> **Outputs:** human-readable findings index, consulted at phase close and during debugging.
> **Dependencies:** convention; loose coupling to `plan-revisions.md`.
> **Failure modes:** OPEN findings at phase close without disposition → phase cannot close.
> **Test criteria:** every OPEN entry either has a resolution path noted or is explicitly marked DEFERRED with a reason; IDs never reused.

---

## Section 5 — Phased Implementation Plan

### Phase 0 — Ground truth and scaffolding

**Goal.** Capability verification + foundational scaffolding. Everything downstream depends on this being solid.

**Scope.**
- Run the 8 verification experiments in `03` §21 (two-terminal session IDs; write-race ordering; `permissionDecision: deny` reaches Claude; `updatedInput`; subagent agent_type firing; SIGKILL vs SessionEnd; hook latency baseline; `flock` on representative filesystems).
- **Experiment #9 (Bash tool timeout):** determine Claude Code's default Bash tool timeout by running `bash -c 'sleep 900 && echo done'` in a test session; record the observed cutoff. Result feeds OI-2 (`coord wait` default timeout must stay below the Bash-tool ceiling).
- Implement `lib/atomic_write.sh`, `lib/hash.sh`, `lib/log_event.sh`, `lib/participant.sh`, `lib/state_query.sh`.
- Implement `session_start.sh`, `session_end.sh` (registration only — no locking, no read-sets yet).
- Implement `install.sh` (including filesystem refusal for NFS/iCloud/Dropbox).
- Implement `events.jsonl` pipeline with concurrency smoke test (5 parallel sessions writing).
- Establish `bats` test suite skeleton with fixtures (mock stdin JSON, mock `.coord/` directory).
- Lock `schema_version = "1.0"`.

**Out of scope for this phase.** Read-set, locks, tasks, watchdog, validation, Mediator.

**Done when.**
- All **9** verification experiments (8 from `03` §21 + Experiment #9 above) have written results in `.coord/phase0-verification.md` (a build artifact, not part of shipped deliverables).
- `coord install` works end-to-end on macOS + Linux; registers a session; logs registration event; `coord status` shows the session.
- `bats` harness passes for the Phase 0 components.
- `events.jsonl` is valid JSONL under 5-session concurrent load.

**Risks.**
- A verification experiment shows a hook behaves differently than Phase 1 research assumed. Mitigation: plan revision in `plan-revisions.md`; may require schema tweaks.
- `flock` on the user's filesystem fails unexpectedly. Mitigation: installer refuses; user notified.

**Rollback.** Uninstall via `coord uninstall`; removes hook entries and gitignore lines; state directory remains until manually deleted.

### Phase 1 — Stale-read warning only (never worse than no coord)

**Goal.** Ship the stale-read detector. Two real Claude sessions with one modifying a file the other read produces a visible warning in the second session's context. No write blocking yet.

**Scope.**
- `pre_tool_use_read.sh`: record Read → read_set with sha256.
- `pre_tool_use_write.sh`: validate read_set; if any file changed, emit `additionalContext` warning (no deny yet).
- `pre_tool_use_any.sh`: (minimal) deliver notifications.
- `user_prompt_submit.sh`: capture prompt + HEAD.
- Corruption recovery (detect + reset + log).
- `coord status` extended to show per-session read-sets.

**Out of scope.** Locks (no write-write prevention). Validation subagent (text warnings only). Watchdog. Tasks. Wait queue. Mediator (stub in place for corruption recovery only).

**Done when.**
- Two-session scenario: Session B modifies foo.ts; Session A's next Write (on any file) sees a warning in `additionalContext` citing foo.ts.
- No false negative in the direct scenario.
- Phase 1 is **never worse** than no coordination: the hook cannot block a tool call in any code path.

**Risks.**
- False positives (formatter runs, editor saves). Accepted for this phase; validation subagent (Phase 4) absorbs.

**Rollback.** Same as Phase 0.

### Phase 2 — Write coordination

**Goal.** Prevent write-write conflicts with hook-enforced deny. Reuse Phase 1's read-set gate.

**Scope.**
- Lock acquisition in `pre_tool_use_write.sh` (flock-protected).
- `permissionDecision: "deny"` when another session holds the lock; `permissionDecisionReason` details the lock-holder + duration + **three options** text (delegate / self-delegate / passive wait).
- Lock release in `post_tool_use_write.sh`.
- Lock release on Stop + SessionEnd (graceful).
- `coord wait <file>` CLI (passive-wait path implementation).
- Lock TTL refresh on any tool call by the holder.

**Out of scope.** Task delegation implementation (the deny message mentions the option, but `coord task-open` is a Phase 6 deliverable). Self-delegation (same). Peer watchdog (still relies on Stop/SessionEnd). Validation subagent (still text warnings).

**Done when.**
- Concurrent writes by two sessions on the same file: one acquires lock and succeeds; the other sees `permissionDecision: "deny"` with actionable reason.
- `coord wait foo.ts` sleeps, receives wake via lock-release, and exits 0 with the unlocked status.
- Read-set warnings from Phase 1 continue working.

**Risks.**
- A crashed session leaves a lock orphan (no watchdog yet). Mitigation: `coord status` exposes orphan for manual `coord reset`. Phase 3 fixes.

**Mediator thread.** Mediator flag file infrastructure appears here: corrupt sessions.json or flock timeout writes to `.coord/mediator/pending.json`; a stub command-hook (not yet the agent) reads it and emits a warning banner. Full agent Mediator comes in Phase 3.

**Rollback.** If Phase 2 is broken, uninstall; Phase 1's read-set tracking remains useful standalone.

### Phase 3 — Recovery, health, and Mediator

**Goal.** Self-healing. Crashed sessions no longer freeze others. Anomalies trigger Mediator.

**Scope.**
- `lib/watchdog.sh`: sampled from SessionStart + PreToolUse; PID+lstart liveness; 2-voter consensus requiring PID-absent/recycled.
- Lock eviction + notification to anyone waiting.
- Subagent / primary session discrimination (`agent_type` filter integrated everywhere; fork-bomb guard on agent hook entry).
- `hooks/mediator_agent.md` full agent-type hook.
- `/coord-mediate` skill (user-invocable).
- Mediator-invoked remediations: reset state, evict dead session, cancel stuck task.

**Out of scope.** Validation subagent agent-hook (still text warnings). Task delegation. Self-delegation.

**Done when.**
- SIGKILL a session; within `watchdog_confirm_seconds` another session's hook cleans up its locks and read-set.
- Legitimate 20-minute reasoning session (with occasional tool calls refreshing last_activity) is NOT evicted.
- Corrupt sessions.json → Mediator resets + logs; next session operation works.
- Running `/coord-mediate` on a healthy system returns "no anomalies detected."

**Risks.** Mediator verdict is wrong (evicts live session). Mitigation: Mediator logs verdict to history; `coord reset --restore` exists for manual rollback; require PID-recycled OR 2 voters.

**Rollback.** Disable watchdog via `watchdog_enabled: false` in config; fall back to Phase 2 behavior.

### Phase 4 — Validation subagent (agent-type hook)

**Goal.** Reduce stale-read false positives by letting a subagent classify diffs as SAFE / MINOR / CRITICAL.

**Scope.**
- `validator_agent.md` agent hook.
- Flag file `.coord/validation/<session_id>.json` written by `pre_tool_use_write.sh` when hash mismatch found.
- CRITICAL verdict → enforced deny on next write attempt until session re-reads.
- MINOR verdict → injected context with diff summary.
- SAFE verdict → silent pass.
- Fork-bomb guard: validator never fires on subagent sessions.

**Out of scope.** Task delegation, self-delegation, wait queue formalization.

**Done when.**
- Formatter-only change → SAFE verdict, silent.
- Unrelated addition → SAFE.
- Semantically adjacent change → CRITICAL with reasoned explanation.
- Repeated SAFE verdicts for the same file+diff are cached in `.coord/validation/cache.json` to avoid token churn.

**Risks.** Validator itself errors (agent hook failure) → default to MINOR (conservative); `mediator_enabled: false` never implied here, only validator-off as a per-session fallback.

**Rollback.** `validator_enabled: false` in config; falls back to Phase 1 text warnings.

### Phase 5 — Wait queue with notifications

**Goal.** Smooth the passive-wait path beyond the basic `coord wait` implementation; formalize FIFO + notifications.

**Scope.**
- `wait_queue[<file>]` FIFO with explicit `waiting_since` ordering.
- Notification emission on lock-release includes content summary ("A renamed loginHandler→signInHandler" — when the task outcome records a diff).
- Three sessions queue on same file → proceed in order without polling.
- `additionalContext` for passive-waiters when they wake up: "You waited for foo.ts; it was released after N seconds. Changes since you last read it: ..."
- Mediator detects deadlocks via `task_graph` cycle detection + wait_queue-deeper-than-N and intervenes.

**Done when.**
- Ordered wake-up verified with 3 sessions.
- Wake-up context contains non-empty diff when lock-holder produced changes.
- Cycle introduced artificially triggers Mediator verdict that breaks the cycle by selecting a session to evict or escalate.

**Rollback.** Disable via `wait_queue_enabled: false`; Phase 4 behavior remains.

### Phase 6 — Task delegation + self-delegation

**Goal.** End-to-end task-delegation and self-delegation flows. Highest-risk feature; arrives last.

**Scope.**
- `coord task-open` CLI: anchor uniqueness check, complexity classification hand-off to Claude, chain-depth + `task_graph` cycle detection.
- `post_tool_use_write.sh` task processor: processes `locks[f].tasks` in order; checks `affected_lines` overlap; writes outcome+diff+status.
- Task outcome notification to opener (with diff embedded).
- `coord self-delegate` CLI + self-task record in `self_tasks[<id>]`.
- `pre_tool_use_any.sh` self-task reminder injection (checks unlocked files in self-tasks).
- `stop.sh` self-task block-once-then-allow.
- Task-delegation toggle: honored when `task_delegation: false` → `coord task-open` exits with "disabled per repo."

**Done when.**
- Happy path: A locks foo.ts, B opens a SIMPLE task, A processes task at release; B receives COMPLETED notification with diff.
- Ambiguous anchor → CONFLICT before application.
- Chain depth > 3 or cycle → rejected with clear error.
- Self-delegation: B defers, continues, later sees reminder, returns.
- `task_delegation: false` → deny message omits option (a), offers only self-delegate / passive-wait.

**Risks.** Highest failure-mode count (Scenarios 1, 7, 10, 14, 20). Mitigation: toggle-off by repo; Mediator can close orphan tasks; each task's outcome includes a diff so the opener can inspect.

**Rollback.** Toggle `task_delegation: false`.

### Phase 7 — Test harness + comparative evaluation

**Goal.** Deliver the four-configuration test harness demanded by the user's success criteria. Verify Mediator + Validator real-`claude -p` semantics under cost + latency stress.

**Scope.**
- Test repo fixture with N (initially 3, parameterizable) scripted prompts aimed at overlapping file sets.
- Harness driver that runs the same fixture under each of:
  1. **N sessions coordinated (our system).** Parallel `claude -p` invocations with `CLAUDE_COORD=1`.
  2. **N sessions sequential, no coordination.** Back-to-back, coordination off.
  3. **1 session, all prompts bundled.** Single prompt concatenating all.
  4. **1 session, prompts in sequence.** One at a time.
- Metrics per run: total tokens (scraped from transcript), wall-clock, git-diff-against-expected, correctness pass/fail, task-delegation counters (opened/completed/failed).
- Output: `phase7-results.json` + `phase7-report.md`.
- Manual regression checklist derived from the 23 stress-test scenarios in `04`.
- **Real-Claude semantic verification of both Mediator and Validator (Phase 4 carry-forward / Decision 1.1):** Phase 4 unit tests use mock claude binary; Phase 7 integration harness exercises both agents against the real `claude -p` to confirm verdict accuracy on synthetic SAFE/MINOR/CRITICAL drifts and Mediator advice/surgical_fix/lockdown decisions.
- **Cost-guard tunable formalization (Phase 4 carry-forward / Decision 1.2):** measure real-Claude cost + latency distribution under stress; formalize `mediator_min_seconds_between_invocations` and `mediator_max_invocations_per_hour` config schema with measurement-driven defaults.
- **Auto-reset race condition fix (Phase 4 carry-forward / Decision 1.4):** Phase 7 stress check on `critical_check.sh` parse-fail counter logic under concurrent multi-session corruption-recovery scenarios.
- **F-016 / F-017 resolution:** Phase 7 integration harness drives real `claude -p` processes outside bats's parallel-execution timing pressure; the watchdog hook-latency timing test (F-017) and `coord wait` SIGINT runtime test (F-016) get definitive resolution here.

**Done when.**
- Harness runs clean end-to-end in CI or a scripted `make bench`.
- `phase7-report.md` shows the comparison with enough detail to evaluate abandonment conditions (cost multiple, correctness regressions).
- Mediator + Validator real-Claude semantic verification: ≥90% verdict accuracy on a curated SAFE/MINOR/CRITICAL test corpus.
- Cost guard tunables shipped with measurement-driven defaults and `coord health` validation bounds.

**Risks.** Claude outputs vary run-to-run; metrics need statistical framing (min/median/max across N=5 runs per config), not single-run numbers.

**Mediator thread note.** The Mediator is NOT a standalone phase. Its scope expands across Phases 2 (flag infrastructure), 3 (full agent hook + skill), 4 (validator-pattern mirror — fully shipped at T4.04 with `lib/validator_spawn.sh` mirroring `lib/mediator_spawn.sh`; CRITICAL escalation via critical_drift pending entry consumed by existing Mediator pipeline per PR-PHASE4-03), 5 (cycle detection), and 6 (task-graph oversight). Phase 7 exercises the full assembly.

### Phase summary table

| Phase | Name | Locks | Read-set | Watchdog | Validator agent | Wait queue | Tasks | Mediator |
|---|---|---|---|---|---|---|---|---|
| 0 | Scaffolding | — | — | — | — | — | — | — |
| 1 | Stale-read warn | — | ✓ | — | text | — | — | stub (corrupt) |
| 2 | Write lock | ✓ | ✓ | Stop-based | text | basic wait | — | flag file |
| 3 | Watchdog + Mediator | ✓ | ✓ | ✓ | text | basic | — | ✓ |
| 4 | Validator agent | ✓ | ✓ | ✓ | ✓ | basic | — | ✓ |
| 5 | Wait queue | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ |
| 6 | Tasks + self-tasks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 7 | Test harness | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## Section 6 — Testing Strategy

### 6.1 Unit tests (per component)

Framework: `bats` (v1.10+). Location: `.coord/tests/unit/<component>.bats`. Every library module in `lib/` and every hook in `hooks/` has at minimum 3 tests: happy path, edge case, failure mode.

Examples:
- `atomic_write.bats`: concurrent writes serialize; interrupted write leaves valid file; flock timeout produces expected exit code.
- `hash.bats`: identical content → identical hash; >10MB → SKIPPED_LARGE; missing file → exit 1.
- `watchdog.bats`: PID alive + threshold exceeded → suspicion; PID absent + 2 voters → eviction; legitimate slow session not evicted.

### 6.2 Integration tests (hook + state file interaction)

Location: `.coord/tests/integration/<scenario>.bats`. Each test:
1. Spawns a clean `.coord/`.
2. Feeds canned stdin JSON to a hook.
3. Asserts on stdout JSON shape (jq queries) + post-hook state of sessions.json.

Coverage: every hook × every code path in its matcher (deny / allow / mediator-flag / fail-open).

### 6.3 Simulation harness (deterministic timing control)

Location: `.coord/tests/sim/`. A driver written in Bash that:
- Spawns multiple subshells simulating sessions.
- Controls timing via explicit `sleep` and fd-based barriers.
- Asserts invariants:
  - No two sessions hold the same lock simultaneously.
  - Every PENDING task eventually terminates in one of COMPLETED/FAILED/CONFLICT/SKIPPED.
  - sessions.json is always valid JSON (parseable by jq).
  - read_sets never exceed `read_set_cap_per_session`.

Seed scenarios from `04` (all 23 stress-test scenarios).

### 6.4 Four-configuration comparative harness (Phase 7 deliverable)

Described fully in §5 Phase 7. Summary:
- Fixture: small repo with 3 prompts that require overlapping edits.
- Runs each of 4 configurations N times (default 5).
- Reports per-metric distribution.
- Feeds the user's abandonment condition: "is coord cost ≥10× uncoordinated cost?" is a binary output.

### 6.5 Manual test checklist

`phase-ship.md` (template for each phase). Items: "install on fresh VM," "two-session stale-read," "concurrent write," "SIGKILL a session," "corrupt sessions.json," "formatter mid-turn." Human signs off per phase before merging.

### 6.6 Regression scenarios from Phase 1 stress tests

Each of the 23 scenarios in `04` becomes a test. Where the scenario exposed a gap now fixed, the test asserts the fix. Where the scenario was accepted as a residual risk (e.g., Bash-mediated `rm`, Grep-with-content), the test is marked `skip` with a note to the stress-test doc reference. No silent regressions.

---

## Section 7 — Risk Register & Mitigations

Risks the Phase 3 executor can control:

| # | Risk | Likelihood | Impact | Mitigation | Detection |
|---|---|---|---|---|---|
| R1 | macOS Bash 3.2 lacks features used by a script | MED | HIGH | Decision 2.2: 3.2-compat style; install-time bash version check refuses <3.2 | `install.sh` version probe + shellcheck lint with `--shell=bash` --severity=error |
| R2 | `jq` version difference across package managers | LOW | MED | Use `jq` features present since 1.6; pin minimum version in installer | Installer runs `jq --version` and refuses <1.6 |
| R3 | `flock` not present on exotic Unix | LOW | BLOCKING | Installer refuses if `flock` missing; `future-work/FUTURE_WORK_windows_native_support.md` covers the Unix-fringe case | `install.sh` dep check |
| R4 | `flock` on NFS/iCloud/Dropbox silently fails | MED | HIGH | Installer detects via `mount` parsing and refuses; docs | Mount parse + smoke test write-read |
| R5 | sessions.json corruption (half-write, bug) | MED | MED | Mediator flag + reset (Decision 2.6, 2.15); temp+rename invariant | Parse error in any hook triggers Mediator |
| R6 | PID recycling evicts live session | LOW | HIGH | Decision 2.19 PID+lstart + consensus on PID-absent, not age | `watchdog.sh` test |
| R7 | Legit slow-reasoning session evicted | MED | HIGH | Same as R6 + last_activity refresh on any tool call | Scenario 6 regression test |
| R8 | Subagent fork-bomb | LOW | HIGH | Decision 2.17 agent_type filter; agent hook early-exit on agent_type | `session_start.sh` test |
| R9 | Task delegation damages files via misclassified complexity | MED | HIGH | Complexity is `[BEST-EFFORT]`; validator re-checks at apply time with `affected_lines` cap; outcome includes diff; opener sees diff | Task outcome + diff in notifications |
| R10 | Anchor ambiguity (Scenario 7) | MED | HIGH | Required `window_lines` + `window_hash`; non-unique → CONFLICT | `coord task-open` refuses ambiguous anchors |
| R11 | sessions.json grows unbounded | MED | MED | `read_set_cap_per_session: 200` with drop-oldest; archive to history on session end | `coord health` reports size |
| R12 | Git HEAD switch invalidates read-sets (Scenario 22) | MED | MED | Decision 2.22 HEAD tracking + invalidation notification | `user_prompt_submit.sh` + `pre_tool_use_any.sh` check |
| R13 | Claude ignores `additionalContext` notification | MED | MED | Safety-critical paths use `permissionDecision: "deny"`, not just context | Phase 1 scenario 15 + unit test |
| R14 | False-positive stale-read from formatter | HIGH | LOW | Validator subagent absorbs (Phase 4); text warning in earlier phases | Phase 4 formatter regression test |
| R15 | CLAUDE.md rule misinterpreted by Claude | MED | LOW-MED | Every rule tagged HOOK-ENFORCED or BEST-EFFORT; BEST-EFFORT rules not load-bearing | Grep on CLAUDE.md for untagged rules |
| R16 | Orphan task (opener crashed before receiving outcome) | MED | MED | Watchdog cleans up opener's session; task outcome archived to history; other sessions can inspect via `coord tasks` | Watchdog eviction cascade |
| R17 | Task chain cycle spanning multiple files (Scenario 10) | LOW | MED | `task_graph` DFS cycle detection on every `coord task-open`; Mediator breaks cycles at deadlock | `coord task-open` DFS + Mediator in Phase 5 |
| R18 | Lock deadlock (wait_queue depth exceeds threshold) | LOW | MED | Mediator intervenes at wait_queue depth ≥ 5 or any waiting_since older than `wait_max_seconds` | Mediator rule in Phase 5 |
| R19 | Notification to closed session lost | MED | LOW | TTL on notifications (default 24h); archived on session close | `sessions_history` notification audit |
| R20 | SessionEnd not firing on SIGHUP/terminal close (Scenario 9) | MED | MED | Watchdog picks up within 20 min; threshold tunable | Watchdog regression test |
| R21 | `coord wait` process leaked after Claude moves on | LOW | LOW | `coord wait` has `--timeout` default (30 min); self-exits | CLI test |
| R22 | Validator agent hook spuriously times out (60s) | LOW | MED | Validator default verdict on timeout = MINOR; logged | Phase 4 timeout test |
| R23 | Mediator itself errors in a loop | LOW | HIGH | First Mediator failure → session-local `mediator_enabled: false` + user-visible warning; `coord mediate --retry` to re-enable | Hook failure counter |

External risks (not engineering; observation-only):

| E1 | Claude Code ships native multi-session coordination | — | Abandonment trigger | Documented in PLANNING_INSTRUCTIONS.md; Phase 7 report watches for it |
| E2 | Claude Code changes hook contract | MED over months | HIGH | Phase 0 verification captures current contract; script_version field enables compatibility gating |
| E3 | Cost multiple vs uncoordinated > 10× | LOW | Abandonment trigger | Phase 7 explicit measurement |
| E4 | Output quality regresses despite correctness | LOW | Abandonment trigger | Phase 7 final-repo-diff comparison |

---

## Section 8 — Open Items

Items the planner honestly could not resolve and that must be decided before or during specific phases.

**OI-1: Agent-hook invocation semantics for subagent sessions.**
Phase 1 `03` §10 flagged "does `SessionStart(agent_type=X)` fire before `SubagentStart`, or instead, or both?" as UNVERIFIED. This affects the fork-bomb guard (Decision 2.17).
- **When it must be decided:** before Phase 0 ship gate.
- **How to decide:** run experiment #5 from `03` §21. Capture observed ordering; document in `phase0-verification.md`; adjust `session_start.sh` early-return logic accordingly.

**OI-2: Whether `coord wait` is a separate process or piggy-backs on Claude's Bash tool timeout.**
`coord wait` is a blocking Bash call from Claude's perspective. Default Bash timeout matters. If Bash tool has its own timeout that cuts off `coord wait`, we need a shorter internal timeout.
- **When:** resolved by **Phase 0 Experiment #9** (see §5 Phase 0 scope); result captured in `phase0-verification.md`.
- **How:** Experiment #9 measures Claude Code's default Bash tool cutoff directly. Set default `wait_max_seconds` to a safe value below that ceiling (rough expectation: Bash tool default commonly ~10 min, so `wait_max_seconds` default capped accordingly). If Experiment #9 reveals a shorter cutoff than the plan's 1800s default, lower the default and record the change via `plan-revisions.md`.

**OI-3: Whether Mediator may modify state outside `.coord/`.**
Default: no. But a resolution might require writing back a file (e.g., reverting a known-corrupt source file using git). Current plan says Mediator is restricted to `.coord/`.
- **When:** before Phase 3 ship gate.
- **How:** default stands. If user later wants broader remediation, create new future-work doc for "Mediator scope expansion."

**OI-4: Whether to redact or hash `prompt` text in the session record.**
Phase 1 `07` §13 noted prompt text may contain secrets. Current plan stores `prompt_id` (a hash), not the prompt itself, in sessions.json. But `user_prompt_submit.sh` does cache the prompt in `.coord/sessions/<id>.env` for the validator subagent to reference.
- **When:** before Phase 4 ship gate.
- **How:** before shipping validator subagent, either redact known-sensitive patterns (e.g., `sk-[A-Za-z0-9]+`) in the cached prompt, or decide it's the user's responsibility. Planner recommends lightweight regex-redaction of common secret patterns with a loud warning in the installer.

**OI-5: Whether to track Grep-with-content as a "read."**
Currently NO (Decision 2.18). May revisit based on Phase 7 observation of how often grep-with-content feeds into subsequent edits.
- **When:** after Phase 7 measurements. Not a v1 blocker.

**OI-6: Default `task_delegation` toggle.**
Currently `true` (Decision 2.12). Phase 1 research recommended `false` until users validate the feature.
- **When:** before Phase 6 ship gate. After Phase 4 or 5 usage data suggests whether defaults should flip.
- **How:** if two or more Phase 7 runs show task delegation produces TASK_FAILED or TASK_CONFLICT >10% of the time, flip default to `false`.

This list is short by design. If an item not on this list is unclear during implementation, escalate via `plan-revisions.md`.

---

## Section 9 — Glossary

- **Additional context (`additionalContext`)** — a string field in `hookSpecificOutput` that is appended to Claude's context before the current turn continues. How notifications and warnings are delivered.
- **Activity log** — `.coord/events.jsonl`; append-only JSON-lines stream of every coordination-relevant event.
- **Agent-type hook** — a Claude Code hook handler that spawns a short-lived subagent with tool access (default 60s timeout). Used for Mediator and validation subagent.
- **Anchor** — textual reference to a region in a file within a delegated task (search string + context + line-window-hash) used to locate the region at apply time without fragile line numbers.
- **Anomaly vote** — record in `sessions.json` where a session suspects another of being crashed, with evidence. Two distinct voters with PID-absent/recycled evidence constitute consensus.
- **ACTIVE / IDLE_ALIVE / IDLE_CLOSED** — three session states. ACTIVE = working on a prompt. IDLE_ALIVE = registered, no current prompt. IDLE_CLOSED = process gone (set by watchdog or SessionEnd).
- **Atomic write** — pattern: acquire `flock`, read current state, transform, write to temp file, rename over target. POSIX rename is atomic.
- **Bash 3.2-compat** — shell scripts that work on macOS's default Bash 3.2; no associative arrays, no `${var,,}`, no `readarray`.
- **Chain depth** — number of delegation hops from the opener of the original task to the current task. Capped at 3.
- **CLAUDE_COORD** — environment variable that, when set to `1`, opts a session into coordination.
- **Command-type hook** — the common shell-script hook form; a script invoked with stdin JSON, stdout JSON influences behavior.
- **Complexity classification** — Claude's SIMPLE / MODERATE / COMPLEX judgment for a proposed change; guides delegation decision. `[BEST-EFFORT]`.
- **Consensus** — two distinct participating sessions independently observing the same anomaly with PID-absent/recycled evidence before eviction proceeds.
- **`coord` CLI** — operator + Claude-usable command-line tool at `.coord/bin/coord`.
- **Coordinated session / participant** — session started with `CLAUDE_COORD=1` and successfully registered in `sessions.json`.
- **Event** — a single JSON object appended to `events.jsonl` representing one observable happening.
- **Flag file** — a sentinel file (e.g., `.coord/mediator/pending.json`) whose presence triggers an agent-hook to do work.
- **`flock`** — POSIX file-locking command-line tool and syscall used for the atomic-write primitive.
- **Git HEAD snapshot** — record of `git rev-parse HEAD` at session registration or prompt submit; tracked to detect branch switches that invalidate read-sets wholesale.
- **Lock (file lock, write lock)** — record in `sessions.locks[<file>]` indicating one session has exclusive claim to a file's edits until release.
- **Mediator** — agent-type hook + skill that diagnoses and remediates coordination anomalies. New in this plan.
- **Notification** — entry in `sessions.notifications[<session_id>]` delivered at the next relevant hook via `additionalContext`.
- **Non-participant session** — a Claude Code session without `CLAUDE_COORD=1`; not registered, not coordinated. Documented limitation.
- **Passive wait** — session waits for a file lock to release via the `coord wait <file>` CLI which polls at 30s → 60s → 120s cadences up to `wait_max_seconds`.
- **Peer watchdog** — distributed cleanup mechanism: every participating session opportunistically checks for crashed peers via PID+lstart.
- **`permissionDecision`** — a field in `hookSpecificOutput` with values `allow|deny|ask|defer`. `"deny"` is the hard-enforcement primitive.
- **Read-set** — per-session record of every file read with content hash, used for stale-read detection.
- **Self-delegation** — a session records a reminder (self-task) to return to a locked file later; injected as a reminder on subsequent hooks.
- **Session registration** — the act of adding the current session to `sessions.sessions` at SessionStart when `CLAUDE_COORD=1` is set.
- **Stale read** — a file's content hash at write-validation time differs from the hash when the session read it; the action was going to be built on an outdated snapshot.
- **Task (delegated)** — instruction left by session X on the lock of a file held by session Y; Y applies it at lock-release and reports outcome.
- **Task graph** — adjacency-list record of who delegated to whom; used for cycle detection.
- **Task state machine** — PENDING → ACCEPTED → IN_PROGRESS → { COMPLETED | FAILED | CONFLICT | SKIPPED }.
- **Validation subagent** — agent-type hook that classifies a stale-read diff as SAFE / MINOR / CRITICAL.
- **Wait queue** — `sessions.wait_queue[<file>]` list of sessions passively waiting for a file to unlock; each entry carries a wake-file path the lock-release hook touches to wake the CLI.
- **`[HOOK-ENFORCED]` / `[BEST-EFFORT]`** — tags in CLAUDE.md Part B indicating whether a rule is enforced deterministically by a hook or depends on Claude's cooperation.

---

## Section 10 — How to Use This Plan

### 10.1 Read order for Phase 3

1. This plan from Section 1 through Section 10 in order.
2. `CLAUDE.md` Part A — rules for the builder.
3. Spot-read the relevant Phase 1 documents when a decision cites them (especially `03` for hook capabilities, `04` for stress scenarios, `07` for engineering considerations).
4. `CLAUDE.md` Part B runtime rules as needed — think of them as the spec for the behavior the hooks must make true.
5. Future-work files — **do not read**. They are out of scope. Read only when someone asks "what about daemon / Go / SQLite / Windows / multi-user / remote / team / UI?"

*Most Phase 1 research documents now live under `archive/` (e.g., `archive/03-claude-code-capabilities-research.md`); consult them per §10.3's decision tree rather than routinely.*

### 10.2 Phase-start checklist

Before beginning any phase:
- [ ] Read the phase's scope, out-of-scope, and done-when criteria in Section 5.
- [ ] Confirm all prior phases' done-when criteria were met (ship gates).
- [ ] Review applicable risks in Section 7.
- [ ] Create a phase branch: `phase-N/<short-description>`.
- [ ] Open a phase notebook in `.coord/phase-N-notes.md` (local, not committed).
- [ ] Read `IMPLEMENTATION_LOG.md` end-to-end — understand what's been done, what's mid-flight, what the last completed step was.
- [ ] Read `FINDINGS.md` — note any OPEN entries relevant to the incoming phase's scope.
- [ ] Create a new section in `IMPLEMENTATION_LOG.md` for the new phase with Status: NOT_STARTED → IN_PROGRESS when starting.

### 10.3 Ambiguity resolution decision tree

When you face a question this plan does not answer clearly, resolve in this order:

1. **User direction** (`archive/PLANNING_INSTRUCTIONS.md` → "User's Finalized Direction" or `archive/09-user-answers.md`).
2. **IMPLEMENTATION_PLAN.md** (this file, especially Section 2 decisions).
3. **CLAUDE.md runtime rules** (Part B).
4. **Phase 1 research** (`01` through `10`; start with `03` for capabilities, `04` for stress tests, `08` for phasing).
5. **Planner judgment by analogy** to existing decisions in Section 2.
6. **Escalate to user** — write the question to `plan-revisions.md` under a new entry, flag in session output, do not silently guess.

### 10.4 When this plan turns out to be wrong

If during construction a Section 2 decision proves untenable:

- Do NOT silently deviate.
- **First:** record the observation in `FINDINGS.md` with status OPEN and a link to the current `IMPLEMENTATION_LOG.md` task.
- **Then:** if the observation requires a plan change, open `plan-revisions.md` (create if missing); record decision number, observation, proposed change, rationale. Reference the FINDINGS entry.
- Surface it in your session output.
- Wait for acknowledgment before proceeding. If the user is unreachable and the phase is blocked, pause the phase and document the blocker in IMPLEMENTATION_LOG.md.

### 10.5 End-of-phase sign-off

At the end of every phase produce `phase-N-signoff.md` (local, not committed) containing:
- **IMPLEMENTATION_LOG reference:** the task ID range this phase covers (e.g., T2.01 through T2.14); confirm every entry is checked.
- **Ship gate checklist** from the plan's §5, each with evidence pointer (bats test path, manual test log, verification experiment file).
- **FINDINGS dispositions:** every finding raised in this phase is OPEN / RESOLVED / WONTFIX / DEFERRED, with a one-line status.
- **Risks realized:** which R-numbers from §7 fired; mitigation effectiveness.
- **New risks discovered:** added to §7 via `plan-revisions.md`.
- **Open questions for next phase.**

---

*End of IMPLEMENTATION_PLAN.md*

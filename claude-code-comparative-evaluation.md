# Claude Code Comparative Evaluation of Parallel Sessions

**Date:** 2026-05-06
**Subject repo:** `parallel-sessions` (formerly `session-synthesis` / `gearcode`) at `/Users/suy/Desktop/ModuleX/repositories/parallel-sessions`
**Reference doc:** `CLAUDE_CODE_FEATURES_DOC.md` (1977 lines, behavior captured early 2026)
**Method:** Per-feature mapping + multi-dimensional evaluation, with deep dives on `/add-dir`, `/advisor`, `/agents`, `/branch`, `/sandbox`, `/tasks`.
**Voice:** Senior-engineering review. No marketing. No defensive framing.

---

## 0. Executive precis (read this first)

Parallel Sessions is a **filesystem-coordination layer** for repositories where one or more AI coding agents (Claude Code, OpenAI Codex) run concurrently. Its mechanism is deliberately small: shell hooks + `flock` + `jq` + an audit log, sitting underneath each agent's tool surface. Its single defensible value proposition is preventing two concurrent AI sessions from clobbering the same file in the same repo, with a deterministic deny banner, FIFO wait queues, crash recovery, stale-read drift classification, cycle detection, and cross-session task delegation.

The Claude Code features document covers Claude's surface-level UX (slash commands, agents, sandbox, plan mode, agent teams, Remote Control, MCP, plugins, etc.) and includes one feature — **git worktrees** — that is the natural sibling of what parallel-sessions does. Worktrees give *filesystem isolation* (each session has its own working tree, so concurrent writes are impossible by construction). Parallel-sessions gives *single-tree coordination* (concurrent writes to the same tree are intercepted, not isolated).

Most parallel-sessions features have no overlap with Claude Code at all, because Claude Code never claimed to coordinate concurrent agents on a shared filesystem — it just gave you `--worktree` and walked away. Where overlap does exist, it is mostly with worktrees (a *prevention* approach versus parallel-sessions' *arbitration* approach), and the two answer different questions.

Bottom line: **parallel-sessions is genuinely useful for a narrow but real use case** — multiple AI sessions, single tree, optionally cross-vendor (Claude + Codex). For the use case it targets, no Claude Code native feature provides equivalent functionality. Within Anthropic's roadmap signal (Desktop creates a worktree per session by default), Anthropic clearly thinks the right solution is *isolation*, not *arbitration* — and the user should be aware of that bet. Detailed reasoning follows.

---

## 1. Mental model alignment

| Concept | Claude Code | Parallel Sessions |
|---|---|---|
| Unit of work | Session (token-budgeted agentic loop) | Session (registered row in `.coord/sessions.json`) |
| Cross-session interaction | None at the file level; `--worktree` isolates trees | Shared `.coord/` arbitrates writes to the same tree |
| Shared persistence | `~/.claude/projects/<project>/...` (per machine) | `<repo>/.coord/` (per repo) |
| Concurrency model | "Run two terminals" with no awareness of each other | Hooks intercept Read/Write/Edit/`apply_patch` |
| Cross-vendor support | Claude only | Claude Code + OpenAI Codex (mixed-mode supported and tested) |

The two systems are operating at different abstraction layers. Claude Code's docs model concurrency as "use worktrees if you want parallel work"; parallel-sessions models concurrency as "arbitrate writes to one tree." That asymmetry is the throughline of every comparison below.

---

## 2. Per-feature comparative analysis

I cover every feature/section in `CLAUDE_CODE_FEATURES_DOC.md`. The six priority commands receive a dedicated deep-dive in §3; in this section they appear in summary form to maintain document coherence and refer to §3 for detail.

The structure for each feature is:

> **Mapping** | **Mechanism comparison (when both exist)** | **Multi-dimensional evaluation** | **Verdict**

Dimensions abbreviated: **TS** = technical soundness, **SP** = speed/latency, **PF** = performance/scalability, **SU** = sustainability, **VP** = value proposition, **UX** = user experience.

### 2.1 Project & Memory Management

#### `/init` — Bootstrap CLAUDE.md
- **Mapping:** No corresponding feature in parallel-sessions. Parallel-sessions has its own `bin/parallels-init` that creates `.coord/` infrastructure, not a CLAUDE.md analogue.
- **Verdict:** Not in parallel-sessions' problem space. `parallels-init` is a coordination-state initializer; `/init` is a project-onboarding generator. Different concerns.

#### `/memory` — View/manage memory files
- **Mapping:** No overlap. Parallel-sessions writes its own audit log (`.coord/events.jsonl`) and state (`sessions.json`), but these are operational data for coordination, not session-context memory.
- **Verdict:** Not in scope.

#### `/add-dir` — Grant access to additional directories
- **Mapping:** Surface-level keyword overlap (both are about "extra directories"), but mechanism is unrelated. See §3.1 for the deep dive.
- **Verdict:** Largely orthogonal. See §3.1.

### 2.2 Context Management

#### `/context`, `/compact`, `/clear`, `/rewind`
- **Mapping:** None of these exist in parallel-sessions. They manage the in-session token budget; parallel-sessions does not interact with the conversation context window. Notably, `coord_log_event` is **non-blocking** by default (backgrounded with disown) so coordination overhead does not consume context.
- **Indirect interaction:** `/rewind` reverts files Claude edited via `Edit`/`Write` tools. If a parallel-sessions lock was acquired during the rewound turn, rewind does NOT release the coord lock — the lock is only released by `PostToolUse`/`Stop`/`SessionEnd` or by Watchdog timeout. **This is a real gap**: a `/rewind` could create a stale lock that another session can't acquire until the lease expires. Parallel-sessions has no awareness of the rewind event because Claude Code does not surface it as a hook.
- **Verdict:** Not overlapping but worth flagging — parallel-sessions has a blind spot on Claude's checkpoint/rewind mechanism.

### 2.3 Planning & Strategy

#### `/plan` — Read-only research/planning mode
- **Mapping:** No equivalent. Parallel-sessions does not modify the agent's tool surface or planning behavior; it only intercepts file-touching tools at the hook layer.
- **Verdict:** Out of scope.

#### `/ultraplan` — Cloud-based planning
- **Mapping:** No equivalent. Parallel-sessions is local-only by design (multi-machine deferred to v2, see §6 in `STATE_OF_SYSTEM.md`).
- **Verdict:** Out of scope.

#### `/advisor` — Executor + advisor model pairing
- **Mapping:** Surface-level overlap (both have "two-Claude" architectures), but the role is different. See §3.2.
- **Verdict:** Largely orthogonal. See §3.2.

### 2.4 Agents & Delegation

#### `/agents` — Subagent management
- **Mapping:** Conceptual overlap (both involve specialized Claude instances), but subagents are about isolating *context*, while parallel-sessions' Mediator/Validator/Task-Processor agents arbitrate *coordination state*. See §3.3.
- **Verdict:** See §3.3. Not redundant; complementary.

#### `/branch` — Fork the conversation
- **Mapping:** Surface-level keyword overlap ("branch") but the operation is entirely different. See §3.4.
- **Verdict:** Not overlapping. See §3.4.

#### `/tasks` — Task list / background tasks
- **Mapping:** Significant conceptual overlap with parallel-sessions' `coord task-open` / `coord self-delegate` / `task_processor.sh`. See §3.5.
- **Verdict:** Genuinely overlapping. See §3.5.

### 2.5 Conversation Tools

#### `/btw`, `/recap`, `/resume`, `/rename`
- **Mapping:** No equivalents. These are conversation-UX features inside the Claude session; parallel-sessions touches none of them.
- **One indirect connection:** `/resume` restores a previous Claude session. Parallel-sessions' `SessionStart` hook detects `source: resume` and runs an idempotent refresh path that re-validates locks against the new PID/lstart, marking orphaned locks via `RESUME_ORPHAN_LOCK_DETECTED` events. So parallel-sessions does correctly handle Claude's resume mechanic — it just doesn't replicate it.
- **Verdict:** Not overlapping.

### 2.6 Model & Performance

#### `/model`, `/effort`, `/fast`
- **Mapping:** No equivalent. Parallel-sessions does not select models for the user's session.
- **Indirect:** Parallel-sessions DOES select models for its own internal spawns (`COORD_MEDIATOR_MODEL=claude-haiku-4-5-20251001`, `COORD_VALIDATOR_MODEL=claude-haiku-4-5-20251001`). These are background analysis subprocesses, not user-facing.
- **Verdict:** Not overlapping.

### 2.7 Permissions & Safety

#### `/permissions` — Allow/deny rules
- **Mapping:** Parallel-sessions emits `permissionDecision: "deny"` from exactly two sites in the Claude codebase (the `pre_tool_use_write.sh` lock-held branch and `lib/lockdown.sh::coord_lockdown_emit_deny`), and is treated as a **policy hook** by Claude Code's permission engine. So parallel-sessions piggybacks on `/permissions`' enforcement infrastructure rather than competing with it.
- **Mechanism:** Claude's `/permissions` is a syntax-based ruleset. Parallel-sessions adds *dynamic, state-aware* deny conditions — "deny if another session holds the lock" — which `/permissions` cannot express because it's stateless across sessions.
- **Multi-dimensional evaluation:**
  - **TS:** Claude > parallel-sessions for static rules; parallel-sessions > Claude for cross-session arbitration. They do different things.
  - **VP:** Complementary — they should be combined, not compared.
- **Verdict:** Complementary. Parallel-sessions effectively extends `/permissions` with cross-session state.

#### `/sandbox` — OS-level isolation
- **Mapping:** Surface-level keyword overlap (both involve "isolation"), but `/sandbox` is OS-level (Seatbelt/bubblewrap), parallel-sessions is application-level (hooks). See §3.6.
- **Verdict:** Not overlapping. See §3.6.

#### `/hooks` — Hook configurations
- **Mapping:** Parallel-sessions IS a hook user, not a hook system. It registers 8 hooks in `.claude/settings.local.json` (and 7 in `.codex/hooks.json`) and uses them as its only interception mechanism. `/hooks` is Claude's discovery UI for what hooks are active; running `/hooks` in a coord-installed Claude session lists the 8 coord hook scripts.
- **Mechanism:** Claude's `/hooks` is the platform; parallel-sessions is one of many possible hook applications. Without `/hooks` (and the underlying SessionStart/PreToolUse/PostToolUse/Stop/SessionEnd events), parallel-sessions could not exist.
- **Verdict:** Hard dependency, not overlap. Parallel-sessions is a hook *consumer* that demonstrates the depth of what's possible with the hook API. If anything, it's a good answer to the "what would you ever build with hooks?" question.

### 2.8 Tools & Extensions

#### `/mcp` — MCP server management
- **Mapping:** No equivalent. Parallel-sessions does not expose itself as an MCP server, and does not consume MCP servers.
- **Could it have?** A natural design alternative would be a `coord-mcp` server exposing `acquire_lock`, `release_lock`, `wait_for_release`, `task_open` as MCP tools. The current design instead uses Claude's hook events to intercept native tools (`Edit`, `Write`, `apply_patch`). The hook approach is **strictly more transparent**: every existing tool is automatically arbitrated; with MCP, only tools that explicitly call `coord-mcp` would be coordinated. This is a sound design choice given the goal of zero-config arbitration over native tool calls.
- **Verdict:** Not overlapping. The MCP-server-not-built decision is correct given the design goal.

#### `/skills` — Skill list
- **Mapping:** No equivalent. Parallel-sessions ships no skills. The repo *contains* `.agents/skills/` but those are Claude-development skills the maintainer used for building parallel-sessions, not skills parallel-sessions exposes to its users.
- **Verdict:** Not overlapping.

#### `/plugin` — Plugin management
- **Mapping:** No equivalent. Parallel-sessions is not a plugin. It installs via a Bash installer that writes `.claude/settings.local.json` directly. **A plugin would be a more natural distribution channel**: the entire `.coord/` infrastructure could ship as a plugin that bundles hooks + the `coord` CLI + reference docs. The Bash installer pre-dates plugin maturity; this is an opportunity for repositioning, not a flaw.
- **Verdict:** Not overlapping but **a recommendation**: distribute parallel-sessions as a Claude Code plugin (and a Codex equivalent if/when Codex's plugin story matures). It would dramatically reduce setup friction (`/plugin install parallel-sessions` vs. `git clone && bash src/install.sh`).

#### `/reload-plugins`
- **Mapping:** Not applicable until parallel-sessions is itself a plugin.
- **Verdict:** Out of scope.

### 2.9 Code Review & Automation

#### `/diff` — View changes
- **Mapping:** No equivalent. Parallel-sessions' Validator pipeline does compute hash-diffs across reads to classify drift, but it does not display those to the user as a diff view.
- **Verdict:** Not overlapping.

#### `/autofix-pr`
- **Mapping:** No equivalent. Parallel-sessions does not interact with PRs.
- **Verdict:** Out of scope.

### 2.10 Visual & Display

#### `/color`, `/theme`, `/tui`, `/focus`
- **Mapping:** None. Parallel-sessions has no UI; it is text in the deny banner channel.
- **One thoughtful note:** `/color` is documented as "useful for visually distinguishing parallel sessions in tmux/iTerm panes — you can tell at a glance which window you're typing in." This is the closest the Claude Code feature doc gets to acknowledging that users do run multiple sessions on the same repo. Parallel-sessions targets exactly that workflow and does not need its own visual marker — it leverages whatever the user already does.
- **Verdict:** Not overlapping.

### 2.11 Output & Cross-Surface

#### `/copy`, `/export`, `/desktop`, `/mobile`, `/teleport`
- **Mapping:** None. Parallel-sessions is local-CLI only; it does not interact with Desktop/mobile/teleport surfaces.
- **Significant note:** `/desktop` mentions: *"The desktop app creates a worktree for every new session automatically — every session starts isolated."* This is Anthropic's tell that they consider worktree-per-session the right answer for parallel work. Parallel-sessions' bet is the opposite: if users run parallel sessions on the same tree (and many do, for compatibility with their workflow), arbitrate them. Both are defensible; Anthropic's chosen direction is isolation.
- **Verdict:** Not overlapping but strategically informative.

### 2.12 Integrations

#### `/chrome`, `/ide`, `/install-github-app`, `/install-slack-app`
- **Mapping:** None. Parallel-sessions is filesystem-bound; these are external integrations.
- **Verdict:** Out of scope.

### 2.13 Remote Work

#### `/remote-control`, `/remote-env`
- **Mapping:** None. Parallel-sessions is single-machine only (per `STATE_OF_SYSTEM.md` §3 and OQ6 binding).
- **Verdict:** Out of scope.

### 2.14 Account & Auth

#### `/login`, `/logout`
- **Mapping:** None. Parallel-sessions has no auth.
- **Verdict:** Out of scope.

### 2.15 System & Diagnostics

#### `/doctor`, `/status`, `/config`, `/privacy-settings`, `/extra-usage`
- **Mapping:**
  - `/status` ↔ `coord status` — both are read-only status displays. `coord status` shows: schema_version, active sessions (with agent kind), locks, wait_queues, self_tasks, validation queue, read_sets summary, events.jsonl line count. Different scope (Claude Code session vs. coord state), no semantic conflict.
  - `/doctor` ↔ `coord health` — both check infrastructure. `coord health` checks deps (jq/flock/shasum/ps/git/perl), config bounds (lock_ttl_seconds ≥ 300, watchdog timing ordering, wait_max < 600), and stray digit-named files at repo root (an F-003/F-012 anti-pattern). Different scope.
  - `/config` — no equivalent. Parallel-sessions edits `.coord/config.json` directly (no UI), with bounded validation in `coord health`.
- **Verdict:** Both `coord status` and `coord health` are *coord-state* commands that complement (do not replace) Claude's `/status` and `/doctor`. They are appropriate, well-scoped, and not redundant with Claude's surface-level diagnostics. **TS / VP: appropriate.**

### 2.16 Help & Discovery

#### `/help`, `/powerup`, `/release-notes`, `/feedback`, `/stickers`
- **Mapping:** None. Parallel-sessions has no in-product help system; users discover via README and `docs/codex-quickstart.md`.
- **Recommendation:** If repackaged as a plugin (see §2.8), it would gain `/help` integration for free and possibly contribute a `/powerup` lesson on parallel sessions.
- **Verdict:** Out of scope.

### 2.17 Setup

#### `/terminal-setup`, `/keybindings`
- **Mapping:** None. Parallel-sessions has no terminal/keybinding configuration.
- **Verdict:** Out of scope.

### 2.18 Session Control

#### `/exit`
- **Mapping:** Indirect. When Claude Code exits cleanly, the `SessionEnd` hook fires; parallel-sessions' `session_end.sh` releases all locks held by the session and flushes events. Parallel-sessions' Watchdog handles the case where Claude crashes (no `SessionEnd` fires).
- **Verdict:** Hard dependency / cooperation, not overlap. Parallel-sessions correctly handles both clean and dirty exits.

---

## 3. Deep Dive: High-Overlap Claude Code Commands

The six commands the user flagged for deep examination. This section is the analytical core.

### 3.1 `/add-dir` (vs. parallel-sessions' coordination scope)

#### What `/add-dir` does
`/add-dir <path>` extends Claude's allowed file-access set at runtime. Subject to standard `Read`/`Edit` permission rules, Claude can now read and edit files in the new directory without restarting. By default, configuration files in the added directory (`CLAUDE.md`, `.claude/agents/`, `.claude/rules/`) are **not** loaded; the env var `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` opts into loading them. When sandboxing is active, the new directory is integrated into OS-level allow-paths.

Use case: monorepo work, sibling repo edits, shared utility directories.

#### What parallel-sessions provides in this space
**Nothing directly equivalent.** Parallel-sessions resolves `.coord/` via `lib/folder_resolver.sh::coord_resolve_root`, which walks up from `$PWD` until it finds an existing `.coord/`. This is a *single-tree* model: one `.coord/` arbitrates all writes inside its subtree, period.

There is no mechanism to extend coordination across multiple directory roots. If Claude reads from a dir outside the coord tree (via `/add-dir`) and writes to a file inside the coord tree, the inside-tree write IS arbitrated; the outside-tree read is not snapshotted in `read_sets`. Concretely:

- `pre_tool_use_read.sh` calls `coord_resolve_root` once. If the read target's path doesn't fall inside that root's subtree, it's untracked.
- `pre_tool_use_write.sh` similarly resolves once. Cross-root writes by the same Claude session are not coordinated together.

This is a real behavioral edge case in `/add-dir` workflows: stale-read drift detection only protects reads of files inside the same coord root as the write target. The user has correctly classified this kind of scenario as out-of-scope (single-tree single-machine v1).

#### Mechanism comparison
| Aspect | `/add-dir` | parallel-sessions |
|---|---|---|
| Purpose | Extend Claude's allowed-paths | Arbitrate writes within one tree |
| Scope | Per Claude session | Per `.coord/` root (one per repo) |
| Multi-root support | Yes (multiple `--add-dir`) | No |
| Subagent visibility | Not propagated | Not propagated (different reason: hooks are session-scoped) |
| Config file loading | Opt-in via env var | N/A |

#### Multi-dimensional evaluation
- **TS:** Both are sound for their stated purpose. `/add-dir` is a small, well-scoped extension to Claude's path allowlist. Parallel-sessions is a large arbitration layer that happens to be single-tree. Neither *fails* its stated purpose; they don't even compete on the same axis.
- **SP / PF:** `/add-dir` is essentially free (config update). Parallel-sessions hooks add ~50–100 ms per Read/Write/Edit (well below Anthropic's 2 s ceiling per the `STATE_OF_SYSTEM.md` §A.6 reference); not directly comparable.
- **SU:** `/add-dir` is platform-supported and will track Claude Code releases. Parallel-sessions is third-party and must track the hook contract.
- **VP:** `/add-dir` is monorepo ergonomics. Parallel-sessions is concurrent-write safety. Different problems, different audiences.
- **UX:** `/add-dir` is one-line; parallel-sessions requires installing the layer once.

#### Edge cases & failure modes
- `/add-dir` failure: forgetting the env var, leading to no CLAUDE.md context for the added directory.
- Parallel-sessions failure: cross-root work in `/add-dir` workflows leaves writes outside the coord root unarbitrated — silent data race possible if two coord-installed sessions both `/add-dir`-ed the same external directory.

#### Verdict
**Largely orthogonal.** Parallel-sessions does not compete with `/add-dir`. The one real interaction (cross-root writes from `/add-dir` sessions) is not a parallel-sessions feature, it's a known limitation. Honest call: parallel-sessions could not reasonably be expected to coordinate across roots without major architectural changes (one `.coord/` per repo is foundational), and the user has correctly scoped multi-root out.

If parallel-sessions wanted to fully cover this case, it would need a "coord-aware" path resolver that walks up to the *nearest* `.coord/` root and a way to opt a multi-root operation into the single-coord arbitration — possibly via a `coord acquire <abs-path>` CLI extension. Phase 7+1 candidate at best.

---

### 3.2 `/advisor` (vs. parallel-sessions' Mediator / Validator / Task-Processor)

#### What `/advisor` does
`/advisor` enables the Advisor Strategy: a fast/cheap executor model (Sonnet/Haiku) drives the work; a stronger advisor model (Opus) is consulted via a `advisor_20260301` tool inside a single API request. The advisor sees the entire conversation, returns ~400–700 tokens of guidance, never calls tools, never produces user-facing output. It runs *inside one inference loop*, persists in shared session context, and conflicts with empirical results are surfaced rather than silently overridden.

Anthropic benchmarks: Sonnet 4.6 + Opus advisor scored 74.8% on SWE-bench Multilingual vs. 72.1% for Sonnet alone, at 11.9% lower cost.

#### What parallel-sessions provides in this space

Parallel-sessions has **three out-of-band Claude spawn sites**, each conceptually similar to "consult a stronger model" but architecturally very different:

1. **Mediator** (`lib/mediator_spawn.sh`): subprocess `claude -p --model claude-haiku-4-5-20251001` invoked when (a) a CRITICAL drift is detected, (b) a lock-dependency cycle is found, (c) a session is suspected dead by the Watchdog, (d) operator runs `coord mediate --reason ...`. The Mediator analyzes the incident (pending entry + sessions snapshot + events tail + verdict history), writes a verdict JSON to `.coord/mediator/verdict/<ts>.json` with action_type ∈ {advice, surgical_fix, lockdown}, and exits. Bounded by `COORD_MEDIATOR_TIMEOUT_SEC=120` and `COORD_MEDIATOR_BUDGET_USD=0.50`. Recursion-guarded (max depth 2). Cost-guarded (12 invocations/hr default).

2. **Validator** (`lib/validator_spawn.sh`): same pattern, classifies stale-read drift as SAFE/MINOR/CRITICAL after a 3-stage pipeline (cache → pre-filter → agent spawn). Capped at 120/hr.

3. **Task Processor** (`lib/task_processor.sh`): processes deferred edits handed off by `coord task-open`. Real-claude branch added in Phase 7. Reserved-but-unset rate cap.

In `mock` mode (default; CI + daily dev), all three sites use mock binaries (deterministic + free). In `semi`/`realistic`, real `claude -p` is used — `realistic` for pre-release smoke only, `semi` for weekly stakes-coverage runs.

#### Mechanism comparison
| Aspect | `/advisor` | parallel-sessions Mediator/Validator/Task-Proc |
|---|---|---|
| Trigger | Inside the executor's inference loop | External event (drift / cycle / dead session / operator) |
| Arch | Two models, one API request | Two processes, two API requests (parent + spawned `claude -p`) |
| Latency | Sub-second (single round-trip) | Tens of seconds (claude startup + analysis ~15–30 s) |
| Output | 400–700 tokens of guidance, no tools | Structured verdict JSON; spawn may use Bash + Read |
| Recursion | Capped at `max_uses` per request | Capped at depth 2 by env-var marker |
| Conflict surfacing | Built-in: empirical results vs. advisor flagged | Verdict-apply is best-effort; conflicts surface via events |
| Direct cost | Counted at advisor model rate within one request | Per-spawn `total_cost_usd` from the JSON output |
| Operator visibility | None for advisor calls (it's internal) | Full audit: `MEDIATOR_SPAWN_STARTED/COMPLETED/FAILED/RATE_LIMITED` events |

The architectures answer different questions. `/advisor` answers *"can I get better quality from one inference?"*. Parallel-sessions' spawns answer *"can I escalate a coordination decision out-of-band when the deterministic logic gives up?"*.

#### Multi-dimensional evaluation
- **TS:**
  - `/advisor`: cleaner — one API request, no orchestration code, conflict-surfaced. Anthropic-built and benchmarked.
  - Parallel-sessions Mediator: solid for what it does (recursion-guarded, cost-guarded, kind-agnostic dispatch, fail-open), but the architecture is heavier — it spawns a whole new `claude -p` and waits up to 120 s.
  - **Edge:** Parallel-sessions wins for its specific niche (cross-session coordination decisions). `/advisor` wins for in-task quality-cost tradeoffs.
- **SP:** `/advisor` is sub-second. Mediator typically 15–30 s. Different cost-of-decision regimes; `/advisor` is much faster.
- **PF:** Mediator's cost guards (sliding 1-hr window, 12/hr default for mediator, 120/hr for validator) are a real feature for runaway protection. `/advisor` has `max_uses` per request. Both are fine.
- **SU:**
  - `/advisor` is platform-supported, with API-stability guarantees.
  - Parallel-sessions' spawn architecture depends on `claude -p`'s output JSON shape (fields like `is_error`, `session_id`, `total_cost_usd`, `result`). The `MEDIATOR_REFERENCE.md` correctly notes that `claude -p` exits 0 regardless of `is_error` — so the integration is brittle to changes in that shape.
  - Worse: `/advisor` is a 2026 feature; parallel-sessions Mediator is a 2025 design that pre-dates `/advisor`. **In hindsight, the Mediator could be implemented as a `claude --advisor` invocation rather than a subprocess spawn**, getting cost-guard for free and reducing the wall-clock latency. This is a plausible Phase 8 refactor direction.
- **VP:**
  - `/advisor`: cost-quality optimization for any task.
  - Parallel-sessions Mediator: out-of-band coordination decisions for multi-session pathologies. **Niche but defensible.**
- **UX:** `/advisor` is set-and-forget. Mediator is invisible until something breaks; when it does, it produces an audit-rich verdict file.

#### Edge cases & failure modes
- `/advisor`: pricing surprises if `max_uses` not set; weak fit for single-turn Q&A; relies on Opus 4.6 specifically.
- Parallel-sessions Mediator: D-1 contract — Codex-only operators MUST install `claude` because Mediator is `claude -p`. Documented well in README "D-1: Codex-only users still need claude" but is a real cross-vendor friction. Cost guards default to 12/hr for mediator — a busy lock-contention storm could starve on rate limit.

#### Verdict
**Largely orthogonal.** Parallel-sessions' Mediator and `/advisor` solve different problems with different architectures. The Mediator is *meaningfully different* from `/advisor` — neither better nor worse, just for a different role. **However**, when `/advisor` matures, parallel-sessions should consider whether the Mediator's spawn architecture can be reimplemented atop `/advisor` semantics (or a similar in-process construct) to reduce latency and lifecycle complexity. This is a future refactor opportunity, not a current redundancy.

---

### 3.3 `/agents` (vs. parallel-sessions' subagent filter and out-of-band agents)

#### What `/agents` does
Manages subagent definitions: Markdown files with YAML frontmatter, each with isolated context, custom system prompt, configurable tools, optional worktree isolation, optional background mode. Resolution order is `--agents` flag → `.claude/agents/` (project) → `~/.claude/agents/` (user) → plugin agents. Built-in subagents include Explore (Haiku, read-only), Plan (read-only research), General-purpose (full tools). Subagents cannot spawn subagents (recursion prevention).

Critical for cross-reference: `isolation: worktree` in subagent frontmatter spawns the agent into a temporary git worktree that's auto-cleaned if no changes are made. This is the Anthropic-recommended way to do parallel agent work without filesystem races.

#### What parallel-sessions provides in this space

Two distinct things:

1. **Subagent filter** (`lib/subagent_filter.sh`): When a Claude subagent (Task tool) fires `PreToolUse`, the input has `agent_type` populated (per F-006 / Decision 2.17). Parallel-sessions detects this and **exits 0 silently**, emitting a `SUBAGENT_ACTIVITY_SKIPPED` event for observability. The deliberate design choice is *do NOT track subagent writes in coord state*. Rationale (per `STATE_OF_SYSTEM.md` "Subagent (Task tool) races stay invisible by design"): subagents share the parent's `session_id` but write through the same tool surface, so trying to track them as separate locking participants would conflict with the parent's lock.

2. **Internal agents that ARE NOT Claude subagents**: Mediator/Validator/Task-Processor are spawned as `claude -p` subprocesses with `CLAUDE_COORD=0` to disable coord hooks for the spawned process. They are out-of-process, not in-conversation subagents. They cannot use the Task tool, do not appear in `/agents`, and are not user-managed.

#### Mechanism comparison
| Aspect | `/agents` (Claude subagents) | parallel-sessions agents |
|---|---|---|
| Discovery | YAML frontmatter in `.claude/agents/` | Hardcoded spawn points; no user-defined |
| Context | Isolated context window | Out-of-process; no shared context |
| Tools | Configurable per-subagent | Fixed: Bash + Read for Mediator/Validator |
| Spawn | `Task` tool, in-process | `claude -p`, out-of-process |
| Lifecycle | Returns summary to parent | Writes verdict file; parent reads it |
| Worktree isolation | `isolation: worktree` per agent | N/A (parallel-sessions itself defends against shared-tree races) |
| Recursion | Hard cap: subagents can't spawn subagents | Hard cap: depth 2 (mediator) or 1 (validator) |

There is real conceptual overlap on the "spawn a Claude with a focused job" axis. The difference is that `/agents` keeps the spawn inside the conversation (context isolation as the first-class feature), while parallel-sessions spawns a separate process for state-arbitration jobs (no shared context with the user's session is intentional — the Mediator must not see the user's prompts to avoid prompt-injection of its verdicts).

The **`isolation: worktree`** subagent feature is the most important overlap point here, and it does not favor parallel-sessions:

- Subagent with `isolation: worktree` runs in a fresh git worktree. The user can spawn three of them in one session, each gets a clean workspace, no overwrite risk, auto-cleanup if no changes.
- Parallel-sessions arbitrates concurrent writes on a *single* tree. Two Claude sessions on the same tree get coord arbitration; a Claude session running three `isolation: worktree` subagents gets *Anthropic's* arbitration (none needed — they're isolated trees).

For a user comfortable with worktrees, the subagent + worktree combination is **strictly simpler** than installing parallel-sessions. Parallel-sessions' value emerges only when worktrees are *not* an option (e.g., shared filesystem semantics depend on a single tree, or the user is running Claude *and* Codex against the same tree, which subagent worktrees don't address because they're Claude-only).

#### Multi-dimensional evaluation
- **TS:**
  - `/agents`: well-designed, with frontmatter validation, plugin-scoped restrictions (`hooks`, `mcpServers`, `permissionMode` disabled in plugins for security), context isolation as a first-class feature.
  - Parallel-sessions filter: small, correct, fail-open. Internal agents: solid but with the spawn-shape brittleness noted in §3.2.
  - **Tie at the level of correctness; / agents is a richer surface.**
- **SP:** `/agents` task-tool spawn is fast (no extra binary). Parallel-sessions out-of-process spawns are slow (10-30s startup).
- **PF:** `/agents` scales with the number of subagents in the conversation. Parallel-sessions adds a fixed per-write hook latency regardless of subagent count.
- **SU:** `/agents` is the recommended Anthropic abstraction; will continue to evolve with the platform. Parallel-sessions' subagent-filter is a defensive measure that depends on the `agent_type` field staying populated as Anthropic intends. **Risk:** if Anthropic changes how subagents identify themselves on hook events, the filter could fail open or closed.
- **VP:**
  - `/agents`: encapsulate logic in a separate context window; specialize behavior; restrict tools.
  - Parallel-sessions: defensively avoid double-counting subagent writes against parent locks; spawn out-of-band coordination decisions.
  - **`/agents` has the broader value proposition; parallel-sessions has the narrower defensive one.**
- **UX:** `/agents` is interactive, integrated, has built-in agents. Parallel-sessions' agents are invisible to users (Mediator only triggers on pathologies; Validator only fires on stale reads; Task Processor only at lock release).

#### Edge cases & failure modes
- `/agents`: subagents loading CLAUDE.md again is a context-cost duplication. Plugin restrictions can be confusing.
- Parallel-sessions: subagent-filter F-015 is a known soft-deprecated banner — subagent races are explicitly NOT tracked, which means if a user runs many parallel subagents that all `Edit` the same file, parallel-sessions will not arbitrate them. This is documented as Decision 2.17 carry-forward but is a real limitation of the integration.

#### Verdict
**Meaningfully different and partially redundant.** For a user whose parallelism need is satisfied by `isolation: worktree` subagents (Claude-only, fresh trees, auto-cleanup), parallel-sessions is **redundant and arguably worse** because it requires installation, adds hook latency, and doesn't isolate at the filesystem level. For a user whose parallelism crosses vendor boundaries (Claude + Codex on the same tree), or whose tooling cannot accommodate worktrees, parallel-sessions is **not redundant** — there is no Claude Code feature that equivalently coordinates a Codex session.

The honest framing: **`/agents` + worktrees is the Anthropic-blessed answer; parallel-sessions covers the gaps Anthropic explicitly does not target.** Parallel-sessions wins where Anthropic's offering doesn't apply — primarily mixed-vendor workflows.

---

### 3.4 `/branch` (vs. parallel-sessions' multi-session model)

#### What `/branch` does
Creates a parallel copy of the current conversation at a chosen point. Both branches retain full context up to the fork point, then proceed independently. New session ID for the branch. Different from `--worktree`: `/branch` is a *conversation* fork, not a *filesystem* fork. Filesystem state is shared between branches (last-write-wins on file edits).

Use case: try a refactor two ways, A/B-test prompts on identical state.

#### What parallel-sessions provides in this space
**Nothing equivalent.** Parallel-sessions is concerned with concurrent sessions on a shared tree, but it has no concept of "fork an existing session." Its session model assumes each session has a unique `session_id` provided by the agent platform (Claude Code or Codex) and arbitrates writes between them.

The closest analog is parallel-sessions' implicit assumption that **filesystem state is shared across `/branch`-ed Claude sessions** — which the Claude Code feature doc explicitly flags as a limitation:

> *"Filesystem state is shared — if both branches edit the same file, last-write-wins. Use git worktrees for true filesystem isolation."*

This is exactly the gap parallel-sessions targets: if a user `/branch`-es a Claude session and both branches end up editing the same file, parallel-sessions intercepts the writes and arbitrates them. The user gets a deny banner from one branch when the other holds the lock. Whether parallel-sessions actually works for `/branch` is an open question because:

1. Two branches share a session_id? Or is each branch given a new session_id at branch time? The Claude Code doc says "new branch starts in a separate session ID" — good, parallel-sessions will see them as distinct sessions and lock-arbitrate correctly.
2. The branched session was started from the same parent conversation — does the parent's CLAUDE_COORD inheritance survive the branch? If yes, both branches will run the SessionStart hook (one of them with `source: resume` likely) and register independently in `sessions.json`. If `/branch` does not fire SessionStart, parallel-sessions will not see the second branch and won't track its writes.

This is a testable integration gap. The repo does not have a test for the `/branch` interaction (search of `src/tests` shows no `branch_*.bats`). Worth adding before claiming `/branch` compatibility.

#### Mechanism comparison
| Aspect | `/branch` | parallel-sessions |
|---|---|---|
| Conceptual unit | Conversation | Filesystem session |
| Forking semantics | Duplicate conversation context, new session_id | N/A — only observes per-session writes |
| Filesystem isolation | None (shared by design; user warned) | Arbitration only (no isolation) |
| Token cost | Doubles per branch | Per-session lock state |

#### Multi-dimensional evaluation
- **TS:** `/branch` is sound for its purpose. Parallel-sessions has zero implementation in this area.
- **SP/PF:** N/A — different layers.
- **SU:** `/branch` is platform-supported. Parallel-sessions does not need to track `/branch` semantics directly because each branch will (likely) trigger SessionStart and be tracked; but this is **untested**.
- **VP:** `/branch` is cheap experimentation. Parallel-sessions could be useful here — if both branches edit the same file, parallel-sessions is the only mechanism that prevents lost work (apart from manual git discipline).
- **UX:** `/branch` is one command. Parallel-sessions is invisible until contention.

#### Edge cases & failure modes
- `/branch` failure: filesystem last-write-wins is the documented danger. Parallel-sessions partially mitigates it by intercepting writes — but only if the branched session has CLAUDE_COORD set, fires SessionStart, and registers properly. Untested.
- Parallel-sessions failure: if `/branch` ever shares a `session_id` (current docs say no, but implementations evolve), parallel-sessions would treat both branches as one session and not arbitrate them — the user's CLAUDE.md changes to "rename" sessions would slip through and the user could get a false sense of safety.

#### Verdict
**Not overlapping at the feature level; complementary at the integration level.** Parallel-sessions does not need its own `/branch`. But the doc explicitly identifies the filesystem-race vulnerability of `/branch` as a known limitation, and parallel-sessions is one of the few mechanisms that *could* mitigate it — assuming the branch fires SessionStart cleanly. **Recommendation:** add a `src/tests/integration/branch_filesystem.bats` to verify that two `/branch`-ed Claude sessions both register in `sessions.json` and arbitrate correctly. Until that exists, claims of `/branch` safety should be hedged.

---

### 3.5 `/sandbox` (vs. parallel-sessions' arbitration scope)

#### What `/sandbox` does
Wraps Claude's bash subprocesses in an OS-level sandbox: filesystem isolation via Seatbelt (macOS), bubblewrap (Linux), bubblewrap (WSL2). Default: write access only to working directory + subdirs, read access to entire computer minus deny paths. Network isolation via outbound proxy (TLS not terminated; only client-supplied hostname checked, so domain fronting can bypass). Two modes: auto-allow (sandboxed bash auto-approved; only fallbacks hit normal permissions) and regular permissions (all bash through normal flow).

Critical: `/sandbox` operates at the OS level. **Even if Claude is prompt-injected, OS policy holds.** Restrictions apply to all subprocesses (kubectl, terraform, npm, etc.), not just Claude's tool calls. Doesn't apply to Claude's built-in Read/Edit/Write tools — those use the permission system directly.

#### What parallel-sessions provides in this space
**Nothing equivalent.** Parallel-sessions is *application-level* arbitration via Bash hooks, not OS-level sandboxing. It does not:

- Restrict filesystem access at the kernel layer
- Restrict network access
- Cover non-Claude subprocesses (kubectl, terraform, etc.)
- Defend against prompt injection (a prompt-injected Claude can call `coord_atomic_edit` directly to bypass the lock — though it would have a hard time, since the deny logic is in the hook, not in the tool)

What parallel-sessions DOES do is intercept Claude's `Read/Edit/Write/NotebookEdit` (and Codex's `apply_patch`) at the hook layer, which is *strictly above* the OS layer. It is enforcement in the same sense that a userspace permission system is enforcement: it works because the hook is wired up correctly; if the user disables the hook, it's gone.

There is a subtle but important interaction: **`/sandbox` is the Claude Code feature most likely to break parallel-sessions hooks.** If the sandbox restricts filesystem write access to `<repo>` only, the hooks try to write to `.coord/sessions.json` (which IS in the repo), `.coord/events.jsonl` (also in the repo), and may invoke `flock` on lock files (also in the repo). All of this should be in scope of the default sandbox config. But:

- `coord task-open` and `coord wait` shell out to `flock` and `jq` — if the sandbox blocks any of these binaries (e.g., a pre-approved subset), the hook fails open per CLAUDE.md §A.5 fail-open posture. So the deny is silently downgraded to "allow uncoordinated."
- The Mediator/Validator spawn `claude -p` as a subprocess — if `/sandbox`'s `excludedCommands` doesn't include `claude`, the spawned process inherits the sandbox restrictions. The Mediator is supposed to be able to read `.coord/events.jsonl` and write `.coord/mediator/verdict/<ts>.json`; both should be in scope. Network access is needed (Anthropic API call); `/sandbox`'s domain allowlist must include `api.anthropic.com` or the spawn will fail.

The parallel-sessions docs do not mention `/sandbox` interactions. This is a **real gap** — running parallel-sessions inside `/sandbox` is plausibly a desirable combination (defense in depth) but is untested.

#### Mechanism comparison
| Aspect | `/sandbox` | parallel-sessions |
|---|---|---|
| Layer | OS (Seatbelt/bubblewrap) | Application (hooks) |
| Bypass surface | Domain fronting on TLS-not-terminated proxy; non-sandboxed tools (excludedCommands) | Disabling the hook; CLAUDE_COORD=0 |
| Subprocess coverage | All subprocesses (kubectl, terraform, npm, …) | Only Claude/Codex tool calls |
| Defends against prompt injection | Yes, OS-enforced | No, just deny banner (Claude could ignore semantically) |
| Per-operation overhead | Negligible | ~50–100 ms per Read/Write/Edit |

#### Multi-dimensional evaluation
- **TS:**
  - `/sandbox` is OS-enforced and substantially more robust against adversarial behavior. Documented limitations (TLS-not-terminated proxy, `excludedCommands` escape hatch) are honest.
  - Parallel-sessions is hook-enforced. A prompt-injected agent can ignore deny banners semantically (though the hook itself blocks the tool call before it executes; Claude-as-attacker would have to script around that).
  - **`/sandbox` strictly stronger on adversarial robustness; parallel-sessions strictly stronger on cross-session arbitration.**
- **SP / PF:** `/sandbox` overhead is small. Parallel-sessions' hook overhead is larger but still under 2s.
- **SU:** `/sandbox` is platform-supported and open-source (`@anthropic-ai/sandbox-runtime` on npm). Parallel-sessions is third-party Bash and depends on hook contract stability.
- **VP:**
  - `/sandbox`: reduce permission fatigue + raise security floor. Single-session safety.
  - Parallel-sessions: cross-session arbitration. Multi-session safety.
  - **Different problems — they should be combined for serious workflows.**
- **UX:** `/sandbox` requires understanding OS-level policy (Seatbelt syntax can be painful). Parallel-sessions UX is "install once, see deny banners on contention."

#### Edge cases & failure modes
- `/sandbox`: WSL1 unsupported; macOS native windows in development; some tools (docker, watchman) require `excludedCommands`.
- Parallel-sessions: untested in `/sandbox` mode. The interaction MUST be validated before claiming defense-in-depth use cases.

#### Verdict
**Not overlapping; complementary.** They solve different security problems at different layers. Parallel-sessions is **not redundant** to `/sandbox`. **However**, parallel-sessions is at risk of breaking inside `/sandbox` if subprocess access (jq, flock, claude) is restricted. The repo should add a `src/tests/integration/sandbox_compat.bats` (or document the required sandbox excludedCommands list) to make the combination usable. Without that, the answer to "can I run parallel-sessions inside Claude's /sandbox?" is "probably yes but untested" — which is not good enough for production claims.

---

### 3.6 `/tasks` (vs. parallel-sessions' task-delegation system)

This is the most directly overlapping feature pair in the entire comparison.

#### What `/tasks` does
Shows the session's task list (pending/in-progress/completed), surfaces background-running operations (ultraplan, long-running agents). For complex multi-step work, Claude auto-creates a task list. Tasks have three states + dependencies (a task with unresolved deps can't be claimed). **Tasks survive `/compact`** (stable plan-of-record). For agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`), the task list is **shared across teammates** with file locking on task-claim. Cross-session sharing via `CLAUDE_CODE_TASK_LIST_ID=my-project` (named directory under `~/.claude/tasks/`).

Critical limitation in the docs: *"File locking covers task-claim race conditions, not source-file conflicts. Two teammates editing the same file still overwrite each other."*

#### What parallel-sessions provides in this space

A full task-delegation subsystem:

1. **`coord task-open`** (`src/core/bin/coord` `cmd_task_open`, ~120 lines): persists a task into `locks[<file>].tasks[]` for the lock-holder to process at lock release. Validates: file path required, complexity enum (SIMPLE/MODERATE/COMPLEX), anchor JSON required, instruction required, optional rationale. Cycle prevention via `lib/cycle_detection.sh::coord_cycle_detect_task_graph`. Chain depth limit (`max_task_chain_depth=3` default). Anchor uniqueness check. Toggle-able via `config.json` `task_delegation: false`.

2. **`coord self-delegate`** (`cmd_self_delegate`): records deferred work in `self_tasks[<sid>]`. Reminders fire on every `pre_tool_use_any` (with throttle on `last_reminded_at`); `stop.sh` blocks-once-then-allows when self-tasks are unresolved (with `stop_block_count` mechanic). Lifecycle: OPENED → REMINDED → ARCHIVED (COMPLETED|SKIPPED|stop_second_attempt|session_end).

3. **`task_processor.sh`**: invoked by `post_tool_use_write.sh` AFTER the lock-holder finishes their edit but BEFORE lock deletion. Iterates `locks[<file>].tasks[]` in queue order. For each task: classifies via `affected_lines` overlap check (per-line range intersection); if no overlap, spawns mock-Claude (or real Claude in semi/realistic mode) with the task instruction; persists outcome (which removes the task + appends a `TASK_OUTCOME` notification to `.notifications[<opener>][<file>]`). Mock-Claude binary contract: `COORD_MOCK_CLAUDE_TASK_PATCH` env var or deterministic default JSON.

4. **Wait queue** (`lib/wait_queue.sh`): per-file FIFO; `coord wait <path> --timeout <30..570>` blocks the caller until lock release (or timeout), with sub-100 ms wake-up via fswatch (macOS) / inotifywait (Linux) / 250 ms polling. Cycle-detection trigger on queue depth ≥ 2.

5. **Cycle detection** (`lib/cycle_detection.sh`): bipartite session/file DFS at queue-enqueue time. Cycles trigger Mediator surgical-fix or lockdown.

#### Mechanism comparison

| Aspect | `/tasks` (Claude) | parallel-sessions task system |
|---|---|---|
| Storage | `~/.claude/tasks/` (per project + named) | `<repo>/.coord/sessions.json` (under flock) + `<repo>/.coord/wait_queues/<sanitized>.lock` |
| Survives compact | Yes | N/A — coord state is not in conversation context |
| Cross-session sharing | Yes, with `CLAUDE_CODE_TASK_LIST_ID` | Yes, by virtue of single shared `.coord/sessions.json` |
| Task claiming race protection | File locking on task-claim | Per-file flock + atomic_edit jq filter |
| Source-file conflict protection | **No** (explicitly documented as out-of-scope) | **Yes** (this is the entire point) |
| Cross-vendor (Claude + Codex) | No | Yes |
| Dependency model | Tasks declare deps; pending blocked until resolved | Task graph cycle detection; chain depth cap |
| Wait/wake-up | Polling | fswatch/inotifywait sub-100 ms |
| Manual delegation | Yes (`@`-mention agent, etc.) | `coord task-open --file --complexity --anchor --instruction` |
| Self-deferral | No explicit mechanism | `coord self-delegate` with stop-block-once + reminders |
| Cycle detection | Implicit via dep graph (best-effort) | Bipartite DFS, hard guard |

The Claude `/tasks` system is *project-management for the agent's own work plan*. The parallel-sessions task system is *cross-session work-handoff with anti-conflict guarantees*. The overlap is real (both have task lists, dependencies, file locking on claim) but the **scope of correctness guarantee is fundamentally different**:

- `/tasks` claim-locking prevents two teammates from claiming the same task. **Source files: NOT covered.**
- Parallel-sessions task-delegation prevents two sessions from editing the same source file. **Source files: covered.**

This is the most defensible value proposition parallel-sessions has against any specific Claude Code feature.

#### Multi-dimensional evaluation
- **TS:**
  - `/tasks`: well-integrated with Claude's planning loop, survives compaction, shared across teammates. The known gap (source-file conflicts) is honestly documented.
  - Parallel-sessions tasks: cycle-detected, chain-depth-capped, anchor-uniqueness-validated, lock-holder-driven processing. Well-tested (Phase 6 ship-gate fixtures + cross-agent integration tests covering task delegation).
  - **Both technically sound; parallel-sessions has the stronger correctness guarantee for the source-file-conflict case.**
- **SP:**
  - `/tasks`: instant (no I/O beyond claim file).
  - Parallel-sessions: enqueue is one atomic_edit (~50 ms); wake-up is sub-100 ms; task processing depends on Mock vs. real Claude (10-30s for real).
  - **`/tasks` is faster for routine tracking; parallel-sessions adds latency only when actual contention occurs.**
- **PF:**
  - `/tasks` scales with task count.
  - Parallel-sessions scales with concurrent session count and per-file contention; cycle detection is O(sessions × files) bipartite DFS.
  - Both fine at single-developer scale.
- **SU:**
  - `/tasks` is platform-supported.
  - Parallel-sessions tasks are Bash, with comprehensive bats tests (43 total task-related across `coord_task_open.bats`, `cycle_detection_task_graph.bats`, `phase6_e2e.bats`, etc.).
  - **`/tasks` will gain features and stability passively; parallel-sessions is at the maintainer's discretion.**
- **VP:**
  - `/tasks` is great for tracking what an agent (or agent team) is *doing*.
  - Parallel-sessions tasks are about *handing off* work between sessions when one session can't do it because another holds a lock.
  - **Different value props that could coexist productively.**
- **UX:**
  - `/tasks` is integrated into the Claude UI; users see and manipulate tasks naturally.
  - Parallel-sessions tasks are CLI-driven (`coord task-open ...`), less ergonomic but auditable.
  - **`/tasks` clearly wins on UX.**

#### Edge cases & failure modes
- `/tasks`: claim-locking covers task-claim races but not source-file races (documented). Tasks can lag — teammates fail to mark complete, blocking dependents.
- Parallel-sessions: task-graph cycle detection at `coord task-open` time is a hard guard; chain depth at depth-3 default may be too tight for legitimate workflows; anchor-uniqueness check rejects duplicate anchors which can confuse users.

#### Verdict
**Genuinely overlapping; both are useful and address different failure modes.** Parallel-sessions' task system is **meaningfully different and arguably better** for the specific concern of *cross-session source-file safety*, which Claude `/tasks` does not address. For *agent work-tracking*, `/tasks` is clearly the better integrated experience.

The two could coexist: a user could use `/tasks` for their own planning and `coord task-open` for cross-session delegation when contention occurs. Parallel-sessions' task system is **not redundant** to `/tasks` but **does duplicate** some lifecycle machinery (states, dependencies, cycle detection). A long-term direction would be for parallel-sessions to *plug into* `/tasks` rather than maintain a parallel structure — emit task records via the Claude task API when available, with the source-file-conflict invariant as parallel-sessions' value-add.

---

## 4. Cross-cutting analysis

### 4.1 Where parallel-sessions adds genuine, non-redundant value

1. **Single-tree multi-session arbitration with deterministic deny banner.** The lock + 3-options banner (delegate / self-delegate / wait) at `pre_tool_use_write.sh` line 458 is the system's most defensible value. No Claude Code feature does this. `/branch` *creates* the conditions where this matters; `/agents` with `isolation: worktree` *avoids* the conditions but isn't always available.
2. **Cross-vendor coordination (Claude + Codex).** Documented and tested via 45 cross-agent integration tests. Codex sessions are not addressable by Claude Code features, period — `/agents` can't spawn a Codex; `/sandbox` doesn't know about Codex; `/tasks` doesn't share with Codex. Parallel-sessions is the only mechanism that arbitrates a Claude `Edit` against a Codex `apply_patch` on the same file.
3. **Stale-read drift classification (SAFE/MINOR/CRITICAL).** Claude Code does not detect "the file you read earlier has changed since you read it." Parallel-sessions' Validator pipeline (cache → pre-filter → spawn) does, with fail-soft fallback to Phase 1 warning. This is a feature Anthropic could add (and might) but does not currently provide.
4. **Lock-dependency cycle detection at queue-enqueue time.** Bipartite session/file DFS triggered when wait_queue depth ≥ 2. Catches A-waits-on-B-waits-on-A patterns deterministically. No Claude Code analog.
5. **Crash recovery via Watchdog 3-signal probe.** PID liveness + last-activity + lock-refresh age, all probed; on consensus "dead," Mediator decides (evict / surgical-fix / lockdown). No Claude Code analog.
6. **Non-blocking event audit log.** `events.jsonl` with `coord_log_event ... &` keeps coordination audit trail separate from session context. Different layer than `/diff`/`/recap`.

### 4.2 Where parallel-sessions duplicates Claude Code without meaningful improvement

1. **`coord status` / `coord health`.** Useful for coord state, but the Claude Code `/status` and `/doctor` cover the same UX role for their respective scope. Not redundant since the scopes differ, but the UX (CLI subcommands vs. slash commands) is dated.
2. **Task list machinery (states, dependencies, cycle detection).** Parallel-sessions reimplements machinery similar to `/tasks` for its task-handoff use case. The underlying state-machine and cycle-prevention logic is good, but the lifecycle metadata (PENDING/IN_PROGRESS/COMPLETED, blockedBy, etc.) is similar enough that long-term reuse via Claude's task API would reduce maintenance.
3. **Manual operator escalation (`coord mediate --reason`).** A user-facing "escalate this" CLI is similar in spirit to `/feedback` (operator-to-platform escalation), though scoped to coord state.

### 4.3 Where parallel-sessions has gaps relative to Claude Code

1. **No `/rewind` integration.** A `/rewind` after a coord lock acquire leaves the lock orphaned until Watchdog timeout. This is a real bug class.
2. **No `/branch` integration testing.** Parallel-sessions assumes branched sessions get unique session_ids via SessionStart, but no test verifies this end-to-end.
3. **No `/sandbox` integration testing.** Running parallel-sessions inside a Claude `/sandbox` is plausibly desirable (defense in depth) but untested.
4. **No plugin distribution.** Bash installer is functional but pre-dates the Claude Code plugin ecosystem. `/plugin install parallel-sessions` would be ergonomic.
5. **No multi-machine support.** Explicitly out of scope for v1 (per OQ6 / `STATE_OF_SYSTEM.md` §3); deferred to v2.
6. **Mediator architecture pre-dates `/advisor`.** The out-of-process spawn model could plausibly be replaced with an `/advisor`-style in-request consult for many of its use cases, reducing latency and complexity.

### 4.4 Discipline and engineering quality (pure observation)

- **Test surface is unusually thorough**: 837 unit tests + 122 integration (45 cross-agent) + 24 ship-gate fixtures + 19-guard architectural invariant. Phase-by-phase signoff documents (`phase-N-signoff.md`) capture decisions and findings (`FINDINGS.md` + `STATE_OF_SYSTEM.md`).
- **Bash 3.2 compatibility is a deliberate constraint** (macOS default Bash). This forces disciplined choices (no associative arrays, no readarray, no `${var,,}`) that limit the codebase but also prevent platform-version drift.
- **Fail-open posture is consistently applied** (CLAUDE.md §A.5): hooks exit 0 in error paths, never propagate non-zero rc to the agent. This is the right bias for a coordination layer (a broken coord layer should not break the user's ability to write code).
- **2-location deny invariant** for Claude (`pre_tool_use_write.sh` lock branch + `lockdown.sh::coord_lockdown_emit_deny`) and 4-location for Codex is enforced by a bats invariant test. This is a real architectural property; it makes the "where could a deny come from?" question answerable in seconds.

These signals indicate a mature codebase. The discipline is in service of a narrow but well-defined goal.

---

## 5. Final verdicts and recommendations

### 5.1 Per-dimension overall winner across the project

| Dimension | Winner | Reasoning |
|---|---|---|
| Technical soundness | Tie (both robust within scope) | Claude is platform-supported and broad; parallel-sessions is narrow-and-deep |
| Speed/latency | Claude Code | Sub-second slash commands vs. 10–30 s Mediator spawns; in-conversation features avoid IPC overhead |
| Performance/scalability | Claude Code | Cloud sessions, agent teams, etc. scale beyond single machine; parallel-sessions stays single-machine by design |
| Sustainability | Claude Code | Vendor-supported; parallel-sessions depends on hook contract and Bash 3.2 — long-term maintenance is the maintainer's responsibility |
| Value proposition strength | Mixed | Claude wins for general agentic coding; parallel-sessions wins for the specific multi-session-on-one-tree case (especially cross-vendor) |
| User experience | Claude Code | Integrated UI, slash commands, task tracking; parallel-sessions is CLI + invisible-until-contention |

### 5.2 Priority-commands findings summary

| Command | Verdict for parallel-sessions counterpart |
|---|---|
| `/add-dir` | Largely orthogonal; parallel-sessions has a known limitation (single coord root) but no claim to compete |
| `/advisor` | Largely orthogonal; Mediator architecture pre-dates `/advisor` and could be modernized atop it |
| `/agents` | Meaningfully different and partially redundant — `/agents` + `isolation: worktree` is the Anthropic-blessed answer to parallel work; parallel-sessions covers gaps that Anthropic doesn't target (mixed-vendor) |
| `/branch` | Not overlapping at the feature level; parallel-sessions COULD mitigate `/branch`'s filesystem-race vulnerability but has no integration test for it |
| `/sandbox` | Not overlapping; complementary; running parallel-sessions inside `/sandbox` is plausibly desirable but untested |
| `/tasks` | Genuinely overlapping; parallel-sessions task system is meaningfully different and BETTER for source-file conflict prevention; `/tasks` is better for everything else |

### 5.3 The headline question

> **Is parallel-sessions genuinely useful, and does it justify its existence given Claude Code's existing capabilities?**

**Yes — for a narrow but real use case.** Specifically:

1. Multiple AI coding sessions (Claude *and/or* Codex) running against the **same git tree** simultaneously, where worktrees are not viable (vendor mix, tooling that can't see worktrees, etc.).
2. Where the failure mode being prevented is *concurrent edits to the same file by independent agents*, and the user values deterministic deny over post-hoc git resolution.

For this niche, **no Claude Code native feature provides equivalent functionality**. The closest analog is `/agents` with `isolation: worktree`, which only works for Anthropic-spawned subagents inside a single Claude Code session — it does not address two top-level Claude sessions or a Claude session paired with a Codex session.

For users *outside* this niche, parallel-sessions is **largely redundant or worse than the Anthropic-blessed alternative**:
- A user running one Claude session at a time → no value.
- A user running parallel work via subagents → `/agents isolation: worktree` is simpler, cleaner, and Anthropic-supported.
- A user running parallel work via Claude Desktop → Desktop creates worktrees automatically.
- A user running multiple top-level Claude sessions on different worktrees → no contention; parallel-sessions adds latency for no gain.

The **strategic question for the project** is whether the niche use case (especially the cross-vendor case) is the right thing to optimize for. The README's positioning ("multi-session coordination for AI coding agents (Claude Code + OpenAI Codex)") frames this honestly: the cross-vendor capability is the strongest defensible differentiator, not the Claude-only multi-session case (which Anthropic is actively working to obviate via Desktop's auto-worktree default).

### 5.4 Concrete recommendations

**Keep:**
- The lock + deny banner + three-options arbitration core (this is the value).
- The cross-agent (Claude + Codex) integration (this is the differentiator).
- The Bash 3.2 + flock + jq + audit-log architecture (small, debuggable, no daemons).
- The Watchdog crash-recovery mechanism (genuinely novel for this domain).
- The fail-open posture (correct discipline for a coordination layer).
- The thorough test surface.

**Reconsider / sharpen:**
- **The Claude-only multi-session positioning.** Anthropic's direction (Desktop auto-worktree, `/agents isolation: worktree`) makes this the weak case. Lead with the cross-vendor case and the cross-tool defensiveness. The README does this reasonably, but the in-tree docs lean Claude-centric (the Codex adapter is documented as an addition to the Claude system rather than a co-equal value prop).
- **The Mediator's out-of-process spawn architecture.** When `/advisor` matures, evaluate whether the Mediator's role can be served by an in-request advisor consult (one API call) instead of a `claude -p` subprocess (two API calls, 10–30 s wall-clock). This is a Phase 8 candidate.
- **Distribution.** Ship as a Claude Code plugin. `/plugin install parallel-sessions` is dramatically more ergonomic than `git clone && bash src/install.sh`. Carry the Codex side via the Codex equivalent when its plugin story matures.

**Drop or repackage:**
- **`coord status` and `coord health` as separate CLIs.** They are appropriate per-component, but exposed from the user's terminal as separate commands rather than slash-integrated, the UX is dated. Consider exposing them via plugin slash-commands (`/coord-status`, `/coord-health`) for parity with the Claude Code surface.
- **Phase-N signoff and FINDINGS docs in the published repo.** They are valuable for the maintainer but bloat the public repo. Move to a dev-only branch or `docs/development-history/` (some of this has been done).

**Sharpen / fill gaps:**
- **`/rewind` integration.** Decide explicitly: should a rewound session release locks acquired during the rewound turn? This is currently undefined behavior. Document it; ideally fix it.
- **`/branch` integration test.** Verify two `/branch`-ed sessions register independently and arbitrate correctly.
- **`/sandbox` compatibility test.** Document the required `excludedCommands` / `allowWrite` settings, and add a smoke test.
- **`/tasks` integration story.** When Claude's task API stabilizes, evaluate emitting parallel-sessions task records via that API instead of (or in addition to) `locks[<file>].tasks[]`.

**Differentiate further:**
- **Multi-machine coordination (v2).** This is the FUTURE_WORK direction the maintainer flagged. It's also the one place where parallel-sessions could plausibly leapfrog Anthropic — Claude Code's Remote Control and cloud sessions don't address shared-tree coordination across machines. If this can be done well (NFS-aware locking, distributed event log, etc.), it's a moat.
- **Agent-team coordination integration.** When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is more mature, the source-file-conflict problem (which parallel-sessions solves and the doc explicitly says agent teams *don't*) is a concrete pitch.

---

## 6. Closing note

This evaluation was written assuming the maintainer wants honest signal, not validation. The system is well-engineered and does what it claims. The strategic question is not "is the implementation good?" (it is) but "is the use case important enough relative to Anthropic's direction?" Anthropic is betting on isolation (worktrees, agent isolation, cloud envs); parallel-sessions is betting on arbitration. Both are defensible. The cross-vendor angle is the strongest defensible point because Anthropic will not unify with Codex. If parallel-sessions doubles down on cross-vendor and multi-machine (v2), it occupies a space Claude Code is unlikely to take. If it stays Claude-centric, it will continue to be a useful niche but increasingly boxed in by Anthropic's worktree-first posture.

End of evaluation.

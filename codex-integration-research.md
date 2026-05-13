# Codex CLI Integration — Pre-Integration Research Report

Branch: `research/codex-integration`
Date: 2026-05-02
Scope: exhaustive map of every Claude-Code coupling in this repository, every site that must change to add a Codex CLI adapter, and every site that must change to share state between a Claude Code session and a Codex session running side-by-side against the same `.coord/`.
**No code changes were made.** This report is the deliverable.

---

## A. Orientation (one paragraph)

`parallel-sessions` is a Bash 3.2 + `jq` + `flock` coordination layer that wires Claude Code hooks (`SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`) into the Claude Code config file `.claude/settings.local.json` so that multiple Claude Code sessions running against the same repository can (a) lock files at write time, (b) detect stale-read drift via a 3-stage cache→pre-filter→Validator-agent pipeline, (c) surface a three-options deny banner (delegate / self-delegate / wait) when a write would clobber another session, (d) recover from crashed sessions via a 3-signal Watchdog (PID liveness + last-activity + lock-refresh age), and (e) escalate corrupt-state / cycle / CRITICAL drift to a Mediator subprocess (`claude -p`) whose verdict is one of advice / surgical_fix / lockdown. State lives in `.coord/sessions.json` (atomic temp+rename + `flock`) and `.coord/events.jsonl` (append-only). No daemon, no server, no UI. Single-developer / single-machine scope. README.md confirms.

---

## B. Inventory

### Repo root
| Path | One-liner |
|---|---|
| `README.md` | Public README — ties the project to "Claude Code" by name. |
| `CONTRIBUTING.md` | Contributor docs — Claude Code-specific terminology. |
| `LICENSE` | MIT. |
| `package.json` | npm bin → `bin/parallel-sessions` (Node wrapper). Keywords include `claude-code`. |
| `.gitignore` | Ignores `.coord/`, `.claude/`, `docs/`, `archive/`, `future-work/`, ship-gate fixtures. |
| `bin/parallel-sessions` | Node wrapper for `init` / `status` / `test`; hard-shells to `bash src/install.sh`. |
| `phase-*-signoff.md` | Gitignored phase artifacts; not shipped. |
| `IMPLEMENTATION_LOG.md`, `FINDINGS.md`, `STATE_OF_SYSTEM.md` | Gitignored construction artifacts. |
| `scripts/stress_semi.sh`, `scripts/stress_realistic.sh` | Manual stress harness for `COORD_TEST_MODE=semi|realistic`. |
| `docs/development-history/CLAUDE.md`, `IMPLEMENTATION_PLAN.md`, `plan-revisions.md`, `phase-3-implementation-prompt.md` | Internal-only (gitignored); NOT loaded at runtime. |

### `src/hooks/` — Claude Code hook entry points
| Path | One-liner |
|---|---|
| `session_start.sh` | SessionStart hook; branches on `input.source` ∈ `startup|resume|clear|compact`; writes `.coord/sessions/<sid>.active` marker; banner via `hookSpecificOutput.additionalContext`. |
| `session_end.sh` | SessionEnd hook; releases held locks (defensive fallback if Stop didn't run); marks IDLE_CLOSED; cleans read snapshots. |
| `stop.sh` | Stop hook; releases held locks; Phase 6 self-task block-once-then-allow path emits `decision: "block"` (the only `decision: block`, distinct from the 2-location `permissionDecision: deny`). |
| `user_prompt_submit.sh` | UserPromptSubmit hook; hashes prompt → prompt_id; supersedes read-set entries; HEAD-drift detection. |
| `pre_tool_use_any.sh` | Cross-cutting PreToolUse hook (matcher `*`); notification consumer; HEAD recheck; mediator-pending consumer; ambient watchdog scan; verdict-file consumer; F-015 subagent-`coord wait` banner. |
| `pre_tool_use_read.sh` | PreToolUse for `Read` tool (matcher `Read`); records sha256 into `read_sets[$sid].reads[]`; writes `.coord/read_snapshots/<sid>/<hash>.txt` snapshot. |
| `pre_tool_use_write.sh` | PreToolUse for `Write|Edit|NotebookEdit`; runs validator pipeline on stale reads; lock check + acquire; one of two `permissionDecision: deny` sites (lock-held branch). |
| `post_tool_use_write.sh` | PostToolUse for `Write|Edit|NotebookEdit`; releases lock; runs Phase 6 task processor on `locks[].tasks[]`; notifies waiters via `notify_waiters`. |

### `src/lib/`
| Path | One-liner |
|---|---|
| `atomic_write.sh` | `coord_atomic_edit` flock+jq+temp-rename; corrupt-state recovery + critical-bypass counter; legacy `pending.json` migration. |
| `log_event.sh` | `coord_log_event` (async backgrounded append) + `coord_log_event_sync`; `coord_now_iso8601`. |
| `subagent_filter.sh` | Reads Claude Code's `agent_type` field; emits `SUBAGENT_ACTIVITY_SKIPPED` and exits 0 silently. **Claude-Code-specific.** |
| `participant.sh` | `coord_is_participant` — checks `.coord/sessions/<sid>.active` marker. |
| `lockdown.sh` | Mediator system-wide pause; one of two `permissionDecision: deny` sites; reads/writes `.coord/mediator/lockdown.json`. |
| `mediator_pending.sh` | JSONL pending-queue producer + consumer + GC; handles `corrupt_state`, `flock_timeout`, `stale_active`, `pid_recycled`, `critical_drift`, `cycle_detected`, `manual` kinds. |
| `mediator_spawn.sh` | Spawns `claude -p` with 3-section prompt (Identity / Constraints / Incident Context); recursion guard via `CLAUDE_CODE_MEDIATOR` env. |
| `validator_spawn.sh` | Spawns `claude -p` Validator; recursion guard via `CLAUDE_CODE_VALIDATOR`. |
| `task_processor.sh` | Phase 6 lock-release task processor; mock-default OR `claude -p` (semi/realistic mode); `CLAUDE_CODE_TASK_PROCESSOR` recursion guard. |
| `spawn_helper.sh` | `COORD_TEST_MODE` resolver (mock|semi|realistic) + 3-site routing matrix. **Agent-agnostic in shape — but currently only routes to `claude` binary.** |
| `cost_guards.sh` | Sliding-window per-site rate limit (mediator/validator/task_processor); per-site flock + counter file. |
| `critical_check.sh` | 3-strike parse-failure counter → directly activates lockdown bypassing Mediator. |
| `cycle_detection.sh` | Bipartite session/file DFS for deadlock detection + Phase 6 task-graph cycle/depth detection. |
| `hash.sh` | Portable sha256 with size cap (`SKIPPED_LARGE` sentinel). |
| `head_tracking.sh` | git HEAD comparison helpers for read-set invalidation. |
| `notify_waiters.sh` | 4-tier diff_summary computation + per-waiter `wake_file` write + `notifications[]` append. |
| `read_snapshots.sh` | Content-addressable read-snapshot store at `.coord/read_snapshots/<sid>/<hash>.txt`; LRU eviction. |
| `self_tasks.sh` | Per-session self-delegation records; reminder throttle; stop-block-count helper. |
| `state_query.sh` | Read-only sessions.json helpers (`coord_lock_holder`, `coord_active_sessions`, etc.). |
| `validator_cache.sh` | Validator verdict cache (SAFE/MINOR only; CRITICAL never cached); TTL + LRU. |
| `validator_prefilter.sh` | Stage-2 deterministic pre-filter (whitespace-only / blank-only / comment-only heuristics). |
| `verdict_apply.sh` | Mediator action applier: `release_lock`, `evict_session`, `clear_read_set`. |
| `wait_backend.sh` | fswatch / inotifywait / 250ms polling fallback dispatch; reads `config.wait_backend`. |
| `wait_queue.sh` | Per-file FIFO wait queue with cycle-detection trigger on depth ≥ 2. |
| `watchdog.sh` | 3-signal probe (PID/lstart, last-activity, lock refresh) + ambient-suspicion scan. |
| `watchdog_cache.sh` | Per-target verdict cache + dedupe lock at `.coord/watchdog/checking/<target>.lock`. |
| `coord_mediate.sh` | `coord mediate` operator CLI: `--reason`, `--approve`, `--escalate`, `--resume`, `status`. |
| `MEDIATOR_REFERENCE.md`, `VALIDATOR_REFERENCE.md` | Inline reference docs embedded in spawn prompts via `.coord/mediator/...` path; copied during install. |

### `src/`
| Path | One-liner |
|---|---|
| `install.sh` | The installer. Writes `.claude/settings.local.json`; materializes `.coord/`; runs SessionStart smoke test. |
| `bin/coord` | The `coord` CLI: `status`, `health`, `log`, `events`, `reset`, `install`, `uninstall`, `wait`, `task-open`, `self-delegate`, `mediate`. |

### `src/tests/`
| Path | One-liner |
|---|---|
| `helpers/common.bash` | Shared bats helpers. |
| `unit/*.bats` (54 files) | Per-module unit tests; many hardcode Claude Code tool names + payload formats. |
| `integration/cost_guards_modes.bats` | Mode-aware cost-guard integration. |
| `integration/spawn_helper_modes.bats` | 3-mode spawn helper integration. |
| `integration/phase5_e2e.bats` | Phase 5 wait-queue/cycle/notify e2e. |
| `integration/phase6_e2e.bats` | Phase 6 task delegation + self-delegate e2e. |
| `manual/phase{3,4,5,6,7}_ship_gate.sh` | Ship-gate driver scripts (gitignored). |
| `manual/linux_probe.sh` | Linux fs probe; runs SessionStart/SessionEnd JSON inputs. |
| `manual/two_session_warn.sh` | Two-session smoke. |
| `concurrent_smoke.sh` | Concurrent stress smoke. |
| `fixtures/two_session_warn/` | Open scenarios. |
| `fixtures/phase{3-7}_ship_gate/` | Gitignored fixtures. |

### `.coord/` runtime state (gitignored)
| Path | One-liner |
|---|---|
| `sessions.json` | Master state JSON (sessions, locks, wait_queues, read_sets, notifications, self_tasks, anomaly_votes, task_graph). |
| `sessions.lock`, `sessions.json.lock`, `events.lock`, `history.lock` | flock sentinels. |
| `events.jsonl` | Append-only audit log. |
| `config.json` | Tunables. |
| `schema_version` | One-line `1.0`. |
| `sessions/<sid>.active` | Participant marker. |
| `sessions/<sid>.env` | Per-session shell-safe KV (only `COORD_PROMPT_ID`). |
| `sessions/<sid>.last_consumed_verdict` | Per-session verdict-pointer for `pre_tool_use_any.sh`. |
| `sessions_history.json`, `sessions_history.json.lock` | Phase 1 history append target. |
| `mediator/pending.jsonl`, `pending.lock`, `pending.consumed`, `lockdown.json`, `lockdown_archive/`, `verdict/<ts>.json`, `MEDIATOR_REFERENCE.md`, `critical_counters.json`, `critical_counters.lock` | Mediator subsystem. |
| `validator/cache.json`, `cache.lock`, `verdict/<ts>.json`, `VALIDATOR_REFERENCE.md` | Validator subsystem. |
| `read_snapshots/<sid>/<hash>.txt` | Content-addressable snapshots. |
| `watchdog/recent_checks.jsonl`, `recent_checks.lock`, `checking/<target>.lock` | Watchdog cache. |
| `wait_queues/<sanitized>.lock`, `wakers/<sid>-<sanitized>.wake` | Wait-queue infrastructure. |
| `cost_guards/<site>.counter`, `<site>.lock` | Per-site rate-limit counters. |
| `self_tasks/<sid>.lock` | Per-session self-task lock. |
| `bin/coord`, `hooks/*.sh`, `lib/*.sh` | Copies of `src/` artefacts (installer copies these). |

---

## C. Findings by area

### 1. Hook entry points

**Current behavior.** Eight hook scripts under `src/hooks/`. Common pattern in every hook:
1. `[ "${CLAUDE_COORD:-}" != "1" ] && exit 0` — env-var participation gate. (e.g., `src/hooks/session_start.sh:75`, `pre_tool_use_any.sh:79`, `pre_tool_use_read.sh:71`, `pre_tool_use_write.sh:476`, `post_tool_use_write.sh:79`, `session_end.sh:67`, `stop.sh:77`, `user_prompt_submit.sh:64`).
2. `INPUT="$(cat)"` — full stdin read of Claude Code's hook event JSON.
3. `coord_subagent_filter "<HookEventName>" "$INPUT"` — checks `input.agent_type` and exits 0 silently for subagents (`src/lib/subagent_filter.sh:40-86`).
4. Parse fields via `jq -r '.session_id // ""'`, `'.tool_name // ""'`, `'.tool_input.file_path // .tool_input.notebook_path // ""'`, `'.cwd // ""'`, `'.source // "startup"'`, `'.prompt // ""'`, `'.reason // "unknown"'`.
5. Resolve `COORD_DIR` via `coord_resolve_root` — uses `${CLAUDE_PROJECT_DIR:-}` first then `git rev-parse --show-toplevel`.
6. `coord_is_participant` check via `.coord/sessions/<sid>.active` marker.
7. `coord_lockdown_check && coord_lockdown_emit_deny "<HookEventName>"` — emits `permissionDecision: deny` envelope with the supplied event name.
8. Hook-specific business logic.
9. On output: `jq -nc --arg t "$text" '{hookSpecificOutput: {hookEventName: "<event>", additionalContext: $t}}'` for banners; `permissionDecision: "deny"` for denies.

**Hardcoded Claude Code couplings (with file:line):**
- **Tool-name branches.** `src/hooks/pre_tool_use_any.sh:96` checks `F015_TOOL = "Bash"` for the F-015 `coord wait` subagent banner.
- **Subagent detection.** `src/lib/subagent_filter.sh:49` reads `.agent_type` (Claude-Code-specific field).
- **Tool-input field names.** `src/hooks/pre_tool_use_read.sh:83` (`tool_input.file_path`); `pre_tool_use_write.sh:490` and `post_tool_use_write.sh:92` (`tool_input.file_path // .tool_input.notebook_path`).
- **Hook event-name strings used as inputs to `emit_additional_context` / `emit_deny`** — `"PreToolUse"`, `"SessionStart"`, `"SessionEnd"`, `"Stop"`, `"UserPromptSubmit"`, `"PostToolUse"`. These appear in every hook's emitter helper.
- **PostToolUse line-range parsing.** `src/hooks/post_tool_use_write.sh:180-189` reads `.tool_response.start_line`, `.tool_input.start_line`, `.tool_response.end_line`, `.tool_input.end_line` — Claude Code's PostToolUse payload shape.
- **PPID assumption.** `src/hooks/session_start.sh:123` does `PID="$PPID"` to capture the Claude Code parent PID for liveness probing. Codex's process model needs to be confirmed: if Codex spawns the hook with the agent process as the direct parent (same as Claude), `PPID` carries; if Codex uses a launcher/wrapper, the captured PID is wrong.

**Required changes for Codex adapter (per file:line):**
- A new `src/adapters/codex/hooks/` family of entry points OR translator wrappers that re-shape Codex's stdin into the same fields the core consumes.
- `pre_tool_use_any.sh:96` Bash special-case — Codex's tool name for shell is also `Bash` (per Codex hook docs), so this carries.
- `subagent_filter.sh` — Codex hook docs do not define `agent_type`. The filter would either become a no-op for Codex or grow a Codex-specific predicate (TBD; Codex subagent semantics are not in the public hook docs — see Open Question H1).
- `pre_tool_use_read.sh` is **structurally absent** in Codex — Codex has no `Read` tool. The replacement is reading `apply_patch`'s pre-edit content (see Finding 5).
- `pre_tool_use_write.sh:490` and `post_tool_use_write.sh:92` — Codex's `apply_patch` payload shape (`tool_input.command` per docs) does not have a `file_path` field directly; the path lives inside the patch text. The path-extraction logic must be Codex-specific.
- `session_start.sh:123` PPID — needs verification on Codex.
- Banner emitter shapes — Codex's `additionalContext` shape on `SessionStart`, `UserPromptSubmit`, `PostToolUse` matches Claude Code (`hookSpecificOutput.{hookEventName, additionalContext}`); usable as-is. **`PreToolUse` is the divergent case**: Claude Code uses `permissionDecision: "deny"` inside `hookSpecificOutput`; Codex documents the same field name (`permissionDecision: "deny"`) for `PreToolUse` too, but pure deny via the `PermissionRequest` event uses `decision: { behavior: "deny", message }`. The current code uses Claude's `permissionDecision: deny` form, which Codex appears to support too.

**Required changes for cross-agent coordination:**
- Hooks must NOT assume the session triggering them is the same agent type as a peer holding a lock. The `LOCK_HOLDER` short-string formatting (`src/hooks/pre_tool_use_write.sh:662`, `HOLDER_SHORT="${LOCK_HOLDER:0:8}"`) is agent-agnostic but the deny banner text references `coord wait <path>` (`build_deny_reason` at `pre_tool_use_write.sh:454-473`) — both Claude and Codex Bash sessions can run `coord wait` since it's a shell command, so this carries.
- `coord_is_participant` semantics: the `.active` marker is per-session-id and agent-agnostic. Confirmed safe.
- PostToolUse line-range parsing: a Codex-emitted PostToolUse will not carry `tool_response.start_line` (different payload). The fall-through is `0/0` which the Phase 6 task processor treats as "force CONFLICT" (`task_processor.sh:509`). That degrades correctness — Codex `apply_patch` line ranges need to be extracted from the patch payload.

**Hidden assumptions / risks.**
- The deny banner references **CLI commands** (`coord task-open`, `coord wait`, `coord self-delegate`) — these are agent-agnostic since `coord` is a shell binary, but the banner explanation assumes the operator will issue a `Bash:` command. Codex's `Bash` tool naming is identical, so the banner text works for Codex. However, Codex agents may interpret the `Bash:` prefix differently in their internal tool-call protocol — verify in integration testing.
- `pre_tool_use_any.sh` does mediator-verdict consumption + watchdog ambient probe + verdict pointer advance. These are agent-agnostic in the **mechanism** but the **emitted banner text** (`"Coord Mediator verdict: <message_to_caller>"`) is rendered into a Claude-style additionalContext shape. Codex shape compatibility depends on whether Codex parses `hookSpecificOutput.additionalContext` from `pre_tool_use_any.sh`'s output — but `pre_tool_use_any.sh`'s matcher is `*`, so if Codex's PreToolUse hook event uses a different matcher syntax, the hook may not fire at all.

---

### 2. Hook registration / installer

**Current behavior.** `src/install.sh:381-447` (`register_hooks` function). Uses `jq` to merge into `.claude/settings.local.json`:
```jq
.hooks.SessionStart       = ((.hooks.SessionStart // [])
    + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/session_start.sh"),     timeout:10}]}])
.hooks.SessionEnd         = ((.hooks.SessionEnd // [])
    + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/session_end.sh"),       timeout:10}]}])
.hooks.Stop               = ((.hooks.Stop // [])
    + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/stop.sh"),              timeout:10}]}])
.hooks.UserPromptSubmit   = ((.hooks.UserPromptSubmit // [])
    + [{matcher:"*", hooks:[{type:"command", command:($hdir+"/user_prompt_submit.sh"),timeout:10}]}])
.hooks.PreToolUse         = ((.hooks.PreToolUse // [])
    + [{matcher:"*",                       hooks:[...pre_tool_use_any.sh,   timeout:10]},
       {matcher:"Read",                    hooks:[...pre_tool_use_read.sh,  timeout:10]},
       {matcher:"Write|Edit|NotebookEdit", hooks:[...pre_tool_use_write.sh, timeout:10]}])
.hooks.PostToolUse        = ((.hooks.PostToolUse // [])
    + [{matcher:"Write|Edit|NotebookEdit", hooks:[...post_tool_use_write.sh,timeout:10]}])
```
- Idempotency: removes any prior coord-owned entries (containing `/.coord/hooks/`) before appending (`install.sh:421-427`).
- `--bypass-permissions`: also sets `.permissions.defaultMode = "bypassPermissions"`.
- `--uninstall`: strips coord entries, leaves `.coord/`.
- `--purge` (only via `bin/coord uninstall --purge` — `src/bin/coord:237-247`): deletes `.coord/`.
- Smoke test (`install.sh:462-485`) pipes a canned `SessionStart` JSON into `session_start.sh`; checks output contains `Coord v1.0 active`; verifies `.active` marker; runs SessionEnd.

**Required changes for Codex adapter:**
- Per Codex hook docs, the config locations are (in precedence order): `~/.codex/hooks.json`, `~/.codex/config.toml` (with inline `[hooks]`), `<repo>/.codex/hooks.json`, `<repo>/.codex/config.toml`. Feature gate `[features] codex_hooks = true` is required in config.
- Codex JSON schema is structurally similar (`{"hooks": {"<EventName>": [{"matcher": "...", "hooks": [{"type": "command", "command": "...", "timeout": 30, "statusMessage": "..."}]}]}}`).
- Codex matcher is **regex** (e.g., `"^Bash$"`) per the docs example, where Claude's matcher is glob/alternation (`"Write|Edit|NotebookEdit"`). Need to verify whether Claude's alternation matcher syntax is interpreted as regex by Codex; safest is to write Codex matchers explicitly: `"^Bash$"`, `"^apply_patch$"`, `"^mcp__"`.
- Idempotency strategy: same as Claude — remove entries whose `command` contains `/.coord/hooks/` (or `/.coord/adapters/codex/hooks/` after refactor) before appending.
- `--uninstall` semantics: strip Codex entries from both `~/.codex/config.toml`'s `[hooks]` table AND `<repo>/.codex/hooks.json`. The TOML parse/unparse needs a different toolchain than `jq`; either require `tomlq`/`toml-cli` or use Python's `tomllib` (3.11+). Alternative: write Codex hooks ONLY to `<repo>/.codex/hooks.json` (project-local JSON), avoiding TOML entirely.
- Smoke test: needs a Codex-shaped SessionStart canned input. Codex docs confirm `SessionStart` event with `source` (startup|resume) field, so the canned JSON shape is the same except for additional fields like `model`, `transcript_path`, `turn_id` which Codex supplies.

**Required changes for cross-agent coordination:**
- A single `bash src/install.sh` invocation must be able to install BOTH adapters when both runtimes are detected (presence of `claude` AND `codex` binaries on PATH, OR explicit `--with-claude-code --with-codex` flags). Currently the installer only writes Claude Code hooks unconditionally.
- The `register_hooks` function needs to grow a per-adapter dispatch.
- Smoke test must run for the agent(s) that were installed.
- The post-install `[8/8] next steps` banner (`install.sh:526-540`) currently says `export CLAUDE_COORD=1` — needs to enumerate the corresponding env var(s) for Codex (TBD: see Open Question H6 — should there be `CODEX_COORD=1` or should `CLAUDE_COORD` be renamed to `COORD_ENABLED` and shared?).

**Hidden assumptions / risks.**
- `install.sh:79` hardcodes `CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.local.json"`. Even after refactor, if a user runs only Codex (no Claude installed), creating `.claude/` is harmless but adds an unused directory.
- The smoke test currently asserts `Coord v1.0 active` banner appears. The banner is emitted unconditionally by `session_start.sh`. With Codex, the same banner emit on `SessionStart` should work (Codex supports `additionalContext`), but verify that Codex's plain-text-stdout fallback (Codex SessionStart accepts plain stdout as developer context) works as a backup.
- `gitignore_entries` (`install.sh:450-459`) appends `.claude/settings.local.json` to `.gitignore`. Add `.codex/hooks.json`.
- The npm wrapper `bin/parallel-sessions:54-72` (init) only ever runs `bash src/install.sh` — same binary handles both adapters.

---

### 3. State schema

**Current shape of `.coord/sessions.json`** (`src/lib/atomic_write.sh:56-69` — empty template; observed live at `.coord/sessions.json:1-22`):
```json
{
  "schema_version": "1.0",
  "sessions": {
    "<sid>": {
      "state": "ACTIVE | IDLE_CLOSED",
      "pid": <int>,
      "pid_lstart": "Fri Apr 24 12:43:37 2026",
      "registered_at": "<ISO 8601>",
      "last_activity_at": "<ISO 8601>",
      "git_head": "<sha>",
      "prompt_id": null | "<sha256 of prompt>",
      "script_version": "1.0"
    }
  },
  "locks": {
    "<file_path>": {
      "session": "<sid>",
      "acquired_at": "<ISO>",
      "last_refresh_at": "<ISO>",
      "tasks": [<task_record>],
      "latest_validator_verdict_ts": null | "<ts>"
    }
  },
  "wait_queues": { "<file_path>": [ {"session_id", "waiting_since", "wake_file", "queue_position"} ] },
  "read_sets": { "<sid>": { "reads": [ {"path", "hash", "at", "is_latest", "superseded_by"?, "superseded_by_head_change"?} ] } },
  "notifications": { "<sid>": { "<file_path>": [ "<msg string>" ] } },
  "self_tasks": { "<sid>": [ {"file","instruction","created_at","prompt_id","last_reminded_at","stop_block_count"} ] },
  "anomaly_votes": {},
  "task_graph": {}
}
```

**Other state files:**
- `.coord/events.jsonl` — append-only audit log (one JSON object per line). Schema: `{ts, session, kind, [tool], [file], [hash], payload}` (`src/lib/log_event.sh:74-91`).
- `.coord/mediator/pending.jsonl` — append-only with `pending.consumed` HWM file (`src/lib/mediator_pending.sh:64-74`). Per-line: `{ts, kind, session, source?, payload}`.
- `.coord/mediator/verdict/<ts>.json` — Mediator output per spawn.
- `.coord/mediator/lockdown.json` — `{active, reason, reason_source ∈ {critical_bypass, mediator_verdict, user_escalation}, started_at}`.
- `.coord/validator/cache.json` — `{entries: [...]}`.
- `.coord/validator/verdict/<ts>.json` — Validator output per spawn.

**Implicitly Claude-Code-specific fields:**
- Nothing in `sessions[<sid>]` carries an explicit "agent" tag. The session is identified by an opaque UUID assigned by Claude Code and recorded as-is.
- `prompt_id` is computed by `src/hooks/user_prompt_submit.sh:117-123` as sha256 of the `input.prompt` field — Codex's UserPromptSubmit also has a `prompt` field per docs, so this carries.
- `git_head` is captured by `coord_current_head` (`src/lib/head_tracking.sh:26-33`) — agent-agnostic.

**Required changes for cross-agent coordination:**

Required new fields on `sessions[<sid>]`:
1. `agent: "claude_code" | "codex"` — needed so deny banners can adapt CLI hint phrasing if needed (e.g., Codex `apply_patch` instead of Claude `Edit`); the watchdog's "what to do with this dead session" decision; the Mediator's eviction-priority guidance (PR-PHASE5-04 §1) may want to favor evicting same-agent sessions first to minimize cross-agent disruption.
2. (Optional) `agent_version: "<sdk_or_cli_version>"` — for diagnostics in events.jsonl.
3. (Optional) `agent_specific: { ... }` — per-adapter scratch (e.g., Codex's `transcript_path` or `model` slug if useful for debugging).

Recommended schema-version bump: `1.0` → `1.1` (additive). Existing sessions without the field should be treated as `agent: "claude_code"` (legacy default) by all readers — no migration breakage.

**Places in code that assume a session is a Claude Code session:**
- `src/hooks/session_start.sh:123` `PID="$PPID"` (parent process ≡ Claude Code parent).
- `src/lib/subagent_filter.sh:49` `.agent_type` field is Claude Code-specific.
- `src/lib/mediator_spawn.sh` and `validator_spawn.sh` and `task_processor.sh` — all hardcode `claude` binary. These are NOT called from hooks directly; they are invoked from within `pre_tool_use_write.sh`'s validator pipeline and from the Mediator pending consumer. The spawned process is always Claude regardless of which agent triggered the spawn.
- `src/install.sh:530` recommends `export CLAUDE_COORD=1`.

**Hidden assumptions / risks.**
- `latest_validator_verdict_ts` on `locks[<file>]` is set when the validator agent ran on this file's drift; `notify_waiters.sh:93-105` looks up the verdict file by ts to compute diff_summary. This is agent-agnostic since the validator output schema does not depend on the originating agent — but the validator was invoked with the spawning session as `sid`, and that sid may now be a Codex session.
- `.coord/sessions/<sid>.env` only stores `COORD_PROMPT_ID` (`src/hooks/user_prompt_submit.sh:159-162`) — agent-agnostic.
- `read_sets[<sid>].reads[]` uses `path` + `hash` — agent-agnostic, but the **producer** (currently only `pre_tool_use_read.sh`) must be replaced with a Codex-side producer (Finding 5).

---

### 4. Tool name dependencies (grep audit)

I grepped for `"Read"`, `"Write"`, `"Edit"`, `"NotebookEdit"`, `"MultiEdit"`, `"Bash"`, `tool_name`, `hook_event_name`, `PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit` across `src/`. Findings:

**Core (`src/lib/`) classification:**
- `src/lib/log_event.sh:38, 122` — bats tests reference `tool=Edit`, `tool=Bash` for log payload. **Adapter-translatable**: log_event accepts arbitrary `tool=` value; the strings come from hooks.
- `src/lib/subagent_filter.sh:49` — reads `.agent_type` (Claude-specific). **Adapter-specific** — Codex equivalent unknown.
- All other libs that touch tool-name strings only do so transitively via the hook layer.

**Hooks (`src/hooks/`) classification:**
- `pre_tool_use_read.sh` — entire script is a Claude `Read` matcher. **Adapter-specific** — has no Codex equivalent.
- `pre_tool_use_write.sh` — bound to `Write|Edit|NotebookEdit` matcher. The script body is mostly agent-agnostic (lock check, validator pipeline, deny banner) but the input parsing (`tool_input.file_path // tool_input.notebook_path`) is Claude-shaped.
- `pre_tool_use_any.sh:96` — special-case for `tool_name = "Bash"` + command starts with `coord wait` (F-015). Codex `Bash` tool name is identical so this carries.
- `post_tool_use_write.sh:180-189` — reads `tool_response.start_line` etc. Claude-shaped.

**Installer (`src/install.sh`):**
- All hook event names + matchers are hardcoded in jq filter (`install.sh:431-444`). Per-adapter installer needed.

**Tests (`src/tests/`):**
- 54 unit bats files; nearly all encode `INPUT='{...,"hook_event_name":"PreToolUse","tool_name":"Read",...}'` style payloads. These test the **adapter** (the Claude Code adapter), not the **core**. Should remain as Claude-Code-adapter unit tests post-refactor.
- Integration tests (`integration/phase6_e2e.bats:81-93`, `phase5_e2e.bats`, `spawn_helper_modes.bats:114`, `cost_guards_modes.bats`) similarly hardcode Claude payload shapes. Same disposition: adapter-level tests.

**Normalization map proposed (Claude → core):**
| Claude hook event | Core normalized event |
|---|---|
| `SessionStart` | `SESSION_START` |
| `SessionEnd` | `SESSION_END` |
| `Stop` | `STOP` |
| `UserPromptSubmit` | `PROMPT_SUBMIT` |
| `PreToolUse(Read)` | `PRE_FILE_READ` |
| `PreToolUse(Write|Edit|NotebookEdit)` | `PRE_FILE_WRITE` |
| `PreToolUse(*)` | `PRE_TOOL_ANY` |
| `PostToolUse(Write|Edit|NotebookEdit)` | `POST_FILE_WRITE` |
| `PostToolUse(Bash)` | (currently NOT registered) |
| Codex `PreToolUse(apply_patch)` | `PRE_FILE_WRITE` (Bash + path-extraction needed) |
| Codex `PreToolUse(Bash)` | `PRE_TOOL_ANY` (no separate read-tracking) |
| Codex `PermissionRequest` | (decide: route to lockdown deny? See OQ H7) |

---

### 5. Read tracking and stale-read drift detection

**How reads are recorded today.** `src/hooks/pre_tool_use_read.sh:73-202`:
1. `INPUT="$(cat)"` — stdin JSON.
2. `FILE_PATH=$(jq -r '.tool_input.file_path // ""' …)`.
3. `HASH=$(coord_hash_file "$FILE_PATH")` (`src/lib/hash.sh:23-56` — `shasum -a 256`).
4. Atomic `coord_atomic_edit` on `sessions.json`:
   ```
   .read_sets[$sid].reads |= ((. // []) | map(
     if .path == $path and ((.is_latest // true) == true)
     then . + {is_latest: false, superseded_by: $hash}
     else . end))
     + [{path: $path, hash: $hash, at: $now, is_latest: true}]
   ```
5. `coord_read_snapshot_write "$SESSION_ID" "$HASH" "$FILE_PATH"` writes the bytes to `.coord/read_snapshots/<sid>/<hash>.txt` for later validator pipeline consumption (`src/lib/read_snapshots.sh:190-257`).

**Where the read-set lives:** in-memory portion at `sessions.json::read_sets[<sid>].reads`. Bytes-on-disk at `.coord/read_snapshots/<sid>/<hash>.txt`.

**Freshness check at write time.** `src/hooks/pre_tool_use_write.sh:538-543`:
```
ENTRIES_TSV=$(jq -r --arg sid "$SESSION_ID" '
  (.read_sets[$sid].reads // [])
  | map(select((.is_latest // false) == true and ((.superseded_by_head_change // false) == false)))
  | .[] | [.path, .hash] | @tsv' "$STATE")
```
For each entry, compute current hash via `coord_hash_file` and compare. If different → run pipeline.

**3-stage pipeline** (`pre_tool_use_write.sh:_coord_phase4_run_pipeline` lines 261-370):
1. **Stage 1 — Validator cache lookup** (`validator_cache.sh:108-141`). Hit on `(file, read_hash, current_hash)` → SAFE (silent) or MINOR (banner) verdict. CRITICAL never cached.
2. **Stage 2 — Pre-filter** (`validator_prefilter.sh:165-297`). Heuristics: whitespace-only, blank-only, comment-only (with multi-line marker guard). Reads `read_snapshot_path(sid, read_hash)` and current file. SAFE → cache + return. ESCALATE → fall to stage 3.
3. **Stage 3 — Validator agent** (`validator_spawn.sh:247-478`). Spawns `claude -p` with the snapshot bytes embedded (Section 3 of prompt at `validator_spawn.sh:130-206`); returns SAFE / MINOR / CRITICAL verdict file.

**CRITICAL handling.** `pre_tool_use_write.sh:_coord_phase4_handle_critical:204-255` — emits `critical_drift` pending entry, calls `coord_mediator_spawn` synchronously, applies actions, prints banner.

**Drift classification verdicts (SAFE / MINOR / CRITICAL):** Validator agent's prompt section 3 at `validator_spawn.sh:172-182` defines them.

**Codex integration plan (the unique opportunity).**

Codex has **no separate Read tool**. Per the Codex hook docs, the relevant tools are `Bash`, `apply_patch`, and MCP tools. There is no `Read`. **Therefore there is no `pre_tool_use_read.sh` for Codex — the read-set must come from a different signal.**

Codex's `apply_patch` payload contains the agent's belief about the pre-edit file content (within the patch's `***` / `@@` chunks). The unified-diff-style payload is the agent's pre-edit assertion. **This is a STRONGER signal than Claude's hash-of-current-file** because:
- Claude's flow: agent does `Read` → hook hashes the disk file at Read time → at write time hook re-hashes disk file and compares. Drift = "the file changed since the agent looked."
- Codex's flow: agent emits `apply_patch` → hook can extract the agent's PRE-EDIT belief from the patch's context → hash it → hash the actual on-disk file → compare. Drift = "the file is not what the agent thinks it is RIGHT NOW."

The **ts** of when the agent formed its belief is unknown for Codex (no Read event), but the strongest drift signal — agent-belief-vs-truth at write time — is directly available without read-tracking.

**Files/functions that need to be adapted for Codex:**

1. **`src/lib/validator_cache.sh:108-141` (`coord_validator_cache_lookup`)** — current key is `(file, read_hash, current_hash)`. For Codex: `(file, agent_belief_hash, current_hash)`. The `read_hash` field becomes `agent_belief_hash` semantically; cache layout unchanged.
2. **`src/lib/validator_prefilter.sh:165-297` (`coord_validator_prefilter`)** — current arg shape: `<sid> <file> <read_hash> <current_hash>` and reads from `coord_read_snapshot_path "$sid" "$read_hash"`. For Codex: the snapshot needs to be derived from the `apply_patch` payload's "pre" content (parsed out of the unified diff context). A new `coord_codex_extract_pre_image` helper would write the synthesized snapshot to `.coord/read_snapshots/<sid>/<agent_belief_hash>.txt`.
3. **`src/lib/validator_spawn.sh:247-478` (`coord_validator_spawn`)** — same adaptation; the prompt section 3 references "Read snapshot (sha256 = $rhash)" which can keep the wording (the bytes are the agent's belief, which is functionally the same as a Read snapshot).
4. **`src/hooks/pre_tool_use_write.sh:538-637`** — the entries-walk currently iterates `read_sets[$sid].reads[]` and skips if `is_latest:false`. For Codex: there is no read_set; the loop body must run **once** with the current `apply_patch`'s pre-image as the input.
5. **`src/lib/read_snapshots.sh`** — no change needed; the storage layer is content-addressable and agent-agnostic.

**Where the absence of a separate Read event would silently degrade.**
- HEAD-change drift detection (`src/hooks/pre_tool_use_any.sh:172-175`, `src/lib/head_tracking.sh:54-60`) marks `superseded_by_head_change:true` on read-set entries. For Codex with no read-set, HEAD-change detection still works — but there are no entries to mark, so the warning becomes "your apply_patch will run against the current HEAD; HEAD has drifted" rather than file-level invalidation.
- Self-task reminders (`src/hooks/pre_tool_use_any.sh:236-274`) check `coord_self_task_check_unlocked` against `self_tasks[<sid>]`; **agent-agnostic**, no degradation.
- Notifications consume on Read (`pre_tool_use_read.sh:144-154`) → for Codex, notifications must be consumed somewhere else. Since Codex has no Read hook, the natural consumer is `pre_tool_use_any.sh` (matcher `*`, fires on every tool call) which already does notification consumption (`pre_tool_use_any.sh:158-166, 213-217`). Confirmed: no new notification-consumer needed.

---

### 6. Mediator, Validator, Task Processor spawn sites

Three `claude -p` invocations across the codebase:

1. **Mediator** — `src/lib/mediator_spawn.sh:317-327`:
   ```bash
   raw_output=$(
     env CLAUDE_COORD=0 CLAUDE_CODE_MEDIATOR="$depth" \
         COORD_DIR="$COORD_DIR" \
         claude -p "$prompt" \
           --output-format json \
           --model "$COORD_MEDIATOR_MODEL" \
           --max-budget-usd "$COORD_MEDIATOR_BUDGET_USD" \
           --allowedTools Bash Read \
           --disallowedTools Write Edit NotebookEdit Task \
           2>/dev/null)
   ```
   - stdin: not used (prompt is via `-p`).
   - Default model: `claude-haiku-4-5-20251001` (env-overridable).
   - Recursion guard env: `CLAUDE_CODE_MEDIATOR=<depth>` (1 or 2; 2 is the peer-review depth).
   - Output parse: `.is_error`, `.session_id`, `.total_cost_usd`, `.result`, `.errors`. The actual verdict is found by `ls -1t "$verdict_dir"/*.json | head -1` (Mediator was instructed to write the file via Bash).

2. **Validator** — `src/lib/validator_spawn.sh:361-371`:
   ```bash
   raw_output=$(
     env CLAUDE_COORD=0 CLAUDE_CODE_VALIDATOR=1 \
         COORD_DIR="$COORD_DIR" \
         claude -p "$prompt" \
           --output-format json \
           --model "$COORD_VALIDATOR_MODEL" \
           --max-budget-usd "$COORD_VALIDATOR_BUDGET_USD" \
           --allowedTools "Bash" "Read" \
           --disallowedTools "Write" "Edit" "NotebookEdit" "Task" \
           2>/dev/null)
   ```
   - Same default model + flags as Mediator.
   - Recursion guard env: `CLAUDE_CODE_VALIDATOR=1` (only depth-1 supported).
   - Output parse: same `.is_error` / `.result` / `.session_id`.

3. **Task Processor** — `src/lib/task_processor.sh:321-331` (real-claude branch; `_coord_tp_real_claude_spawn`):
   ```bash
   raw_output=$(
     env CLAUDE_COORD=0 CLAUDE_CODE_TASK_PROCESSOR=1 \
         COORD_DIR="$COORD_DIR" \
         claude -p "$prompt" \
           --output-format json \
           --model "$COORD_TASK_PROCESSOR_MODEL" \
           --max-budget-usd "$COORD_TASK_PROCESSOR_BUDGET_USD" \
           --allowedTools "Bash" "Read" \
           --disallowedTools "Write" "Edit" "NotebookEdit" "Task" \
           2>/dev/null)
   ```
   - Recursion guard env: `CLAUDE_CODE_TASK_PROCESSOR=1`.
   - Mock-bypass: env `COORD_MOCK_CLAUDE_TASK_PATCH` set → use verbatim (highest precedence).

**Does the spawned subprocess need to match the agent that triggered the spawn?**

**Architectural recommendation: NO.** Always spawn `claude -p` regardless of which agent triggered.

Rationale:
- The Mediator/Validator/Task-Processor are pure analytical / classifier roles. They produce structured JSON verdicts with no agent-specific output dependencies.
- Forcing `claude -p` everywhere keeps the prompts, recursion guards, output parsers, cost guards, and 3-mode COORD_TEST_MODE matrix unchanged.
- Cross-platform consistency: the same Mediator analysis algorithm runs whether the trigger was Claude or Codex.
- Lower complexity: no per-agent prompt templates.

**Hard prerequisite:** **`claude` binary MUST be installed and on PATH**, even for Codex-only users. This must be documented prominently in install.sh, README, CONTRIBUTING.

If the user pushes back ("I want Codex-only with no Claude installed"), the alternative is a `coord_spawn_helper_resolve_backend` extension that picks `claude -p` vs `codex exec` based on a `COORD_MEDIATOR_BACKEND` env var. Adding `codex exec` as an alternative would require:
- A separate prompt template (Codex's `codex exec` system-prompt convention may differ).
- Output-format normalization (Codex may not have `--output-format json` with the same `.is_error/.result/.session_id` fields).
- Recursion guard env name (Codex would need its own — `CODEX_CODE_MEDIATOR=<depth>` analogue).
- Per-backend cost-guard tunables (Codex pricing differs).

The simpler choice — claude required as a hard dep — is the recommended starting point.

---

### 7. Cost guard / rate limiting

**Current scope.** Per-site, NOT per-agent (`src/lib/cost_guards.sh`):
- Sites: `mediator`, `validator`, `task_processor` (`_coord_cg_paths:120-122`).
- Counters: one file per site at `.coord/cost_guards/<site>.counter`.
- Tunables: `COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=300`, `COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=12`, `COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=120`, task_processor=disabled (max=0 sentinel).

**Per-agent vs global question.**

Since all spawn sites use `claude -p` regardless of trigger (recommendation in Finding 6), the cost guard naturally measures "claude API cost per repository per hour" — which is the meaningful billing-aligned quantity. Per-agent cost guard has no value if the spawned process is always Claude.

**Recommendation: keep cost guard global per site**, NOT per-agent. The tunable still represents Claude API rate / cost.

If/when `codex exec` becomes a Mediator/Validator backend (Open Question H8), the counter file should be per-(site, backend), e.g., `.coord/cost_guards/mediator.claude.counter` vs `.coord/cost_guards/mediator.codex.counter`, since the rate limits and cost units differ.

---

### 8. Crash recovery / Watchdog

**Current 3-signal consensus** (`src/lib/watchdog.sh:144-211`):
1. **Signal 1 — PID/lstart liveness.** `_coord_watchdog_ps_lstart $pid` runs `ps -p <pid> -o lstart=`. Empty output → `pid_gone`. Mismatch with stored `pid_lstart` → `pid_recycled`.
2. **Signal 2 — last_activity_at age.** Compares against `COORD_WATCHDOG_SUSPICION_LAST_ACTIVITY_SEC=600s`.
3. **Signal 3 — lock acquired_at == last_refresh_at AND age > `COORD_WATCHDOG_SUSPICION_LOCK_UNREFRESHED_SEC=1800s`.** Lock never refreshed → suspicion.

**Are the signals agent-agnostic?**

- Signal 1: **agent-agnostic** (`ps -p` is OS-level).
- Signal 2: **agent-agnostic** (`last_activity_at` is updated by every hook regardless of agent).
- Signal 3: **agent-agnostic** (`locks[<file>]` doesn't depend on agent).

**Place that assumes the dead process was Claude.**

`src/lib/watchdog.sh:217` reason text: `"PID $pid recycled (lstart mismatch: stored=$pid_lstart current=$(...))"` — agent-agnostic.

The Mediator's eviction of a dead session via `coord_verdict_apply_evict_session` (`verdict_apply.sh:104-138`) deletes `.sessions[$sid]`, all locks held, read_sets, notifications, self_tasks, and the `.active` marker. **None of this is agent-specific.**

**Conclusion:** Watchdog is fully agent-agnostic. A Claude Code session can recover a crashed Codex session and vice versa without code changes (post-refactor; the watchdog already lives in the agent-agnostic layer).

---

### 9. Session identity and registration

**How session UUIDs are assigned.** Claude Code passes `session_id` on every hook stdin (`session_start.sh:90`, `pre_tool_use_*.sh`, etc.). Coord captures it as-is and stores it in `sessions.json`. **The session UUID is opaque from coord's perspective.**

**When SessionStart fires.** Claude Code emits SessionStart on `startup` (new session), `resume` (`/resume`), `clear` (`/clear`), `compact` (compaction). The coord hook (`src/hooks/session_start.sh:151-239`) branches on `input.source` and inserts/refreshes the session row, marks the `.active` file.

**Codex equivalent.** Codex DOES emit `SessionStart` per the docs (https://developers.openai.com/codex/hooks#sessionstart). Source field: `startup` or `resume`. So a Codex SessionStart hook can register a Codex session into the same `sessions.json`.

**If Codex lacks SessionStart in some configurations (defensive plan).** Per the docs SessionStart IS supported. But if a particular Codex deployment had it disabled, the cleanest fallback registration site is the **first PreToolUse**: the hook checks `coord_is_participant` and if missing, lazily registers the session (mirrors `session_start.sh`'s startup branch). This is also the recovery path for the existing Phase 1 anomaly "startup-without-prior-row" branch (`session_start.sh:159-160`).

**Required adaptations:**
- `session_start.sh:91` reads `.source` ∈ `startup|resume|clear|compact`. Codex docs only enumerate `startup` and `resume`. The `clear` and `compact` branches might not fire from Codex; the existing `*` fallback (`session_start.sh:224-238`) catches unknown sources and treats as startup, so there's defensive coverage.
- `session_start.sh:123` `PID="$PPID"` — Codex's invocation model needs verification. If Codex spawns the hook as a direct child (parent = Codex agent process), PPID carries.
- The session's `agent: "codex"` field needs to be set at registration time. The Codex translator must inject `agent` into the FILTER jq template.

---

### 10. CLAUDE.md and agent instruction files

**Does the system depend on Claude reading CLAUDE.md for runtime behavior?**

**No.** Searched for `CLAUDE.md` references across `src/`:
- `docs/development-history/CLAUDE.md` — **gitignored** (per `.gitignore:42`); this is internal-only construction documentation, NOT loaded at runtime.
- Comments in source code (e.g., `pre_tool_use_any.sh:87`, `validator_prefilter.sh:32`) reference CLAUDE.md by name as documentation pointers, but these are comments — not code.
- `src/install.sh:217-235` and `:241-257` copy `MEDIATOR_REFERENCE.md` and `VALIDATOR_REFERENCE.md` to `.coord/{mediator,validator}/`. These are **the only runtime-loaded markdown files** — they are referenced inside the Mediator and Validator prompts (`src/lib/mediator_spawn.sh:198`, `validator_spawn.sh:211`) for the spawned `claude -p` to optionally Read.
- The Mediator's prompt explicitly tells the spawned agent: "For detailed mechanics... read `.coord/mediator/MEDIATOR_REFERENCE.md` when needed" (`mediator_spawn.sh:103`).

**Codex equivalent.** Codex's project-instruction file is `AGENTS.md` (the Codex / OpenAI conventions parallel). However, since coord does NOT depend on either CLAUDE.md or AGENTS.md at runtime, this is a non-issue for the integration. The `.coord/{mediator,validator}/*_REFERENCE.md` files are agent-agnostic technical specs and remain unchanged.

**One nuance:** the Mediator prompt is currently fed to `claude -p`. If we ever switch the Mediator backend to `codex exec`, the prompt's "use Bash + Read tools" instruction would need to become "use Bash + apply_patch" (no Read tool in Codex). But per Finding 6, we're recommending `claude -p` as a hard dep, so this nuance is moot for v1.

---

### 11. Test fixtures and bats files

**Counts:**
- 54 `.bats` files under `src/tests/unit/` (per `wc -l` of `ls`).
- 4 `.bats` files under `src/tests/integration/`: `cost_guards_modes.bats`, `phase5_e2e.bats`, `phase6_e2e.bats`, `spawn_helper_modes.bats`.
- 7 `.sh` driver files under `src/tests/manual/` (gitignored ship-gate drivers + `linux_probe.sh`, `two_session_warn.sh`).
- Fixtures under `src/tests/fixtures/` (some gitignored).

**Hardcoding analysis (which tests assume Claude payloads):**

Tests that **encode Claude Code's hook payload format** in their inputs (and thus belong in the Claude Code adapter test layer post-refactor):
- `unit/session_start.bats:25-27` — `INPUT_PARENT='{"session_id":"...","cwd":"...","hook_event_name":"SessionStart","source":"startup"}'`
- `unit/session_end.bats:17,30,44,...` — same pattern with `SessionEnd`.
- `unit/stop.bats:33-35,43,50` — `Stop` + `PreToolUse` Edit payloads.
- `unit/user_prompt_submit.bats:41-43` — `UserPromptSubmit` payloads.
- `unit/pre_tool_use_read.bats:36-38` — `PreToolUse` Read payloads.
- `unit/pre_tool_use_write.bats:33-38` — `PreToolUse` Write/Edit/NotebookEdit payloads.
- `unit/pre_tool_use_any.bats:33-35` — `PreToolUse` Bash payloads.
- `unit/post_tool_use_write.bats:28-30` — `PostToolUse` Write payloads.
- `unit/corruption_recovery.bats:57-138` — `SessionStart` + `PreToolUse` Bash payloads.
- `unit/install_register.bats:38-96` — asserts hook entries in `.claude/settings.local.json`.
- `unit/lockdown.bats:145-340` — emits deny for various hookEventName values (`PreToolUse`, `PostToolUse`, `SessionStart`, `SessionEnd`, `Stop`, `UserPromptSubmit`).
- `unit/mediator_flock_timeout.bats:150-183`, `unit/mediator_peer_review.bats:99`, `unit/post_tool_use_write_task_processor.bats:54-93`, `unit/self_task_reminder.bats:97-155`, `unit/stop_self_task_block_once.bats:60`, `unit/subagent_coord_wait_banner.bats:46-133`, `unit/subagent_filter.bats:33-128`, `unit/watchdog.bats:290-319`, `integration/phase5_e2e.bats`, `integration/phase6_e2e.bats:81-358`, `integration/spawn_helper_modes.bats:114`, `integration/cost_guards_modes.bats`.
- All `manual/linux_probe.sh:77-162`, `fixtures/two_session_warn/scenarios/01_basic_warn/timeline.sh:24-51`, `fixtures/phase3_ship_gate/scenarios/.../timeline.sh:13+19`.

**Tests that test the CORE (and stay-as-is post-refactor):**
- `unit/atomic_write.bats` — only touches the atomic-write layer, no hook payloads.
- `unit/log_event.bats` — only the event log mechanics. (Lines 38, 122 reference `tool=Edit`, `tool=Bash` but these are arbitrary log payload values, not hook input.)
- `unit/hash.bats`, `unit/cycle_detection.bats`, `unit/cycle_detection_task_graph.bats`, `unit/state_query.bats`, `unit/wait_queue.bats`, `unit/wait_backend.bats`, `unit/watchdog_cache.bats`, `unit/validator_cache.bats`, `unit/validator_prefilter.bats`, `unit/validator_spawn.bats`, `unit/spawn_helper.bats`, `unit/cost_guards.bats`, `unit/critical_bypass.bats`, `unit/mediator_spawn.bats`, `unit/mediator_corrupt_state_migration.bats`, `unit/mediator_cycle_handling.bats`, `unit/mediator_gc.bats`, `unit/coord_health.bats`, `unit/coord_status.bats`, `unit/coord_mediate_cli.bats`, `unit/coord_self_delegate.bats`, `unit/coord_task_open.bats`, `unit/coord_wait.bats`, `unit/notify_waiters_diff.bats`, `unit/read_snapshots.bats`, `unit/head_tracking.bats`, `unit/participant.bats`, `unit/self_tasks.bats`, `unit/verdict_apply.bats`, `unit/bats_meta.bats`.

**Which tests need parallel Codex variants:**
- `unit/install_register.bats` — needs a `unit/codex_install_register.bats` asserting Codex hook entries land in `.codex/hooks.json`.
- `unit/session_start.bats` — needs a Codex variant feeding Codex-shaped SessionStart JSON.
- `unit/pre_tool_use_write.bats` + `unit/post_tool_use_write.bats` — need Codex variants exercising `apply_patch` and the agent-belief-from-patch read-set replacement.
- `unit/pre_tool_use_any.bats` — Codex variant for the `*` matcher path.
- `unit/lockdown.bats` — already covers all hook event names; would need duplicates for Codex-shaped inputs.
- `unit/subagent_filter.bats` — Codex equivalent depends on whether Codex has subagents (Open Question H1).
- `integration/phase5_e2e.bats` and `phase6_e2e.bats` — Codex parallels.

**Which tests can stay Claude-only:** all the install/hook-entry-shape and Claude-payload-decoding tests stay under the Claude Code adapter test directory. Tests of `validator_spawn.sh`, `mediator_spawn.sh`, `task_processor.sh` (currently using Claude binary) stay agent-internal since the spawn target is always Claude.

**Disposition:** the 54 unit + 4 integration bats files split roughly 60/40 between adapter-coupled and core-pure tests. Post-refactor: ~30 files relocate to `src/adapters/claude-code/tests/`, ~24 stay at `src/core/tests/`, and a parallel ~10-15 file `src/adapters/codex/tests/` is added.

---

### 12. Documentation references to "Claude Code" / "Claude"

**Hard references** (this is the Claude Code adapter — keep):
- `README.md:3, 5-9, 11, 17, 20-24, 49-51, 73, 87, 96` — every paragraph.
- `CONTRIBUTING.md:3, 6, 36-37, 51, 56, 73`.
- `package.json:3, 19-25` — keywords + description.
- `src/install.sh:9-12, 50-56, 397-444, 488-507, 524-539` — installer messaging + jq target.
- `src/hooks/*.sh` headers — every hook says "Claude Code <event-name> hook".
- `src/lib/MEDIATOR_REFERENCE.md`, `src/lib/VALIDATOR_REFERENCE.md` — title says "Phase X <Name> Technical Reference" but body refers to "Claude Code coordination system" in places.
- `bin/parallel-sessions:16, 33` — npm wrapper README text.

**Soft references** (could be generalized):
- `src/lib/spawn_helper.sh:1-46` — comment "claude binary routing" — should become "coord agent backend routing" eventually.
- `src/lib/cost_guards.sh:30-33` — comment "real-claude spawn sites" — still accurate (we recommend keeping `claude -p`).
- Many `src/lib/*.sh` comments reference "the hook" generically.

**Plan:**
- Rename none of the public-facing docs (`README.md`, `CONTRIBUTING.md`) for the v1 single-agent shape. They are accurate today.
- For the v2 cross-agent narrative: `README.md` headline becomes "Multi-session coordination for AI coding agents" with a "Supported agents: Claude Code, OpenAI Codex CLI" subhead. The body explains the coordination layer and adapters.
- `package.json` keywords add `codex`, `openai-codex`.
- `src/lib/MEDIATOR_REFERENCE.md` / `VALIDATOR_REFERENCE.md` — the body says "Claude Code coordination system"; if Mediator backend stays `claude -p`, leave verbatim (the spawned agent IS Claude regardless of trigger). If we ever add Codex backend, generalize.

---

### 13. Path conventions

| Path | Scope | Disposition |
|---|---|---|
| `.coord/` | Project-internal — shared across agents | **STAYS shared** (Codex sessions register into the same `.coord/sessions.json`). No parameterization needed. Hard-coded throughout: `coord_resolve_root` (every hook), `install.sh:78`, `bin/parallel-sessions`. |
| `.claude/settings.local.json` | Claude Code-specific config target | **Adapter-specific**; Codex equivalent is `.codex/hooks.json` (or `~/.codex/config.toml`). Hardcoded in `install.sh:79`. |
| `.coord/hooks/` | Installer-copied hook scripts | **Stays shared physical location**. Internally split into `claude-code/` and `codex/` subdirs after refactor (e.g., `.coord/hooks/claude-code/session_start.sh`). The settings.local.json command pointers update accordingly. Alternatively keep flat and use translator-prefixed names (`.coord/hooks/cc_session_start.sh`, `.coord/hooks/cx_session_start.sh`). |
| `.coord/lib/` | Installer-copied libraries | **Stays shared**; libraries are agent-agnostic post-refactor. |
| `.coord/bin/coord` | Coord CLI | **Stays shared**. |
| `.coord/agents/` | Empty placeholder created by installer (`install.sh:199`) | Currently unused; could become per-agent config (e.g., `.coord/agents/claude-code/`, `.coord/agents/codex/`). |
| `~/.codex/config.toml` (Codex global) | Codex global config | Avoid touching by default; prefer project-local `.codex/hooks.json`. Doc'd in OQ H4. |
| `~/.codex/hooks.json` | Codex global hooks | Same as above. |
| `<repo>/.codex/hooks.json` | Codex project-local hooks | **Adapter target for Codex install**. |
| `<repo>/.codex/config.toml` | Codex project-local config | Optional — only needed if `[features] codex_hooks = true` requires project-level enabling and global enabling is undesired. |
| `CLAUDE_PROJECT_DIR` env | Used by `coord_resolve_root` | Keep but also accept `CODEX_PROJECT_DIR` (if Codex defines one — see OQ H3). |
| `CLAUDE_COORD=1` env | Participation gate | Either rename to `COORD_ENABLED=1` shared, or add a parallel `CODEX_COORD=1` and have hooks accept either. The participation gate is binary; using a single shared name (`COORD_ENABLED`) is cleaner. See OQ H6. |

---

### 14. Three-mode test switch (`COORD_TEST_MODE`)

**Resolution path** (`src/lib/spawn_helper.sh:59-107`):
- Env `COORD_TEST_MODE` ∈ `mock|semi|realistic`. Default: `mock`.
- Invalid value → fail-closed to `mock` + warning + `COORD_TEST_MODE_INVALID` event.
- Cached per-process.

**Routing matrix** (`spawn_helper.sh:109-147`):
| Site | mock | semi | realistic |
|---|---|---|---|
| mediator | mock | real | real |
| validator | mock | mock | real |
| task_processor | mock | real | real |

**Wiring at the spawn sites** (`mediator_spawn.sh:267-292`, `validator_spawn.sh:309-337`, `task_processor.sh:_coord_tp_real_claude_spawn:233-374`):
1. Resolve mode.
2. Check `coord_spawn_helper_should_use_real_claude <site>`.
3. If real-claude: check cost guard (`coord_cost_guards_check <site>`); rate-limited → degrade.
4. If mock: return mock-default literal (task_processor) OR rely on a mock binary on PATH (mediator + validator).

**Stress harness** (`scripts/stress_semi.sh:53-81`):
- Exports `COORD_TEST_MODE=semi`, runs all phase ship-gate drivers, then a focused cost-guard exercise.
- `scripts/stress_realistic.sh` does the same with `realistic`.

**How a Codex realistic mode would interact.**

Two design options:

**Option A (recommended): COORD_TEST_MODE remains agent-orthogonal.** It selects whether the spawn sites use mock vs `claude -p`, regardless of which agent (Claude or Codex) triggered the spawn. No change to spawn_helper. Cost-guard tunables stay claude-specific.

**Option B: COORD_TEST_MODE becomes per-agent.** New env `COORD_TEST_MODE_CLAUDE=mock|semi|realistic` and `COORD_TEST_MODE_CODEX=mock|semi|realistic`, fallback to `COORD_TEST_MODE` if unset. Spawn helper consults the relevant per-agent mode. Useful only if we ever support `codex exec` as a backend (Open Question H8).

**Recommendation: Option A for v1.** Maintains the existing routing matrix as-is; Codex sessions trigger the same Mediator/Validator spawns to `claude -p`.

`coord_spawn_helper_should_use_real_claude` should be renamed to `coord_spawn_helper_should_use_real_backend` if/when Option B happens.

---

### 15. Edge cases and hidden coupling

1. **`session_start.sh:123` PPID assumption.** Captures Claude Code's parent PID for liveness. If Codex's process model differs (hook child of a launcher, not the agent), the wrong PID is recorded and watchdog signals 1 + 3 misfire. **Verify via experiment: spawn a Codex session, inspect `sessions.json::sessions.<sid>.pid`, compare to actual Codex agent process via `ps`.**

2. **`subagent_filter.sh:49` reads `.agent_type`.** Codex hook docs do not specify a `agent_type` field. If Codex emits hooks for its subagents using a different field name (e.g., `agent_id`, `parent_session_id`, or no field at all), the filter won't catch them and Codex subagents would corrupt the parent's read-set or take locks under a sub-id. **Open Question H1.**

3. **`pre_tool_use_any.sh:96` `F015_TOOL = "Bash"` special-case.** Codex's Bash tool is also named `Bash`, so this carries — but the body checks for `coord wait` command prefix. Codex Bash command serialization should be verified; the `tool_input.command` field name is documented for Codex too.

4. **`post_tool_use_write.sh:180-189` line-range parsing.** Reads `tool_response.start_line` etc. Codex's PostToolUse for `apply_patch` does not have these fields documented. The fall-through is `EDIT_START=0, EDIT_END=0` → `force_conflict=1` in task processor → all delegated tasks become CONFLICT. **For Codex, line ranges must be extracted from the patch's `@@` headers.**

5. **`install.sh:312-313` wait_backend autodetect at install time.** The detected backend is baked into `config.json` at install time. If a Codex install runs on a host where the previous Claude install detected `polling` and now `fswatch` is installed, `--repair` re-detects. This is agent-orthogonal; no Codex-specific concern.

6. **`coord_resolve_root` env-var precedence: `COORD_DIR` > `CLAUDE_PROJECT_DIR` > `git rev-parse`.** If a Codex session sets `CLAUDE_PROJECT_DIR` (unlikely) it would still work. If Codex sets `CODEX_PROJECT_DIR` (TBD per OQ H3), the resolver should accept either.

7. **The `.coord/sessions/<sid>.env` shell-safe KV file** (`user_prompt_submit.sh:159-162`) — only stores `COORD_PROMPT_ID`. Agent-agnostic, not consumed by spawned subprocesses (the spawn helpers don't source this file). Safe.

8. **The Mediator's prompt section 2 constraint #2 says "Use Bash and Read tools only"** (`mediator_spawn.sh:91-93`). Since the Mediator IS `claude -p`, this is internally consistent. The Mediator may need to inspect a file the Codex session wrote — `Read` tool works.

9. **`bin/coord` `cmd_wait` (`src/bin/coord:cmd_wait:279-405`) is a shell command.** It runs in the user's terminal regardless of which agent's `Bash` tool invokes it. Agent-agnostic by design.

10. **`coord_log_event_sync` (`src/lib/log_event.sh:136-157`)** is used in `cmd_wait`'s SIGINT trap. Foreground flock+append. Agent-agnostic.

11. **The `pre_tool_use_write.sh` deny banner text is a multi-line jq-encoded string with embedded newlines** (`pre_tool_use_write.sh:464-471`). Claude Code preserves the newlines through `permissionDecisionReason`. Codex docs do not explicitly state how multi-line `permissionDecisionReason` is rendered. **Verify in integration testing.**

12. **`pre_tool_use_write.sh:524`** — the early `coord_log_event kind=WRITE` runs BEFORE the deny check. If Codex denies and the agent retries 5x, we get 5 `WRITE` events for the same intent. Acceptable noise, but the Mediator's "recent_cycle_count" calculation in `cycle_detection.sh:434-450` could be affected by per-agent retry frequency differences. Low risk.

13. **`session_end.sh:147-154`** does a defensive `.locks |= with_entries(select(.value.session != $sid))` after the per-lock release loop. This is agent-agnostic but the comment talks about "session_end has always done."

14. **The Watchdog cache invalidate-dead pass (`watchdog_cache.sh:227-245`) is wired to be called on session_start.** Per `T3.05 wiring` per source comment but the actual wiring is at `session_start.sh` — let me check… Actually grepping, this appears to be **not currently wired**: `session_start.sh` does not call `coord_watchdog_cache_invalidate_dead`. This is a latent issue today, not a Codex-specific one — but worth flagging for a future fix.

15. **`pre_tool_use_any.sh:331-411` verdict-file consumer** does file system listing of `.coord/mediator/verdict/*.json` and lex-sorts. Each session-id has a per-session pointer file at `.coord/sessions/<sid>.last_consumed_verdict`. Agent-agnostic.

---

## D. Refactor map (proposed file moves and new files)

### Source-tree split

```
src/
├── core/                                # NEW — agent-agnostic
│   ├── lib/
│   │   ├── atomic_write.sh              ← from src/lib/atomic_write.sh
│   │   ├── log_event.sh                 ← src/lib/log_event.sh
│   │   ├── participant.sh               ← src/lib/participant.sh
│   │   ├── lockdown.sh                  ← src/lib/lockdown.sh
│   │   ├── hash.sh                      ← src/lib/hash.sh
│   │   ├── head_tracking.sh             ← src/lib/head_tracking.sh
│   │   ├── state_query.sh               ← src/lib/state_query.sh
│   │   ├── wait_queue.sh                ← src/lib/wait_queue.sh
│   │   ├── wait_backend.sh              ← src/lib/wait_backend.sh
│   │   ├── notify_waiters.sh            ← src/lib/notify_waiters.sh
│   │   ├── self_tasks.sh                ← src/lib/self_tasks.sh
│   │   ├── cycle_detection.sh           ← src/lib/cycle_detection.sh
│   │   ├── critical_check.sh            ← src/lib/critical_check.sh
│   │   ├── verdict_apply.sh             ← src/lib/verdict_apply.sh
│   │   ├── watchdog.sh                  ← src/lib/watchdog.sh
│   │   ├── watchdog_cache.sh            ← src/lib/watchdog_cache.sh
│   │   ├── mediator_pending.sh          ← src/lib/mediator_pending.sh
│   │   ├── mediator_spawn.sh            ← src/lib/mediator_spawn.sh
│   │   ├── validator_spawn.sh           ← src/lib/validator_spawn.sh
│   │   ├── validator_cache.sh           ← src/lib/validator_cache.sh
│   │   ├── validator_prefilter.sh       ← src/lib/validator_prefilter.sh
│   │   ├── read_snapshots.sh            ← src/lib/read_snapshots.sh
│   │   ├── task_processor.sh            ← src/lib/task_processor.sh
│   │   ├── spawn_helper.sh              ← src/lib/spawn_helper.sh
│   │   ├── cost_guards.sh               ← src/lib/cost_guards.sh
│   │   ├── coord_mediate.sh             ← src/lib/coord_mediate.sh
│   │   ├── normalized_events.sh         # NEW — defines core event types
│   │   ├── MEDIATOR_REFERENCE.md        ← src/lib/MEDIATOR_REFERENCE.md
│   │   └── VALIDATOR_REFERENCE.md       ← src/lib/VALIDATOR_REFERENCE.md
│   ├── bin/
│   │   └── coord                        ← src/bin/coord
│   └── tests/
│       ├── unit/                        ← agent-agnostic bats from src/tests/unit/
│       │   (atomic_write, hash, state_query, wait_queue, wait_backend, watchdog,
│       │    cycle_detection, validator_prefilter, validator_cache, etc.)
│       └── helpers/
│           └── common.bash              ← src/tests/helpers/common.bash
│
├── adapters/                            # NEW
│   ├── claude-code/
│   │   ├── hooks/
│   │   │   ├── session_start.sh         ← src/hooks/session_start.sh (translator + delegate)
│   │   │   ├── session_end.sh           ← src/hooks/session_end.sh
│   │   │   ├── stop.sh                  ← src/hooks/stop.sh
│   │   │   ├── user_prompt_submit.sh    ← src/hooks/user_prompt_submit.sh
│   │   │   ├── pre_tool_use_any.sh      ← src/hooks/pre_tool_use_any.sh
│   │   │   ├── pre_tool_use_read.sh     ← src/hooks/pre_tool_use_read.sh
│   │   │   ├── pre_tool_use_write.sh    ← src/hooks/pre_tool_use_write.sh
│   │   │   └── post_tool_use_write.sh   ← src/hooks/post_tool_use_write.sh
│   │   ├── lib/
│   │   │   ├── translator.sh            # NEW — Claude Code event → core normalized event
│   │   │   └── subagent_filter.sh       ← src/lib/subagent_filter.sh
│   │   ├── install.sh                   # NEW — Claude-Code-specific config writes
│   │   └── tests/
│   │       └── unit/                    ← Claude-payload-coupled bats
│   │
│   └── codex/                           # NEW
│       ├── hooks/
│       │   ├── session_start.sh         # NEW — translator + delegate to core
│       │   ├── stop.sh                  # NEW
│       │   ├── user_prompt_submit.sh    # NEW
│       │   ├── pre_tool_use_any.sh      # NEW (matcher *)
│       │   ├── pre_tool_use_apply_patch.sh # NEW (matcher ^apply_patch$)
│       │   ├── pre_tool_use_bash.sh     # NEW (matcher ^Bash$)
│       │   ├── permission_request.sh    # NEW — optional; routes to lockdown gate
│       │   ├── post_tool_use_apply_patch.sh # NEW (matcher ^apply_patch$)
│       │   └── (NO session_end — Codex docs do not enumerate; see OQ H5)
│       ├── lib/
│       │   ├── translator.sh            # NEW — Codex event → core normalized event
│       │   ├── apply_patch_parser.sh    # NEW — extract paths + pre/post images from apply_patch payload
│       │   └── subagent_filter.sh       # NEW (or stub if no Codex subagents)
│       ├── install.sh                   # NEW — writes .codex/hooks.json
│       └── tests/
│           └── unit/                    ← Codex-payload-coupled bats
│
└── install.sh                           # REWRITE — dispatches to adapters based on flags / detection
```

### `src/install.sh` (rewritten)
- Detect/accept flags: `--with-claude-code`, `--with-codex`, default `--with-claude-code` only (back-compat).
- Run `src/adapters/claude-code/install.sh` if Claude requested.
- Run `src/adapters/codex/install.sh` if Codex requested.
- Materialize `.coord/` once (shared).
- Smoke test for each requested adapter.

### `src/core/lib/normalized_events.sh` (new)
Defines abstract event-type constants and the contract:
```bash
# Normalized event types (string sentinels)
COORD_EVENT_SESSION_START=SESSION_START
COORD_EVENT_SESSION_END=SESSION_END
COORD_EVENT_STOP=STOP
COORD_EVENT_PROMPT_SUBMIT=PROMPT_SUBMIT
COORD_EVENT_PRE_TOOL_ANY=PRE_TOOL_ANY
COORD_EVENT_PRE_FILE_READ=PRE_FILE_READ
COORD_EVENT_PRE_FILE_WRITE=PRE_FILE_WRITE
COORD_EVENT_POST_FILE_WRITE=POST_FILE_WRITE
COORD_EVENT_PRE_BASH=PRE_BASH
COORD_EVENT_POST_BASH=POST_BASH
COORD_EVENT_PERMISSION_REQUEST=PERMISSION_REQUEST   # Codex-only
```

### `src/adapters/claude-code/lib/translator.sh` (new)
Functions:
- `coord_cc_translate_event <hook_event_name> <tool_name>` → normalized event.
- `coord_cc_extract_session_id <input_json>` → sid.
- `coord_cc_extract_file_path <input_json>` → path (Claude's `tool_input.file_path` // `tool_input.notebook_path`).
- `coord_cc_extract_subagent <input_json>` → returns rc 0 if `.agent_type` non-empty.
- `coord_cc_extract_edit_range <input_json>` → `start_line\tend_line` from PostToolUse payload.
- `coord_cc_emit_deny <reason> <hook_event_name>` → `{hookSpecificOutput: {hookEventName, permissionDecision: "deny", permissionDecisionReason: $reason}}`.
- `coord_cc_emit_additional_context <text> <hook_event_name>` → `{hookSpecificOutput: {hookEventName, additionalContext: $text}}`.

### `src/adapters/codex/lib/translator.sh` (new)
Same shape, Codex-specific:
- `coord_cx_translate_event <hook_event_name> <tool_name>`.
- `coord_cx_extract_session_id` (Codex `session_id` field — same name).
- `coord_cx_extract_file_path` — for `apply_patch`: parse path from `tool_input.command` patch text via `apply_patch_parser.sh`. For `Bash`: returns empty.
- `coord_cx_extract_subagent` — TBD per OQ H1.
- `coord_cx_extract_edit_range` — for `apply_patch`: parse `@@` headers from patch.
- `coord_cx_extract_pre_image` — extract the agent's pre-edit content from the patch (for stage-2/3 validator pipeline).
- `coord_cx_emit_deny <reason> <hook_event_name>` — same shape as Claude per Codex docs.
- `coord_cx_emit_additional_context <text> <hook_event_name>` — same shape.

### `src/adapters/codex/lib/apply_patch_parser.sh` (new, critical)
Parses Codex's `apply_patch` payload (`tool_input.command` per docs). The exact parser depends on Codex's apply_patch format (Open Question H2). Conservatively assumes a unified-diff-with-context format:
```
*** Update File: /abs/path/to/file
@@ ...
 unchanged context
-removed line
+added line
 unchanged context
```
Functions:
- `coord_cx_apply_patch_paths <patch>` → newline-separated absolute paths.
- `coord_cx_apply_patch_pre_image <patch> <path>` → reconstructs the pre-edit file content from context lines.
- `coord_cx_apply_patch_edit_range <patch> <path>` → `start_line\tend_line` from `@@ -<start>,<count>` headers.
- `coord_cx_apply_patch_pre_image_hash <patch> <path>` → sha256 of pre-image.

This is the single highest-risk new component for the Codex adapter (Risk Register I3).

---

## E. State schema delta

### Today (`schema_version: "1.0"`)
```json
{
  "schema_version": "1.0",
  "sessions": { "<sid>": { "state", "pid", "pid_lstart", "registered_at",
                            "last_activity_at", "git_head", "prompt_id", "script_version" } },
  "locks": { ... },
  "wait_queues": { ... },
  "read_sets": { ... },
  "notifications": { ... },
  "self_tasks": { ... },
  "anomaly_votes": { ... },
  "task_graph": { ... }
}
```

### Proposed (`schema_version: "1.1"` — additive only)
```json
{
  "schema_version": "1.1",
  "sessions": {
    "<sid>": {
      "state": "...",
      "pid": <int>,
      "pid_lstart": "...",
      "registered_at": "...",
      "last_activity_at": "...",
      "git_head": "...",
      "prompt_id": null | "...",
      "script_version": "...",
      "agent": "claude_code" | "codex",                  // NEW
      "agent_version": "..." | null,                     // NEW (optional)
      "agent_specific": {                                // NEW (optional, opaque per adapter)
        "transcript_path": "...",                        // Codex example
        "model": "gpt-5-codex"                           // Codex example
      }
    }
  },
  ...
}
```

### Rationale per added field

| Field | Why | Who reads it |
|---|---|---|
| `agent` | Watchdog / Mediator may want per-agent eviction policy; deny banners may want per-agent CLI hint phrasing if it ever differs; events.jsonl gets agent dimension for debugging. | Hooks (translator), Mediator prompt context, `coord status`, watchdog. |
| `agent_version` | Diagnostics — flag schema-incompatibility scenarios when Claude/Codex CLI updates change payload shape. | Optional; not required in v1. |
| `agent_specific` | Per-adapter scratch (e.g., Codex's `transcript_path`) so adapters don't need separate sidecar files. Opaque to core. | The adapter that produced it; surfaced in `coord status`. |

### Backward compatibility
- All readers MUST tolerate sessions without the new fields (treat as `agent: "claude_code"` for legacy rows). Implement via `jq`'s `// "claude_code"` fallback in any code that reads `agent`.
- `schema_version` bump is **informational only**. `bin/coord:cmd_health` (`src/bin/coord:106-165`) does NOT enforce strict version match today; the bump is a documentation aid.
- No migration script needed — 1.0 sessions are fully compatible with 1.1 readers.

### Required code edits to populate `agent`
- `src/adapters/claude-code/hooks/session_start.sh` — when assembling the FILTER jq template, add `agent: "claude_code"` to the `.sessions[$sid] = {...}` literal at lines (currently `session_start.sh:162-171, 177-186, 226-235`).
- `src/adapters/codex/hooks/session_start.sh` (new) — set `agent: "codex"`.

---

## F. Adapter interface specification

### Adapter contract (each adapter SHALL provide):

#### 1. `<adapter>_translate_event(hook_event_name, tool_name) → core_event`
- Input: the hook event name string (`SessionStart`, `PreToolUse`, etc.) and the tool name (may be empty for non-tool events).
- Output: one of `COORD_EVENT_SESSION_START | COORD_EVENT_SESSION_END | COORD_EVENT_STOP | COORD_EVENT_PROMPT_SUBMIT | COORD_EVENT_PRE_TOOL_ANY | COORD_EVENT_PRE_FILE_READ | COORD_EVENT_PRE_FILE_WRITE | COORD_EVENT_POST_FILE_WRITE | COORD_EVENT_PRE_BASH | COORD_EVENT_POST_BASH | COORD_EVENT_PERMISSION_REQUEST` or empty.
- Errors: empty output on unknown combinations (caller falls open).

#### 2. `<adapter>_extract_session_id(input_json) → string`
- Pulls `.session_id` (both Claude and Codex use this name).

#### 3. `<adapter>_extract_file_path(input_json) → string`
- Claude: `.tool_input.file_path // .tool_input.notebook_path // ""`.
- Codex (`apply_patch`): parse path from `.tool_input.command` patch text via `apply_patch_parser.sh`. Multiple paths possible — caller iterates.

#### 4. `<adapter>_extract_pre_image_hash(input_json, file_path) → hash | "" `
- Claude: returns the most-recent `is_latest:true` hash for `<file_path>` from `read_sets[<sid>]`. Empty if no prior Read.
- Codex: parses the agent's pre-edit content from the patch and hashes it. Always available for `apply_patch` events. Empty for non-apply_patch events.

#### 5. `<adapter>_extract_subagent(input_json) → rc 0|1`
- Claude: rc 0 if `.agent_type != ""`.
- Codex: rc 0 if `<TBD per OQ H1>`. Stub returns rc 1 in v1.

#### 6. `<adapter>_extract_edit_range(input_json, file_path) → "start\tend"`
- Claude PostToolUse: `.tool_response.start_line` etc.
- Codex PostToolUse `apply_patch`: parse `@@ -<start>,<count>` headers; emit `start\tend`.
- Empty `0\t0` → caller treats as whole-file edit (force CONFLICT in task processor).

#### 7. `<adapter>_emit_deny(reason, hook_event_name) → JSON to stdout`
- Both Claude and Codex use `{hookSpecificOutput: {hookEventName, permissionDecision: "deny", permissionDecisionReason}}` for `PreToolUse`. Codex's `PermissionRequest` event uses `decision: { behavior: "deny", message }` instead — **different shape**.

#### 8. `<adapter>_emit_additional_context(text, hook_event_name) → JSON to stdout`
- Both: `{hookSpecificOutput: {hookEventName, additionalContext}}`.

#### 9. `<adapter>_extract_session_source(input_json) → "startup" | "resume" | "clear" | "compact"`
- Claude: all four. Codex: `startup` and `resume` (per docs); `clear` and `compact` not enumerated — fall to `startup` defensively.

#### 10. `<adapter>_extract_prompt_text(input_json) → string`
- Both: `.prompt`.

### Error handling
- Translators MUST be fail-soft: on parse failure of input JSON, return empty / rc=1 and exit 0 silently. The hook entry point's `[ "${COORD_ENABLED:-}" != "1" ] && exit 0` and `coord_is_participant` checks handle the no-op case.
- Translators do NOT log on every parse failure (would flood events.jsonl); only surface on first-failure-per-process via a process-scoped guard variable.

### Where the contract is invoked
- Each adapter hook script's "main" body sources its `translator.sh` immediately after `core/lib/atomic_write.sh` etc., then calls the translator functions to build the same downstream call sequence as today. The downstream core lib functions (lockdown, atomic_edit, mediator_pending, etc.) consume normalized inputs.

---

## G. Codex CLI hook system — research notes

Source: https://developers.openai.com/codex/hooks (single-page documentation).

### Hook event names (confirmed)
- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest` (new — no Claude analogue; fires when Codex is "about to ask for approval, such as a shell escalation")
- `PostToolUse`
- `Stop`

**Notable absences from Codex hook docs:**
- **No `SessionEnd` event** documented. Implication: a Codex session's locks are released only via `Stop` (or via Watchdog after timeout) — there is no graceful-exit fallback. The current `session_end.sh` defensive cleanup (`session_end.sh:106-138`) has no Codex equivalent. **Open Question H5.**
- **No `PreCompact` event** — Claude has compact source; Codex's lifecycle treats compact differently (or not at all).

### Config file format and locations
Per `https://developers.openai.com/codex/hooks#where-codex-looks-for-hooks`:
1. `~/.codex/hooks.json` (global)
2. `~/.codex/config.toml` with inline `[hooks]` (global)
3. `<repo>/.codex/hooks.json` (project-local) — **recommended target for our installer**
4. `<repo>/.codex/config.toml` with inline `[hooks]`
- "If a single layer contains both `hooks.json` and inline `[hooks]`, Codex merges them and warns at startup."
- Feature gate REQUIRED in config: `[features] codex_hooks = true`.

### Hook script invocation contract
Stdin is JSON with these fields (per `#common-input-fields`):
| Field | Notes |
|---|---|
| `session_id` | Same field name as Claude. |
| `transcript_path` | `string \| null`. Path to session transcript. **Claude does not provide this.** |
| `cwd` | Working directory. Same as Claude. |
| `hook_event_name` | E.g., `SessionStart`. Same as Claude. |
| `model` | Active model slug (e.g., `gpt-5-codex`). **Claude does not provide this in hook input.** |
| `turn_id` | Present in turn-scoped events (PreToolUse, PostToolUse, PermissionRequest, UserPromptSubmit, Stop). **Claude does not have this.** |
| `tool_name` | E.g., `Bash`, `apply_patch`, `mcp__server__tool`. Same shape as Claude. |
| `tool_input` | Object with tool-specific fields. Codex Bash + apply_patch use `.command`. |

### Tool names
Per `#matcher-patterns`:
- `Bash` — shell command execution.
- `apply_patch` — file edits (also matched by aliases `Edit` or `Write` per Codex). **CRITICAL: Codex's apply_patch is the file-write equivalent.**
- MCP tools: `mcp__<server>__<tool>` (e.g., `mcp__filesystem__read_file`).
- **No standalone `Read` tool.** File reads happen via apply_patch's pre-edit context or via MCP tools.

### apply_patch payload shape
Per docs `#pretooluse`:
```json
{
  "tool_name": "apply_patch",
  "tool_input": { "command": "..." }
}
```
**The exact format of `command` (string with embedded patch? structured object?) is not fully specified in the public docs. Probably mirrors Codex's `apply_patch` CLI tool format.** Open Question H2.

The schema reference at `https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated` may have the exact shape — a follow-up read of the schema is needed before implementing the parser.

### Permission/deny mechanism

**Two different shapes depending on event:**

`PreToolUse` deny (mirrors Claude shape per docs example):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "..."
  }
}
```

`PermissionRequest` deny (different shape):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Blocked by repository policy."
    }
  }
}
```

Conflict resolution: "If multiple matching hooks return decisions, any `deny` wins."

**For our purposes:** the lock-held deny continues to use the `PreToolUse` shape (same as Claude). The `PermissionRequest` event is a NEW capability; we can optionally route it through the lockdown gate but otherwise leave it pass-through.

### SessionStart equivalent
Per `#sessionstart`: yes, fires with `source: "startup" | "resume"`. SessionStart accepts plain stdout as developer context OR JSON with `hookSpecificOutput.additionalContext`.

### Environment variables
**Not documented.** No equivalent to `CLAUDE_PROJECT_DIR` mentioned. Working directory is supplied via stdin's `cwd`. **Open Question H3.**

### Subagent semantics
**Not covered in hook docs.** Codex docs mention subagents as a feature elsewhere (`/codex/subagents`) but the hooks reference does not specify session_id inheritance, agent_type fields, or how hooks fire for nested agents. **Open Question H1.**

### Banner/additionalContext mechanism
Supported on `SessionStart`, `UserPromptSubmit`, `PostToolUse`. **NOT documented for `PreToolUse`** in the docs page (Claude DOES support it). Whether Codex supports `additionalContext` on `PreToolUse` is unclear; the docs example for `PreToolUse` only shows `permissionDecision`. **Risk:** our existing code emits `additionalContext` on `PreToolUse` from `pre_tool_use_any.sh` and stale-read warnings from `pre_tool_use_write.sh`. Need to verify Codex behavior.

### Hook timeout behavior
Default: **600 seconds** (Codex). Claude's default in our current install is **10 seconds** (`install.sh:432-444` `timeout: 10`). Different defaults — need to set Codex matchers to 10s explicitly.

### Exit code semantics
`0` = success/continue. `2` = block/deny with stderr as reason. (Same as Claude per Codex docs.)

### Output formats per event (`stdout` interpretation)
Per docs `#common-output-fields`:
| Event | Stdout text | Stdout JSON |
|---|---|---|
| `SessionStart` | "added as extra developer context" | `hookSpecificOutput.additionalContext` |
| `UserPromptSubmit` | "added as extra developer context" | `hookSpecificOutput.additionalContext` |
| `PreToolUse` | **ignored** | `hookSpecificOutput.{permissionDecision, permissionDecisionReason}` |
| `PermissionRequest` | (not specified) | `hookSpecificOutput.decision.{behavior, message}` |
| `PostToolUse` | **ignored** | `hookSpecificOutput.additionalContext` (and possibly block) |
| `Stop` | "invalid; expects JSON" | JSON shape TBD |

### Known gaps explicitly listed in Codex docs
- "WebSearch / non-shell tool hooks: not yet supported."
- "Unified_exec tool interception: noted as incomplete."

---

## H. Open questions

| # | Question | Why it matters | Recommended initial answer |
|---|---|---|---|
| H1 | Does Codex emit hooks for subagent activity? If so, with what discriminator field (analogue to Claude's `agent_type`)? | Without a subagent filter, a Codex subagent's `apply_patch` could acquire a lock under a sub-id, breaking the parent's coordination. | Stub `coord_cx_extract_subagent` to always return rc=1 (treat all events as parent). Audit via integration testing; if subagent activity bleeds in, add discriminator. |
| H2 | What is the exact format of Codex's `apply_patch` `tool_input.command`? Does it include file paths in a parseable form? Does it include the pre-edit file content or only diff hunks? | This is the foundation of the "agent-belief drift detection" path that replaces Claude's read-tracking for Codex. | **READ `https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated` schema files BEFORE implementing the parser.** Until the schema is confirmed, write `apply_patch_parser.sh` to a conservative subset (extract paths from `*** Update File:` headers; reconstruct pre-image from context lines). Add fixtures under `src/adapters/codex/tests/fixtures/apply_patch/`. |
| H3 | Does Codex set any environment variable equivalent to `CLAUDE_PROJECT_DIR` when invoking hooks? | `coord_resolve_root` currently relies on `CLAUDE_PROJECT_DIR` first then `git rev-parse`. Codex hooks may run from arbitrary `cwd`. | Read `cwd` from stdin JSON instead of relying on env. Already supported (`session_start.sh:92`). For the pre-cwd-parse path, fall through to git-toplevel. |
| H4 | Should our installer write to `~/.codex/config.toml` (global) or only `<repo>/.codex/hooks.json` (project-local)? | Global writes affect all repos; project-local is contained. | **Project-local only by default.** Global only via `--global` opt-in (mirrors `--bypass-permissions`). |
| H5 | Codex has no `SessionEnd` event. How do we recover locks held by a gracefully-exited Codex session? | Without SessionEnd, only `Stop` releases locks. If `Stop` doesn't fire (e.g., user kills with SIGTERM), the lock persists until the Watchdog catches it (10+ minutes). | (a) Watchdog already covers crashed sessions. (b) Document the semantic difference: Codex sessions release via `Stop` or via Watchdog; never via SessionEnd. (c) No code change needed beyond not registering a SessionEnd hook for Codex. |
| H6 | Should `CLAUDE_COORD=1` be renamed to `COORD_ENABLED=1` (shared) or supplemented with `CODEX_COORD=1` (per-agent)? | The participation gate is the entry point. Two names is more verbose; one shared name is cleaner. | **Shared `COORD_ENABLED=1`.** Hooks accept either `COORD_ENABLED` OR `CLAUDE_COORD` (legacy alias) for back-compat. Document `COORD_ENABLED` as canonical going forward. |
| H7 | Should Codex's `PermissionRequest` event be wired through coord at all, or left pass-through? | If we don't hook it, Codex's escalation prompts run unfettered. If we do, we have a third deny location which breaks the 2-location invariant. | **Leave pass-through in v1.** Document as future-work. The 2-location invariant (`pre_tool_use_write.sh` lock-held branch + `lockdown.sh` global pause) stays intact. |
| H8 | Should the Mediator/Validator/Task-Processor backends ever be `codex exec` instead of `claude -p`? | Single backend (claude) keeps complexity low; per-trigger backend would let Codex-only users avoid installing Claude. | **Single backend (`claude -p`) for v1.** Document hard dep on Claude binary. Defer dual-backend to v2 if user demand emerges. |
| H9 | Does Codex's `additionalContext` on `PreToolUse` work? The docs example does not show it. | Our existing code emits `additionalContext` from `pre_tool_use_any.sh` and stale-read banners. If Codex ignores it, we lose drift warnings under Codex. | Verify in integration testing. If Codex ignores, fall back to stderr (Claude also surfaces stderr). The drift signal still gets through via the deny path. |
| H10 | What's the right Codex matcher syntax — Claude uses `Write|Edit|NotebookEdit` (regex/alternation); Codex docs example uses `^Bash$`. | Mismatched syntax silently breaks matchers. | Use explicit anchored regex: `^Bash$`, `^apply_patch$`, `^mcp__`, `^.*$` (universal). Test by emitting matched events. |
| H11 | Codex hooks' default timeout is 600s; ours is 10s. What's the right value for Codex? | 10s may be too tight for the Codex agent's expectations; 600s is excessive. | Use 10s explicitly in the JSON config to match Claude's behavior. The hooks themselves are bounded by `flock -w 5` and per-script body. |
| H12 | Cross-agent banner phrasing — should the deny banner say "you are a Codex session denied by a Claude session"? | Could improve user troubleshooting, but adds adapter coupling to the deny banner producer (currently agent-agnostic at `pre_tool_use_write.sh:454-473`). | **Keep banner agnostic in v1.** Emit `holder_session: <sid_short>` plus `agent: <claude_code|codex>` in the events.jsonl payload only; user can `coord status` if they want to see the holder's agent. |

---

## I. Risk register (highest blast radius first)

| # | Risk | Blast radius | Mitigation |
|---|---|---|---|
| I1 | **Refactor breaks the existing Claude Code single-agent v1.** 645 unit tests + 48 integration tests + 24 ship-gate fixtures depend on the current `src/hooks/` layout and `src/lib/` paths. | Extreme. Production regressions. | Move files in stages with `git mv` (preserves history); update SOURCE-DIR resolution in every `. "$LIB_DIR/..."` source line; run full test surface after every commit; phase the move so each commit leaves the v1 green. |
| I2 | **Codex apply_patch parser produces wrong pre-image hash.** Validator pipeline runs on bad input → false-SAFE on real CRITICAL drifts → silent data loss. | High. Functional correctness of the drift detection. | Read Codex's apply_patch schema before implementing. Write 20+ fixture-driven unit tests covering: simple update, multi-file patch, file create, file delete, binary/encoding edge cases. Compare parser output against reference Codex execution. |
| I3 | **Codex subagent activity is not filtered.** A subagent's `apply_patch` acquires a lock under the sub-id — the parent's lock holder seems to be a phantom session. | Medium-high. Cross-agent coordination breakdown. | Until OQ H1 is answered, default-deny: a Codex subagent's apply_patch is treated as a parent's apply_patch; locks are correct under parent. If Codex emits sub-events with a different session_id, we'll see ghost sessions in `coord status` — easy to detect. |
| I4 | **`PPID` capture in session_start.sh is wrong for Codex.** Watchdog signals 1 + 3 misfire. Crashed Codex sessions never get evicted. | Medium-high. Defeats the recovery mechanism. | Verify Codex's process model in integration testing. If wrong, replace `$PPID` with reading a Codex-supplied PID (e.g., from env var or stdin). |
| I5 | **Cross-agent banner phrasing assumes shell-tool name matches Claude's vocabulary.** Banner says "Bash:" prefix; Codex Bash is also called "Bash" — confirmed. But "Edit" mention in (a) `Bash: coord task-open ...` becomes confusing for Codex users who only know `apply_patch`. | Low-medium. UX confusion only. | Banner is informational; both agents understand `coord task-open` as a shell command. Leave as-is for v1. |
| I6 | **Schema bump 1.0 → 1.1 is missed by an old reader (e.g., a stale `.coord/` from an older install).** Sessions without `agent` field default to "claude_code" — but if a Codex session lands in such a state via translator bug, it's mislabeled. | Low. Mislabeling only; no functional break. | Make `agent` default-to-claude-code via `// "claude_code"` everywhere. Add a single bats test: a sessions.json missing the `agent` field should not break any reader. |
| I7 | **Mediator/Validator backend is `claude -p` even for Codex-only users.** They must install Claude. | Low. Documentation/UX issue. | Document hard dependency in README, install.sh, error message when `claude` is not on PATH (`mediator_spawn.sh:255`). |
| I8 | **Codex's `~/.codex/config.toml` is under `[features] codex_hooks = true` gate.** Without operator action, Codex hooks don't fire. | Medium. Silent no-op. | Installer detects the feature flag state and either sets it (if the user opts in via `--enable-codex-feature-flag`) or surfaces a one-time message: "Codex hooks require `[features] codex_hooks = true` in your config — set it manually or rerun with --enable-codex-feature-flag." |
| I9 | **`pre_tool_use_any.sh` runs on every Codex tool call (matcher `*`).** It calls `coord_watchdog_check_ambient_suspicion`, walks verdict files, runs jq passes — adds latency to every tool call. | Medium. Latency budget; today the budget is "2s p99 no-contention." | Already designed as fail-soft + backgrounded for the watchdog probes (`pre_tool_use_any.sh:309-311`). Verify the latency on Codex by running `phase7_invariant.bats` equivalent. |
| I10 | **Codex `apply_patch` may target multiple files in one call.** Today `pre_tool_use_write.sh` has `TARGET=$(jq -r '.tool_input.file_path...' )` — single path. Codex multi-file patches break this assumption. | Medium-high. Loses coordination on N-1 of N files in a multi-file patch. | The translator's `coord_cx_extract_file_path` returns newline-separated paths. The hook body iterates the list, locking each file. If any file is held by another session → deny the entire `apply_patch`. (Cycle/depth concerns multiply — multi-file write is a deadlock-prone operation.) |
| I11 | **Cross-agent test surface explosion.** Adding a Codex variant for every Claude-coupled bats roughly doubles the unit suite and may regress under CI time. | Low. CI cost. | Use `bats -j N` parallelism; make Codex unit tests opt-in via `BATS_INCLUDE_CODEX=1` env until baseline is green; tag the most-critical Codex tests as ship-gate must-pass. |
| I12 | **No SessionEnd for Codex** means Stop is the only graceful release point. If a Codex user's session dies between `Stop` events (e.g., hard kill), the Watchdog's 10-minute window leaves locks dangling for the live Claude session. | Medium. Recovery latency. | Document this. Tighten Watchdog defaults for Codex sessions if needed (per-agent threshold at OQ H8 future-work). |

---

## J. Suggested execution order

The cardinal rule: **the Claude Code v1 must remain green at every commit.** Use small, reviewable PRs.

### Phase A — Refactor (no behavior change)
1. **Branch hygiene.** Land a `git mv` PR that moves `src/hooks/*.sh` → `src/adapters/claude-code/hooks/` and `src/lib/*.sh` → `src/core/lib/` plus `src/adapters/claude-code/lib/subagent_filter.sh`. Update every `. "$LIB_DIR/..."` source line and every install.sh `cp` path. Single commit, full test surface green. **(High risk; review carefully.)**
2. **Update install.sh paths.** `install.sh:79` `CLAUDE_SETTINGS` becomes `<adapter>/install.sh` parameter. Materialize `.coord/` plumbing stays at `src/install.sh`.
3. **Add `src/core/lib/normalized_events.sh`** (constants only; no consumers yet). No behavior.
4. **Add `src/adapters/claude-code/lib/translator.sh`.** Move all `jq -r '.tool_input.file_path ...'` parsing from hooks into translator. Hooks call translator helpers. **(Medium risk.)**
5. **Add `agent` field to sessions.json template.** Schema bump 1.0 → 1.1. Claude Code adapter's session_start sets `agent: "claude_code"`. Add `// "claude_code"` defaults everywhere readers consume `.agent`. **(Low risk, validates schema additivity.)**

After phase A, the Claude Code v1 is structurally split but functionally identical. Full test surface green.

### Phase B — Codex adapter scaffolding (no Codex hooks fire yet)
6. **Add `src/adapters/codex/` skeleton.** Translator + `apply_patch_parser.sh` + install.sh. Translators stubbed; install.sh writes empty `.codex/hooks.json` (validator returns "yes, this is valid Codex JSON"). Bats unit tests for the parser using fixtures.
7. **Implement `apply_patch_parser.sh` with fixture-driven tests.** Cover: single-file Update, multi-file patches, Create, Delete, edge cases (CRLF, embedded `@@`, large files). Validate against schema reference at `https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated`.
8. **Implement Codex translator (`src/adapters/codex/lib/translator.sh`).** Mirror Claude's translator API. Tests with fixture stdin.

### Phase C — Codex adapter wiring (Codex hooks fire end-to-end)
9. **Implement Codex hook entry points** (`src/adapters/codex/hooks/*.sh`). Each is a thin shim: parse stdin → translator → core libs.
10. **Add `src/adapters/codex/install.sh`.** Writes `.codex/hooks.json`. Smoke test pipes a canned Codex SessionStart through.
11. **Update `src/install.sh`** to dispatch on `--with-claude-code` / `--with-codex` flags; default keeps v1 behavior (Claude only).
12. **Codex-side tests.** Mirror the most-critical Claude bats files (`session_start`, `pre_tool_use_write`, `post_tool_use_write`, `lockdown`). Skip `pre_tool_use_read` (no Read tool).

### Phase D — Cross-agent integration
13. **Add cross-agent integration tests.** Spawn a fake Claude session and a fake Codex session against the same `.coord/`. Verify:
    - Claude acquires lock → Codex `apply_patch` denied with three-options banner.
    - Codex acquires lock → Claude Edit denied.
    - Claude crashes (kill -9) → Codex Watchdog detects and recovers.
    - Cycle detection between sessions of different agents.
    - Cross-agent FIFO wait queue.
14. **Phase 7 ship-gate parallel.** Add `phase7_codex_invariant.bats` mirroring `phase7_invariant.bats` but with Codex inputs.

### Phase E — Documentation & ship surface
15. **Update README.md.** Headline: "Multi-session coordination for AI coding agents." Body: "Supported agents: Claude Code, OpenAI Codex CLI." Quick start updates.
16. **Update CONTRIBUTING.md** with Codex testing instructions.
17. **Update package.json** keywords (`codex`, `openai-codex`).
18. **Update bin/parallel-sessions** help text.

### Phase F — Distribution (v2 territory; deferred per project brief)
- npx wrapper auto-detect agents present.
- Skill marketplace integration.
- Multi-machine team coordination.

### Suggested commit cadence
- Each step is one PR.
- Each PR runs the full test surface green.
- Review focus per phase: A (refactor mechanics), B (parser correctness), C (translator coverage), D (cross-agent semantics), E (docs).

---

## Notes captured but not addressed in the report

- The repo's `IMPLEMENTATION_LOG.md` (gitignored, 394kB) and `phase-*-signoff.md` files contain rich design rationale but were NOT read during this pass; they may yield additional design-context insights but should not block integration work.
- `STATE_OF_SYSTEM.md` (gitignored, 31kB) likewise.
- The `.coord/sessions.json` smoke test residue (`install-smoke-28827`) is benign — only used for installer verification.
- The `wait_backend.sh` sets a config `wait_backend` field that the smoke test config doesn't carry (observed in `.coord/config.json:1-15` — no `wait_backend` field). This is unrelated to the Codex integration but worth flagging as a latent install-vs-config consistency drift.

---

End of report.

---

# ADDENDUM (2026-05-02, post-Codex-source dive)

After the user cloned the Codex CLI source to `codex-ref-repo/codex/`, a deep read of `codex-rs/hooks/`, `codex-rs/tools/`, and `codex-rs/core/src/tools/handlers/apply_patch.rs` produced ground-truth answers to H1, H2, plus revised approaches for H4 and H6 per user direction.

## H1 RESOLVED — Codex subagent semantics

**Codex has a `spawn_agent` tool (v1 + v2)** at `codex-rs/tools/src/agent_tool.rs:29-82` — analogous to Claude's Task tool. Subagents can recursively spawn more subagents.

**Each subagent gets its own `ThreadId`** which is what gets serialized as `session_id` in hook stdin. Confirmed by test code at `codex-rs/core/tests/suite/subagent_notifications.rs:119` — it explicitly searches for a thread_id ≠ parent's session_id.

**There is NO discriminator field** in any hook payload analogous to Claude's `agent_type`. The `HookToolKind` enum at `codex-rs/hooks/src/types.rs:86-91` has only `Function | Custom | LocalShell | Mcp`. No "Subagent" / "Task" variant. Hook input schemas (e.g., `pre-tool-use.command.input.schema.json`) do NOT contain any subagent-discriminator field.

**Parent-child relationships ARE tracked separately** in the `agent-graph-store` crate (`codex-rs/agent-graph-store/src/store.rs`), but this is NOT exposed via hook stdin. A hook script could read it at runtime but that's expensive + brittle.

**Decision (final):** **Treat each Codex subagent as its own coord session.** It registers via SessionStart (subagent spawning is a thread Startup), gets its own `.active` marker, acquires its own locks, has its own read-set / drift detection. Pros: simplest implementation, consistent with the coord model (every session is independent). Cons: many short-lived sessions in `.coord/sessions.json` if a parent spawns many subagents — but the Watchdog and SessionEnd-via-Stop will clean them up. We do NOT need a `subagent_filter.sh` analogue for Codex.

**Future enhancement (v2 if needed):** add a `parent_session: <sid> | null` field on `sessions[<sid>]` populated by reading `agent-graph-store` at SessionStart. Would let the deny banner say "your parent already holds this lock" — but not required for v1.

## H2 RESOLVED — apply_patch payload format

**Confirmed shape:**
```json
{ "command": "<raw-patch-text>" }
```
Source: `codex-rs/core/src/tools/handlers/apply_patch.rs:314-318`:
```rust
fn pre_tool_use_payload(&self, invocation: &ToolInvocation) -> Option<PreToolUsePayload> {
    apply_patch_payload_command(&invocation.payload).map(|command| PreToolUsePayload {
        tool_name: HookToolName::apply_patch(),
        tool_input: serde_json::json!({ "command": command }),
    })
}
```
This is the SAME shape regardless of whether the underlying tool kind is `Function` (with `arguments.input` JSON field) or `Custom` (freeform string) — both get normalized into `{"command": "<patch>"}` for the hook.

**Patch text format (Codex custom, NOT standard unified diff):**

Grammar at `codex-rs/tools/src/apply_patch_tool.rs:50-59`:
```
Patch     := Begin { FileOp } End
Begin     := "*** Begin Patch" NEWLINE
End       := "*** End Patch" NEWLINE
FileOp    := AddFile | DeleteFile | UpdateFile
AddFile   := "*** Add File: " path NEWLINE { "+" line NEWLINE }
DeleteFile:= "*** Delete File: " path NEWLINE
UpdateFile:= "*** Update File: " path NEWLINE [ MoveTo ] { Hunk }
MoveTo    := "*** Move to: " newPath NEWLINE
Hunk      := "@@" [ header ] NEWLINE { HunkLine } [ "*** End of File" NEWLINE ]
HunkLine  := (" " | "-" | "+") text NEWLINE
```

**Concrete example** (from fixture `002_multiple_operations`):
```
*** Begin Patch
*** Add File: nested/new.txt
+created
*** Delete File: delete.txt
*** Update File: modify.txt
@@
-line2
+changed
*** End Patch
```

**Multi-file patches are ONE apply_patch call** with multiple `*** Update File:` / `*** Add File:` / `*** Delete File:` sections inside one envelope. Not N separate calls. Confirmed by `tools/src/apply_patch_tool.rs:50-72` grammar.

**Pre-image extraction strategy (the key for our drift detection):**
- For each `*** Update File: <path>` operation, find every `@@` hunk inside.
- Within a hunk, the **pre-image** = lines starting with `' '` (context, unchanged) ∪ lines starting with `'-'` (about to be removed), in original order.
- Default 3 lines of pre-context + 3 lines of post-context per change.
- The optional `@@ <header>` line names a class/function for ambiguity resolution but is not part of the file's bytes.
- This is a **partial pre-image** — only the bytes around each change. NOT the full file. So we can hash a per-hunk pre-image fragment, but NOT a whole-file hash unless we read the disk file (which is what current state already is).

**Practical implication:** Codex's drift signal differs from Claude's:
- Claude: "agent's `Read`-time hash" vs "current disk hash" — full file comparison.
- Codex: "agent's per-hunk context-line belief" vs "current disk file's actual bytes at the same locations" — partial comparison.

The right adaptation is: for each hunk, locate its anchor in the current file (using the context lines as a search pattern), compare the anchor's actual disk content with what the agent believes is there. If the anchor cannot be located OR the located content differs from agent's belief → drift on this hunk → escalate to validator pipeline with the disk file as "current" and a synthesized pre-image text file (built from context+removed lines) as "pre-image" — same shape the validator already consumes.

This is feasible with `awk`/`sed` parsing in pure Bash 3.2 + `jq`. The parser is a few hundred lines but bounded — it's just a state machine over the patch text.

**Multi-file = multi-lock atomicity issue:** If a single apply_patch call updates file A and file B, and another session holds file B, our hook should deny the entire apply_patch (atomic acquire-all-or-nothing). This is a NEW capability — the current Claude code only sees one file per Edit/Write call. The Codex hook needs:
1. Parse all file paths from the patch.
2. Try to lock all of them in deterministic order (alphabetical, to prevent parallel-acquire deadlocks).
3. If ANY is held by another session → deny with banner listing all blocked files.
4. If all available → acquire all.
5. PostToolUse releases all.

**Risk:** This raises complexity. For v1, an acceptable simplification is: deny multi-file apply_patch entirely (force the agent to break it into N separate single-file patches). This is conservative but breaks ergonomics. **Recommendation:** Multi-file lock-all-or-deny in v1 — moderate parser work but correct.

**PostToolUse `tool_response` shape:** `tool_response` is the `ApplyPatchToolOutput::post_tool_use_response()` value — contains exit_code, stdout, stderr, and the actually-applied final file content. Not directly useful for drift detection (the apply already happened) but useful for the task-processor's outcome diff.

## Critical Codex restrictions discovered

1. **`permissionDecision` and `additionalContext` are MUTUALLY EXCLUSIVE in the SAME hook output JSON** for `PreToolUse`. Test at `codex-rs/hooks/src/events/pre_tool_use.rs:396-423` ("unsupported_additional_context_fails_open") confirms a hook returning both fields in `hookSpecificOutput` will be marked Failed. Our existing code is structurally compatible (each hook output emits one or the other, not both), but we must NOT compose them in any future change.

2. **Plain stdout is IGNORED on PreToolUse and PostToolUse** (codex tests `plain_stdout_is_ignored*`). Only JSON-shaped output matters there. SessionStart and UserPromptSubmit DO accept plain text as developer-context — but JSON is preferred for consistency.

3. **Stop hook input includes `last_assistant_message`** field. Useful future signal: a stop with an empty assistant message might indicate a stuck session. (Not needed for v1.)

4. **Stop hook input includes `stop_hook_active: bool`** — same name as Claude's. Used for our self-task block-once-then-allow detection (we already check this; carries unchanged).

5. **`permission_mode` field on every tool-scoped hook input.** Values: `default | acceptEdits | plan | dontAsk | bypassPermissions`. Future use: skip coord lock acquisition in `plan` mode (planning, not executing). Not needed for v1.

6. **`tool_use_id` is unique per tool call.** Codex uses this; Claude doesn't expose it on hook stdin. Could enable per-tool-call event correlation but not needed for v1.

7. **Matcher syntax in Codex.** The Rust matcher logic at `codex-rs/hooks/src/events/common.rs:118-153` accepts: empty / `*` (match-all), exact strings with `|` alternation (`Edit|Write|NotebookEdit`), and full regex (`^Bash$`, `mcp__memory__.*`). Our existing matcher strings (`"Read"`, `"Write|Edit|NotebookEdit"`, `"*"`) are accepted by Codex's matcher engine as-is. **No conversion needed.**

8. **No `SessionEnd` event in Codex** — confirmed via `codex-rs/hooks/src/events/mod.rs:1-7` which exports exactly 6 modules. Lock release relies on `Stop` + Watchdog. Documented in OQ H5 above.

9. **SessionStart sources** in Codex are `Startup | Resume | Clear` (no `Compact`). Our `session_start.sh` already has a `*` fallback that treats unknown sources as Startup, so `compact` simply never fires for Codex — no break.

## H4 RESOLVED — Folder-local install (no git requirement)

User direction: "hep kullanıcının install ettiği repo folderında çalışmalı (repo olmasına gerek yok normal bir folderda çalıştırmak isteyen developer olmayan kişilerde kullanabilir)".

**Required changes to drop the git dependency:**

1. `src/install.sh:73-76` currently:
   ```bash
   if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
     die "not inside a git repository; run this from inside a repo"
   fi
   ```
   Change to: prefer `git rev-parse --show-toplevel` if available; otherwise use `pwd` as the install root, with a confirmation prompt unless `--yes`.

2. `src/hooks/*.sh` `coord_resolve_root()` functions (every hook has this) currently look up `CLAUDE_PROJECT_DIR` then `git rev-parse --show-toplevel`. Update to a fallback chain:
   - `${COORD_DIR}` env (already first)
   - **NEW**: walk up from `${cwd}` (passed via stdin's `cwd` field) looking for a `.coord/` directory — stops at first match or filesystem root.
   - **NEW**: walk up from `${BASH_SOURCE[0]}`'s parent looking for `.coord/` (script-location-based fallback for headless invocations).
   - `${CLAUDE_PROJECT_DIR}` env (legacy)
   - `git rev-parse --show-toplevel` (last resort)

3. `bin/parallel-sessions:54-72` (Node wrapper for `init`) currently runs `git rev-parse` BEFORE invoking install.sh. Remove the git check; pass an `--allow-no-git` mode flag if needed.

4. `src/bin/coord:cmd_health` already does `git rev-parse --show-toplevel 2>/dev/null || pwd` (line 146) — already handles non-git folders correctly.

5. `src/lib/head_tracking.sh:26-33` (`coord_current_head`) returns empty string when not in a git repo — agent-agnostic, already handles non-git.

6. `.gitignore` insertion in `install.sh:454-459` should be skipped if `.gitignore` doesn't exist or `.git/` is absent (no-op, not an error).

**Smoke test** must work in a non-git temp folder for the new install.sh path.

## H6 RESOLVED — Launcher commands instead of env var

User direction: no env var; the user types `parallels-claude` or `parallels-codex` to start a coordinated session.

**Architecture:**

1. **Provide two launcher binaries:**
   - `bin/parallels-claude` (or `parallels-claude.sh`) — sets up coord state, then `exec`s `claude "$@"`.
   - `bin/parallels-codex` — sets up coord state, then `exec`s `codex "$@"` (or whatever Codex's CLI invocation is).
2. **Internally these scripts set `COORD_ENABLED=1`** before exec'ing the agent. The env var is an implementation detail; user never sees or types it.
3. **Hooks check `COORD_ENABLED=1`** (renamed from `CLAUDE_COORD`; keep `CLAUDE_COORD` as legacy alias for back-compat).
4. **Wrapper does pre-flight:**
   - Verify coord is installed in current folder (i.e., `.coord/` exists).
   - If not, prompt the user to run `parallels-init` first (or auto-install with confirmation).
   - For `parallels-codex`, also ensure `.codex/hooks.json` is registered.
   - For `parallels-claude`, also ensure `.claude/settings.local.json` is registered.
5. **`bin/parallels-init`** — the install command. Replaces user-facing `bash src/install.sh`. Detects which agents are installed (claude binary, codex binary on PATH) and installs hooks for each.

**Naming proposal (subject to user approval):**
- `parallels-init` — install / repair / uninstall / purge.
- `parallels-claude` — start a coordinated Claude Code session.
- `parallels-codex` — start a coordinated Codex session.
- `parallels-status` — alias for `coord status` (in case user prefers `parallels-` prefix everywhere).

**Implementation:**
- Each launcher is ~30 lines of bash.
- The `bin/parallel-sessions` Node wrapper currently has subcommands `init` / `status` / `test` / `help`. Keep it as a npm-publishable entry but it won't be the recommended UX — the dedicated `parallels-claude` / `parallels-codex` scripts will be.
- For npm distribution: package exposes `parallels-init`, `parallels-claude`, `parallels-codex`, `parallels-status` as separate `bin` entries in `package.json`.

**Direct-claude (without wrapper) behavior:** if the user runs `claude` without the wrapper, the env var is unset, hooks check `COORD_ENABLED != 1` and exit 0 silently — coord is dormant. This preserves the "test claude without coord" escape hatch. The same applies to direct `codex` runs.

## Final summary of decisions

| OQ | Question | Final decision |
|---|---|---|
| H1 | Codex subagent filter? | No filter. Each subagent is its own coord session (different `session_id`). Schema field `agent: "codex"` carries forward; sessions register naturally via SessionStart with `source: "startup"`. |
| H2 | apply_patch payload parser? | Custom Codex grammar (not unified diff). Parser implemented as a state machine in pure bash. Pre-image = ` ` + `-` lines per hunk. Multi-file patches → multi-lock acquire-all-or-deny in v1. Reference: `codex-rs/tools/src/apply_patch_tool.rs:50-72` grammar. |
| H4 | Folder-local install? | Drop git requirement. Install root = current folder (or first parent containing `.coord/`). 6 specific code-change sites listed above. |
| H6 | Env var or launcher? | Launcher scripts: `parallels-init`, `parallels-claude`, `parallels-codex`, `parallels-status`. Internal `COORD_ENABLED=1` env var (user-invisible) for hook-side participation gate. `CLAUDE_COORD=1` kept as legacy alias. |

End of addendum.

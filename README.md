# Parallel Sessions

Multi-session coordination for Claude Code — prevent concurrent edits, recover from crashes, delegate work between sessions.

## What it does

When you run multiple Claude Code sessions against the same repository, they have no awareness of each other. Two sessions can edit the same file simultaneously and clobber each other's work; one session can read a stale version of a file another has just changed; a crashed session can leave locks behind that block everyone else indefinitely.

Parallel Sessions is a coordination layer that sits between Claude Code and your repository. It registers Claude Code hooks (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd`) that observe and arbitrate every Read, Write, and Edit. Files get locked when a session starts editing them; other sessions trying to write the same file see a deny banner with three options (delegate the work, self-delegate and come back later, or wait). Stale reads are detected and classified by a Validator agent into SAFE, MINOR, or CRITICAL drift. Crashes are recovered by a Watchdog and a Mediator agent.

The mental model is deliberately small. There is no server, no daemon, no UI. State lives at `.coord/sessions.json` (atomically edited under `flock`). The audit log lives at `.coord/events.jsonl`. The hooks are pure Bash 3.2 + `jq` + `flock`. Everything is observable; nothing runs unless a Claude Code session triggers it.

Scope: single-developer / single-machine. Multi-machine team scenarios are out of scope for v1.

## Quick start

Parallel Sessions v1 ships with a Bash installer. The npx wrapper is coming in a follow-up release.

```bash
git clone https://github.com/ModuleXAI/parallel-sessions.git
cd parallel-sessions
bash src/install.sh           # registers hooks into .claude/settings.local.json

# Activate in your Claude Code session:
export CLAUDE_COORD=1
claude
```

The installer is idempotent. To remove: `bash src/install.sh --uninstall` (preserves audit log) or `--purge` (also drops `.coord/`).

### Optional: install with permission bypass

`bash src/install.sh --bypass-permissions` (or `npx parallel-sessions init --bypass-permissions`) additionally sets `permissions.defaultMode = "bypassPermissions"` in `.claude/settings.local.json`, auto-approving every Claude Code tool-permission prompt in this repo. **DANGEROUS — opt-in only.** Off by default. Useful for trusted single-developer workflows where the prompts add friction without risk; never the right default for shared or untrusted environments. Combinable with `--yes` and `--repair`. To revert, remove the `defaultMode` key from `.claude/settings.local.json` or set it back to `"default"` / `"acceptEdits"` / `"plan"`.

## Features

- **File locking with actionable deny banner** — three options offered: delegate a SIMPLE/MODERATE task to the holder, self-delegate (defer your work and come back), or wait passively for release.
- **Crash recovery** — Watchdog detects dead sessions via 3-signal consensus (PID liveness + last-activity + lock-refresh age); Mediator agent decides whether to evict, surgical-fix, or lockdown.
- **Stale-read drift classification** — 3-stage pipeline (cache → pre-filter → Validator agent) classifies drift as SAFE / MINOR / CRITICAL. CRITICAL escalates to the Mediator inline.
- **Multi-waiter FIFO queue with event-driven wake-up** — `fswatch` (macOS) / `inotifywait` (Linux) / 250 ms polling fallback. Sub-100 ms wake-up latency in the event-driven path.
- **Lock-dependency cycle detection** — bipartite session/file DFS triggered when a wait queue grows; Mediator resolves by evicting the lowest-priority session.
- **Cross-session task delegation** — a session blocked on a locked file can hand off the edit (`coord task-open`) with anchor + complexity + chain-depth + cycle-detection guards.
- **Self-delegation lifecycle** — `coord self-delegate` records deferred work; reminders fire on every `PreToolUse` after the file unlocks; `Stop` blocks once if self-tasks are unresolved.
- **Three-mode operator switch** — `COORD_TEST_MODE=mock|semi|realistic` routes the 3 spawn sites between mock fakes and real `claude -p` for staged validation.
- **Cost-guard rate-limit enforcement** — sliding-window counters guard the Mediator + Validator + Task-Processor spawn sites against runaway invocations.

## How it works

The hooks register into `.claude/settings.local.json` at install time. On `SessionStart`, your session is registered into `.coord/sessions.json` and assigned a coordination UUID. On every `Read`, the hook records the file hash; on every `Write`/`Edit`, the hook validates your read-set is still fresh, acquires a lock (or denies with three options), and on the `PostToolUse` it processes any tasks delegated to that lock and notifies waiters.

When something the deterministic logic cannot handle arises — corrupt state, a stuck session, a lock-dependency cycle, a CRITICAL drift verdict — a Mediator pending entry is written to `.coord/mediator/pending.jsonl` and a `claude -p` subprocess is spawned to analyze and decide. The Mediator's verdict is one of three actions: advice, surgical_fix, or lockdown. This 3-action contract is fixed by design — new failure kinds added in the future must fit it without code changes.

For deeper architecture, design rationale, decision records, and the ~25 hard-won lessons from construction (Bash 3.2 portability, `set -e + pipefail` traps, `jq` edge cases, fixture inheritance issues, etc.), see `docs/development-history/CLAUDE.md` (Part A construction discipline; Part B runtime contract; §A.13 lessons library).

## Test modes

`COORD_TEST_MODE` selects which spawn sites use real `claude -p` versus mock fakes:

- **mock** (default; CI + daily dev) — all 3 spawn sites use mocks. Fast, free, deterministic, CI-safe.
- **semi** (weekly stakes-coverage smoke) — Mediator + Task Processor real Claude; Validator stays mock.
- **realistic** (pre-release smoke) — all 3 sites real Claude.

Manual stress runs:

```bash
bash scripts/stress_semi.sh
bash scripts/stress_realistic.sh
```

Output lands under `scripts/stress_<mode>_out/<ISO_ts>.log` (gitignored).

## Documentation

- `docs/development-history/` — full 8-phase implementation arc, design decisions (`IMPLEMENTATION_PLAN.md`), revision ledger (`plan-revisions.md`), construction discipline + runtime contract (`CLAUDE.md`).
- `LICENSE` — MIT.
- `CONTRIBUTING.md` — setup, coding standards, PR process.

## Status

v1 production-ready at single-developer / single-machine scale. Verification surface:

- 645 unit tests (54 `bats` files)
- 48 integration tests (4 `bats` files)
- 24 ship-gate fixtures (Phase 3-7 driver scripts)
- 19-guard architectural invariant (`phase7_invariant.bats`)

Multi-machine team scenarios are deferred to the next major version.

## Contributing

See `CONTRIBUTING.md`.

## License

MIT — see `LICENSE`.

## Acknowledgments

Built by Sezer Yavuz. Implementation arc disciplined via F-011 honest-reporting binding and ship-gate fixture methodology — every phase closed with deterministic, replayable evidence rather than aspirational claims.

# Contributing to Parallel Sessions

Thanks for your interest. Parallel Sessions is a small, opinionated coordination layer for AI coding agents (Claude Code + OpenAI Codex), and contributions that align with its scope and discipline are welcome.

## Reporting issues

File issues at [github.com/ModuleXAI/parallel-sessions/issues](https://github.com/ModuleXAI/parallel-sessions/issues). Please include:

- OS (`uname -a`) and Bash version (`bash --version`)
- `jq --version`, `flock --version` (Linux) or note macOS, `perl -v`
- Which adapter(s) installed (`bash src/install.sh ...` flags used)
- Reproduction steps (smallest possible)
- Expected vs. actual behavior
- Output of `bash src/tests/manual/phase7_ship_gate.sh` if a ship-gate scenario reproduces the issue

If the issue is intermittent, attach the relevant slice of `.coord/events.jsonl` (it is the audit trail of every coordination event during the run). When the issue involves cross-agent contention, also attach `.coord/sessions.json` so the agent-mix is visible.

## Development setup

```bash
git clone https://github.com/ModuleXAI/parallel-sessions.git
cd parallel-sessions

# Run the unit suite (837 tests across the bats files):
bats src/tests/unit

# Run the integration suite top-level (77 tests):
bats src/tests/integration

# Run the cross-agent integration suite (45 tests under
# src/tests/integration/cross_agent/ — bats does NOT recurse by default,
# so an explicit -r is required):
bats -r src/tests/integration/cross_agent

# Run the full integration surface (122 tests including cross_agent):
bats -r src/tests/integration

# Run the ship-gate drivers (24 scenarios across Phases 3-7):
bash src/tests/manual/phase3_ship_gate.sh
bash src/tests/manual/phase4_ship_gate.sh
bash src/tests/manual/phase5_ship_gate.sh
bash src/tests/manual/phase6_ship_gate.sh
bash src/tests/manual/phase7_ship_gate.sh
```

Required tooling: Bash 3.2+, `jq`, `flock`, `perl`, `bats`. Optional but recommended for sub-100 ms wait wake-ups: `fswatch` (macOS, `brew install fswatch`) or `inotify-tools` (Linux, `apt install inotify-tools`).

For Codex testing, the `codex` binary is OPTIONAL at test time (the helpers stub it on `$PATH` for dispatcher auto-detection); for actual Codex sessions it must be installed from [github.com/openai/codex](https://github.com/openai/codex). Per the D-1 contract, **the `claude` binary is required even for Codex-only operators** because the Mediator backend is `claude -p` regardless of which adapter triggered the decision.

## Architecture overview

Parallel Sessions is two layers of Bash, organized by adapter under `src/`:

1. **Core** (`src/core/`) — agent-agnostic shared layer.
   - `core/lib/` — atomic state writes (`atomic_write.sh`), event log (`log_event.sh`), validator pipeline (`validator_*.sh`), wait-queue + cycle detection (`wait_queue.sh`, `cycle_detection.sh`), spawn helpers (`spawn_helper.sh`, `mediator_spawn.sh`, `validator_spawn.sh`, `task_processor.sh`), and many more.
   - `core/bin/coord` — the coord CLI.
2. **Claude Code adapter** (`src/adapters/claude-code/`) — entry points wired into `.claude/settings.local.json`.
   - `hooks/` — 8 hook scripts (`session_start.sh`, `session_end.sh`, `stop.sh`, `user_prompt_submit.sh`, `pre_tool_use_any.sh`, `pre_tool_use_read.sh`, `pre_tool_use_write.sh`, `post_tool_use_write.sh`).
   - `lib/subagent_filter.sh` — subagent (Task tool) defensive filter.
   - `install.sh` — adapter-specific installer.
3. **Codex adapter** (`src/adapters/codex/`) — entry points wired into `.codex/hooks.json`.
   - `hooks/` — 7 hook scripts (no `SessionEnd` per D-10; `pre_tool_use_*.sh` split into `_any.sh` / `_bash.sh` / `_apply_patch.sh` per matcher).
   - `lib/translator.sh` — Codex stdin/stdout shape adapter.
   - `lib/apply_patch_parser.sh` — pure-bash apply_patch grammar parser.
   - `install.sh` — adapter-specific installer.

The top-level `src/install.sh` is the adapter dispatcher: it materializes the shared `.coord/` infrastructure once, then delegates to each adapter's installer based on `--with-*` / `--without-*` flags and `claude` / `codex` PATH detection.

In-line reference docs near the code: `src/core/lib/MEDIATOR_REFERENCE.md` and `src/core/lib/VALIDATOR_REFERENCE.md` cover the spawn contracts for those two subsystems. The Codex integration's locked decisions and plan are at `codex-integration-plan.md` (definitive), `codex-integration-research.md` (background), `codex-integration-log.md` (PR-by-PR audit trail of the integration arc).

## Coding standards

- **Bash 3.2 compatibility is mandatory.** macOS ships Bash 3.2.57 by default. Forbidden: associative arrays, `readarray`/`mapfile`, `${var,,}` / `${var^^}`, `&>>`, Bash 4+ parameter expansion. Test syntax with `bash -n <file>` on a Bash 3.2.
- **All hooks fail-open.** Internal errors must exit 0; never return non-zero from a hook unless the contract explicitly requires it (today: Claude lock-held deny + Codex apply_patch deny + lockdown deny).
- **2-location deny invariant for Claude; 4-location for Codex.** `permissionDecision: "deny"` appears in EXACTLY two places in the Claude codebase: `src/adapters/claude-code/hooks/pre_tool_use_write.sh` (lock-held branch) and `src/core/lib/lockdown.sh` (global pause). For Codex, `permissionDecision: "deny"` appears in `src/adapters/codex/hooks/pre_tool_use_apply_patch.sh` (peer-held / drift / race-loss / lockdown), and the lockdown helper is shared. Every new lib MUST be enumerated in `src/tests/unit/phase7_invariant.bats` (Claude) or `src/tests/unit/codex_phase7_invariant.bats` (Codex) and confirmed deny-free.
- **No additionalContext on Codex PreToolUse hooks (A-D4-02).** Codex's hook output parser explicitly rejects `additionalContext` on `PreToolUse` events (`codex-rs/hooks/src/engine/output_parser.rs:16-20` + `:337-348`). Codex `pre_tool_use_*.sh` hooks emit ONLY `permissionDecision` (deny via lockdown helper, deny in apply_patch hook) or empty stdout. Bookkeeping side effects (notification clear, HEAD-drift mark, mediator verdict apply, watchdog probe) still run; the banner channel is just unavailable on `PreToolUse` for Codex. See README §"Why Codex is quieter on PreToolUse" for the operator-facing explanation.
- **Atomic state writes.** Every mutation of `.coord/sessions.json` / `events.jsonl` / `config.json` goes through `core/lib/atomic_write.sh` or `core/lib/log_event.sh`. Never `>` directly; never `jq -i` on coord state.
- **Event logging is non-blocking.** Use `coord_log_event ... &` with `disown` — hook latency budget is 2 s p99 in the no-contention case.
- **Mediator dispatch is kind-agnostic.** Adding a new pending kind MUST NOT require touching `core/lib/mediator_spawn.sh` / `core/lib/mediator_pending.sh` / `core/lib/verdict_apply.sh`. New kinds fit the 3-action contract (advice / surgical_fix / lockdown) at the verdict layer.
- **D-1: Mediator is `claude -p` always.** Codex sessions DO trigger Mediator decisions; the dispatch shape stays `claude -p`. `core/lib/mediator_spawn.sh` already enforces the `command -v claude` precondition; if absent, it returns rc=1 with `MEDIATOR_SPAWN_REFUSED reason=claude_binary_missing`. Don't add a Codex-side spawn fallback without an explicit plan amendment.
- **D-2: No subagent filter on Codex hooks.** Codex has no subagent concept. `subagent_filter.sh` is a Claude-adapter lib; sourcing it from a Codex hook would be dead code (or worse). The codex invariant guard #3 forbids it.
- **D-10: No SessionEnd registration for Codex.** Codex does not deliver `SessionEnd`; lock release is via `Stop` + Watchdog. The codex installer's `.codex/hooks.json` writer must NOT include `SessionEnd`.
- **Watch the common traps.** Pipefail capture inside `set -e` blocks, GNU-first stat invocation (`stat -c` before BSD `stat -f`), `claude -p` spawn discipline (always backgrounded + disowned), bats integration patterns (fixture cleanup, sub-shell PATH propagation), and AVOID `BASH_*` as local variable names (`BASH_COMMAND` is a built-in that holds the currently-executing command's text — using it as a local will populate with the source line, not the value you assigned).

## Pull request process

1. Fork the repository and create a topic branch (`feat/...` or `fix/...`).
2. Make your changes. Add or update tests; new behavior requires either a unit test or an integration test, and ideally a ship-gate fixture if it touches a hook contract. Cross-agent behavior changes require a `src/tests/integration/cross_agent/` scenario.
3. Confirm the full local verification surface is green:
   - `bats src/tests/unit` — 837/837 PASS
   - `bats src/tests/integration` — 77/77 PASS (top-level)
   - `bats -r src/tests/integration/cross_agent` — 45/45 PASS
   - `bats -r src/tests/integration` — 122/122 PASS (full with recursion)
   - `bash src/tests/manual/phase{3,4,5,6,7}_ship_gate.sh` — 24/24 PASS
   - `bats src/tests/unit/phase7_invariant.bats` — 19/19 PASS (Claude invariant)
   - `bats src/tests/unit/codex_phase7_invariant.bats` — 7/7 PASS (Codex invariant)
4. Update documentation when behavior changes. Public-facing behavior changes go in `README.md`; in-tree reference docs (`src/core/lib/MEDIATOR_REFERENCE.md`, `src/core/lib/VALIDATOR_REFERENCE.md`) get updated when the relevant subsystem contract shifts. Codex-specific operator notes go in `docs/codex-quickstart.md` (when present).
5. Open a PR. Describe what changed, why, and reference any issue. One reviewer approval is required before merge.
6. Squash-merge is preferred for small/medium PRs; a clean linear history is the project default.

## Code of conduct

Be kind. No harassment. Disagreements stay technical and surface evidence rather than authority. If a discussion is going sideways, step back and re-anchor on the specific code, test, or decision record under debate.

## License

By contributing, you agree that your contributions are licensed under the MIT License (see `LICENSE`).

# Contributing to GearCode

Thanks for your interest. GearCode is a small, opinionated coordination layer for Claude Code, and contributions that align with its scope and discipline are welcome.

## Reporting issues

File issues at [github.com/sezeryavuz/gearcode/issues](https://github.com/sezeryavuz/gearcode/issues). Please include:

- OS (`uname -a`) and Bash version (`bash --version`)
- `jq --version`, `flock --version` (Linux) or note macOS, `perl -v`
- Reproduction steps (smallest possible)
- Expected vs. actual behavior
- Output of `bash src/tests/manual/phase7_ship_gate.sh` if a ship-gate scenario reproduces the issue

If the issue is intermittent, attach the relevant slice of `.coord/events.jsonl` (it is the audit trail of every coordination event during the run).

## Development setup

```bash
git clone https://github.com/sezeryavuz/gearcode.git
cd gearcode

# Run the unit suite (645 tests, 54 .bats files):
bats src/tests/unit

# Run the integration suite (48 tests, 4 .bats files):
bats src/tests/integration

# Run the ship-gate drivers (24 scenarios across Phases 3-7):
bash src/tests/manual/phase3_ship_gate.sh
bash src/tests/manual/phase4_ship_gate.sh
bash src/tests/manual/phase5_ship_gate.sh
bash src/tests/manual/phase6_ship_gate.sh
bash src/tests/manual/phase7_ship_gate.sh
```

Required tooling: Bash 3.2+, `jq`, `flock`, `perl`, `bats`. Optional but recommended for sub-100 ms wait wake-ups: `fswatch` (macOS, `brew install fswatch`) or `inotify-tools` (Linux, `apt install inotify-tools`).

## Architecture overview

GearCode is two layers of Bash:

1. **Hooks** (`src/hooks/`) — entry points wired into `.claude/settings.local.json`. Each hook source `src/lib/lockdown.sh` for the global pause check, `src/lib/participant.sh` for the early-exit check, and the relevant subsystem libraries.
2. **Libraries** (`src/lib/`) — atomic state writes (`atomic_write.sh`), event log (`log_event.sh`), validator pipeline (`validator_*.sh`), wait-queue + cycle detection (`wait_queue.sh`, `cycle_detection.sh`), spawn helpers (`spawn_helper.sh`, `mediator_spawn.sh`, `validator_spawn.sh`, `task_processor.sh`), and many more.

For the canonical deep-dive (decision records, runtime contract, ~25 lessons from construction), read `docs/development-history/CLAUDE.md`. Part A is construction discipline. Part B is the runtime contract that hooks make true. Section A.13 is the lessons library — every entry came from a real bug that surfaced during a phase build.

## Coding standards

- **Bash 3.2 compatibility is mandatory.** macOS ships Bash 3.2.57 by default. Forbidden: associative arrays, `readarray`/`mapfile`, `${var,,}` / `${var^^}`, `&>>`, Bash 4+ parameter expansion. Test syntax with `bash -n <file>` on a Bash 3.2.
- **All hooks fail-open.** Internal errors must exit 0; never return non-zero from a hook unless the contract explicitly requires it (today: lock-held deny + lockdown deny only).
- **2-location deny invariant.** `permissionDecision: "deny"` appears in EXACTLY two places in the codebase: `src/hooks/pre_tool_use_write.sh` (lock-held branch) and `src/lib/lockdown.sh` (global pause). Every new lib MUST be enumerated in `src/tests/unit/phase7_invariant.bats` and confirmed deny-free.
- **Atomic state writes.** Every mutation of `.coord/sessions.json` / `events.jsonl` / `config.json` goes through `lib/atomic_write.sh` or `lib/log_event.sh`. Never `>` directly; never `jq -i` on coord state.
- **Event logging is non-blocking.** Use `coord_log_event ... &` with `disown` — hook latency budget is 2 s p99 in the no-contention case.
- **Mediator dispatch is kind-agnostic.** Adding a new pending kind MUST NOT require touching `lib/mediator_spawn.sh` / `lib/mediator_pending.sh` / `lib/verdict_apply.sh`. New kinds fit the 3-action contract (advice / surgical_fix / lockdown) at the verdict layer.
- **Apply §A.13 lessons proactively.** The lessons library in `docs/development-history/CLAUDE.md` §A.13 is not retrospective reading — it is a checklist. Pipefail capture (lesson #2 / #5), GNU-first stat (lesson #3), `claude -p` spawn discipline (lesson #4), and bats integration patterns (lessons #17 / #18 / #23) are the most-frequently-tripped items.

## Pull request process

1. Fork the repository and create a topic branch (`feat/...` or `fix/...`).
2. Make your changes. Add or update tests; new behavior requires either a unit test or an integration test, and ideally a ship-gate fixture if it touches a hook contract.
3. Confirm the full local verification surface is green:
   - `bats src/tests/unit` — 645/645 PASS
   - `bats src/tests/integration` — 48/48 PASS
   - `bash src/tests/manual/phase{3,4,5,6,7}_ship_gate.sh` — 24/24 PASS
   - `bats src/tests/unit/phase7_invariant.bats` — 19/19 PASS
4. Update documentation when behavior changes. Runtime-contract changes update `docs/development-history/CLAUDE.md` Part B; new lessons go in §A.13.
5. Open a PR. Describe what changed, why, and reference any issue. One reviewer approval is required before merge.
6. Squash-merge is preferred for small/medium PRs; a clean linear history is the project default.

## Code of conduct

Be kind. No harassment. Disagreements stay technical and surface evidence rather than authority. If a discussion is going sideways, step back and re-anchor on the specific code, test, or decision record under debate.

## License

By contributing, you agree that your contributions are licensed under the MIT License (see `LICENSE`).

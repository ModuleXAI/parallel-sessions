# Fixture: `two_session_warn`

Verifies Phase 1's done-when criterion #1:

> Two-session scenario: Session B modifies foo.ts; Session A's next Write
> (on any file) sees a warning in `additionalContext` citing foo.ts.

This fixture is structured as a **Phase-7-extensible seed**: T1.11 ships
the first scenario (`01_basic_warn`); Phase 7 will add additional
scenarios alongside it without re-architecting. The driver, fixture init,
and assertion contract are stable.

## Layout

```
two_session_warn/
├── README.md            (this file)
├── init.sh              creates an isolated fresh workspace + coord install
└── scenarios/
    ├── 01_basic_warn/
    │   ├── description.md     human-readable spec for the scenario
    │   └── timeline.sh        action sequence + assertions (sourceable)
    └── <future_scenarios>/    same shape; add by copying 01_basic_warn/
```

## How a scenario directory is structured

A scenario directory contains:

- **`description.md`** — human-readable: goal, timeline (hook-sim and
  real-claude variants), assertions. Required.
- **`timeline.sh`** — sourceable bash. Defines two functions:
  - `scenario_run`: drives the hook-sim timeline. Sets `STDOUT_OF_FINAL_HOOK`
    to capture stdout from the assertion target.
  - `scenario_assert`: runs assertions against the captured stdout +
    events.jsonl + sessions.json. Prints diagnostics on failure. Returns
    0 (pass) or 1 (fail).

## How the driver invokes scenarios

`src/tests/manual/two_session_warn.sh [--mode=<hook-sim|real>] [--scenario=<name>]`

- `--mode=hook-sim` (default): drives scenarios by direct hook invocation.
  No API key required. Deterministic. CI-runnable.
- `--mode=real`: spawns actual `claude -p` sessions per scenario's
  description.md "real-claude timeline" section. Requires
  `ANTHROPIC_API_KEY`; SKIPS (exit 77) if absent. **Stubbed in Phase 1;
  Phase 7 fills in.**
- `--scenario=<name>`: run a single scenario. Default: run all scenarios
  in `scenarios/`.

Exit codes:
- `0` — all scenarios passed
- `1` — at least one scenario failed (with diagnostic stderr/stdout)
- `77` — scenarios skipped (e.g., real mode without API key)

## How Phase 7 will extend this

Phase 7 adds new scenarios by:

1. `cp -r scenarios/01_basic_warn scenarios/02_<new_scenario>`
2. Edit `description.md` and `timeline.sh` for the new case.
3. The driver picks it up automatically (lexicographic scenario order).

Phase 7 also implements the `--mode=real` path inside
`src/tests/manual/two_session_warn.sh` — this fixture's hook-sim mode
is the same fixture seed; only the orchestration layer changes.

# phase5_ship_gate fixtures

End-to-end ship-gate verification for Phase 5 (wait queue + cycle
detection). Mirrors the `phase4_ship_gate/` pattern with Phase 5
deliverables (T5.02-T5.07) exercised through realistic
producer-consumer flows in hook-sim mode.

## Fixtures (4 scenarios)

| # | Scenario | Phase 5 done-when criterion |
|---|----------|------------------------------|
| 01 | `01_wait_queue_fifo_ordering` | Ordered wake-up verified with 3 sessions. |
| 02 | `02_wake_file_event_driven` | Polling-backend wake-up latency budget (deterministic across hosts). |
| 03 | `03_diff_summary_on_release` | Wake-up context contains non-empty diff when lock-holder produced changes (Tier 1 verdict_file). |
| 04 | `04_cycle_detected_mediator_evict` | Cycle introduced artificially triggers Mediator verdict that breaks the cycle by selecting a session to evict. |

## Run

```bash
bash src/tests/manual/phase5_ship_gate.sh
```

Filter to one scenario via `--scenario=<dirname>`. Keep the
fixture workspace via `--keep`. Real-mode (real `claude -p` spawn)
returns exit 77 (skip; Phase 7 stress harness territory).

## Mock claude binary

`init.sh` installs a fake `claude` at `$WORKDIR/bin/claude` that
dispatches by env var:

- `CLAUDE_CODE_VALIDATOR=1` → write validator verdict per
  `MOCK_VALIDATOR_VERDICT` (SAFE / MINOR / CRITICAL) +
  `MOCK_VALIDATOR_DIFF_SUMMARY` (override for MINOR).
- `CLAUDE_CODE_MEDIATOR=N` → write Mediator verdict per
  `MOCK_MEDIATOR_ACTION` (advice / surgical_fix / lockdown) +
  `MOCK_MEDIATOR_EVICT_SID` (target sid for surgical_fix
  evict_session — Phase 5 cycle_detected uses this).

Scenario 04 uses `MOCK_MEDIATOR_ACTION=surgical_fix
MOCK_MEDIATOR_EVICT_SID=sid-b-04-cycle` to verify the Mediator
verdict-write integrates correctly with the cycle_detected
producer (`coord_cycle_emit_pending` → mediator inline spawn →
verdict file written).

## init.sh helper functions

- `coord_fixture_init` — bootstrap workspace + install + force
  `wait_backend=polling` for deterministic latency assertions.
- `coord_fixture_p5_register_session <sid>` — add session row to
  sessions.json + create `.active` marker.
- `coord_fixture_p5_acquire <file> <sid> [<verdict_ts>]` — synthetic
  lock acquisition (bypasses Phase 4 pipeline; scenarios control
  the lock state directly).
- `coord_fixture_p5_release <file> <holder>` — delete lock entry +
  invoke `coord_notify_lock_release_waiters` with the captured
  verdict_ts (4-tier diff_summary chain from T5.04 fires).

All scenarios source these helpers from init.sh and define
`scenario_run` + `scenario_assert` per the Phase 4 ship-gate
contract.

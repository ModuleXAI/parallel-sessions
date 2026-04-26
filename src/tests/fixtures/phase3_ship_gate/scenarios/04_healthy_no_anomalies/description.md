# Scenario 04 — healthy system + manual escalation = no anomalies

Phase 3 plan §5 done-when criterion #4: "Running `/coord-mediate`
on a healthy system returns no anomalies detected."

The ship-gate sanity check: when the operator escalates manually
on a clean system, Mediator produces an `advice` verdict with no
state mutation.

## Timeline

1. Register Session A and Session B (healthy state — no locks,
   no stale activity).
2. Operator runs `coord mediate --reason "test escalation"`.
   Manual pending entry written.
3. Mediator spawns (mocked: fake claude binary writes verdict
   with action_type=advice, message_to_caller="No anomalies
   detected. System healthy.").
4. Verdict consumer applies (no actions to apply).
5. State unchanged.

## Assertions (scenario_assert)

D.1  Manual pending entry written (kind=manual, source=user_invocation).
D.2  Verdict file produced with action_type=advice.
D.3  No locks materialized.
D.4  No sessions evicted (count unchanged from setup).
D.5  No lockdown active.

## Mode

`hook-sim` only.

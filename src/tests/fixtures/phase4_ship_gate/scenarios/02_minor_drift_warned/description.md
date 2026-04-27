# Scenario 02 — minor_drift_warned

**Phase 4 ship-gate criterion:** Non-trivial-but-non-breaking drift
→ MINOR verdict via validator agent → banner with diff_summary →
proceed.

## Setup

1. Session A reads `utils.ts` (file with `parsed` local variable).
2. Session B renames `parsed` → `decoded` inside the function (real
   code change, not whitespace-only — pre-filter ESCALATES).
3. Session A attempts Write to a different file (`other.ts`).

Mock claude binary scripted via `MOCK_VALIDATOR_VERDICT=MINOR`.
Real `claude -p` spawn deferred to Phase 7 integration harness per
Decision 1.1.

## Expected behavior

A's `pre_tool_use_write.sh`:
- Stage 1 cache lookup → MISS.
- Stage 2 pre-filter → ESCALATE_TO_AGENT (non-trivial diff;
  variable rename is not whitespace-only).
- Stage 3 validator spawn (mock) → MINOR verdict.
- Cache write MINOR/validator_agent with diff_summary.
- Banner: "Drift on `utils.ts`: Variable rename inside function. No
  caller impact. Validator classified as MINOR. Proceeding."
- A's Write succeeds.

## Assertions

1. `VALIDATOR_PREFILTER_ESCALATED` event with
   `escalation_reason=non_trivial_diff`.
2. `VALIDATOR_SPAWN_STARTED` event present.
3. `VALIDATOR_VERDICT_MINOR` event present with `diff_summary`
   payload field.
4. `cache.json` contains a MINOR entry with non-empty `diff_summary`.
5. Hook stdout contains "Coord drift report" banner.
6. Hook stdout contains "MINOR" classification text.
7. Hook stdout contains "Variable rename" text (from mock's
   diff_summary).
8. NO `permissionDecision` emitted.
9. No lockdown active.

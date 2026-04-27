# Scenario 04 — validator_failure_failopen

**Phase 4 ship-gate criterion:** Validator binary unavailable →
pipeline fail-open → Phase 1 fallback warning banner → caller's
Write proceeds → no `permissionDecision`.

## Setup

1. Session A reads `complex.ts`.
2. Session B applies a non-trivial change (escapes pre-filter).
3. Session A attempts Write to a different file (`other.ts`).
4. Validator binary path REMOVED from PATH (so
   `coord_validator_spawn` fails with `claude_binary_missing`).

## Expected behavior

A's `pre_tool_use_write.sh`:
- Cache MISS, pre-filter ESCALATE.
- Validator spawn → `claude_binary_missing` → returns rc=1.
- `_coord_phase4_run_pipeline` returns rc=1.
- Caller's `if line=$(...)` form catches the failure → substitutes
  `_coord_phase4_phase1_fallback` warning text.
- Banner: "Drift on `complex.ts` (modified since read; pipeline
  failed). Pipeline unavailable; consider re-reading before
  proceeding."
- A's Write succeeds (lock acquired on `other.ts`); no
  `permissionDecision`.

## Assertions

1. `VALIDATOR_PREFILTER_ESCALATED` event present.
2. `VALIDATOR_SPAWN_FAILED` event with
   `reason=claude_binary_missing`.
3. `VALIDATOR_PIPELINE_FAILED` event present.
4. Hook stdout contains "Pipeline unavailable" Phase 1 fallback
   text.
5. NO `permissionDecision` emitted (fail-open).
6. A's Write succeeds (hook rc=0).
7. No spurious lockdown.
8. `cache.json` does NOT contain a SAFE/MINOR entry for this drift
   (no cache write on pipeline failure).

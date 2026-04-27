# Scenario 01 — safe_drift_silent

**Phase 4 ship-gate criterion:** Formatter-only / whitespace-only
change → SAFE verdict, silent.

## Setup

1. Session A reads `target.ts` (small file with code).
2. Session B applies a whitespace-only change (extra blank line).
3. Session A attempts `Write` to a different file (`other.ts`).

## Expected behavior

A's `pre_tool_use_write.sh` detects hash mismatch on `target.ts`
in A's read-set. Pipeline:
- Stage 1 cache lookup → MISS (no entry).
- Stage 2 pre-filter (`coord_validator_prefilter`) → SAFE
  (`whitespace_only` heuristic fires; `diff -w` produces empty).
- Cache write SAFE/prefilter.
- No banner emitted.
- A's Write succeeds (lock acquired).

Validator agent NOT spawned (cheap path; pre-filter handled it).

## Assertions

1. `VALIDATOR_PIPELINE_STARTED` event present for `target.ts`.
2. `VALIDATOR_PREFILTER_SAFE` event present with
   `prefilter_reason=whitespace_only`.
3. `VALIDATOR_PIPELINE_COMPLETED` event present.
4. NO `VALIDATOR_SPAWN_STARTED` event (pre-filter short-circuited).
5. `cache.json` contains a SAFE entry with `verdict_source=prefilter`.
6. Hook stdout does NOT contain "Coord drift report" banner.
7. Hook stdout does NOT contain `permissionDecision`.
8. No lockdown active.

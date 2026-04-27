# 03_diff_summary_on_release

**Goal:** verify Phase 5 diff_summary 4-tier chain Tier 1
(verdict_file lookup) integrates correctly with the lock record's
`latest_validator_verdict_ts` schema field (T5.04 / PR-PHASE5-02 §5).

**Scenario:**
1. Pre-write a validator verdict file at
   `.coord/validator/verdict/<ts>.json` with
   `verdict=MINOR` and `diff_summary="Variable rename inside function.
   No caller impact."`.
2. Holder A acquires lock on `/p/baz` WITH `latest_validator_verdict_ts=<ts>`
   (simulating the Phase 4 pipeline having run during A's pre-write
   hook turn and produced a fresh verdict).
3. Sessions B, C, D enqueue on `/p/baz`.
4. Holder A releases. `notify_waiters.sh` reads verdict_ts from lock
   record, looks up verdict file, broadcasts `diff_summary` to all 3
   wake_files.
5. All 3 wake_files contain identical "Variable rename..." text.
6. `NOTIFICATION_PRODUCED` event records
   `diff_summary_source=verdict_file` and `waiter_count=3`.

**Assertions:**
- B/C/D wake_file contents EXACTLY match the verdict's diff_summary.
- `NOTIFICATION_PRODUCED` event with `diff_summary_source=verdict_file`
  and `waiter_count=3` (single broadcast).
- No fresh validator/Mediator spawn during release (Tier 1 short-
  circuits before Tier 2/3/4).
- Phase 5 invariant: zero `permissionDecision`.

**Phase 5 done-when criterion (plan §5):**
"Wake-up context contains non-empty diff when lock-holder produced
changes."

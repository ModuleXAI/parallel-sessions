# 02_wake_file_event_driven

**Goal:** verify Phase 5 event-driven wake-up via the polling backend
(deterministic across hosts; init.sh forces `wait_backend=polling` so
the assertion budgets are host-independent).

**Scenario:**
1. Holder A acquires lock on `/p/bar`.
2. Session B issues `coord_wait_for_release_polling` on B's wake_file
   in a BACKGROUND subshell; captures start timestamp.
3. Holder A holds for 200ms (intentional delay; well under the
   5-second budget specified in the resume prompt — 5s is the upper
   bound for production but the fixture is deterministic + faster).
4. Holder A releases; `notify_waiters` writes diff_summary to B's
   wake_file.
5. B's polling backend detects content within ≤600ms (250ms cadence
   + observation overhead).
6. Capture end timestamp; compute total elapsed.

**Assertions:**
- B's `coord_wait_for_release_polling` returned rc=0 (wake-up
  detected, not timeout).
- B's wake_file has non-empty content after release.
- Total elapsed (start of B's wait → wake-up): 200ms hold +
  ≤600ms polling = ≤800ms total (<1500ms safety margin for CI
  variance).
- `WAIT_BACKEND` event payload `backend=polling` (init.sh forced
  this).

**Phase 5 done-when criterion (plan §5):**
"Wake-up context contains non-empty diff when lock-holder produced
changes." (covered by 03_diff_summary_on_release for the diff content
specifics; this scenario focuses on the latency budget.)

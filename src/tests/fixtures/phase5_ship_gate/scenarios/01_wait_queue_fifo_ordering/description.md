# 01_wait_queue_fifo_ordering

**Goal:** verify Phase 5 wait_queues FIFO arrival order is maintained
under multi-waiter enqueue + lock release sequence.

**Scenario:**
1. Holder D acquires lock on `/p/foo`.
2. Sessions A, B, C enqueue on `/p/foo` in arrival order (1ms apart so
   `waiting_since` ms-precision timestamps are strictly ascending).
3. D releases lock; `notify_waiters.sh` writes `diff_summary` to A's,
   B's, AND C's wake_files in one broadcast (single
   `NOTIFICATION_PRODUCED` event with `waiter_count=3`).
4. Each waiter dequeues itself in head-of-queue order (A first, then
   B, then C — simulating each waking up + retrying their write).
5. After all dequeues, `wait_queues[/p/foo]` is removed from
   sessions.json (clean state).

**Assertions:**
- `wait_queues[/p/foo]` length=3 after the 3 enqueues.
- `queue_position` is 0/1/2 for A/B/C respectively.
- Wake_files for A, B, C all contain identical "modified by D..."
  content after the release broadcast.
- `WAIT_QUEUE_ENQUEUED` event count = 3.
- After dequeues: `wait_queues` empty (key removed).
- `WAIT_QUEUE_DEQUEUED` event count = 3.
- Phase 5 invariant preserved: zero `permissionDecision` in any output.

**Phase 5 done-when criterion (plan §5):**
"Ordered wake-up verified with 3 sessions."

# 04_cycle_detected_mediator_evict

**Goal:** verify Phase 5 cycle detection + Mediator surgical_fix
eviction end-to-end. Mock Mediator returns `evict_session(sid-B)`;
fixture verifies the cycle_detected pending entry was written, the
Mediator inline spawn fired, and the surgical_fix verdict was
recorded for downstream apply.

**Scenario:**
1. A acquires lock on `/p/x`.
2. B acquires lock on `/p/y`.
3. A enqueues for `/p/y` (depth 1 — no trigger; silent half-cycle
   per T5.05 architectural note).
4. B enqueues for `/p/x` (depth 1 — no trigger; A↔B silent 2-cycle
   exists at this point).
5. C enqueues for `/p/x` (depth 2 → trigger fires from C). C is NOT
   in the cycle but trigger forces detection from C; DFS from C
   reaches /p/x → A (holder) → /p/y (A waits) → B (holder) → /p/x
   (B waits) → A (visited) → no cycle through C found.
6. Re-enqueue B onto /p/x with depth 2 still (we use B as the
   trigger session by re-issuing the enqueue; idempotent enqueue
   returns same wake_file but the trigger-from-B path runs DFS
   which finds B → /p/x → A → /p/y → B closure).

   Actually simpler approach: drop step 5 (C is just noise). After
   step 4, depth on /p/x is 1 (only B). Add a third session D
   enqueueing /p/x (depth 2) — C/D's enqueue triggers detection
   from C/D, but they're not in the cycle. To make trigger find
   the A↔B cycle, the trigger session must be in the cycle. So:
   - A waits /p/y (depth 1)
   - B waits /p/x (depth 1)
   - C waits /p/x (depth 2 from C; not in cycle → detection
     returns empty)
   - The trick: have B enqueue on /p/x AGAIN (idempotent) but
     SECOND while there's already a waiter on /p/x. Setup:
       A holds /p/x, B holds /p/y
       A enqueues /p/y (depth 1)
       D enqueues /p/y (depth 2, but D not in cycle → no detect)
       B enqueues /p/y (depth 3 from B, B IS in cycle → detect)
7. Mock Mediator returns surgical_fix evict_session(sid-B) per
   3-tier priority guidance.
8. Verdict file written at `.coord/mediator/verdict/<ts>.json`.

**Assertions:**
- `cycle_detected` pending entry written to `pending.jsonl` with
  9-key payload including `cycle_description` containing 3-tier
  guidance.
- Mediator verdict file written with `action_type=surgical_fix`
  and `actions=[{verb:evict_session, session_id:sid-B}]`.
- Phase 5 invariant: zero `permissionDecision` during cycle
  detection or Mediator spawn (deny only via existing lockdown
  gate, not exercised here).
- The CYCLE_DETECTED event was emitted.

**Phase 5 done-when criterion (plan §5):**
"Cycle introduced artificially triggers Mediator verdict that breaks
the cycle by selecting a session to evict or escalate."

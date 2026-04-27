# Scenario 03 — critical_drift_escalated

**Phase 4 ship-gate criterion:** Semantically breaking drift →
CRITICAL verdict → critical_drift pending entry → synchronous Mediator
inline → surgical_fix applied → caller's read-set cleared → caller
proceeds.

## Setup

1. Session A reads `api.ts` (function with old signature).
2. Session B changes the function signature (CRITICAL drift —
   callers will break).
3. Session A attempts Write to a different file (`other.ts`).

Both binaries (validator + Mediator) mocked via the init.sh fake
claude binary. Validator returns CRITICAL; Mediator returns
surgical_fix with `clear_read_set` action.

## Expected behavior

A's `pre_tool_use_write.sh`:
- Pre-filter ESCALATE → validator agent (mock) → CRITICAL.
- `_coord_phase4_handle_critical` writes critical_drift pending
  entry, spawns Mediator inline (mock returns surgical_fix), applies
  actions via `coord_verdict_apply_actions` (clear_read_set drops
  A's read-set entries), advances `last_consumed_verdict` pointer,
  composes banner from action_type + message_to_caller.
- Banner: "Critical drift on `api.ts` -> Mediator: surgical_fix;
  Mediator applied surgical_fix; retry your write."
- A's Write succeeds (lock acquired on `other.ts` after the inline
  Mediator returns; the per-file pipeline does not block lock
  acquisition for downstream files).

## Assertions

1. `VALIDATOR_VERDICT_CRITICAL` event present.
2. `critical_drift` entry written to `pending.jsonl`.
3. `VALIDATOR_VERDICT_CRITICAL_ESCALATED_TO_MEDIATOR` event present.
4. Mediator verdict file present in `.coord/mediator/verdict/`
   with `action_type=surgical_fix`.
5. `MEDIATOR_INLINE_VERDICT_APPLIED` event present.
6. `clear_read_set` action applied: A's `read_sets[].reads` length
   = 0 after.
7. `cache.json` does NOT contain a CRITICAL entry (CRITICAL never
   cached per PR-PHASE4-04).
8. `last_consumed_verdict` pointer file advanced for A.
9. Hook stdout contains "Critical drift" banner text.
10. Hook stdout does NOT contain `permissionDecision` (Phase 4
    invariant: deny routes through existing lockdown gate, not the
    CRITICAL pathway directly).
11. No lockdown active (Mediator chose surgical_fix, not lockdown).

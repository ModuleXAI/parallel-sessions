# 02_lock_deny — Phase 2 lock contention end-to-end

**Goal.** Validate the Phase 2 deny + release + notify cycle that
T2.01–T2.04 introduced. The 01_basic_warn scenario covered Phase 1's
read-set drift warning; this one covers everything that followed:
acquisition, contention deny with the §B.2 three-options reason,
release with notification population, and Phase 1's dormant
notification consumer becoming active.

## Timeline

1. Two sessions register: A (`sid-a-2sw-02-…`) and B (`sid-b-2sw-02-…`).
2. **A acquires** the lock on `foo.ts` via Write (PreToolUse).
3. **B is denied** on `foo.ts`. Capture B's hook stdout — this carries
   the §B.2 three-options `permissionDecisionReason`.
4. **A releases** the lock via PostToolUse on `foo.ts`. The release
   path:
    - emits `LOCK_RELEASED`,
    - scans `events.jsonl` for B's prior `LOCK_DENIED` in the hold
      window,
    - populates `notifications[B][foo.ts]` with the action-hint
      message,
    - emits `NOTIFICATION_PRODUCED` with `waiter_count=1`.
5. **B reads** `foo.ts` (PreToolUse Read). The Phase-1 consumer in
   `pre_tool_use_read.sh` delivers the queued notification via
   `additionalContext` and clears the bucket atomically.

## Assertions

| ID  | Check                                                                    |
|-----|--------------------------------------------------------------------------|
| B.1 | B's hook exit 0 (deny is signaled via JSON, not shell exit)              |
| B.2 | B's stdout contains `permissionDecision` field with value `"deny"`       |
| B.3 | B's reason cites `foo.ts` and contains "Locked by session"               |
| B.4 | B's reason has all three option markers `(a)` `(b)` `(c)`                |
| B.5 | (a)/(b) reference `coord task-open` / `coord self-delegate` abstractly   |
| B.6 | B's reason does NOT freeze Phase 6 syntax (`task-open --file`)           |
| B.7 | (c) shows full `coord wait foo.ts --timeout 570` invocation              |
| B.8 | Reason carries both `acquired` + `last activity` ages                    |
| B.9 | events.jsonl: A's LOCK_ACQUIRED → B's LOCK_DENIED → A's LOCK_RELEASED    |
| B.10| events.jsonl: NOTIFICATION_PRODUCED with waiter_count=1                  |
| B.11| sessions.json: notifications[B][foo.ts] populated post-release           |
| B.12| B's subsequent Read delivers the notification via additionalContext      |
| B.13| B's bucket is cleared after delivery (length 0 in sessions.json)         |
| B.14| Phase 1 invariant preserved: only B's deny carries permissionDecision    |

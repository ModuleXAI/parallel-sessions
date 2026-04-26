# Scenario 01 — SIGKILL → cleanup

Phase 3 plan §5 done-when criterion #1: "SIGKILL a session; within
`watchdog_confirm_seconds` another session's hook cleans up its locks
and read-set."

## Timeline

1. Register Session A (`sid-a`) and Session B (`sid-b`) via the
   SessionStart hook.
2. Session A acquires the lock on `foo.ts` via PreToolUse(Write).
3. Simulate SIGKILL by mutating `sessions.json` so Session A's row
   has a PID that is provably absent (`99999`) and stale activity
   (>10 min ago). The lock entry remains under A's name, but A's
   PID is gone — exactly the post-SIGKILL state per Phase 0
   Experiment #6.
4. Session B's `pre_tool_use_any.sh` runs. Ambient-suspicion scan
   detects A's stale activity + PID-gone → fires watchdog probe.
5. Watchdog probe (synchronous in the fixture for determinism)
   confirms PID gone → verdict=dead/pid_gone → emits pending
   entry kind=stale_active source=watchdog.
6. Mediator spawns (mocked: fake claude binary writes a verdict
   with action_type=surgical_fix + actions=[release_lock,
   evict_session]).
7. Session B's NEXT `pre_tool_use_any.sh` consumes the verdict →
   applies actions via `verdict_apply` pipeline → A's session
   removed + A's lock on foo.ts released.
8. Session B can now acquire the lock on foo.ts (no contention).

## Assertions (scenario_assert)

A.1  Session A's row removed from `sessions.json`.
A.2  Lock on foo.ts removed from `sessions.json` (or held by B).
A.3  Pending entry kind=stale_active was written to pending.jsonl.
A.4  MEDIATOR_VERDICT event recorded in events.jsonl.
A.5  Session B's PreToolUse(Write) on foo.ts succeeds (no deny).
A.6  No spurious lockdown.json present (this is a surgical_fix,
     not a system-wide lockdown scenario).

## Mode

`hook-sim` only. Real-mode (Phase 7) would drive actual Claude Code
sessions and SIGKILL one of them; that integration is deferred.

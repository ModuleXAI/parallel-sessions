# Scenario 02 — 20-min reasoning session NOT evicted

Phase 3 plan §5 done-when criterion #2: "Legitimate 20-minute
reasoning session (with occasional tool calls refreshing
last_activity) is NOT evicted."

This is the false-positive prevention test. A long-running session
that's THINKING (no tool calls in a while) but whose process is
still alive must not be killed by the watchdog.

## Timeline

1. Register Session A and Session B.
2. Session A acquires lock on foo.ts.
3. Mutate sessions.json so A's last_activity is stale (>10 min ago)
   BUT pid + pid_lstart match the current bash process (which is
   alive). This simulates a real 20-min reasoning gap.
4. Session B's pre_tool_use_any.sh fires ambient-suspicion scan.
   A is flagged for stale activity (>600s).
5. Watchdog probes A: PID alive + lstart matches → verdict=alive.
6. NO Mediator spawn. NO eviction.

## Assertions (scenario_assert)

B.1  A's session row STILL present in sessions.json.
B.2  A's lock on foo.ts STILL held.
B.3  Watchdog wrote alive verdict to recent_checks.jsonl.
B.4  No MEDIATOR_VERDICT events recorded.
B.5  pending.jsonl has NO stale_active entries from watchdog.
B.6  No lockdown active.

This is the watchdog's primary protective duty — distinguishing
"thinking" sessions from dead ones.

## Mode

`hook-sim` only.

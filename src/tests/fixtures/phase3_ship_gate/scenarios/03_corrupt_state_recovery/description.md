# Scenario 03 — corrupt sessions.json → critical bypass → operator recovery

Phase 3 plan §5 done-when criterion #3: "Corrupt sessions.json →
Mediator resets + logs; next session operation works."

T3.07 PR-PHASE3-01 disposition: critical-conditions bypass triggers
lockdown directly when sessions.json fails jq parse 3+ consecutive
times — Mediator's own analysis would inherit the corrupt state.
The recovery path is OPERATOR-DRIVEN: user runs `coord mediate
--resume` after either fixing the file manually or accepting the
auto-reset done by atomic_write.sh.

## Timeline

1. Register Session A.
2. Trigger 3 consecutive parse failures by re-corrupting
   sessions.json before each atomic_edit attempt.
3. After the 3rd failure, critical bypass activates lockdown
   with reason_source=critical_bypass + emits
   CRITICAL_CONDITION_DETECTED event.
4. Operator runs `coord mediate --resume` (the documented manual
   recovery path).
5. Lockdown clears; sessions.json (auto-reset by atomic_write
   during one of the parse-failure paths) is parseable.

## Assertions (scenario_assert)

C.1  After step 3: `.coord/mediator/lockdown.json` exists with
     reason_source=critical_bypass.
C.2  CRITICAL_CONDITION_DETECTED event recorded.
C.3  After step 4: lockdown.json is gone.
C.4  Cleared lockdown archived to lockdown_archive/<ts>.cleared.json.
C.5  sessions.json now parses cleanly (auto-reset succeeded).

## Mode

`hook-sim` only.

# Scenario 01 — Basic stale-read warning

**Goal.** Verify Phase 1 done-when criterion #1 — Session A's Write after
Session B modified a file Session A had read produces a stale-read
`additionalContext` warning citing the modified file. The Write is still
allowed (no `permissionDecision`) per the Phase 1 ship gate.

## Hook-sim timeline (deterministic; runs in CI)

1. Register Session A via `session_start.sh` with `source=startup`.
2. Register Session B via `session_start.sh` with `source=startup`.
3. Session A reads `foo.ts` via `pre_tool_use_read.sh` — A's read_set now
   contains `foo.ts` with hash H1.
4. Session B writes `foo.ts`:
   - Invoke `pre_tool_use_write.sh` as B (allowed, no warning — B has
     no read of foo.ts in its read_set).
   - Mutate `foo.ts` on disk to v2 (representing B's tool execution; in
     Phase 1 there is no PostToolUse hook to release a lock and there are
     no locks).
5. Session A attempts to write `bar.ts` via `pre_tool_use_write.sh`. The
   hook walks A's read_set, recomputes `foo.ts`'s sha256 (now H2 ≠ H1),
   and emits the stale-read warning.

## Assertions

After step 5:
- A's `pre_tool_use_write.sh` exit status is `0` (allow — never deny).
- A's stdout contains `additionalContext` mentioning `foo.ts` AND
  the substring `stale-read warning`.
- A's stdout does NOT contain `permissionDecision` (Phase 1 invariant).
- `events.jsonl` contains a `STALE_READ_WARNED` event with `session = SID_A`
  and `stale_count >= 1`.
- B's earlier `pre_tool_use_write.sh` produced no stale-read warning (B's
  read_set was empty at that point).

## Real-claude timeline (Phase 7 extension)

In Phase 7's `--mode=real`, this scenario runs as two parallel `claude -p`
processes:

- **Session A prompt:** "Read foo.ts in this directory, then write a new
  file bar.ts containing 'export const bar = \"v2\";'."
- **Session B prompt:** "Modify foo.ts to set the foo constant to 'v2'."

Sequencing is enforced via barriers (sleep + wait_queue inspection) so
that A's Read precedes B's Write, and A's Write follows B's Write. The
same assertions on `events.jsonl` apply.

Phase 7 will implement this in
`src/tests/manual/two_session_warn.sh --mode=real`. It is **stubbed** in
Phase 1 and exits 77 (skip) when invoked.

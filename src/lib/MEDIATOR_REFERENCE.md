# MEDIATOR_REFERENCE.md — Phase 3 Mediator Technical Reference

**Audience:** the Mediator agent itself (a `claude -p` spawned
session). The Mediator is invoked with a 3-section system prompt;
the System Constraints section names this file as the deep
reference. Read sections on demand via `Read` (NOT prophylactically).

**Layout:** `.coord/mediator/MEDIATOR_REFERENCE.md` (installed by
`install.sh`; copied from `src/lib/MEDIATOR_REFERENCE.md`).

**Philosophy:** the Mediator's prompt is short by design — five
core rules. This file provides the full technical detail: schemas,
helper signatures, ordering rules, communication contract.

---

## 1. Verdict JSON Schema (full field reference)

Every Mediator invocation MUST write exactly one verdict file at
`.coord/mediator/verdict/<ts>.json` with the following shape:

```json
{
  "verdict_id": "<UUID v4 — generate with uuidgen or shasum>",
  "ts": "<ISO 8601 UTC timestamp, e.g., 2026-04-26T03:55:00.000Z>",
  "for_pending_entry": "<reference to the triggering pending.jsonl entry — preferably the entry's ts field>",
  "mediator_session_id": "<your spawn-session UUID — claude -p assigns this; you can read it via $CLAUDE_CODE_SESSION_ID env or from .coord/sessions of your own bash session>",
  "depth": 1,

  "action_type": "advice" | "surgical_fix" | "lockdown",
  "severity": "brief" | "extended" | null,
  "confidence": "auto_apply" | "needs_review",

  "reasoning": "<2-5 sentences: what you observed, why this verdict>",

  "actions": [
    { "op": "release_lock", "target": "<file_path>", "session": "<sid>" },
    { "op": "evict_session", "session": "<sid>" },
    { "op": "clear_read_set", "session": "<sid>" }
  ],

  "message_to_caller": "<text shown to the session that triggered the pending entry; appears as additionalContext on its next tool call>",
  "message_to_others": "<text shown to ALL active sessions; lockdown action only — null otherwise>",

  "spawn_metadata": {
    "duration_ms": <int — how long your invocation took, from spawn helper>,
    "model": "<model name, e.g., claude-haiku-4-5-20251001>",
    "spawn_mode": "no_bare" | "bare"
  }
}
```

### Field constraints

- `severity` is **required and not null** when `action_type ==
  "surgical_fix"`; **must be null** otherwise.
- `message_to_others` is **required** when `action_type ==
  "lockdown"`; **must be null** otherwise.
- `actions` is empty array `[]` when `action_type == "advice"`
  (advice has no state changes).
- `actions` is empty array `[]` when `action_type == "lockdown"`
  (lockdown writes lockdown.json directly via your Bash tool;
  the action verbs in this array are for sessions/locks/read-sets).
- `confidence == "auto_apply"` means: apply the verdict
  immediately. `confidence == "needs_review"` means: the hook
  layer will spawn a peer Mediator at depth=2 with your verdict in
  context for cross-validation.
- `depth == 1` for primary Mediator invocation; `depth == 2` for
  peer review. NEVER submit `depth == 3` — that is automatic user
  escalation territory.

### Action verbs

| op | Required fields | Effect |
|---|---|---|
| `release_lock` | `target` (file path), `session` (lock holder) | Atomically removes `locks[<file>]` if held by `<session>`. Idempotent. |
| `evict_session` | `session` | Removes `sessions[<sid>]` AND any locks/read_sets/notifications/self_tasks referencing it. Removes `.active` marker. |
| `clear_read_set` | `session` | Sets `read_sets[<sid>].reads = []` without removing the session row. |

Apply **ordering rules** (the hook layer pre-sorts before
applying):

1. `lockdown` (if `action_type == "lockdown"`) takes effect first
   — Mediator writes `.coord/mediator/lockdown.json` BEFORE any
   actions[] mutation.
2. `release_lock` BEFORE `evict_session` for the same session
   (otherwise eviction races against held-lock state).
3. `clear_read_set` is independent — runs anytime.

If you emit actions in violation of these rules, the hook layer
re-sorts them. Idempotent helpers tolerate misordering, but
emitting actions in the correct order yields cleaner audit logs.

---

## 2. Lockdown.json schema + clearing protocol

**Path:** `.coord/mediator/lockdown.json`

```json
{
  "active": true,
  "reason": "<human-readable text shown in deny banner>",
  "reason_source": "mediator_verdict" | "critical_bypass",
  "started_at": "<ISO 8601 UTC>"
}
```

### Activate (you do this for action_type=lockdown)

Use the helper from your Bash tool:
```bash
. .coord/lib/log_event.sh
. .coord/lib/lockdown.sh
coord_lockdown_activate "Mediator pause: <your reason>" "mediator_verdict"
```

The helper handles atomic temp+rename and emits
`LOCKDOWN_ACTIVATED` event with payload.

### Clear (you do this AFTER applying state mutations)

```bash
coord_lockdown_clear
```

Atomic rename: `lockdown.json → lockdown_archive/<ts>.cleared.json`.
Emits `LOCKDOWN_CLEARED` event with `archived_to` payload.

**Existence-based gate:** every coord hook checks
`[ -f .coord/mediator/lockdown.json ]` before its main work. The
file existing means "system paused"; clearing it (rename to
archive) means "resume." There is no `active=false` retention
state — cleared lockdowns live in archive only.

### Apply ordering for lockdown verdicts

```
1. coord_lockdown_activate "<reason>" "mediator_verdict"
2. Apply actions[] in sorted order (release_lock → evict_session,
   clear_read_set anywhere)
3. Verify state consistency (read sessions.json, confirm expected
   shape)
4. coord_lockdown_clear
5. Write verdict file
```

If you crash between steps 1 and 4, lockdown remains active —
operator must run `coord mediate --resume` (T3.08). This is
intentional fail-safe: stuck-lockdown is recoverable; corrupt
state during lockdown-clear-without-cleanup is not.

---

## 3. atomic_write.sh helpers (state mutation)

You MUST use these helpers for every state mutation.
Edit/Write/NotebookEdit are forbidden by your spawn flags
(`--disallowedTools Write Edit NotebookEdit`).

```bash
. .coord/lib/log_event.sh        # for coord_log_event + coord_now_iso8601
. .coord/lib/mediator_pending.sh  # for coord_mediator_emit_pending
. .coord/lib/atomic_write.sh     # the main mutator
```

### Primary mutator

```bash
coord_atomic_edit <state_file> <jq_filter> [<jq_args> ...]
```

- `<state_file>` is normally `$COORD_DIR/sessions.json`.
- `<jq_filter>` is a jq expression that transforms the state.
  Use `--arg key value` to pass shell variables in.
- Returns 0 on success; 42 on flock timeout (>5s); 43 on jq error;
  44 on write failure.

Example: release a stuck lock:
```bash
coord_atomic_edit "$COORD_DIR/sessions.json" \
  'del(.locks[$f])' \
  --arg f "/some/file.txt"
```

Example: evict a session:
```bash
coord_atomic_edit "$COORD_DIR/sessions.json" '
    del(.sessions[$sid])
  | .locks |= with_entries(select(.value.session != $sid))
  | del(.read_sets[$sid])
' --arg sid "the-dead-session-uuid"
```

### Atomic JSONL rewrite

```bash
coord_atomic_rewrite_jsonl <jsonl_file> <jq_filter>
```

For mass-filter operations on append-only JSONL files (e.g.,
pending.jsonl GC). The filter is applied per-entry; entries
emitting non-null output are kept.

---

## 4. Pending queue (read + GC)

**Path:** `.coord/mediator/pending.jsonl` — append-only.
**HWM:** `.coord/mediator/pending.consumed` — single integer line
indicating the count of entries already surfaced via banner. Every
hook firing advances HWM after consume.

### Pending entry schema

```json
{
  "ts": "<ISO 8601 UTC>",
  "kind": "<corrupt_state | flock_timeout | stale_active | pid_recycled | manual>",
  "session": "<the session that emitted; may be the watchdog-observer>",
  "source": "<atomic_write | watchdog | coord_mediate | ...>",
  "payload": {
    "<arbitrary key=value pairs>"
  }
}
```

### Read entries (you can do this via cat/jq)

```bash
# All unconsumed entries (above HWM):
hwm=$(cat .coord/mediator/pending.consumed 2>/dev/null || echo 0)
tail -n +$((hwm + 1)) .coord/mediator/pending.jsonl | jq -c .
```

### GC (you trigger this AT THE END of your verdict-write pass)

```bash
coord_mediator_gc_pending 24   # hours retention; default 24
```

Atomic rewrite under flock. Keeps unconsumed entries + recently-
consumed (<24h). Rebases HWM. Emits `PENDING_GC_RUN` event.

---

## 5. Lock release mechanism (manual)

If your verdict prefers a direct lock release without going through
the hook-layer apply pipeline (e.g., for surgical_fix-extended
that releases multiple locks in one transaction), use the
`atomic_edit` jq filter directly:

```bash
coord_atomic_edit "$COORD_DIR/sessions.json" \
  '.locks |= with_entries(select(.value.session != $sid))' \
  --arg sid "<dead-session-id>"
```

This deletes ALL locks held by `<dead-session-id>` in one atomic
write. Equivalent to issuing N `release_lock` actions but with
fewer round-trips.

Best practice: prefer the actions[] array form when possible (better
audit log via per-lock LOCK_RELEASED events). Use the bulk-edit
form only when the session is being evicted entirely.

---

## 6. Event log format

All events go to `.coord/events.jsonl` via:
```bash
coord_log_event kind=<KIND> [<key>=<value> ...]
```

### Common kinds you might emit

| Kind | When | Required payload |
|---|---|---|
| `MEDIATOR_VERDICT` | After writing verdict file | `verdict_id, action_type, confidence, scope, depth` |
| `MEDIATOR_USER_APPROVED` | If user pre-approved an action via `coord mediate --approve` | `verdict_path, approved_action` |
| `LOCKDOWN_ACTIVATED` / `LOCKDOWN_CLEARED` | Via lockdown.sh helpers (auto-emit) | (helpers handle this) |
| `LOCK_RELEASED` | Via verdict_apply.sh helpers (auto-emit) | (helpers handle this) |
| `SESSION_EVICTED` | Via verdict_apply.sh helpers (auto-emit) | (helpers handle this) |
| `READ_SET_CLEARED` | Via verdict_apply.sh helpers (auto-emit) | (helpers handle this) |
| `PENDING_GC_RUN` | Via coord_mediator_gc_pending (auto-emit) | (helpers handle this) |
| `CRITICAL_CONDITION_DETECTED` | Manual escalation if you detect a state too degraded for verdict | `condition, triggering_observation` |

You typically don't need to call coord_log_event directly — the
helpers auto-emit. Only emit MEDIATOR_VERDICT manually after
writing the verdict file.

---

## 7. Caller communication contract

Your verdict's `message_to_caller` field is surfaced to the session
that triggered the pending entry. The hook layer
(`pre_tool_use_any.sh`) reads new verdict files on every tool call
and composes them into `additionalContext` for the caller's next
turn.

### Format

- 1-3 sentences, plain text, no apostrophes (F-014 lesson).
- Concrete: name the file/session/lock that's affected.
- Actionable when possible: tell the caller what to do next.

### Examples

```
"Released stuck lock on /src/foo.ts (held by session abc123... for 35min, never refreshed). Retry your write."

"Evicted session abc123... — its PID was recycled (lstart mismatch). All its locks released. Resume work."

"No anomaly confirmed for session abc123... — its activity is recent and PID matches. False alarm. Continue."
```

### `message_to_others` (lockdown only)

When you trigger lockdown, this text appears in the `reason` field
of `lockdown.json`. Every coord hook reads that and emits a deny
banner with the text. Format:

```
"<one-sentence summary of why everyone is paused>"
```

Example:
```
"Mediator is releasing 4 orphan locks from session abc123... Wait 30 seconds before retrying."
```

---

## 8. Recursion guard

Your environment includes `CLAUDE_CODE_MEDIATOR=<depth>` (1 for
primary, 2 for peer review). The hook-layer spawn helper refuses
to spawn another Mediator if it detects this env var (i.e.,
prevents YOU from accidentally spawning a third Mediator via your
Bash tool).

If you find yourself wanting to spawn another `claude -p` for any
reason, **don't** — it will fail. Instead:
- For sub-problem reasoning: use your own context to think through
  the issue.
- For verification of a heavy state mutation: use Bash to run
  `coord status` or read state files directly.

---

## 9. Spawn modes (for your context)

You may be spawned in one of two modes (both transparent to you;
the `spawn_metadata.spawn_mode` field captures which):

- **`bare`**: parent set `ANTHROPIC_API_KEY` and your spawn used
  `--bare`. Hooks do not fire for your tool calls. Faster startup,
  cheaper.
- **`no_bare`** (subscription mode): parent has only OAuth/keychain
  auth. Your spawn ran with `CLAUDE_COORD=0` set so coord hooks
  early-exit. Slower startup, ~$0.10/invocation cost.

Either way, your tool calls are isolated from the coord layer. You
read coord state via `cat`/`jq`; you mutate via the atomic_write
helpers.

---

## 10. What you do NOT do

- **Do not use `Edit`, `Write`, or `NotebookEdit` tools.** Your
  spawn flags forbid these. Use `Bash` + atomic_write helpers.
- **Do not spawn another `claude -p`.** Recursion guard prevents
  this; attempting wastes time + cost.
- **Do not mutate state files outside `.coord/`.** Your authority
  is coord state only — never touch user code, git config, etc.
- **Do not skip writing a verdict file.** Even if your action_type
  is `advice` (no mutation), the verdict file is the audit record.
- **Do not emit verdicts at depth > 2.** That triggers automatic
  user escalation — your spawn flags should prevent this; if you
  see depth 3 in your env, halt with `action_type=advice` +
  `message_to_caller="depth limit exceeded"` + return.

---

## Appendix: example verdict for "release orphan lock"

Triggering pending entry (in pending.jsonl):
```json
{"ts":"2026-04-26T04:00:00Z","kind":"stale_active","session":"observer-001",
 "source":"watchdog","payload":{"target":"abc-dead-session","verdict":"dead",
 "reason":"PID 12345 is gone (no ps record)","subkind":"pid_gone"}}
```

Your verdict file (`.coord/mediator/verdict/2026-04-26T04-00-15Z.json`):
```json
{
  "verdict_id": "5e6f7c89-1234-...",
  "ts": "2026-04-26T04:00:15.123Z",
  "for_pending_entry": "2026-04-26T04:00:00Z",
  "mediator_session_id": "1d2d8047-fe76-4d09-...",
  "depth": 1,
  "action_type": "surgical_fix",
  "severity": "brief",
  "confidence": "auto_apply",
  "reasoning": "Watchdog confirmed PID 12345 is gone. Session abc-dead-session held one lock on /src/foo.ts for 47 minutes without refresh. PID recycled check shows no current process matches. Safe to release lock and evict session.",
  "actions": [
    { "op": "release_lock", "target": "/src/foo.ts", "session": "abc-dead-session" },
    { "op": "evict_session", "session": "abc-dead-session" }
  ],
  "message_to_caller": "Released stuck lock on /src/foo.ts and evicted session abc-dead-session... (its PID was gone for 47 min). Retry your write.",
  "message_to_others": null,
  "spawn_metadata": {
    "duration_ms": 18432,
    "model": "claude-haiku-4-5-20251001",
    "spawn_mode": "no_bare"
  }
}
```

The hook layer picks this up on the caller's next tool call,
applies the actions in order (release_lock → evict_session),
clears the verdict from the unread queue, and surfaces
`message_to_caller` as `additionalContext`.

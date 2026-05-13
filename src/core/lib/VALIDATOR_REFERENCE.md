# VALIDATOR_REFERENCE.md — Phase 4 Validator Technical Reference

**Audience:** the Validator agent itself (a `claude -p` spawned
session). The Validator is invoked with a 3-section system prompt;
the System Constraints section names this file as the deep
reference. Read sections on demand via `Read` (NOT prophylactically).

**Layout:** `.coord/validator/VALIDATOR_REFERENCE.md` (installed by
`install.sh`; copied from `src/core/lib/VALIDATOR_REFERENCE.md`).

**Philosophy:** the Validator's prompt is short by design — five
core rules. This file provides the full technical detail: schemas,
classification heuristics, diff-summary conventions, hand-off
contract.

---

## 1. Purpose

You classify file drift between two versions:
- **Read snapshot** — the version a session read, captured at Read
  time and stored at `.coord/read_snapshots/<sid>/<hash>.txt`.
- **Current state** — the version on disk now.

You return ONE of three verdicts:
- **SAFE** — the change cannot break any caller. Pipeline proceeds
  silently.
- **MINOR** — the change may surprise a caller but cannot break
  them. Pipeline proceeds with a banner showing your `diff_summary`.
- **CRITICAL** — the change can break callers. Pipeline writes a
  `kind=critical_drift` pending entry; the Mediator picks it up on
  the next tool call (or inline within the same hook invocation per
  PR-PHASE4-02 synchronous-CRITICAL semantics) and decides
  advice / surgical_fix / lockdown.

**You are invoked when:**
1. A coordinated session attempts a Write/Edit on a file whose
   `read_sets[<sid>].reads[]` entry is stale (hash mismatch with
   current on-disk content).
2. The cache lookup at `.coord/validator/cache.json` returned MISS
   for the (file, read_hash, current_hash) triple.
3. The Bash pre-filter (`lib/validator_prefilter.sh`) returned
   ESCALATE_TO_AGENT — the drift was non-trivial enough that the
   pre-filter could not classify it as SAFE.

You are NOT invoked for trivial drifts (whitespace-only,
blank-line-only, comment-only on files without multi-line string
markers); the pre-filter handles those and writes their verdicts
directly to the cache.

**You do not take actions on state.** Mediator handles all state
mutations (lock release, session eviction, read-set clearing). Your
job is classification only. The spawn helper post-processes your
verdict file (injects `validator_session_id`, augments
`spawn_metadata`) before downstream consumers read it.

---

## 2. Verdict JSON Schema (full field reference)

Every Validator invocation MUST write exactly one verdict file at
`.coord/validator/verdict/<ts>.json` with the following shape:

```json
{
  "verdict_id": "<UUID v4 — generate with uuidgen or shasum>",
  "ts": "<ISO 8601 UTC timestamp, e.g., 2026-04-26T03:55:00.000Z>",
  "for_pending_entry": null,
  "validator_session_id": "<placeholder; spawn helper injects real UUID>",

  "file": "<path the caller is attempting to write>",
  "session": "<caller session_id>",
  "verdict": "SAFE" | "MINOR" | "CRITICAL",

  "reasoning": "<2-5 sentences plain text explaining your classification>",
  "diff_summary": "<1-3 sentences plain text describing what changed>",

  "spawn_metadata": {
    "duration_ms": <int — spawn helper injects measured wall-clock>,
    "model": "<model name, e.g., claude-haiku-4-5-20251001>",
    "spawn_mode": "no_bare",
    "spawn_session_id": "<UUID — spawn helper injects from claude -p top-level session_id>",
    "total_cost_usd": <float — spawn helper injects from claude -p .total_cost_usd; Phase 7 cost-tracking source>
  }
}
```

### Field constraints

- `verdict_id` is a UUID v4. Use `uuidgen` if available, otherwise
  any unique string with reasonable entropy.
- `ts` is the ISO 8601 UTC timestamp at verdict-write time. Should
  match the filename (with colons and dots replaced by hyphens).
- `for_pending_entry` is **always null** for Validator verdicts.
  This field is reserved for Mediator verdicts that reference the
  triggering pending entry; Validator does not consume pending
  entries.
- `validator_session_id` — write a placeholder string. The spawn
  helper (`lib/validator_spawn.sh`) post-processes the file to
  inject the real `claude -p` spawn UUID.
- `file` is the path the caller's Write is targeting (provided in
  Section 3 of your prompt as item (a)).
- `session` is the caller's session_id (provided in Section 3
  drift context).
- `verdict` enum is exactly `{SAFE, MINOR, CRITICAL}`. No other
  values permitted.
- `reasoning` is your detailed explanation (2-5 sentences).
  Plain text. **No apostrophes** per F-014 lesson — use "is not"
  rather than `isn't`. ASCII only; the bats test harness has
  apostrophe-fragility in some test scaffolds (resolved at code
  level but the doctrine prevents reintroduction).
- `diff_summary` is a tight 1-3 sentence description of the drift.
  See §4 below for format conventions.
- `spawn_metadata` — the spawn helper injects most fields; you can
  emit a placeholder structure and the helper will overwrite
  `duration_ms`, `model`, `spawn_mode`, `spawn_session_id`,
  `total_cost_usd`.

### Fields you do NOT include (Mediator-specific)

The following appear in Mediator verdicts but **must not** appear
in Validator verdicts:

- `actions[]` — Validator does not propose state changes.
- `confidence` — Validator does not have a needs_review path
  (depth-1 only).
- `severity` — no surgical_fix gradient.
- `message_to_caller` — caller-facing text is the `diff_summary`
  for MINOR or the entire pending-entry banner for CRITICAL.
- `message_to_others` — only Mediator uses this (lockdown only).

If you include any of these, the spawn helper does not strip them
but downstream consumers ignore them.

---

## 3. Drift classification heuristics

The decision rule, in priority order:

> **Can callers of this code break because of the change?**
> - Yes → CRITICAL
> - Probably not, but they may behave differently → MINOR
> - No → SAFE

### SAFE examples

A SAFE verdict means the change is invisible to callers of the
file's exported surface. Examples:

- **Formatter-only changes:** indentation, line wrapping, trailing
  comma additions, sort order of imports (when imports are
  unused / order-insensitive).
- **Comment additions or rewordings:** `// happy path` added
  inside a function body; docstring rephrased without changing
  parameter names or return types.
- **Blank-line additions:** spacing change between definitions.
- **License header additions or updates** at the top of a file.
- **Unused-import reorder** when the imports' presence is
  unchanged.
- **Stylistic rename of a private (non-exported) helper** when no
  other file references the helper's name.

Concrete reasoning template for SAFE:

> "Change is <kind>. No exported signatures, types, or behavior
> affected. Callers cannot be broken by this change."

### MINOR examples

A MINOR verdict means a caller's behavior could subtly differ but
no caller would fail to compile / run / pass tests. Examples:

- **Local variable renamed inside a function** (e.g., `parsed`
  → `decoded`). The function's signature and return value are
  unchanged.
- **String literal changed** in a way that does not affect type or
  validity (e.g., a log message reworded).
- **Test added** in a `*.test.ts` or similar file that does not
  modify production code paths.
- **Typo fixed** in a comment, docstring, or error message string.
- **New private function added** that is not exported.
- **Internal refactor** that reshuffles private code paths but
  preserves all public behavior.

Concrete reasoning template for MINOR:

> "Change <verb> <thing> inside <scope>. Function signature,
> behavior, and callers are unaffected. <Optional surprise note>."

### CRITICAL examples

A CRITICAL verdict means a caller can break: a runtime error, a
type error, a behavior change with downstream impact, or a data
schema change that callers cannot ignore. Examples:

- **Function signature changed:** new required parameter, parameter
  removed, parameter type narrowed, return type changed (especially
  if return type expanded to include `null` or new error states).
- **Exported variable / constant removed** or renamed.
- **Type definition changed:** field added, field removed, field
  type narrowed; interface contract altered.
- **Database / API schema migration in progress:** column added,
  column removed, column type changed.
- **Behavior reversal:** a function that previously returned on
  failure now throws; a function that was idempotent now is not.
- **Dependency upgrade with breaking changes** even if the upgrade
  itself is just a version bump in a manifest.
- **Security-relevant change:** authentication check removed,
  permission narrowing/widening.

Concrete reasoning template for CRITICAL:

> "Function signature changed: <change description>. Callers that
> depend on the old <signature/return type/behavior> will <fail
> to compile / fail to run / silently produce wrong results>. This
> requires Mediator escalation."

### Edge cases

- **Mixed change** (some lines clearly SAFE + some clearly
  CRITICAL) → classify as CRITICAL. The CRITICAL parts dominate.
- **Cannot tell from the diff alone** (e.g., the change is to a
  file you have not seen before, and the type of code is
  unfamiliar) → use Bash + Read to inspect related files
  (imports, callers, tests) before deciding. If still unsure,
  classify as CRITICAL — false-positive MINOR/CRITICAL is
  acceptable; false-negative SAFE is dangerous.
- **Change is to a test file or fixture** → likely MINOR (tests
  do not have callers in the production sense). But if the test
  asserts a contract that production code depends on, treat as
  CRITICAL.
- **Change is to a generated file** (e.g., `*.gen.ts`,
  `dist/*.js`) → likely SAFE because the source of truth is
  elsewhere; but verify the file path's `*.gen.*` or `dist/`
  location before declaring SAFE.

---

## 4. Diff-summary format conventions

Your `diff_summary` field appears in:
- The MINOR banner shown to the caller via `additionalContext`
  on its next tool call ("Drift on `<file>`: <diff_summary>.
  Validator classified as MINOR. Proceeding.").
- The CRITICAL pending entry payload, which the Mediator embeds
  in its prompt context (Section 3 — Incident Context) as the
  primary description of what changed.

Both consumers benefit from a tight, specific, first-paragraph
description.

### Format rules

- **1-3 sentences.** Longer descriptions belong in `reasoning`,
  not `diff_summary`.
- **Plain text.** No markdown, no code blocks, no ASCII art.
- **No apostrophes** per F-014 lesson. Use "is not" / "does not"
  / "will not" instead of contractions. Banners may flow through
  shell scaffolding that is apostrophe-fragile (resolved at code
  level via `_grep_output_for` helper, but the doctrine prevents
  regressions).
- **Tense:** descriptive past or present. "Variable renamed from
  X to Y." or "Function signature now requires options parameter."
  Avoid future tense.
- **Specificity:** name what changed. Variable names, function
  names, line numbers when helpful. The Mediator's reasoning will
  be better when your `diff_summary` is concrete.

### Good examples

- "Local variable renamed from `parsed` to `decoded` inside
  `checkAuth` function. No functional change."
- "Function `fetchUser` signature now requires an `options`
  parameter. Return type expanded from `Promise<User>` to
  `Promise<User | null>`. Behavior changed to return null on
  failed response."
- "Indentation changed from 2 spaces to 4 spaces throughout file.
  No semantic change."
- "Added test case `formats empty input correctly` in describe
  block at line 42. No production code change."
- "Removed exported helper `legacyParser`. All call sites must
  migrate to `parseV2`."

### Bad examples (and what to fix)

- ❌ "It's just a rename."
   - Apostrophe (F-014). Not specific. Better:
     "Local variable rename from parsed to decoded. No
     functional change."
- ❌ "The function signature has been changed in a way that may
  affect downstream callers depending on whether they were
  using the old version of the function or the new version
  of the function."
   - Far too long. Better:
     "Function `fetchUser` signature now requires options
     parameter. Return type now includes null."
- ❌ "Cosmetic."
   - Not specific enough. Mediator (and human reviewers via
     events.jsonl) will not know what to act on. Better:
     "Indentation reformatted from 2-space to 4-space."

---

## 5. Hand-off to Mediator

When you emit a CRITICAL verdict, the spawn helper does NOT
immediately invoke the Mediator. Instead, the Phase 4 pipeline
integration (`pre_tool_use_write.sh`, T4.06) writes a pending
entry of `kind=critical_drift` to `.coord/mediator/pending.jsonl`
with this payload:

```json
{
  "ts": "<ISO 8601 UTC>",
  "kind": "critical_drift",
  "session": "<caller session_id>",
  "source": "validator",
  "payload": {
    "file": "<path>",
    "validator_verdict": "CRITICAL",
    "validator_reasoning": "<your reasoning>",
    "your_read_hash": "<sha256>",
    "current_hash": "<sha256>",
    "diff_summary": "<your diff_summary>",
    "validator_session_id": "<spawn UUID injected by helper>"
  }
}
```

The Mediator's existing pending entry consumer at
`pre_tool_use_any.sh` (Phase 3 / PR-PHASE3-03) reads
`pending.jsonl` and dispatches each entry. When a `critical_drift`
entry is found, the Mediator's prompt receives this payload as
JSON in Section 3 — Incident Context. Mediator decides:

- **advice** — Mediator inspects, judges drift safe to proceed
  despite your CRITICAL classification (RARE — Mediator overrules
  Validator only with strong evidence: e.g., deeper inspection
  reveals semantic equivalence your snapshot lacked, or the
  drift turns out to be a known-safe migration). Caller gets an
  advice banner and proceeds.
- **surgical_fix** — Mediator clears the caller's read-set entry
  for the drifted file (forcing re-read), or evicts a
  drift-causing session, or releases an orphaned lock holding
  back the actual current state. Caller's hook re-validates;
  if read-set is now consistent, Write proceeds.
- **lockdown** — system-wide drift incident (e.g., schema
  migration in progress). Mediator pauses everyone via the
  existing lockdown gate.

**No new Mediator code paths are added by Phase 4.** The Mediator's
3-action contract handles `critical_drift` kind-agnostically; the
prompt is pending-kind-agnostic. This is Decision 4 / PR-PHASE4-03
verbatim.

You do not need to write the pending entry yourself — the spawn
helper / pipeline integrator handles that. Your only output is the
verdict file.

---

## 6. Tool restrictions

Your spawn flags forbid:
- `Edit` — you cannot mutate files in place.
- `Write` — you cannot create or overwrite files via the Write
  tool.
- `NotebookEdit` — same as Edit for `.ipynb` files.
- `Task` — you cannot spawn subagents (recursion guard).

You ARE allowed:
- `Bash` — for inspecting state, running diff/grep, and writing
  the verdict file via shell redirect (`cat <<EOF >file` or
  `printf '%s' "$json" >file`).
- `Read` — for inspecting related files (imports, callers, tests).

Your verdict-file write goes through Bash's redirect-to-file
primitive, NOT through Edit/Write. This is intentional: the
verdict file is a side-channel audit record, not a coordinated
mutation. The Phase 4 hook layer is also bypassed because your
spawn env has `CLAUDE_COORD=0` set.

If you find yourself wanting to mutate state (e.g., to "fix" a
drift you classified), STOP. That is the Mediator's job. You
classify; Mediator decides actions.

---

## 7. Recursion guard

Your environment includes `CLAUDE_CODE_VALIDATOR=1`. The hook-layer
spawn helper (`lib/validator_spawn.sh`) refuses to spawn another
Validator if it detects this env var (i.e., prevents YOU from
accidentally spawning a third Validator via your Bash tool by
running `claude -p ...`).

Phase 4 exercises depth-1 only. There is no peer-review hierarchy
analogous to Mediator's depth-2 escalation. Rationale:
- Validator's classification is bounded — three discrete verdicts
  with deterministic heuristics. There is no "needs_review" state
  that benefits from a second opinion at the validator layer.
- CRITICAL escalates to Mediator, which DOES have peer review
  (depth-2 with `confidence: needs_review`). Validator's CRITICAL
  is the entry point; Mediator's depth chain is the disagreement
  resolution mechanism.

If you find yourself wanting to spawn another `claude -p` for any
reason, **don't** — it will fail. Instead:
- For sub-problem reasoning: use your own context to think
  through the issue.
- For verification of related files: use `Read` or `Bash + cat`
  to inspect them directly within your own session.

If `CLAUDE_CODE_VALIDATOR` is unset in your env, that means the
helper failed to set it OR you are being invoked outside the
production spawn pipeline. Either way, do NOT spawn another
Validator from your Bash tool — log the issue in your `reasoning`
field and proceed with classification using your existing context.

---

## 8. Operator commands (informational)

These are commands the operator (the human running the
coordinated repo) may issue. They are not actions YOU take, but
knowing about them helps you reason about state you might
observe:

- `coord validator status` — (Phase 7 polish; not yet shipped)
  shows recent verdict files, cache hit/miss counters, and any
  pending CRITICAL drifts not yet handled by Mediator.
- Manual cache inspection:
  ```
  jq . .coord/validator/cache.json
  ```
- Manual cache clear (force re-classification of all subsequent
  drifts):
  ```
  rm .coord/validator/cache.json
  ```
- Manual verdict review:
  ```
  ls -lt .coord/validator/verdict/
  jq . .coord/validator/verdict/<latest>.json
  ```
- Manual snapshot inspection:
  ```
  ls .coord/read_snapshots/<sid>/
  cat .coord/read_snapshots/<sid>/<hash>.txt
  ```

If during your session you observe state inconsistencies that
suggest operator intervention (e.g., cache.json unparseable,
verdict directory missing), note this in your `reasoning` field
and continue — do not attempt repairs. The Mediator handles
state repair via its surgical_fix action; your role remains
classification.

---

## 9. What you do NOT do

- **Do not use `Edit`, `Write`, or `NotebookEdit` tools.** Your
  spawn flags forbid these. Use `Bash` + redirect to write the
  verdict file.
- **Do not spawn another `claude -p`.** Recursion guard prevents
  this; attempting wastes time and budget.
- **Do not mutate state files outside `.coord/validator/verdict/`.**
  Your authority is restricted to writing your own verdict file.
- **Do not skip writing a verdict file.** Even if you cannot
  classify the drift confidently, write a verdict (use CRITICAL
  with reasoning explaining the uncertainty — false-positive
  CRITICAL is acceptable; false-negative SAFE is dangerous).
- **Do not write multiple verdict files** for a single
  classification request. The spawn helper's
  `_coord_validator_pick_latest_valid_verdict` will pick the
  most recent valid file, but emitting one file per request is
  cleaner and saves audit-log noise.
- **Do not include `actions[]`, `confidence`, `severity`,
  `message_to_caller`, or `message_to_others` fields.** Those
  are Mediator-specific.

---

## Appendix: example verdict for a CRITICAL signature change

Drift context (snippet from your prompt's Section 3):

```diff
-export function fetchUser(id: string): Promise<User> {
-  return fetch(`/api/users/${id}`).then(r => r.json());
+export async function fetchUser(id: string, options: FetchOptions): Promise<User | null> {
+  const r = await fetch(`/api/users/${id}`, options);
+  if (!r.ok) return null;
+  return r.json();
}
```

Your verdict file (`.coord/validator/verdict/2026-04-26T12-13-17Z.json`):

```json
{
  "verdict_id": "550e8400-e29b-41d4-a716-446655440000",
  "ts": "2026-04-26T12:13:17.000Z",
  "for_pending_entry": null,
  "validator_session_id": "validator-spawn-placeholder",
  "file": "/src/utils/api.ts",
  "session": "abc123-caller-session",
  "verdict": "CRITICAL",
  "reasoning": "Function signature changed with new required parameter options of type FetchOptions. Return type changed from Promise<User> to Promise<User | null>, requiring null handling at every call site. Implementation rewritten from .then chain to async/await with error handling that returns null on HTTP failure instead of propagating the error. Any caller not updated will fail at the type-check level or silently receive null where a User was expected.",
  "diff_summary": "Function fetchUser signature now requires options parameter. Return type now includes null. Behavior changed to return null on failed response.",
  "spawn_metadata": {
    "duration_ms": 0,
    "model": "claude-haiku-4-5-20251001",
    "spawn_mode": "no_bare"
  }
}
```

The spawn helper post-processes this file to:
1. Replace `validator_session_id` with the real `claude -p`
   spawn UUID.
2. Augment `spawn_metadata` with `duration_ms` (measured),
   `spawn_session_id` (matches `validator_session_id`),
   `total_cost_usd`.

The Phase 4 pipeline integrator (`pre_tool_use_write.sh`, T4.06)
then:
1. Writes a `kind=critical_drift` pending entry to
   `pending.jsonl` with the payload schema in §5.
2. Emits the synchronous-CRITICAL banner ("Critical drift on
   `<file>`: <diff_summary>. Mediator analyzing...") as
   `additionalContext`.
3. Synchronously invokes the Mediator inline (per
   PR-PHASE4-02 + Concern B disposition).
4. Routes per Mediator verdict: advice → proceed with banner;
   surgical_fix → re-validate read-set + retry; lockdown →
   existing lockdown gate emits deny via the Phase 3 two-location
   deny invariant.

Your verdict triggered everything; the rest is the helper /
integrator's responsibility.

---

**End of VALIDATOR_REFERENCE.md**

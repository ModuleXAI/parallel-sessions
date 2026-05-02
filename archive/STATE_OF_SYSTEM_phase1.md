# State of the System — 2026-04-25

A briefing for someone joining the project who has read nothing.
Snapshot at the close of Phase 1 (merge commit `629b1fb` on `main`).

---

## 1. The product in plain English

This is a **coordination layer for multiple Claude Code sessions
working in the same git repo at the same time.** Claude Code is
Anthropic's CLI for the Claude model; one developer sometimes runs
two or three of them side by side — one fixing a bug, one writing
tests, one refactoring. Without coordination, the sessions are
blind to each other.

**Concrete chaos scenario.** Session A reads `payment_service.ts`
and plans a refactor. Session B reads the same file twenty seconds
later, fixes a separate bug, and writes back its edit. Session A —
still working from the version it originally read — writes its
refactor on top, silently overwriting B's bug fix. Neither Claude
saw it happen; the regression turns up in CI hours later.

**With this system installed (Phase 1 today):** Session A's write
attempt produces an inline warning in A's context: *"Coord
stale-read warning: 1 file(s) you previously read have changed:
payment_service.ts (modified since read). This write is being
allowed, but your earlier plan may be based on outdated content.
Consider re-reading before proceeding."* Claude can re-read,
revise, or proceed knowingly. **The write is not blocked** — that
is a Phase 2 capability.

**Explicitly NOT this system's job:**
- Not a multi-user or team-shared service. One machine, one repo,
  one developer; per-machine opt-in via env var.
- Not a backup, version-control, or audit tool. Git remains source
  of truth.
- Not Windows-native. macOS + Linux only; WSL2 works.
- Not a productivity nudger or code reviewer. It coordinates
  *mechanics*, not semantics.

---

## 2. Current capabilities (what works today)

A "hook" below means a Bash script Claude Code invokes at specific
events (session start, before a tool call, etc.) which can inject
text into Claude's context.

### Installation experience
- **`coord install`** — checks deps (`bash`, `jq`, `flock`,
  `shasum`, `ps`, `git`), refuses unreliable filesystems (network
  mounts, cloud-sync), creates `.coord/`, registers six hooks into
  `.claude/settings.local.json` (preserving user hooks), updates
  `.gitignore`, runs an end-to-end self-test. `coord uninstall`
  reverses; `--purge` wipes everything. *Advisory.*

### Per-session behavior
- **Session-start banner.** Sessions launched with `CLAUDE_COORD=1`
  see *"Coord v1.0 active. Your coordination session ID is `<uuid>`.
  There are currently N other coordinated session(s). See `coord
  status`."* injected on Claude's first turn. *Mechanism:*
  `session_start.sh` records the row (PID, lstart, git HEAD)
  atomically. *Advisory.*
- **Lifecycle awareness.** The system distinguishes a fresh start,
  resume after crash, explicit context clear, and compaction.
  Read-history is preserved on resume/compact, invalidated on
  clear, re-marked when git HEAD has drifted. *Advisory.*
- **Clean exit.** `SessionEnd` removes the marker, releases any
  locks (none in Phase 1), logs the close. *Bookkeeping.*

### Per-tool-call behavior
- **Read tracking.** Every Read records sha256 + path + timestamp
  into a per-session "read-set." Re-reading supersedes the prior
  entry. *Advisory.*
- **Stale-read warning on Write.** Before any
  Write/Edit/NotebookEdit, the system re-hashes every file in the
  writer's read-set and warns on any mismatch via
  `additionalContext`. *Advisory.*
- **HEAD-drift recheck.** Every tool call re-checks git HEAD; if
  changed since this session was last active, the read-set is
  marked invalidated and Claude is told. *Advisory.*

### Cross-session behavior (the Phase 1 ship gate)
Two-session smoke verified: B modifies `foo.ts` after A read it; A's
next Write produces a warning citing `foo.ts`. No false positives
on B's own write (B's read-set is empty so B is silent). **The
write is not denied.** No coordination today blocks any tool call.

### Operator commands
- `coord status` — sessions, lock state (empty in Phase 1),
  per-session read-set summary; `--reads` for the per-file detail.
- `coord health` — deps + config-bound check + stray-digit-file
  scan at the repo root (a hygiene check from finding F-012).
- `coord log --tail N --kind X`, `coord events --since <ts>` —
  query the append-only event log.
- `coord reset --confirm` — operator escape hatch.
- **Stubbed for later phases:** `coord wait`, `coord task-open`,
  `coord self-delegate`, `coord tasks`, `coord locks`, `coord
  mediate` — print a clean "not available in Phase N" error.

### Self-protection
- **Atomic writes.** Every `sessions.json` mutation goes through
  `atomic_write.sh`: hold an exclusive `flock`, read, apply a `jq`
  filter, write to a temp file in the same directory, rename
  atomically — readers see either the old state or the new, never
  a partial. Five-way concurrent writers verified clean.
- **Corruption recovery.** If `sessions.json` ever fails to parse,
  it is auto-archived and replaced; the next session start surfaces
  *"Coordination state was reset due to corruption."*
- **Fail-open everywhere.** No hook ever blocks a tool call due
  to its own failure. Missing deps, unreadable files,
  atomic-write failures all log and allow. The Phase 1 ship-gate
  invariant — "no code path ever sets `permissionDecision`" — has
  a dedicated test asserting it.

---

## 3. Current limitations (what does NOT work yet)

**Two sessions cannot be prevented from clobbering each other's
writes.** Phase 1 is warning-only by design. Both writes succeed;
last writer wins. *Why:* Phase 2 lands lock acquisition + deny.
*Workaround:* read the warning when it appears.

**A session cannot wait for another to finish.** `coord wait` is
stubbed. *Why:* depends on locks (Phase 2) + wake mechanism (Phase
6). *Workaround:* none.

**Crash recovery is partial.** A SIGKILL-ed session leaves its
registry row behind; the watchdog that evicts it doesn't exist
yet. *Why:* peer-watchdog is Phase 3. *Workaround:* `coord reset
--confirm`.

**Subagent races are invisible.** Subagent tool calls (spawned via
the Task tool) are deliberately not coordinated — they're filtered
out and logged for observability only. A subagent writing a file
its parent doesn't lock can race silently with another session.
*Why:* design choice (Decision 2.17). *Workaround:* prefer `coord
self-delegate` (Phase 6) over subagents for deferred work.

**3+ concurrent sessions** work at the warning level but offer no
contention prevention. The state file scales fine; the user
experience is "every write sees a warning naming stale files,"
which gets noisy under heavy contention. Phase 2's deny model is
what makes this pleasant at scale.

---

## 4. Is this usable right now?

**(a) Solo dev, 1–2 sessions occasionally.** Marginal today. The
warning helps in the rare overlap; otherwise invisible. Real value
comes in Phase 2 (block clobbering) and Phase 4 (validator subagent
classifies safe vs critical drift).

**(b) Solo dev, 3–5 concurrent sessions on the same repo.** Nudged,
not protected. Reliably tells Claude when an earlier read is stale;
does not stop the write. A thoughtful session re-reads; a less
careful one writes on top. Materially better than nothing, not yet
"safe." Wait for Phase 2 if silent clobbering is expensive in your
workflow.

**(c) Team / multi-developer / multi-machine.** Out of scope for v1.

---

## 5. How it actually works (architecture in ~200 words)

**State file:** `.coord/sessions.json` — JSON with a frozen v1.0
schema. Tracks session rows (id, pid, lstart, git_head, prompt_id),
per-session read-sets, locks (empty in Phase 1), notifications,
self-tasks (empty in Phase 1), plus tables Phase 2+ populates.

**Hook layer:** six Bash scripts under `.coord/hooks/`, registered
into `.claude/settings.local.json`. Each receives event JSON on
stdin and emits either nothing (allow) or
`hookSpecificOutput.additionalContext` (inject text into Claude's
context). Phase 2+ also emits `permissionDecision: deny`.

**Library layer:** reusable modules under `.coord/lib/` —
`atomic_write.sh`, `log_event.sh`, `hash.sh`, `head_tracking.sh`,
`subagent_filter.sh`, `participant.sh`, `state_query.sh`.

**CLI:** `.coord/bin/coord` — operator surface for status, health,
events, install/uninstall/reset, plus stubbed Phase-N+ subcommands.

**Events log:** `.coord/events.jsonl` — append-only, one JSON
object per line, written non-blockingly under a brief flock. Every
interesting state transition is logged.

**Atomicity guarantee:** every state-file write uses the subshell
+ redirected-fd flock convention plus temp+rename. No torn writes,
no lost updates; verified under 5-way concurrent load on macOS APFS
and Linux overlayfs.

---

## 6. What ships in Phase 2

When Phase 2 merges, the warning becomes a **deny.** A second
session attempting to write a file the first has open sees a
message in Claude's context naming the lock holder, hold duration,
and three options: delegate as a small task, defer as a
self-reminder, or wait passively. The lock releases automatically
when the holder's write completes — no manual release. Phase 2
also lands the first real producer of notifications, so the
dormant Phase-1 plumbing starts firing.

Phase 1 + Phase 2 together shift the system from "tells you when
you've made a mistake" to "stops you from making it" — the first
phase that materially earns its keep at 3–5 sessions.

---

## 7. Trust posture

**Experimental but rigorously tested for the scope it covers.**
137/137 unit tests green on macOS and Linux (Docker
`ubuntu:24.04`); end-to-end smoke covers a manual two-session
driver and a 5-session concurrent stress test. The Phase 1 ship
gate ("never worse than no coordination — no code path can block a
tool call") has a dedicated invariant test asserting absence of
`permissionDecision` across every branch. The system fails open on
every error, so the worst case is "coordination silently disabled
this session" — no data loss, no stuck tools. That said: Phase 1
is honestly observation-only. It will not yet prevent two sessions
from clobbering each other's writes. Trust it for the warning it
provides; do not yet trust it as a safety net.

---

*End of briefing.*

# Codex Quickstart

A walkthrough for OpenAI Codex CLI users adding Parallel Sessions to their workflow. Pairs with the high-level [README §Quick start](../README.md#quick-start); this doc is the operator-deep-dive.

## Prerequisites

| What | Why | How |
|---|---|---|
| `codex` CLI | The agent itself | https://github.com/openai/codex |
| `claude` CLI | Mediator backend (D-1 contract — see below) | https://docs.anthropic.com/en/docs/claude-code/quickstart |
| `jq`, `flock`, `perl`, `bats` | Coordination machinery | macOS: `brew install jq flock perl bats-core` ; Linux: package manager |
| `fswatch` (macOS) or `inotify-tools` (Linux) | Sub-100 ms wait wake-up (optional but recommended) | `brew install fswatch` ; `apt install inotify-tools` |

**Why claude is required for Codex-only operators**: the Mediator (the agent that decides eviction / surgical-fix / lockdown when a session goes pathological) is a `claude -p` subprocess. This is locked decision D-1; it applies regardless of which adapter triggered the decision. If you skip the `claude` install, coordination still works for the deterministic paths (lock acquisition, drift detection, FIFO wait queues, graceful release), but Mediator-resolved scenarios refuse with a clean audit trail (`MEDIATOR_SPAWN_REFUSED reason=claude_binary_missing`) rather than a hang. See [README §D-1](../README.md#d-1-codex-only-users-still-need-claude).

## Install

### Option A — Codex only

```bash
git clone https://github.com/sezeryavuz/parallel-sessions.git ~/parallel-sessions
cd ~/parallel-sessions
bash src/install.sh \
  --yes \
  --without-claude-code \
  --with-codex
```

This:
- Materializes `<your-repo>/.coord/` with shared core libs.
- Copies Codex hooks into `<your-repo>/.coord/hooks/codex/`.
- Copies Codex adapter libs into `<your-repo>/.coord/lib/codex/`.
- Writes `<your-repo>/.codex/hooks.json` registering 5 events (SessionStart, Stop, UserPromptSubmit, PreToolUse with three matchers, PostToolUse on `^apply_patch$`).
- Always writes/merges `[features] codex_hooks = true` into `<your-repo>/.codex/config.toml` (A-M-T1-04, plan v1.4). Codex's hook discovery requires this "active config layer" alongside `hooks.json`; without it, the discovery layer is dormant and the installer's hook registration is invisible to the Codex CLI. The installer is idempotent — if `.codex/config.toml` already contains the flag, it is left byte-stable; if it contains other user settings, the flag is merged in preserving user content.

**Run from inside your project directory** (or pass an explicit repo root). The dispatcher resolves `.coord/` relative to git's `--show-toplevel` or `$PWD`.

> The `--enable-codex-feature` flag from earlier releases is **deprecated** but still accepted as a no-op for back-compat with existing runbooks. Plan v1.4 makes the flag unnecessary because the installer always writes the active config layer.

### Option B — Codex + Claude (mixed mode)

```bash
bash src/install.sh --yes --with-claude-code --with-codex
```

Both adapters install into the same `.coord/`. Claude hooks land at `.coord/hooks/` (flat); Codex hooks at `.coord/hooks/codex/`. One shared `sessions.json` arbitrates writes from either agent type. See [README §Cross-agent coordination](../README.md#cross-agent-coordination).

### Idempotency + repair

Re-running the install is safe; it strips prior coord-owned entries from `.codex/hooks.json` before re-appending them. To force-overwrite hook scripts (for instance after pulling a new release):

```bash
bash src/install.sh --yes --repair --with-codex
```

To uninstall (preserves `.coord/` audit log):

```bash
bash src/install.sh --uninstall --with-codex
```

To fully remove: `rm -rf .coord/`.

## Verify the install

```bash
cat .coord/sessions.json | jq '.schema_version'   # → "1.1"
cat .codex/hooks.json     | jq '.hooks | keys'
# → ["PostToolUse","PreToolUse","SessionStart","Stop","UserPromptSubmit"]
ls .coord/hooks/codex/
# → post_tool_use_apply_patch.sh   pre_tool_use_apply_patch.sh
#   pre_tool_use_any.sh            pre_tool_use_bash.sh
#   session_start.sh               stop.sh
#   user_prompt_submit.sh
ls .coord/lib/codex/
# → apply_patch_parser.sh   translator.sh
```

## Start a session

```bash
parallels-codex   # exports COORD_ENABLED=1, exec's `codex`
```

The launcher walks up from `$PWD` to find `.coord/` and refuses with rc=2 if coordination isn't installed, rc=3 if `codex` isn't on `$PATH`. Once the Codex CLI is up, every `apply_patch` gets arbitrated by the coordination hooks transparently.

## What you'll see (and what you won't)

### What appears as expected

- **`SessionStart`** — A "Coord v1.0 active" banner appears in your Codex context, listing your session ID and any other coord-active sessions in this repo. This is the additionalContext channel which IS supported on SessionStart.
- **`UserPromptSubmit`** — On HEAD drift since your last activity, a banner says "git HEAD changed since your last activity. Your read-set is invalidated; re-read any files you depend on." Otherwise silent.
- **`apply_patch` lock conflict** — Codex's `pre_tool_use_apply_patch.sh` emits a `permissionDecision: deny` with a multi-option deny banner naming the holder (their session ID prefix, lock acquisition age, lock refresh age). Codex surfaces this as the tool's denial reason.
- **`apply_patch` drift** — If the file changed underneath the patch (the hunk's pre-image is no longer present), the hook emits a drift-deny banner explaining which file's hunk has the mismatch. Re-read and resubmit.

### What is intentionally quiet on Codex

Per A-D4-02 / D-D4-02 (output_parser.rs:16-20 + :337-348) Codex's PreToolUse parser explicitly rejects the `additionalContext` channel. The bookkeeping side effects still happen — they're recorded in `.coord/events.jsonl` — but the in-turn banner text is not surfaced. Affected:

- Stale-read drift warnings → replaced by structural deny on `apply_patch` (you don't need a soft warning; the deny IS the signal).
- Mediator verdict messages → recorded in `.coord/mediator/verdict/<ts>.json` and viewable via `coord status`. The verdict actions (lockdown / evict / surgical_fix) still apply automatically.
- Self-task reminders → recorded as `SELF_TASK_REMINDER` events; not surfaced as an in-turn banner (mechanism behaves as documented per F-D4-03 / A-D4-02; whether the missing banner causes user-visible impact is an open behavior question — see `codex-integration-log.md` F-D4-03 for status). Issue `coord status` to see pending self-tasks for your session.
- HEAD-drift on `PreToolUse` → rerouted to `UserPromptSubmit` (next prompt). You see it on the next turn rather than mid-tool-call.

The audit trail (`.coord/events.jsonl`) is authoritative. If something unexpected happens, grep there:

```bash
jq -rs '.[] | select(.session == "your-codex-session-id")' .coord/events.jsonl
```

## Mixed-mode (running alongside Claude)

When a Claude session and a Codex session share a repo:

- Both register into `sessions.json` with their `agent` field (`"claude_code"` vs `"codex"`).
- File locks are shared. Claude's `Edit` and Codex's `apply_patch` contend for the same locks. Whichever session calls the pre-write hook first wins.
- Multi-file `apply_patch` follows D-12 all-or-deny atomicity: if Claude holds even one of N target files, the entire patch is denied. The deny banner enumerates every blocked file, not just the first.
- Stop / SessionEnd / kill behaviors are symmetric across agent types. A crashed Codex session is detected by the Watchdog the same way a crashed Claude session would be.

The cross-agent invariants are exercised end-to-end across 45 integration tests under `src/tests/integration/cross_agent/`. If you suspect the coord layer is mis-arbitrating between your two agents, those tests are the contract documentation.

## Troubleshooting

### My Codex session doesn't show the SessionStart "Coord v1.0 active" banner — hooks aren't firing

Symptoms (from M-T1-04 BEFORE evidence, post-H.1 manual testing on macOS with Codex CLI v0.128.0):

- Codex TUI opens, but no SessionStart banner appears.
- `grep -i hook ~/.codex/log/codex-tui.log` returns ZERO lines (Codex never even attempted hook discovery).
- `.coord/events.jsonl` has no real-session `SESSION_REGISTER` / `PROMPT_SUBMIT` / `PRE_BASH` entries — only install-time smoke entries.
- `coord status` shows no active session despite the TUI being open.

**Diagnostic command:**

```bash
cat .codex/config.toml
# Should print at minimum:
#   [features]
#   codex_hooks = true
```

**Root cause:** Codex's hook discovery requires an "active config layer" — a sibling `config.toml` in the same directory as `hooks.json`. Without `.codex/config.toml`, the layer is dormant and `.codex/hooks.json` is invisible. This was a silent product failure mode pre-v1.4 (install reported success / `EXIT_CODE=0` / "[6/6] coord installation ready" / "next steps: Run parallels-codex" — yet no hook ever fired).

**Fix:** Plan v1.4 / A-M-T1-04 (commit `8cec664`) made the installer always write `.codex/config.toml` regardless of CLI flags. If you installed against this version of parallel-sessions and still see the symptoms above, re-run the installer:

```bash
bash src/install.sh --uninstall --with-codex
bash src/install.sh --yes --with-codex
```

The installer's idempotent merge preserves any other user-authored content in `.codex/config.toml`. If you installed against an older version (pre-8cec664), creating `.codex/config.toml` with the snippet under "Diagnostic command" above resolves it without re-running the installer; the next `parallels-codex` invocation will produce the SessionStart banner.

See `codex-integration-log.md` 2026-05-05 dated section for the full BEFORE/AFTER evidence trail.

### apply_patch is denied with a "drift" reason but I just read the file

The drift gate searches the file for each hunk's pre-image text. If the file changed between your `Read` and your `apply_patch` (another session wrote it, or you committed in another shell), the pre-image won't match and the patch is rejected to avoid a corrupting apply. Re-read with `Read` and submit a fresh patch.

For files larger than 1 MB, the drift gate skips (see codex-integration-plan.md A-D4-01 / preview §4.3). The patch acquires the lock and apply_patch's own anchor-matching becomes the only defense. If your patch fails at apply time on a large file with a drift-shaped error, the file changed; re-read.

### `MEDIATOR_SPAWN_REFUSED reason=claude_binary_missing` in events.jsonl

You're hitting the D-1 contract. The Mediator backend is `claude -p`, and `claude` isn't on `$PATH`. Install Claude CLI from https://docs.anthropic.com/en/docs/claude-code/quickstart and re-run whatever triggered the failure. Coord's deterministic paths kept working through this; only the Mediator-resolved decision was deferred.

### My Codex session "doesn't see" a banner I expected

Check whether the expected banner is in the `PreToolUse` channel — that channel is intentionally quiet on Codex. The bookkeeping ran; only the in-turn banner was dropped. Inspect `.coord/events.jsonl` for the underlying event (e.g., `HEAD_CHANGE`, `MEDIATOR_INLINE_VERDICT_APPLIED`, `SELF_TASK_REMINDER`) and `coord status` for the live state.

### Multi-file apply_patch denied because one file is locked by Claude

The deny banner names the holder. Three options (same as Claude's deny flow):

1. `coord task-open --file <path>` — delegate the edit to Claude.
2. `coord self-delegate --file <path>` — defer your work, do something else, return when the file unlocks.
3. `coord wait <path1> <path2> ...` — block until all target files are free or timeout.

## Reference

- High-level overview: [README.md](../README.md).
- Implementation plan + locked decisions D-1..D-13: `codex-integration-plan.md`.
- Background research + upstream Codex hook contract: `codex-integration-research.md`.
- PR-by-PR integration audit: `codex-integration-log.md`.
- Cross-agent invariant guards: `src/tests/unit/codex_phase7_invariant.bats`.
- Cross-agent scenarios: `src/tests/integration/cross_agent/*.bats`.

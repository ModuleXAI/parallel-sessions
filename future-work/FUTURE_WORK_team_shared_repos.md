# FUTURE_WORK — Team-Shared Coordination Config (Checked into Git)

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 gitignores everything: `.coord/`, `.claude/settings.local.json`, hook scripts. This matches user direction ("everything gitignored") and makes the system strictly per-developer opt-in. The user currently runs this solo; team-sharing is not a v1 use case.

But a team might want the coordination system to be **team-default**: when any developer clones the repo, they should get the coordination capability without manually running `coord install`. That requires at least some files to be checked into git.

## Proposed approach

### Minimum shareable artifacts

- **Hook scripts** (`.coord/hooks/*.sh`, `.coord/lib/*.sh`, `.coord/bin/coord`). These are code; checking them in is normal.
- **`.claude/settings.json`** (not `settings.local.json`) — team-shared hook registrations.
- **`.coord/config.json`** — team-shared tunables (lock TTL, validator_enabled, task_delegation toggle).
- **`.coord/schema_version`** — team-shared schema contract.
- **Documentation** — `.coord/README.md` explaining the system to new contributors.

### What stays gitignored

- `sessions.json` — live state; ephemeral.
- `sessions_history.json` — per-developer history; no audit value to share.
- `events.jsonl` — firehose; purely local.
- `.coord/sessions/*.active`, `*.wait`, `*.env` — session-local files.
- `.coord/validation/*.json` — session-local pending validations.
- `.coord/mediator/pending.json`, `verdict/*.json` — session-local Mediator artifacts.
- `.claude/settings.local.json` — if present; for overrides.

### Installer behavior under team-shared mode

`coord install --team`:
- Creates `.coord/` hook tree as a **tracked** subset + **gitignored** subset. Uses a `.coord/.gitignore` file to allow only the shareable paths.
- Writes `.claude/settings.json` (team-shared) with hook registrations. No `settings.local.json` unless the developer wants overrides.
- On first pull, a new team member runs `coord setup` (idempotent):
  - Verifies deps.
  - Creates the gitignored state directory structure.
  - Registers the developer's environment.

### Opt-in / opt-out per developer

- **Hook-level opt-out** — a developer who does not want coordination sets `CLAUDE_COORD=0` (or leaves it unset). Hooks detect non-participant and no-op.
- **Repo-level opt-out** — developer's `.claude/settings.local.json` overrides team `.claude/settings.json` to remove hooks entirely.
- **CI concern** — in CI environments, hooks must not run. CI config sets `CLAUDE_COORD=0`.

### Pitfalls

- **Hook scripts are executable code from git.** Developers pulling the repo execute this code on every Claude Code tool call. Trust boundary. Mitigations:
  - Code review every hook change.
  - Hook scripts are minimal wrappers that delegate to a signed/checksummed binary (relates to `FUTURE_WORK_go_native_implementation.md`).
  - Hook script hashes verified at runtime against a committed manifest.
- **Config drift between developers.** One developer hand-edits `.coord/config.json`; others pick up changes silently. Mitigation: config changes require PR review like any other code.
- **State file pollution via accidental commits.** If a developer force-adds `sessions.json`, it pollutes the repo. Mitigation: `.gitignore` + a pre-commit hook that refuses to commit `.coord/sessions.json`.

## Tradeoffs vs per-developer gitignored (v1)

| Aspect | v1 gitignored | Team-shared |
|---|---|---|
| Setup per developer | `coord install` | `coord setup` (simpler) |
| Config consistency | none (each dev owns) | high (tracked in git) |
| Trust | each dev owns their hooks | team must trust committed hooks |
| Discoverability | dev has to learn to install | dev gets it by default |
| CI safety | trivially off (no install) | needs env var |
| Forkability | fork inherits nothing | fork inherits config |

## Why it's deferred

- User direction is "everything gitignored; I run this solo."
- Team coordination pattern is premature: v1 must prove itself as a personal tool first.
- Trust-of-committed-hook-scripts story needs a security review that is out of v1 scope.

## What would trigger revisiting this

- User or other adopters shift from solo use to team use.
- Public release / community wants a canonical "install once, works for everyone" story.
- Intersection with `FUTURE_WORK_go_native_implementation.md` — signed binaries simplify the hook-trust concern.

## Relation to other future-work docs

- `FUTURE_WORK_go_native_implementation.md` — committed binary + signature is the natural trust story.
- `FUTURE_WORK_multi_user_shared_machine.md` — different problem (same box, different users) vs this (different boxes, shared repo).
- `FUTURE_WORK_remote_sessions.md` — at the limit (team-shared + cross-machine), this becomes a coordination service.

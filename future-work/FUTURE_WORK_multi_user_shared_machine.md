# FUTURE_WORK — Multi-User Shared Machine

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 assumes a single user on the machine. Coordination state has no user attribution; the `sessions.json` schema identifies sessions by Claude Code's `session_id` UUID, not by OS user.

A multi-user scenario — several humans sharing the same machine (rare now, but possible in shared-dev-box setups, lab environments, or paired-programming rigs) — introduces questions:

- Whose files does the coordinator protect?
- Are cross-user delegations allowed?
- Who owns the `.coord/` directory? What are the file permissions?
- Can user A's session block user B's session? Should it?
- Whose name appears in audit logs?

v1 ignores all of these because it assumes a single-user context.

## Proposed approach

### Model choices

**Option 1 — Per-user coordination scopes (isolated).**
Each user has their own `.coord/` (e.g., `~/.coord/<repo-key>/`). Users cannot interfere with each other. Uses UNIX file permissions. Simplest. Loses the collaboration benefit if users are actually working on the same repo.

**Option 2 — Shared coordination scope with user attribution.**
A single `.coord/` is shared (typical location: the repo's `.coord/`). Each session record includes `os_user` in addition to `session_id`. Sessions see each other regardless of user.

Design details for Option 2:
- `sessions.json` session record gains `os_user: "alice"` and `os_uid: 501`.
- The Mediator's policy can be tuned per `os_user`.
- `coord status --user <u>` filters views.
- Delegation across users is allowed but logged with a `cross_user: true` marker in `events.jsonl`.
- Permissions on `.coord/`: setgid directory owned by a shared group `coord-users`, mode `g+rwxs`. New files inherit the group. All participating users must be in the group.

**Option 3 — Hybrid.**
Shared scope for coordination; per-user private areas for self-tasks and read-sets. Read-only visibility of other users' locks; blocked writes to another user's locked file.

### Authentication / trust

Since all users are on the same machine, UNIX-level authentication is sufficient (UIDs). No additional auth layer required.

**Caveat:** a malicious local user can still clobber `.coord/sessions.json` by breaking permissions (given root or file permissions). The system is cooperative, not adversarial.

### File-ownership pitfalls to watch

- `flock` takes a file descriptor; any user with write access can acquire it. No privilege escalation.
- `ps` visibility: a user can see every other user's PIDs. The `pid_lstart` liveness check works across users.
- State file written by user A must be writable by user B. This is the hardest practical problem: file modes must allow shared write.

### Audit and privacy

- `events.jsonl` would contain which user did what. Good for audit; bad for privacy. In a shared-machine context, the owner of the machine should document and consent.
- `task_prompt` (stored as a hash in v1) remains a hash; the cached prompt text (in `.coord/sessions/<id>.env`) is per-session and should be readable only by that session's user (permissions `0600`).

### Migration from v1

- Add `os_user`, `os_uid` fields to session records (additive; v1 scripts tolerant of extra fields).
- `session_start.sh` fills them via `id -un` and `id -u`.
- Installer mode: `coord install --multi-user` sets up shared permissions.
- Single-user mode remains default; multi-user is opt-in.

## Why it's deferred

- User direction is explicitly single-user for v1.
- Shared-dev-machine use cases are uncommon in practice.
- Permissions + group management are installer complexity that doesn't help the primary audience.

## What would trigger revisiting this

- A team adopts the system in a shared-dev-box setup (bioinformatics shops, academic labs, some enterprise dev environments).
- Requests specifically for multi-user observability.
- Intersection with `FUTURE_WORK_remote_sessions.md` — the same design questions (whose session, what permissions) recur there in a different form.

## Relation to other future-work docs

- `FUTURE_WORK_remote_sessions.md` — the same attribution concern arises across machines; solutions generalize.
- `FUTURE_WORK_team_shared_repos.md` — different problem (multiple users, different machines, same repo via git). Multi-user-same-machine is the narrower case.

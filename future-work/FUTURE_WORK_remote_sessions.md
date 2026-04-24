# FUTURE_WORK — Remote Sessions / Multi-Device Coordination

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 is single-user, single-machine. All coordinated sessions share a local filesystem. The design depends on POSIX `flock`, local `ps`, and local file paths. It cannot coordinate sessions running on different machines (e.g., Claude Code Remote, cloud dev env, Codespaces, a teammate's laptop during a pairing session).

A remote-session extension lets sessions on different machines coordinate as if they shared a filesystem, by substituting a coordination service for the local state file.

## Proposed approach

### Architecture

```
   +-----------+     +-----------+     +-----------+
   | session A |     | session B |     | session C |
   | machine 1 |     | machine 2 |     | machine 3 |
   +-----+-----+     +-----+-----+     +-----+-----+
         |                 |                 |
         +--------+--------+--------+--------+
                  |                 |
                  ▼                 ▼
         +-------------------------------+
         |    coord-coordinator service  |
         |  (HTTPS + WebSocket)          |
         |  authoritative state          |
         |  SQLite backing store         |
         +-------------------------------+
```

- **`coord-coordinator`** — a small HTTPS service (one per team or one per repo; configurable). Holds sessions.json-equivalent state. Exposes REST for queries, WebSocket for notifications and real-time lock-state updates.
- **Client-side** — hooks become thin clients that talk HTTPS. Local `flock` is replaced with server-side transactions (SQLite, as per `FUTURE_WORK_sqlite_state_storage.md`).
- **Authentication** — per-session API token. Registration step: `coord login` exchanges user credentials for a token saved in `~/.coord/credentials`.
- **Repo identity** — each coordinated scope is identified by a repo URL + branch (or a user-chosen repo key). Sessions on different machines identify themselves as working on the same scope.

### Key changes from v1

- `lib/atomic_write.sh` → HTTP POST to `/state/transaction`. The server applies the transaction atomically; hook receives success/failure.
- Notifications → subscribed via WebSocket. Lock-release pushes a message to all waiters' connections.
- Watchdog → server-side heartbeat. Clients ping every N seconds; server evicts missing clients after threshold.
- PID/lstart check → replaced with liveness heartbeat over the WebSocket.
- `coord wait` → subscribes to the WebSocket for the file's lock-released event; exits on receipt.

### Security / trust model

- TLS required.
- Per-user tokens; per-repo scopes within a user's token.
- Server does not read file contents; it only stores coordination metadata (paths, hashes, task instructions).
- **Optional end-to-end:** task instructions can be encrypted client-side with a shared key known to all participating sessions; server stores ciphertext. Prevents the server operator from reading delegations.

### Deployment options

1. **Self-hosted** — team runs `coord-coordinator` on their own VPS. Tight control; no third-party dependency.
2. **Hosted service** — Anthropic (or a third party) offers a coord service. User signs up; no infra work.
3. **Peer-to-peer** — no central service; sessions discover each other via mDNS on LAN or a relay. Harder; lower trust boundary; out of scope for a first release.

### Edge cases

- **Network partition.** Session temporarily offline; cannot query state. Behavior: block writes (fail-closed) OR fall back to local-only mode (fail-open). Configurable per session.
- **Clock skew.** Timestamps disagree across machines. Mitigation: rely on server-assigned timestamps; ignore client clocks except for debugging.
- **Session resume across machines.** Unlikely but possible (dev uses laptop → desktop). Would require deliberate design; easier to require a new session registration per device.

## Why it's deferred

- User direction: single-user, single-machine scope for v1.
- Adds an entire service + auth + deployment story.
- Requires trust model; security review.
- v1's file-based approach is quicker to validate the core correctness claims.

## What would trigger revisiting this

- Claude Code Remote (or equivalent) becomes common and users want the coordination benefit across their local + remote sessions.
- Team adoption of the system succeeds (via `FUTURE_WORK_team_shared_repos.md`) and a natural next ask is "what about when I'm on the train with an iPad session?"
- Cloud dev environments (Codespaces, Coder) become a dominant use case.

## Relation to other future-work docs

- `FUTURE_WORK_daemon_architecture.md` — local daemon is a stepping stone; remote is the daemon-plus-auth version.
- `FUTURE_WORK_sqlite_state_storage.md` — server-side storage is natural fit.
- `FUTURE_WORK_multi_user_shared_machine.md` — overlap but distinct; this doc assumes different machines per user.
- `FUTURE_WORK_team_shared_repos.md` — once state is on a server, checking in team coordination becomes a per-team-config thing rather than per-developer gitignored files.

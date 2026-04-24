# FUTURE_WORK — Daemon Architecture

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1's Bash + `jq` + `flock` architecture treats `.coord/sessions.json` as authoritative state. Every hook call: acquire `flock`, parse JSON, transform, write temp, rename, release. This works but has two ceiling problems:

1. **Contention cost.** With 5 concurrent sessions making frequent tool calls, `flock` serializes the critical sections. Per-hook overhead of 20–80ms scales to 100ms+ p99 under load. At 10 sessions, tail latency climbs further. The user's declared baseline is 5 sessions; headroom to 10 is requested.
2. **Startup overhead.** Every hook call spawns `bash`, `jq`, and a few small commands. Per-invocation startup is perhaps 30–50ms on top of the lock cost. At several tool calls per second across a five-session fleet, this is meaningful.
3. **Query expressiveness.** `jq` handles JSON transformation fine but struggles with relational-style queries ("show all locks older than 10 minutes held by sessions whose PID is absent"). A daemon can expose rich query API.

A daemon — one long-running process per repo — holds state in memory, serves RPC over a Unix socket, and flushes to disk on a controlled cadence. Hooks become thin clients that RPC to the daemon.

## Proposed approach

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      coord-daemon                           │
│  ┌─────────┐  ┌────────────┐  ┌──────────┐  ┌──────────┐   │
│  │  State  │  │  Lock mgr  │  │  Tasks   │  │  Watchdog│   │
│  └─────────┘  └────────────┘  └──────────┘  └──────────┘   │
│                         ↑                                    │
│                    Unix socket                               │
│                         ↑                                    │
└─────────────────────────┬───────────────────────────────────┘
                          │
   ┌──────────────────────┼──────────────────────────┐
   │                      │                          │
   ▼                      ▼                          ▼
 hook A                 hook B                    hook C
 (Bash client)        (Bash client)             (Bash client)
```

### Components

1. **`coord-daemon`** — long-running Go or Rust binary listening on `.coord/coord.sock`. Holds `sessions.json`-equivalent state in-memory. Periodically snapshots to disk (every N ops or every M seconds) for crash recovery.
2. **Hook-side clients** — small Bash scripts (or compiled minimal binaries) that send a request to the socket and return the response. The hooks keep their current interface; internals change.
3. **Supervisor** — the first hook call that cannot reach the daemon starts it via `nohup coord-daemon &` or `launchctl` / `systemd --user`. Subsequent calls reach the running daemon.
4. **Socket protocol** — JSON-RPC 2.0 over Unix socket. Methods: `register_session`, `unregister_session`, `lock_acquire`, `lock_release`, `lock_query`, `read_set_record`, `read_set_validate`, `task_open`, `task_apply`, `self_delegate`, `wait_enter`, `wait_wake`, `mediator_invoke`, `health`.
5. **Persistence** — WAL-style log (`.coord/daemon.wal`) appended on every state change; periodic snapshot to `sessions.json` for compatibility with the v1 CLI and debugging. Daemon recovers from WAL on restart.

### Migration from v1 (JSON + flock)

1. Keep `sessions.json` as the committed-to-disk snapshot format — no schema break.
2. v1 CLI (`coord status`, etc.) remains functional by reading the snapshot OR querying the daemon socket if present.
3. New env var `CLAUDE_COORD_DAEMON=1` opts a repo into daemon mode. Absence → v1 behavior unchanged.
4. Both modes use the same `sessions.json` schema; a daemon-mode session cannot share state with a JSON-flock session in the same repo concurrently (too many atomicity-model mismatches). Document as: pick one mode per repo.

### Advantages

- Contention-free from the hook's POV; hooks acquire an in-process lock inside the daemon (sub-microsecond).
- No startup overhead — socket RPC is ~1ms.
- Richer state queries. The Mediator gains a real SQL-ish query interface.
- Built-in heartbeat + liveness detection (daemon pings sessions via socket).
- Can push notifications (the daemon can `touch` a wake file on lock-release without the client polling the filesystem).
- Historical data stays hot; queries over `events.jsonl` can be served from memory.

### Disadvantages

- Another process to supervise. Crash recovery is more complex than "rename over the old file."
- One socket per repo. Socket path collisions possible in weird layouts.
- Debugging a bug-in-daemon is harder than debugging a bug-in-shell-script.
- Install complexity: a daemon binary must be distributed (Go static binary, or Node.js script + `node` requirement).
- WSL2 sockets have occasional quirks; need validation.

## Why it's deferred

- User direction: prefer simplicity for community adoption.
- v1 contention at 5 sessions is expected to be tolerable (Phase 1 research `05` §G estimates 100ms p99 at 5 sessions).
- Adding a daemon now doubles the testing matrix without evidence that the simpler approach fails.

## What would trigger revisiting this

- Phase 7 test harness shows hook-level p99 latency exceeds user tolerance (e.g., >500ms) at 5 sessions.
- Users running 10+ sessions hit scalability walls.
- Complex queries needed by the Mediator become awkward in `jq`.
- Future UI/visualization project (`FUTURE_WORK_visualization_ui.md`) wants real-time push that a file-based approach cannot cleanly deliver.

## Relation to other future-work docs

- `FUTURE_WORK_go_native_implementation.md` overlaps: a Go-compiled daemon is one realization of this doc. The Go doc focuses on replacing the **hook scripts** with compiled binaries even without a daemon; this doc focuses on introducing **a server**.
- `FUTURE_WORK_sqlite_state_storage.md` is an alternative that preserves the no-daemon model while solving the query-expressiveness problem. If SQLite is enough, daemon may never become necessary.
- `FUTURE_WORK_remote_sessions.md` effectively requires a daemon (or a network service) — it cannot be purely file-based.

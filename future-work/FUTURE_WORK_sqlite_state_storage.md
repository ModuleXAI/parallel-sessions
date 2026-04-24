# FUTURE_WORK — SQLite State Storage

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 stores coordination state as a single JSON file (`sessions.json`) protected by `flock`. This works, but hits three scaling and ergonomics walls:

1. **Query expressiveness.** `jq` can transform JSON, but complex queries (e.g., "list all locks held longer than 10 minutes whose holder's PID is absent OR recycled, grouped by file extension") are awkward. The Mediator in particular would benefit from richer querying.
2. **Concurrent access patterns.** Even with atomic writes, every mutation requires loading and rewriting the entire file. SQLite indexes and row-level updates scale better.
3. **History growth.** `sessions_history.json` and `events.jsonl` grow unbounded. SQLite with scheduled VACUUM and age-based pruning is a cleaner story.

SQLite replaces `sessions.json` with `.coord/state.db`. Hooks open, query, update, close per call. SQLite handles atomicity via its built-in journal/WAL.

## Proposed approach

### Schema

Direct translation of the v1 JSON schema to relational form:

```sql
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  state TEXT CHECK(state IN ('ACTIVE','IDLE_ALIVE','IDLE_CLOSED')),
  pid INTEGER,
  pid_lstart TEXT,
  registered_at TEXT,
  last_activity_at TEXT,
  git_head TEXT,
  prompt_id TEXT,
  script_version TEXT
);

CREATE TABLE locks (
  file TEXT PRIMARY KEY,
  session TEXT REFERENCES sessions(id),
  acquired_at TEXT,
  last_refresh_at TEXT
);

CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  lock_file TEXT REFERENCES locks(file),
  from_session TEXT,
  instruction TEXT,
  rationale TEXT,
  complexity TEXT,
  anchor_json TEXT,
  status TEXT,
  created_at TEXT,
  applied_at TEXT,
  affected_lines_json TEXT,
  diff TEXT,
  outcome TEXT,
  chain_depth INTEGER,
  parent_task_id TEXT REFERENCES tasks(id)
);

CREATE TABLE wait_queue (
  file TEXT,
  session TEXT,
  waiting_since TEXT,
  wake_file TEXT,
  reason TEXT,
  PRIMARY KEY(file, session)
);

CREATE TABLE read_sets (
  session TEXT,
  file TEXT,
  ts TEXT,
  hash TEXT,
  is_latest INTEGER,
  superseded_by TEXT,
  superseded_by_head_change INTEGER DEFAULT 0,
  PRIMARY KEY(session, file, ts)
);

CREATE TABLE notifications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  recipient TEXT,
  type TEXT,
  created_at TEXT,
  expires_at TEXT,
  delivered INTEGER DEFAULT 0,
  payload_json TEXT
);

CREATE TABLE self_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner TEXT,
  file TEXT,
  instruction TEXT,
  created_at TEXT,
  prompt_id TEXT,
  status TEXT
);

CREATE TABLE anomaly_votes (
  voter TEXT,
  target TEXT,
  observed_at TEXT,
  kind TEXT,
  evidence TEXT
);

CREATE TABLE task_graph (
  parent TEXT,
  child TEXT,
  PRIMARY KEY(parent, child)
);

CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT,
  session TEXT,
  kind TEXT,
  tool TEXT,
  file TEXT,
  hash TEXT,
  payload_json TEXT
);

CREATE INDEX idx_events_ts ON events(ts);
CREATE INDEX idx_read_sets_latest ON read_sets(session, is_latest);
CREATE INDEX idx_notifications_undelivered ON notifications(recipient, delivered);
```

### Concurrency

SQLite in WAL mode supports multiple concurrent readers + one writer without `flock`. Each hook opens the DB with `PRAGMA journal_mode=WAL` and relies on SQLite's own locking. No `sessions.lock` file needed.

### CLI / hook changes

- `coord` CLI gets a `--sql <query>` subcommand for operators who want to poke state directly (read-only by default).
- Hooks use `sqlite3` CLI + `.mode json` for compatibility with jq tooling, or transition to a proper SQLite binding if paired with `FUTURE_WORK_go_native_implementation.md`.
- Mediator gains rich queries. Watchdog queries "stale sessions" in one SQL rather than iterating JSON.

### Migration from v1 JSON

1. Freeze v1 schema at `schema_version 1.0`.
2. Introduce schema_version `2.0-sqlite` as an alternative.
3. A one-shot `coord migrate --to sqlite` reads `sessions.json`, creates `state.db`, imports rows.
4. Hook runtime detects which mode is active via the presence of `state.db` vs `sessions.json`.
5. Rollback: `coord migrate --to json` exports SQL to JSON.

### Advantages

- Atomicity for free. SQLite transactions replace the flock+temp+rename dance.
- Concurrent readers. Reads do not block writes.
- Queries. Mediator gets SQL; `coord status` can render useful aggregates; operators can debug directly.
- Bounded history. Scheduled DELETE / VACUUM keeps `events` table from ballooning.
- Universal availability. Every macOS + Linux install has SQLite.

### Disadvantages

- Inspectability regression. `cat sessions.json | jq` is trivial; `cat state.db` is binary. Mitigation: `coord dump --format=json` that streams current state.
- Binary schema migration friction. Adding a column requires ALTER TABLE; coordinating migrations with running sessions is harder than a JSON additive-fields pattern.
- SQLite version skew. Older Linux distros ship ancient sqlite; if we use recent features (e.g., `json_patch`), installer must check version.
- WAL file cleanup. Under some crash conditions, WAL needs explicit cleanup.

## Why it's deferred

- **User direction:** simplicity priority; JSON is inspectable with zero learning curve.
- **No scaling evidence yet.** Phase 7 will show whether JSON really hits a ceiling at 5 sessions.
- **Migration cost.** Requires touching every hook.

## What would trigger revisiting this

- Phase 7 measurements show JSON parse/write is dominant overhead.
- `events.jsonl` grows to MB+ in common sessions and queries become slow.
- Mediator queries outgrow `jq` ergonomics.
- A UI project (`FUTURE_WORK_visualization_ui.md`) needs fast range queries against historical events.

## Relation to other future-work docs

- `FUTURE_WORK_daemon_architecture.md` — a daemon typically uses in-memory state with SQLite as the on-disk backing store. Combining is natural.
- `FUTURE_WORK_go_native_implementation.md` — Go + SQLite is a standard combo (`modernc.org/sqlite` is pure-Go, no CGO).
- `FUTURE_WORK_visualization_ui.md` — a UI reading SQLite is trivially implemented with any SQL library.

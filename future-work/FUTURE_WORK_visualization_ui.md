# FUTURE_WORK — Visualization UI

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 makes all coordination state inspectable via the `coord` CLI (`status`, `locks`, `tasks`, `log`, `events`) and the raw JSONL stream at `.coord/events.jsonl`. This is sufficient for debugging but offers no time-aware, visual overview of what's happening across sessions. The user's direction for v1 explicitly asks that activity logging be rich enough to feed a future UI.

A UI consuming `events.jsonl` (and `sessions.json` for live state) can render:

- A live timeline per session: which files each is reading/writing, lock state, pending tasks.
- A file-centric view: for file X, the history of locks, tasks, notifications.
- Deadlock / anomaly highlighting: cycle in `task_graph`, long-held locks, stuck waiters.
- Playback: given a time range, replay events step-by-step to investigate "what happened when."
- Task delegation animation: arrows showing which session delegated what to whom, statuses as colors.

## Proposed approach

### Data sources

- **`sessions.json`** — current state snapshot. Poll at 1–2 Hz or hook-driven push.
- **`events.jsonl`** — firehose of every coordination event. Tail + parse; aggregate as needed.
- **`sessions_history.json`** — curated archive; useful for post-hoc timelines longer than the events retention window.

### Architecture options

**Option A — Local web UI launched on demand.**
`coord ui` command starts a tiny HTTP server on `127.0.0.1:<port>` serving a static SPA (React/Svelte). The SPA:
- Polls `/api/state` for `sessions.json`.
- Subscribes to `/api/events` via Server-Sent Events that tails `events.jsonl`.
- Renders in-browser visualizations (D3.js timeline, Graphviz-style delegation graph).

**Option B — CLI-based TUI.**
`coord tui` (built on `bubbletea` / `textual` / `urwid`). No browser; terminal-native. Lower setup cost; less visually expressive.

**Option C — VS Code extension.**
Extension panel reads the same data sources; renders in the editor. Tight integration; requires VS Code.

Recommendation when built: ship A first (broadest audience), B as a complementary operator tool, C later if demand emerges.

### Features roadmap (suggested)

1. **Live status panel.** Grid of sessions with current state, held locks, pending tasks. Colored state indicators.
2. **File timeline.** One row per file; horizontal axis is time; colored segments show lock holders; glyphs show tasks, stale-read events, Mediator interventions.
3. **Delegation graph.** Directed graph of `task_graph`; arrows animated on status change. Cycle detection highlights.
4. **Event stream with filters.** Table view of `events.jsonl` with full-text filter + kind/session/file filters.
5. **Playback.** Slider over a time range replays state changes. Useful for debugging "why did my session get denied at 10:14:03?"
6. **Mediator decision log.** Chronological view of `sessions_history.json` MEDIATOR_VERDICT events, with before/after state diffs.
7. **Performance dashboard.** Latency percentiles of hook calls (from events), flock contention graph, task-delegation success/fail rate.

### Event schema considerations

v1's `events.jsonl` schema is designed to feed this UI. When building the UI, verify:
- Every event has `ts` (sortable), `session`, `kind`.
- Payload fields are consistent per kind.
- New event kinds are added with backward-compatible additive fields only; never repurpose an existing kind.

If during UI construction the schema proves inadequate, propose additions via `plan-revisions.md` — do not silently change the event format.

### Relation to cost / abandonment

The user's abandonment conditions include "the system degrades output quality despite correct operation." A UI makes such degradation far more detectable: if a user can see their session is spending 40% of wall-clock waiting on locks, they can evaluate the cost/benefit directly.

## Why it's deferred

- v1 scope is the coordination system itself, not tooling around it.
- The event log is built to support a UI *eventually*; shipping a UI now adds engineering load without completing the coordination system.
- A UI is best built against a stabilized event schema; v1 may still tweak event fields across phases.

## What would trigger revisiting this

- User feels "I cannot tell what's going on" during regular use.
- Community adopts the system; external users want at-a-glance status.
- Phase 7 data suggests deadlocks / orphan tasks happen often enough that an inspector beats `coord log | jq`.
- Someone volunteers to build it.

## Relation to other future-work docs

- `FUTURE_WORK_sqlite_state_storage.md` — a UI on SQLite is simpler to build than on JSONL (no streaming parser).
- `FUTURE_WORK_daemon_architecture.md` — a daemon can push state changes to the UI directly via WebSocket.
- `FUTURE_WORK_remote_sessions.md` — if remote sessions join the fleet, the UI is how the user would monitor them.

# FUTURE_WORK — Go-Native Implementation

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 hook scripts are Bash + `jq` + `flock`. Each hook invocation spawns bash and at least one jq. Baseline cold-start cost: ~30–50ms before any real work. At high tool-call frequency across multiple sessions, this overhead accumulates. Additionally, the Bash 3.2-compatibility requirement constrains the coding style in ways that complicate logic over time.

A Go-compiled binary would replace the hook scripts with a single static executable. Startup cost drops to single-digit milliseconds; JSON handling uses the Go standard library (faster and stricter than `jq`); `flock` becomes a library call (`golang.org/x/sys/unix.Flock`); error handling is typed.

## Proposed approach

### Scope

Replace `.coord/hooks/*.sh` and `.coord/lib/*.sh` with a single `coord` binary that dispatches internally on event type. The hook entries in `.claude/settings.local.json` become:

```json
{"hooks": {
  "PreToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "coord hook pre-tool-use-read"}]}],
  ...
}}
```

The `coord` CLI already exists in v1. Extend it with a `hook <event>` sub-command tree. The implementation shifts from Bash to Go; the interface to Claude Code is unchanged.

### Components

1. **`cmd/coord/main.go`** — CLI entry point with Cobra or similar.
2. **Hook handlers** — `internal/hooks/pre_tool_use_read.go`, etc. Each reads stdin JSON, consults `internal/state`, emits response.
3. **`internal/state`** — sessions.json reader + atomic writer. Uses `encoding/json` + `os.Rename` + `unix.Flock`. Type-safe vs the v1 `jq` pipelines.
4. **`internal/hash`** — sha256 via `crypto/sha256`. Stream large files rather than reading all at once.
5. **`internal/watchdog`** — PID+lstart liveness check using `/proc/<pid>/stat` on Linux, `ps` output on macOS (no `/proc`).
6. **`internal/mediator`** — agent hook orchestrator.
7. **`internal/log`** — structured event writer with bounded concurrency (no spawn overhead per event).

### Distribution

- **Static binary** — `go build -ldflags='-s -w'`, cross-compiled for `darwin/amd64`, `darwin/arm64`, `linux/amd64`, `linux/arm64`. Release via GitHub + install script that downloads the right binary.
- **Homebrew formula** — `brew install <tap>/coord` installs the binary.
- **Alternate: build from source** — `go install github.com/<org>/coord@latest`. Requires Go on the dev machine.

### Migration from Bash

1. Schema unchanged.
2. The two implementations are wire-compatible: a Go hook and a Bash hook can coordinate via the same `sessions.json` (both respect the `flock` + temp-file-rename convention). Mixed-mode is acceptable during migration; recommended steady state: all-Go or all-Bash.
3. Installer gains a `--runtime=<bash|go>` flag. Default is `bash` initially; flips to `go` once Go implementation is validated.
4. Removal of Bash implementation only after Go proves itself across the test matrix for multiple phases.

### Performance expectations

| Metric | Bash + jq (v1) | Go binary |
|---|---|---|
| Cold-start per hook | 30–50 ms | 5–10 ms |
| sessions.json read+parse (typical size) | 15–30 ms | 1–3 ms |
| sessions.json write | 10–20 ms | 2–5 ms |
| Under 5-session contention p99 | 150–250 ms | 40–80 ms |

(Rough estimates; validate via benchmark if port is commissioned.)

### Advantages

- Speed. Tool-call overhead becomes negligible even at 10 sessions.
- Type safety. Schema changes become compile-errors, not runtime JSON-shape surprises.
- Testability. Go unit tests are faster, richer, and less flaky than `bats`.
- Error handling. Typed errors + stack traces beat shell exit-code interpretation.
- Simpler Bash-3.2 workarounds. We stop writing to the lowest common shell denominator.

### Disadvantages

- Installation complexity. A binary distribution is heavier than `curl install.sh | bash`. Homebrew helps; raw-download less so.
- Debuggability. When a user hits a coord bug, they cannot `cat coord` to inspect. Release debug binaries + verbose mode to mitigate.
- Platform matrix grows. macOS amd64 + arm64, Linux amd64 + arm64, eventually Windows (from the other future-work doc).
- Rebuild every upgrade. Dev machines must have the Go binary fresh; silent staleness is easier than with shell scripts that are literally the source.

## Why it's deferred

- **User direction.** Prefer simpler Bash-first approach for community adoption.
- **No evidence of the ceiling yet.** Phase 7 will measure real contention. If Bash + `jq` + `flock` handles 5 sessions comfortably, Go is unnecessary.
- **Development cost.** Writing and maintaining two implementations is the main cost; preserving only the Go implementation is cheaper long-run but expensive short-term.

## What would trigger revisiting this

- Phase 7 measurements show hook latency is a felt problem at the user's 5-session baseline.
- Bash 3.2 compat style becomes a bug source (test flakes, regressions).
- A contributor donates a Go implementation.
- Expanding to Windows via `FUTURE_WORK_windows_native_support.md` — if the port is via Go (rather than Node), this doc becomes more relevant.

## Relation to other future-work docs

- `FUTURE_WORK_daemon_architecture.md` — a Go binary can be a daemon OR a stateless per-invocation tool. Both can coexist: Go binary stateless in one repo, Go daemon in another, configured via `.coord/config.json`.
- `FUTURE_WORK_windows_native_support.md` — a Go port is one approach to Windows; Node is another.
- `FUTURE_WORK_sqlite_state_storage.md` — Go has excellent SQLite bindings (`modernc.org/sqlite`). The combination (Go + SQLite) is a strong alternative to JSON + flock.

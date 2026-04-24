# FUTURE_WORK — Windows Native Support

> **NOT INCLUDED IN CURRENT PLAN. DO NOT READ THIS FILE AS PART OF IMPLEMENTATION PREP.**
> **This document captures a deferred direction. Revisit only when/if the conditions in the associated note are met.**

---

## Problem this addresses

v1 targets macOS + Linux natively. Windows users are directed to WSL2 (which presents as Linux). This is a documentation workaround, not an implementation; Windows developers who refuse to use WSL2, or whose corporate policies forbid it, cannot adopt the system.

A Windows-native port would let `cmd.exe` / PowerShell users adopt the coordination system without WSL2.

## Proposed approach (enough detail to resume)

### Option A — Dual implementation with a thin runtime shim

Keep the Bash + jq + flock implementation for macOS/Linux. Ship a parallel Node.js (or Go) implementation for Windows native. A shared JSON schema for state guarantees the two implementations are interoperable in principle (though in practice we do not mix platforms in the same coordinated scope).

**Components that need Windows-native replacement:**

- `flock` → Windows has `LockFileEx` via a native binding. In Node: `proper-lockfile`. In Go: `golang.org/x/sys/windows.LockFileEx`. For PowerShell: `System.IO.FileStream` with `FileShare.None`.
- `shasum -a 256` → `CertUtil -hashfile <path> SHA256` or Node `crypto.createHash('sha256')`.
- `ps -p <pid> -o lstart=` → `Get-Process -Id <pid>` with `StartTime`. PID recycling check becomes `Get-Process | Select Id, StartTime` comparison.
- `jq` → ship via `choco install jq` / `scoop install jq`; alternatively use a Node JSON layer (no external dep).
- `mv tmp dest` atomic rename → `MoveFileEx` with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH` in native code; Node's `fs.rename` is POSIX-like on Windows but less atomic under antivirus contention.
- Hook scripts `#!/usr/bin/env bash` → replace with `node hook.js` or `powershell -File hook.ps1`; Claude Code on Windows invokes via `cmd.exe` by default, so script entry must be Windows-invocable.

### Option B — Require WSL2 (current direction)

Maintain v1's documentation-only approach. The system runs unchanged under WSL2. This is cheap; it excludes users who cannot use WSL2.

### Known Claude Code Windows hook issues to track

From Phase 1 research + community reports as of 2026-Q1:
- WSL path resolution conflicts when hooks are declared with `/bin/bash` paths but the Claude Code binary resolves them through the Windows path layer.
- `$CLAUDE_PROJECT_DIR` sometimes normalized with forward slashes, sometimes backslashes; cross-tool parsing is fragile.
- Hook stdin JSON on Windows may have `\r\n` line endings that Bash's `jq` handles but naïve shell parsing breaks.
- Anti-virus interference: Windows Defender scanning `.coord/` state on every write doubles flock hold times.

Before any port, verify each of these still applies and document current behavior.

### Recommended path when port becomes justified

1. Ship Node.js port (Option A, Node variant) because Node is the smallest runtime with a mature cross-platform locking lib (`proper-lockfile`) and json handling (native).
2. Dual-test in CI: macOS + Linux run Bash hooks; Windows runs Node hooks; both against the same `sessions.json` schema.
3. Installer detects OS and installs the appropriate variant.
4. Document: "Within a single repo, do not mix Windows-native and Bash sessions; choose one implementation per team." Mixing is technically possible but increases the chance of subtle state-file race conditions due to differing atomic-rename semantics.

## Why it's deferred

- **User direction.** v1 scope is narrowed to macOS + Linux.
- **Capability gaps.** Claude Code's hook runtime on native Windows has documented issues that would bloat the v1 implementation to defend against.
- **Implementation cost.** Maintaining two hook implementations doubles the test matrix and risk surface.
- **Simpler workaround exists.** WSL2 is broadly available and handles the case.

## What would trigger revisiting this

- Corporate / community demand from Windows users who cannot use WSL2.
- Claude Code resolves its Windows hook issues upstream, making a native port cheap.
- WSL2 proves insufficient for some real use case (e.g., a specific filesystem interaction).
- v1 stabilizes and has capacity for platform expansion.

## Out-of-scope for this future work

- Cross-platform coordination (macOS session + Windows session in same repo at same time). Remains out of scope even with a native Windows port; covered briefly by `FUTURE_WORK_remote_sessions.md` if it ever merges.

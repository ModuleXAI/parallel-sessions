# CLAUDE.md — Multi-Session Coordination System

This file has three audiences, clearly separated.

- **Part A** is for Claude (the Phase 3 builder) during construction. It governs how the system gets built.
- **Part B** is shipped as part of the coordination system and read by every coordinated session at runtime. It governs how registered sessions respond to hook signals.
- **Part C** is meta — rules about this file itself.

**Precedence at all times:** User direction (PLANNING_INSTRUCTIONS.md / `09-user-answers.md`) > `IMPLEMENTATION_PLAN.md` > this file's runtime rules > Phase 1 research.

---

## Part A — Rules for the Phase 3 Builder (Construction-Time)

### A.1 What this project is

A coordination layer for multiple Claude Code sessions operating in the same repository. Built in Bash + `jq` + `flock`, targeting macOS + Linux native. It interposes hooks that track reads, enforce write locks, delegate tasks, detect stale reads, and heal from crashes.

### A.2 Where the plan, research, and user direction live

*Files under `archive/` are historical artifacts consulted only when explicitly directed (per §10.3's decision tree in the plan), not routinely.*

- `archive/PLANNING_INSTRUCTIONS.md` — user's authoritative direction. Read first.
- `IMPLEMENTATION_PLAN.md` — single source of truth for what to build and in what order.
- `archive/09-user-answers.md` — raw user answers (historical context).
- `archive/01-comprehension-summary.md` through `archive/10-working-notes.md` — Phase 1 research.
- `archive/planning-scratch.md` — planner's synthesis notes (historical).
- `future-work/FUTURE_WORK_*.md` — **out of scope.** Do not read during Phase 3 implementation unless revisiting a deferred decision.

### A.3 Document precedence

User direction > IMPLEMENTATION_PLAN.md > this CLAUDE.md runtime rules (Part B) > Phase 1 research.

If documents conflict, the higher-precedence wins. If the higher-precedence is silent on a point, descend the list.

### A.4 Phase-by-phase execution discipline

- Never build outside the current phase's scope, even if "obvious."
- Phases 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 in order. Each phase's "Done when" criteria must be met before starting the next.
- Mediator capability grows across phases per the plan's Mediator thread. Do not ship all Mediator features in one phase.
- Task delegation and self-delegation are Phase 6 only. Do not implement `coord task-open` or `coord self-delegate` machinery in earlier phases. Earlier phases' deny messages may mention the option for future use; the CLI subcommand must exit "disabled" until Phase 6.

### A.5 Quality standards (mandatory)

- **All Bash scripts begin with `set -euo pipefail`.** No exceptions.
- **All state-file writes go through `lib/atomic_write.sh`.** Never `>` or `jq -i` directly on `sessions.json`, `sessions_history.json`, or `config.json`. Never use `tee` without `flock`. Event log writes go through `lib/log_event.sh`, which holds its own lock on `events.lock`.
- **All hooks handle their own crash gracefully.** Trap SIGINT/SIGTERM where meaningful; write to `.tmp` then `mv`; never leave a half-written state file.
- **All shell scripts use `#!/usr/bin/env bash`** and **must run on macOS's default Bash 3.2**. Forbidden: associative arrays (`declare -A`), `readarray`/`mapfile`, `${var,,}`, `${var^^}`, `&>>` (use `>> ... 2>&1`), Bash 4+ parameter expansion (`${var@Q}`, etc.). Portable alternatives: parallel indexed arrays with a key-to-index helper, `tr '[:upper:]' '[:lower:]'`.
- **No Python, Node.js, Go, or Rust code** in v1. If something appears to need a feature Bash cannot handle cleanly, stop and open `plan-revisions.md` with the tension. Do not silently reach for another runtime.
- **Every new component has a test** before "done." `bats` test suite must pass.
- **Event logging is non-blocking.** Use `log_event ... &` to background the append so hook latency is not increased by log writes.
- **No Windows-specific code paths.** Forbidden: `if [[ "$OSTYPE" == "msys"|"cygwin"|"win32" ]]`, `cmd.exe`, `powershell`, PowerShell-compatible path handling. If you find yourself writing one, stop — Windows is out of scope for v1 and has a dedicated future-work document.
- **Do not silently deviate from the plan.** Write to `plan-revisions.md` and surface to the user.
- **Prefer `shasum -a 256` over `sha256sum`** (macOS ships the former, Linux ships both). Use a small wrapper in `lib/hash.sh`.
- **Never shell-construct JSON by string concatenation.** Always use `jq -n --arg ... --arg ...` to build.
- **Gitignore hygiene.** Every artifact created by the system (state, logs, hook scripts under `.coord/`, `.claude/settings.local.json`) must be gitignored by the installer.

### A.6 Hook specification rigor

Every hook script must:
- Exit 0 for "allow" paths (or emit JSON with `permissionDecision: "allow"`).
- Exit 0 with JSON `permissionDecision: "deny"` + `permissionDecisionReason` for hard-enforced denials. Do not use exit 2 unless the hook genuinely wants the generic blocking-error treatment.
- Exit 0 without side effects if the current session is not a participant (`$CLAUDE_COORD` unset or no `.active` marker).
- Write event log entries in the background, not on the critical path.
- Complete within 2 seconds p99 in the no-contention case. Measure this in `bats`.
- Never spawn subshells inside critical (`flock`-held) sections.

### A.7 Communication & escalation

- Surface blockers immediately; do not guess. The user's trust depends on honest reporting.
- Before making a choice this plan does not cover, consult user direction, then IMPLEMENTATION_PLAN.md (§10.3 decision tree).
- Every phase ends with `phase-N-signoff.md` (local, not committed) summarizing what got built, what didn't, and which risks materialized.

### A.8 Proof-of-concept allowance

If you need a tiny POC to verify a Claude Code capability assumption before committing to a design decision, that is allowed. Do NOT commit the POC. Capture only the finding: update `phase0-verification.md` (Phase 0 artifact) or open a `plan-revisions.md` entry.

### A.9 End-of-phase completion report format

`phase-N-signoff.md` (local, not committed) structure:

```
# Phase N Sign-off — <date>

## Done-when criteria
- [x] criterion 1 — evidence: <test path or observation>
- [x] criterion 2 — evidence: ...

## Risks realized
- R<n>: <what happened, how mitigated>

## New risks discovered
- (added to Section 7 via plan-revisions.md)

## Open questions for next phase
- ...

## Artifacts
- bats tests: <path>
- build notes: <path>
```

### A.10 Commit discipline

- Never commit `.coord/` (it is gitignored).
- Never commit state snapshots to the research files (`01`–`10`, `multi-session-coordination-system-en.md`, `09-user-answers.md`, `PLANNING_INSTRUCTIONS.md`). They are historical record.
- Phase branches merge back via PR; commit messages reference phase number and done-when criteria satisfied.

### A.11 Construction Progress Discipline

You MUST maintain `IMPLEMENTATION_LOG.md` at the project root throughout Phase 3 construction. This file is your primary artifact for "where are we."

**Protocol:**

- **Before starting any task** (component, experiment, test suite, or install script), append an unchecked entry with task ID `T<phase>.<seq>` and start timestamp.
- **After completing any task**, check it off with completion timestamp and a one-line result note including test outcomes.
- **If paused mid-task**, leave it as `[IN_PROGRESS]`; never delete entries.
- **When starting a phase**, add a new phase section with header, start timestamp, and status; copy the phase's "Done when" criteria from the plan §5 as the ship gate checklist at the end of that section.
- **When closing a phase**, every task entry in the phase section must be checked (or explicitly ABANDONED with a plan-revisions reference), and every ship gate item must be checked with evidence.

**When resuming after context loss or a session break:**

- FIRST read `IMPLEMENTATION_LOG.md` end to end.
- THEN read `FINDINGS.md` for anything flagged OPEN.
- THEN return to the last `[IN_PROGRESS]` task or the first unchecked one.

**IMPLEMENTATION_LOG.md is gitignored.** It is for the builder and the user, not git history.

### A.12 Discovery Logging Discipline

You MUST maintain `FINDINGS.md` at the project root. This file captures everything the plan didn't anticipate: observations, plan inaccuracies, environment quirks, deferred questions.

**When to add an entry:**

- The plan says X, you observe Y. → Entry with status OPEN and a proposed action path.
- You notice something non-blocking but worth remembering (e.g., "this would be cleaner if refactored later"). → Entry with status DEFERRED.
- You hit a macOS vs Linux quirk, a Bash version issue, a jq edge case. → Entry with status RESOLVED once handled.
- You realize a Phase 1 document was wrong or ambiguous. → Entry with OPEN; may trigger a plan-revisions.md entry.

**Entry format:**

```
## F-<NNN> — <short title>
**Status:** OPEN | RESOLVED | WONTFIX | DEFERRED
**Raised:** <ISO timestamp> during T<phase>.<seq>
**Summary:** 2-4 sentences describing the observation.
**Action:** what happens next (resolution plan, plan-revisions reference, or "accept as deferred").
**Resolution:** (filled in when status becomes RESOLVED or WONTFIX)
```

**Rules:**

- IDs are monotonically assigned: F-001, F-002, F-003 …
- IDs are **never reused**, even if an entry becomes WONTFIX.
- **Before declaring a phase done**, every OPEN finding relevant to that phase's scope must have a disposition (RESOLVED, WONTFIX, or explicitly DEFERRED with a decision deadline).
- FINDINGS.md and plan-revisions.md are distinct: FINDINGS captures *observations*; plan-revisions captures *decisions to change the plan*. Many findings do not require plan changes.

**FINDINGS.md is gitignored.**

### A.13 Testing, portability, and subagent-invocation notes (Phase 3 + Phase 4 lessons)

These patterns accumulated during Phase 3 + Phase 4 construction. Each surfaced from a real bug and must be the default for future work. They are operational guidance, not architectural decisions — no plan-revision required.

**Pre-implementation audit checklist (Phase 4 reinforcement, T4.09 disposition).** Lesson #2 (pipefail capture) hit FOUR times during Phase 4 construction (T4.04 ×2, T4.06 ×1, T4.07 ×1) — all caught pre-commit by tests but the repeat suggests retrospective awareness is not enough. When implementing **spawn helpers, pipeline-integration code, or ship-gate fixtures**, audit the following BEFORE running tests:

- **Pipefail patterns** (lesson #2 below): `ls | sort | wc`, `cat | jq`, `var=$(cmd)` followed by `rc=$?`, `var=$(cmd) || alt` — the last form always reads `rc=0` from the `||` branch in bash 3.2 with set -e + pipefail propagated from sourced libraries. Use `if var=$(cmd); then ...; else ...; fi` for true rc capture, OR explicit `|| <fallback>` per-call. Inspect every `$()`/`|` for the failure modes set -e + pipefail can take.
- **Event-emission completeness**: when adding pipeline-completion or lifecycle events, ensure every code path (success, partial, failure) emits the appropriate event. Silent paths often miss the audit emission and the gap is only caught when a ship-gate fixture asserts the event count. Surface as a checklist item: "does every return / exit branch emit the lifecycle event?"
- **Heuristic ambiguity in test assertions**: when assertions match specific sub-cases of broader heuristic categories (e.g., `prefilter_reason=whitespace_only` vs `blank_only` — both indicate trivial-drift SAFE), accept multiple valid outcomes. Otherwise heuristic ordering changes silently break tests.

Four hits during Phase 4 build (T4.04 dead `pre_snapshot=$(ls...)` pipeline + missing jq fallbacks; T4.06 `var=$()` rc-capture + missing `VALIDATOR_PIPELINE_COMPLETED` on SAFE silent path; T4.07 prefilter_reason ambiguity). Pattern requires active checklist application, not retrospective reading.

**1. `perl utime` for portable mtime manipulation in tests** (T3.04 lesson, F-016 family).

Tests that need to backdate a file's mtime (e.g., to verify a stale-lock detector) MUST use `perl utime` with raw epoch seconds, NOT `touch -t`:

```bash
perl -e 'utime time-60, time-60, $ARGV[0]' "$file"   # 60 seconds ago
```

`touch -t` interprets its timestamp argument in LOCAL timezone, not UTC. On hosts where local != UTC, a `date -u` formatted string fed to `touch -t` produces a future-dated mtime (observed: 5h drift on macOS, surfaced in T3.04 watchdog cache stale-lock test). `perl utime` takes a raw epoch and bypasses both `touch -t` and date-format conversions. Perl ships in the base OS on macOS and Linux per F-009, so this is portable.

**2. Command-substitution capture pattern for `set -o pipefail` isolation in sourced libraries** (T3.05 lesson, F-018 family).

Sourced libraries that may run under callers using `set -o pipefail` (which propagates from any of `log_event.sh`, `atomic_write.sh`, etc.) MUST capture command output into a variable BEFORE piping, instead of piping directly:

```bash
# WRONG — pipefail will kill the function when ps -p <gone-pid> returns rc=1:
ps -p "$pid" -o lstart= 2>/dev/null | sed -e 's/^ *//' | tr -d '\n'

# RIGHT — function's trailing command is always printf (rc=0):
local raw
raw=$(ps -p "$pid" -o lstart= 2>/dev/null) || raw=""
printf '%s' "$raw" | sed -e 's/^ *//' | tr -d '\n'
```

Bash 3.2 lacks `local +o pipefail`, so this capture pattern is the portable alternative. Surfaced in T3.05 watchdog `_coord_watchdog_ps_lstart` (caller saw rc=2 with empty stdout instead of rc=0 with empty lstart, killing the probe silently). Also relevant to any helper that parses optional command output where rc=1 is normal.

**3. GNU-first `stat` probe for portable file-mtime / file-size helpers** (T3.10 lesson, F-018).

Helpers that read file mtime or size MUST try GNU form first, validate the captured value is a pure integer, and fall back to BSD only on rc != 0 OR non-numeric output:

```bash
# WRONG — Linux GNU stat re-purposes -f as filesystem info (rc=0 with garbage):
mtime=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || printf '0')

# RIGHT — GNU first; numeric-validate; BSD only on failure:
mtime=$(stat -c '%Y' "$f" 2>/dev/null)
case "$mtime" in
  ''|*[!0-9]*) mtime="" ;;
esac
if [ -z "$mtime" ]; then
  mtime=$(stat -f '%m' "$f" 2>/dev/null)
  case "$mtime" in
    ''|*[!0-9]*) mtime=0 ;;
  esac
fi
```

macOS users see no symptoms with the WRONG form (BSD stat succeeds, fallback never fires). Linux deployments would silently mis-evaluate file-age comparisons or produce garbage event payloads.

**4. `claude -p` spawn discipline for any in-process Claude invocation** (T3.06 + T3.07 lesson).

Hook scripts or libraries that spawn `claude -p` (today: only the Mediator; future: any in-process subagent pattern) MUST follow these rules:

- `--output-format json` — structured output is the only reliable parsing path.
- ALWAYS parse `is_error` from JSON. NEVER rely on shell exit code: `claude -p` exits 0 even on auth failure / budget cap / model error. The truth is in the JSON payload.
- `--max-budget-usd <cap>` — cost guard. Default $0.50/invocation; cache_creation tokens dominate cost (~$0.10 minimum without `--bare`).
- `--allowedTools` + `--disallowedTools` — restrict the spawned session's capabilities. Never give it Edit/Write/NotebookEdit if it should mutate state via Bash + atomic_write helpers.
- `CLAUDE_COORD=0` in spawn env — coord hooks early-exit, preventing recursive registration of the spawned session. Required even when `--bare` is used (defense in depth).
- `CLAUDE_CODE_MEDIATOR=<depth>` env (or analogous) — recursion guard marker. The spawn helper MUST refuse to spawn from within a session that already has this marker set.
- Spawned `claude -p` gets a NEW UUID `session_id`, NOT the parent's. Subagent-filter (`subagent_filter.sh`) does NOT recognize claude -p spawns — the isolation comes from `--bare` or `CLAUDE_COORD=0`, not from agent_type filtering.
- Hook timeout: 120s wall-clock max for the spawn's full lifetime. Real Mediator analysis takes 20-35s with `--bare`, 30-60s without; >120s indicates stuck spawn that should be killed and treated as Mediator-failed.

These rules apply to any future use of `claude -p` from coord scripts, not just the Mediator. See `src/lib/MEDIATOR_REFERENCE.md` (installed at `.coord/mediator/MEDIATOR_REFERENCE.md`) for the full Mediator-specific contract.

**5. `if var=$(cmd); then ...; else ...; fi` pattern for rc capture under set -e + pipefail** (T4.06 lesson, Phase 4 reinforcement).

The `var=$(failing_command) || alt; rc=$?` form is broken under bash 3.2 + set -e + pipefail (inherited from sourced log_event.sh / atomic_write.sh). The `||` branch always succeeds (rc=0), so the subsequent `rc=$?` reads `0` even when the command failed. The function then proceeds as if the call succeeded, silently dropping the failure path.

```bash
# WRONG — rc captured from || branch is always 0; failure path never fires:
result=$(coord_validator_spawn ... 2>/dev/null) || result=""
rc=$?
if [ "$rc" -ne 0 ]; then handle_failure; fi   # never executes

# RIGHT — `if var=$(...)` exempts from set -e and dispatches on the
# subshell's actual rc:
if result=$(coord_validator_spawn ... 2>/dev/null); then
  : # success path
else
  handle_failure
fi
```

Use `if var=$(cmd)` whenever you need to BOTH capture stdout AND act on rc. For commands where stdout is not needed, `if cmd; then ...; else ...; fi` works directly. Per-stage `|| <fallback>` is acceptable when you only need a default value (no failure-path branching needed).

**6. Event-emission audit at every return path** (T4.07 lesson).

When adding lifecycle events to a multi-branch function, the silent-success path is the easiest to miss. Audit by enumerating every `return` / function-exit / loop-iteration-end and confirming each emits the lifecycle event with appropriate payload flags. Test scenarios that assert event counts (not just presence) are the canonical verification.

```bash
# WRONG — COMPLETED event only fires when banner is non-empty:
if [ -n "$BANNER_LINES" ]; then
  STALE_BANNER=...
  coord_log_event kind=VALIDATOR_PIPELINE_COMPLETED ...
fi

# RIGHT — emit COMPLETED inside the per-iteration branch with payload
# flags carrying the disposition; outer banner block only composes
# the banner from BANNER_LINES.
case "$drift_kind" in
  modified)
    pipeline_ok=1
    if line=$(_coord_phase4_run_pipeline ...); then : ; else pipeline_ok=0; ...; fi
    coord_log_event kind=VALIDATOR_PIPELINE_COMPLETED \
      pipeline_ok="$pipeline_ok" had_banner=$([ -n "$line" ] && printf 1 || printf 0) ...
    ;;
esac
```

The lifecycle-event-completeness audit is part of the lesson #2 pre-implementation checklist above.

These rules apply to any future hook / pipeline / spawn-helper construction. The Phase 4 implementations of `pre_tool_use_write.sh` (T4.06), `lib/validator_spawn.sh` (T4.04), and `phase4_ship_gate` fixtures (T4.07) are the canonical references for the patterns.

**7. Bash 3.2 parser fragility on `out=$( ( cmd ) 9>"lock" )` form** (T5.02 lesson, F-018 portability family).

The `out=$( ( cmd ) 9>"$lock" )` pattern fails to parse under Bash 3.2 when the inner subshell contains nested `$(cmd "arg")` inside double-quoted strings. Bash reports `syntax error near unexpected token`)'`on the outer `)`. macOS's default Bash (3.2.57) is the binding version per CLAUDE.md §A.5. The pattern is convenient because it captures stdout AND holds flock simultaneously, but it is unsupportable under Bash 3.2.

```bash
# WRONG — bash 3.2 syntax error on inner $(cmd "...") nesting:
out=$(
  (
    flock -x -w "$timeout" 9 || exit 2
    : > "${COORD_DIR}/wakers/${sid}-$(_coord_wq_sanitize "$file").wake"
    printf 'appended\t%s\n' "$sz"
  ) 9>"$lock_path"
)
```

RIGHT — temp-file inter-subshell communication; mirrors `lib/atomic_write.sh`, `lib/log_event.sh`, `lib/mediator_spawn.sh`:

```bash
local out_tmp="${COORD_DIR}/wait_queues/.enq.$$.${sid}.out"
: >"$out_tmp"
(
  flock -x -w "$timeout" 9 || exit 2
  printf 'appended\t%s\n' "$sz" >"$out_tmp"
) 9>"$lock_path"
local rc=$?
local out
out=$(cat "$out_tmp" 2>/dev/null || printf '')
rm -f "$out_tmp"
```

Surfaced in T5.02 `coord_wait_queue_enqueue` + `coord_wait_queue_dequeue`. Caught at bats setup phase before any test ran. Pre-sanitize the file path into a local variable BEFORE entering the flock-wrapped subshell to keep nested `$()` interactions outside the outer command-substitution boundary.

**8. bats PATH manipulation is fragile cross-host** (T5.03 lesson, F-018 family).

A bats helper that strips PATH directories to fake-absent host binaries (e.g., `fswatch` to test polling fallback) breaks on hosts where `/usr/bin` contains other essentials. On Linux with `inotify-tools` installed at `/usr/bin/inotifywait`, stripping `/usr/bin` from PATH ALSO strips `chmod`, `rm`, `sleep`. Tests that run after the strip silently fail with cascading "command not found" errors.

```bash
# WRONG — strips /usr/bin if it contains inotifywait → chmod/rm/sleep break:
_isolate_path() {
  local kept=""
  IFS=':'
  for entry in $PATH; do
    if ! { [ -x "$entry/fswatch" ] || [ -x "$entry/inotifywait" ]; }; then
      kept="${kept:+$kept:}$entry"
    fi
  done
  PATH="$TMP/bin${kept:+:$kept}"
}
```

RIGHT — skip-based tests using `command -v` against the live host:

```bash
@test "wait_backend: fswatch present + macOS -> backend=fswatch" {
  [ "$(uname -s)" = "Darwin" ] || skip "macOS-only"
  command -v fswatch >/dev/null 2>&1 || skip "fswatch not installed"
  run coord_wait_backend_detect
  [ "$output" = "fswatch" ]
}
```

Skip-based tests reflect the host configuration honestly without breaking the test environment. Use `skip "..."` whenever you cannot reproduce a binary's absence without breaking other tools.

**9. Helper stdout bleeds into `$()` captures of higher-order functions** (T5.04 lesson).

When a function captures another function's stdout via `$()` and the inner function calls helpers that print to stdout under rc=0 (e.g., `coord_validator_prefilter` prints `safe:whitespace_only`, `coord_validator_cache_lookup` prints `MINOR\t<source>\t<diff>`), the helper output bleeds into the outer capture. The captured value is the concatenation of all writes during the call. ALSO, globals set in the captured function are LOST because `$()` runs in a subshell.

```bash
# WRONG — prefilter prints "safe:whitespace_only" to stdout under rc=0;
# this bleeds into $diff_summary captured by the caller:
_coord_notify_compute_diff_summary() {
  if coord_validator_prefilter "$holder" "$path" "$prev_hash" "$current_hash" 2>/dev/null; then
    _COORD_NOTIFY_LAST_TIER='prefilter_safe'   # LOST in subshell
    printf 'trivial change (whitespace/comment)'
  fi
}
diff_summary=$(_coord_notify_compute_diff_summary ...)  # = "safe:whitespace_only\ntrivial change..."
```

RIGHT — explicit stdout suppression on inner helpers + TSV stdout protocol for tier propagation:

```bash
_coord_notify_compute_diff_summary() {
  if coord_validator_prefilter "$holder" "$path" "$prev_hash" "$current_hash" >/dev/null 2>&1; then
    printf 'prefilter_safe\ttrivial change (whitespace/comment)'
    return 0
  fi
  printf 'fallback\tmodified by %s' "${holder:0:8}"
}
local _ds_tsv
_ds_tsv=$(_coord_notify_compute_diff_summary ...)
diff_tier=$(printf '%s' "$_ds_tsv" | awk -F'\t' '{print $1}')
diff_summary=$(printf '%s' "$_ds_tsv" | awk -F'\t' '{print $2}')
```

Two patterns to remember: (a) explicit `>/dev/null 2>&1` on inner helpers when their stdout is not part of the outer capture contract, and (b) TSV stdout protocol with awk-split for multi-value returns from `$()`-captured functions.

**10. `jq --argjson` requires valid JSON, not jq's bare-key syntax** (T5.05 lesson).

jq's object-construction syntax allows bare keys (`{from:"x"}` is valid jq). But `--argjson` is a JSON parser, not a jq parser — bare keys are rejected. Build edges + nested objects via TSV stdin → `jq -Rsc 'split("\n") | ...'` with QUOTED keys for `--argjson` consumption.

```bash
# WRONG — jq bare-key syntax fails --argjson parse:
local edges_jq_lines=""
for k in ...; do
  edges_jq_lines+="{from:\"$from_sid\", type:\"waits_for\", to:\"$f\"},"
done
jq -nc --argjson edges "[${edges_jq_lines%,}]" '...'
# → jq: invalid JSON text passed to --argjson
```

RIGHT — TSV stdin → jq map construction with quoted JSON keys:

```bash
local edges_tsv=""
for k in ...; do
  edges_tsv+=$'\n'"${from_sid}"$'\t'"waits_for"$'\t'"$f"
done
local edges_json
edges_json=$(printf '%s\n' "${edges_tsv#$'\n'}" | jq -Rsc '
  [ split("\n")[] | select(length > 0) | split("\t")
    | {from: .[0], type: .[1], to: .[2]} ]
')
jq -nc --argjson edges "$edges_json" '...'
```

Surfaced in T5.05 `cycle_detection.sh` edges builder. Caught at bats setup phase. The TSV intermediate also forces explicit field-position discipline (`split("\t")[0/1/2]`), reducing risk of misordered concatenation.

**Lesson #4 reinforcement (T5.05 case study).** `head -n -1` is a GNU extension; macOS BSD `head` rejects negative line counts (`illegal line count -- -1`). Initial `cycle_path` session-array dedup used `head -n -1` to drop the closing duplicate of `start_sid`. Fix: use `jq unique` instead of `head -n -1` for natural deduplication. Pattern: prefer pure-jq pipelines over CLI-tool composition where deduplication / sorting is needed; jq is portable and feature-complete for these operations.

**11. Bash 3.2 multi-assign `local` RHS-eval-before-assign with set -u** (T6.04 lesson, F-018 portability family).

Bash 3.2 evaluates all RHS expressions in a multi-assign `local` statement BEFORE binding any of the variables. With `set -u` inherited from sourced libs (atomic_write.sh / log_event.sh), referencing an earlier assign's left-hand variable inside a later RHS triggers unbound-variable error.

```bash
# WRONG — bash 3.2 + set -u: $f and $opener unbound when tid evaluates:
_add_task() {
  local f="$1" opener="$2" tid="${3:-tid-$f-$opener}"
}
```

RIGHT — split into separate `local` lines per assignment:

```bash
_add_task() {
  local f="$1"
  local opener="$2"
  local tid="${3:-tid-$f-$opener}"
}
```

Surfaced in T6.04 self_tasks.bats `_add_task` helper. Caught at first run; helper rewrite + 18 tests PASS post-fix. The same rule applies anywhere multi-assign `local` is used in code that may run under set -u inheritance.

**12. `coord_log_event` reserved-key collision in payload args** (T6.02 lesson).

`coord_log_event` reserves four key names for top-level event metadata: `kind`, `tool`, `file`, `hash`. Payload extras passed as additional `key=value` args MUST use distinct names. Reusing a reserved key as a payload arg silently overwrites the top-level slot — the event ends up with an unexpected `kind`, breaking downstream consumers / grep gates / invariant tests.

```bash
# WRONG — payload `kind=cycle` overwrites top-level
# kind=TASK_GRAPH_VIOLATION_DETECTED; event surfaces in
# events.jsonl with kind=cycle (no longer matches kind grep gate):
coord_log_event kind=TASK_GRAPH_VIOLATION_DETECTED \
  session="$start_sid" target="$target_file" \
  kind=cycle path="$rendered" duration_ms="$elapsed_ms"
```

RIGHT — payload key uses non-reserved name (`violation`):

```bash
coord_log_event kind=TASK_GRAPH_VIOLATION_DETECTED \
  session="$start_sid" target="$target_file" \
  violation=cycle path="$rendered" duration_ms="$elapsed_ms"
```

Surfaced in T6.02 `coord_cycle_detect_task_graph` event emission. Reserved set: `kind`, `tool`, `file`, `hash`.

**13. `var=$(cmd) || alt` inside `$()` concatenates stdout** (T6.03 lesson).

The `var=$(grep -F -c X file 2>/dev/null || printf '0')` form does NOT replace stdout on failure. The `||` runs INSIDE the command substitution: when grep prints "0\n" with rc=1 (no match found), the `||` triggers `printf '0'` which APPENDS another "0" to the same subshell stdout. Captured value becomes "0\n0" — non-numeric, fails `[ -gt 1 ]` integer comparison, silently bypasses guards.

```bash
# WRONG — match_count="0\n0" on no-match (grep prints "0",
# `|| printf '0'` appends another "0"):
match_count=$(grep -F -c -- "$anchor" "$file" 2>/dev/null || printf '0')
```

RIGHT — `if var=$(cmd); then ... else ... fi` (lesson #5 pattern) + post-capture numeric sanitize via `case` glob:

```bash
if match_count=$(grep -F -c -- "$anchor" "$file" 2>/dev/null); then
  : # rc 0: grep found ≥1 match
else
  : # rc 1/2: var captured stdout already; sanitize below
fi
case "$match_count" in
  ''|*[!0-9]*) match_count=0 ;;
esac
```

Surfaced in T6.03 `cmd_task_open` anchor uniqueness check.

**14. jq `// alt` triggers on FALSE in addition to null** (T6.03 lesson).

jq's `//` operator is the "alternative operator" — by spec it returns the right-hand value when the left-hand is null OR false. When reading a boolean config field where you want to distinguish absent-key from present-and-false, `// true` silently bypasses the present-and-false case.

```bash
# WRONG — task_delegation: false in config.json reads as true via
# // alt (jq spec: false triggers alternative):
toggle=$(jq -r '.task_delegation // true' config.json)
```

RIGHT — explicit `if has(...) then ... else <default> end` to distinguish absent-key from present-and-false:

```bash
toggle=$(jq -r 'if has("task_delegation") then .task_delegation else true end' config.json)
```

Surfaced in T6.03 cmd_task_open + T6.09 build_deny_reason toggle handling. Same fix applied at both sites.

**15. ms-precision idempotency window flake at second-truncation boundaries** (T6.04 lesson).

When implementing time-windowed idempotency / dedup logic with `Time::HiRes` ms-precision new timestamps compared against `fromdateiso8601 * 1000` truncated existing timestamps (jq lacks native ms parsing on fractional ISO8601), the comparison can flake at .999 / .001 boundaries. Existing entry stored at `2026-04-27T13:10:15.999Z` truncates to second `2026-04-27T13:10:15Z` × 1000 = ...15000 ms. New ms-call at ...16001 ms. Difference = 1001 ms; if window is `<= 1000`, it fails. The two calls were ~2ms apart in wall-clock.

Mitigation options (not fixed in T6.04 — flake observed 1/~10 runs and stable in normal use; documented for future reference): (a) widen window to ≥ 2000 ms; (b) store created_at_ms as a separate numeric field alongside ISO created_at and compare directly; (c) use jq's `gsub("\\.\\d+Z$";"Z") | fromdateiso8601 * 1000 + (extracted ms part)` to recover full precision.

Surfaced in T6.04 self_tasks.bats test 2 idempotency 1/~10 flake. Three consecutive 15/15 reruns confirmed stability in practice. Future mitigation if flake observed under production load.

**16. jq context-rebind in `$x | filter` pipelines** (T6.04 lesson).

When piping `$variable_object | filter` inside a `select` or `map`, the pipe rebinds `.` to `$variable_object` inside `filter`. References to outer scope's `.field` become `$variable_object.field` — not the surrounding task's field. Save the outer object as `$t` BEFORE the pipeline to access outer scope.

```jq
# WRONG — `.file` inside `has(.file)` reads $lk.file
# (always absent), not the outer task's file:
.self_tasks[$s] // []
| map(select(
    ($lk | has(.file) | not)
    or ($lk[.file].session == $s)
  ))
```

RIGHT — save outer task as `$t`:

```jq
.self_tasks[$s] // []
| map(. as $t | select(
    ($lk | has($t.file) | not)
    or ($lk[$t.file].session == $s)
  ))
```

Surfaced in T6.04 `coord_self_task_check_unlocked`. Also applies to `as $key | filter` patterns where outer scope access is needed.

**17. bats integration tests for hook invocation MUST use `bash -c` subshell wrapper** (T6.05 lesson).

Direct pipe `printf '%s' "$input" | "$hook"` from inside a bats `@test` body loses backgrounded log_event subshells when the @test body's outer pipe context exits. The hook spawns `coord_log_event &` with `disown`, but bats's pipe lifetime ends before the disowned subshell can flush events.jsonl writes. Result: events.jsonl appears empty after the hook runs; downstream assertions fail.

```bash
# WRONG — direct pipe; backgrounded log_event lost:
_run_hook() {
  CLAUDE_COORD=1 printf '%s' "$1" | "$HOOK"
}
```

RIGHT — wrap with `bash -c "..."` subshell so backgrounded subshells inherit the wrapper's lifetime:

```bash
_run_hook() {
  CLAUDE_COORD=1 bash -c "printf '%s' '$1' | '$HOOK'"
}
```

Surfaced in T6.05 `post_tool_use_write_task_processor.bats`. Mirrored at T6.06 + T6.07 + T6.09 helpers.

**18. bats inline `bash -c` env-prefix scoping** (T6.09 lesson).

When a single-line bats command sets env-prefix INSIDE the quoted bash -c command:

```bash
# WRONG — CLAUDE_COORD=1 only scopes to printf, NOT
# the piped hook (env-prefix is per-command, not
# per-pipeline):
run bash -c "CLAUDE_COORD=1 printf '%s' '$INPUT' | '$HOOK'"
```

The hook receives no CLAUDE_COORD=1 → exits 0 silently without producing additionalContext.

RIGHT — env-prefix on the OUTER `bash -c` invocation so the inner pipeline inherits via process env:

```bash
run env CLAUDE_COORD=1 bash -c "printf '%s' '$INPUT' | '$HOOK'"
```

Surfaced in T6.09 phase6_e2e.bats S6/S8/S9/S10. Helper-defined invocations (`_pre_acquire`, etc.) already used the correct outer-prefix pattern; only inline `bash -c` calls regressed.

**19. Fixture timeline.sh inherits set -e + pipefail from init.sh; `var=$(failing_cmd)` aborts silently** (T6.10 lesson).

Fixture timeline.sh files run inside a shell sourced from init.sh which has `set -euo pipefail` at top. Under inherited set -e, `var=$(failing_cmd)` triggers script abort immediately — without ever reaching the `var_RC=$?` capture or downstream assertion logic. The driver loop sees the timeline source completing "successfully" (because the abort happens INSIDE the sourced timeline subshell which exits 0 from the abort), but scenario_assert is undefined, so the driver reports an error or hangs.

```bash
# WRONG — set -e inherited from init.sh aborts when cmd
# returns non-zero:
TASK_OPEN_OUT=$(coord_fixture_p6_task_open ... 2>&1)
TASK_OPEN_RC=$?     # never reached when cmd fails
```

RIGHT — wrap with `set +e ... set -e` block when capturing expected-non-zero rc:

```bash
set +e
TASK_OPEN_OUT=$(coord_fixture_p6_task_open ... 2>&1)
TASK_OPEN_RC=$?
set -e
```

Alternative: append `|| true` to the assignment line (Phase 5 fixture style). The `set +e/-e` block is preferred when followed by `RC=$?` capture for clarity.

Surfaced in T6.10 phase6_ship_gate scenarios 02/03/05. Phase 5 fixtures used the `|| true` pattern; Phase 6 chose the explicit set +e/-e block.

**20. PR APPROVED status authoritative for downstream task specs; sign-off task spec messages must reference PR-X §implementation surface verbatim** (T7.04 F-011 surface + T7.09 echo).

User T7.04 GO message paraphrased PR-PHASE7-03 §"Implementation surface" with imprecise naming (`coord_cost_guard_check_mediator <sid>` vs PR's `coord_cost_guards_check <site>`) AND a different concurrency model (split check + record_invocation vs PR's atomic check+append-on-allow). T7.09 repeated at smaller scope (`BATS_RUN_REALISTIC` env-var vs PR's `COORD_TEST_MODE=realistic` gate).

```bash
# WRONG — implementer pattern-matches user paraphrase:
coord_cost_guard_check_mediator() { ... }
coord_cost_guard_record_invocation() { ... }
# Result: 3-site spawn refactor at T7.03 (commit c188b9a)
# calls coord_cost_guards_check (PR-API-compliant); T7.04
# implementation diverges; cost-guard SLOTs never fire;
# F-011 surface required to surface ambiguity at T7.04 GO.

# RIGHT — implementer surfaces ambiguity via F-011, user
# CONFIRMS Option A (PR verbatim), implementation proceeds
# against APPROVED PR contract:
coord_cost_guards_check() { ... }
coord_cost_guards_status() { ... }
coord_cost_guards_clear() { ... }
```

Surfaced at T7.04 GO and again at T7.09 GO (env-var divergence echo). User-CONFIRMED disposition: PR APPROVED status binding for downstream tasks. Phase 4-5-6 precedent treats PR APPROVED status this way; T7.04 F-011 surface formalizes the rule.

**21. Phase-close evidence bar tradeoff — target vs achievable budget; document v1 vs Phase N+1 follow-up candidates** (T7.06a 1000-iter target → 100-iter achievable).

OQ1 binding referenced 1000-iteration parallel-bats target as F-016 fix evidence bar. T7.06a achieved 100-iter at 100/100 PASS within budget; 1000-iter would have pushed wall-clock budget by ~9× without material confidence improvement (P(single-iter fail) bound ~0.46% upper confidence at 100/100 → already ≪ 1%). 100-iter accepted as v1 evidence bar with concrete root cause + targeted fix already shipped.

```bash
# WRONG — implementer treats target as binary pass/fail
# evidence bar; misses budget reality:
# 1000-iter run = 80 minutes wall-clock, 8000% over the
# OQ task budget. Implementer skips the run entirely OR
# exceeds budget without surfacing.

# RIGHT — implementer evaluates target vs budget,
# achieves 100-iter at 100/100, documents:
#   - achieved evidence bar
#   - statistical bound on remaining risk
#   - Phase N+1 follow-up candidate if audit-log gap
#     concerns surface in production
# User accepts at v1 close.
```

Surfaced at T7.06a close. User-ACCEPTED disposition: 100-iter is v1-acceptable evidence bar; 1000-iter as Phase 7+1 follow-up candidate documented in phase-7-signoff.md.

**22. bats test environment SIGINT/SIGTERM semantics differ from production; test SIGTERM path through cleanup_interrupt handler bound to BOTH signals** (T7.06a).

bats with job control off (`set -m off`, default) causes async background commands to inherit `SIG_IGN` for SIGINT per bash(1) "asynchronous commands ignore SIGINT and SIGQUIT". Tests sending `kill -INT $bg_pid` silently no-op — kernel never delivers SIGINT to the bg process.

```bash
# WRONG — test under bats:
coord wait $TARGET --timeout 60 &
pid=$!
sleep 0.5
kill -INT $pid    # Silently no-op under bats
wait $pid         # Blocks until 60s timeout

# RIGHT — test under bats:
coord wait $TARGET --timeout 60 &
pid=$!
sleep 0.5
kill -TERM $pid   # SIGTERM delivers normally
wait $pid || rc=$?
# cleanup_interrupt bound to BOTH INT and TERM, so SIGTERM
# fires the SAME handler. Production users hitting Ctrl-C
# use the SIGINT path; test exercises the equivalent
# SIGTERM path through the SAME cleanup code.

# PRODUCTION traps must bind both signals to identical
# cleanup logic so test-via-SIGTERM is equivalent to
# user-via-SIGINT:
trap cleanup_interrupt INT TERM
```

Surfaced at T7.06a — real Unix semantics quirk. DEFERRED disposition would have left this obscured indefinitely; audit-first approach (Option α) surfaced the architectural reality. Cleanup helper must be signal-agnostic (same code path for INT + TERM).

**23. bats setup() that unset's an env-var defeats per-process opt-in patterns; preserve operator's marker in setup, mutate per-test via subshell** (T7.09).

setup() runs before each test body. If setup() does `unset COORD_TEST_MODE`, the operator's process-level opt-in marker is clobbered before the test's skip-gate sees it. Symptom: opt-in invocation (`COORD_TEST_MODE=realistic bats ...`) still skips realistic-tagged tests, BUT the default-skip meta-test passes (because in default no-opt-in mode, COORD_TEST_MODE really IS unset — the unset is cosmetic and matches reality). The bug is INVISIBLE under default-CI verification — only surfaces when an operator actively tries to opt in.

```bash
# WRONG — setup unset clobbers opt-in marker:
setup() {
  TMP="$(mktemp -d -t coord-XXXX)"
  export COORD_DIR="$TMP/.coord"
  unset COORD_TEST_MODE || true   # BUG
}

@test "realistic stub" {
  [ "${COORD_TEST_MODE:-}" = "realistic" ] || skip
  # Always skips even when operator opted in.
}

# RIGHT — preserve operator's marker; mutate per-test
# via subshell:
setup() {
  TMP="$(mktemp -d -t coord-XXXX)"
  export COORD_DIR="$TMP/.coord"
  # Do NOT unset COORD_TEST_MODE — it's the operator's
  # opt-in marker.
}

@test "default mode behavior" {
  # Per-test cases that need a clean env use inline
  # `env <var>=<val>` or sub-shell `bash -c`:
  run env COORD_TEST_MODE=mock bash -c '...'
}
```

Surfaced at T7.09 close. Real test-design bug that would have made the realistic-tag opt-in mechanism INOPERABLE despite passing the default-skip meta-test. Caught only by explicit opt-in path verification. **Verification rule corollary:** opt-in mechanisms require EXPLICIT opt-in path verification, not just default-skip meta-test.

**24. lib CLI shims that delegate to functions depending on `coord_log_event` must source `log_event.sh` defensively; standalone CLI invocation otherwise silently skips audit emission** (T7.11).

`lib/cost_guards.sh` CLI shim invokes `coord_cost_guards_check` which calls `coord_log_event` only when `command -v coord_log_event` resolves. Bats unit tests source log_event.sh + cost_guards.sh together so the check resolves; standalone CLI invocation (`bash $LIB_DIR/cost_guards.sh check mediator`) doesn't source log_event.sh — `command -v coord_log_event` returns non-zero — audit emission silently skipped. rc behavior is correct (rc=0/rc=1 from cost-guard semantics) but events.jsonl is empty — fixtures and stress scripts that verify audit events fail without an obvious root cause.

```bash
# WRONG — fixture invokes via CLI shim, expects audit events:
scenario_run() {
  bash "$LIB_DIR/cost_guards.sh" check mediator || RC=$?
  # ... assertion on COST_GUARD_RATE_LIMITED event ...
}
# Symptom: rc behavior correct; events.jsonl empty;
# assertion fails with "event not found" but cost-guard
# semantics work.

# RIGHT — fixture invokes via direct sourced subshell so
# log_event.sh is sourced before cost_guards.sh:
_check_in_subshell() {
  bash -c '
    source "$LIB_DIR/log_event.sh"
    source "$LIB_DIR/cost_guards.sh"
    if coord_cost_guards_check "$1"; then exit 0; else exit 1; fi
  ' bash "$1"
}

# ARCHITECTURAL ALTERNATIVE (post-v1): update cost_guards.sh
# CLI shim to source log_event.sh defensively at top of the
# script (mirror of what the bats tests do explicitly).
# Phase 7+1 candidate; cleaner but touches T7.04 commit
# territory.
```

Surfaced at T7.11 close. Same architectural pattern likely affects T7.08 stress scripts (audit-event evidence check is opportunistic — `[ -s events.jsonl ]` short-circuits silently). Documented in phase-7-signoff.md as Phase 7+1 enhancement candidate (CLI shim defensive sourcing).

**25. Test infrastructure relocations must include forward-compat invocation blocks for new phases in the SAME commit as the relocation, not as follow-up** (T7.07 + T7.12).

T7.07 relocated `linux_probe.sh` from `.coord/experiments/linux-parity/` (gitignored) to `src/tests/manual/` (committed) — content preserved verbatim. The original probe driver predated Phase 7, so it didn't include a `phase7_ship_gate.sh` invocation block. T7.12 Linux Docker re-probe surfaced the gap: 19/19 ship-gate fixtures verified instead of the 24/24 cumulative target. Working-tree fix added the invocation block; T7.13 sign-off bundle absorbed the addition. The verbatim-relocation discipline traded coverage gap for content-preservation simplicity — wrong tradeoff.

```bash
# WRONG — relocation preserves verbatim, leaves new-phase
# invocation as follow-up:
# T7.07 commit:
#   cp .coord/.../linux_probe.sh src/tests/manual/
#   # Content unchanged — phase3-6 invocations preserved.
# T7.12 verification surfaces the gap.

# RIGHT — relocation includes forward-compat additions in
# the SAME commit:
# T7.07 commit:
#   cp .coord/.../linux_probe.sh src/tests/manual/
#   # ADD phaseN invocation for the current phase under
#   # construction (Phase 7 at T7.07 time); even if the
#   # new fixtures don't exist YET, the placeholder
#   # invocation makes the gap visible at relocation time
#   # not at sign-off time.

# Or pre-condition: add the new phase's ship-gate driver +
# invocation block in linux_probe.sh BEFORE the relocation
# task. Then relocation IS verbatim and complete.
```

Surfaced at T7.12 (Cand-25 origin — initially logged as Phase 7+1 follow-up but folded into §A.13 batch at T7.13 sign-off per Phase 6 close precedent for organic gap-fix lessons). Future relocations of test infrastructure (linux_probe.sh, phase-N ship-gate drivers, fixture init scripts) MUST audit forward-compat checklist BEFORE the relocation commit, not after.

These rules apply to any future hook / pipeline / spawn-helper / fixture / spawn-routing / cost-guard construction. The Phase 7 implementations of `lib/spawn_helper.sh` (T7.02), `lib/cost_guards.sh` (T7.04), 3-site spawn refactor (T7.03), cost-guard interlock + pipeline graceful degrade (T7.05), F-016 SIGINT path fix via `coord_log_event_sync` + watcher PID cleanup (T7.06a), F-019 `linux_probe.sh` relocation (T7.07), manual stress scripts (T7.08), bats integration mode handling (T7.09), `phase7_invariant.bats` 19 guards (T7.10), and `phase7_ship_gate` fixtures (T7.11) are the canonical references for lessons #20-#25. Phase 6 references (T6.04/T6.05/T6.10) remain canonical for lessons #11-#19. Phase 5 references (T5.02/T5.03/T5.04/T5.05/T5.09) remain canonical for lessons #7-#10. Phases 3-4 references remain canonical for lessons #1-#6. The system is v1-production-ready at single-developer scale post-Phase 7 close; multi-machine team scenarios are out of scope per OQ6 (next major version candidate).

---

## Part B — Runtime Rules for Coordinated Sessions

> **Framing (read before the rules).** These rules describe the behavior of sessions running under the coordination system. **Wherever possible, hooks enforce these rules deterministically.** Every rule below is tagged `[HOOK-ENFORCED]` (the hook makes the rule true regardless of what Claude tries to do) or `[BEST-EFFORT]` (the rule depends on Claude-the-model cooperating; the hook cannot make it true on its own). Treat `[BEST-EFFORT]` rules as probabilistic — the system is designed so that no safety-critical behavior depends solely on them.

### B.0 You will know you are in a coordinated session because

At SessionStart, if `CLAUDE_COORD=1` was set in the environment that launched you, the `session_start.sh` hook injects an `additionalContext` line stating:

> **Coord v1.0 active.** Your coordination session ID is `<uuid>`. There are currently `<N>` other coordinated sessions in this repository. See `coord status` for live state.

If this banner is absent, you are not in a coordinated session and none of the rules below apply.

### B.0a Install-time permission policy (operator note)

The installer (`src/install.sh`) by default touches ONLY the `.hooks` subtree of `.claude/settings.local.json`; user-authored `.permissions` (allow/deny lists, modes) is preserved verbatim. An operator may opt in to `bash src/install.sh --bypass-permissions` (forwardable through `npx parallel-sessions init --bypass-permissions`), which additionally sets `.permissions.defaultMode = "bypassPermissions"` — auto-approving every Claude Code tool-permission prompt in this repo. The flag is **OPT-IN ONLY**, idempotent (re-asserts on re-run with the flag; never silently demotes a previously-set mode when the flag is omitted), and ignored under `--uninstall` (operator reverts manually). Coord hook contract is independent of permission mode: hooks fire under `default`, `acceptEdits`, `plan`, and `bypassPermissions` identically. Whether the operator chose bypass affects what the human user sees (fewer prompts), not what the coord layer enforces — the 2-location deny invariant (lock-held + lockdown gate) is still authoritative.

### B.1 Before reading any file

**Rule:** Read the file directly; the `PreToolUse(Read)` hook handles the coordination work (hash recording, notification delivery). You do not need to consult `sessions.json` yourself.

**Enforcement:** `[HOOK-ENFORCED]` — the `pre_tool_use_read.sh` hook:
1. Computes `sha256` of the target file via `lib/hash.sh`.
2. Emits `hookSpecificOutput.additionalContext` with any relevant notifications addressed to your session about this file (e.g., "File modified by session X since your last read").
3. Under `flock sessions.lock`, appends an entry to `read_sets[<your_session_id>].reads[]`, supersedes any prior entry for the same file (`is_latest: false, superseded_by: <new_hash>`).
4. Logs event `READ`.
5. Exits 0 (allow).

**What you do:** If `additionalContext` contained a notification, internalize it. If the notification says "File modified by X since your last read," consider whether your current plan is still valid.

### B.2 Before writing any file (branching tree)

**Rule:** Attempt the Write/Edit. The `PreToolUse(Write|Edit|NotebookEdit)` hook evaluates lock state and read-set freshness and either allows, denies, or flags for Mediator.

**Enforcement:** `[HOOK-ENFORCED]` throughout. The `pre_tool_use_write.sh` hook under `flock sessions.lock`:

1. **No lock on the target file:**
   - Validate your `read_sets[<self>].reads[]` for any file where `is_latest: true` and `superseded_by_head_change: false`: compute current `sha256`, compare to stored hash.
     - **All match** → acquire lock (`locks[target] = {session:self, acquired_at, last_refresh_at, tasks:[]}`), update `sessions[self].last_activity_at`, exit 0 (allow).
     - **Some mismatch (Phase 4 / T4.06 pipeline)** → for each drifted file, run the 3-stage validator pipeline (cache lookup → pre-filter → validator agent spawn). Per-file disposition:
       - **SAFE** (silent): no banner contribution; pipeline writes a SAFE entry to `.coord/validator/cache.json` (1h TTL) so subsequent identical drifts are recognized cheaply.
       - **MINOR**: banner line appended ("Drift on `<file>`: `<diff_summary>`. Validator classified as MINOR. Proceeding."); cache write MINOR with diff_summary.
       - **CRITICAL**: write `kind=critical_drift` pending entry to `pending.jsonl`; spawn Mediator INLINE (synchronous; ~20–35 s); apply Mediator verdict's `actions[]` via `verdict_apply.sh` (release_lock / evict_session / clear_read_set); advance per-session `last_consumed_verdict` pointer; banner line composed from Mediator's `action_type` + `message_to_caller`. CRITICAL is NEVER cached.
       - **Pipeline failure** (cache error, validator spawn fail, Mediator spawn fail): per-file Phase 1 fallback line ("Drift on `<file>` (modified since read; pipeline failed). Pipeline unavailable; consider re-reading before proceeding.") — fail-open per CLAUDE.md §A.5.
   - The hook then continues to lock acquisition. **Phase 4 invariant: validator pipeline emits NO `permissionDecision: deny`.** CRITICAL → Mediator → lockdown (when scope is system-wide) routes through the existing Phase 3 lockdown gate. The two-location deny invariant (lock-held + lockdown active) is preserved through Phases 4+5+6.

2. **Lock held by another session:**
   - Exit with `permissionDecision: "deny"` and a `permissionDecisionReason` like:
     > File `foo.ts` is locked by session `<holder_id>` since `<ts>` (~<mins> min). Options:
     > (a) Delegate a SIMPLE/MODERATE task: `Bash: coord task-open --file foo.ts --complexity SIMPLE --anchor '{"search":"...","window_lines":"..."}' --instruction '...' [--rationale '...']`.
     > (b) Self-delegate (do other work, return later): `Bash: coord self-delegate --file foo.ts --instruction '...'`.
     > (c) Passively wait: `Bash: coord wait foo.ts --timeout 570` (blocks your Bash call until unlocked or timeout; 570 s is the max — it sits just below Claude Code's 600 s Bash-tool ceiling).
     > Pick (a) for small, self-contained edits; (b) if you have other productive work; (c) only if the change is too complex to delegate AND you have no other work.

3. **Lock held by yourself:**
   - Refresh `last_refresh_at`; exit 0 (allow).

**What you do:** On deny, read the reason, pick an option, issue the appropriate Bash command. On allow, proceed with the Write/Edit.

### B.3 Before taking final action (stale-read validation)

**Rule:** There is no separate "before final action" hook. Stale-read validation runs at every write via the Phase 4 pipeline (B.2). If you intend to produce a final answer that does not involve a write but is nonetheless consequential (e.g., a report whose content implies file contents unchanged), you may invoke `coord validate-reads` explicitly (Phase 7+).

**Enforcement:** `[HOOK-ENFORCED]` on writes (see B.2). `[BEST-EFFORT]` on non-write final answers — the hook cannot intercept a plain text response.

### B.3a Validator pipeline operational details (Phase 4 / T4.06)

The 3-stage pipeline at `pre_tool_use_write.sh` is `[HOOK-ENFORCED]` end-to-end. You do not invoke it; it runs automatically when stale-read drift is detected. Operational details for context:

- **Stage 1 — Cache** (`lib/validator_cache.sh`): keyed by `(file, read_hash, current_hash)` triple. TTL: 1 hour for SAFE/MINOR. **CRITICAL is never cached** (every CRITICAL drift must trigger fresh Mediator escalation per PR-PHASE4-04). Opportunistic GC drops expired entries on each write.
- **Stage 2 — Pre-filter** (`lib/validator_prefilter.sh`): pure-bash deterministic classifier. SAFE on `whitespace_only` / `blank_only` / `comment_only` (the last requires no `"""` / `'''` / triple-backtick markers anywhere in the file — conservative doctrine prevents false-SAFE on lines that may be inside a multi-line string). Files >1 MB or pre-filter timeout >5 s → ESCALATE_TO_AGENT. Doctrine: false-positive ESCALATE on trivial drift is acceptable; false-negative SAFE on real drift is dangerous.
- **Stage 3 — Validator agent spawn** (`lib/validator_spawn.sh`): `claude -p` subprocess in subscription mode (no `--bare`), with `CLAUDE_COORD=0` + `CLAUDE_CODE_VALIDATOR=1` env. Recursion guard refuses spawn from within a Validator context (depth-1 only — Phase 4 does not exercise peer review; Mediator's depth-2 escalation handles disagreement resolution). Tool restrictions: `--allowedTools "Bash" "Read"` + `--disallowedTools "Write" "Edit" "NotebookEdit" "Task"`. Validator returns SAFE/MINOR/CRITICAL via verdict file at `.coord/validator/verdict/<ts>.json`.
- **CRITICAL synchronous pathway** (PR-PHASE4-02 + Concern B disposition): when Validator emits CRITICAL, the hook synchronously invokes the Mediator inline; total wall-clock ~60–100 s worst case (validator ~30–60 s + Mediator ~20–35 s). The Bash-tool 600 s ceiling and CLAUDE.md §A.6's 2-second hook-latency target are intentionally exceeded for CRITICAL drift events (~5–10% of stale-read attempts). Justification: a CRITICAL verdict means intervention is needed before the Write proceeds; letting it land defeats the validator's purpose.
- **Read-snapshot store** (`lib/read_snapshots.sh` / PR-PHASE4-05): `pre_tool_use_read.sh` captures file content at Read time to `.coord/read_snapshots/<sid>/<hash>.txt`. Validator pipeline consumes this content for diff computation + agent prompt context. Files >10 MB (existing `SKIPPED_LARGE` cap) skip snapshot; pre-filter ESCALATEs unconditionally. Snapshots GCed on supersede / session_end / Mediator `evict_session`.
- **Reference doc**: `.coord/validator/VALIDATOR_REFERENCE.md` (~545 lines) is the canonical technical reference for the spawned Validator. It documents the verdict JSON schema, classification heuristics with worked examples, diff-summary conventions (no apostrophes per F-014), hand-off to Mediator (critical_drift pending entry payload), tool restrictions, and recursion guard rationale.

**What you do:** nothing different. The pipeline runs transparently. If you see a banner like "Drift on `<file>`: ... MINOR. Proceeding." → consider whether the change affects your plan. If you see "Critical drift on `<file>` -> Mediator: ..." → the Mediator has already analyzed; act on its `message_to_caller` text. If you see "Drift on `<file>` (modified since read; pipeline failed). Pipeline unavailable; consider re-reading before proceeding." → the validator infrastructure is degraded; treat as Phase 1 warning and re-read before the operation if the change matters.

### B.4 Before releasing a lock (task processing + wait-queue notification)

**Rule:** You do not manually release locks. The `PostToolUse(Write|Edit)` hook does it.

**Enforcement:** `[HOOK-ENFORCED]`. The `post_tool_use_write.sh` hook under `flock sessions.lock`:
1. For each entry in `locks[<file>].tasks[]` in order:
   - Inject `additionalContext` describing the task (`from`, `instruction`, `anchor`, plus `affected_lines` of any previously-applied tasks under the same lock so Claude can reason about conflicts).
   - **This is the one place `[BEST-EFFORT]` enters the lock-release flow:** Claude-the-model applies the task using `Edit`. If the task is inapplicable (anchor gone, target changed), Claude marks the outcome `CONFLICT` and moves on.
2. Record `status`, `diff`, `affected_lines`, `outcome` per task.
3. Remove `locks[<file>]`; archive to `sessions_history.json`.
4. For each `wait_queue[<file>]` entry, `touch` the `wake_file` and emit `lock_released` notification with the final diff summary.
5. Update task_graph edges, delete processed ones.
6. Log `LOCK_RELEASE` + per-task `TASK_OUTCOME` events.

### B.5 Before finishing a prompt (cleanup, unresolved tasks)

**Rule:** On `Stop`, the hook checks for unresolved self-tasks. If any, the first `Stop` returns `decision: "block"` with a reminder; the second `Stop` allows exit.

**Enforcement:** `[HOOK-ENFORCED]` for the block-once-then-allow mechanics. `[BEST-EFFORT]` for whether you act on the reminder.

**What you do on reminder:** If your self-task's file is now unlocked and you can sensibly apply the deferred work, do so. If not, the next `Stop` allows exit and the self-task is archived as `SKIPPED`.

### B.6 On encountering anomalies (Mediator invocation protocol)

**Rule:** You do not invoke the Mediator directly in the common case. Command hooks detect anomalies (corrupt state, flock timeout, PID/lstart consensus, schema mismatch, fork-bomb suspicion) and write `.coord/mediator/pending.json`. The next `PreToolUse` triggers the `mediator_agent.md` agent-hook, which reads the flag, analyzes, remediates, and injects a verdict summary as `additionalContext`.

**Enforcement:** `[HOOK-ENFORCED]` via flag file + agent hook.

**Manual invocation (rare):** If you suspect a coordination problem not flagged automatically, `Bash: coord mediate` writes a manual pending flag with `kind:"manual"` and your supplied context. The next tool call fires the Mediator.

**When Mediator cannot decide:** It writes `kind:"escalate_to_user"` in its verdict and emits `additionalContext` asking you to surface the situation to the user in your response.

**Watchdog signal model (Phase 3 / PR-PHASE3-02 §A clarification).** When ambient suspicion fires a watchdog probe of another session, the watchdog combines three signals to produce one of three verdicts:

- **Signal 1 (deterministic — PID liveness):** `ps -p <pid> -o lstart=` is empty → dead/pid_gone. lstart mismatch → dead/pid_recycled. Match → continue to Signal 2/3.
- **Signal 2 (timing — last_activity_at):** older than `watchdog_suspicion_last_activity_seconds` (default 600s) → suspicious. Does NOT promote to dead by itself.
- **Signal 3 (lock-context):** any lock with `last_refresh_at == acquired_at` AND age > `watchdog_suspicion_lock_unrefreshed_seconds` (default 1800s) → suspicious. Does NOT promote to dead by itself.

**Verdict computation:**
- `dead` REQUIRES Signal 1 confirmation. Subkind (pid_gone / pid_recycled) drives Mediator pending kind (stale_active / pid_recycled).
- `alive` REQUIRES Signal 1 confirms-alive AND no Signal 2 / 3 fires. No pending entry emitted.
- `uncertain` when Signal 1 confirms alive BUT Signal 2 OR 3 fires (suspicion without deterministic dead confirmation). Emits stale_active pending with `payload.uncertain=true`; Mediator decides escalation.

The watchdog NEVER returns `alive` solely on activity/lock signals — Signal 1 is mandatory for the alive verdict. This is the false-negative protection: a session whose PID is gone cannot be declared alive even if its last_activity is recent.

### B.7 On self-delegation (a session deferring its own work until a lock clears)

**Rule:** When you choose option (b) from the lock-denied prompt (§B.2), issue:
> `Bash: coord self-delegate --file <path> --instruction "<self-note>"`

**Enforcement:** `[HOOK-ENFORCED]` for the record keeping, injection of reminders, and block-on-Stop.

**What happens after:**
1. An entry is appended to `self_tasks[<you>][]` with status `PENDING`.
2. On every subsequent `PreToolUse` (any tool) during your turn, `pre_tool_use_any.sh` checks whether any of your self-tasks' files are now unlocked. If yes, it injects:
   > REMINDER: You deferred `<file>` earlier ("<instruction>"). It is now unlocked. Consider returning to it before finishing.
3. On `Stop`, self-tasks drive the block-once behavior (§B.5).

**Passive reliability:** `[BEST-EFFORT]` — you must notice and act on the reminder. The hook will surface it, but whether you return to the file is your decision. Archive as `SKIPPED` is the fallback.

### B.8 On passive waiting (event-driven wake-up)

**Rule:** Passive wait is the fallback when delegation and self-delegation are not appropriate (e.g., the blocked edit is complex, you have no other productive work). Issue:
> `Bash: coord wait <file> --timeout 570`

**Enforcement:** `[HOOK-ENFORCED]` for the FIFO ordering, the event-driven wake (lock-release writes diff_summary to your wake_file; `coord wait` exits with that text on stdout), and the timeout.

**Phase 5 / PR-PHASE5-02 wake-up backend (T5.03):**
1. `coord wait <path>` enqueues your session into `wait_queues[<path>]` (FIFO; per-file flock); the CLI captures the per-(session, file) wake_file path.
2. The wake_file is watched via the platform-appropriate backend, auto-detected at install time and recorded in `.coord/config.json::wait_backend`:
   - **macOS:** `fswatch` (preferred); polling fallback if absent.
   - **Linux:** `inotifywait` (preferred); `fswatch` second; polling fallback if neither installed.
   - **Other Unix:** 250 ms wake_file mtime polling.
3. On lock release, the holder's hook (`post_tool_use_write.sh` / `stop.sh` via `lib/notify_waiters.sh`) writes a one-line diff_summary into your wake_file. The watcher fires; `coord wait` reads the content (with a 50 ms grace re-read for the create-vs-write race) and prints it on stdout for your `additionalContext`.
4. If the wake_file is empty on read, the fallback string is `"modified by <session_id_prefix>"` — semantically correct (you know the file changed) even when the diff_summary computation is degraded.

**SessionStart polling-mode warning:** if `wait_backend` resolves to `polling`, the SessionStart banner appends an `additionalContext` line recommending `brew install fswatch` (macOS) or `apt install inotify-tools` (Linux) for sub-100 ms wake-up latency. F-001 precedent: graceful degradation with operator guidance, never a silent regression.

**What happens on timeout:** `coord wait` exits non-zero with `WAIT_TIMEOUT(reason=deadline)`; you receive "timeout after Ns" on stdout, dequeued automatically. Next step is usually to ask the user (the coordination system has done everything it can; the problem is human-scale).

**SIGINT/SIGTERM:** dequeues your session from the wait_queue, kills any backend watcher PID, emits `WAIT_TIMEOUT(reason=interrupted)`, exits 130. Clean shutdown.

**Latency:** sub-100 ms with `fswatch` / `inotifywait`; ≤ 250 ms with the polling fallback. Phase 2's 30s/60s/120s polling cadence is fully superseded by the event-driven flow; the 250 ms cadence is preserved only in the no-tooling fallback.

**`wait_max_seconds` bound:** clamped to [30, 570] per Decision 2.20; default 570 sits below Claude Code's 600 s Bash-tool ceiling.

### B.8a Phase 5 end-to-end pipeline + cycle detection (operational guidance, T5.08)

**End-to-end flow when you `coord wait <path>`:**

1. **Enqueue.** Your session is appended to `wait_queues[<path>]` under per-file flock (`.coord/wait_queues/<sanitized_path>.lock`; sanitization: `tr / __`). An empty wake_file is touched at `.coord/wakers/<sid>-<sanitized>.wake`.
2. **Cycle-detection trigger.** If post-append queue depth ≥ 2, `coord_cycle_detect` runs a bipartite session/file DFS from your session as the start. If a cycle is found, a `cycle_detected` pending entry is written to `.coord/mediator/pending.jsonl` and the Mediator is spawned inline (synchronous, ~50-100 s worst case, mirroring Phase 4 `critical_drift` pattern).
3. **Backend dispatch.** Your `coord wait` blocks on the wake_file via the resolved backend (`fswatch` on macOS, `inotifywait` on Linux, 250 ms polling fallback otherwise — auto-detected at install). First-use emits `WAIT_BACKEND` event.
4. **Lock release on the holder side.** The holder's `post_tool_use_write.sh` (or `stop.sh` / `session_end.sh`) calls `notify_waiters.sh`, which:
   - Reads `locks[<path>].latest_validator_verdict_ts` (Phase 5 schema field; populated when the Phase 4 validator pipeline produced a fresh verdict during the holder's write turn).
   - Computes the `diff_summary` via the **4-tier priority chain**:
     - **Tier 1** (verdict-file): jq lookup of `.coord/validator/verdict/<ts>.json::.diff_summary`.
     - **Tier 2** (cache hit): `coord_validator_cache_lookup` on `(file, prev_hash, current_hash)`. SAFE → "trivial change (no semantic drift)"; MINOR → cached diff_summary text.
     - **Tier 3** (pre-filter SAFE): `coord_validator_prefilter` on the holder's read snapshot vs current file. SAFE → "trivial change (whitespace/comment)".
     - **Tier 4** (fallback): `"modified by <holder_id_prefix>"`.
   - Writes the resolved diff_summary to every queued waiter's wake_file via `printf "%s\n" "$diff_summary" > "$wake_file"`.
   - Emits one `NOTIFICATION_PRODUCED` event with `diff_summary_source=<tier>` for the audit trail.
5. **Wake-up.** Your backend fires; `coord wait` reads wake_file content (with a 50 ms grace re-read for the create-vs-write race), exits with the `diff_summary` on stdout for your `additionalContext`.

**Operator commands:**
- `coord status` shows `wait_queues: N waiter(s)` and per-file queue lengths via `coord status --reads` (extended in Phase 5 T5.02).
- `coord wait <path>` is the primary user-facing command (blocks until release or timeout; prints diff_summary on success).
- `coord mediate` and `coord mediate --resume` cover Mediator escalations including `cycle_detected` lockdown verdicts (Phase 3 carry-forward).

**When you encounter a long `coord wait`:**
- If a `polling` backend warning surfaced at SessionStart, install `fswatch` (macOS: `brew install fswatch`) or `inotify-tools` (Linux: `apt install inotify-tools`) and re-run `coord install --repair` to switch backends. The 250 ms polling fallback is correct but adds ~150-200 ms wake-up latency vs the event-driven path.
- If `coord wait` times out (`WAIT_TIMEOUT(reason=deadline)`), the lock holder is likely stuck or the cycle detector missed a silent 2-cycle (depth ≤ 1 on both queues — see §B.8a "Silent 2-cycle case" below). Surface to the user; the human-scale problem is beyond what the coordination system can resolve alone.

**When you encounter a `cycle_detected` Mediator verdict:**
- The Mediator's `message_to_caller` describes which session was evicted and why (3-tier priority: oldest activity → fewest locks → youngest session age — see `MEDIATOR_REFERENCE.md` §4.X.1).
- The evicted session loses its locks, wait_queue entries, read-set, read-snapshots, and wake_files in one atomic step. Other waiters in the cycle wake up via the standard lock-release notification path.
- A `lockdown` verdict on `cycle_detected` indicates a global deadlock (cycle spans all active sessions, OR ≥ 4 sessions, OR `recent_cycle_count` ≥ 2 within 60 s — Mediator can't surgical-fix). Operator runs `coord mediate --resume` after investigating.

**Silent 2-cycle case (architectural note from T5.05).** When session A holds `/p/foo` and waits for `/p/bar`, AND session B holds `/p/bar` and waits for `/p/foo`, each queue has depth 1 and the depth ≥ 2 trigger doesn't fire. The cycle is silent until either:
1. A third session enqueues on one of the cycle's files (depth 2 → trigger fires).
2. A cycle session re-enqueues on the other's file with another waiter already there.
3. The `wait_max_seconds` clamp expires (570 s) and Phase 7 will add follow-up cleanup detection from the timed-out session's perspective.

For Phase 5, the depth ≥ 2 trigger is sufficient for the done-when criterion. Silent-2-cycle handling is deferred to Phase 7.

### B.8b Phase 7 mode switch + cost-guard tunables (operational guidance, T7.09)

**`COORD_TEST_MODE` env-var** routes the 3 spawn sites between mock and real `claude -p` per PR-PHASE7-01 OQ4 binding. Three values:

- `mock` (default; CI + daily dev) — all 3 spawn sites use mock binaries / mock fakes. No real-Claude cost.
- `semi` (weekly stakes-coverage smoke) — Mediator + Task Processor route to real `claude -p`; Validator stays mock (high-frequency, mid-stakes; CRITICAL escalation routes through Mediator).
- `realistic` (pre-release smoke) — all 3 sites route to real `claude -p`.

Invalid values fail-closed to `mock` with a one-time stderr `WARNING` + `COORD_TEST_MODE_INVALID` audit event. Empty string is treated as unset (no warning). Mode resolved once per process and cached; the chosen mode emits one `COORD_SPAWN_MODE_RESOLVED` event per process.

**Cost-guard tunables** (PR-PHASE7-03 OQ5 binding) enforce rate limits in semi + realistic modes; mock mode bypasses entirely:

```
COORD_MEDIATOR_MIN_SECONDS_BETWEEN_INVOCATIONS=300   # 5 min default
COORD_MEDIATOR_MAX_INVOCATIONS_PER_HOUR=12           # hourly ceiling
COORD_VALIDATOR_MAX_SPAWNS_PER_HOUR=120              # validator hi-freq
```

Rate-limit hits emit dedicated `*_SPAWN_RATE_LIMITED` audit events (Mediator + Validator + Task-Processor variants). Mediator rate-limit: caller fail-open per existing Phase 3-4 contract. Validator rate-limit: pipeline degrades to MINOR with `[validator rate-limited]` banner suffix per PR-PHASE7-03 §"Hard block vs graceful degrade".

**Manual stress scripts** (PR-PHASE7-04 / T7.08): `scripts/stress_semi.sh` + `scripts/stress_realistic.sh` orchestrate ship-gate fixtures + cost-guard exercise under each mode. Operator-driven; not run in CI. Output to `scripts/stress_<mode>_out/<ISO_ts>.log` (gitignored).

**Bats realistic-tag opt-in** (PR-PHASE7-04 / T7.09): tests carrying `# bats test_tags=realistic` skip by default. To run: `COORD_TEST_MODE=realistic bats --filter-tags realistic src/tests/integration/spawn_helper_modes.bats`. CI safety preserved — without explicit opt-in, no real-Claude tests fire.

### B.9 Edge-case rules

#### B.9.1 Missing state file

**Rule:** If `sessions.json` is missing when a hook runs, the hook creates an empty initialized file under `flock` and emits `additionalContext: "Coordination state initialized (was missing)."`

**Enforcement:** `[HOOK-ENFORCED]` in `atomic_write.sh`.

#### B.9.1a Critical-conditions bypass (Phase 3 / PR-PHASE3-01 disposition)

**Rule:** Some failure modes are too degraded for Mediator analysis to be safe — Mediator's own context loading would inherit the corrupt state and produce a wrong verdict. For these, the system skips Mediator entirely and triggers lockdown directly with `reason_source=critical_bypass`. Recovery is OPERATOR-DRIVEN.

**Conditions that trigger critical bypass (Phase 3 implements the first; others are documented for Phase 4+):**
1. `sessions.json` fails jq parse 3+ consecutive times (the parse-fail counter at `.coord/mediator/critical_counters.json` resets on any successful parse).

**Enforcement:** `[HOOK-ENFORCED]` via `lib/critical_check.sh`'s `coord_critical_record_parse_failure` (called from `atomic_write.sh` parse-fail branch). When threshold reached, the helper invokes `coord_lockdown_activate` directly with `reason_source=critical_bypass` and emits a `CRITICAL_CONDITION_DETECTED` event.

**Recovery path:**
1. Operator inspects the situation (e.g., reads the most recent `sessions.json.corrupt.<ts>.json` archive).
2. Operator runs `coord mediate --resume`, which clears `lockdown.json` and archives it to `lockdown_archive/<ts>.cleared.json`.
3. Sessions resume normal operation. The atomic_write.sh parse-fail branch will have already auto-reset `sessions.json` to a clean empty template, so the next operation finds a parseable file.

**What this means for you (Claude in a coordinated session):** If you see a system-pause deny banner with `reason_source=critical_bypass`, do NOT retry the operation. The recovery requires the user. Surface the situation in your response — the user runs `coord mediate --resume` once they've confirmed the underlying fix.

The bypass is a safety mechanism: the alternative (firing Mediator on corrupt state) risks Mediator producing a confidently-wrong verdict. Pause-and-escalate is preferred to confidently-wrong.

#### B.9.2 Corrupted state file

**Rule:** If `sessions.json` fails to parse (`jq` non-zero), the current hook:
1. Moves the file to `.coord/sessions.corrupt.<ISO-ts>.json`.
2. Creates a fresh empty `sessions.json`.
3. Writes Mediator flag (`kind: "corrupt_state"`).
4. Emits `additionalContext` banner warning: "Coordination state was reset due to corruption. Mediator will diagnose; prior locks are lost. Retry your operation."
5. Fail-open: allow the current tool call to proceed.

**Enforcement:** `[HOOK-ENFORCED]`.

#### B.9.3 Hook script failure

**Rule:** If a hook script errors in an unhandled way, the Claude Code default kicks in: non-zero exit is non-blocking, tool proceeds. This is fail-open by Claude Code's contract. The `events.jsonl` records `ERROR` if the hook got that far; otherwise the failure is silent.

**Enforcement:** `[BEST-EFFORT]` — we cannot enforce recovery from a hook that itself is broken. Mitigation: `bats` tests + code review.

#### B.9.4 Missing dependencies (`jq` or `flock`)

**Rule:** The installer refuses to install without them. If somehow a session runs with them missing (e.g., `jq` uninstalled after install), every hook:
1. Detects the missing dependency at top-of-script.
2. Emits a loud `additionalContext` warning: "Coordination dependency missing: <name>. Operating uncoordinated. Install with `<cmd>` and re-register with `coord install --repair`."
3. Exits 0 without state change.

**Enforcement:** `[HOOK-ENFORCED]` for the warning; coordination itself is disabled (documented degradation).

#### B.9.5 Non-participant session

**Rule:** If `CLAUDE_COORD` is unset or `.coord/sessions/<self>.active` is absent, every coordination hook exits 0 without side effects. Your session operates as if the coordination layer were not installed.

**Enforcement:** `[HOOK-ENFORCED]` via `lib/participant.sh` check at the top of every hook.

#### B.9.6 Git HEAD changed mid-session

**Rule:** On `UserPromptSubmit` or at the start of any `PreToolUse` if git HEAD differs from the session's recorded `git_head`:
1. Mark all `read_sets[<self>].reads[].superseded_by_head_change = true`.
2. Update `sessions[<self>].git_head`.
3. Emit `additionalContext`: "Git HEAD changed since your last activity. Your read-set is invalidated; re-read any files you depend on."
4. Log `HEAD_CHANGE` event.

**Enforcement:** `[HOOK-ENFORCED]`.

#### B.9.7 Session resumed, cleared, or compacted

**Rule:** On a `SessionStart` event with `source ∈ {resume, clear, compact}`, the coordination layer preserves or selectively invalidates your read-set according to Decision 2.5's source-matrix (per PR-PHASE1-01):
- `resume`: your prior read-set is **preserved intact**. If git HEAD drifted during the gap, read-set entries are automatically marked `superseded_by_head_change: true` and the relevant files will trigger stale-read warnings when you next read or write them.
- `clear`: read-set entries are marked `superseded_by: "new_prompt"` — treated as a fresh-start boundary.
- `compact`: read-set is **preserved intact** (context compression preserves read history semantically; the stored hashes are still the truth about what the session last observed on disk).

You do **not** need to re-read files prophylactically after any of these events. The hooks will flag staleness when it actually matters (on the next write, or via `additionalContext` on HEAD drift). Prophylactic re-reads waste tokens and reset the read-set to state the coord layer has already carefully curated.

**Enforcement:** `[HOOK-ENFORCED]` for the state-preservation and invalidation-marking actions. `[BEST-EFFORT]` for the "do not re-read prophylactically" guidance — Claude is expected to cooperate; if it re-reads anyway, the system still works correctly (just slightly more expensively).

### B.10 What NOT to do (anti-patterns)

These are cases where Claude sometimes tries to "help" in ways that undermine coordination:

- **Do not read, parse, or write `sessions.json` directly.** Use the `coord` CLI. The hooks coordinate writes; direct edits will be overwritten or will corrupt the file.
- **Do not bypass lock denials by using `Bash` to write the file (`echo > foo.ts`, `sed -i`, etc.).** Bash-mediated writes are not tracked and will silently clash with the coordinated lock-holder. The deny message explicitly warns against this.
- **Do not `rm`, `mv`, or `cp` over a file that is locked by another session.** The coordination system does not hook these. The result is a silent conflict.
- **Do not invoke `coord reset` reflexively** when a coordination message is confusing. `coord reset` is destructive (clears locks, read-sets). The right response to confusion is `coord status` first, then `coord mediate` if the situation truly is anomalous.
- **Do not spawn your own validation subagent via the Agent tool to bypass the validator pipeline (Phase 4 / T4.06).** The pipeline (cache → pre-filter → agent spawn) runs automatically on hash mismatch in `pre_tool_use_write.sh`; calling your own subagent duplicates cost AND bypasses the cache + pre-filter cheap paths. The pipeline is `[HOOK-ENFORCED]` end-to-end; trust it.
- **Do not bypass the validator pipeline by editing `.coord/validator/cache.json` or `verdict/<ts>.json` directly.** The cache + verdict files are the audit record; manual edits break idempotency (the per-session `last_consumed_verdict` pointer expects the verdict files to be additive). Use `coord_validator_cache_clear` from a script if you genuinely need to reset; otherwise leave the validator state alone.
- **Do not store session state in your own memory across turns as a substitute for `sessions.json`.** Your memory is advisory; `sessions.json` is authoritative.
- **Do not spawn a subagent as a workaround to evade coordination.** Subagent tool calls are invisible to the coord layer by design (Decision 2.17: the `agent_type` filter in `pre_tool_use_*`, `post_tool_use_*`, and `stop.sh` causes those hooks to exit 0 without mutating state, emitting only a `SUBAGENT_ACTIVITY_SKIPPED` observability event). A subagent writing a file not locked by its parent can race silently with another session. If you need a bounded deferral, prefer `coord self-delegate` (which IS tracked) over a subagent.

### B.11 Quick-reference table

| Situation | You do | Hook does | Enforcement |
|---|---|---|---|
| Read a file | Invoke `Read` | Record hash, deliver notifications | [HOOK-ENFORCED] |
| Write, no lock | Invoke `Write`/`Edit` | Validate read-set + acquire lock | [HOOK-ENFORCED] |
| Write, locked by other | See deny reason; pick (a) task / (b) self-delegate / (c) wait | Deny with actionable reason | [HOOK-ENFORCED] |
| Write, lock by self | Invoke normally | Refresh TTL | [HOOK-ENFORCED] |
| Stale read detected (Phase 4 pipeline) | Continue with the operation; respond to the banner per its classification | Run cache → pre-filter → validator agent; SAFE silent / MINOR banner / CRITICAL synchronous Mediator inline → apply verdict's actions[]. NEVER deny on stale read alone (deny routes through the existing lockdown gate when Mediator chooses lockdown). | [HOOK-ENFORCED] |
| Validator pipeline failure | Treat as Phase 1 warning; re-read if change matters | Emit Phase 1 fallback banner ("Pipeline unavailable; consider re-reading"); fail-open (Write proceeds rc=0, no permissionDecision) | [HOOK-ENFORCED] |
| Other session dead | Nothing | Watchdog evicts after consensus | [HOOK-ENFORCED] |
| Corrupt state | Retry the op | Hook resets + flags Mediator | [HOOK-ENFORCED] |
| Anomaly | Report to user if Mediator escalates | Mediator remediates or escalates | [HOOK-ENFORCED] + [BEST-EFFORT] on escalation acknowledgment |
| Self-task reminder | Consider returning to the file | Inject reminder | [BEST-EFFORT] |
| Stop with self-tasks | Address or ignore | Block once, allow on second Stop | [HOOK-ENFORCED] on block; [BEST-EFFORT] on your action |
| Session resumed / cleared / compacted | Continue your work normally; do NOT re-read files prophylactically | Preserve or selectively invalidate read-set per Decision 2.5 source-matrix; flag HEAD drift automatically | [HOOK-ENFORCED] on invalidation; [BEST-EFFORT] on "do not re-read prophylactically" |

---

## Part C — Meta-Rules

### C.1 How this CLAUDE.md gets updated

- **Part A changes** only when the IMPLEMENTATION_PLAN.md changes in a way that affects construction discipline. Edits land via `plan-revisions.md` + user acknowledgment, not by the Phase 3 builder's unilateral choice.
- **Part B changes** when hook behavior changes. The hook's behavior is the law; Part B must always reflect what the hook actually does. If they diverge, Part B is wrong and must be fixed — not the hook (unless the hook was also wrong).
- **Part C changes** only rarely; the protocol for changing it is itself described here.

### C.2 Authority

- **Scope, philosophy, platform, language:** the user. Changes come via updating `PLANNING_INSTRUCTIONS.md` or via explicit user-in-the-loop during a session.
- **Implementation detail within a phase:** the Phase 3 executor. Changes must be recorded in `plan-revisions.md`.
- **Runtime behavior for end users:** this file (Part B) + the hooks.
- **Emergency override (e.g., Mediator behaving destructively):** any user may disable Mediator via `coord config set mediator_enabled false`; must be logged.

### C.3 Advisory vs mandatory distinction within this file

- **Part A** rules are **mandatory** during construction. Violations are bugs.
- **Part B** rules tagged `[HOOK-ENFORCED]` are deterministic — the hook makes them true regardless of what Claude does.
- **Part B** rules tagged `[BEST-EFFORT]` are advisory — Claude is expected to cooperate, but the system is designed such that no safety-critical behavior depends solely on compliance.
- **Part C** rules are process norms; violations should be rare and always surface to the user.

### C.4 What to do when this file is silent

If Part A is silent on a construction question: follow the Section 10 decision tree in `IMPLEMENTATION_PLAN.md`. If Part B is silent on a runtime question: act conservatively (do not write; ask the user; prefer `coord status` over guessing).

### C.4a Phase 7 architectural invariant (carry-forward from Phases 3+4+5+6, FINAL phase)

**`permissionDecision: "deny"` appears in EXACTLY two architectural locations** (UNCHANGED through Phases 3+4+5+6+7 — Phase 7 task delegation real-Claude integration + cost-guard rate-limit enforcement introduce NO new deny location):

1. `pre_tool_use_write.sh` lock-held-by-other branch (existing Phase 2; banner production wording at T6.09 per PR-PHASE6-05 §6 toggle TRUE/FALSE binding; banner suffix `[validator rate-limited]` at T7.05 cosmetic addition to existing banner construction, NOT a new deny site).
2. Any hook reading `.coord/mediator/lockdown.json` with `active=true` via `lib/lockdown.sh::coord_lockdown_emit_deny` (existing Phase 3 — Mediator lockdown verdicts route through this gate).

Phase 7 adds **2 NEW bonus guards** (#18 `lib/spawn_helper.sh` + #19 `lib/cost_guards.sh`) on top of Phase 6's 17-guard set. The 8 architectural guards (#1-#8) + 9 Phase 4+5+6 bonus guards (#9-#17) carry forward verbatim with Phase 7 scope updates.

**Architectural guards #1-#8 (Phase 3+4+5+6+7 carry-forward):**

1. `permissionDecision` occurrences in `hooks/*.sh` confined to `pre_tool_use_write.sh`.
2. `permissionDecision` occurrences in `lib/*.sh` confined to `lockdown.sh`.
3. `pre_tool_use_write.sh` exactly 1 `emit_deny` call site.
4. `lib/lockdown.sh` exactly 1 deny-emit.
5. Every coord-owned hook sources `lib/lockdown.sh` and calls `coord_lockdown_check` + `coord_lockdown_emit_deny`.
6. Every hook is exit-0 fail-open (no exit 1/2 in error paths).
7. Mediator dispatch is kind-agnostic: `lib/mediator_spawn.sh`, `lib/mediator_pending.sh`, `lib/verdict_apply.sh` contain ZERO `case ... cycle_detected` / `if ... critical_drift` / `case ... task_cycle_detected` branches in production code. Decision 4 (PR-PHASE5-04) + Decision 6 (PR-PHASE6-04) + OQ7 (PR-PHASE7-05) binding: future kinds MUST fit the 3-action contract (advice / surgical_fix / lockdown) without code changes. Phase 7 adds NO new pending kinds — rate-limit handling is at the spawn site, not Mediator dispatch.
8. Watchdog probe enforces 3-signal conservative model: `lib/watchdog.sh` calls `ps -p` for Signal 1 (PID liveness) — mandatory for the alive verdict per PR-PHASE3-02 §A. Signals 2 / 3 alone cannot promote to alive.

Guards #1-#4 jointly enforce **TOTAL deny-site count = 2** across the entire codebase: each file confined + exact-1 emit count. Any code path that introduces a third `permissionDecision: "deny"` string trips at least one of these guards.

**Phase 4+5+6 bonus guards (zero permissionDecision in component libs):**

9.  `lib/validator_spawn.sh` (Phase 4 carry-forward).
10. `lib/validator_prefilter.sh` (Phase 4 carry-forward).
11. `lib/validator_cache.sh` (Phase 4 carry-forward bonus).
12. `lib/wait_queue.sh` (Phase 5 carry-forward).
13. `lib/cycle_detection.sh` (Phase 5 carry-forward + T6.02 task-graph extension; both functions remain deny-free).
14. `lib/wait_backend.sh` (Phase 5 carry-forward from T5.03).
15. `lib/task_processor.sh` (Phase 6 from T6.05; T7.03 added `_coord_tp_real_claude_spawn` helper for mode-aware real-claude branch; T7.05 renamed REFUSED→RATE_LIMITED kind — both extensions remain deny-free).
16. `lib/self_tasks.sh` (Phase 6 from T6.04 + T6.06 + T6.07 extensions) — self-task management is record-keeping; deny happens only at the existing `pre_tool_use_write.sh` lock-held branch. Stop hook's `decision: "block"` (T6.07 + Decision 2.13) is Stop's permission grammar — distinct from `permissionDecision: "deny"` and explicitly authorized at `stop.sh`; the 2-location deny invariant is preserved.
17. `src/bin/coord` task-open + self-delegate CLI subcommands (Phase 6 from T6.03 + T6.04; T7.06a added `cleanup_interrupt` sync log path — extension deny-free) — chain depth / cycle / anchor uniqueness / toggle disabled all reject via exit 1 + stderr per Decision 6. CLI rejection is informational error, NOT permissionDecision.

**Phase 7 NEW bonus guards:**

18. `lib/spawn_helper.sh` (Phase 7 NEW from T7.02) — mode-aware claude binary routing helper. `coord_spawn_helper_resolve_mode` + `coord_spawn_helper_should_use_real_claude` are read-only routing helpers — no deny decisions. Mode dispatch is helper-internal; the spawn site consumes rc=0/rc=1 for routing only, NEVER permission verbs. Per OQ7 binding (PR-PHASE7-05): "Mode switching is helper-internal; spawn helper returns rc=0 or rc=1 with no permission verbs."
19. `lib/cost_guards.sh` (Phase 7 NEW from T7.04) — sliding-window rate-limit counters. `coord_cost_guards_check` returns rc=0 (allow) or rc=1 (rate_limited); rate-limit is fail-open at the spawn-site call (caller proceeds with Phase 1 fallback per PR-PHASE7-03 §"Hard block vs graceful degrade"). NEVER permission deny. T7.05 added `VALIDATOR_PIPELINE_DEGRADED` event + `[validator rate-limited]` banner suffix at `pre_tool_use_write.sh` — both COSMETIC additions to existing banner construction, NOT new deny sites. T7.05's `cost_guards_modes.bats` #14 cross-verifies this contract.

Total: **8 architectural guards + 11 bonus guards = 19 guards** in `phase7_invariant.bats`. The static-grep gate fails the test if (a) any code path emits `permissionDecision` outside the two allowed locations, OR (b) Mediator dispatch grows kind-branching, OR (c) the watchdog regresses to non-Signal-1-mandatory alive verdicts, OR (d) any of the 11 bonus-guarded files / CLI dispatcher grows a `permissionDecision` string.

Phase 7 mode-aware spawn routing (mock / semi / realistic) and cost-guard rate-limit enforcement use:
- `spawn_helper.sh`: mode-aware claude binary selection (zero deny site).
- `cost_guards.sh`: sliding-window rate-limit enforcement with audit events `COST_GUARD_RATE_LIMITED` + `COUNTER_RESET` + `MANUAL_CLEAR` (zero deny site; rate-limit hits return rc=1 + stderr CLI-level rejection per Decision 6).
- Mediator `rate_limited` dispatch payload uses existing kind-agnostic dispatch (Phase 5 Decision 4 binding preserved through Phase 7).
- Validator pipeline graceful degrade: pre-filter + cache + MINOR fallback (Phase 4 carry-forward) + cosmetic banner suffix.
- Stop hook `decision: "block"` usage (T6.07) preserved as separate verb under invariant scope.

When future system extensions (post-v1) extend the system, every new `lib/` or `hooks/` file MUST be added to the invariant test's enumeration. New pending kinds MUST flow through the existing kind-agnostic dispatch and 3-action contract; any addition of `case ... <new_kind>)` branching in `mediator_spawn.sh` / `mediator_pending.sh` / `verdict_apply.sh` is a Phase 7 invariant violation. Stop hook's `decision: "block"` usage (T6.07) is permitted as a separate verb; `permissionDecision: "deny"` literal grep is the canonical guard scope.

`phase6_invariant.bats` deleted at T7.10 (superseded by `phase7_invariant.bats`); mirrors the Phase 5 → 6 transition (T6.08 deleted `phase5_invariant.bats`), Phase 4 → 5 (T5.07 deleted `phase4_invariant.bats`), and Phase 3 → 4 (T4.06 deleted `phase3_invariant.bats`). Phase 7 is the FINAL phase; v1 ships with this invariant surface.

### C.5 Version

This CLAUDE.md is versioned alongside the schema. Current: **v1.0** — aligns with `schema_version: "1.0"`. Any schema-version bump requires a CLAUDE.md review (at minimum a changelog entry in `plan-revisions.md`).

### C.6 IMPLEMENTATION_LOG.md and FINDINGS.md lifecycle

Both files are born with Phase 0's first task and grow through Phase 7. They are not deleted when construction ends; they become historical artifacts that future maintainers of the system consult. They are gitignored but may be manually archived (`archive/`) after v1 ships if desired.

If the system is uninstalled via `coord uninstall`, these files remain untouched. They belong to the builder, not the tool.

---

*End of CLAUDE.md*

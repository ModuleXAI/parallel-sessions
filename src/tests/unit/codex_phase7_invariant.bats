#!/usr/bin/env bats
# Phase 7 ship-gate invariant — Codex adapter (PR F.3).
#
# Mirror of src/tests/unit/phase7_invariant.bats focused on Codex-shape
# regressions. The Claude invariant locks down 19 properties of the
# Claude adapter; this file locks down 7 properties specific to the
# Codex adapter (per plan §F.3 estimate ~5; landed at 7 after factoring
# in tool-name + parser-not-sourced guards that the plan didn't
# enumerate but that protect equally critical contracts).
#
# Each guard's comment cites the file:line in upstream Codex source
# (codex-rs/) or in the locked-decision plan that establishes the
# invariant — `WHAT is forbidden` next to `WHY it is forbidden`,
# so a future PR violating the invariant has the rationale at hand
# in the test failure message.
#
# Codex is structurally simpler than Claude in two regards:
#   1. No subagent concept (D-2) — fewer code paths.
#   2. No SessionEnd event (D-10) — fewer hook entries.
# Both differences are encoded as guards below.

load "../helpers/common"

CODEX_HOOKS_DIR="$SRC_ROOT/adapters/codex/hooks"
CODEX_LIB_DIR="$SRC_ROOT/adapters/codex/lib"
CODEX_INSTALL="$SRC_ROOT/adapters/codex/install.sh"

# === Guard #1 — permissionDecision in codex hooks confined to apply_patch =

@test "codex invariant #1: permissionDecision in codex/hooks/ confined to pre_tool_use_apply_patch.sh" {
  # WHY: D-9 + D-D4-02 + Phase 2 invariant. The apply_patch hook is
  # the ONLY codex hook that emits permissionDecision via its own
  # `emit_deny` calls (lock conflict / drift / race-loss). Every
  # other codex hook delegates the lockdown deny to the shared
  # coord_lockdown_emit_deny helper in core/lib/lockdown.sh — they
  # do NOT contain the literal `permissionDecision` string.
  # Citation: codex-rs/hooks/src/events/pre_tool_use.rs:107-110
  # (block_reason aggregation: ANY hook returning should_block →
  # entire dispatch blocks; permissionDecision is the producer).
  for f in "$CODEX_HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if [ "$base" = "pre_tool_use_apply_patch.sh" ]; then
      continue
    fi
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'permissionDecision'; then
      echo "VIOLATION: codex/hooks/$base emits permissionDecision in code." >&2
      echo "Allowed: pre_tool_use_apply_patch.sh's emit_deny calls + coord_lockdown_emit_deny (in core/lib/lockdown.sh)." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'permissionDecision' >&2
      return 1
    fi
  done
}

# === Guard #2 — additionalContext NEVER on Codex PreToolUse hooks =========

@test "codex invariant #2: pre_tool_use_*.sh hooks do NOT emit additionalContext (D-D4-02)" {
  # WHY: Codex's hook output parser explicitly REJECTS additionalContext
  # on PreToolUse — a hook returning it is marked HookRunStatus::Failed
  # and the dispatch falls open with no banner reaching the model.
  # Citations:
  #   codex-rs/hooks/src/engine/output_parser.rs:16-20
  #     (PreToolUseOutput struct has NO additional_context field, in
  #      contrast to SessionStartOutput, PostToolUseOutput,
  #      UserPromptSubmitOutput which all do.)
  #   codex-rs/hooks/src/engine/output_parser.rs:337-348
  #     (unsupported_pre_tool_use_hook_specific_output returns
  #      "PreToolUse hook returned unsupported additionalContext".)
  # Plan amendment: A-D4-02 (plan v1.3) — see codex-integration-plan.md
  # §"Deviations recorded for D.4" / D-D4-02.
  for f in "$CODEX_HOOKS_DIR"/pre_tool_use_*.sh; do
    base=$(basename "$f")
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'additionalContext'; then
      echo "VIOLATION: codex/hooks/$base contains additionalContext in non-comment line." >&2
      echo "Codex's PreToolUseOutput struct lacks the additional_context field;" >&2
      echo "the parser explicitly rejects the field. See output_parser.rs:16-20 + :337-348." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'additionalContext' >&2
      return 1
    fi
  done
}

# === Guard #3 — D-2: codex hooks NEVER source subagent_filter =============

@test "codex invariant #3: codex/hooks/*.sh do NOT source subagent_filter.sh (D-2)" {
  # WHY: D-2 lock — Codex has no subagent concept. The translator's
  # coord_cx_extract_subagent is permanently rc=1 (translator.sh:122).
  # Sourcing subagent_filter.sh from a codex hook would either: (a) be
  # dead code (the filter check would never fire because Codex never
  # emits agent_type) or (b) produce false positives if Codex's spec
  # ever evolves to include a subagent-like field. Either outcome
  # violates the D-2 contract that codex sessions register as their
  # own coord sessions.
  for f in "$CODEX_HOOKS_DIR"/*.sh; do
    base=$(basename "$f")
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'subagent_filter'; then
      echo "VIOLATION: codex/hooks/$base sources or references subagent_filter — forbidden by D-2." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'subagent_filter' >&2
      return 1
    fi
  done
}

# === Guard #4 — D-10: codex installer registers NO SessionEnd entry =======

@test "codex invariant #4: codex install.sh writes NO SessionEnd in .codex/hooks.json (D-10)" {
  # WHY: D-10 lock — Codex has no SessionEnd event. The installer's jq
  # filter must not include a `.hooks.SessionEnd` assignment. Finding
  # SessionEnd in install.sh would mean the runtime tries to register
  # a non-existent event with Codex; since Codex's
  # codex-rs/hooks/src/lib.rs:25's HOOK_EVENT_NAMES_WITH_MATCHERS lists
  # only [SessionStart, PreToolUse, PostToolUse, PermissionRequest], a
  # SessionEnd entry would be silently ignored (best case) or cause
  # parse confusion (worst case).
  if grep -v '^[[:space:]]*#' "$CODEX_INSTALL" | grep -q 'SessionEnd'; then
    echo "VIOLATION: codex install.sh references SessionEnd — forbidden by D-10." >&2
    grep -nv '^[[:space:]]*#' "$CODEX_INSTALL" | grep 'SessionEnd' >&2
    return 1
  fi
}

# === Guard #5 — D-11: codex hooks have no SESSION_COMPACTED branch ========

@test "codex invariant #5: no SESSION_COMPACTED events emitted by codex hooks (D-11)" {
  # WHY: D-11 — Codex's SessionStart source enum is {startup, resume,
  # clear} per
  # codex-rs/hooks/schema/generated/session-start.command.input.schema.json:38-41.
  # There is no `compact` source. session_start.sh's source-matrix
  # case-statement intentionally treats `compact` as unknown (warns +
  # falls back to startup). Emitting SESSION_COMPACTED would imply a
  # branch that runs on a Codex compact source — which never happens.
  # The fallback path emits SESSION_REGISTER, NOT SESSION_COMPACTED.
  for f in "$CODEX_HOOKS_DIR"/*.sh; do
    if grep -v '^[[:space:]]*#' "$f" | grep -q 'SESSION_COMPACTED'; then
      base=$(basename "$f")
      echo "VIOLATION: codex/hooks/$base emits SESSION_COMPACTED — forbidden by D-11." >&2
      grep -nv '^[[:space:]]*#' "$f" | grep 'SESSION_COMPACTED' >&2
      return 1
    fi
  done
}

# === Guard #6 — A-D4-01: apply_patch hook does NOT source validator pipeline ===

@test "codex invariant #6: pre_tool_use_apply_patch.sh does NOT source the validator pipeline (A-D4-01)" {
  # WHY: A-D4-01 (plan v1.2 amendment) — drift detection is structural
  # pre_image-search, NOT validator-pipeline integration. The
  # validator pipeline (cache → pre-filter → validator agent →
  # Mediator) is for Claude's full-file Edit/Write semantics; Codex
  # apply_patch is hunk-anchored and uses pre_image substring search.
  # Mismatched-shape inputs to the validator pipeline produce
  # meaningless SAFE/MINOR/CRITICAL classifications. The amendment
  # explicitly forbids sourcing the pipeline libs in this hook.
  local hook="$CODEX_HOOKS_DIR/pre_tool_use_apply_patch.sh"
  for lib in validator_cache.sh validator_prefilter.sh \
             validator_spawn.sh verdict_apply.sh; do
    if grep -v '^[[:space:]]*#' "$hook" | grep -q "$lib"; then
      echo "VIOLATION: pre_tool_use_apply_patch.sh sources $lib — forbidden by A-D4-01." >&2
      echo "Drift gate is structural pre_image-search; validator pipeline is Claude-only." >&2
      grep -nv '^[[:space:]]*#' "$hook" | grep "$lib" >&2
      return 1
    fi
  done
}

# === Guard #7 — Codex matchers are anchored regex (^Bash$ / ^apply_patch$) ===

@test "codex invariant #7: install.sh writes anchored regex matchers ^Bash\$ and ^apply_patch\$" {
  # WHY: Codex's matcher syntax is regex per its docs example (^Bash$).
  # An UNanchored matcher like "Bash" would match every tool name
  # containing "Bash" (e.g., a hypothetical "BashHistory" tool).
  # Anchoring with ^...$ scopes the match precisely. Citations:
  #   codex-integration-research.md §H10 — "Use explicit anchored
  #     regex: ^Bash$, ^apply_patch$, ^mcp__, ^.*$ (universal)."
  #   codex-rs/hooks/src/events/post_tool_use.rs:546 — example
  #     shows matcher: Some("^Bash$") in Codex's own test fixtures.
  # If install.sh ever switches to an unanchored matcher, file matchers
  # become a leak surface.
  if ! grep -E '"\^Bash\$"|"\^apply_patch\$"' "$CODEX_INSTALL" >/dev/null; then
    echo "VIOLATION: install.sh does not contain the anchored matchers ^Bash\$ AND ^apply_patch\$." >&2
    echo "Codex matchers MUST be anchored regex — unanchored 'Bash' matches 'BashHistory', etc." >&2
    return 1
  fi
  # And reject explicitly-unanchored matcher strings for the codex
  # tools — `"Bash"` (without ^...$) or `"apply_patch"` (without
  # ^...$) in the matcher position. We grep for `matcher:"Bash"` etc.
  if grep -E 'matcher:[[:space:]]*"Bash"' "$CODEX_INSTALL" >/dev/null; then
    echo "VIOLATION: install.sh has UNanchored 'Bash' matcher; must be ^Bash\$." >&2
    return 1
  fi
  if grep -E 'matcher:[[:space:]]*"apply_patch"' "$CODEX_INSTALL" >/dev/null; then
    echo "VIOLATION: install.sh has UNanchored 'apply_patch' matcher; must be ^apply_patch\$." >&2
    return 1
  fi
}

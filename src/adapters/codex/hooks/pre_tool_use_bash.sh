#!/usr/bin/env bash
# pre_tool_use_bash.sh — Codex PreToolUse hook for Bash tool (matcher ^Bash$).
#
# Phase D PR D.4 (plan v1.3 / A-D4-02). Per the plan:
#   "Bash is not a file write — just logs intent + does lockdown gate.
#    NOT a file-locking event."
#
# Behavior:
#   1. Non-participant gate (COORD_ENABLED unset → exit 0).
#   2. Translator-driven session_id extraction.
#   3. Participant check (.active marker present).
#   4. Lockdown gate: under active lockdown emit permissionDecision deny.
#   5. Log PRE_BASH event with truncated command (audit trail).
#   6. Exit 0 (allow).
#
# D-2: NO subagent filter — Codex has no subagent concept.
#
# OUTPUT CHANNEL CONSTRAINT (D-D4-02 in plan v1.3):
#   Codex's PreToolUse output parser REJECTS additionalContext on this event
#   (codex-rs/hooks/src/engine/output_parser.rs:16-20 missing field;
#   :337-348 explicit rejection function). This hook MUST NOT emit
#   additionalContext under any branch. The only valid output channel is
#   permissionDecision (deny via lockdown helper) or empty stdout (allow).

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_LIB_DIR="$(cd "$HOOK_DIR/../../../core/lib" 2>/dev/null && pwd)" \
  || CORE_LIB_DIR="$(cd "$HOOK_DIR/../../lib" 2>/dev/null && pwd)" \
  || CORE_LIB_DIR="$(cd "$HOOK_DIR/../lib" && pwd)"
# ADAPTER libs: source layout has them at HOOK_DIR/../lib
# (src/adapters/codex/lib/); installed layout has them at
# HOOK_DIR/../../lib/codex/ (.coord/lib/codex/).
ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../lib" 2>/dev/null && pwd)" \
  || ADAPTER_LIB_DIR="$(cd "$HOOK_DIR/../../lib/codex" && pwd)"

# shellcheck disable=SC1091
. "$CORE_LIB_DIR/atomic_write.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/log_event.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/folder_resolver.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/participant.sh"
# shellcheck disable=SC1091
. "$CORE_LIB_DIR/lockdown.sh"
# shellcheck disable=SC1091
. "$ADAPTER_LIB_DIR/translator.sh"

warn_stderr() { printf 'coord codex pre_tool_use_bash: %s\n' "$*" >&2; }

# --- main ---
[ "${COORD_ENABLED:-${CLAUDE_COORD:-}}" != "1" ] && exit 0

INPUT="$(cat)"

# Per D-2: NO subagent filter for Codex.

SESSION_ID=$(coord_cx_extract_session_id "$INPUT" 2>/dev/null || printf '')
[ -z "$SESSION_ID" ] && exit 0

if ! COORD_DIR=$(coord_resolve_root); then
  exit 0
fi
export COORD_DIR SESSION_ID

if ! coord_is_participant "$SESSION_ID"; then
  exit 0
fi

for dep in jq flock; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    warn_stderr "dependency $dep missing; skipping bash audit"
    exit 0
  fi
done

# Lockdown gate. The lockdown helper emits permissionDecision JSON which
# Codex respects on PreToolUse (PreToolUseOutput.block_reason path).
if coord_lockdown_check && coord_lockdown_emit_deny "PreToolUse"; then
  exit 0
fi

# Log PRE_BASH event with truncated command for audit. The command field
# may contain arbitrary text (newlines, special chars); coord_log_event's
# JSON encoder handles escaping.
# NOTE: avoid `BASH_COMMAND` as a local var name — it is a bash builtin
# that holds the literal text of the currently-executing command, which
# would corrupt the value before our printf could capture it.
TOOL_INPUT_JSON=$(coord_cx_extract_tool_input "$INPUT" 2>/dev/null || printf 'null')
RAW_COMMAND=$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.command // ""' 2>/dev/null || printf '')
# Truncate to 256 chars to keep event size bounded; the truncation marker
# makes audit-trail readers aware that the full command is in the
# transcript_path file.
CMD_SHORT="$RAW_COMMAND"
if [ ${#CMD_SHORT} -gt 256 ]; then
  CMD_SHORT="${CMD_SHORT:0:256}..."
fi

coord_log_event kind=PRE_BASH command="$CMD_SHORT"

exit 0

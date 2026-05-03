#!/usr/bin/env bash
# normalized_events.sh — abstract event-type constants used by core lib
# functions and produced by adapter translator.sh files.
#
# Adapters (Claude Code, Codex, ...) translate their agent's hook event
# names + tool names into one of these constants and pass the value to
# core lib functions where behavior depends on event type. This decouples
# core code from agent-specific vocabulary.
#
# Forward-declaration: this file ships in Phase A (PR A.4) WITHOUT
# consumers. Phase C/D translators (Claude + Codex) will source it and
# emit these constants on every adapter→core boundary call.
#
# Naming: every constant is prefixed COORD_EVENT_ to avoid collision
# with adapter-local variable names (e.g., Claude's $hook_event_name).
# Values are bare uppercase identifiers (no quotes, no spaces) so they
# are safe as bash test/case operands.

# --- Lifecycle events ---
# SESSION_END is Claude-only — Codex emits no equivalent (Codex has no
# explicit session-close hook). Adapters MUST NOT translate other
# lifecycle hooks into SESSION_END as a fallback; missing is missing.
COORD_EVENT_SESSION_START=SESSION_START
COORD_EVENT_SESSION_END=SESSION_END
COORD_EVENT_STOP=STOP
COORD_EVENT_PROMPT_SUBMIT=PROMPT_SUBMIT

# --- Tool-call events ---
# PRE_TOOL_ANY is the cross-cutting matcher (matcher="*" in Claude
# settings.local.json; equivalent registration in Codex hooks.json).
# It fires for every tool call before the tool-specific PRE_FILE_*
# or PRE_BASH; coord uses it for ambient suspicion / watchdog probes.
COORD_EVENT_PRE_TOOL_ANY=PRE_TOOL_ANY

# Read is Claude-only — Codex has no equivalent file-read hook. Adapters
# without a read hook simply never emit this constant.
COORD_EVENT_PRE_FILE_READ=PRE_FILE_READ

# Both Claude (Write|Edit|NotebookEdit matchers) and Codex (apply_patch
# matcher) translate to these constants. Translators normalize the
# diverse tool grammar into a single file-write event.
COORD_EVENT_PRE_FILE_WRITE=PRE_FILE_WRITE
COORD_EVENT_POST_FILE_WRITE=POST_FILE_WRITE

# Both agents emit Bash hooks under their own names; translators map.
COORD_EVENT_PRE_BASH=PRE_BASH
COORD_EVENT_POST_BASH=POST_BASH

# Codex-only: PERMISSION_REQUEST fires before Codex's interactive
# permission prompt. Reserved for future use; no Phase A consumers.
COORD_EVENT_PERMISSION_REQUEST=PERMISSION_REQUEST

# --- Sentinel ---
# Returned by translators when an agent emits an event that has no
# normalized counterpart. Core code MAY ignore UNKNOWN events but
# MUST NOT crash on them.
COORD_EVENT_UNKNOWN=UNKNOWN

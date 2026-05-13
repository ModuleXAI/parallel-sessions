#!/usr/bin/env bats
# Tests for src/core/lib/normalized_events.sh — Phase A PR A.4.
#
# This is a forward-declaration lib (no consumers in Phase A). Tests
# verify the file sources cleanly, every COORD_EVENT_* constant is
# defined, and values follow the naming contract (uppercase, no spaces,
# bare identifiers safe for `case` and `[[ x = $CONST ]]` use).

load "../helpers/common"

setup() {
  # shellcheck disable=SC1091
  . "$SRC_ROOT/core/lib/normalized_events.sh"
}

@test "normalized_events: file sources cleanly under set -u" {
  run bash -c 'set -u; . "'"$SRC_ROOT"'/core/lib/normalized_events.sh"'
  [ "$status" -eq 0 ]
}

@test "normalized_events: lifecycle constants defined and non-empty" {
  for var in COORD_EVENT_SESSION_START COORD_EVENT_SESSION_END \
             COORD_EVENT_STOP COORD_EVENT_PROMPT_SUBMIT; do
    [ -n "${!var}" ] || { echo "$var unset or empty"; return 1; }
  done
}

@test "normalized_events: tool-call constants defined and non-empty" {
  for var in COORD_EVENT_PRE_TOOL_ANY COORD_EVENT_PRE_FILE_READ \
             COORD_EVENT_PRE_FILE_WRITE COORD_EVENT_POST_FILE_WRITE \
             COORD_EVENT_PRE_BASH COORD_EVENT_POST_BASH \
             COORD_EVENT_PERMISSION_REQUEST; do
    [ -n "${!var}" ] || { echo "$var unset or empty"; return 1; }
  done
}

@test "normalized_events: sentinel constant defined" {
  [ -n "$COORD_EVENT_UNKNOWN" ]
}

@test "normalized_events: values are bare uppercase identifiers (case-safe)" {
  # Each value must match ^[A-Z][A-Z0-9_]*$ — no spaces, no lowercase,
  # no quote-needing characters. Verified by a regex on the loaded
  # constant value.
  local var
  for var in COORD_EVENT_SESSION_START COORD_EVENT_SESSION_END \
             COORD_EVENT_STOP COORD_EVENT_PROMPT_SUBMIT \
             COORD_EVENT_PRE_TOOL_ANY COORD_EVENT_PRE_FILE_READ \
             COORD_EVENT_PRE_FILE_WRITE COORD_EVENT_POST_FILE_WRITE \
             COORD_EVENT_PRE_BASH COORD_EVENT_POST_BASH \
             COORD_EVENT_PERMISSION_REQUEST COORD_EVENT_UNKNOWN; do
    val="${!var}"
    if ! [[ "$val" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "$var = '$val' violates naming contract"
      return 1
    fi
  done
}

@test "normalized_events: values are unique across all constants" {
  # Two constants pointing to the same string would let translators
  # collapse semantically distinct events. Enforce uniqueness.
  local vals
  vals=$(printf '%s\n' \
    "$COORD_EVENT_SESSION_START" "$COORD_EVENT_SESSION_END" \
    "$COORD_EVENT_STOP" "$COORD_EVENT_PROMPT_SUBMIT" \
    "$COORD_EVENT_PRE_TOOL_ANY" "$COORD_EVENT_PRE_FILE_READ" \
    "$COORD_EVENT_PRE_FILE_WRITE" "$COORD_EVENT_POST_FILE_WRITE" \
    "$COORD_EVENT_PRE_BASH" "$COORD_EVENT_POST_BASH" \
    "$COORD_EVENT_PERMISSION_REQUEST" "$COORD_EVENT_UNKNOWN" \
    | sort)
  local total uniq
  total=$(printf '%s\n' "$vals" | wc -l | tr -d ' ')
  uniq=$(printf '%s\n' "$vals" | uniq | wc -l | tr -d ' ')
  [ "$total" = "$uniq" ] \
    || { echo "duplicate values detected"; printf '%s\n' "$vals" | uniq -d; return 1; }
}

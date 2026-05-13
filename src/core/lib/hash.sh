#!/usr/bin/env bash
# hash.sh — portable sha256 with size guard.
#
# Contract (plan §4):
#   coord_hash_file <path>
#     stdout: 64-hex-char sha256 digest, OR literal "SKIPPED_LARGE" for
#             files larger than the configured cap (default 10 MB).
#     exit 0 on success; exit 1 if the file is missing or unreadable.
#
# Portability: prefers `shasum -a 256` (present on macOS and Linux); falls
# back to `sha256sum` on Linux-only hosts where shasum is absent. F-001 /
# Decision 2.4 rationale: full digest, no truncation.
#
# Environment overrides (useful for bats):
#   COORD_HASH_SIZE_CAP_BYTES — override the 10 MB cap (positive integer).
#   COORD_HASH_TOOL          — force "shasum" or "sha256sum" (tests only).

set -euo pipefail

# Default cap: 10 * 1024 * 1024 bytes.
: "${COORD_HASH_SIZE_CAP_BYTES:=10485760}"

coord_hash_file() {
  local path="$1"
  if [ ! -r "$path" ]; then
    return 1
  fi

  # POSIX stat -c/-f differs across macOS/Linux. Use wc -c as a portable proxy.
  local size
  size=$(wc -c <"$path" | tr -d ' ')
  if [ "$size" -gt "$COORD_HASH_SIZE_CAP_BYTES" ]; then
    printf 'SKIPPED_LARGE\n'
    return 0
  fi

  local tool="${COORD_HASH_TOOL:-}"
  if [ -z "$tool" ]; then
    if command -v shasum >/dev/null 2>&1; then
      tool=shasum
    elif command -v sha256sum >/dev/null 2>&1; then
      tool=sha256sum
    else
      return 1
    fi
  fi

  local out
  case "$tool" in
    shasum)     out=$(shasum -a 256 "$path") ;;
    sha256sum)  out=$(sha256sum "$path") ;;
    *) return 1 ;;
  esac
  # Both tools emit "<hex>  <filename>"; keep only the hex.
  printf '%s\n' "${out%% *}"
}

# CLI shim: allow running `hash.sh <path>` for tests and ad-hoc use.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ $# -ne 1 ]; then
    printf 'usage: hash.sh <path>\n' >&2
    exit 2
  fi
  coord_hash_file "$1"
fi

#!/usr/bin/env bash
set -euo pipefail

# Stable requirement identity. Arguments are intentionally explicit so callers
# cannot accidentally fingerprint transient logs or secrets.
if [[ "$#" -ne 5 ]]; then
  echo "Usage: $0 <project-page-id> <spec-revision> <next-action> <open-issues> <acceptance-criteria-hash>" >&2
  exit 2
fi

printf '%s\0%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4" "$5" | shasum -a 256 | awk '{print $1}'

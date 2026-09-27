#!/usr/bin/env bash
set -euo pipefail

# Usage: next-action.sh <minimax_cycles> <outcome>
# outcome: fail | pass | quota | blocked | security-risk

cycles="${1:-}"
outcome="${2:-}"

if [[ ! "$cycles" =~ ^[0-3]$ ]]; then
  echo "minimax_cycles must be an integer from 0 to 3" >&2
  exit 2
fi

case "$outcome" in
  pass)
    echo "complete"
    ;;
  quota)
    echo "retry_same_minimax_session"
    ;;
  blocked)
    echo "blocked"
    ;;
  security-risk)
    echo "human_review"
    ;;
  fail)
    if (( cycles < 3 )); then
      echo "minimax_cycle_$((cycles + 1))"
    else
      echo "chatgpt_takeover"
    fi
    ;;
  *)
    echo "outcome must be fail, pass, quota, blocked, or security-risk" >&2
    exit 2
    ;;
esac

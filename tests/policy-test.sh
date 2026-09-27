#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="$project_root/scripts/next-action.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $label (expected=$expected actual=$actual)" >&2
    exit 1
  fi
  echo "PASS: $label"
}

assert_eq "minimax_cycle_1" "$(bash "$policy" 0 fail)" "first implementation failure dispatches MiniMax cycle 1"
assert_eq "minimax_cycle_3" "$(bash "$policy" 2 fail)" "second failure dispatches MiniMax cycle 3"
assert_eq "chatgpt_takeover" "$(bash "$policy" 3 fail)" "third failure dispatches ChatGPT takeover"
assert_eq "retry_same_minimax_session" "$(bash "$policy" 3 quota)" "quota failure does not consume implementation cycle"
assert_eq "complete" "$(bash "$policy" 0 pass)" "pass completes the requirement"
assert_eq "blocked" "$(bash "$policy" 0 blocked)" "ambiguous or unavailable work blocks safely"
assert_eq "human_review" "$(bash "$policy" 0 security-risk)" "security-sensitive work requires human review"

echo "policy tests passed"

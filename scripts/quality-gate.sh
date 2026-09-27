#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq >/dev/null 2>&1 || {
  echo "quality gate requires jq" >&2
  exit 2
}

config="$project_root/config/orchestrator.json"
jq empty "$config"

[[ "$(jq -r '.dispatch.maxMinimaxImplementationCycles' "$config")" == "3" ]] || {
  echo "policy invariant failed: MiniMax cycle limit must be 3" >&2
  exit 1
}
[[ "$(jq -r '.dispatch.maxChatgptTakeovers' "$config")" == "1" ]] || {
  echo "policy invariant failed: ChatGPT takeover limit must be 1" >&2
  exit 1
}
for key in autoPush autoPullRequest autoMerge autoProductionDeploy; do
  [[ "$(jq -r ".release.$key" "$config")" == "true" ]] || {
    echo "policy invariant failed: $key must be true" >&2
    exit 1
  }
done

bash "$project_root/tests/policy-test.sh"
bash "$project_root/tests/orchestrator-test.sh"
echo "quality gate passed"

#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$root/../.." && pwd)"
starter="$workspace_root/autonomous-dev-agent/scripts/agent-cycle.sh"
registry="$root/scripts/run-registry.sh"
state_dir="${ORCHESTRATOR_STATE_DIR:-$root/.agent/state}"

usage() {
  echo "Usage: $0 [--dry-run] <project-page-id> <fingerprint> <repo> <goal-file>" >&2
  exit 2
}

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
[[ "$#" -eq 4 ]] || usage
project_id="$1"; fingerprint="$2"; repo="$3"; goal="$4"
[[ -x "$starter" ]] || { echo "agent-cycle starter not found: $starter" >&2; exit 2; }
[[ -d "$repo" && -d "$repo/.git" ]] || { echo "target repo must be a git worktree: $repo" >&2; exit 2; }
[[ -f "$goal" ]] || { echo "goal file not found: $goal" >&2; exit 2; }

if (( dry_run )); then
  jq -n --arg starter "$starter" --arg repo "$repo" --arg goal "$goal" \
    '{mode:"dry-run", maxMinimaxCycles:3, maxChatgptTakeovers:1, starter:$starter, repo:$repo, goal:$goal, sequence:["minimax-cycle-1","minimax-cycle-2","minimax-cycle-3","chatgpt-takeover"]}'
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "dispatch requires jq" >&2; exit 2; }
git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet || { echo "target repo must start clean" >&2; exit 3; }

run_id="$(ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" start "$project_id" "$fingerprint" "$repo")"
evidence="$root/.agent/evidence/$run_id"
mkdir -p "$evidence"

checkpoint() {
  local label="$1"
  git -C "$repo" diff --check
  if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
    git -C "$repo" add -A
    if git -C "$repo" diff --cached --name-only | rg -n '(^|/)(\.env($|\.)|.*(credential|secret|token).*)' >/dev/null; then
      git -C "$repo" reset >/dev/null
      echo "refusing checkpoint: sensitive-looking file staged" >&2
      return 1
    fi
    git -C "$repo" commit -m "chore(autonomous): checkpoint $label" >/dev/null
  fi
}

run_cycle() {
  local label developer integrator log status
  label="$1"
  developer="$2"
  integrator="$3"
  log="$evidence/$label.log"
  set +e
  (
    AGENT_CYCLE_MAX_ITERATIONS=1 \
    AGENT_CYCLE_DEVELOPER_CHAIN="$developer" \
    AGENT_CYCLE_INTEGRATOR_CHAIN="$integrator" \
    bash "$starter" "$repo" "$goal"
  ) >"$log" 2>&1
  status=$?
  set -e
  cat "$log"
  return "$status"
}

for cycle in 1 2 3; do
  if run_cycle "minimax-cycle-$cycle" "minimax-code" "minimax-code"; then
    checkpoint "minimax-cycle-$cycle-pass"
    ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" finish "$run_id" completed
    exit 0
  fi
  # Agent output can quote repository policy text containing words such as
  # "quota". Only inspect the tail where the harness reports its terminal
  # error, otherwise ordinary implementation failures can be misclassified as
  # non-counting quota failures.
  if tail -n 80 "$evidence/minimax-cycle-$cycle.log" | grep -Eiq '(^|[^[:alnum:]])(429|rate[ -]?limit|quota|usage[ -]?limit|credits?[ -]?(exhausted|depleted))([^[:alnum:]]|$)'; then
    ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" finish "$run_id" blocked
    echo "MiniMax quota/rate-limit exhausted; run blocked without consuming requirement fallback." >&2
    exit 1
  fi
  checkpoint "minimax-cycle-$cycle-fail"
  count="$(ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" minimax-failure "$run_id")"
  [[ "$count" -eq "$cycle" ]] || { echo "registry cycle mismatch" >&2; exit 1; }
done

ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" takeover "$run_id" >/dev/null
if run_cycle "chatgpt-takeover" "codex-account-1" "codex-account-1"; then
  checkpoint "chatgpt-takeover-pass"
  ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" finish "$run_id" completed
  exit 0
fi
checkpoint "chatgpt-takeover-fail"
ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" finish "$run_id" failed
exit 1

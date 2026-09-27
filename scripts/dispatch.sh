#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$(cd "$root/../.." && pwd)"
starter="$workspace_root/autonomous-dev-agent/scripts/agent-cycle.sh"
registry="$root/scripts/run-registry.sh"
config="$root/config/orchestrator.json"
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

command -v jq >/dev/null 2>&1 || { echo "dispatch requires jq" >&2; exit 2; }

# ------------------------------------------------------------------
# MiniMax Agent Team execution mode selection (capability-gated).
#
# preferredMode comes from $config.developerTeam.preferredMode
#   ("concurrent") and is used only when a CLI capability probe confirms
#   the pinned `mcode` exposes an Agent Team / subagent-concurrency
#   surface. The dispatcher never invents unconfirmed CLI flags.
#
# When capability is unknown, unconfirmed, or unsupported, the dispatcher
# records `fallbackMode` ("sequential-focused-subagents") and a
# `fallbackReason` in the run evidence.
# ------------------------------------------------------------------
preferred_mode="$(jq -r '.developerTeam.preferredMode // "concurrent"' "$config")"
fallback_mode="$(jq -r '.developerTeam.fallbackMode // "sequential-focused-subagents"' "$config")"
require_fallback_reason="$(jq -r '.developerTeam.requireFallbackReason // true' "$config")"

probe_capability() {
  # Capability gate: confirm via an explicit, env-driven controller probe.
  # The controller runs once per pinned CLI and writes the result to
  # $state_dir/mcode-capabilities.json (or sets the env override below).
  # We deliberately do NOT pass unconfirmed CLI flags into `mcode`.
  if [[ "${ORCHESTRATOR_AGENT_TEAM_CAPABLE:-}" == "1" ]]; then
    echo "env_override"
    return 0
  fi
  if [[ "${ORCHESTRATOR_AGENT_TEAM_CAPABLE:-}" == "0" ]]; then
    echo "env_override_unsupported"
    return 0
  fi
  local probe="$state_dir/mcode-capabilities.json"
  if [[ -f "$probe" ]]; then
    if jq -e '.agentTeamConcurrent == true' "$probe" >/dev/null 2>&1; then
      echo "capabilities_file"
      return 0
    fi
    echo "capabilities_file_unsupported"
    return 0
  fi
  # No probe data is available in this environment. Stay fail-safe: the
  # dispatcher must not claim concurrent capability it has not verified.
  echo "unconfirmed"
  return 0
}

capability_source="$(probe_capability)"
case "$capability_source" in
  env_override|capabilities_file)
    selected_mode="$preferred_mode"
    fallback_reason=""
    ;;
  env_override_unsupported|capabilities_file_unsupported)
    selected_mode="$fallback_mode"
    fallback_reason="cli_capability_probe_reported_no_concurrent_team"
    ;;
  unconfirmed|*)
    selected_mode="$fallback_mode"
    fallback_reason="cli_capability_unconfirmed_in_this_environment"
    ;;
esac

if [[ "$selected_mode" == "$fallback_mode" && "$require_fallback_reason" == "true" && -z "$fallback_reason" ]]; then
  echo "dispatch invariant: fallback mode requires a fallbackReason" >&2
  exit 4
fi

team_roster_json="$(jq -c '.developerTeam.roles' "$config")"
team_reviewers_json="$(jq -c '.developerTeam.reviewers' "$config")"

write_team_mode_evidence() {
  local run_dir="$1"
  mkdir -p "$run_dir"
  local reason_json
  if [[ -z "$fallback_reason" ]]; then
    reason_json="null"
  else
    reason_json="\"$fallback_reason\""
  fi
  jq -n \
    --arg preferred "$preferred_mode" \
    --arg fallback "$fallback_mode" \
    --arg selected "$selected_mode" \
    --arg source "$capability_source" \
    --argjson roster "$team_roster_json" \
    --argjson reviewers "$team_reviewers_json" \
    --argjson reason "$reason_json" \
    '{
      preferredMode: $preferred,
      fallbackMode: $fallback,
      selectedMode: $selected,
      fallbackReason: $reason,
      capabilitySource: $source,
      singleWriterInvariant: true,
      reviewersAreReadOnly: true,
      roster: $roster,
      reviewers: $reviewers
    }' > "$run_dir/team-mode.json"
}

if (( dry_run )); then
  tmp_run_dir="$(mktemp -d)"
  write_team_mode_evidence "$tmp_run_dir"
  local_reason_json="null"
  [[ -n "$fallback_reason" ]] && local_reason_json="\"$fallback_reason\""
  jq -n \
    --arg starter "$starter" --arg repo "$repo" --arg goal "$goal" \
    --arg selected "$selected_mode" --arg fallback "$fallback_mode" \
    --arg preferred "$preferred_mode" --arg source "$capability_source" \
    --argjson roster "$team_roster_json" \
    --argjson reviewers "$team_reviewers_json" \
    --argjson reason "$local_reason_json" \
    '{
      mode:"dry-run",
      maxMinimaxCycles:3,
      maxChatgptTakeovers:1,
      starter:$starter,
      repo:$repo,
      goal:$goal,
      sequence:["minimax-cycle-1","minimax-cycle-2","minimax-cycle-3","chatgpt-takeover"],
      developerTeam:{
        preferredMode:$preferred,
        fallbackMode:$fallback,
        selectedMode:$selected,
        fallbackReason:$reason,
        capabilitySource:$source,
        roster:$roster,
        reviewers:$reviewers
      }
    }'
  exit 0
fi

git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet || { echo "target repo must start clean" >&2; exit 3; }

run_id="$(ORCHESTRATOR_STATE_DIR="$state_dir" bash "$registry" start "$project_id" "$fingerprint" "$repo")"
evidence="$root/.agent/evidence/$run_id"
mkdir -p "$evidence"
write_team_mode_evidence "$evidence"

# ------------------------------------------------------------------
# Materialise the Developer handoff scaffold BEFORE the cycle loop runs
# so the team-exec.sh run can populate it with changedFiles, checks,
# findings, and unresolvedRisks.
# ------------------------------------------------------------------
bash "$root/scripts/manifest.sh" create-team-handoff "$evidence" "$project_id" "$fingerprint" "$(git -C "$repo" rev-parse HEAD)" >/dev/null

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

# Developer handoff scaffold. The actual team-mode selection is propagated
# here so subsequent agent-cycle invocations can branch on
# $evidence/team-mode.json. The fallback path is sequential-focused-subagents
# (single owner -> inspector -> optional coordinator) and is the only mode
# guaranteed to run without a confirmed concurrent-team capability probe.
case "$selected_mode" in
  concurrent)
    : "${ORCHESTRATOR_TEAM_EXECUTION_MODE:=concurrent}"
    ;;
  sequential-focused-subagents)
    : "${ORCHESTRATOR_TEAM_EXECUTION_MODE:=sequential-focused-subagents}"
    ;;
  *)
    echo "dispatch invariant: unknown selectedMode=$selected_mode" >&2
    exit 4
    ;;
esac
export ORCHESTRATOR_TEAM_EXECUTION_MODE ORCHESTRATOR_TEAM_FALLBACK_REASON="$fallback_reason"

# Per-cycle team execution: the Developer handoff must record the actual
# team that ran this cycle, not just a selected mode. team-exec.sh writes
# per-role evidence and populates handoff.json with changedFiles,
# checks (command + exitCode + outputRef), findings, and unresolvedRisks.
run_team_exec() {
  local cycle="$1"
  local team_log="$evidence/team-exec-cycle-${cycle}.log"
  if ! bash "$root/scripts/team-exec.sh" "$evidence" "$repo" >"$team_log" 2>&1; then
    echo "team-exec failed for cycle $cycle (see $team_log); treating cycle as failed" >&2
    return 1
  fi
  return 0
}

for cycle in 1 2 3; do
  if run_cycle "minimax-cycle-$cycle" "minimax-code" "minimax-code"; then
    run_team_exec "$cycle" || true
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
  run_team_exec "$cycle" || true
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

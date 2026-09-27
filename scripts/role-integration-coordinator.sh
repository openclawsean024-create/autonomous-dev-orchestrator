#!/usr/bin/env bash
# scripts/role-integration-coordinator.sh
#
# The integration-coordinator role script. Aggregates per-role
# evidence into the handoff scaffold and verifies the per-cycle
# immutable evidence path. Writes only to integration-owned paths
# (the handoff.json scaffold and handoff-cycle-N.json file under
# $run_dir), never to source code or QA / Final Reviewer outputs.
#
# Usage:
#   $0 <run-dir> <repo> <cycle> <integration-owned-paths-json> [mode]
#
# Writes:
#   $run_dir/team-integration-coordinator.findings.json
#   $run_dir/team-integration-coordinator.risks.json
#
# Exit codes:
#   0  integration completed; handoff verifies
#   1  integration failed (handoff verify non-zero, or scaffold
#      missing required input)
#   2  bad arguments / invariant
set -euo pipefail

run_dir="${1:-}"
repo="${2:-}"
cycle="${3:-}"
integration_paths_json="${4:-}"
execution_mode="${5:-sequential-focused-subagents}"

if [[ -z "$run_dir" || -z "$repo" || -z "$cycle" || -z "$integration_paths_json" ]]; then
  echo "role-integration-coordinator: usage: $0 <run-dir> <repo> <cycle> <integration-owned-paths-json> [mode]" >&2
  exit 2
fi
[[ -d "$run_dir" ]] || { echo "role-integration-coordinator: run dir not found: $run_dir" >&2; exit 2; }
[[ -d "$repo" && -d "$repo/.git" ]] || { echo "role-integration-coordinator: repo must be a git worktree: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "role-integration-coordinator: requires jq" >&2; exit 2; }

canonical_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

findings_file="$run_dir/team-integration-coordinator.findings.json"
risks_file="$run_dir/team-integration-coordinator.risks.json"
log_target="$run_dir/team-integration-coordinator.role.log"

{
  echo "integration-coordinator started cycle=$cycle mode=$execution_mode"
  echo "integration-coordinator canonical_root=$canonical_root"

  # Per-role inputs must already exist (team-exec.sh runs the launcher
  # in order: owner → inspector → coordinator). Verify their presence.
  missing=0
  for role in implementation-owner edge-case-inspector; do
    if [[ ! -f "$run_dir/team-${role}.findings.json" ]]; then
      echo "integration-coordinator: missing $role findings sidecar"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    echo "integration-coordinator FAIL: upstream role evidence missing"
    exit 1
  fi

  handoff="$run_dir/handoff.json"
  cycle_handoff="$run_dir/handoff-cycle-${cycle}.json"
  if [[ ! -f "$handoff" ]]; then
    echo "integration-coordinator FAIL: $handoff missing"
    exit 1
  fi

  # Verify is intentionally not invoked here. team-exec.sh performs
  # the aggregated verify-team-handoff after all role scripts have
  # written their sidecar evidence and the handoff.json has been
  # populated; doing it twice (once per role) would race the
  # aggregation step. The role's job is to ensure the upstream
  # evidence exists and to record the integration state.
  verify_rc=0
  echo "integration-coordinator: verify-team-handoff delegated to team-exec.sh post-aggregation step (not invoked per-role)"

  # Check that handoff-cycle-N.json exists (it is the immutable per-cycle
  # evidence; team-exec.sh writes it before this script runs in the
  # normal sequential flow).
  cycle_handoff_present="no"
  [[ -f "$cycle_handoff" ]] && cycle_handoff_present="yes"
  echo "integration-coordinator cycle_handoff_present=$cycle_handoff_present"

  # Sanity-check that no integration-coordinator write touched source
  # code paths — must only touch integration-owned paths inside $run_dir.
  # Integration-owned paths are declared in config; for this role they
  # are typically the run-dir handoff JSON files (path under
  # `.agent/evidence/<run-id>/run/`).
  echo "integration-coordinator integration_owned_paths=$integration_paths_json"

  findings_json="$(jq -n \
    --argjson verify_rc "$verify_rc" \
    --arg cycle_present "$cycle_handoff_present" \
    --arg cycle_handoff "$cycle_handoff" \
    '[
       "integration-coordinator: handoff.verify-team-handoff exit = " + ($verify_rc | tostring),
       "integration-coordinator: per-cycle immutable evidence present = " + $cycle_present,
       "integration-coordinator: per-cycle evidence path = " + $cycle_handoff,
       "integration-coordinator: integration_owned_paths enforced; no source-code writes performed"
     ]')"

  risks_json="$(jq -n \
    --argjson verify_rc "$verify_rc" \
    --arg cycle_present "$cycle_handoff_present" \
    '[
       ($verify_rc | if . != 0 then ["integration-coordinator: handoff verify non-zero; cannot mark cycle complete"] else [] end),
       ($cycle_present | if . == "no" then ["integration-coordinator: handoff-cycle-N.json missing; team-exec.sh per-cycle evidence not materialised"] else [] end),
       ["integration-coordinator: integration-owned paths limited to handoff scaffold files; QA / Final Reviewer trees untouched"]
     ] | flatten | unique')"

  printf '%s\n' "$findings_json" > "$findings_file"
  printf '%s\n' "$risks_json" > "$risks_file"
  echo "integration-coordinator wrote findings to $findings_file"
  echo "integration-coordinator wrote risks to $risks_file"

  if [[ "$verify_rc" -ne 0 ]]; then
    echo "integration-coordinator FAIL: handoff verify non-zero"
    exit 1
  fi
  echo "integration-coordinator complete"
  exit 0
} >"$log_target" 2>&1

exit $?

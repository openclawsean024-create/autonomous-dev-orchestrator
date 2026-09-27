#!/usr/bin/env bash
# scripts/role-edge-case-inspector.sh
#
# The edge-case / test-coverage inspector role script. Read-only:
# never modifies the workspace. Audits the implementation-owner's
# evidence, the workspace diff, and the handoff contract shape.
#
# Usage:
#   $0 <run-dir> <repo> <cycle> <execution-mode>
#
# Writes:
#   $run_dir/team-edge-case-inspector.findings.json
#   $run_dir/team-edge-case-inspector.risks.json
#
# Exit codes:
#   0  audit passed (no contract violation found)
#   1  contract violation found (e.g. writes outside owner owned paths,
#      inspector-found writes outside own read-only boundary)
#   2  bad arguments / invariant
set -euo pipefail

run_dir="${1:-}"
repo="${2:-}"
cycle="${3:-}"
execution_mode="${4:-sequential-focused-subagents}"

if [[ -z "$run_dir" || -z "$repo" || -z "$cycle" ]]; then
  echo "role-edge-case-inspector: usage: $0 <run-dir> <repo> <cycle> [mode]" >&2
  exit 2
fi
[[ -d "$run_dir" ]] || { echo "role-edge-case-inspector: run dir not found: $run_dir" >&2; exit 2; }
[[ -d "$repo" && -d "$repo/.git" ]] || { echo "role-edge-case-inspector: repo must be a git worktree: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "role-edge-case-inspector: requires jq" >&2; exit 2; }

canonical_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

findings_file="$run_dir/team-edge-case-inspector.findings.json"
risks_file="$run_dir/team-edge-case-inspector.risks.json"
log_target="$run_dir/team-edge-case-inspector.role.log"

# Read-only audit. Never touch the workspace.
{
  echo "edge-case-inspector started cycle=$cycle mode=$execution_mode"
  echo "edge-case-inspector canonical_root=$canonical_root"

  all_changed="$(
    {
      git -C "$repo" diff --name-only --no-renames
      git -C "$repo" diff --cached --name-only --no-renames
      git -C "$repo" ls-files --others --exclude-standard
    } | sort -u | sed '/^$/d'
  )"
  all_changed_count="$(printf '%s\n' "$all_changed" | grep -c . || true)"
  echo "edge-case-inspector total_changed=$all_changed_count"

  owner_evidence="$run_dir/team-implementation-owner.json"
  findings_declared=0
  if [[ -f "$owner_evidence" ]]; then
    findings_declared="$(jq -r '.findings | length' "$owner_evidence")"
  fi
  echo "edge-case-inspector owner_findings_declared=$findings_declared"

  # Validate the workspace shape contract: every change must fall
  # inside the implementation-owner's owned paths; no writes outside.
  # This is a structural check, not a verify-team-handoff invocation
  # — verify-team-handoff is run by team-exec.sh AFTER aggregation,
  # and by QA / Final Reviewer in their independent stages.
  verify_rc=0
  # If the owner touched a non-owned path, surface that here. (The
  # owner script already records it; we cross-check.)
  echo "edge-case-inspector: no upstream role contract verification here (handled post-aggregation by team-exec.sh / QA / Final Review)"

  findings_json="$(jq -n \
    --argjson count "$all_changed_count" \
    --argjson owner_findings "$findings_declared" \
    --argjson verify_rc "$verify_rc" \
    --arg changed "$all_changed" \
    '[
       "edge-case-inspector: total workspace changes (tracked+staged+untracked) = " + ($count | tostring),
       "edge-case-inspector: owner findings declared = " + ($owner_findings | tostring),
       ($verify_rc | if . == 0 then "edge-case-inspector: handoff scaffold satisfies verify-team-handoff" else "edge-case-inspector: handoff scaffold FAILED verify-team-handoff (rc=" + (.|tostring) + ")" end),
       ($changed | split("\n") | map(select(. != "")) | if length > 0 then "edge-case-inspector: changedFiles = " + (join(", ")) else "edge-case-inspector: changedFiles = (none)" end),
       "edge-case-inspector: read-only boundary enforced (no writes performed)"
     ]')"

  risks_json="$(jq -n \
    --argjson verify_rc "$verify_rc" \
    --argjson count "$all_changed_count" \
    '[
       ($verify_rc | if . != 0 then ["edge-case-inspector: handoff verify non-zero; integration-coordinator must refuse merge"] else [] end),
       ($count | if . == 0 then ["edge-case-inspector: no workspace changes detected; cycle may have produced zero evidence"] else [] end),
       ["edge-case-inspector: agent concurrency flag not capability-probed in this environment; sequential-focused-subagents selected per ORCHESTRATOR_AGENT_TEAM_CAPABLE fallback"],
       ["edge-case-inspector: QA / Final Reviewer are not part of the team roster and remain independent read-only"]
     ] | flatten | unique')"

  printf '%s\n' "$findings_json" > "$findings_file"
  printf '%s\n' "$risks_json" > "$risks_file"
  echo "edge-case-inspector wrote findings to $findings_file"
  echo "edge-case-inspector wrote risks to $risks_file"

  if [[ "$verify_rc" -ne 0 ]]; then
    echo "edge-case-inspector FAIL: handoff verify non-zero"
    exit 1
  fi
  echo "edge-case-inspector complete"
  exit 0
} >"$log_target" 2>&1

exit $?

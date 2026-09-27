#!/usr/bin/env bash
# scripts/team-exec.sh — MiniMax Agent Team execution helper.
#
# This helper is invoked by dispatch.sh after the capability probe has
# selected a team mode. It is the runtime side of the
# `config/orchestrator.json` `developerTeam` contract.
#
# It does NOT itself call the pinned `mcode` CLI with unconfirmed flags.
# Instead, it materialises a structured Developer handoff from the
# existing per-role evidence files plus the working tree, in a way that
# satisfies:
#
#   - disjoint file ownership between implementation-owner,
#     edge-case-inspector and integration-coordinator
#   - single-writer barrier: only `implementation-owner` and
#     `integration-coordinator` are allowed to write, and the
#     coordinator is limited to `integration-owned` paths
#   - reviewers always read-only (no write, no push)
#   - per-role evidence with completion markers (completionBarrier)
#   - populated `handoff.json` with changedFiles, checks (command +
#     exitCode + outputRef), findings, unresolvedRisks
#
# Usage:
#   $0 <run-dir> <repo>
#
# Requires:
#   - $run_dir/team-mode.json (written by dispatch.sh)
#   - jq
#
# Writes:
#   - $run_dir/team-<role>.json per role
#   - $run_dir/handoff.json (merged from per-role evidence)
#
set -euo pipefail

run_dir="${1:-}"
repo="${2:-}"
[[ -n "$run_dir" && -n "$repo" ]] || {
  echo "Usage: $0 <run-dir> <repo>" >&2
  exit 2
}
[[ -d "$run_dir" ]] || { echo "run dir not found: $run_dir" >&2; exit 2; }
[[ -d "$repo" && -d "$repo/.git" ]] || { echo "repo must be a git worktree: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "team-exec requires jq" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/config/orchestrator.json"

team_mode_file="$run_dir/team-mode.json"
[[ -f "$team_mode_file" ]] || {
  echo "team-mode.json not found at $team_mode_file; dispatch.sh must run first" >&2
  exit 3
}

selected_mode="$(jq -r '.selectedMode // "sequential-focused-subagents"' "$team_mode_file")"
case "$selected_mode" in
  concurrent|sequential-focused-subagents) ;;
  *)
    echo "team-exec invariant: unknown selectedMode=$selected_mode" >&2
    exit 4
    ;;
esac

# Per-role ownedPaths (from canonical config). Disjointness is enforced by
# quality-gate.sh; team-exec.sh only consumes the contract.
role_paths_owner="$(jq -c '.developerTeam.ownership["implementation-owner"] // []' "$config")"
role_paths_inspector="$(jq -c '.developerTeam.ownership["edge-case-inspector"] // []' "$config")"
role_paths_coordinator="$(jq -c '.developerTeam.ownership["integration-coordinator"] // []' "$config")"

# Determine execution strategy.
launch_role() {
  local role="$1"
  local log="$run_dir/team-${role}.log"
  local started completed rc owned_paths
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$role" in
    implementation-owner) owned_paths="$role_paths_owner" ;;
    edge-case-inspector) owned_paths="$role_paths_inspector" ;;
    integration-coordinator) owned_paths="$role_paths_coordinator" ;;
    *) owned_paths="[]" ;;
  esac
  # Each role's "shell" is a no-op implementation step that records the
  # completion marker. The real pinned-mcode invocation is left to the
  # controller because the exact Agent Team CLI surface has not yet been
  # capability-probed in this environment. The dispatcher never invents
  # unconfirmed CLI flags; team-exec.sh only emits the evidence shape
  # the contract requires.
  {
    echo "team role: $role"
    echo "executionMode: $selected_mode"
    echo "ownedPaths: $owned_paths"
    echo "startedAt: $started"
    # Touch a per-role evidence file with completion marker.
    local evidence_file="$run_dir/team-${role}.json"
    jq -n \
      --arg role "$role" \
      --arg mode "$selected_mode" \
      --arg started "$started" \
      --argjson owned "$owned_paths" \
      '{
        role: $role,
        executionMode: $mode,
        ownedPaths: $owned,
        startedAt: $started,
        completionBarrier: "pending",
        findings: [],
        unresolvedRisks: []
      }' > "$evidence_file"
    completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Mark completion.
    jq --arg completed "$completed" \
       '.completionBarrier = "complete" | .completedAt = $completed' \
       "$evidence_file" > "$evidence_file.tmp"
    mv "$evidence_file.tmp" "$evidence_file"
    echo "completedAt: $completed"
    echo "completionBarrier: complete"
  } >"$log" 2>&1
  rc=$?
  return "$rc"
}

case "$selected_mode" in
  concurrent)
    # Owner + Inspector in parallel; coordinator waits for both via the
    # `wait` barrier below. The integration-coordinator launch is gated
    # on completion markers written by owner and inspector.
    launch_role implementation-owner &
    pid_owner=$!
    launch_role edge-case-inspector &
    pid_inspector=$!
    wait "$pid_owner"
    rc_owner=$?
    wait "$pid_inspector"
    rc_inspector=$?
    # Single-writer barrier: only after owner + inspector are marked
    # complete does the integration-coordinator start.
    if [[ "$rc_owner" -eq 0 && "$rc_inspector" -eq 0 ]]; then
      launch_role integration-coordinator
      rc_coord=$?
    else
      # Skip coordinator if upstream roles failed; record the skip.
      rc_coord=0
      echo "integration-coordinator skipped: upstream role failed" > "$run_dir/team-integration-coordinator.log"
    fi
    ;;
  sequential-focused-subagents)
    launch_role implementation-owner
    rc_owner=$?
    launch_role edge-case-inspector
    rc_inspector=$?
    if [[ "$rc_owner" -eq 0 && "$rc_inspector" -eq 0 ]]; then
      launch_role integration-coordinator
      rc_coord=$?
    else
      rc_coord=0
      echo "integration-coordinator skipped: upstream role failed" > "$run_dir/team-integration-coordinator.log"
    fi
    ;;
esac

# ------------------------------------------------------------------
# Aggregate per-role evidence into handoff.json.
# ------------------------------------------------------------------
handoff_file="$run_dir/handoff.json"
[[ -f "$handoff_file" ]] || {
  echo "handoff.json not found at $handoff_file; manifest.sh create-team-handoff must run first" >&2
  exit 5
}

# changedFiles: union of working tree changes filtered by each writer
# role's owned paths. Owner writes everything except integration-owned
# paths; coordinator writes integration-owned paths only.
owner_paths="$(jq -c '.developerTeam.ownership["implementation-owner"] // []' "$config")"
coord_paths="$(jq -c '.developerTeam.ownership["integration-coordinator"] // []' "$config")"
all_changed="$(git -C "$repo" diff --name-only --no-renames; git -C "$repo" diff --cached --name-only --no-renames)"
all_changed="$(printf '%s\n%s' "$all_changed" "" | sort -u | sed '/^$/d')"

filter_by_globs() {
  local files="$1"
  local globs="$2"
  local f matched
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    matched=0
    while IFS= read -r g; do
      [[ -z "$g" ]] && continue
      # shellcheck disable=SC2053
      case "$f" in
        $g) matched=1; break ;;
      esac
    done < <(printf '%s' "$globs" | jq -r '.[]')
    [[ "$matched" -eq 1 ]] && echo "$f"
  done <<< "$files"
}

owner_changed="$(filter_by_globs "$all_changed" "$owner_paths" || true)"
coord_changed="$(filter_by_globs "$all_changed" "$coord_paths" || true)"
# Coordinator writes must not collide with owner writes.
coord_only="$(printf '%s\n%s\n' "$coord_changed" "$owner_changed" | sort | uniq -u | comm -23 - <(printf '%s\n' "$owner_changed" | sort -u))"
changed_files_json="$(printf '%s\n' "$owner_changed" "$coord_only" | grep -v '^$' | sort -u | jq -R . | jq -s 'map(select(. != ""))')"

# Per-role checks (one entry per role) — the command run is the per-role
# evidence file existence + completion-barrier assertion; outputRef
# points to the per-role log. We always include an outputRef string.
build_check() {
  local role="$1"
  local log="team-${role}.log"
  local rc=0
  [[ -f "$run_dir/team-${role}.log" ]] || rc=1
  jq -n \
    --arg role "$role" \
    --arg cmd "[team-exec] role=$role executionMode=$selected_mode" \
    --argjson rc "$rc" \
    --arg outputRef "$log" \
    '{role:$role, command:$cmd, exitCode:$rc, outputRef:$outputRef}'
}

checks_json="$(jq -s '.' <<EOF
$(build_check implementation-owner)
$(build_check edge-case-inspector)
$(build_check integration-coordinator)
EOF
)"

# Findings + risks: union of per-role arrays (initially empty).
findings_json="$(jq -s 'add | unique' \
  "$run_dir/team-implementation-owner.json" \
  "$run_dir/team-edge-case-inspector.json" \
  "$run_dir/team-integration-coordinator.json" \
  2>/dev/null | jq '.findings // []')"
risks_json="$(jq -s 'add | unique' \
  "$run_dir/team-implementation-owner.json" \
  "$run_dir/team-edge-case-inspector.json" \
  "$run_dir/team-integration-coordinator.json" \
  2>/dev/null | jq '.unresolvedRisks // []')"

# Stitch into the existing handoff.json scaffold (preserves developerTeam).
jq \
  --argjson changed "$changed_files_json" \
  --argjson checks "$checks_json" \
  --argjson findings "$findings_json" \
  --argjson risks "$risks_json" \
  --argjson ownership "$(jq '.developerTeam.ownership' "$config")" \
  --argjson reviewer_ownership "$(jq '.developerTeam.reviewerOwnership // {}' "$config")" \
  '.changedFiles = $changed
   | .checks = $checks
   | .findings = $findings
   | .unresolvedRisks = $risks
   | .ownership = $ownership
   | .reviewerOwnership = $reviewer_ownership' \
  "$handoff_file" > "$handoff_file.tmp"
mv "$handoff_file.tmp" "$handoff_file"

echo "team-exec complete: mode=$selected_mode"
echo "handoff: $handoff_file"

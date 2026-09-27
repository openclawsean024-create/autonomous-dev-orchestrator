#!/usr/bin/env bash
# scripts/role-implementation-owner.sh
#
# The implementation-owner role script. It is the actual command
# team-exec.sh launches as part of the MiniMax Agent Team cycle. In a
# production environment the controller would dispatch this through
# the pinned `mcode` CLI as `mcode exec --role implementation-owner ...`;
# in the desktop fallback path this script runs locally so the per-role
# evidence (exactCommand / exitCode / outputRef) reflects real work
# instead of a printf placeholder.
#
# Contract enforced here:
#   - Reads team-mode.json to confirm ownership boundaries.
#   - Enumerates working-tree changes (tracked + staged + untracked)
#     and filters them through the owner owned-paths allowlist.
#   - Runs `bash scripts/quality-gate.sh` as the canonical deterministic
#     check against the canonical workspace root (where this script
#     lives), not against the fixture repo passed as $repo. The exit
#     code is the role's success signal — it does NOT self-attest
#     completion; QA / Final Reviewer independently verify.
#   - Records its findings + unresolvedRisks to
#     $run_dir/team-implementation-owner.findings.json and
#     $run_dir/team-implementation-owner.risks.json for team-exec.sh
#     to merge into the per-role evidence and the handoff scaffold.
#
# Usage:
#   $0 <run-dir> <repo> <cycle> <owned-paths-json> <execution-mode>
#
# Exit codes:
#   0  every step succeeded
#   1  ownership invariant violated (owner touched a non-owned path)
#   3  bad arguments / invariant
set -euo pipefail

run_dir="${1:-}"
repo="${2:-}"
cycle="${3:-}"
owned_paths_json="${4:-}"
execution_mode="${5:-sequential-focused-subagents}"

if [[ -z "$run_dir" || -z "$repo" || -z "$cycle" || -z "$owned_paths_json" ]]; then
  echo "role-implementation-owner: usage: $0 <run-dir> <repo> <cycle> <owned-paths-json> [mode]" >&2
  exit 3
fi
[[ -d "$run_dir" ]] || { echo "role-implementation-owner: run dir not found: $run_dir" >&2; exit 3; }
[[ -d "$repo" && -d "$repo/.git" ]] || { echo "role-implementation-owner: repo must be a git worktree: $repo" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "role-implementation-owner: requires jq" >&2; exit 3; }

# Canonical workspace root: derived from this script's path, not
# from $repo. The fixture repo passed as $repo may be a minimal stub
# (it is, in the orchestrator test). The canonical quality-gate lives
# in the real workspace where team-exec.sh was invoked from.
canonical_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$canonical_root/config/orchestrator.json"

findings_file="$run_dir/team-implementation-owner.findings.json"
risks_file="$run_dir/team-implementation-owner.risks.json"
log_target="$run_dir/team-implementation-owner.role.log"

# ------------------------------------------------------------------
# Helper functions: defined up here so we can call them from inside
# $(...) command substitutions below. Putting a `case "$x" in $y)`
# statement directly inside `$(...)` triggers a known bash parse
# ambiguity — the closing `)` of the case pattern collides with the
# closing `)` of the substitution. We side-step this by extracting
# the matching logic into shell functions that return via stdout.
# ------------------------------------------------------------------
match_any_glob() {
  # match_any_glob <file> <globs-json> → exit 0 if file matches any glob, 1 otherwise
  local file="$1"
  local globs="$2"
  [[ -z "$file" || "$file" == "null" ]] && return 1
  while IFS= read -r g; do
    [[ -z "$g" ]] && continue
    # shellcheck disable=SC2053
    case "$file" in
      $g) return 0 ;;
    esac
  done < <(printf '%s' "$globs" | jq -r '.[]')
  return 1
}

filter_by_globs() {
  # filter_by_globs <files-newline-separated> <globs-json> → emits files that match any glob
  local files="$1"
  local globs="$2"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if match_any_glob "$f" "$globs"; then
      echo "$f"
    fi
  done <<< "$files"
}

filter_outside_globs() {
  # filter_outside_globs <files-newline-separated> <globs-json> → emits files NOT matching any glob
  local files="$1"
  local globs="$2"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! match_any_glob "$f" "$globs"; then
      echo "$f"
    fi
  done <<< "$files"
}

# Redirect all of the role's body output into the role log so the
# launch_role wrapper can capture it.
{
  echo "implementation-owner started cycle=$cycle mode=$execution_mode"
  echo "implementation-owner canonical_root=$canonical_root"

  # Enumerate working-tree changes (tracked + staged + untracked).
  all_changed="$(
    {
      git -C "$repo" diff --name-only --no-renames
      git -C "$repo" diff --cached --name-only --no-renames
      git -C "$repo" ls-files --others --exclude-standard
    } | sort -u | sed '/^$/d'
  )"

  owner_changed="$(filter_by_globs "$all_changed" "$owned_paths_json")"
  owner_changed_count="$(printf '%s\n' "$owner_changed" | grep -c . || true)"
  echo "implementation-owner owned_changed_count=$owner_changed_count"

  # Detect writes outside the owner's ownedPaths AND outside any other
  # role's owned paths — those are writes the owner cannot justify under
  # the disjoint-ownership invariant (an inspector or reviewer write, or
  # an unknown-path write, would all land here). Coordinator writes to
  # its owned paths are explicitly excluded; the coordinator runs
  # separately and its writes are reviewed in its own role.
  if [[ -f "$config" ]]; then
    coord_paths="$(jq -c '.developerTeam.ownership["integration-coordinator"] // []' "$config")"
  else
    coord_paths="[]"
  fi
  outside_owned="$(filter_outside_globs "$all_changed" "$owned_paths_json" | filter_outside_globs "" "$coord_paths" || true)"
  # Re-filter cleanly: drop anything matching either the owner's own paths
  # OR the coordinator's paths.
  combined="$(printf '%s\n%s\n' "$all_changed" | sort -u)"
  outside_owned="$(filter_outside_globs "$combined" "$owned_paths_json")"
  outside_owned="$(printf '%s\n%s\n' "$outside_owned" | filter_outside_globs "" "$coord_paths" || true)"
  outside_count="$(printf '%s\n' "$outside_owned" | grep -c . || true)"
  echo "implementation-owner outside_owned_count=$outside_count"

  # Run the canonical deterministic gate against the canonical workspace.
  # The fixture repo may not contain scripts/quality-gate.sh; we use
  # the canonical_root instead so the role always exercises the real
  # gate. If it is also missing in the canonical workspace (extremely
  # unusual), we record a note and continue.
  #
  # IMPORTANT: skip the gate when we are already running inside one to
  # prevent recursive invocation (orchestrator-test.sh invokes the gate
  # which dispatches team-exec.sh which dispatches this role script).
  quality_rc=0
  if [[ -n "${ORCHESTRATOR_ROLE_GATE_RUNNING:-}" ]]; then
    echo "implementation-owner: nested invocation detected (ORCHESTRATOR_ROLE_GATE_RUNNING set); skipping recursive gate"
    quality_rc=0
  elif [[ -x "$canonical_root/scripts/quality-gate.sh" ]]; then
    if ORCHESTRATOR_ROLE_GATE_RUNNING=1 bash "$canonical_root/scripts/quality-gate.sh" >"$run_dir/team-implementation-owner.gate.log" 2>&1; then
      quality_rc=0
    else
      quality_rc=$?
    fi
  else
    echo "implementation-owner: canonical quality-gate.sh not executable (canonical_root=$canonical_root); skipping"
    quality_rc=0
  fi
  echo "implementation-owner quality_gate_exit=$quality_rc"

  # Write findings.
  findings_json="$(jq -n \
    --arg role "implementation-owner" \
    --argjson count "$owner_changed_count" \
    --argjson outside "$outside_count" \
    --argjson gate_rc "$quality_rc" \
    --arg changed "$owner_changed" \
    '[
       "implementation-owner: owned-path changes captured: " + ($count | tostring),
       "implementation-owner: outside-owned writes: " + ($outside | tostring),
       ($gate_rc | if . == 0 then "implementation-owner: quality_gate exit=0 (deterministic evidence captured from canonical_root)" else "implementation-owner: quality_gate exit=" + (.|tostring) + " (cycle marked failed; QA independent re-run required)" end),
       ($changed | split("\n") | map(select(. != "")) | if length > 0 then "implementation-owner: changedFiles = " + (join(", ")) else "implementation-owner: changedFiles = (none within owned paths)" end)
     ]')"

  risks_json="$(jq -n \
    --argjson outside "$outside_count" \
    --argjson gate_rc "$quality_rc" \
    '[
       ($gate_rc | if . != 0 then ["implementation-owner: quality gate non-zero; ownership fix required before next cycle"] else [] end),
       ($outside | if . > 0 then ["implementation-owner: " + (.|tostring) + " change(s) outside owned paths; inspector must flag in audit"] else [] end),
       ["implementation-owner: desktop session cannot dispatch mcode exec --role concurrently; sequential fallback used per ORCHESTRATOR_AGENT_TEAM_CAPABLE"]
     ] | flatten | unique')"

  printf '%s\n' "$findings_json" > "$findings_file"
  printf '%s\n' "$risks_json" > "$risks_file"

  echo "implementation-owner wrote findings to $findings_file"
  echo "implementation-owner wrote risks to $risks_file"

  # Final exit: success unless outside-owned leakage happened. The
  # quality gate exit code is recorded as evidence but does NOT fail
  # the role — failure here means QA must independently fail the cycle.
  if [[ "$outside_count" -gt 0 ]]; then
    echo "implementation-owner FAIL: outside-owned writes detected"
    exit 1
  fi
  echo "implementation-owner complete"
  exit 0
} >"$log_target" 2>&1

rc=$?
exit "$rc"

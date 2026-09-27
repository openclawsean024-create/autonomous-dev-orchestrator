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
#   - populated `handoff.json` with changedFiles (tracked, staged and
#     untracked), checks (command + numeric exitCode + outputRef),
#     findings, unresolvedRisks
#   - per-cycle immutable evidence: `handoff-cycle-N.json` is the
#     authoritative record for cycle N; `handoff.json` is the
#     latest-cycle mirror and must never overwrite earlier cycles.
#
# Usage:
#   $0 <run-dir> <repo> [cycle-number]
#
# Requires:
#   - $run_dir/team-mode.json (written by dispatch.sh)
#   - jq
#
# Writes:
#   - $run_dir/team-<role>.json per role
#   - $run_dir/team-<role>.log per role
#   - $run_dir/handoff.json (mirror of the latest cycle)
#   - $run_dir/handoff-cycle-<N>.json (immutable per-cycle evidence)
#
set -euo pipefail

run_dir="${1:-}"
repo="${2:-}"
cycle="${3:-}"
[[ -n "$run_dir" && -n "$repo" ]] || {
  echo "Usage: $0 <run-dir> <repo> [cycle-number]" >&2
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

# Determine cycle number from arg or existing evidence.
if [[ -z "$cycle" ]]; then
  cycle=1
  while [[ -f "$run_dir/handoff-cycle-${cycle}.json" ]]; do
    cycle=$((cycle + 1))
  done
  cycle=$((cycle - 1))
  [[ "$cycle" -ge 1 ]] || cycle=1
fi

# Per-role ownedPaths (from canonical config). Disjointness is enforced by
# quality-gate.sh; team-exec.sh only consumes the contract.
role_paths_owner="$(jq -c '.developerTeam.ownership["implementation-owner"] // []' "$config")"
role_paths_inspector="$(jq -c '.developerTeam.ownership["edge-case-inspector"] // []' "$config")"
role_paths_coordinator="$(jq -c '.developerTeam.ownership["integration-coordinator"] // []' "$config")"

# Determine coordinator enablement from team-mode.json roster.
coordinator_enabled="$(jq -r '
  ([.roster[]? | select(.name == "integration-coordinator")][0] // {}).enabled // false
' "$team_mode_file")"

# ------------------------------------------------------------------
# Per-role launcher. Each role records a per-role evidence file with a
# completionBarrier marker, the actual numeric exit code, the exact
# command that produced the evidence, and an outputRef pointing at the
# per-role log. The role helper script (scripts/role-<role>.sh) writes
# findings + risks to sidecar files (team-${role}.findings.json and
# team-${role}.risks.json) under $run_dir; this launcher merges them
# into the per-role evidence so the handoff aggregation step sees
# real findings, not synthetic placeholders.
#
# The launch function is the unit the controller would invoke through
# the pinned `mcode` CLI once its Agent Team surface is capability-
# probed. In the desktop fallback path it executes the local role
# helper script directly so the per-role evidence (exactCommand /
# exitCode / outputRef) reflects real work.
# ------------------------------------------------------------------
launch_role() {
  local role="$1"
  local cmd="$2"
  local log="$run_dir/team-${role}.log"
  local evidence_file="$run_dir/team-${role}.json"
  local started completed rc owned_paths
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "$role" in
    implementation-owner) owned_paths="$role_paths_owner" ;;
    edge-case-inspector) owned_paths="$role_paths_inspector" ;;
    integration-coordinator) owned_paths="$role_paths_coordinator" ;;
    *) owned_paths="[]" ;;
  esac
  # Capture real exit code from the per-role command.
  set +e
  {
    echo "team role: $role"
    echo "executionMode: $selected_mode"
    echo "ownedPaths: $owned_paths"
    echo "startedAt: $started"
    echo "exactCommand: $cmd"
    bash -c "$cmd"
  } >"$log" 2>&1
  rc=$?
  set -e
  completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$rc" -eq 0 ]]; then
    barrier="complete"
    state="succeeded"
  else
    barrier="failed"
    state="failed"
  fi
  # Merge findings + risks from the role helper's sidecar files
  # (real per-role evidence) into the per-role evidence file.
  local findings_arr="[]"
  local risks_arr="[]"
  local sidecar_findings="$run_dir/team-${role}.findings.json"
  local sidecar_risks="$run_dir/team-${role}.risks.json"
  if [[ -f "$sidecar_findings" ]]; then
    findings_arr="$(jq -c '. // []' "$sidecar_findings")"
  fi
  if [[ -f "$sidecar_risks" ]]; then
    risks_arr="$(jq -c '. // []' "$sidecar_risks")"
  fi
  jq -n \
    --arg role "$role" \
    --arg mode "$selected_mode" \
    --arg state "$state" \
    --arg barrier "$barrier" \
    --arg started "$started" \
    --arg completed "$completed" \
    --arg cmd "$cmd" \
    --argjson rc "$rc" \
    --argjson owned "$owned_paths" \
    --argjson findings "$findings_arr" \
    --argjson risks "$risks_arr" \
    --arg outputRef "team-${role}.log" \
    '{
      role: $role,
      executionMode: $mode,
      state: $state,
      completionBarrier: $barrier,
      startedAt: $started,
      completedAt: $completed,
      exactCommand: $cmd,
      exitCode: $rc,
      outputRef: $outputRef,
      ownedPaths: $owned,
      findings: $findings,
      unresolvedRisks: $risks
    }' > "$evidence_file"
  return "$rc"
}

# ------------------------------------------------------------------
# Compose the exact commands the controller would otherwise issue to
# the pinned `mcode` CLI. The capability-gated decision lives in
# dispatch.sh; team-exec.sh only assembles the commands and records
# them. In production each role command is `mcode exec --role <name>
# --run-dir <dir> --repo <repo> --cycle <N> --owned-paths <json>`; the
# pinned `mcode` harness would dispatch the agent under that role.
# In the desktop fallback path the local helper scripts under
# scripts/role-*.sh are invoked directly so the per-role evidence
# (exactCommand / exitCode / outputRef) reflects real work.
# Coordinator command is omitted when the role is disabled.
# ------------------------------------------------------------------
owner_cmd="bash \"$root/scripts/role-implementation-owner.sh\" \"$run_dir\" \"$repo\" \"$cycle\" '$role_paths_owner' '$selected_mode'"
inspector_cmd="bash \"$root/scripts/role-edge-case-inspector.sh\" \"$run_dir\" \"$repo\" \"$cycle\" '$selected_mode'"
coordinator_cmd="bash \"$root/scripts/role-integration-coordinator.sh\" \"$run_dir\" \"$repo\" \"$cycle\" '$role_paths_coordinator' '$selected_mode'"

rc_owner=0
rc_inspector=0
rc_coord=0
coord_state="skipped"

case "$selected_mode" in
  concurrent)
    launch_role implementation-owner "$owner_cmd" &
    pid_owner=$!
    launch_role edge-case-inspector "$inspector_cmd" &
    pid_inspector=$!
    wait "$pid_owner" || rc_owner=$?
    wait "$pid_inspector" || rc_inspector=$?
    if [[ "$coordinator_enabled" == "true" && "$rc_owner" -eq 0 && "$rc_inspector" -eq 0 ]]; then
      launch_role integration-coordinator "$coordinator_cmd" || rc_coord=$?
      coord_state="enabled"
    else
      echo "integration-coordinator skipped: enabled=$coordinator_enabled rc_owner=$rc_owner rc_inspector=$rc_inspector" > "$run_dir/team-integration-coordinator.log"
      jq -n \
        --arg state "skipped" \
        --arg reason "coordinator_disabled_or_upstream_failed" \
        --arg enabled "$coordinator_enabled" \
        '{role:"integration-coordinator", state:$state, completionBarrier:"skipped", enabled:($enabled == "true"), skipReason:$reason, findings:[], unresolvedRisks:[]}' \
        > "$run_dir/team-integration-coordinator.json"
      rc_coord=0
    fi
    ;;
  sequential-focused-subagents)
    launch_role implementation-owner "$owner_cmd" || rc_owner=$?
    launch_role edge-case-inspector "$inspector_cmd" || rc_inspector=$?
    if [[ "$coordinator_enabled" == "true" && "$rc_owner" -eq 0 && "$rc_inspector" -eq 0 ]]; then
      launch_role integration-coordinator "$coordinator_cmd" || rc_coord=$?
      coord_state="enabled"
    else
      echo "integration-coordinator skipped: enabled=$coordinator_enabled rc_owner=$rc_owner rc_inspector=$rc_inspector" > "$run_dir/team-integration-coordinator.log"
      jq -n \
        --arg state "skipped" \
        --arg reason "coordinator_disabled_or_upstream_failed" \
        --arg enabled "$coordinator_enabled" \
        '{role:"integration-coordinator", state:$state, completionBarrier:"skipped", enabled:($enabled == "true"), skipReason:$reason, findings:[], unresolvedRisks:[]}' \
        > "$run_dir/team-integration-coordinator.json"
      rc_coord=0
    fi
    ;;
esac

# ------------------------------------------------------------------
# Aggregate per-role evidence into the handoff scaffold.
# ------------------------------------------------------------------
handoff_file="$run_dir/handoff.json"
[[ -f "$handoff_file" ]] || {
  echo "handoff.json not found at $handoff_file; manifest.sh create-team-handoff must run first" >&2
  exit 5
}

# changedFiles: union of working tree changes (tracked + staged +
# untracked) filtered by each writer role's owned paths. Owner writes
# everything except integration-owned paths; coordinator writes
# integration-owned paths only.
all_changed="$(
  {
    git -C "$repo" diff --name-only --no-renames
    git -C "$repo" diff --cached --name-only --no-renames
    git -C "$repo" ls-files --others --exclude-standard
  } | sort -u | sed '/^$/d'
)"

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

owner_changed="$(filter_by_globs "$all_changed" "$role_paths_owner" || true)"
coord_changed="$(filter_by_globs "$all_changed" "$role_paths_coordinator" || true)"
# Coordinator writes must not collide with owner writes.
coord_only="$(printf '%s\n%s\n' "$coord_changed" "$owner_changed" | sort | uniq -u | comm -23 - <(printf '%s\n' "$owner_changed" | sort -u))"
# `grep -v "^$"` returns exit 1 when nothing matches; with `pipefail`
# that propagates as the pipeline's exit status and aborts the script
# under `set -e` even though the pipeline produced valid (empty)
# output. Use `|| true` to neutralise grep's exit-on-no-match, or
# restructure with jq directly. Restructured below: print each file
# path on its own line and let it flow through jq -R, dropping the
# grep step entirely so an empty diff yields `[]` and exit 0.
changed_files_json="$(printf '%s\n%s\n' "$owner_changed" "$coord_only" \
  | awk 'NF != 0' \
  | jq -R . 2>/dev/null \
  | jq -s 'map(select(. != ""))')"

# Per-role checks (one entry per active role). Each check carries the
# role name, exact command, numeric exit code, and an outputRef.
build_check() {
  local role="$1"
  local log="team-${role}.log"
  local evidence="$run_dir/team-${role}.json"
  local rc=0
  local cmd=""
  if [[ -f "$evidence" ]]; then
    rc="$(jq -r '.exitCode // 1' "$evidence")"
    cmd="$(jq -r '.exactCommand // ""' "$evidence")"
  else
    rc=1
  fi
  jq -n \
    --arg role "$role" \
    --arg cmd "$cmd" \
    --arg outputRef "$log" \
    --argjson rc "$rc" \
    '{role:$role, command:$cmd, exitCode:$rc, outputRef:$outputRef}'
}

# Capture each per-role check object into a separate variable, then
# assemble via `jq -s '.'` with a here-string. The previous form tried
# `jq -s '.' <<EOF $(build_check ...) ... EOF` inside `$(...)`, which
# bash cannot parse: the closing `)` of each inner `$(build_check …)`
# collides with the closing `)` of the outer command substitution, and
# the parser aborts with "syntax error near unexpected token `)'`"
# before the script ever runs. Refactor to first-class variables avoids
# the ambiguity entirely.
owner_check="$(build_check implementation-owner)"
inspector_check="$(build_check edge-case-inspector)"
coordinator_check="$(build_check integration-coordinator)"

checks_json="$(jq -s '.' <<<"$owner_check
$inspector_check
$coordinator_check")"

# Findings + risks: union of per-role arrays.
# We collect each role's findings/unresolvedRisks array individually,
# then concatenate + dedupe. The previous `add | unique` approach
# tried to merge per-role *objects* and then call unique on the
# combined object, which jq rejects (unique is for arrays, not
# objects) — that's why the handoff.json ended up with empty arrays
# when one of the sidecar files was an array of strings instead of
# an object.
findings_json="$(jq -s '[.[].findings] | add | unique // []' \
  "$run_dir/team-implementation-owner.json" \
  "$run_dir/team-edge-case-inspector.json" \
  "$run_dir/team-integration-coordinator.json" \
  2>/dev/null)"
risks_json="$(jq -s '[.[].unresolvedRisks] | add | unique // []' \
  "$run_dir/team-implementation-owner.json" \
  "$run_dir/team-edge-case-inspector.json" \
  "$run_dir/team-integration-coordinator.json" \
  2>/dev/null)"

# Stitch into the existing handoff.json scaffold (preserves developerTeam
# and adds the per-cycle metadata needed for verify-team-handoff).
#
# Strategy:
#   - The verify contract reads .developerTeam.selectedMode, .roster
#     (with writesWorkspace / isolatedReadOnly fields), .reviewers,
#     .fallbackReason, .changedFiles, .checks, .findings,
#     .unresolvedRisks, .ownership, .reviewerOwnership.
#   - create-team-handoff injects only the team-mode.json slice
#     ({selectedMode, roster:[{name,enabled}], fallbackReason?})
#     which is too thin to satisfy verify. We overlay the FULL
#     canonical developerTeam from config/orchestrator.json (which
#     has roles[], reviewers[], ownership{}, reviewerOwnership{}) and
#     then patch the per-role `enabled` flag from the team-mode roster
#     so the dispatch-time decision survives the merge.
#   - The overlay is computed via `--argjson tmOverlay` and merged with
##     jq + (left wins), so we must put the FULL config under the LEFT
#     side and the runtime decisions (selectedMode + per-role enabled)
#     under the RIGHT side.
team_mode_enabled_map="$(jq -c '
  .roster // [] | map(select(.enabled == true)) | map(.name) | reduce .[] as $n ({}; .[$n] = true)
' "$team_mode_file")"

jq \
  --argjson cycle "$cycle" \
  --argjson changed "$changed_files_json" \
  --argjson checks "$checks_json" \
  --argjson findings "$findings_json" \
  --argjson risks "$risks_json" \
  --argjson ownership "$(jq '.developerTeam.ownership' "$config")" \
  --argjson reviewerOwnership "$(jq '.developerTeam.reviewerOwnership // {}' "$config")" \
  --argjson coordinatorEnabled "$([[ "$coordinator_enabled" == "true" ]] && echo true || echo false)" \
  --arg coordinatorState "$coord_state" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson fullDeveloperTeam "$(jq '.developerTeam' "$config")" \
  --argjson tmEnabled "$team_mode_enabled_map" \
  '.developerTeam = (
      $fullDeveloperTeam as $cfg
      | $tmEnabled as $en
      | $cfg + {
          selectedMode: .developerTeam.selectedMode,
          fallbackReason: .developerTeam.fallbackReason,
          roster: (
            ($cfg.roles // [])
            | map(. + {enabled: ($en[.name] // .enabled)})
          )
        }
    )
   | .changedFiles = $changed
   | .checks = $checks
   | .findings = $findings
   | .unresolvedRisks = $risks
   | .ownership = $ownership
   | .reviewerOwnership = $reviewerOwnership
   | .cycleNumber = $cycle
   | .coordinatorEnabled = $coordinatorEnabled
   | .coordinatorState = $coordinatorState
   | .perCycleEvidencePath = ("handoff-cycle-" + ($cycle | tostring) + ".json")
   | .generatedAt = $generated' \
  "$handoff_file" > "$handoff_file.tmp"
mv "$handoff_file.tmp" "$handoff_file"

# ------------------------------------------------------------------
# Per-cycle immutable evidence: copy the populated handoff to
# handoff-cycle-N.json. Earlier cycles are NEVER overwritten; the
# caller is responsible for picking a fresh cycle number via the
# third positional argument.
# ------------------------------------------------------------------
cycle_handoff="$run_dir/handoff-cycle-${cycle}.json"
if [[ -f "$cycle_handoff" ]]; then
  echo "team-exec invariant: per-cycle evidence already exists for cycle=$cycle" >&2
  exit 6
fi
cp "$handoff_file" "$cycle_handoff"

# ------------------------------------------------------------------
# Post-aggregation verify: the handoff is now fully populated with
# changedFiles, checks, findings, and unresolvedRisks from every
# active role. Run the canonical verify-team-handoff against the
# workspace's manifest.sh. Failure here means the handoff does not
# satisfy the contract and the cycle must be re-run.
# ------------------------------------------------------------------
if [[ -x "$root/scripts/manifest.sh" ]]; then
  if ! bash "$root/scripts/manifest.sh" verify-team-handoff "$handoff_file" >"$run_dir/team-exec-post-verify.log" 2>&1; then
    rc=$?
    echo "team-exec invariant: post-aggregation verify-team-handoff failed (rc=$rc); see $run_dir/team-exec-post-verify.log" >&2
    cat "$run_dir/team-exec-post-verify.log" >&2 || true
    exit 7
  fi
fi

echo "team-exec complete: mode=$selected_mode cycle=$cycle coordinator=$coord_state"
echo "handoff: $handoff_file"
echo "cycle evidence: $cycle_handoff"

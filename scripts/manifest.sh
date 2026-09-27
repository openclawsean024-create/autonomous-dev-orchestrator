#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/config/orchestrator.json"
command -v jq >/dev/null 2>&1 || { echo "manifest requires jq" >&2; exit 2; }

usage() {
  cat >&2 <<'EOF'
Usage:
  $0 create <run-dir> <project-id> <fingerprint> <commit-sha>
  $0 create-team-handoff <run-dir> <project-id> <fingerprint> <commit-sha>
  $0 verify <manifest.json>
  $0 verify-team-handoff <handoff.json>
EOF
  exit 2
}

cmd="${1:-}"
shift || true

case "$cmd" in
  create)
    [[ "$#" -eq 4 ]] || usage
    run_dir="$1"; project_id="$2"; fingerprint="$3"; commit_sha="$4"
    mkdir -p "$run_dir"
    jq -n --arg project "$project_id" --arg fp "$fingerprint" --arg sha "$commit_sha" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{version:1, projectId:$project, fingerprint:$fp, commitSha:$sha, generatedAt:$generated, deterministicChecks:null, qaVerdict:null, finalReviewVerdict:null, githubSha:null, vercelSha:null, notionSha:null, evidence:{}}' \
      > "$run_dir/manifest.json"
    echo "$run_dir/manifest.json"
    ;;
  verify)
    [[ "$#" -eq 1 && -f "$1" ]] || usage
    jq -e '(.version == 1) and (.projectId | type == "string") and (.fingerprint | type == "string") and (.commitSha | type == "string") and (.deterministicChecks == "PASS") and (.qaVerdict == "PASS") and (.finalReviewVerdict == "PASS") and (.githubSha == .commitSha) and (.vercelSha == .commitSha) and (.notionSha == .commitSha)' "$1" >/dev/null
    echo "manifest verified"
    ;;
  create-team-handoff)
    [[ "$#" -eq 4 ]] || usage
    run_dir="$1"; project_id="$2"; fingerprint="$3"; commit_sha="$4"
    mkdir -p "$run_dir"
    team_mode_file="$run_dir/team-mode.json"
    if [[ ! -f "$team_mode_file" ]]; then
      echo "team-mode.json not found at $team_mode_file; dispatch.sh must run first" >&2
      exit 3
    fi
    jq -n --arg project "$project_id" --arg fp "$fingerprint" --arg sha "$commit_sha" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --slurpfile tm "$team_mode_file" \
      '{
        schemaVersion: 2,
        version: 1,
        projectId: $project,
        fingerprint: $fp,
        commitSha: $sha,
        generatedAt: $generated,
        developerTeam: ($tm[0] // {}),
        changedFiles: [],
        checks: [],
        findings: [],
        unresolvedRisks: []
      }' > "$run_dir/handoff.json"
    echo "$run_dir/handoff.json"
    ;;
  verify-team-handoff)
    [[ "$#" -eq 1 && -f "$1" ]] || usage
    manifest_version_for_team_evidence="$(jq -r '.developerTeam.manifestVersionForTeamEvidence // 2' "$config")"
    # Contract invariants enforced here:
    #   - writesWorkspace=true is allowed only for implementation-owner /
    #     integration-coordinator; inspectors and reviewers must be
    #     read-only with no exemption by name.
    #   - Every reviewer must be strictly read-only: writesWorkspace=false
    #     AND isolatedReadOnly=true. There is no name-based exemption.
    #   - Every check entry must carry an outputRef string so evidence
    #     can be retrieved without re-running the command.
    #   - Ownership across roles must be disjoint. Inspector must own
    #     nothing. Reviewer ownership (if declared) must be empty.
    jq -e --argjson mfv "$manifest_version_for_team_evidence" '
      def arr_nonempty: type == "array" and length > 0;
      def valid_check:
        (has("command") and (.command | type == "string"))
        and (has("exitCode") and (.exitCode | type == "number"))
        and (has("outputRef") and (.outputRef | type == "string") and (.outputRef | length > 0));

      (.schemaVersion == 2)
      and (.developerTeam.selectedMode | type == "string")
      and (.developerTeam.roster | arr_nonempty)
      and (.developerTeam.reviewers | arr_nonempty)
      and ([.developerTeam.roster[] | select(.writesWorkspace == true)] | length > 0)
      and (
        [.developerTeam.roster[]
          | select(.writesWorkspace == true)
          | (.name == "implementation-owner" or .name == "integration-coordinator")
        ] | all
      )
      and (
        [.developerTeam.roster[]
          | select(.name == "edge-case-inspector" and .writesWorkspace == false)
        ] | any
      )
      # Reviewer isolation: every reviewer must be read-only AND isolated.
      and (
        (.developerTeam.reviewers | length)
        == ([.developerTeam.reviewers[]
              | select(.writesWorkspace == false and .isolatedReadOnly == true)
            ] | length)
      )
      # Inspector writesWorkspace must be false AND ownership empty.
      and (
        [.developerTeam.roster[]
          | select(.name == "edge-case-inspector"
                   and (.writesWorkspace == true
                        or ((.ownedPaths // []) | length > 0)))
        ] | length == 0
      )
      and (
        .developerTeam.selectedMode != "concurrent"
        or (.developerTeam.fallbackReason == null)
      )
      and (
        .developerTeam.selectedMode == "concurrent"
        or ((.developerTeam.fallbackReason // "") | length > 0)
      )
      and (.changedFiles | arr_nonempty)
      and (.checks | arr_nonempty)
      and ((.checks | length) == ([.checks[] | select(valid_check)] | length))
      and (.findings | type == "array")
      and (.unresolvedRisks | type == "array")
      # Ownership disjointness across roles when ownership is provided.
      # Direct pairwise overlap check (avoids jq helper-function quirks).
      and (
        (.ownership // null) == null
        or (
          (.ownership | type == "object")
          and (
            ([.ownership["implementation-owner"] // []] | flatten | unique) as $a
            | ([.ownership["edge-case-inspector"] // []] | flatten | unique) as $b
            | ([.ownership["integration-coordinator"] // []] | flatten | unique) as $c
            | ([.reviewerOwnership // {} | to_entries[] | .value] | flatten | unique) as $r
            | ([$a[] | select(. as $x | any($b[]; . == $x))] | length) == 0
              and ([$a[] | select(. as $x | any($c[]; . == $x))] | length) == 0
              and ([$a[] | select(. as $x | any($r[]; . == $x))] | length) == 0
              and ([$b[] | select(. as $x | any($c[]; . == $x))] | length) == 0
              and ([$b[] | select(. as $x | any($r[]; . == $x))] | length) == 0
              and ([$c[] | select(. as $x | any($r[]; . == $x))] | length) == 0
          )
        )
      )
    ' "$1" >/dev/null
    echo "team handoff verified"
    ;;
  *) usage ;;
esac

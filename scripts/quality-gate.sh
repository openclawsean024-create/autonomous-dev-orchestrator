#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v jq >/dev/null 2>&1 || {
  echo "quality gate requires jq" >&2
  exit 2
}

config="$project_root/config/orchestrator.json"
jq empty "$config"

# ------------------------------------------------------------------
# Existing fallback / release / takeover invariants
# ------------------------------------------------------------------
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

# ------------------------------------------------------------------
# MiniMax Agent Team contract invariants
# ------------------------------------------------------------------
team_block="$(jq -c '.developerTeam' "$config")"
[[ "$team_block" != "null" ]] || {
  echo "policy invariant failed: developerTeam contract missing" >&2
  exit 1
}

[[ "$(jq -r '.developerTeam.preferredMode' "$config")" == "concurrent" ]] || {
  echo "policy invariant failed: developerTeam.preferredMode must be 'concurrent'" >&2
  exit 1
}
[[ "$(jq -r '.developerTeam.fallbackMode' "$config")" == "sequential-focused-subagents" ]] || {
  echo "policy invariant failed: developerTeam.fallbackMode must be 'sequential-focused-subagents'" >&2
  exit 1
}
[[ "$(jq -r '.developerTeam.requireFallbackReason' "$config")" == "true" ]] || {
  echo "policy invariant failed: developerTeam.requireFallbackReason must be true" >&2
  exit 1
}
[[ "$(jq -r '.developerTeam.singleWriterInvariant' "$config")" == "true" ]] || {
  echo "policy invariant failed: developerTeam.singleWriterInvariant must be true" >&2
  exit 1
}
[[ "$(jq -r '.developerTeam.disjointOwnershipRequired' "$config")" == "true" ]] || {
  echo "policy invariant failed: developerTeam.disjointOwnershipRequired must be true" >&2
  exit 1
}
[[ "$(jq -r '.developerTeam.reviewersAreReadOnly' "$config")" == "true" ]] || {
  echo "policy invariant failed: developerTeam.reviewersAreReadOnly must be true" >&2
  exit 1
}
[[ "$(jq -r '.developerTeam.manifestVersionForTeamEvidence' "$config")" == "2" ]] || {
  echo "policy invariant failed: developerTeam.manifestVersionForTeamEvidence must be 2" >&2
  exit 1
}

# Roster structure: must include implementation-owner, edge-case-inspector,
# integration-coordinator, and must keep reviewers read-only.
jq -e '
  (.developerTeam.roles | map(.name) | contains(["implementation-owner"]))
  and (.developerTeam.roles | map(.name) | contains(["edge-case-inspector"]))
  and (.developerTeam.roles | map(.name) | contains(["integration-coordinator"]))
  and ([.developerTeam.roles[] | select(.name == "implementation-owner" and .writesWorkspace == true and .canPush == false)] | length == 1)
  and ([.developerTeam.roles[] | select(.name == "edge-case-inspector" and .writesWorkspace == false)] | length == 1)
  and ([.developerTeam.roles[] | select(.name == "integration-coordinator" and .writesWorkspace == true and .integrationOwnedOnly == true and .canPush == false)] | length == 1)
  and ([.developerTeam.reviewers[] | select(.writesWorkspace == false and (.isolatedReadOnly == true))] | length >= 1)
' "$config" >/dev/null || {
  echo "policy invariant failed: developerTeam roster / reviewer structure invalid" >&2
  exit 1
}

# Only one writesWorkspace=true role is the implementation-owner outside of
# integration-owned paths; integration-coordinator may also write but only to
# integration-owned paths. Inspectors and reviewers must NEVER be writers.
writer_role_count="$(jq '[.developerTeam.roles[] | select(.writesWorkspace == true)] | length' "$config")"
[[ "$writer_role_count" -ge 1 && "$writer_role_count" -le 2 ]] || {
  echo "policy invariant failed: developerTeam writer-role count out of bounds" >&2
  exit 1
}

# Inspector must NEVER have writesWorkspace=true
if jq -e '.developerTeam.roles[] | select(.name == "edge-case-inspector" and .writesWorkspace == true)' "$config" >/dev/null; then
  echo "policy invariant failed: edge-case-inspector must not write workspace" >&2
  exit 1
fi

# Reviewers must NEVER write workspace or push
if jq -e '.developerTeam.reviewers[] | select(.writesWorkspace == true)' "$config" >/dev/null; then
  echo "policy invariant failed: reviewers must not write workspace" >&2
  exit 1
fi
if jq -e '.developerTeam.reviewers[] | select(.canPush == true)' "$config" >/dev/null; then
  echo "policy invariant failed: reviewers must not be allowed to push" >&2
  exit 1
fi

# Reviewers must ALWAYS be isolatedReadOnly. No name-based exemptions.
if [[ "$(jq '[.developerTeam.reviewers[] | select(.isolatedReadOnly == true)] | length' "$config")" != "$(jq '.developerTeam.reviewers | length' "$config")" ]]; then
  echo "policy invariant failed: every reviewer must be isolatedReadOnly" >&2
  exit 1
fi

# Ownership disjointness: implementation-owner, edge-case-inspector,
# integration-coordinator, and reviewerOwnership must all be pairwise
# disjoint. Inspector ownership must be empty.
ownership="$(jq -c '.developerTeam.ownership // {}' "$config")"
reviewer_ownership="$(jq -c '.developerTeam.reviewerOwnership // {}' "$config")"
if [[ "$ownership" != "{}" ]]; then
  owner_paths="$(jq -c '.developerTeam.ownership["implementation-owner"] // []' "$config")"
  inspector_paths="$(jq -c '.developerTeam.ownership["edge-case-inspector"] // []' "$config")"
  coord_paths="$(jq -c '.developerTeam.ownership["integration-coordinator"] // []' "$config")"
  reviewer_paths_combined="$(jq -c '[.developerTeam.reviewerOwnership // {} | to_entries[] | .value] | flatten | unique' "$config")"
  if [[ "$(echo "$inspector_paths" | jq 'length')" != "0" ]]; then
    echo "policy invariant failed: edge-case-inspector must have empty ownership" >&2
    exit 1
  fi
  for pair in "owner:inspector" "owner:coord" "owner:reviewer" "inspector:coord" "inspector:reviewer" "coord:reviewer"; do
    a="${pair%%:*}"; b="${pair##*:}"
    case "$a" in
      owner) va="$owner_paths" ;;
      inspector) va="$inspector_paths" ;;
      coord) va="$coord_paths" ;;
      reviewer) va="$reviewer_paths_combined" ;;
    esac
    case "$b" in
      owner) vb="$owner_paths" ;;
      inspector) vb="$inspector_paths" ;;
      coord) vb="$coord_paths" ;;
      reviewer) vb="$reviewer_paths_combined" ;;
    esac
    # Skip if either side is empty.
    if [[ "$(echo "$va" | jq 'length')" == "0" || "$(echo "$vb" | jq 'length')" == "0" ]]; then
      continue
    fi
    overlap="$(jq -n --argjson a "$va" --argjson b "$vb" '[$a[] | select(. as $x | $b | index($x))] | length')"
    if [[ "$overlap" != "0" ]]; then
      echo "policy invariant failed: ownership overlap between $a and $b ($overlap path(s))" >&2
      exit 1
    fi
  done
fi

bash "$project_root/tests/policy-test.sh"
bash "$project_root/tests/orchestrator-test.sh"
echo "quality gate passed"

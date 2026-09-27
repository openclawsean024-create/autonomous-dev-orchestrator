#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "manifest requires jq" >&2; exit 2; }

case "${1:-}" in
  create)
    [[ "$#" -eq 5 ]] || { echo "Usage: $0 create <run-dir> <project-id> <fingerprint> <commit-sha>" >&2; exit 2; }
    run_dir="$2"; project_id="$3"; fingerprint="$4"; commit_sha="$5"
    mkdir -p "$run_dir"
    jq -n --arg project "$project_id" --arg fp "$fingerprint" --arg sha "$commit_sha" \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{version:1, projectId:$project, fingerprint:$fp, commitSha:$sha, generatedAt:$generated, deterministicChecks:null, qaVerdict:null, finalReviewVerdict:null, githubSha:null, vercelSha:null, notionSha:null, evidence:{}}' \
      > "$run_dir/manifest.json"
    echo "$run_dir/manifest.json"
    ;;
  verify)
    [[ "$#" -eq 2 && -f "$2" ]] || { echo "Usage: $0 verify <manifest.json>" >&2; exit 2; }
    jq -e '(.version == 1) and (.projectId | type == "string") and (.fingerprint | type == "string") and (.commitSha | type == "string") and (.deterministicChecks == "PASS") and (.qaVerdict == "PASS") and (.finalReviewVerdict == "PASS") and (.githubSha == .commitSha) and (.vercelSha == .commitSha) and (.notionSha == .commitSha)' "$2" >/dev/null
    echo "manifest verified"
    ;;
  *)
    echo "Usage: $0 {create|verify} ..." >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
owner="${GITHUB_OWNER:-openclawsean024-create}"

usage() {
  echo "Usage: $0 preflight <manifest.json> | push <repo> <branch> | pr <repo> <branch> | merge <repo> <pr-number> | deploy <repo> <sha> | deploy-cli <project-dir> <sha> | smoke <url> [seconds] | rollback <deployment>" >&2
  exit 2
}

require_clean_repo() {
  git -C "$1" diff --quiet && git -C "$1" diff --cached --quiet || { echo "repository has uncommitted changes" >&2; exit 1; }
}

case "${1:-}" in
  preflight)
    [[ "$#" -eq 2 && -f "$2" ]] || usage
    jq -e '(.deterministicChecks == "PASS") and (.qaVerdict == "PASS") and (.finalReviewVerdict == "PASS") and (.githubSha == .commitSha) and (.vercelSha == .commitSha) and (.notionSha == .commitSha)' "$2" >/dev/null || {
      echo "release gate failed: manifest is not fully aligned" >&2
      exit 1
    }
    echo "release preflight passed"
    ;;
  push)
    [[ "$#" -eq 3 ]] || usage
    command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 2; }
    require_clean_repo "$2"
    git -C "$2" push origin "$3"
    ;;
  pr)
    [[ "$#" -eq 3 ]] || usage
    command -v gh >/dev/null 2>&1 || { echo "gh CLI is required for automatic PR creation" >&2; exit 2; }
    gh pr create --repo "$owner/$2" --head "$3" --base main --fill
    ;;
  merge)
    [[ "$#" -eq 3 ]] || usage
    command -v gh >/dev/null 2>&1 || { echo "gh CLI is required for automatic merge" >&2; exit 2; }
    gh pr merge "$3" --repo "$owner/$2" --auto --squash --delete-branch
    ;;
  deploy)
    [[ "$#" -eq 3 ]] || usage
    command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
    [[ -n "${VERCEL_TOKEN:-}" && -n "${VERCEL_PROJECT_ID:-}" ]] || { echo "VERCEL_TOKEN and VERCEL_PROJECT_ID are required" >&2; exit 2; }
    payload="$(jq -n --arg name "$2" --arg owner "$owner" --arg sha "$3" '{name:$name,target:"production",gitSource:{type:"github",org:$owner,repo:$name,ref:"main",sha:$sha}}')"
    curl -fsS -X POST "https://api.vercel.com/v13/deployments?projectId=${VERCEL_PROJECT_ID}" \
      -H "Authorization: Bearer ${VERCEL_TOKEN}" -H 'Content-Type: application/json' -d "$payload" | jq '{id,url,readyState,gitSource}'
    ;;
  deploy-cli)
    [[ "$#" -eq 3 && -d "$2" ]] || usage
    command -v npx >/dev/null 2>&1 || { echo "npx is required" >&2; exit 2; }
    actual_sha="$(git -C "$2" rev-parse HEAD)"
    [[ "$actual_sha" == "$3" ]] || { echo "deploy-cli refused: project HEAD is ${actual_sha}, expected ${3}" >&2; exit 1; }
    (cd "$2" && npx --yes vercel deploy --prod --yes --meta "gitCommitSha=${3}" --json) | jq '{id,url,readyState,target,meta}'
    ;;
  smoke)
    [[ "$#" -ge 2 && "$#" -le 3 ]] || usage
    seconds="${3:-60}"
    deadline=$(( $(date +%s) + seconds ))
    while (( $(date +%s) <= deadline )); do
      code="$(curl -L -sS -o /dev/null -w '%{http_code}' "$2" || true)"
      [[ "$code" == "200" ]] && { echo "smoke PASS HTTP 200"; exit 0; }
      sleep 5
    done
    echo "smoke FAIL: production did not return HTTP 200 within ${seconds}s" >&2
    exit 1
    ;;
  rollback)
    [[ "$#" -eq 2 ]] || usage
    command -v vercel >/dev/null 2>&1 || { echo "vercel CLI is required for rollback" >&2; exit 2; }
    vercel rollback "$2" --yes
    ;;
  *) usage ;;
esac

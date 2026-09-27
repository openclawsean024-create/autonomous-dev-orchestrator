#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || { echo "FAIL: $label expected=$expected actual=$actual" >&2; exit 1; }
  echo "PASS: $label"
}

fingerprint="$(bash "$root/scripts/fingerprint.sh" page-1 spec-v1 'implement adapters' 0 ac-hash)"
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: fingerprint format" >&2; exit 1; }
echo "PASS: fingerprint format"

state="$tmp/state"
run_id="$(ORCHESTRATOR_STATE_DIR="$state" bash "$root/scripts/run-registry.sh" start page-1 "$fingerprint" /tmp/repo)"
[[ "$run_id" == run-* ]] || { echo "FAIL: run id" >&2; exit 1; }
echo "PASS: run registry start"

if ORCHESTRATOR_STATE_DIR="$state" bash "$root/scripts/run-registry.sh" start page-1 "$fingerprint" /tmp/repo >/dev/null 2>/dev/null; then
  echo "FAIL: duplicate lease was accepted" >&2
  exit 1
fi
echo "PASS: duplicate lease rejected"

for expected in 1 2 3; do
  actual="$(ORCHESTRATOR_STATE_DIR="$state" bash "$root/scripts/run-registry.sh" minimax-failure "$run_id")"
  assert_eq "$expected" "$actual" "MiniMax failure count $expected"
done
assert_eq "chatgpt_takeover" "$(ORCHESTRATOR_STATE_DIR="$state" bash "$root/scripts/run-registry.sh" takeover "$run_id")" "ChatGPT takeover gate"
ORCHESTRATOR_STATE_DIR="$state" bash "$root/scripts/run-registry.sh" finish "$run_id" completed
assert_eq "completed" "$(ORCHESTRATOR_STATE_DIR="$state" bash "$root/scripts/run-registry.sh" show | jq -r --arg id "$run_id" '.runs[] | select(.id == $id) | .status')" "terminal completion"

snapshot="$tmp/snapshot.json"
cat > "$snapshot" <<'EOF'
{"projects":[
  {"page_id":"ready","name":"ready","status":"開發中","spec_url":"https://spec","github_url":"https://github","local_repo":"/tmp/repo","open_issues":0,"prod_http":200},
  {"page_id":"blocked","name":"blocked","status":"開發中","spec_url":"https://spec","github_url":"https://github","local_repo":"/tmp/repo","open_issues":3,"prod_http":200},
  {"page_id":"terminal","name":"terminal","status":"已上線","spec_url":"https://spec","github_url":"https://github","local_repo":"/tmp/repo","open_issues":0,"prod_http":200},
  {"page_id":"nospec","name":"nospec","status":"開發中","github_url":"https://github","local_repo":"/tmp/repo","open_issues":0,"prod_http":200}
]}
EOF
patrol_output="$(bash "$root/scripts/patrol.sh" "$snapshot")"
assert_eq "ready_to_dev" "$(printf '%s' "$patrol_output" | jq -r '.projects[] | select(.page_id == "ready") | .classification')" "patrol ready classification"
assert_eq "blocked" "$(printf '%s' "$patrol_output" | jq -r '.projects[] | select(.page_id == "blocked") | .classification')" "patrol blocker classification"
assert_eq "terminal" "$(printf '%s' "$patrol_output" | jq -r '.projects[] | select(.page_id == "terminal") | .classification')" "patrol terminal classification"
assert_eq "no_spec" "$(printf '%s' "$patrol_output" | jq -r '.projects[] | select(.page_id == "nospec") | .classification')" "patrol missing spec classification"

manifest="$tmp/run"
manifest_path="$(bash "$root/scripts/manifest.sh" create "$manifest" page-1 "$fingerprint" abc123)"
if bash "$root/scripts/manifest.sh" verify "$manifest_path" >/dev/null 2>&1; then
  echo "FAIL: incomplete manifest was accepted" >&2
  exit 1
fi
echo "PASS: incomplete manifest rejected"
jq '.deterministicChecks="PASS" | .qaVerdict="PASS" | .finalReviewVerdict="PASS" | .githubSha=.commitSha | .vercelSha=.commitSha | .notionSha=.commitSha' "$manifest_path" > "$manifest_path.tmp"
mv "$manifest_path.tmp" "$manifest_path"
assert_eq "manifest verified" "$(bash "$root/scripts/manifest.sh" verify "$manifest_path")" "complete manifest accepted"

assert_eq "release preflight passed" "$(bash "$root/scripts/release.sh" preflight "$manifest_path")" "release preflight accepts aligned manifest"

dispatch_output="$(bash "$root/scripts/dispatch.sh" --dry-run page-1 "$fingerprint" "$root" "$root/PRD/SPEC.md")"
assert_eq "chatgpt-takeover" "$(printf '%s' "$dispatch_output" | jq -r '.sequence[3]')" "dispatch exposes ChatGPT takeover as fourth stage"
assert_eq "3" "$(printf '%s' "$dispatch_output" | jq -r '.maxMinimaxCycles | tostring')" "dispatch exposes three MiniMax cycles"

echo "orchestrator tests passed"

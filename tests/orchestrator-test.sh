#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="$root/config/orchestrator.json"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || { echo "FAIL: $label expected=$expected actual=$actual" >&2; exit 1; }
  echo "PASS: $label"
}

# ------------------------------------------------------------------
# Existing regression coverage: 3-cycle MiniMax, 1 ChatGPT takeover,
# active-lease dedup, fingerprint stability, patrol classifications,
# manifest / release / dispatch dry-run shape.
# ------------------------------------------------------------------
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

# ------------------------------------------------------------------
# MiniMax Agent Team contract coverage
# ------------------------------------------------------------------

# 1) Dry-run dispatch must include team roster + preferred/fallback mode.
dispatch_output="$(bash "$root/scripts/dispatch.sh" --dry-run page-1 "$fingerprint" "$root" "$root/PRD/SPEC.md")"
assert_eq "chatgpt-takeover" "$(printf '%s' "$dispatch_output" | jq -r '.sequence[3]')" "dispatch exposes ChatGPT takeover as fourth stage"
assert_eq "3" "$(printf '%s' "$dispatch_output" | jq -r '.maxMinimaxCycles | tostring')" "dispatch exposes three MiniMax cycles"
assert_eq "concurrent" "$(printf '%s' "$dispatch_output" | jq -r '.developerTeam.preferredMode')" "dispatch exposes preferred concurrent mode"
assert_eq "sequential-focused-subagents" "$(printf '%s' "$dispatch_output" | jq -r '.developerTeam.fallbackMode')" "dispatch exposes sequential-focused-subagents fallback"
assert_eq "3" "$(printf '%s' "$dispatch_output" | jq -r '[.sequence[] | select(startswith("minimax-cycle-"))] | length | tostring')" "dry-run still has three MiniMax cycles before ChatGPT takeover"
roster_names="$(printf '%s' "$dispatch_output" | jq -r '.developerTeam.roster[].name' | sort | tr '\n' ',' | sed 's/,$//')"
assert_eq "edge-case-inspector,implementation-owner,integration-coordinator" "$roster_names" "dispatch roster includes required roles"

# 2) Capability gate: without a probe, dispatch must select fallback and
#    record a non-empty fallbackReason in dry-run output too.
unset ORCHESTRATOR_AGENT_TEAM_CAPABLE
probe_root="$tmp/dispatch-state"
mkdir -p "$probe_root"
fallback_output="$(ORCHESTRATOR_STATE_DIR="$probe_root" bash "$root/scripts/dispatch.sh" --dry-run page-1 "$fingerprint" "$root" "$root/PRD/SPEC.md")"
assert_eq "sequential-focused-subagents" "$(printf '%s' "$fallback_output" | jq -r '.developerTeam.selectedMode')" "fallback selected when capability unconfirmed"
fallback_reason="$(printf '%s' "$fallback_output" | jq -r '.developerTeam.fallbackReason')"
[[ -n "$fallback_reason" && "$fallback_reason" != "null" ]] || { echo "FAIL: fallbackReason required when in fallback mode" >&2; exit 1; }
echo "PASS: fallbackReason populated"

# 3) Capability probe via state file forces concurrent mode.
echo '{"agentTeamConcurrent": true}' > "$probe_root/mcode-capabilities.json"
concurrent_output="$(ORCHESTRATOR_STATE_DIR="$probe_root" bash "$root/scripts/dispatch.sh" --dry-run page-1 "$fingerprint" "$root" "$root/PRD/SPEC.md")"
assert_eq "concurrent" "$(printf '%s' "$concurrent_output" | jq -r '.developerTeam.selectedMode')" "concurrent selected when capability probe asserts"
assert_eq "capabilities_file" "$(printf '%s' "$concurrent_output" | jq -r '.developerTeam.capabilitySource')" "capability source recorded"

# 4) Capability probe via env override forces concurrent mode.
concurrent_env="$(ORCHESTRATOR_AGENT_TEAM_CAPABLE=1 bash "$root/scripts/dispatch.sh" --dry-run page-1 "$fingerprint" "$root" "$root/PRD/SPEC.md")"
assert_eq "concurrent" "$(printf '%s' "$concurrent_env" | jq -r '.developerTeam.selectedMode')" "concurrent selected via env override"
assert_eq "env_override" "$(printf '%s' "$concurrent_env" | jq -r '.developerTeam.capabilitySource')" "env override source recorded"

# ------------------------------------------------------------------
# Team handoff evidence: create-team-handoff / verify-team-handoff
# ------------------------------------------------------------------
handoff_root="$tmp/handoff"
mkdir -p "$handoff_root"

# Build a team-mode.json that matches what dispatch.sh writes (concurrent, no
# fallbackReason required) so we can drive create-team-handoff.
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"integration-coordinator", writesWorkspace:true, integrationOwnedOnly:true, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"codex-qa", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"},
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$handoff_root/team-mode.json"

handoff_path="$(bash "$root/scripts/manifest.sh" create-team-handoff "$handoff_root" page-1 "$fingerprint" abc123)"
[[ -f "$handoff_path" ]] || { echo "FAIL: create-team-handoff did not produce a file" >&2; exit 1; }
echo "PASS: create-team-handoff produced handoff.json"

# 4a) Empty handoff must NOT verify.
if bash "$root/scripts/manifest.sh" verify-team-handoff "$handoff_path" >/dev/null 2>&1; then
  echo "FAIL: empty team handoff was accepted" >&2
  exit 1
fi
echo "PASS: empty team handoff rejected"

# 4b) Valid concurrent handoff fixture must verify.
jq '
  .changedFiles = ["scripts/foo.sh", "tests/foo-test.sh"]
  | .checks = [
      {command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"},
      {command:"bash tests/orchestrator-test.sh", exitCode:0, outputRef:"orchestrator-test.log"}
    ]
  | .findings = [
      "implementation-owner: implemented disjoint file set",
      "edge-case-inspector: enumerated 3 missing tests, no write access used"
    ]
  | .unresolvedRisks = [
      "mcode Agent Team concurrency invocation flags not yet confirmed in CI"
    ]
' "$handoff_path" > "$handoff_path.tmp"
mv "$handoff_path.tmp" "$handoff_path"
assert_eq "team handoff verified" "$(bash "$root/scripts/manifest.sh" verify-team-handoff "$handoff_path")" "valid concurrent handoff accepted"

# 4c) Fallback fixture: sequential-focused-subagents MUST require a
#     fallbackReason.
fallback_root="$tmp/handoff-fallback"
mkdir -p "$fallback_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "sequential-focused-subagents",
    fallbackReason: "cli_capability_unconfirmed_in_this_environment",
    capabilitySource: "unconfirmed",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$fallback_root/team-mode.json"

fallback_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$fallback_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = ["inspector: documented missing concurrent CLI probe"]
  | .unresolvedRisks = ["fallback path used pending CLI capability confirmation"]
' "$fallback_handoff" > "$fallback_handoff.tmp"
mv "$fallback_handoff.tmp" "$fallback_handoff"
assert_eq "team handoff verified" "$(bash "$root/scripts/manifest.sh" verify-team-handoff "$fallback_handoff")" "valid fallback handoff accepted"

# 4d) Missing fallbackReason in fallback mode must FAIL.
broken_root="$tmp/handoff-broken"
mkdir -p "$broken_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "sequential-focused-subagents",
    fallbackReason: null,
    capabilitySource: "unconfirmed",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$broken_root/team-mode.json"
broken_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$broken_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
' "$broken_handoff" > "$broken_handoff.tmp"
mv "$broken_handoff.tmp" "$broken_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$broken_handoff" >/dev/null 2>&1; then
  echo "FAIL: missing fallbackReason in fallback mode was accepted" >&2
  exit 1
fi
echo "PASS: missing fallbackReason in fallback mode rejected"

# 4e) Inspector writesWorkspace=true must FAIL the contract.
inv_root="$tmp/handoff-inspector-writes"
mkdir -p "$inv_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$inv_root/team-mode.json"
inv_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$inv_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
' "$inv_handoff" > "$inv_handoff.tmp"
mv "$inv_handoff.tmp" "$inv_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$inv_handoff" >/dev/null 2>&1; then
  echo "FAIL: inspector with writesWorkspace=true was accepted" >&2
  exit 1
fi
echo "PASS: inspector writesWorkspace=true rejected"

# 4f) Reviewer marked as writer must FAIL the contract.
inv2_root="$tmp/handoff-reviewer-writes"
mkdir -p "$inv2_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:true, isolatedReadOnly:false, harness:"codex"}
    ]
  }
' > "$inv2_root/team-mode.json"
inv2_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$inv2_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
' "$inv2_handoff" > "$inv2_handoff.tmp"
mv "$inv2_handoff.tmp" "$inv2_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$inv2_handoff" >/dev/null 2>&1; then
  echo "FAIL: reviewer marked writesWorkspace=true was accepted" >&2
  exit 1
fi
echo "PASS: reviewer writesWorkspace=true rejected"

# 4g) Evidence failure: missing checks / changedFiles / findings must FAIL.
empty_root="$tmp/handoff-empty-evidence"
mkdir -p "$empty_root"
cp "$handoff_root/team-mode.json" "$empty_root/team-mode.json"
empty_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$empty_root" page-1 "$fingerprint" abc123)"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$empty_handoff" >/dev/null 2>&1; then
  echo "FAIL: handoff with empty checks/changedFiles was accepted" >&2
  exit 1
fi
echo "PASS: empty evidence fields rejected"

# 4h) Checks must include command + numeric exitCode for every entry.
malformed_root="$tmp/handoff-malformed-checks"
mkdir -p "$malformed_root"
cp "$handoff_root/team-mode.json" "$malformed_root/team-mode.json"
malformed_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$malformed_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh"}]
  | .findings = []
  | .unresolvedRisks = []
' "$malformed_handoff" > "$malformed_handoff.tmp"
mv "$malformed_handoff.tmp" "$malformed_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$malformed_handoff" >/dev/null 2>&1; then
  echo "FAIL: malformed check entry (missing exitCode) was accepted" >&2
  exit 1
fi
echo "PASS: malformed check entry rejected"

# 4i) Checks missing outputRef must FAIL.
noref_root="$tmp/handoff-no-outputref"
mkdir -p "$noref_root"
cp "$handoff_root/team-mode.json" "$noref_root/team-mode.json"
noref_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$noref_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0}]
  | .findings = []
  | .unresolvedRisks = []
' "$noref_handoff" > "$noref_handoff.tmp"
mv "$noref_handoff.tmp" "$noref_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$noref_handoff" >/dev/null 2>&1; then
  echo "FAIL: check without outputRef was accepted" >&2
  exit 1
fi
echo "PASS: check without outputRef rejected"

# 4j) Reviewer with isolatedReadOnly=false (no name exemption) must FAIL.
strict_root="$tmp/handoff-strict-reviewer"
mkdir -p "$strict_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:false, harness:"codex"}
    ]
  }
' > "$strict_root/team-mode.json"
strict_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$strict_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
' "$strict_handoff" > "$strict_handoff.tmp"
mv "$strict_handoff.tmp" "$strict_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$strict_handoff" >/dev/null 2>&1; then
  echo "FAIL: reviewer with isolatedReadOnly=false was accepted (name-based exemption)" >&2
  exit 1
fi
echo "PASS: reviewer with isolatedReadOnly=false rejected"

# 4k) Inspector must not own any paths.
owninv_root="$tmp/handoff-inspector-owns"
mkdir -p "$owninv_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    ownership: {
      "implementation-owner": ["src/**"],
      "edge-case-inspector": ["tests/**"],
      "integration-coordinator": [".agent/**"]
    },
    reviewerOwnership: {},
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code", ownedPaths:["tests/**"]}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$owninv_root/team-mode.json"
owninv_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$owninv_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
' "$owninv_handoff" > "$owninv_handoff.tmp"
mv "$owninv_handoff.tmp" "$owninv_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$owninv_handoff" >/dev/null 2>&1; then
  echo "FAIL: inspector owning paths was accepted" >&2
  exit 1
fi
echo "PASS: inspector owning paths rejected"

# 4l) Overlapping ownership between owner and coordinator must FAIL.
overlap_root="$tmp/handoff-overlap"
mkdir -p "$overlap_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    ownership: {
      "implementation-owner": ["scripts/**", "tests/**"],
      "edge-case-inspector": [],
      "integration-coordinator": ["tests/**"]
    },
    reviewerOwnership: {},
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"integration-coordinator", writesWorkspace:true, integrationOwnedOnly:true, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$overlap_root/team-mode.json"
overlap_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$overlap_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
  | .ownership = {
      "implementation-owner": ["scripts/**", "tests/**"],
      "edge-case-inspector": [],
      "integration-coordinator": ["tests/**"]
    }
  | .reviewerOwnership = {}
' "$overlap_handoff" > "$overlap_handoff.tmp"
mv "$overlap_handoff.tmp" "$overlap_handoff"
if bash "$root/scripts/manifest.sh" verify-team-handoff "$overlap_handoff" >/dev/null 2>&1; then
  echo "FAIL: overlapping ownership was accepted" >&2
  exit 1
fi
echo "PASS: overlapping ownership rejected"

# 4m) Disjoint ownership in handoff must verify.
disjoint_root="$tmp/handoff-disjoint"
mkdir -p "$disjoint_root"
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    ownership: {
      "implementation-owner": ["scripts/**", "tests/**"],
      "edge-case-inspector": [],
      "integration-coordinator": [".agent/**"]
    },
    reviewerOwnership: {},
    roster: [
      {name:"implementation-owner", writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"integration-coordinator", writesWorkspace:true, integrationOwnedOnly:true, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$disjoint_root/team-mode.json"
disjoint_handoff="$(bash "$root/scripts/manifest.sh" create-team-handoff "$disjoint_root" page-1 "$fingerprint" abc123)"
jq '
  .changedFiles = ["AGENTS.md"]
  | .checks = [{command:"bash scripts/quality-gate.sh", exitCode:0, outputRef:"quality-gate.log"}]
  | .findings = []
  | .unresolvedRisks = []
  | .ownership = {
      "implementation-owner": ["scripts/**", "tests/**"],
      "edge-case-inspector": [],
      "integration-coordinator": [".agent/**"]
    }
  | .reviewerOwnership = {}
' "$disjoint_handoff" > "$disjoint_handoff.tmp"
mv "$disjoint_handoff.tmp" "$disjoint_handoff"
assert_eq "team handoff verified" "$(bash "$root/scripts/manifest.sh" verify-team-handoff "$disjoint_handoff")" "disjoint ownership handoff accepted"

# ------------------------------------------------------------------
# Final invariant: orchestrator config still pins MiniMax to 3 cycles and
# ChatGPT to a single takeover.
# ------------------------------------------------------------------
assert_eq "3" "$(jq -r '.dispatch.maxMinimaxImplementationCycles' "$config")" "config still pins MiniMax to 3 cycles"
assert_eq "1" "$(jq -r '.dispatch.maxChatgptTakeovers' "$config")" "config still pins ChatGPT to 1 takeover"

# ------------------------------------------------------------------
# team-exec.sh actually executes the team and populates the handoff.
# The repo fixture lives under the test's mktemp -d temp dir so the
# workspace's .tmp/ directory is not polluted by test artefacts. The
# trap at the top of this script (`rm -rf "$tmp"`) cleans up the
# fixture automatically when the test exits.
# ------------------------------------------------------------------
teamx_root_under_tmp="$tmp/team-exec-fixture"
mkdir -p "$teamx_root_under_tmp"
teamx_repo="$teamx_root_under_tmp/repo"
rm -rf "$teamx_repo"
mkdir -p "$teamx_repo"
git -C "$teamx_repo" init -q -b main
git -C "$teamx_repo" config user.email "test@example.com"
git -C "$teamx_repo" config user.name "Test"
git -C "$teamx_repo" commit --allow-empty -q -m "initial"
mkdir -p "$teamx_repo/scripts"
echo "scratch" > "$teamx_repo/scripts/sample.sh"
git -C "$teamx_repo" add scripts/sample.sh
git -C "$teamx_repo" commit -q -m "owner change"
mkdir -p "$teamx_repo/.agent/evidence"
echo "evidence" > "$teamx_repo/.agent/evidence/placeholder"
git -C "$teamx_repo" add .agent/evidence/placeholder
git -C "$teamx_repo" commit -q -m "coord change"

# Leave working-tree changes uncommitted so team-exec.sh's
# `git diff --name-only` + `git ls-files --others --exclude-standard`
# surfaces real changedFiles. Without this the handoff's changedFiles
# is empty, and verify-team-handoff rejects the cycle (it requires
# `changedFiles` to be a non-empty array). This mirrors the real
# run shape: implementation-owner produces working-tree changes during
# the cycle, not after the cycle.
echo "owner-edit" >> "$teamx_repo/scripts/sample.sh"
echo "coord-edit" >> "$teamx_repo/.agent/evidence/placeholder"

teamx_root="$tmp/team-exec"
mkdir -p "$teamx_root/run"

# Concurrent mode team-mode.json
jq -n '
  {
    preferredMode: "concurrent",
    fallbackMode: "sequential-focused-subagents",
    selectedMode: "concurrent",
    fallbackReason: null,
    capabilitySource: "env_override",
    singleWriterInvariant: true,
    reviewersAreReadOnly: true,
    roster: [
      {name:"implementation-owner", enabled:true, writesWorkspace:true, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"edge-case-inspector", enabled:true, writesWorkspace:false, integrationOwnedOnly:false, canPush:false, harness:"minimax-code"},
      {name:"integration-coordinator", enabled:true, writesWorkspace:true, integrationOwnedOnly:true, canPush:false, harness:"minimax-code"}
    ],
    reviewers: [
      {name:"final-reviewer", writesWorkspace:false, isolatedReadOnly:true, harness:"codex"}
    ]
  }
' > "$teamx_root/run/team-mode.json"

# Initialise the handoff scaffold.
bash "$root/scripts/manifest.sh" create-team-handoff "$teamx_root/run" page-1 "$fingerprint" abc123 >/dev/null

# Run team-exec.sh (it operates on the real repo, so we point it at our fixture).
bash "$root/scripts/team-exec.sh" "$teamx_root/run" "$teamx_repo" >/dev/null

# Each role must have an evidence file with completionBarrier=complete.
for role in implementation-owner edge-case-inspector integration-coordinator; do
  assert_eq "complete" "$(jq -r '.completionBarrier' "$teamx_root/run/team-${role}.json")" "team-exec wrote completion barrier for $role"
  [[ "$(jq -r '.executionMode' "$teamx_root/run/team-${role}.json")" == "concurrent" ]] || {
    echo "FAIL: $role missing executionMode" >&2; exit 1
  }
  echo "PASS: $role carries executionMode"
done

# Handoff must be populated with checks that have outputRef and
# changedFiles matching the disjoint ownership boundary.
assert_eq "3" "$(jq '.checks | length' "$teamx_root/run/handoff.json")" "handoff has three per-role checks"
for ref in "$(jq -r '.checks[0].outputRef' "$teamx_root/run/handoff.json")" \
           "$(jq -r '.checks[1].outputRef' "$teamx_root/run/handoff.json")" \
           "$(jq -r '.checks[2].outputRef' "$teamx_root/run/handoff.json")"; do
  [[ -n "$ref" && "$ref" != "null" ]] || { echo "FAIL: check outputRef empty" >&2; exit 1; }
done
echo "PASS: every check carries outputRef"

assert_eq "team handoff verified" "$(bash "$root/scripts/manifest.sh" verify-team-handoff "$teamx_root/run/handoff.json")" "team-exec output passes verify-team-handoff"

# Sequential mode should also produce a populated handoff.
teamx_seq_root="$tmp/team-exec-seq"
mkdir -p "$teamx_seq_root/run"
jq '
  .selectedMode = "sequential-focused-subagents"
  | .fallbackReason = "cli_capability_unconfirmed_in_this_environment"
  | .capabilitySource = "unconfirmed"
' "$teamx_root/run/team-mode.json" > "$teamx_seq_root/run/team-mode.json"
bash "$root/scripts/manifest.sh" create-team-handoff "$teamx_seq_root/run" page-1 "$fingerprint" abc123 >/dev/null
bash "$root/scripts/team-exec.sh" "$teamx_seq_root/run" "$teamx_repo" >/dev/null
assert_eq "sequential-focused-subagents" "$(jq -r '.executionMode' "$teamx_seq_root/run/team-implementation-owner.json")" "sequential mode recorded on owner"
assert_eq "team handoff verified" "$(bash "$root/scripts/manifest.sh" verify-team-handoff "$teamx_seq_root/run/handoff.json")" "sequential team-exec output verifies"

# ------------------------------------------------------------------
# Config-level ownership disjointness: orchestrator.json must itself
# pass the same disjoint invariant when ownership is declared.
# ------------------------------------------------------------------
ownership_role_count="$(jq '.developerTeam.ownership | length' "$config")"
[[ "$ownership_role_count" -ge 3 ]] || { echo "FAIL: developerTeam.ownership missing required roles" >&2; exit 1; }
echo "PASS: config declares ownership for required roles"

inspector_paths_len="$(jq '.developerTeam.ownership["edge-case-inspector"] | length' "$config")"
assert_eq "0" "$inspector_paths_len" "config inspector owns no paths"

# Spot-check that ownership entries match the roles declared in the roster.
for role in implementation-owner edge-case-inspector integration-coordinator; do
  [[ "$(jq --arg r "$role" '.developerTeam.ownership[$r] != null' "$config")" == "true" ]] || {
    echo "FAIL: ownership entry missing for $role" >&2; exit 1
  }
done
echo "PASS: ownership entries cover required roles"

echo "orchestrator tests passed"

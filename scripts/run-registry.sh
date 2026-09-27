#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="${ORCHESTRATOR_STATE_DIR:-$root/.agent/state}"
runs_file="$state_dir/runs.json"
lease_seconds="${ORCHESTRATOR_LEASE_SECONDS:-5400}"

command -v jq >/dev/null 2>&1 || { echo "run registry requires jq" >&2; exit 2; }
[[ "$lease_seconds" =~ ^[0-9]+$ ]] || { echo "ORCHESTRATOR_LEASE_SECONDS must be an integer" >&2; exit 2; }
mkdir -p "$state_dir"
[[ -f "$runs_file" ]] || printf '%s\n' '{"runs":[]}' > "$runs_file"

acquire_lock() {
  local lock="$state_dir/.lock"
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.05; done
  LOCK_PATH="$lock"
}

release_lock() {
  [[ -n "${LOCK_PATH:-}" ]] && rmdir "$LOCK_PATH" 2>/dev/null || true
}

write_json() {
  local next="$runs_file.tmp"
  cat > "$next"
  mv -f "$next" "$runs_file"
}

now="$(date +%s)"
cmd="${1:-}"

case "$cmd" in
  start)
    [[ "$#" -eq 4 ]] || { echo "Usage: $0 start <project-id> <fingerprint> <repo>" >&2; exit 2; }
    project_id="$2"; fingerprint="$3"; repo="$4"
    acquire_lock; trap release_lock EXIT
    active_id="$(jq -r --arg p "$project_id" --arg f "$fingerprint" --argjson now "$now" \
      '.runs[] | select(.projectId == $p and .fingerprint == $f and .status == "active" and .leaseExpiresAt > $now) | .id' "$runs_file" | head -n 1)"
    if [[ -n "$active_id" ]]; then
      echo "active:$active_id" >&2
      exit 3
    fi
    run_id="run-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
    expires=$((now + lease_seconds))
    jq --arg id "$run_id" --arg p "$project_id" --arg f "$fingerprint" --arg r "$repo" \
      --argjson now "$now" --argjson expires "$expires" \
      '.runs += [{id:$id, projectId:$p, fingerprint:$f, repo:$r, status:"active", owner:"controller", minimaxCycles:0, chatgptTakeovers:0, createdAt:$now, updatedAt:$now, leaseExpiresAt:$expires}]' \
      "$runs_file" | write_json
    printf '%s\n' "$run_id"
    ;;
  heartbeat)
    [[ "$#" -eq 2 ]] || { echo "Usage: $0 heartbeat <run-id>" >&2; exit 2; }
    acquire_lock; trap release_lock EXIT
    expires=$((now + lease_seconds))
    jq -e --arg id "$2" 'any(.runs[]; .id == $id and .status == "active")' "$runs_file" >/dev/null || { echo "active run not found: $2" >&2; exit 1; }
    updated="$(jq --arg id "$2" --argjson now "$now" --argjson expires "$expires" \
      '(.runs[] | select(.id == $id and .status == "active")) |= (.updatedAt=$now | .leaseExpiresAt=$expires)' "$runs_file")"
    printf '%s\n' "$updated" | write_json
    ;;
  minimax-failure)
    [[ "$#" -eq 2 ]] || { echo "Usage: $0 minimax-failure <run-id>" >&2; exit 2; }
    acquire_lock; trap release_lock EXIT
    jq -e --arg id "$2" 'any(.runs[]; .id == $id and .status == "active")' "$runs_file" >/dev/null || { echo "active run not found: $2" >&2; exit 1; }
    updated="$(jq --arg id "$2" --argjson now "$now" \
      '(.runs[] | select(.id == $id and .status == "active")) |= (.minimaxCycles += 1 | .updatedAt=$now)' "$runs_file")"
    count="$(printf '%s' "$updated" | jq -r --arg id "$2" '.runs[] | select(.id == $id) | .minimaxCycles')"
    printf '%s\n' "$updated" | write_json
    printf '%s\n' "$count"
    ;;
  takeover)
    [[ "$#" -eq 2 ]] || { echo "Usage: $0 takeover <run-id>" >&2; exit 2; }
    acquire_lock; trap release_lock EXIT
    current="$(jq -r --arg id "$2" '.runs[] | select(.id == $id) | [.status,.minimaxCycles,.chatgptTakeovers] | @tsv' "$runs_file")"
    [[ -n "$current" ]] || { echo "run not found: $2" >&2; exit 1; }
    IFS=$'\t' read -r status cycles takeovers <<< "$current"
    [[ "$status" == "active" && "$cycles" -ge 3 && "$takeovers" == "0" ]] || {
      echo "takeover gate not satisfied: status=$status cycles=$cycles takeovers=$takeovers" >&2
      exit 1
    }
    jq --arg id "$2" --argjson now "$now" \
      '(.runs[] | select(.id == $id)) |= (.owner="chatgpt" | .chatgptTakeovers=1 | .updatedAt=$now)' "$runs_file" | write_json
    echo "chatgpt_takeover"
    ;;
  finish)
    [[ "$#" -eq 3 ]] || { echo "Usage: $0 finish <run-id> <completed|blocked|needs_human_review|failed>" >&2; exit 2; }
    case "$3" in completed|blocked|needs_human_review|failed) ;; *) echo "invalid terminal status" >&2; exit 2 ;; esac
    acquire_lock; trap release_lock EXIT
    jq -e --arg id "$2" 'any(.runs[]; .id == $id and .status == "active")' "$runs_file" >/dev/null || { echo "active run not found: $2" >&2; exit 1; }
    updated="$(jq --arg id "$2" --arg s "$3" --argjson now "$now" \
      '(.runs[] | select(.id == $id and .status == "active")) |= (.status=$s | .updatedAt=$now | .leaseExpiresAt=0)' "$runs_file")"
    printf '%s\n' "$updated" | write_json
    ;;
  show)
    cat "$runs_file"
    ;;
  *)
    echo "Usage: $0 {start|heartbeat|minimax-failure|takeover|finish|show} ..." >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 <normalized-notion-snapshot.json>" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "patrol requires jq" >&2; exit 2; }

# The Notion connector produces the normalized snapshot. Keeping this adapter
# file-based makes patrol deterministic and prevents credentials entering logs.
jq -e '.projects and (.projects | type == "array")' "$1" >/dev/null
jq '[.projects[] |
  if (.status == "已結案" or .status == "已上線") then
    . + {classification:"terminal", reason:"terminal_status"}
  elif ((.spec_url // "") == "") then
    . + {classification:"no_spec", reason:"missing_spec"}
  elif ((.github_url // "") == "") then
    . + {classification:"blocked", reason:"missing_github_url"}
  elif ((.local_repo // "") == "") then
    . + {classification:"blocked", reason:"missing_local_repo"}
  elif ((.open_issues // 0) >= 3) then
    . + {classification:"blocked", reason:"open_issues_at_least_3"}
  elif ((.prod_http // 200) != 200) then
    . + {classification:"blocked", reason:"production_http_not_200"}
  elif (.status == "開發中" or .status == "已開案" or .status == "測試中") then
    . + {classification:"ready_to_dev", reason:"eligible"}
  else
    . + {classification:"ignored", reason:"status_not_ready"}
  end
] | {generated_at:(now | todateiso8601), projects:.}' "$1"

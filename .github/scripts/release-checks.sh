#!/bin/sh
# Wait for the exact source commit; missing checks never count as success.
set -eu
sha=${1:?commit required}
limit=${2:-3600}
case "$sha" in *[!0-9a-f]*|'') exit 2 ;; esac
[ "${#sha}" -eq 40 ] || exit 2
case "$limit" in *[!0-9]*|'') exit 2 ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
awk -F '\t' '
  NF != 2 || $1 !~ /^[a-z0-9-]+[.]yml$/ || $2 == "" || seen[$2]++ { bad = 1 }
  END { exit bad || NR == 0 }
' "$root/.github/release-checks.tsv" || { echo 'Invalid required check manifest' >&2; exit 2; }
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
deadline=$(( $(date +%s) + limit ))
while :; do
  gh api --paginate --slurp "repos/$repo/commits/$sha/check-runs?filter=latest&per_page=100" > "$work/checks"
  cut -f1 "$root/.github/release-checks.tsv" | sort -u | while IFS= read -r workflow; do
    gh api --paginate --slurp "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=100" > "$work/$workflow"
  done
  pending=false
  while IFS="$(printf '\t')" read -r workflow name || [ -n "$workflow" ]; do
    suite=$(jq -r --arg sha "$sha" --arg path ".github/workflows/$workflow" '
      [.[].workflow_runs[] | select(.head_sha == $sha and .path == $path)]
      | max_by(.id)
      | if .event == "push" or .event == "workflow_dispatch" then (.check_suite_id // 0) else 0 end' "$work/$workflow")
    result=$(jq -r --arg name "$name" --arg sha "$sha" --argjson suite "$suite" '
      [.[].check_runs[] | select(.name == $name and .app.slug == "github-actions"
         and .head_sha == $sha and .check_suite.id == $suite and $suite != 0)]
      | max_by(.id) | if . == null then "missing"
        elif .status != "completed" then .status else (.conclusion // "missing") end
      ' "$work/checks")
    case "$result" in
      success)
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
          jq -r --arg name "$name" --arg sha "$sha" --argjson suite "$suite" '
            [.[].check_runs[] | select(.name == $name and .app.slug == "github-actions"
               and .head_sha == $sha and .check_suite.id == $suite)]
            | max_by(.id) | "- [\(.name)](\(.details_url))"' "$work/checks" >> "$GITHUB_STEP_SUMMARY"
        fi ;;
      missing|queued|in_progress|waiting|pending|requested)
        echo "Required check '$name' on $sha: $result ($workflow)"
        pending=true ;;
      *) echo "Required check '$name' on $sha failed: $result" >&2; exit 1 ;;
    esac
  done < "$root/.github/release-checks.tsv"
  [ "$pending" = true ] || { echo "All required checks passed on $sha"; exit 0; }
  [ "$(date +%s)" -lt "$deadline" ] || { echo 'Timed out waiting for missing or unfinished required checks' >&2; exit 1; }
  sleep 30
done

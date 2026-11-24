#!/bin/sh
# Wait for the exact source commit; missing checks never count as success.
set -eu
sha=${1:?commit required}
limit=${2:-3600}
only=${3:-}
case "$sha" in *[!0-9a-f]*|'') exit 2 ;; esac
[ "${#sha}" -eq 40 ] || exit 2
case "$limit" in *[!0-9]*|'') exit 2 ;; esac
case "$only" in *[!a-z0-9.-]*) exit 2 ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
awk -F '\t' '
  NF != 2 || $1 !~ /^[a-z0-9-]+[.]yml$/ || $2 == "" || seen[$2]++ { bad = 1 }
  END { exit bad || NR == 0 }
' "$root/.github/release-checks.tsv" || { echo 'Invalid required check manifest' >&2; exit 2; }
[ -z "$only" ] || cut -f1 "$root/.github/release-checks.tsv" | grep -Fxq -- "$only" || exit 2
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
deadline=$(( $(date +%s) + limit ))
while :; do
  gh api --paginate --slurp "repos/$repo/commits/$sha/check-runs?filter=all&per_page=100" > "$work/checks"
  cut -f1 "$root/.github/release-checks.tsv" | sort -u | while IFS= read -r workflow; do
    gh api --paginate --slurp "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=100" > "$work/$workflow"
  done
  pending=false
  while IFS="$(printf '\t')" read -r workflow name || [ -n "$workflow" ]; do
    [ -z "$only" ] || [ "$workflow" = "$only" ] || continue
    # Newest push/dispatch run decides; while it is unfinished, an earlier
    # completed successful run holding every required name may stand in.
    suite=$(jq -r --arg sha "$sha" --arg path ".github/workflows/$workflow" '
      [.[].workflow_runs[] | select(.head_sha == $sha and .path == $path
         and (.event == "push" or .event == "workflow_dispatch"))]
      | sort_by(-.id) | .[] | "\(.check_suite_id // 0) \(.status // "") \(.conclusion // "")"' "$work/$workflow" \
      | {
        newest=0
        first=true
        chosen=
        while read -r candidate status conclusion; do
          if [ "$first" = true ]; then
            first=false
            newest=$candidate
            [ "$status" != completed ] || break
            continue
          fi
          [ "$status" = completed ] && [ "$conclusion" = success ] && [ "$candidate" != 0 ] || continue
          complete=true
          while IFS="$(printf '\t')" read -r w n || [ -n "$w" ]; do
            [ "$w" = "$workflow" ] || continue
            jq -e --arg name "$n" --arg sha "$sha" --argjson suite "$candidate" '
              [.[].check_runs[] | select(.name == $name and .app.slug == "github-actions"
                 and .head_sha == $sha and .check_suite.id == $suite)]
              | max_by(.id) | .status == "completed" and .conclusion == "success"' "$work/checks" > /dev/null || complete=false
          done < "$root/.github/release-checks.tsv"
          if [ "$complete" = true ]; then chosen=$candidate; break; fi
        done
        echo "${chosen:-$newest}"
      })
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

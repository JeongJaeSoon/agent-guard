#!/bin/sh
# A threshold is advisory; missing, unfinished or invalid evidence blocks release.
set -eu
sha=${1:?source commit required}
limit=${2:-3600}
case "$sha" in *[!0-9a-f]*|'') exit 2 ;; esac
[ "${#sha}" -eq 40 ] || exit 2
case "$limit" in *[!0-9]*|'') exit 2 ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
deadline=$(( $(date +%s) + limit ))
while :; do
  gh api "repos/$repo/actions/workflows/performance.yml/runs?head_sha=$sha&per_page=100" > "$work/runs"
  latest=$(jq -r --arg sha "$sha" '[.workflow_runs[] | select(.head_sha == $sha)] | max_by(.id)
    | if . == null then "missing 0" else "\(.status) \(.id)" end' "$work/runs")
  status=${latest%% *}
  id=${latest#* }
  [ "$status" != completed ] || break
  echo "Performance evidence on $sha: $status"
  [ "$(date +%s)" -lt "$deadline" ] || { echo 'Performance measurement did not finish before deadline' >&2; exit 1; }
  sleep 30
done
for artifact in packaged-performance instruction-count; do
  gh run download "$id" --repo "$repo" --name "$artifact" --dir "$work/$artifact"
done
verdict=$(sh "$root/.github/scripts/performance-verdict.sh" "$work")
url="https://github.com/$repo/actions/runs/$id"
for artifact in packaged-performance instruction-count; do
  [ ! -f "$work/$artifact/errors.txt" ] || cat "$work/$artifact/errors.txt" >&2
done
case "$verdict" in
  passed) echo "Performance evidence passed: $url" ;;
  threshold_exceeded) echo "::warning title=Release performance evidence::Threshold exceeded in completed measurements: $url" ;;
  *) echo "Performance measurement did not finish or failed validation: $url" >&2; exit 1 ;;
esac

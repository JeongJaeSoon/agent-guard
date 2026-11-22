#!/bin/sh
# A failed lookup falls back to full main CI; it never grants reused evidence.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
sha=${GITHUB_SHA:?}
repo=${GITHUB_REPOSITORY:?}
if [ "${GITHUB_EVENT_NAME:-}" != push ] || [ "${GITHUB_REF:-}" != refs/heads/main ]; then
  echo 'reuse=false'
  exit 0
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
qualify() {
  gh api "repos/$repo/commits/$sha/pulls" > "$work/prs" || return 1
  number=$(jq -er --arg sha "$sha" --arg repo "$repo" '
    [.[] | select(.merged_at != null and .merge_commit_sha == $sha
      and .base.ref == "main" and .head.repo.full_name == $repo
      and .user.login == "github-actions[bot]"
      and (.labels | any(.name == "release"))
      and (.body | contains("<!-- agent-guard-release:publish -->")))]
    | select(length == 1) | .[0].number' "$work/prs") || return 1
  version=$(jq -r --argjson number "$number" '.[] | select(.number == $number) | .head.ref | sub("^release/v"; "")' "$work/prs") || return 1
  # Publication and main CI consume the same parent/tree/check proof.
  GITHUB_REPOSITORY="$repo" sh "$root/.github/scripts/release-target.sh" "$number" "$version" false > "$work/target" || return 1
  source=$(sed -n 's/^source_sha=//p' "$work/target")
  head=$(sed -n 's/^release_head_sha=//p' "$work/target")
  [ "$source" = "$head" ] && [ "$head" != "$sha" ] || return 1
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### Reused release tree\n\nSource head: %s\n\n' "$head"
    } >> "$GITHUB_STEP_SUMMARY" || return 1
  fi
  printf 'reuse=true\nsource_sha=%s\n' "$head"
}
if ! qualify; then
  echo 'Release tree evidence unavailable; running full main CI' >&2
  echo 'reuse=false'
fi

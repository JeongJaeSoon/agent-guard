#!/bin/sh
# Resolve a reviewed release PR to a source tree and an immutable publication SHA.
set -eu
number=${1:?PR number required}
version=${2:?version required}
dry_run=${3:-false}
case "$number" in *[!0-9]*|'') exit 2 ;; esac
printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || exit 2
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
gh api "repos/$repo/pulls/$number" > "$work/pr"
jq -e --arg repo "$repo" --arg version "$version" --arg candidate "$dry_run" '
  .base.ref == "main" and .head.repo.full_name == $repo
  and (.labels | any(.name == "release"))
  and (if $candidate == "true"
       then (.head.ref | startswith("release/dry-run-")) and (.head.ref | endswith("/v" + $version))
       else .head.ref == "release/v" + $version end)
  and .user.login == "github-actions[bot]"
  ' "$work/pr" >/dev/null || { echo 'Not a bot-created, version-matched release PR' >&2; exit 1; }
head=$(jq -r '.head.sha' "$work/pr")
git fetch origin main "$head"
manifest=$(git show "$head:plugins/agent-guard/.claude-plugin/plugin.json" | jq -r '.version')
[ "$manifest" = "$version" ] || { echo 'Release PR version mismatch' >&2; exit 1; }
if [ "$dry_run" = true ]; then
  jq -e '.merged == false and .state == "open" and (.body | contains("<!-- agent-guard-release:dry-run -->"))' "$work/pr" >/dev/null
  release=$head
else
  jq -e '.merged == true and (.body | contains("<!-- agent-guard-release:publish -->"))' "$work/pr" >/dev/null
  release=$(jq -r '.merge_commit_sha' "$work/pr")
  [ "$release" = "$(git rev-parse origin/main)" ] || { echo 'Release merge is no longer current main' >&2; exit 1; }
fi
head_tree=$(git rev-parse "$head^{tree}")
release_tree=$(git rev-parse "$release^{tree}")
same_tree=false
if [ "$head_tree" = "$release_tree" ]; then
  if [ "$dry_run" = true ]; then
    same_tree=true
  else
    base=$(jq -r '.base.sha' "$work/pr")
    gh api "repos/$repo/commits/$release" > "$work/merge"
    if [ "$head" != "$release" ] && jq -e --arg base "$base" '.parents | length == 1 and .[0].sha == $base' "$work/merge" >/dev/null; then
      same_tree=true
    fi
  fi
fi
if [ "$same_tree" = true ]; then
  source=$head
  echo "Reusing required checks from identical PR tree $head_tree" >&2
else
  source=$release
  echo 'Tree or squash evidence differs; requiring all checks on the exact merge commit' >&2
fi
printf 'release_sha=%s\nrelease_head_sha=%s\nsource_sha=%s\n' "$release" "$head" "$source"

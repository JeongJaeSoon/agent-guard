#!/bin/sh
# Evidence that this run's tree already passed this workflow, so the heavy
# jobs need not run again. Prints reuse=true|false and ordinary=true|false.
#
#   sh .github/scripts/reuse-tested-tree.sh WORKFLOW_FILE
#
# A push to main reuses the newest pull_request run of WORKFLOW_FILE at the
# head of the one PR that was squash-merged into it, when that run succeeded,
# the merge has one parent, the parent is an ancestor of the PR head (so the
# run's merge ref held the same tree) and both trees are equal. ordinary=true
# marks a merge of a non-release PR; release merges keep reuse-release-tree.sh
# and the full matrix. A schedule run reuses an earlier successful schedule
# run at the same commit. Any failed lookup prints reuse=false ordinary=false,
# which runs everything.
set -eu
workflow=${1:?workflow file required}
case "$workflow" in *[!a-z0-9.-]*|'') exit 2 ;; esac
sha=${GITHUB_SHA:?}
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
ordinary=false
runs() { # $1 commit, $2 event
  gh api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$1&event=$2&per_page=100" > "$work/runs"
}
merged_pr() {
  gh api "repos/$repo/commits/$sha/pulls" > "$work/prs" || return 1
  jq -e --arg sha "$sha" --arg repo "$repo" '
    [.[] | select(.merged_at != null and .merge_commit_sha == $sha
      and .base.ref == "main" and .head.repo.full_name == $repo)]
    | select(length == 1) | .[0]' "$work/prs" > "$work/pr" || return 1
  jq -e '(.labels | any(.name == "release")) or (.head.ref | startswith("release/"))' "$work/pr" > /dev/null \
    && return 1
  ordinary=true
}
pr_tree_passed() {
  number=$(jq -er '.number | tostring | select(test("^[0-9]+$"))' "$work/pr") || return 1
  head=$(jq -er '.head.sha | select(test("^[0-9a-f]{40}$"))' "$work/pr") || return 1
  ref=$(jq -er '.head.ref' "$work/pr") || return 1
  [ "$(git rev-list --parents -n 1 "$sha" | wc -w | tr -d ' ')" = 2 ] || return 1
  git fetch -q --no-tags origin "refs/pull/$number/head" || return 1
  git cat-file -e "$head^{commit}" || return 1
  [ "$(git rev-parse "$head^{tree}")" = "$(git rev-parse "$sha^{tree}")" ] || return 1
  git merge-base --is-ancestor "$sha^" "$head" || return 1
  runs "$head" pull_request || return 1
  jq -e --arg sha "$head" --arg ref "$ref" --arg repo "$repo" --arg path ".github/workflows/$workflow" '
    [.workflow_runs[] | select(.head_sha == $sha and .event == "pull_request" and .path == $path
      and .head_branch == $ref and .head_repository.full_name == $repo)]
    | max_by(.id) | .status == "completed" and .conclusion == "success"' "$work/runs" > /dev/null || return 1
  printf 'source_sha=%s\n' "$head"
}
schedule_passed() {
  runs "$sha" schedule || return 1
  jq -e --arg sha "$sha" --arg path ".github/workflows/$workflow" --argjson self "${GITHUB_RUN_ID:?}" '
    any(.workflow_runs[]; .head_sha == $sha and .event == "schedule" and .path == $path
      and .id != $self and .status == "completed" and .conclusion == "success")' "$work/runs" > /dev/null || return 1
  printf 'source_sha=%s\n' "$sha"
}
reuse=false
case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
  push:refs/heads/main)
    if merged_pr && pr_tree_passed > "$work/source"; then reuse=true; fi ;;
  schedule:refs/heads/main)
    if schedule_passed > "$work/source"; then reuse=true; fi ;;
esac
[ "$reuse" = false ] || cat "$work/source"
printf 'reuse=%s\nordinary=%s\n' "$reuse" "$ordinary"

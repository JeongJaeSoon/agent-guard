#!/bin/sh
# Evidence that this run's tree already passed this workflow, so the heavy
# jobs need not run again. Prints reuse=true|false and ordinary=true|false.
#
#   sh .github/scripts/reuse-tested-tree.sh WORKFLOW_FILE
#
# A push to main finds the one PR squash-merged into it and the newest
# pull_request run of WORKFLOW_FILE at that PR's head. It reuses that run when
# the run succeeded and its tested-tree artifact (the tree of the merge commit
# it checked out, recorded only when its suites ran) equals this commit's
# tree. ordinary=true marks a merge of a non-release PR; release merges keep
# reuse-release-tree.sh and the full matrix. A schedule run reuses an earlier
# successful schedule run at the same commit. A failed lookup prints
# reuse=false ordinary=false, which runs everything.
set -eu
workflow=${1:?workflow file required}
case "$workflow" in *[!a-z0-9.-]*|'') exit 2 ;; esac
sha=${GITHUB_SHA:?}
repo=${GITHUB_REPOSITORY:?}
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
ordinary=false
# Each check returns 1 when the evidence does not qualify and 2 when it could
# not be read.
merged_pr() {
  gh api "repos/$repo/commits/$sha/pulls" > "$work/prs" || return 2
  jq -e --arg sha "$sha" --arg repo "$repo" '
    [.[] | select(.merged_at != null and .merge_commit_sha == $sha
      and .base.ref == "main" and .head.repo.full_name == $repo)]
    | select(length == 1) | .[0]' "$work/prs" > "$work/pr" || return 2
  kind=$(jq -er '
    if (.labels | type) == "array" and (.head.ref | type) == "string" then
      if (.labels | any(.name == "release")) or (.head.ref | startswith("release/")) then "release" else "ordinary" end
    else error("malformed PR") end' "$work/pr") || return 2
  [ "$kind" = ordinary ] || return 1
  ordinary=true
}
pr_tree_passed() {
  head=$(jq -er '.head.sha | select(test("^[0-9a-f]{40}$"))' "$work/pr") || return 2
  ref=$(jq -er '.head.ref' "$work/pr") || return 2
  tree=$(git rev-parse --verify "$sha^{tree}") || return 2
  gh api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$head&event=pull_request&per_page=100" > "$work/runs" || return 2
  jq -e '.workflow_runs | type == "array"' "$work/runs" > /dev/null || return 2
  run=$(jq -er --arg sha "$head" --arg ref "$ref" --arg repo "$repo" --arg path ".github/workflows/$workflow" '
    [.workflow_runs[] | select(.head_sha == $sha and .event == "pull_request" and .path == $path
      and .head_branch == $ref and .head_repository.full_name == $repo)]
    | max_by(.id) | select(.status == "completed" and .conclusion == "success") | .id | tostring' "$work/runs") || return 1
  case "$run" in *[!0-9]*|'') return 2 ;; esac
  gh api "repos/$repo/actions/runs/$run/artifacts?name=tested-tree" > "$work/artifacts" || return 2
  jq -e '.artifacts | type == "array"' "$work/artifacts" > /dev/null || return 2
  jq -e '[.artifacts[] | select(.name == "tested-tree" and .expired == false)] | length == 1' "$work/artifacts" > /dev/null || return 1
  gh run download "$run" --repo "$repo" --name tested-tree --dir "$work/tested" || return 2
  recorded=$(cat "$work/tested/tree") || return 2
  printf '%s\n' "$recorded" | grep -Eqx '[0-9a-f]{40}' || return 2
  [ "$recorded" = "$tree" ] || return 1
  printf 'source_sha=%s\nsource_run=%s\n' "$head" "$run"
}
schedule_passed() {
  gh api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&event=schedule&per_page=100" > "$work/runs" || return 2
  jq -e '.workflow_runs | type == "array"' "$work/runs" > /dev/null || return 2
  # The newest earlier nightly decides: a later failure is never hidden by an
  # older success at the same commit.
  jq -e --arg sha "$sha" --arg path ".github/workflows/$workflow" --argjson self "${GITHUB_RUN_ID:?}" '
    [.workflow_runs[] | select(.head_sha == $sha and .event == "schedule" and .path == $path and .id != $self)]
    | max_by(.id) | .status == "completed" and .conclusion == "success"' "$work/runs" > /dev/null || return 1
  printf 'source_sha=%s\n' "$sha"
}
reuse=false
status=0
case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
  push:refs/heads/main)
    merged_pr || status=$?
    if [ "$status" -eq 0 ]; then pr_tree_passed > "$work/source" || status=$?; fi ;;
  schedule:refs/heads/main)
    schedule_passed > "$work/source" || status=$? ;;
  *) status=1 ;;
esac
case "$status" in
  0) reuse=true; cat "$work/source" ;;
  1) ;;
  *) ordinary=false; echo 'Tested-tree evidence unavailable; running everything' >&2 ;;
esac
printf 'reuse=%s\nordinary=%s\n' "$reuse" "$ordinary"

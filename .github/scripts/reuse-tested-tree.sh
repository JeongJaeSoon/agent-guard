#!/bin/sh
# Evidence that this run's tree already passed this workflow, so the heavy
# jobs need not run again. Prints reuse=true|false and ordinary=true|false.
#
#   sh .github/scripts/reuse-tested-tree.sh WORKFLOW_FILE
#
# A push to main finds the one PR squash-merged into it and the newest
# pull_request run of WORKFLOW_FILE at that PR's head (by start time, so a
# re-run counts as new). It reuses that run when
# the run succeeded and its tested-tree artifact (the tree of the merge commit
# it checked out, recorded only when its suites ran) equals this commit's
# tree. ordinary=true marks a merge of a non-release PR; release merges keep
# reuse-release-tree.sh and the full matrix. A schedule run reuses the newest
# earlier schedule run at the same commit that ran the matrix itself, when it
# passed and no schedule run started after it failed. A failed lookup prints
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
  # Every page: a re-run keeps its place in the list but starts again.
  gh api --paginate --slurp "repos/$repo/actions/workflows/$workflow/runs?head_sha=$head&event=pull_request&per_page=100" > "$work/runs" || return 2
  jq -e 'type == "array" and all(.[]; .workflow_runs | type == "array")' "$work/runs" > /dev/null || return 2
  # jq prints a run id or "none"; a jq error is unreadable evidence.
  run=$(jq -r --arg sha "$head" --arg ref "$ref" --arg repo "$repo" --arg path ".github/workflows/$workflow" '
    [.[].workflow_runs[]]
    | if any(.[]; [.head_sha, .event, .path] | any(type != "string")) then error("unreadable run") else . end
    | map(select(.head_sha == $sha and .event == "pull_request" and .path == $path))
    | if any(.[]; (.head_branch | type) != "string" or (.head_repository.full_name | type) != "string")
      then error("run without identity") else . end
    | map(select(.head_branch == $ref and .head_repository.full_name == $repo))
    | if any(.[]; (.run_started_at | type) != "string") then error("unordered runs") else . end
    | if any(.[]; (.status | type) != "string" or (.status == "completed" and (.conclusion | type) != "string")) then error("run without a result") else . end
    | max_by([.run_started_at, .id]) | if . != null and .status == "completed" and .conclusion == "success" then .id else "none" end' "$work/runs") || return 2
  [ "$run" != none ] || return 1
  case "$run" in *[!0-9]*|'') return 2 ;; esac
  gh api "repos/$repo/actions/runs/$run/artifacts?name=tested-tree" > "$work/artifacts" || return 2
  jq -e '.artifacts | type == "array" and all(.[]; (.name | type) == "string" and (.expired | type) == "boolean")' "$work/artifacts" > /dev/null || return 2
  found=$(jq -r '[.artifacts[] | select(.name == "tested-tree" and .expired == false)] | length == 1' "$work/artifacts") || return 2
  [ "$found" = true ] || return 1
  gh run download "$run" --repo "$repo" --name tested-tree --dir "$work/tested" || return 2
  [ "$(grep -c '' "$work/tested/tree")" = 1 ] || return 2
  recorded=$(cat "$work/tested/tree") || return 2
  printf '%s\n' "$recorded" | grep -Eqx '[0-9a-f]{40}' || return 2
  [ "$recorded" = "$tree" ] || return 1
  printf 'source_sha=%s\nsource_run=%s\n' "$head" "$run"
}
schedule_passed() {
  # A re-run keeps the run id; it must run, not find an older success.
  [ "${GITHUB_RUN_ATTEMPT:-1}" = 1 ] || return 1
  gh api --paginate --slurp "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&event=schedule&per_page=100" > "$work/runs" || return 2
  jq -e 'type == "array" and all(.[]; .workflow_runs | type == "array")' "$work/runs" > /dev/null || return 2
  jq -c --arg sha "$sha" --arg path ".github/workflows/$workflow" --argjson self "${GITHUB_RUN_ID:?}" '
    [.[].workflow_runs[]]
    | if any(.[]; [.head_sha, .event, .path] | any(type != "string")) then error("unreadable run") else . end
    | map(select(.head_sha == $sha and .event == "schedule" and .path == $path and .id != $self))
    | if any(.[]; (.run_started_at | type) != "string") then error("unordered runs") else . end
    | if any(.[]; (.status | type) != "string" or (.status == "completed" and (.conclusion | type) != "string")) then error("run without a result") else . end
    | sort_by([.run_started_at, .id]) | reverse | .[]
    | {id, done: (.status == "completed"), passed: (.status == "completed" and .conclusion == "success")}' "$work/runs" > "$work/nightly" || return 2
  # Newest first: the newest nightly that ran the matrix itself (it holds a
  # tested-tree record) must have passed, and no nightly started after it may
  # have failed or still run. A nightly that reused evidence records nothing.
  while IFS= read -r row; do
    id=$(printf '%s\n' "$row" | jq -r '.id | tostring') || return 2
    case "$id" in *[!0-9]*|'') return 2 ;; esac
    printf '%s\n' "$row" | jq -e '.passed' > /dev/null || return 1
    gh api "repos/$repo/actions/runs/$id/artifacts?name=tested-tree" > "$work/artifacts" || return 2
    jq -e '.artifacts | type == "array" and all(.[]; (.name | type) == "string" and (.expired | type) == "boolean")' "$work/artifacts" > /dev/null || return 2
    found=$(jq -r '[.artifacts[] | select(.name == "tested-tree" and .expired == false)] | length == 1' "$work/artifacts") || return 2
    if [ "$found" = true ]; then
      printf 'source_sha=%s\nsource_run=%s\n' "$sha" "$id"
      return 0
    fi
  done < "$work/nightly"
  return 1
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

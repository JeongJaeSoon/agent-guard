#!/bin/sh
# Record the job's check identity without an Actions API permission.
set -eu
out=${1:?evidence directory required}
[ ! -e "$out/source.json" ] || { echo 'refusing to overwrite evidence source' >&2; exit 1; }
if ! source=$(printf '%s\n' "${EVIDENCE_JOB_CONTEXT:?}" | jq -ce \
  --arg run "${GITHUB_RUN_ID:?}" --arg attempt "${GITHUB_RUN_ATTEMPT:?}" --arg sha "${GITHUB_SHA:?}" '
  {check_run_id:(.check_run_id | tostring), run_id:$run, run_attempt:$attempt, head_sha:$sha}
  | select(all(.check_run_id, .run_id, .run_attempt; test("^[1-9][0-9]*$")) and .head_sha != "")
  '); then
  echo 'could not record the current performance job identity' >&2
  exit 1
fi
printf '%s\n' "$source" > "$out/source.json"

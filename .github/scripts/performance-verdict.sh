#!/bin/sh
# Shared release/nightly classification; absent or invalid evidence fails closed.
set -eu
evidence=${1:?evidence directory required}
sha=${2:-}
verdict=passed
for artifact in packaged-performance instruction-count; do
  file="$evidence/$artifact/verdict.txt"
  status=measurement_error
  [ ! -f "$file" ] || status=$(cat "$file")
  case "$artifact" in
    packaged-performance) job='Packaged performance evidence' ;;
    instruction-count) job='Shell instruction count against the latest release' ;;
  esac
  reason=verified
  if [ -z "$sha" ]; then
    reason=missing_head_sha
  elif [ ! -f "$file" ]; then
    reason=missing_verdict
  elif [ ! -f "$evidence/jobs.json" ]; then
    reason=missing_jobs
  elif [ ! -f "$evidence/$artifact/source.json" ]; then
    reason=missing_source
  elif ! reason=$(jq -er --arg name "$job" --arg sha "$sha" --arg verdict "$status" \
      --slurpfile source "$evidence/$artifact/source.json" '
      [.[].jobs[] | select(.name == $name)] as $all
      | ($all | max_by(.run_attempt) | .run_attempt) as $attempt
      | [$all[] | select(.run_attempt == $attempt)] | unique_by(.id)
      | if length == 0 then "missing_job"
        elif length != 1 then "ambiguous_job"
        elif ($source | length) != 1 then "ambiguous_source"
        else .[0] as $job | $source[0] as $source
          | if all($source.check_run_id, $source.run_id, $source.run_attempt;
                   type == "string" and test("^[1-9][0-9]*$")) | not then "invalid_source"
            elif $job.status != "completed" then "unfinished_job"
            elif $job.conclusion == "cancelled" then "job_cancelled"
            elif $job.head_sha != $sha or $source.head_sha != $sha then "sha_mismatch"
            elif ($job.run_id | tostring) != $source.run_id then "run_mismatch"
            elif ($job.run_attempt | tostring) != $source.run_attempt then "attempt_mismatch"
            elif ($job.check_run_url | split("/") | last) != $source.check_run_id then "check_mismatch"
            elif ($verdict == "passed" and $job.conclusion == "success")
                 or (($verdict == "threshold_exceeded" or $verdict == "measurement_error")
                     and $job.conclusion == "failure") then "verified"
            else "conclusion_mismatch" end
        end
      ' "$evidence/jobs.json" 2>/dev/null); then
    reason=invalid_metadata
  fi
  if [ "$reason" != verified ]; then
    printf '%s: evidence link %s\n' "$artifact" "$reason" >&2
    status=measurement_error
  fi
  case "$status" in
    passed) ;;
    threshold_exceeded) [ "$verdict" != passed ] || verdict=threshold_exceeded ;;
    *) verdict=measurement_error ;;
  esac
done
printf '%s\n' "$verdict"

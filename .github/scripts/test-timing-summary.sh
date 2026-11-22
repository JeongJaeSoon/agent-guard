#!/bin/sh
set -eu
: "${RUNNER_TEMP:?}" "${GITHUB_STEP_SUMMARY:?}" "${TEST_JOB_STARTED:?}" "${TEST_JOB_TIMEOUT_MINUTES:?}"
elapsed=$(( $(date +%s) - TEST_JOB_STARTED ))
limit=$((TEST_JOB_TIMEOUT_MINUTES * 60))
{
  printf '### Test job time budget\n\nElapsed: %s seconds; limit: %s seconds.\n\n' "$elapsed" "$limit"
  if [ "$((elapsed * 100))" -gt "$((limit * 80))" ]; then
    printf '**Warning: this job used more than 80%% of its time limit.**\n\n'
  fi
  printf '### Suites (slowest first)\n\n| Seconds | Exit | Suite |\n| ---: | ---: | --- |\n'
  for file in "$RUNNER_TEMP"/test-partition-*.suites.tsv; do
    [ -f "$file" ] || continue
    partition=${file##*/test-partition-}
    partition=${partition%%.*}
    awk -F '\t' -v partition="$partition" '{ print $1 "\t" $2 "\tPartition " partition ": " $3 }' "$file"
  done | LC_ALL=C sort -k1,1nr | awk -F '\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
} >>"$GITHUB_STEP_SUMMARY"

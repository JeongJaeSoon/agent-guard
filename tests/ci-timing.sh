#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/functions" "$CASE/runner"
sh "$ROOT/tests/helpers/extract-functions.sh" "$ROOT/tests/run.sh" "$CASE/functions" run_expect
. "$CASE/functions/run_expect.sh"
PROJECT_ROOT=$ROOT
ROOT="$CASE/fixture"
mkdir -p "$ROOT/tests"
printf 'exit 7\n' >"$ROOT/tests/failing-child.sh"
OUT="$CASE/out"
ERR="$CASE/err"
ok() { :; }
not_ok() { :; }
AGENT_GUARD_TEST_TIMINGS="$CASE/runner/test-partition-1.suites.tsv"
GITHUB_STEP_SUMMARY="$CASE/live.md"
AGENT_GUARD_TEST_SHARD=1
set +e
run_expect 7 'failing child' sh "$ROOT/tests/failing-child.sh"
run_expect 7 'absolute shell child' "$(command -v sh)" "$ROOT/tests/failing-child.sh"
run_expect 7 'environment wrapped child' env "$(command -v sh)" "$ROOT/tests/failing-child.sh"
run_expect 0 'syntax check is not a standalone suite' sh -n "$ROOT/tests/failing-child.sh"
run_expect 0 'inline command is not a standalone suite' sh -c ':'
set -e
test "$(wc -l <"$AGENT_GUARD_TEST_TIMINGS" | tr -d ' ')" = 3
awk -F '\t' '$1 >= 0 && $2 == 7 && $3 == "failing-child.sh" { found=1 } END { exit !found }' "$AGENT_GUARD_TEST_TIMINGS"
grep -F '| 1 | failing-child.sh |' "$GITHUB_STEP_SUMMARY"
printf '9\t0\tslow\n3\t7\tfast failure\n' >"$AGENT_GUARD_TEST_TIMINGS"
export GITHUB_STEP_SUMMARY
export RUNNER_TEMP="$CASE/runner"
export TEST_JOB_TIMEOUT_MINUTES=1
export TEST_JOB_STARTED=$(( $(date +%s) - 49 ))
printf '20\n' >"$RUNNER_TEMP/test-partition-1.seconds"
sh "$PROJECT_ROOT/.github/scripts/test-timing-summary.sh" >"$CASE/stdout"
grep -F 'more than 80%' "$GITHUB_STEP_SUMMARY"
# The job log carries the same table, so per-suite seconds survive without the
# step summary (the API does not serve it).
grep -F '| 9 | 0 | Partition 1: slow |' "$CASE/stdout"
grep -F 'Partition 1: 20 seconds in total, 12 in timed suites' "$CASE/stdout"
grep '^| [0-9]' "$GITHUB_STEP_SUMMARY" >"$CASE/rows"
tail -n 2 "$CASE/rows" >"$CASE/sorted"
printf '| 9 | 0 | Partition 1: slow |\n| 3 | 7 | Partition 1: fast failure |\n' >"$CASE/expected"
cmp "$CASE/expected" "$CASE/sorted"
GITHUB_STEP_SUMMARY="$CASE/healthy.md"
TEST_JOB_STARTED=$(date +%s)
sh "$PROJECT_ROOT/.github/scripts/test-timing-summary.sh"
if grep -q 'Warning:' "$GITHUB_STEP_SUMMARY"; then
  echo 'healthy job incorrectly warned' >&2; exit 1
fi
printf 'CI suite timing and job budget contracts passed\n'

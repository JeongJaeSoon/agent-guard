#!/usr/bin/env bash
# Run at most two independent partitions on one runner. Each keeps its own
# temporary files, complete output, exit status and timing. Do not fail fast:
# both results must be collected, including when the first partition fails.
set -uo pipefail
case $# in 1|2) ;; *) echo 'expected one or two partition IDs' >&2; exit 2 ;; esac
seen=' '
for shard in "$@"; do
  case "$shard" in 1|2|3|4|5) ;; *) echo "invalid partition: $shard" >&2; exit 2 ;; esac
  case "$seen" in *" $shard "*) echo "duplicate partition: $shard" >&2; exit 2 ;; esac
  seen="$seen$shard "
done
: "${RUNNER_TEMP:?}" "${GITHUB_STEP_SUMMARY:?}"
pids=()
logs=()
times=()
shards=("$@")
directories=()
# Allocate before starting any child, so allocation failure cannot orphan work.
# Preserve the suite's OS temp root: RUNNER_TEMP ancestors may have writable
# ACLs, which the allow-list security regressions intentionally reject.
for shard in "$@"; do
  directories+=("$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-partition-$shard.XXXXXX")") || exit 1
done
index=0
for shard in "$@"; do
  temporary=${directories[$index]}
  index=$((index + 1))
  log="$RUNNER_TEMP/test-partition-$shard.txt"
  timing="$RUNNER_TEMP/test-partition-$shard.seconds"
  (
    started=$SECONDS
    result=0
    TMPDIR="$temporary" AGENT_GUARD_TEST_SHARD="$shard" tests/run.sh >"$log" 2>&1 || result=$?
    printf '%s\n' "$((SECONDS - started))" >"$timing" || result=1
    exit "$result"
  ) &
  pids+=("$!")
  logs+=("$log")
  times+=("$timing")
done
status=0
for ((index=0; index<${#pids[@]}; index++)); do
  shard=${shards[$index]}
  result=0
  wait "${pids[$index]}" || result=$?
  [ "$result" -eq 0 ] || status=$result
  echo "::group::Partition $shard — full test assertions"
  cat "${logs[$index]}" || status=1
  echo '::endgroup::'
  grep -E '^(not ok - |passed: |failed: )' "${logs[$index]}" || true
  elapsed=$(cat "${times[$index]}") || { elapsed=unknown; status=1; }
  {
    printf '### Partition %s\n\nExecution: %s seconds; exit: %s.\n\n' "$shard" "$elapsed" "$result"
    grep -E '^(passed: |failed: )' "${logs[$index]}" || true
  } >>"$GITHUB_STEP_SUMMARY" || status=1
  # Existing real-scanner no-skip gate reads this exact output file.
  if [ "$shard" = 4 ]; then
    cp "${logs[$index]}" "$RUNNER_TEMP/test-output.txt" || status=1
  fi
done
exit "$status"

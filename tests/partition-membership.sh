#!/bin/sh
# Partition 1 alone took 24 to 25 minutes on macOS, the whole 25-minute job
# limit. These suites were measured on the macOS runner and moved to partition 2, which has room;
# keep them there so the macOS partitions stay balanced (see CONTRIBUTING.md
# "Test partitions").
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
status=0
for suite in handback-values bash-path-text-data path-operands-only redaction-wrapped-values tracked-file-exception; do
  shard=$(awk -v suite="tests/$suite.sh" '
    /^if in_shard [0-9]; then/ { current = $3; sub(/;/, "", current) }
    /^fi # end of shard/ { current = "" }
    index($0, "sh \"$ROOT/" suite "\"") { print current; exit }
  ' "$ROOT/tests/run.sh")
  if [ "$shard" != 2 ]; then
    echo "$suite runs in partition '${shard:-none}', expected 2" >&2
    status=1
  fi
done
[ "$status" -eq 0 ] && echo 'moved suites run in partition 2'
exit "$status"
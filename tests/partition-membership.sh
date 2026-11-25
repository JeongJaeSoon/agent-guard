#!/bin/sh
# Every suite that tests/run.sh starts with `sh "$ROOT/tests/NAME"` must sit in
# exactly one `if in_shard N` block, once. A suite outside every block would run
# in every shard; one in two blocks would run twice. Suites moved to balance the
# macOS jobs (see CONTRIBUTING.md "Test partitions") must stay where they were
# measured, and a test file that run.sh does not start must be started by
# something else, so no file is in no shard by accident.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
RUN_SH=${PARTITION_MEMBERSHIP_RUN_SH:-$ROOT/tests/run.sh}
status=0

# One "shard suite" line per start: the shard is "none" outside every block.
starts=$(awk '
  /^if in_shard [0-9]; then/ { current = $3; sub(/;/, "", current) }
  /^fi # end of shard/ { current = "" }
  /^[[:space:]]*#/ { next }
  {
    line = $0
    while (match(line, /(sh|"\$REAL_SH"|bash) "\$ROOT\/tests\/[A-Za-z0-9_.-]+"/)) {
      started = substr(line, RSTART, RLENGTH)
      sub(/^.*tests\//, "", started)
      sub(/"$/, "", started)
      print (current == "" ? "none" : current), started
      line = substr(line, RSTART + RLENGTH)
    }
  }' "$RUN_SH")

[ -n "$starts" ] || { echo 'no suite starts found in run.sh' >&2; exit 1; }

duplicates=$(printf '%s\n' "$starts" | sort | uniq -d)
if [ -n "$duplicates" ]; then
  printf 'started twice in one shard:\n%s\n' "$duplicates" >&2
  status=1
fi
outside=$(printf '%s\n' "$starts" | awk '$1 == "none" { print $2 }')
if [ -n "$outside" ]; then
  printf 'started outside every shard block (runs in all shards):\n%s\n' "$outside" >&2
  status=1
fi
split=$(printf '%s\n' "$starts" | awk '{ n[$2]++; s[$2] = s[$2] " " $1 } END { for (f in n) if (n[f] > 1) print f ":" s[f] }' | sort -u)
if [ -n "$split" ]; then
  printf 'started in more than one shard:\n%s\n' "$split" >&2
  status=1
fi

expect_shard() {
  expected=$1
  shift
  for suite in "$@"; do
    got=$(printf '%s\n' "$starts" | awk -v suite="$suite.sh" '$2 == suite { print $1; exit }')
    if [ "$got" != "$expected" ]; then
      echo "$suite runs in partition '${got:-none}', expected $expected" >&2
      status=1
    fi
  done
}
expect_shard 2 tracked-file-exception path-operands-only redaction-wrapped-values
expect_shard 6 search-operand-ground-truth gh-program-segments tool-coverage jq-program-segments env-lookup-allowlist heredoc-body-text gh-jq-option plugin-management runtime-global-text long-input
expect_shard 7 bash-path-text-data handback-values

# A test file run.sh never starts must be started by a workflow, another suite
# or the Makefile; otherwise nothing runs it.
started=$(printf '%s\n' "$starts" | awk '{ print $2 }' | sort -u)
orphans=
for file in "$ROOT"/tests/*.sh "$ROOT"/tests/*.py; do
  name=${file##*/}
  [ "$name" != run.sh ] || continue
  printf '%s\n' "$started" | grep -Fxq -- "$name" && continue
  if ! git -C "$ROOT" grep -lF -- "$name" -- . ":(exclude)tests/run.sh" ":(exclude)tests/$name" >/dev/null 2>&1; then
    orphans="$orphans $name"
  fi
done
if [ -n "$orphans" ]; then
  echo "test files that no shard, workflow or suite starts:$orphans" >&2
  status=1
fi

[ "$status" -eq 0 ] && echo 'every suite runs in exactly one shard; moved suites are where they were measured'
exit "$status"

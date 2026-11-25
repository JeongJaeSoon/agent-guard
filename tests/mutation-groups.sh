#!/usr/bin/env sh
# The workflow groups must cover every mutation exactly once (--lint), and a
# matrix that drops or duplicates a group must be rejected.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
WF=$ROOT/.github/workflows/mutation-check.yml
T=$(mktemp -d "${TMPDIR:-/tmp}/mutation-groups.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
n=0
check() { # check EXPECT_RC NAME GROUP_LIST
  n=$((n + 1))
  sed "s/^\( *group: \)\[.*\] *$/\1[$3]/" "$WF" >"$T/wf.yml"
  AGENT_GUARD_MUTATION_WORKFLOW=$T/wf.yml sh "$ROOT/tests/mutation-check.sh" --lint >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$1" ]; then echo "ok $n - $2"; else echo "not ok $n - $2 (exit $rc, wanted $1)"; fail=1; fi
}
fail=0
echo "TAP version 13"
shards=$(sed -n 's/^ *group: \[\(.*\)\] *$/\1/p' "$WF")
check 0 "the workflow's own groups are accepted" "$shards"
check 2 "a dropped bash shard is rejected" "core, handback, bash-1, bash-2, bash-3, bash-5, bash-6"
check 2 "a dropped core group is rejected" "handback, bash-1, bash-2, bash-3, bash-4, bash-5, bash-6"
check 2 "a repeated group is rejected" "core, core, handback, bash-1, bash-2, bash-3, bash-4, bash-5, bash-6"
check 2 "an unknown group is rejected" "core, handback, bash-1, bash-2, bash-3, bash-4, bash-5, bash-6, extra"
echo "1..$n"
exit "$fail"

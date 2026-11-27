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
# without GROUP: the workflow's own group list less GROUP.
without() {
  printf '%s\n' "$shards" | tr -d ' ' | tr ',' '\n' | grep -vx "$1" | paste -sd , - | sed 's/,/, /g'
}
fail=0
echo "TAP version 13"
shards=$(sed -n 's/^ *group: \[\(.*\)\] *$/\1/p' "$WF")
check 0 "the workflow's own groups are accepted" "$shards"
check 2 "a dropped bash shard is rejected" "$(without bash-4)"
check 2 "a dropped core group is rejected" "$(without core)"
check 2 "a dropped deny-chars shard is rejected" "$(without deny-chars-2)"
check 2 "a repeated group is rejected" "core, $shards"
check 2 "an unknown group is rejected" "$shards, extra"
check 2 "a deny-chars shard beyond its count is rejected" "$(without deny-chars-2), deny-chars-4"
echo "1..$n"
exit "$fail"

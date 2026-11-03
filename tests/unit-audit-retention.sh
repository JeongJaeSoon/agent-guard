#!/bin/sh
# Audit retention must work with awks that do not implement interval expressions.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-retention.XXXXXX")
trap 'rm -rf "$CASE"' 0
sed -n '/^audit_prune() ($/,/^)/p' "$SOURCE" >"$CASE/prune.sh"
sh -n "$CASE/prune.sh"
. "$CASE/prune.sh"
if [ -n "${AGENT_GUARD_TEST_AWK:-}" ]; then
  mkdir "$CASE/bin"
  printf '#!/bin/sh\nexec "$AGENT_GUARD_TEST_AWK" "$@"\n' >"$CASE/bin/awk"
  chmod +x "$CASE/bin/awk"
  PATH="$CASE/bin:$PATH"
  export PATH AGENT_GUARD_TEST_AWK
fi
AG_AUDIT_START=2000000
mkdir "$CASE/age"
: >"$CASE/age/event-1000000-ABC123"
: >"$CASE/age/event-2000000-abc123"
mkdir "$CASE/age/live-probe-1000000-ABC123"
for name in event-1-abc12 event-1-abcdefg event-1000000000000-abc123 event-1-a-bc12 event-x-abc123 event-1-ébc123; do
  : >"$CASE/age/$name"
done
audit_prune "$CASE/age"
test ! -e "$CASE/age/event-1000000-ABC123"
test ! -e "$CASE/age/live-probe-1000000-ABC123"
test -f "$CASE/age/event-2000000-abc123"
for name in event-1-abc12 event-1-abcdefg event-1000000000000-abc123 event-1-a-bc12 event-x-abc123 event-1-ébc123; do
  test -f "$CASE/age/$name"
done
mkdir "$CASE/count"
i=0
while [ "$i" -lt 1001 ]; do
  : >"$CASE/count/event-2000000-$(printf '%06d' "$i")"
  i=$((i + 1))
done
audit_prune "$CASE/count"
count=$(find "$CASE/count" -type f | wc -l | tr -d ' ')
test "$count" = 999
printf 'passed: 10\nfailed: 0\n'

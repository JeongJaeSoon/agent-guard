#!/bin/sh
# The CLI must select its own payload through regular and linked entrypoints.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/payload with spaces/bin" "$CASE/payload with spaces/scripts" "$CASE/links" "$CASE/tools"
cp "$ROOT/plugins/agent-guard/bin/agent-guard" "$CASE/payload with spaces/bin/agent-guard"
cat >"$CASE/payload with spaces/scripts/gitleaks-checksum.sh" <<'MARKER'
#!/bin/sh
test "$#" -eq 1 && test "$1" = location-contract || exit 2
printf 'selected expected payload\n'
MARKER
ln -s "$CASE/payload with spaces/bin/agent-guard" "$CASE/links/absolute"
ln -s '../payload with spaces/bin/agent-guard' "$CASE/links/relative"
ln -s relative "$CASE/links/chain"
ln -s "$CASE/payload with spaces" "$CASE/parent-link"
ln -s missing "$CASE/links/broken"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
count=0
check() {
  "$@" checksum location-contract >"$CASE/out"
  test "$(cat "$CASE/out")" = 'selected expected payload'
  count=$((count + 1))
  printf 'ok - script location contract %s\n' "$count"
}
check "$CASE/payload with spaces/bin/agent-guard"
check "$CASE/links/absolute"
check "$CASE/links/relative"
check "$CASE/links/chain"
check "$CASE/parent-link/bin/agent-guard"
cd "$CASE"
check './payload with spaces/bin/agent-guard'
check env PATH="$CASE/payload with spaces/bin:$PATH" agent-guard
if sh "$CASE/links/broken" checksum location-contract >"$CASE/out" 2>"$CASE/err"; then
  echo 'broken executable link unexpectedly succeeded' >&2
  exit 1
fi
count=$((count + 1))
printf 'passed: %s script location contracts\n' "$count"

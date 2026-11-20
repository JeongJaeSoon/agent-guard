#!/usr/bin/env sh
set -u

# A command that runs in the CLI's own shell and needs a temp directory must
# not replace the process EXIT trap: that trap also removes the per-invocation
# rundir and stops leftover gitleaks probes. smoke-test is one such command, so
# after it exits nothing it created may remain in TMPDIR.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/exit-trap-cleanup.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" "$CASE/tmp" || exit 1

pass=0 fail=0
(
  cd "$CASE" || exit 2
  env HOME="$CASE/home" TMPDIR="$CASE/tmp" AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" \
    sh "$GUARD" smoke-test
) >"$CASE/out" 2>&1
status=$?
leftover=$(find "$CASE/tmp" -mindepth 1 -maxdepth 1 -name 'agent-guard*' 2>/dev/null)
if [ "$status" -eq 0 ]; then
  pass=$((pass + 1)); printf 'ok - smoke-test passes\n'
else
  fail=$((fail + 1)); printf 'not ok - smoke-test passes (status %s)\n' "$status"
  sed 's/^/  /' "$CASE/out"
fi
if [ -z "$leftover" ]; then
  pass=$((pass + 1)); printf 'ok - smoke-test leaves no agent-guard temp directory\n'
else
  fail=$((fail + 1)); printf 'not ok - smoke-test leaves no agent-guard temp directory\n'
  printf '%s\n' "$leftover" | sed "s|$CASE|<case>|; s/^/  left: /"
fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

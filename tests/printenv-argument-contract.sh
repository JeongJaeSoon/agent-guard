#!/bin/sh
# Independent CLI expectations for jq 1.6 raw-slurp argument boundaries.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off
REAL_PRINTENV=$(command -v printenv)
export REAL_PRINTENV
# Give every platform the same GNU-style multi-argument semantics. The existing
# full suite separately checks the host's actual printenv status/argument rules.
cat > "$case_dir/printenv" <<'STUB'
#!/bin/sh
status=0
for name do
  "$REAL_PRINTENV" "$name" || status=1
done
exit "$status"
STUB
chmod +x "$case_dir/printenv"
check() {
  label=$1 expected=$2 expected_status=$3
  shift 3
  status=0
  actual=$("$@") || status=$?
  if [ "$status" != "$expected_status" ] || [ "$actual" != "$expected" ]; then
    printf 'not ok - %s (status %s)\n' "$label" "$status" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}
check 'empty requested secret remains empty' '' 0 \
  env EMPTY_PASSWORD='' "$GUARD" exec -- "$case_dir/printenv" EMPTY_PASSWORD
# Synthetic values are assembled at runtime, as in tests/run.sh, so repository
# secret scanners do not mistake the test fixture for a deployed credential.
fixture_first=$(printf '%s-%s' documented-fake-printenv-value 123456)
fixture_second=$(printf '%s-%s' omega-secret-tail alpha-long-value)
check 'missing argument preserves status and both emitted masks' "$(printf '[REDACTED]\n[REDACTED]')" 1 \
  env -u AGENT_GUARD_TEST_UNSET_PASSWORD DEMO_TOKEN="${fixture_first}" \
    SECONDARY_PASSWORD="${fixture_second}" \
    "$GUARD" exec -- "$case_dir/printenv" DEMO_TOKEN AGENT_GUARD_TEST_UNSET_PASSWORD SECONDARY_PASSWORD
newline_secret=$(printf 'alpha-secret-head\nx')
newline_secret=${newline_secret%x}
check 'trailing secret newline does not consume a later public value' "$(printf '[REDACTED]\nalpha-secret-head')" 0 \
  env FIRST_TOKEN="${newline_secret}" PUBLIC_INFO=alpha-secret-head \
    "$GUARD" exec -- "$case_dir/printenv" FIRST_TOKEN PUBLIC_INFO
newline_secret=$(printf 'abcd\nx')
newline_secret=${newline_secret%x}
check 'trailing empty value preserves public prefix and masks complete secret' "$(printf 'x\n[REDACTED]')" 0 \
  env PUBLIC_INFO=x PASSWORD="${newline_secret}" EMPTY='' \
    "$GUARD" exec -- "$case_dir/printenv" PUBLIC_INFO PASSWORD EMPTY

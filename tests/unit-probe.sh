#!/bin/sh
# Probe eligibility contracts with literal framing and independent expectations.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-probe.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" secretish_env_values
. "$CASE/secretish_env_values.sh"
pass=0 fail=0
check() {
  name=$1
  printf '%b' "$2" >"$CASE/input"
  printf '%b' "$3" >"$CASE/expected"
  status=0
  secretish_env_values probe <"$CASE/input" >"$CASE/actual" 2>"$CASE/error" || status=$?
  if [ "$status" -eq 0 ] && cmp -s "$CASE/expected" "$CASE/actual" && [ ! -s "$CASE/error" ]; then
    pass=$((pass + 1)); printf 'ok - %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'not ok - %s (status %s)\n' "$name" "$status"
  fi
}
# RS plus LF is the transport boundary, not part of an assignment's value.
check 'probe ignores already-redacted value' 'PASSWORD=[REDACTED]\036\n' ''
check 'probe ignores ineligible short value' 'TOKEN=1\036\n' ''
# The structural closer makes the full token eligible for contextual masking.
check 'probe retains contextual short mapping' 'TOKEN=123}\036\n' 'x\n'
# Compare files so trailing newlines and duplicate markers cannot be hidden.
check 'probe emits exactly one marker for two eligible leaves' \
  'PASSWORD=probe-first-value\036\nTOKEN=probe-second-value\036\n' 'x\n'
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

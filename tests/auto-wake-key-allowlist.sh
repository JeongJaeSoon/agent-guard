#!/usr/bin/env sh
set -u

# `orch-dash inbox resolve --key auto-wake:<dispatch id>`: the dispatch id
# (`ctx_` plus lowercase hex) sits behind a `key` option and a `:`, which
# generic-api-key reads as a labelled secret. Only that exact shape is exempt.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-auto-wake-key.XXXXXX")
ORIGINAL_PATH=$PATH
# A host that passes the variable empty means "no real gitleaks": PATH then holds
# only run.sh's mock, which would turn every must-fail case into a false failure.
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
pass=0
fail=0

cleanup() {
  rm -rf "$CASE_ROOT"
}
trap cleanup EXIT INT TERM
# Scanned directory holds only the fixture; stdout/stderr captures stay outside.
mkdir -p "$CASE_ROOT/scan"

if [ -z "$GITLEAKS" ]; then
  printf 'skip - real gitleaks is not installed\n'
  exit 0
fi

export AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG=${AUTO_WAKE_TEST_CONFIG:-$ROOT/plugins/agent-guard/config/gitleaks.toml}
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT

ok() {
  pass=$((pass + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE_ROOT/err" ] || sed 's/^/  stderr: /' "$CASE_ROOT/err"
}

# $1 expected status, $2 label, $3 file content
ctxk_case() {
  printf '%s\n' "$3" >"$CASE_ROOT/scan/fixtures.json"
  PATH="$(dirname "$GITLEAKS"):$ORIGINAL_PATH" "$GUARD" \
    scan-path "$CASE_ROOT/scan" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  ctxk_status=$?
  if [ "$ctxk_status" -eq "$1" ]; then
    ok "real gitleaks: $2"
  else
    not_ok "real gitleaks: $2 (expected $1, got $ctxk_status)"
  fi
}

# Fixed, not random: a low-entropy id falls under the rule's floor and would
# turn every must-fail case below into a silent pass. Secret-shaped words are
# built at run time so this file holds no literal finding.
UUIDK_ID=$(printf '%s-%s-%s-%s-%s' 7b42a1e9 63dc 4f08 a295 1c8e6d03b574)
UUIDK_AK=$(printf '%s%s' api _key)
CTXK_HEX=9f3a7c21d4e6
CTXK_ID="ctx_$CTXK_HEX"
CTXK_CMD="orch-dash inbox resolve --key auto-wake:"
CTXK_OPT=$(printf '%s%s' to ken)

ctxk_case 0 "an auto-wake dispatch id under --key is clean" \
  "$CTXK_CMD$CTXK_ID"
ctxk_case 0 "an auto-wake dispatch id under --key is clean before more options" \
  "$CTXK_CMD$CTXK_ID --json"
ctxk_case 0 "an auto-wake dispatch id under --key is clean beside an Orca repo id" \
  "skills-sync card /b/cards-key.md --repo id:$UUIDK_ID --name fix-some-thing-card; $CTXK_CMD$CTXK_ID"
ctxk_case 0 "a kebab-case card name beside a key word is clean" \
  "skills-sync card /b/cards-key.full.md --name cards-key-fix-some-thing-card"
ctxk_case 1 "a dispatch id under another option is still found" \
  "orch-dash inbox resolve --$CTXK_OPT auto-wake:$CTXK_ID"
ctxk_case 1 "a dispatch id assigned to an api key name is still found" \
  "$UUIDK_AK=$CTXK_ID"
ctxk_case 1 "a dispatch id with a trailing character under --key is still found" \
  "$CTXK_CMD${CTXK_ID}Z"
ctxk_case 1 "a dispatch id joined to a double-quoted tail under --key is still found" \
  "$CTXK_CMD$CTXK_ID\"Z\""
ctxk_case 1 "a dispatch id joined to a single-quoted tail under --key is still found" \
  "$CTXK_CMD$CTXK_ID'Z'"
ctxk_case 1 "a dispatch id joined to a carriage-return tail under --key is still found" \
  "$CTXK_CMD$CTXK_ID$(printf '\r')Z"
ctxk_case 1 "a dispatch id joined to a form-feed tail under --key is still found" \
  "$CTXK_CMD$CTXK_ID$(printf '\f')Z"
ctxk_case 0 "an auto-wake dispatch id under --key is clean before a next command" \
  "$CTXK_CMD$CTXK_ID; echo done"
ctxk_case 1 "an uppercase dispatch id under --key is still found" \
  "$CTXK_CMD$(printf '%s' "$CTXK_ID" | tr 'a-f' 'A-F')"
ctxk_case 1 "a non-dispatch value under auto-wake: is still found" \
  "$CTXK_CMD$CTXK_HEX$CTXK_HEX"
ctxk_case 1 "a dispatch id without the auto-wake label is still found" \
  "orch-dash inbox resolve --key other:$CTXK_ID"
ctxk_case 1 "an api key after a dispatch id on one line is still found" \
  "$CTXK_CMD$CTXK_ID $UUIDK_AK=$UUIDK_ID"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

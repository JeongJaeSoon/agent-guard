#!/bin/sh
# The suites that check the rules and allowlists of
# plugins/agent-guard/config/gitleaks.toml, one after another.
# tests/gitleaks-probe-cache.sh starts this file unless the workflow runs it
# as a step of its own, which ci.yml does in the Linux Codex navigation job
# (see CONTRIBUTING.md "Test partitions"). Without a real gitleaks a suite
# skips or uses the mock. On Linux CI a missing gitleaks and a skipped suite
# are failures: a green step must mean every suite ran against the real
# scanner.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
REAL_GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || :)}
strict=0
[ "${CI:-}" != true ] || [ "$(uname -s)" != Linux ] || strict=1
if [ -z "$REAL_GITLEAKS" ]; then
  if [ "$strict" -eq 1 ]; then
    printf 'not ok - real gitleaks is required for the rule suites on Linux CI\n'
    exit 1
  fi
elif [ ! -f "$REAL_GITLEAKS" ] || [ ! -x "$REAL_GITLEAKS" ] \
    || [ "$(basename -- "$REAL_GITLEAKS")" != gitleaks ]; then
  # The suites put this file's directory on PATH and run gitleaks by name, so
  # without an executable of that name there they would scan with whichever
  # gitleaks PATH has next.
  printf 'not ok - AGENT_GUARD_TEST_REAL_GITLEAKS must be an executable file named gitleaks: %s\n' "$REAL_GITLEAKS"
  exit 1
else
  # Some suites change directory before they scan.
  REAL_GITLEAKS=$(CDPATH= cd -- "$(dirname -- "$REAL_GITLEAKS")" && pwd -P)/gitleaks || exit 1
fi
# Exit before the cleanup trap exists: an empty CASE would make `cd -- ""`
# resolve to the current directory, which the trap then removes.
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-gitleaks-rules.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
# dash runs the exit trap only when the script itself exits.
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$CASE/home" "$CASE/private-gitleaks-empty"
# The environment tests/run.sh and tests/gitleaks-probe-cache.sh give their
# suites, so the CI step runs them as a nested run does.
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=on
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_PROMPT_GUARD_MODE=block AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/private-gitleaks-empty"
export AGENT_GUARD_TEST_REAL_GITLEAKS="$REAL_GITLEAKS"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT AGENT_GUARD_GITLEAKS_BIN
pass=0 fail=0

# $1 what the suite guards, $2 its file under tests/.
run_suite() {
  started=$(date +%s)
  sh "$ROOT/tests/$2" >"$CASE/out" 2>&1
  status=$?
  seconds=$(($(date +%s) - started))
  skipped=0
  ! grep -q '^skip - ' "$CASE/out" || skipped=1
  if [ "$status" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    pass=$((pass + 1))
    printf 'ok - %s (%s, %ss)\n' "$1" "$2" "$seconds"
    return
  fi
  if [ "$status" -eq 0 ] && [ "$strict" -eq 0 ]; then
    printf 'skip - %s (%s)\n' "$1" "$2"
    return
  fi
  fail=$((fail + 1))
  printf 'not ok - %s (%s, exit %s, %ss)\n' "$1" "$2" "$status" "$seconds"
  sed 's/^/  /' "$CASE/out"
}

run_suite 'auto-wake dispatch ids under --key are clean while key-shaped values stay found' auto-wake-key-allowlist.sh
run_suite 'UUID reference ids are clean while UUID-shaped credentials stay found' reference-id-allowlist.sh
run_suite 'Figma MCP file keys pass while the same value elsewhere stays found' figma-file-key.sh
run_suite 'issue ids after a Secret-suffixed name pass while secret shapes stay blocked' prompt-issue-reference.sh
run_suite 'HTTP routes after a secret label pass while secret shapes stay blocked' prompt-route-reference.sh
run_suite 'modal prose after a secret label passes while secret shapes stay blocked' prompt-prose-reference.sh
run_suite 'prefixed-UUID keys are found while sdk- package names stay clean' prefixed-uuid-key.sh
run_suite 'force-with-lease expectations pass while keyword assignments stay found' force-with-lease-sha.sh
run_suite 'git object ids named as commits pass in Write content while secrets stay blocked' write-content-object-id.sh

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]

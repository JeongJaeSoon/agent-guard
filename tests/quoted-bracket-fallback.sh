#!/usr/bin/env sh
# Synthetic hook inputs only: none of the command strings below are executed.
# When the quoted-bracket normalization cannot run, the protected-path check
# must scan the original command text and keep its verdict, never an empty one.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-bracket-fallback.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
REAL_AWK=$(command -v awk) || exit 1
# An awk that fails only for the normalization program (it is the one that
# defines pyneutral) and behaves normally for every other caller.
mkdir "$CASE_ROOT/bin" || exit 1
{
  printf '#!/bin/sh\n'
  printf 'case "$*" in *pyneutral*) : >"%s/normalizer-ran"; exit 2 ;; esac\n' "$CASE_ROOT"
  printf 'exec %s "$@"\n' "$REAL_AWK"
} >"$CASE_ROOT/bin/awk"
chmod +x "$CASE_ROOT/bin/awk"
failed=0
checked=0
check() {
  expected=$1
  label=$2
  command=$3
  checked=$((checked + 1))
  jq -nc --arg c "$command" --arg w "$CASE_ROOT" \
    '{tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
    | PATH="$CASE_ROOT/bin:$PATH" "$GUARD" hook-pre-tool > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'ok - bracket fallback %s: %s\n' "$checked" "$label"
  else
    printf 'not ok - bracket fallback %s: %s: expected %s got %s\n' "$checked" "$label" "$expected" "$status"
    failed=$((failed + 1))
  fi
}

# The normalization only runs on a command that has a `[` followed by a quote,
# so each of these carries one.
check 2 "unquoted bracket glob stays blocked when normalization fails" "python3 -c 'a[\"x\"]' | cat .e[n]v"
check 2 "quoted fragments around an unquoted bracket stay blocked" "python3 -c 'a[\"x\"]' | cat '.e'[n]\"v\""
check 2 "plain dotenv read stays blocked" 'cat .env.local'
check 0 "an unrelated command still passes" 'ls -la'

# A command with no `[` followed by a quote must not pay for the normalizer:
# the Bash hook runs on every command, and the extra processes were a measured
# latency regression in the pre-bash-clean benchmark.
rm -f "$CASE_ROOT/normalizer-ran"
for clean in 'ls -la' 'git log --oneline -5 --format="%h %s" | head -3' "grep -n 'foo' src/main.c"; do
  checked=$((checked + 1))
  jq -nc --arg c "$clean" --arg w "$CASE_ROOT" \
    '{tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
    | PATH="$CASE_ROOT/bin:$PATH" "$GUARD" hook-pre-tool > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  if [ -e "$CASE_ROOT/normalizer-ran" ]; then
    printf 'not ok - bracket fallback %s: normalizer ran for a command without a subscript: %s\n' "$checked" "$clean"
    failed=$((failed + 1))
    rm -f "$CASE_ROOT/normalizer-ran"
  else
    printf 'ok - bracket fallback %s: no normalizer process for: %s\n' "$checked" "$clean"
  fi
done

[ "$failed" -eq 0 ] || exit 1
printf 'passed: %s\n' "$checked"

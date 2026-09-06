#!/usr/bin/env sh
# These are synthetic executions of the existing Claude and Codex manifest
# commands. They verify the CLI contract after each manifest resolver has
# selected the plugin binary. They deliberately cannot prove a host's own
# pre-hook denial or that a real host executed an allowed command.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
GUARD="$PLUGIN_ROOT/bin/agent-guard"
MOCK_GITLEAKS="$ROOT/tests/fixtures/mock-gitleaks"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-hook-outcome.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM

failed=0
checked=0

ok() {
  checked=$((checked + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  checked=$((checked + 1))
  failed=$((failed + 1))
  printf 'not ok - %s\n' "$1"
  sed 's/^/  stderr: /' "$CASE_ROOT/err"
}

run_cli() {
  AGENT_GUARD_GITLEAKS_BIN="$MOCK_GITLEAKS" "$GUARD" "$1" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
}

run_missing_cli() {
  AGENT_GUARD_GITLEAKS_BIN="$CASE_ROOT/no-gitleaks" "$GUARD" "$1" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
}

run_manifest() {
  host=$1
  failure_mode=$2
  scanner=$3
  payload=$4
  case "$host" in
    claude)
      root_name=CLAUDE_PLUGIN_ROOT
      command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' \
        "$PLUGIN_ROOT/hooks/hooks.json")
      ;;
    codex)
      root_name=PLUGIN_ROOT
      command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' \
        "$PLUGIN_ROOT/hooks.json")
      ;;
    *) return 64 ;;
  esac
  printf '%s' "$payload" \
    | (cd "$CASE_ROOT" && env "$root_name=$PLUGIN_ROOT" \
        AGENT_GUARD_GITLEAKS_BIN="$scanner" \
        AGENT_GUARD_INFRA_FAILURE_MODE="$failure_mode" \
        AGENT_GUARD_WARNING_DIR="$CASE_ROOT/warnings-$host-$failure_mode" \
        sh -c "$command") >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
}

# setup and doctor have one implementation. Test their actual stderr contract
# in both healthy and dependency-failure paths; neither outcome is host proof.
for diagnosis in setup doctor; do
  run_cli "$diagnosis"
  status=$?
  if [ "$status" -eq 0 ] \
     && grep -Fq 'setup ok (dependencies only)' "$CASE_ROOT/err" \
     && grep -Fq 'host hook protection: unverified (dependency checks do not observe tool dispatch)' "$CASE_ROOT/err"; then
    ok "$diagnosis reports dependencies only and leaves host dispatch unverified"
  else
    not_ok "$diagnosis healthy output retains the unverified host boundary (status $status)"
  fi

  run_missing_cli "$diagnosis"
  status=$?
  if [ "$status" -eq 1 ] \
     && grep -Fq 'host hook protection: unverified (dependency checks do not observe tool dispatch)' "$CASE_ROOT/err"; then
    ok "$diagnosis dependency failure retains the unverified host boundary"
  else
    not_ok "$diagnosis dependency failure retains the unverified host boundary (status $status)"
  fi
done

for host in claude codex; do
  # An observed policy diagnostic is a Guard denial for this manifest path.
  run_manifest "$host" open "$MOCK_GITLEAKS" \
    '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'
  status=$?
  if [ "$status" -eq 2 ] && grep -Fq 'agent-guard: blocked' "$CASE_ROOT/err"; then
    ok "$host manifest path reports an observed Guard denial"
  else
    not_ok "$host manifest path reports an observed Guard denial (status $status)"
  fi

  # A clean pre-hook result is dispatch-only: this synthetic call never asks a
  # host to execute the command after returning zero.
  run_manifest "$host" open "$MOCK_GITLEAKS" \
    '{"tool_name":"Bash","tool_input":{"command":"printf clean"}}'
  status=$?
  if [ "$status" -eq 0 ] && [ ! -s "$CASE_ROOT/err" ]; then
    ok "$host manifest path allows a clean pre-hook input"
  else
    not_ok "$host manifest path allows a clean pre-hook input (status $status)"
  fi

  run_manifest "$host" open "$MOCK_GITLEAKS" \
    '{"tool_name":"FutureTool","tool_input":{"x":1}}'
  status=$?
  if [ "$status" -eq 0 ] && [ ! -s "$CASE_ROOT/err" ]; then
    ok "$host manifest path preserves unknown-tool passthrough"
  else
    not_ok "$host manifest path preserves unknown-tool passthrough (status $status)"
  fi

  run_manifest "$host" open "$CASE_ROOT/no-gitleaks" \
    '{"session_id":"outcome-open","tool_name":"Bash","tool_input":{"command":"printf clean"}}'
  status=$?
  if [ "$status" -eq 0 ] && grep -Fq 'DEGRADED' "$CASE_ROOT/err" \
     && grep -Fq 'AGENT_GUARD_INFRA_FAILURE_MODE=open' "$CASE_ROOT/err"; then
    ok "$host manifest path reports degraded open infrastructure"
  else
    not_ok "$host manifest path reports degraded open infrastructure (status $status)"
  fi

  run_manifest "$host" closed "$CASE_ROOT/no-gitleaks" \
    '{"session_id":"outcome-closed","tool_name":"Bash","tool_input":{"command":"printf clean"}}'
  status=$?
  if [ "$status" -eq 2 ] && grep -Fq 'DEGRADED' "$CASE_ROOT/err"; then
    ok "$host manifest path applies closed infrastructure policy"
  else
    not_ok "$host manifest path applies closed infrastructure policy (status $status)"
  fi
done

printf '%s hook outcome contract checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

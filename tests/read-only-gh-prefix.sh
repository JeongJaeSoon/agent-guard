#!/usr/bin/env sh
# Synthetic hook inputs only: none of the fixture commands is executed.
# A read-only gh query that saves its output to an absolute file cannot change
# what a later command name runs, so a sed script, jq filter or grep pattern
# after it is read as program text as it is after an inert command. A writing
# gh subcommand, a redirect target named like a command on the line, an
# expansion, and every real file operand stay in the protected-path scan.
# Each fixture runs through both hosts' native event shapes.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=${AGENT_GUARD_TEST_FIXTURE:-$ROOT/tests/fixtures/read-only-gh-prefix.json}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-gh-prefix.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export HOME="$CASE_ROOT/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
mkdir -p "$HOME" "$CASE_ROOT/work"
failed=0
checked=0
jq -e 'type == "array" and length > 0' "$FIXTURE" >/dev/null || {
  printf 'not ok - %s is not a non-empty array\n' "$FIXTURE"
  exit 1
}
jq -c '.[]' "$FIXTURE" >"$CASE_ROOT/cases" || exit 1
while IFS= read -r row; do
  expected=$(printf '%s' "$row" | jq -r '.expected_status')
  name=$(printf '%s' "$row" | jq -r '.id + " (" + .classification + "): " + .description')
  for host in claude codex; do
    case "$host" in
      codex) shape='{tool_name:"Bash",tool_input:{command:.command,workdir:$d}}' ;;
      *) shape='{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:.command},cwd:$d}' ;;
    esac
    checked=$((checked + 1))
    printf '%s' "$row" | jq -c --arg d "$CASE_ROOT/work" "$shape" \
      | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
    status=$?
    if [ "$status" -eq "$expected" ]; then
      printf 'ok - [%s] %s\n' "$host" "$name"
    else
      printf 'not ok - [%s] %s: expected %s got %s\n' "$host" "$name" "$expected" "$status"
      sed 's/^/#   /' "$CASE_ROOT/err"
      failed=$((failed + 1))
    fi
  done
done <"$CASE_ROOT/cases"
printf '%s read-only gh prefix checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

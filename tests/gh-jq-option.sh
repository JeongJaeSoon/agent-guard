#!/usr/bin/env sh
# Synthetic hook inputs only: none of the fixture commands is executed.
# The --jq value of gh is a jq filter that gh runs itself: it opens no file
# the filter names, and the --jq word is an option of gh, not a jq command.
# Field names in it are dropped like those of a jq filter, and the option no
# longer stops the rewrite of a jq later in the same pipeline. File operands,
# option values, redirect targets, expansions and a gh that a wrapper, alias
# or function may replace stay in the protected-path scan.
# Every row runs in Claude's native event shape. The host changes the block
# message and the output envelope, never the decision, and no row here depends
# on where the event carries the working directory. So only the rows marked
# "both_hosts", one that passes and one that blocks, also run in Codex's shape.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=${AGENT_GUARD_TEST_FIXTURE:-$ROOT/tests/fixtures/gh-jq-option.json}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-gh-jq.XXXXXX") || exit 1
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
jq -e 'all(.[]; (has("both_hosts") | not) or (.both_hosts | type == "boolean"))' "$FIXTURE" >/dev/null || {
  printf 'not ok - %s: both_hosts must be true or false where a row sets it\n' "$FIXTURE"
  exit 1
}
# A bundled fixture keeps rows for Codex; one given from outside may hold a
# single row.
case "$FIXTURE" in
  "$ROOT"/tests/fixtures/*)
    jq -e 'any(.[]; .both_hosts == true and .expected_status == 0)
           and any(.[]; .both_hosts == true and .expected_status == 2)' "$FIXTURE" >/dev/null || {
      printf 'not ok - %s needs a both_hosts row that passes and one that blocks\n' "$FIXTURE"
      exit 1
    }
    ;;
esac
jq -c '.[]' "$FIXTURE" >"$CASE_ROOT/cases" || exit 1
while IFS= read -r row; do
  expected=$(printf '%s' "$row" | jq -r '.expected_status')
  name=$(printf '%s' "$row" | jq -r '.id + " (" + .classification + "): " + .description')
  # An empty host list would skip the row without a failure.
  hosts=$(printf '%s' "$row" | jq -r 'if .both_hosts == true then "claude codex" else "claude" end') \
    && [ -n "$hosts" ] || {
      printf 'not ok - %s: cannot read which hosts run the row\n' "$name"
      exit 1
    }
  for host in $hosts; do
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
printf '%s gh --jq option checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

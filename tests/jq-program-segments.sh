#!/usr/bin/env sh
# Synthetic hook inputs only: none of the fixture commands is executed.
# A jq at a command position in any segment of a command, or in a loop or
# condition body, reads its program word as jq program text, as long as no
# earlier part of the command can change which jq runs (94S-2135). File
# operands, input redirects, --rawfile, --slurpfile and -f paths stay in the
# protected-path scan. A row may set path_prefix, a relative PATH entry put
# in front of PATH for that row.
# Each fixture runs through both hosts' native event shapes.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=${AGENT_GUARD_TEST_FIXTURE:-$ROOT/tests/fixtures/jq-program-segments.json}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-jq-segments.XXXXXX") || exit 1
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
  prefix=$(printf '%s' "$row" | jq -r '.path_prefix // empty')
  name=$(printf '%s' "$row" | jq -r '.id + " (" + .classification + "): " + .description')
  for host in claude codex; do
    case "$host" in
      codex) shape='{tool_name:"Bash",tool_input:{command:.command,workdir:$d}}' ;;
      *) shape='{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:.command},cwd:$d}' ;;
    esac
    checked=$((checked + 1))
    printf '%s' "$row" | jq -c --arg d "$CASE_ROOT/work" "$shape" \
      | PATH="${prefix:+$prefix:}$PATH" AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
    status=$?
    # A shell error in the hook exits 0 under the default infrastructure
    # policy, so a must-pass row also needs a clean stderr.
    if [ "$status" -eq "$expected" ] \
      && ! grep -Eq 'unbound variable|syntax error|not found|line [0-9]+:' "$CASE_ROOT/err" \
      && { [ "$expected" -eq 0 ] || grep -Fq 'reason=bash_protected_path_text_match' "$CASE_ROOT/err"; }; then
      printf 'ok - [%s] %s\n' "$host" "$name"
    else
      printf 'not ok - [%s] %s: expected %s got %s\n' "$host" "$name" "$expected" "$status"
      sed 's/^/#   /' "$CASE_ROOT/err"
      failed=$((failed + 1))
    fi
  done
done <"$CASE_ROOT/cases"
printf '%s jq program segment checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

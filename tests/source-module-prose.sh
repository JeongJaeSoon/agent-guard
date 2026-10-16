#!/usr/bin/env sh
# Synthetic hook inputs only: none of the command strings below are executed.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-prose.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
mkdir "$CASE_ROOT/nested"
printf 'synthetic fixture\n' > "$CASE_ROOT/.env"
ln -s ../.env "$CASE_ROOT/nested/env.py"
ln -s .env "$CASE_ROOT/env.py,"
ln -s .env "$CASE_ROOT/see env.py"
failed=0
checked=0
check() {
  expected=$1
  command=$2
  checked=$((checked + 1))
  jq -nc --arg c "$command" --arg w "$CASE_ROOT" \
    '{tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
    | "$GUARD" hook-pre-tool > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'ok - source prose %s\n' "$checked"
  else
    printf 'not ok - source prose %s expected %s got %s: %s\n' "$checked" "$expected" "$status" "$command"
    failed=$((failed + 1))
  fi
}
check 0 'echo "see env.py"'
check 0 'echo "see env.py, then"'
check 0 'echo "rename the env.py module later"'
check 0 "echo 'see \`env.py\` and <env.ts>'"
check 0 "printf '%s' 'see env.py,'"
check 0 "printf '%s\n' 'see env.py,'"
check 0 'git commit -m "fix: load keys from env.py"'
check 0 "git commit --message 'fix: see env.py,'"
check 2 'echo "see .env and env.py"'
check 2 'echo "see env.py and .env.local"'
check 2 'echo "see nested/env.py"'
check 2 'cat "see env.py"'
check 2 'cat env.py,'
check 2 "eval 'cat env.py,'"
check 2 "eval echo 'cat env.py,'"
check 2 "echo 'cat env.py,' | sh"
check 2 "printf '%s' 'cat env.py,' | sh"
check 2 "eval 'cd nested && cat env.py'"
check 2 "sh -c 'cd nested && cat env.py'"
check 2 'echo "see $(cat .env) env.py"'
check 2 'echo "see `cat .env` env.py"'
check 2 'echo "see ${X@P} env.py"'
check 2 'echo "see env.py" > .env'
check 2 'git commit -m "see env.py" && cat .env'
check 2 'git commit -m "see env.py" .env'
check 2 'echo "see env.py'
# A custom deny file must keep authority over the source-name exception.
printf 'env.*\n' > "$CASE_ROOT/deny"
export AGENT_GUARD_DENY_READ_PATHS="$CASE_ROOT/deny"
check 2 'echo "see env.py"'
printf 'env.py,\n' > "$CASE_ROOT/deny"
check 2 'echo "see env.py,"'
printf 'echo\n' > "$CASE_ROOT/deny"
check 2 'echo "hello world"'
printf '%s source prose checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

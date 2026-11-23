#!/usr/bin/env sh
# Synthetic hook inputs only: no command below is executed, and every file is
# written here with placeholder text.
# An env example file (a name ending in .example, .sample or .template) that
# the repository tracks is readable through the Read tool and through a shell
# command, and so is text that only names one: a file-name filter after
# `git ls-files`, or a comment handed to a CLI that opens no file. A real env
# file, an example-named symlink to one, and a command that feeds the names to
# a reader stay blocked, and a secret inside an example file is still masked
# in the tool output.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-env-example.XXXXXX") || exit 1
CASE_ROOT=$(CDPATH= cd -P -- "$CASE_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export HOME="$CASE_ROOT/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_TRACKED_FILE_EXCEPTION AGENT_GUARD_DENY_READ_MODE AGENT_GUARD_DENY_READ_PATHS \
  AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_INFRA_FAILURE_MODE GREP_OPTIONS AI_AGENT
REPO=$CASE_ROOT/repo
mkdir -p "$HOME" "$REPO/infra"
TRACKED='.env.example infra/test-ops.env.example infra/app.env.sample infra/svc.env.template'
for f in $TRACKED; do printf 'NAME=placeholder\n' >"$REPO/$f"; done
(
  cd "$REPO" && git init -q . >/dev/null 2>&1 && git add . >/dev/null 2>&1 \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
      -c core.hooksPath=/dev/null commit -q -m fixture >/dev/null 2>&1
) || { printf 'not ok - could not build the fixture repository\n'; exit 1; }
# Untracked: a real env file, and an example-named symlink that points at it.
printf 'NAME=placeholder\n' >"$REPO/.env"
ln -s "$REPO/.env" "$REPO/infra/link.env.example"

failed=0
checked=0
# check EXPECTED HOST LABEL JSON
check() {
  checked=$((checked + 1))
  printf '%s' "$4" | (cd "$REPO" && AGENT_GUARD_HOOK_HOST=$2 "$GUARD" hook-pre-tool) >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$1" ]; then
    printf 'ok - [%s] %s\n' "$2" "$3"
  else
    printf 'not ok - [%s] %s: expected %s got %s\n' "$2" "$3" "$1" "$status"
    sed 's/^/#   /' "$CASE_ROOT/err"
    failed=$((failed + 1))
  fi
}
read_json() {
  jq -nc --arg p "$REPO/$1" --arg d "$REPO" \
    '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:$p},cwd:$d}'
}
bash_json() {
  case "$1" in
    codex) jq -nc --arg c "$2" --arg d "$REPO" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d}}' ;;
    *) jq -nc --arg c "$2" --arg d "$REPO" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}' ;;
  esac
}
shell() { # EXPECTED LABEL COMMAND, on both hosts
  for host in claude codex; do check "$1" "$host" "$2" "$(bash_json "$host" "$3")"; done
}

for f in $TRACKED; do
  check 0 claude "Read of tracked $f" "$(read_json "$f")"
  shell 0 "cat of tracked $f" "cat $f"
done
check 2 claude "Read of a real env file" "$(read_json .env)"
shell 2 "cat of a real env file" "cat .env"
check 2 claude "Read of an example-named symlink to a real env file" "$(read_json infra/link.env.example)"
shell 2 "cat of an example-named symlink to a real env file" "cat infra/link.env.example"

# Text that names an example file without opening one (the three shapes of
# the 2026-11-23 bot report), each with a control that still blocks.
shell 0 "tracked names filtered by an example-name pattern" \
  "git ls-files | grep -iE '\\.env\\.example|\\.env\\.sample|test-ops'"
shell 2 "the same names fed to a reader" \
  "git ls-files | grep -iE '\\.env\\.example|test-ops' | xargs cat"
shell 0 "an item comment that names an example file" \
  'orca bot item set 135 --comment "checked infra/test-ops.env.example against the template"'
shell 0 "an item comment that quotes a deny entry" \
  "orca bot item set 135 --comment \"the entry ('*.env.*') matched the example name\""
shell 0 "a needs-you item with a question and options" \
  'orca bot item set 135 --status needs-you --comment "the .env.example file is ready" --ask "Copy it to .env.local?" --option "Yes" --option "No"'
shell 2 "an item comment read from a real env file" 'orca bot item set 135 --comment-file .env'
shell 2 "a quoted item comment file that is a real env file" "orca bot item set 135 --comment-file '.env'"
shell 2 "a real env file attached to an item comment" 'orca bot item set 135 --comment "see attachment" --file .env'
shell 2 "an item comment built from a real env file" 'orca bot item set 135 --comment "$(cat .env)"'
shell 2 "a read after the item comment" 'orca bot item set 135 --comment "checked .env.example"; cat .env'
shell 2 "another orca command with a comment option" 'orca worktree create --comment "from .env.local" x'

# A secret inside an example file is still masked in the Read output.
S=AGENT_GUARD_TEST
S="${S}_SECRET"
post=$(jq -nc --arg p "$REPO/infra/test-ops.env.example" --arg d "$REPO" --arg c "API_TOKEN=$S" \
  '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:$p},cwd:$d,
    tool_response:{type:"text",file:{filePath:$p,content:$c,numLines:1,startLine:1,totalLines:1}}}')
checked=$((checked + 1))
printf '%s' "$post" | (cd "$REPO" && AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-post-tool) >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 0 ] && [ -s "$CASE_ROOT/out" ] && ! grep -Fq -- "$S" "$CASE_ROOT/out" "$CASE_ROOT/err"; then
  printf 'ok - [claude] Read output of an example file has its secret masked\n'
else
  printf 'not ok - [claude] Read output of an example file has its secret masked (status %s)\n' "$status"
  failed=$((failed + 1))
fi

printf '%s env example checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

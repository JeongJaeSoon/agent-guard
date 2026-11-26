#!/usr/bin/env sh
# Synthetic hook inputs only: none of the fixture commands is executed, and
# every file below is written here with placeholder text.
# A deny-read name pattern is matched against path operands. The program text
# of a known tool is not one: a jq filter (and a gh --jq value), the regexes
# of a sed script, an awk program, a grep pattern behind a gh query, and the
# inline script of python -c, node -e, perl -e and ruby -e. What can still
# name a file stays in the scan: every file operand, option value and
# redirection, every string literal that names a file, a suffix literal the
# program could build a name from, the body of sh -c and eval, a command
# substitution, and every argument of a command that is not on that list.
# Every case runs in Claude's native event shape. The host changes the block
# message and the output envelope, never the decision, and Codex's shape differs
# only in where the event carries the working directory. So only the cases
# marked "both_hosts" also run in Codex's shape: the must-pass cases whose
# result depends on the event workdir, each with the block case after it.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=${AGENT_GUARD_TEST_FIXTURE:-$ROOT/tests/fixtures/path-operands-only.json}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-operands.XXXXXX") || exit 1
CASE_ROOT=$(CDPATH= cd -P -- "$CASE_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export HOME="$CASE_ROOT/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_TRACKED_FILE_EXCEPTION AGENT_GUARD_DENY_READ_MODE GREP_OPTIONS
REPO=$CASE_ROOT/repo
SUFFIXDIR=$CASE_ROOT/suffix
mkdir -p "$HOME" "$REPO/tests/fixtures" "$SUFFIXDIR"
# The workdir: a repository with one committed fixture whose name is on the
# deny list and one untracked dotenv file. The second workdir holds a file
# named exactly like a bare suffix.
printf 'name: placeholder\n' >"$REPO/tests/fixtures/secrets.yaml"
printf 'name: placeholder\n' >"$REPO/.env"
printf 'placeholder\n' >"$SUFFIXDIR/.p8"
(
  cd "$REPO" && git init -q . >/dev/null 2>&1 \
    && git add tests >/dev/null 2>&1 \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
      -c core.hooksPath=/dev/null commit -q -m fixture >/dev/null 2>&1
) || { printf 'not ok - could not build the fixture repository\n'; exit 1; }

failed=0
checked=0
jq -e 'type == "array" and length > 0' "$FIXTURE" >/dev/null || {
  printf 'not ok - %s is not a non-empty array\n' "$FIXTURE"
  exit 1
}
# Every must-pass case is followed directly by a must-still-block case.
jq -e '. as $all | all(range(0; length); . as $i
         | $all[$i].classification == "must-still-block"
           or ($all[$i].classification == "must-pass"
               and ($all[$i + 1].classification // "") == "must-still-block"))' "$FIXTURE" >/dev/null || {
  printf 'not ok - every must-pass case in %s needs a must-still-block case right after it\n' "$FIXTURE"
  exit 1
}
# Each fixture keeps cases for Codex, and a must-pass case that runs there has
# its block case there too.
jq -e '. as $all | any(.[]; .both_hosts == true)
       and all(.[]; (.both_hosts // false) | type == "boolean")
       and all(range(0; length); . as $i
         | ($all[$i].both_hosts // false) == false
           or $all[$i].classification == "must-still-block"
           or ($all[$i + 1].both_hosts // false) == true)' "$FIXTURE" >/dev/null || {
  printf 'not ok - %s needs a both_hosts case, and each both_hosts must-pass case needs its block case marked too\n' "$FIXTURE"
  exit 1
}
jq -c --arg repo "$REPO" --arg suffix "$SUFFIXDIR" '
  .[] | .workdir = ((if .workdir == null then "@REPO@" else .workdir end) | gsub("@REPO@"; $repo) | gsub("@SUFFIXDIR@"; $suffix))' \
  "$FIXTURE" >"$CASE_ROOT/cases" || exit 1
while IFS= read -r row; do
  expected=$(printf '%s' "$row" | jq -r '.expected_status')
  name=$(printf '%s' "$row" | jq -r '.id + " (" + .classification + "): " + .description')
  hosts=$(printf '%s' "$row" | jq -r 'if .both_hosts == true then "claude codex" else "claude" end')
  for host in $hosts; do
    case "$host" in
      codex) shape='{tool_name:"Bash",tool_input:({command:.command} + (if .workdir == "" then {} else {workdir:.workdir} end))}' ;;
      *) shape='{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:.command}} + (if .workdir == "" then {} else {cwd:.workdir} end)' ;;
    esac
    checked=$((checked + 1))
    printf '%s' "$row" | jq -c "$shape" \
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
printf '%s path-operand checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

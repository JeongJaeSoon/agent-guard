#!/usr/bin/env sh
# Word splitting for the env-template and rg exclusion exceptions
# (shell_command_words). Each command is first given to the hook, then run for
# real in a scratch directory whose protected-looking files hold only a
# marker: a must-fail command must be blocked and must print a marker when
# run, a must-pass command must be allowed and must print none.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-shell-words.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
RUN_SHELL=$(command -v bash) || RUN_SHELL=/bin/sh
W=$CASE_ROOT/work
mkdir "$W" || exit 1
printf 'MARK_PEM\n' > "$W/!secret.pem"
printf 'MARK_RSA\n' > "$W/id_rsa"
printf 'MARK_ENV\n' > "$W/.env"
printf 'X=1\n' > "$W/.env.example"
for f in 'x;rg' 'x|rg' 'x&&rg' x foo src; do printf 'plain\n' > "$W/$f"; done
NL='
'
TAB='	'
failed=0
checked=0
note() { printf 'not ok - shell words %s: %s\n' "$checked" "$1"; failed=$((failed + 1)); }
case_run() {
  expected=$1 label=$2 command=$3
  checked=$((checked + 1))
  label="$HOST: $label"
  jq -nc --arg c "$command" --arg w "$W" \
    '{tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
    | AGENT_GUARD_HOOK_HOST=$HOST "$GUARD" hook-pre-tool > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -ne "$expected" ]; then
    note "$label: expected $expected got $status"
    sed 's/^/#   /' "$CASE_ROOT/err"
    return
  fi
  # Ground truth: the same text, run by a real shell.
  case "$expected:$command" in
    2:rg\ *) command -v rg >/dev/null 2>&1 || {
      printf 'ok - shell words %s: %s # skip run, rg missing\n' "$checked" "$label"; return; } ;;
  esac
  ran=$(cd "$W" && SHELL=$RUN_SHELL "$RUN_SHELL" -c "$command" 2>&1 < /dev/null)
  case "$ran" in *MARK_*) leaked=1 ;; *) leaked=0 ;; esac
  if [ "$expected" -eq 2 ] && [ "$leaked" -eq 0 ]; then
    note "$label: blocked, but the real shell read no protected file (bad fixture)"
  elif [ "$expected" -eq 0 ] && [ "$leaked" -eq 1 ]; then
    note "$label: allowed, but the real shell read a protected file"
  else
    printf 'ok - shell words %s: %s\n' "$checked" "$label"
  fi
}

for HOST in claude codex; do

# Must fail. A quoted, substituted or expanded `;`, `|` or `&&` is no command
# boundary, so the rg exclusion exception does not apply to what follows.
case_run 2 "quoted ; does not start an rg segment" "sort \"x;rg\" -g '!secret.pem'"
case_run 2 "quoted | does not start an rg segment" "sort 'x|rg' -g '!secret.pem'"
case_run 2 "quoted && does not start an rg segment" "sort 'x&&rg' -g '!secret.pem'"
case_run 2 "a ; inside \$(...) does not start an rg segment" "sort \$(echo x;rg ) -g '!secret.pem'"
case_run 2 "a ; inside \${...} does not start an rg segment" "sort \${unset_v:-x;rg } -g '!secret.pem'"
# A lone & ends the rg segment.
case_run 2 "a lone & ends an rg segment" "rg zz x & sort -g '!secret.pem'"
case_run 2 "an unspaced & ends an env template word" "cat .env&x.env.example"
# A newline survives, so the multi-line check of the quoted-bracket
# normalization still sees the second line.
case_run 2 "a second line keeps a python glob in the scan" \
  "python3 -c 'print(\"cat id_r?a\")' | sort -o c${NL}\$SHELL c"
# Brace expansion turns the exclusion value into a second word rg opens.
case_run 2 "a brace exclusion value names a second operand" "rg MARK -g !{x,secret}.pem"
# Controls that were blocked before this change and must stay blocked.
case_run 2 "quoted ; before -g that keeps its quote" "cat \"x;rg -g\" '!secret.pem'"
case_run 2 "quoted | before -g that keeps its quote" "cat 'x|rg -g' '!secret.pem'"
case_run 2 "an exclusion value that runs a substitution" "rg -g \"!\$(cat .env >&2)\" zz x"
case_run 2 "an env template word with ; under eval" "eval cat '.env;x.env.example'"
case_run 2 "a dotenv read next to a template" "cat .env.example .env"
case_run 2 "a dotenv read on its own line" "cat .env.example${NL}cat .env"
case_run 2 "a spaced & before a dotenv read" "cat .env & x.env.example"
case_run 2 "a direct sort of the exclusion value" "sort -g '!secret.pem'"
case_run 2 "a dotenv read before a comment naming a template" "cat .env # .env.example"
case_run 2 "a dotenv read after a comment line naming a template" "# see .env.example${NL}cat .env"

# Must pass: ordinary quoted, multi-line and redirected commands keep both
# exceptions.
case_run 0 "rg negative glob" "rg -g '!*.pem' MARK_PEM ."
case_run 0 "rg negative glob after a quoted operand with two blanks" "rg -g '!*.pem' \"two  words\" foo src"
case_run 0 "rg negative glob after ;" "echo a; rg -g '!secret.pem' MARK_PEM foo"
case_run 0 "rg negative glob on a second line" "echo a${NL}rg -g '!*.pem' MARK_PEM ."
case_run 0 "rg negative glob with a substituted operand" "rg -g '!*.pem' MARK_PEM \"\$(pwd)\""
case_run 0 "env template" "cat .env.example"
case_run 0 "quoted env template" "cat \".env.example\""
case_run 0 "env template on a second line" "echo hi${NL}cat .env.example"
case_run 0 "env template after a comment with an apostrophe" "# don't${NL}cat .env.example"
case_run 0 "env template named again in a comment" "cat .env.example # inspect .env.example"
case_run 0 "env template after a tab" "cat${TAB}.env.example"
case_run 0 "env template after ;" "echo a ;cat .env.example"
case_run 0 "env template with 2>&1" "cat .env.example 2>&1 | head -1"
case_run 0 "env template after a quoted assignment" "X='a b' cat .env.example"
done

[ "$failed" -eq 0 ] || { printf '%s shell word checks, %s failed\n' "$checked" "$failed"; exit 1; }
printf 'passed: %s\n' "$checked"

#!/bin/sh
# A bare `$name` after a credential key is a variable reference only inside a
# brace or parenthesis expression: a jq filter reading `--arg k`
# (`{private_key:$k}`). There it is not a value, for the prompt guard or for
# PostToolUse output masking. Anywhere else a letters-only `$name` cannot be
# told from a password of letters, and a `$` value that carries a digit or a
# second `$` (bcrypt, argon2) always stays a value.
#
# Controls: the hash-shaped values below must still block and still mask. Their
# tails are random per run, so no literal in this file looks like a credential.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-bare-var.XXXXXX") || exit 1
trap 'rm -rf "$CASE"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_HOOK_HOST=claude
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"

rnd=$(od -An -N20 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
bcrypt='$2b$12$'"$rnd"
argon='$argon2id$v=19$m=65536$'"$rnd"
digit='$9'"$rnd"
q='"'

failed=0
checked=0
verdict() { # $1 label, $2 ok(0/1), $3 detail
  checked=$((checked + 1))
  if [ "$2" -eq 0 ]; then
    printf 'ok - %s\n' "$1"
  else
    printf 'not ok - %s\n' "$1"
    [ -z "$3" ] || printf '  %s\n' "$3"
    failed=$((failed + 1))
  fi
}

prompt() { # $1 expected exit, $2 label, $3 prompt text
  jq -nc --arg p "$3" '{session_id:"t",hook_event_name:"UserPromptSubmit",prompt:$p}' \
    | "$BIN" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
  status=$?
  [ "$status" -eq "$1" ]
  verdict "prompt guard $2" $? "expected $1 got $status"
}

post_tool() { # $1 must-mask(1)/untouched(0), $2 label, $3 stdout text
  jq -nc --arg o "$3" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$o,stderr:"",interrupted:false,isImage:false}}' \
    | "$BIN" hook-post-tool >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$1" -eq 0 ]; then
    [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ]
  else
    [ "$status" -eq 0 ] && [ -s "$CASE/out" ] && ! grep -qF -- "\$$rnd" "$CASE/out"
  fi
  verdict "post-tool $2" $? "status $status"
}

jq_arg='jq -n --arg k '"$q"'$K'"$q"' '\''{kid:"x",private_key:$k}'\'
jq_arg_space='jq -n --arg k '"$q"'$K'"$q"' '\''{kid:"x",private_key: $k}'\'

# Must pass: a variable reference is not a value.
prompt 0 "allows a jq --arg reference" "$jq_arg"
prompt 0 "allows a jq --arg reference with a space" "$jq_arg_space"
jq_next_key='jq -n --arg k '"$q"'$K'"$q"' '\''{private_key:$k,kid:"x"}'\'
prompt 0 "allows a reference followed by the next key of the expression" "$jq_next_key"
post_tool 0 "leaves a jq --arg reference untouched" "$jq_arg"
post_tool 0 "leaves a reference followed by the next key untouched" "$jq_next_key"

# Outside a brace or parenthesis expression the name is indistinguishable from
# a password that happens to be letters, so a line end or a space keeps it a value.
prompt 2 "blocks a name at the end of an env assignment" 'PRIVATE_KEY=$KEY'
prompt 2 "blocks a name after a label" 'password: $PASSWORD'
prompt 2 "blocks random letters after a label" "password: \$$rnd"
prompt 2 "blocks a name followed by a spaced shell separator" "export PRIVATE_KEY=\$$rnd; echo done"
prompt 2 "blocks random letters inside an expression with a space after" "{${q}private_key${q}: \$$rnd }"
# A quote before the closer ends a quoted string, not a variable use.
prompt 2 "blocks random letters at the end of a quoted string inside parentheses" "(echo 'password: \$$rnd')"
prompt 2 "blocks random letters at the end of a quoted string inside braces" "{echo 'password: \$$rnd'}"
post_tool 1 "masks random letters at the end of a quoted string inside parentheses" "(echo 'password: \$$rnd')"
post_tool 1 "masks a name at the end of an env assignment" 'PRIVATE_KEY=$KEY'
post_tool 1 "masks random letters after a label" "password: \$$rnd"

# Must block or mask: the same keys with a hash-shaped value.
prompt 2 "blocks a bcrypt value" "DB_PASSWORD=$bcrypt"
prompt 2 "blocks an argon2 value" "DB_PASSWORD=$argon"
prompt 2 "blocks a dollar-digit value" "DB_PASSWORD=$digit"
prompt 2 "blocks a letter-digit-dollar value" "DB_PASSWORD=\$k9\$$rnd"
prompt 2 "blocks a letters-then-dollar value" "DB_PASSWORD=\$argon\$$rnd"
prompt 2 "blocks a bare dollar value in JSON" "{${q}private_key${q}:\$k9\$$rnd}"
prompt 2 "blocks a bcrypt value in JSON" "{${q}private_key${q}:${q}$bcrypt${q}}"
# The token ends at a delimiter, so text glued to the name after `;` or `,` is
# part of a value, while a shell separator followed by a space ends a command.
prompt 2 "blocks a name followed by glued text after a semicolon" "password: \$$rnd;$rnd"
prompt 2 "blocks a name followed by glued text after a comma" "password: \$$rnd,$rnd"
post_tool 1 "masks a name followed by glued text after a semicolon" "password: \$$rnd;$rnd"
post_tool 1 "masks a bcrypt value" "DB_PASSWORD=$bcrypt"
post_tool 1 "masks an argon2 value" "DB_PASSWORD=$argon"
post_tool 1 "masks a bcrypt value in JSON" "{${q}private_key${q}:${q}$bcrypt${q}}"

printf '%s bare variable reference checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

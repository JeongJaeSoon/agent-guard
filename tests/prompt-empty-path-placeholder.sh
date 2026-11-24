#!/usr/bin/env sh
# Synthetic prompts only. An empty value, a bare key-file path, an environment
# reference or an obvious placeholder after a secret-named key is not a value;
# a real-looking value in each shape, or next to the path, stays blocked.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-empty-path.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_HOOK_HOST=claude
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
# Random per run, so no literal in this file looks like a credential. The
# prefix makes it credential-shaped whatever the digits are.
val=Q7$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')
# Key names built at run time keep KEY=value literals out of this file.
k=API_$(printf TOK)EN
pw=DB_PASS$(printf WORD)
f=$k$(printf _FILE)
p=/run/secrets/api_token
bt=$(printf '\140')
fence=$bt$bt$bt
nl='
'
failed=0
checked=0
check() {
  expected=$1
  label=$2
  prompt=$3
  checked=$((checked + 1))
  jq -nc --arg p "$prompt" '{prompt:$p}' \
    | "$GUARD" hook-user-prompt > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'ok - prompt empty/path %s: %s\n' "$checked" "$label"
  else
    printf 'not ok - prompt empty/path %s: %s: expected %s got %s\n' "$checked" "$label" "$expected" "$status"
    failed=$((failed + 1))
  fi
}

# A bare key-file path.
check 0 "absolute key-file path" "$k=$p"
check 0 "exported key-file path" "export $pw=/run/secrets/db_password"
check 0 "home-relative path" "$k=~/.config/app/token"
check 0 "dot-relative path" "$k=./secrets/api_token"
check 0 "parent-relative path with a numbered name" "$k=../secrets/api_token_2"
check 0 "path in a code span" "Use $bt$k=$p$bt"
check 0 "path in a fenced block" "Run:$nl${fence}sh$nl$k=$p$nl$fence"
check 0 "path in double quotes" "$k=\"$p\""
check 0 "_FILE variable with a path" "$f=$p"
check 2 "random segment in a path" "$k=/run/secrets/$val"
check 2 "random value after one slash" "$k=/$val"
check 2 "single-segment absolute word" "$k=/hunterpass"
check 2 "route path outside a filesystem root" "$k=/v1/providers/rotation"
check 2 "real-looking value after the path" "$k=$p $val"
check 2 "real-looking value before a path" "$k=$val $p"
check 2 "random segment in a quoted path" "$k=\"/run/secrets/$val\""
check 2 "real-looking value after a quoted path" "$k=\"$p\" $val"
check 0 "quoted path in a fenced block" "${fence}$nl$k=\"$p\"$nl$fence"
check 2 "value glued to a path by a colon" "$k=$p:$val"
check 2 "real value next to a _FILE path" "$f=$p $k=$val"
check 2 "symbol password after the path" "$pw=/run/secrets/db_password p@ss!wd"
check 2 "real-looking value on the line below a path" "$k=$p$nl$val"
check 2 "short words after the path" "$k=$p correct horse battery staple"
check 2 "value glued to a fence line below a path" "${fence}$nl$k=$p$nl${fence}$val"
check 2 "long lowercase run glued to a fence line below a path" "$k=$p$nl${fence}$(printf '%s' "$val" | tr 'A-Z0-9' 'a-zabcdefghij')qwertyuiopasdf"
check 0 "fence with a language name below a path" "$k=$p$nl${fence}properties"
check 2 "short value glued to a fence line below a path" "$k=$p$nl${fence}$(printf '%.10s' "$val")"

# An obvious placeholder (#543 keeps changeme a value).
# changeme is also a real default password, so it stays a value (#543).
check 2 "changeme" "$k=changeme"
check 2 "change-me" "$pw=change-me"
check 0 "x run" "$k=xxxxxxxx"
check 0 "your-token" "$k=your-token"
check 0 "your_api_token" "$k=your_api_token"
check 0 "angle placeholder" "$k=<your-token>"
check 0 "placeholder in a fenced block" "${fence}$nl$k=xxxxxxxx$nl$fence"
check 2 "x run glued to a value" "$k=xxxx$val"
check 2 "your- before a value" "$k=your-$val"
check 2 "your- before unlisted words" "$k=your-horse-battery"
check 2 "real value in a fenced block" "${fence}$nl$k=$val$nl$fence"
check 2 "real value after your-token" "$k=your-token $val"
check 2 "real value after an x run" "$k=xxxxxxxx $val"
check 2 "real value on the line below an x run" "$k=xxxxxxxx$nl$val"
check 2 "real value after a quoted your-token" "$k=\"your-token\" $val"

# An environment reference.
check 0 "braced reference" "$k=\${OTHER_TOKEN}"
check 0 "bare reference" "$k=\$OTHER_TOKEN"
check 0 "reference with an empty default" "$k=\${OTHER_TOKEN:-}"
check 2 "reference glued to a value" "$k=\$OTHER$val"

# An empty value.
check 0 "empty at the end of the line" "Set $k=$nl then run."
check 0 "empty double quotes" "$k=\"\""
check 0 "empty in a fenced block" "${fence}sh$nl$k=$nl$fence"
check 2 "real value after an empty code span" "Leave $bt$k=$bt $val"
check 2 "symbol password after an empty code span" "Leave $bt$k=$bt p@ss!wd here"
check 2 "ten digits after an empty code span" "Leave $bt$k=$bt 4829105736"
check 2 "real value after the delimiter and a space" "Set $k= $val"
check 2 "empty double quotes glued to a value" "$k=\"\"$val"

printf '%s prompt empty/path checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

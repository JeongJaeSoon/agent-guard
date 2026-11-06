#!/bin/sh
# Source text that merely names a runtime environment object (`process.env.X`,
# `import.meta.env`, `Bun.env`, `Deno.env`) or a jq field (`"\(.key)"`) is not a
# protected-file read. The hook-only checks are never executed. Controls: a file
# that really has the runtime-global name, a path-shaped name and the plain
# protected files must stay blocked, and the leak control proves the harness can
# see a canary when the same text is a file operand.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-runtime-global.XXXXXX") || exit 1
trap 'rm -rf "$CASE"' 0 HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
canary=agcanary$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')

# W holds no runtime-global-named file; X holds one of each name; Y has them
# one directory down.
W="$CASE/w" X="$CASE/x" Y="$CASE/y"
mkdir -p "$W" "$X" "$Y/sub"
printf 'VALUE=%s\n' "$canary" >"$W/.env"
printf '{"key":"%s"}\n' "$canary" >"$W/server.key"
for f in process.env process.env.local import.meta.env Bun.env Deno.env; do
  printf 'VALUE=%s\n' "$canary" >"$X/$f"
  printf 'VALUE=%s\n' "$canary" >"$Y/sub/$f"
done
printf '{"a":1}\n' >"$W/data.json"

pass=0 fail=0 n=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

gate() { # $1 workdir, $2 command
  n=$((n + 1))
  jq -nc --arg c "$2" --arg d "$1" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | "$BIN" hook-pre-tool >/dev/null 2>"$CASE/err"
}

check() { # $1 expected status, $2 workdir, $3 command
  gate "$2" "$3"
  status=$?
  if [ "$status" -eq "$1" ]; then
    ok "runtime global $n: expected $1"
  else
    bad "runtime global $n: expected $1 got $status: $3"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
}

# Source text in a directory that holds no file of that name.
check 0 "$W" "node -e 'console.log(process.env.HOME)'"
check 0 "$W" 'node -e "console.log(process.env.PORT ?? 3000)"'
check 2 "$W" "node -e 'const {PORT} = process.env; console.log(PORT)'"
check 2 "$W" "node -e 'console.log(process.env)'"
check 2 "$W" "node -e 'console.log(JSON.stringify(process.env))'"
check 2 "$W" "node -e 'console.log({...process.env})'"
check 2 "$W" 'deno eval "console.log(Deno.env.toObject())"'
check 2 "$W" "bun -e 'console.log(Bun.env.valueOf())'"
check 2 "$W" "node -e 'console.log(process.env.valueOf())'"
check 2 "$W" 'echo "a\"b"; cat process.env.A'
check 0 "$W" "node -e 'console.log(process.env.PORT.toString())'"
# An object-level method hands back the whole environment at any chain length,
# and when it is only referenced and called later.
check 2 "$W" "deno eval 'console.log(Deno.env.toObject.call(null))'"
check 2 "$W" "deno eval 'console.log(Deno.env[\"toObject\"].call(null))'"
check 2 "$W" "deno eval 'const f = Deno.env.toObject; console.log(f())'"
check 2 "$W" "node -e 'const f = process.env.valueOf; console.log(f.call(process))'"
check 2 "$W" "bun -e 'console.log(Bun.env.entries.call(null))'"
# A quoted word with no code in it may be a file operand; only the pattern of a
# grep-family command is text.
check 2 "$W" "tar -xOf config.tar 'process.env.PORT'"
check 2 "$W" "tar -xOf config.tar \"process.env.PORT\""
check 2 "$W" "cat 'process.env.PORT'"
check 2 "$W" "grep -f 'process.env.PORT' data.json"
check 2 "$W" "grep -e x 'process.env.PORT'"
check 2 "$W" "grep -n x | tar -xOf config.tar 'process.env.PORT'"
check 0 "$W" "grep -n 'process.env.PORT' data.json"
check 0 "$W" "rg -n \"process.env.PORT\" ."
check 0 "$W" "grep -rn 'import.meta.env.DEV' . | wc -l"
check 0 "$W" "deno eval \"console.log(Deno.env.get('PORT'))\""
check 2 "$W" "cat <<EOF
it's
EOF
cat Bun.env.x"
check 2 "$W" "cat process.env.PORT"
check 2 "$W" "echo process.env.PORT"
check 0 "$W" "node -e 'console.log(process.env[\"NODE_ENV\"])'"
check 0 "$W" "bun -e 'console.log(Bun.env.PORT)'"
check 0 "$W" "deno eval 'console.log(Deno.env.get(\"HOME\"))'"
check 0 "$W" "node --input-type=module -e 'console.log(import.meta.env.DEV)'"
check 0 "$W" "cd $W && node -e 'console.log(process.env.HOME)'"
check 0 "$W" "node -e 'console.log(process.env.A, process.env.B)' && ls"
check 0 "$W" "echo 'uses process.env.PORT' | wc -l"
check 0 "$W" "python3 -c 'import os; print(\"process.env.PORT\")'"
# A quoted file operand is not text however the word looks; only a command
# known to treat the word as text qualifies.
check 2 "$W" "tar -xOf /dev/stdin 'process.env.PORT '"
check 2 "$W" "tar -xOf /dev/stdin ' process.env.PORT'"
check 2 "$W" "tar -xOf a.tar 'x process.env.PORT y'"
check 2 "$W" "tar -xOf a.tar 'f(process.env.PORT)'"
check 2 "$W" "unzip -p a.zip 'process.env.PORT '"
check 2 "$W" "7z x -so a.7z 'process.env.PORT '"
check 2 "$W" "bsdtar -xOf a.tar 'process.env.PORT '"
check 2 "$W" "node app.js -e 'process.env.PORT '"
# echo and printf output that becomes a file operand is not text.
check 2 "$W" "echo 'process.env.PORT ' | xargs -I{} tar -xOf config.tar '{}'"
check 2 "$W" "printf '%s' 'process.env.PORT ' | xargs tar -xOf config.tar"
check 2 "$W" "echo 'process.env.PORT ' | wc -l | xargs tar -xOf config.tar"
check 2 "$W" "tar -xOf config.tar \"\$(echo 'process.env.PORT ')\""
check 2 "$W" "(echo 'process.env.PORT ') | xargs tar -xOf config.tar"
check 0 "$W" "echo 'process.env.PORT' | sort | uniq -c"
check 0 "$W" "echo 'process.env.PORT' || ls"
check 2 "$W" "env X=1 tar -xOf a.tar 'process.env.PORT '"
check 2 "$W" "command tar -xOf a.tar 'process.env.PORT '"
check 0 "$W" "env NODE_ENV=test node -e 'console.log(process.env.PORT)'"
check 0 "$W" "command node -e 'console.log(process.env.PORT)'"

# A jq field chain inside a string interpolation is program text.
check 0 "$W" "jq -r 'to_entries[] | \"\\(.key) \\(.value)\"' data.json"
check 0 "$W" "jq -c '.[] | \"k=\\(.key)\"' data.json"
check 0 "$W" "jq -r '.a | tostring | \"\\(.) \\(.key)\"' data.json"

# The same text is a read when it names a file that exists here.
check 2 "$X" "cat process.env"
check 2 "$X" "node -e 'console.log(process.env.HOME)'"
check 2 "$X" "node -e 'console.log(process.env.local)'"
check 2 "$X" "bun -e 'console.log(Bun.env.PORT)'"
check 2 "$X" "deno eval 'console.log(Deno.env.get(1))'"
check 2 "$X" "node --input-type=module -e 'console.log(import.meta.env.DEV)'"
# One cd to a static directory, or several, moves the relative names.
check 2 "$Y" "cd sub && node -e 'console.log(process.env.HOME)'"
check 2 "$Y" "cd ./sub && cat process.env"
check 2 "$Y" "cd sub; cd .. ; node -e 'console.log(process.env.HOME)'"
check 2 "$Y" "git -C sub show HEAD:x; node -e 'console.log(process.env.HOME)'"
check 2 "$Y" "cd \"\$SUB\" && node -e 'console.log(process.env.HOME)'"
# A name with a directory part, an absolute path, or a dotted prefix is a path.
check 2 "$W" "cat ./process.env"
check 2 "$W" "cat sub/process.env"
check 2 "$W" "cat $X/process.env"
check 2 "$W" "cat app.process.env"
check 2 "$W" "cat my-process.env"
check 2 "$W" "node -e 'x' $X/process.env.local"
# The protected files stay protected next to runtime-global text.
check 2 "$W" "cat .env"
check 2 "$W" "node -e 'console.log(process.env.HOME)'; cat .env"
check 2 "$W" "node -e 'console.log(process.env.HOME)' < .env"
check 2 "$W" "cat server.key"
check 2 "$W" "jq -r '\"\\(.key)\"' server.key"
check 2 "$W" "jq -r '\"\\(\"server.key\")\"' data.json"
check 2 "$W" "jq -r 'include \"server.key\"; .' data.json"
check 2 "$W" "jq -r '\"\\(.key)\" ' -f server.key"
check 2 "$W" "jq -r '\"\\(.key)\"' < server.key"

# Leak control: the canary reaches the output when the file is read, so the
# blocked cases above are not blocked on a harness that cannot see a leak.
leak=$(cd "$X" && cat process.env 2>/dev/null)
case "$leak" in
  *"$canary"*) ok "leak control: reading the real file shows the canary" ;;
  *) bad "leak control: canary missing" ;;
esac

printf '# pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

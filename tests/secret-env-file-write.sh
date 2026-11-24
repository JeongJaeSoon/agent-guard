#!/bin/sh
# A command that writes the value of a secret-named environment variable to a
# file (#497): a $NAME or ${NAME} expansion in a command with a > or >>
# redirect, or in the body of an unquoted here-document.
#
# Ground truth, not the verdict alone: every case also runs in bash with a
# random canary in the secret-named variable, and the gate must block exactly
# the cases whose run left the canary in a file under the work directory.
# Must-pass neighbours (a non-secret variable, a literal, a quoted delimiter, an
# escaped or single-quoted name, a length, a test, stderr, /dev/null) prove the
# rule is not "any redirect".
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-secret-env-write.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0 HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
canary=9$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')
tab=$(printf '\t')

pass=0 fail=0 n=0 blocked=0 allowed=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

check() { # $1 expected status, $2 command
  n=$((n + 1))
  w="$CASE/w$n"
  mkdir -p "$w/notes"
  ( cd "$w" && EXAMPLE_SECRET_TOKEN=$canary EXAMPLE_NOTE=public-note \
      bash -c "$2" >/dev/null 2>&1 )
  if grep -rqF -- "$canary" "$w"; then truth=2; else truth=0; fi
  rm -rf "$w"
  mkdir -p "$w/notes"
  if [ "$truth" -ne "$1" ]; then
    bad "case $n: ground truth $truth differs from expected $1: $2"
    return
  fi
  for host in claude codex; do
    jq -nc --arg c "$2" --arg d "$w" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"secret-env-write"}' \
      | AGENT_GUARD_HOOK_HOST=$host "$BIN" hook-pre-tool >/dev/null 2>"$CASE/err"
    status=$?
    if [ "$status" -ne "$1" ]; then
      bad "case $n ($host): expected $1 got $status: $2"
      sed 's/^/  stderr: /' "$CASE/err"
      continue
    fi
    if [ "$status" -eq 2 ] && ! grep -q 'reason=bash_secret_env_value_file_write' "$CASE/err"; then
      bad "case $n ($host): blocked for another reason: $2"
      sed 's/^/  stderr: /' "$CASE/err"
      continue
    fi
    ok "case $n ($host): $1"
  done
  if [ "$1" -eq 2 ]; then blocked=$((blocked + 1)); else allowed=$((allowed + 1)); fi
}

# Must block: the shapes from #497 and their close variants.
check 2 'cat > notes/note.md <<EOF
$EXAMPLE_SECRET_TOKEN
EOF'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md'
check 2 'echo "${EXAMPLE_SECRET_TOKEN}" >> notes/note.md'
check 2 'echo $EXAMPLE_SECRET_TOKEN>notes/note.md'
check 2 'printf '"'"'%s\n'"'"' "$EXAMPLE_SECRET_TOKEN" > notes/note.md'
check 2 'cat <<EOF > notes/note.md
token=${EXAMPLE_SECRET_TOKEN}
EOF'
check 2 "cat <<-EOF > notes/note.md
${tab}value: \$EXAMPLE_SECRET_TOKEN
${tab}EOF"
check 2 'mkdir -p notes && echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" | cat > notes/note.md'
check 2 'cat <<< "$EXAMPLE_SECRET_TOKEN" > notes/note.md'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" 1> notes/note.md'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" &> notes/note.md'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" >| notes/note.md'
check 2 '>notes/note.md echo "$EXAMPLE_SECRET_TOKEN"'
check 2 'echo "x${EXAMPLE_SECRET_TOKEN:-}" > notes/note.md'
check 2 'echo start; echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md; echo done'
check 2 'cat > notes/a.md <<'"'"'A'"'"'
$EXAMPLE_SECRET_TOKEN
A
cat > notes/b.md <<B
$EXAMPLE_SECRET_TOKEN
B'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" |
  cat > notes/note.md'
check 2 'bash -c '"'"'echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md'"'"
check 2 'bash -c '"'"'echo "$EXAMPLE_SECRET_TOKEN"'"'"' > notes/note.md'
check 2 '(echo "$EXAMPLE_SECRET_TOKEN";) > notes/note.md'
check 2 '{ echo "$EXAMPLE_SECRET_TOKEN"; } > notes/note.md'
check 2 'for i in 1; do echo "$EXAMPLE_SECRET_TOKEN"; done > notes/note.md'
check 2 'if true; then
  echo "$EXAMPLE_SECRET_TOKEN"
fi > notes/note.md'
check 2 'echo "$(printf %s "$EXAMPLE_SECRET_TOKEN")" > notes/note.md'
check 2 'echo "$(echo $EXAMPLE_SECRET_TOKEN > notes/note.md)"'
check 2 'printf %s "$EXAMPLE_SECRET_TOKEN" 2> notes/note.md >&2'
check 2 'eval '"'"'echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md'"'"
check 2 'bash -c "echo \"\$EXAMPLE_SECRET_TOKEN\"" > notes/note.md'
check 2 'echo out=$EXAMPLE_SECRET_TOKEN > notes/note.md'
check 2 'echo out="$EXAMPLE_SECRET_TOKEN" > notes/note.md'
check 2 'eval '"'"'echo "$EXAMPLE_SECRET_TOKEN"'"'"' > notes/note.md'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" 3> notes/note.md >&3'
check 2 'trap '"'"'echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md'"'"' EXIT'
check 2 'case x in x) echo "$EXAMPLE_SECRET_TOKEN";; esac > notes/note.md'
check 2 'T=$(echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md) true'
check 2 'echo "$EXAMPLE_SECRET_TOKEN" | cat > notes/note.md | cat'
check 2 '{ printf %s "$EXAMPLE_SECRET_TOKEN" >&2; } 2> notes/note.md'
check 2 'cat > notes/a.md <<A; cat > notes/b.md <<'"'"'B'"'"'
$EXAMPLE_SECRET_TOKEN
A
$EXAMPLE_SECRET_TOKEN
B'

# Must pass: neighbours that write no secret value to a file.
check 0 'echo "$EXAMPLE_NOTE" > notes/note.md'
check 0 'echo "hello world" > notes/note.md'
check 0 'cat > notes/note.md <<EOF
$EXAMPLE_NOTE
EOF'
check 0 'cat > notes/note.md <<'"'"'EOF'"'"'
$EXAMPLE_SECRET_TOKEN
EOF'
check 0 'cat > notes/note.md <<"EOF"
${EXAMPLE_SECRET_TOKEN}
EOF'
check 0 'cat > notes/note.md <<\EOF
$EXAMPLE_SECRET_TOKEN
EOF'
check 0 'cat > notes/note.md <<EOF
\$EXAMPLE_SECRET_TOKEN
EOF'
check 0 'echo '"'"'$EXAMPLE_SECRET_TOKEN'"'"' > notes/note.md'
check 0 'echo \$EXAMPLE_SECRET_TOKEN > notes/note.md'
check 0 'echo "${#EXAMPLE_SECRET_TOKEN}" > notes/len.txt'
check 0 'test -n "$EXAMPLE_SECRET_TOKEN" && echo present > notes/note.md'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" > /dev/null'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" >&2'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" 2>/dev/null'
check 0 'echo "EXAMPLE_SECRET_TOKEN is set" > notes/note.md'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" 2> notes/err.log'
check 0 'echo ok > "notes/a b"; echo '"'"'$EXAMPLE_SECRET_TOKEN'"'"
check 0 'bash -c '"'"'echo "$EXAMPLE_NOTE" > notes/note.md'"'"
check 0 'cat >/dev/null <<EOF
$EXAMPLE_SECRET_TOKEN
EOF'
check 0 '{ echo "$EXAMPLE_NOTE"; } > notes/note.md'
check 0 'cat >/dev/null <<EOF
$EXAMPLE_SECRET_TOKEN
EOF
echo safe > notes/note.md'
check 0 'test -n "$EXAMPLE_SECRET_TOKEN" > notes/note.md'
check 0 'if [ -n "$EXAMPLE_SECRET_TOKEN" ]; then echo present; fi > notes/note.md'
check 0 '{ printf %s "$EXAMPLE_SECRET_TOKEN" >&2; } 2>/dev/null > notes/note.md'
check 0 'echo "${EXAMPLE_SECRET_TOKEN:+present}" > notes/note.md'
check 0 'FORWARDED="$EXAMPLE_SECRET_TOKEN" printf safe > notes/note.md'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" | cat >/dev/null | cat > notes/note.md'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" >/dev/null | cat > notes/note.md'
check 0 'bash -c '"'"'echo "$EXAMPLE_SECRET_TOKEN" > /dev/null'"'"' > notes/note.md'
check 0 'echo safe > notes/note.md; bash -c '"'"'test -n "$EXAMPLE_SECRET_TOKEN"'"'"
check 0 'cat >/dev/null <<EOF; echo ok
$EXAMPLE_SECRET_TOKEN
EOF'
check 0 'echo "$EXAMPLE_SECRET_TOKEN" > notes/note.md >/dev/null'
check 0 '(echo "$EXAMPLE_SECRET_TOKEN"; echo hi) 2> notes/err.log'
check 0 'bash -c '"'"'echo "$EXAMPLE_SECRET_TOKEN"'"'"' 2>/dev/null'

printf '# blocked=%s allowed=%s\n' "$blocked" "$allowed"
# Both control groups must have run, or the comparison proved nothing.
[ "$blocked" -ge 25 ] && [ "$allowed" -ge 20 ] || bad "control groups too small: blocked=$blocked allowed=$allowed"
printf '# pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

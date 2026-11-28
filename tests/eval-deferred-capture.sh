#!/bin/sh
# An eval whose text defers a command substitution or copies one named variable
# (`eval "sid=\$(sqlite3 ...)"`, `eval "$k=\$v"`) does only what the same text
# does without eval, so the eval deny pattern (item 613) leaves it to the other
# checks. An eval whose text builds a variable name at run time (`\$$n`,
# `\${$n}`, `\$A$n`, `\${!n}`) reads a value the command never names and stays
# blocked.
#
# Controls: every capture of a secret source stays blocked directly, through a
# command substitution and through eval. The ground-truth rows run under bash
# with stub database clients and a canary variable: each allowed row assigns
# the stub's ids and never prints the canary, and each blocked indirect row
# really prints it, so the verdicts are tied to what the shell does.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-eval-capture.XXXXXX") || exit 1
trap 'rm -rf "$CASE"' 0 HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
# The rows expect a plain session in the default failure mode.
unset AGENT_GUARD_SESSION_ROLE AGENT_GUARD_INFRA_FAILURE_MODE
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
W="$CASE/w"
mkdir -p "$W" "$CASE/stub"
canary=9$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')
sid=5f0c1a2e-7b3d-4c8e-9a61-2d4b8e0f3c17
rid=c2e9d4b1-0a6f-4e3a-8b72-91f5d3a0e6b4

pass=0 fail=0 n=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

check() { # $1 expected status, $2 command
  n=$((n + 1))
  jq -nc --arg c "$2" --arg d "$W" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | "$BIN" hook-pre-tool >/dev/null 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$1" ]; then
    ok "eval capture $n: expected $1"
  else
    bad "eval capture $n: expected $1 got $status: $2"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
}

# Stub database clients print name=value lines when the query asks for them,
# else one id, as the reported stack's clients did.
for client in sqlite3 psql mysql docker; do
  {
    printf '#!/bin/sh\n'
    printf 'case "$*" in\n'
    printf "  *SESSION_ID*) printf 'SESSION_ID=%%s\\\\nREQUEST_ID=%%s\\\\n' %s %s ;;\n" "$sid" "$rid"
    printf "  *) printf '%%s\\\\n' %s ;;\n" "$sid"
    printf 'esac\n'
  } >"$CASE/stub/$client"
  chmod +x "$CASE/stub/$client"
done

# truth EXPECT COMMAND: run COMMAND under bash (dash has no `<<<` or `< <()`)
# with the stubs first on PATH, the canary in AG_CANARY_SECRET, n naming it
# whole and m naming it without its first letter. "ids": the output holds the
# stub's id and not the canary. "leak": the output holds the canary.
truth() {
  n=$((n + 1))
  rm -f "$W/ids.txt" "$W/helper.sh"
  PATH="$CASE/stub:$PATH" AG_CANARY_SECRET=$canary n=AG_CANARY_SECRET m=G_CANARY_SECRET \
    bash -c 'cd "$0" && eval "$1"' "$W" "$2" >"$CASE/out" 2>&1 </dev/null
  case $1 in
    ids)
      if grep -qF -- "$sid" "$CASE/out" && ! grep -qF -- "$canary" "$CASE/out"; then
        ok "eval capture $n: bash assigns the id and prints no canary"
      else
        bad "eval capture $n: bash did not assign the id without the canary: $2"
        sed 's/^/  out: /' "$CASE/out"
      fi ;;
    leak)
      if grep -qF -- "$canary" "$CASE/out"; then
        ok "eval capture $n: bash prints the canary, so the block guards a real read"
      else
        bad "eval capture $n: bash did not print the canary: $2"
        sed 's/^/  out: /' "$CASE/out"
      fi ;;
  esac
}

allowed() { check 0 "$1"; truth ids "$1"; }
indirect() { check 2 "$1"; truth leak "$1"; }

# The reported style and close variants: query results, ids and counts put
# into variables through eval.
allowed 'eval "sid=\$(sqlite3 stack.db '\''select id from sessions limit 1'\'')"; echo "$sid"'
allowed 'eval "export SESSION_ID=\$(psql -At -c '\''select id from sessions limit 1'\'')"; echo "$SESSION_ID"'
allowed 'eval "sid=\$(docker exec stack-db psql -U app -At -c '\''select id from sessions limit 1'\'')"; echo "$sid"'
allowed 'eval "count=\$(mysql -N -e '\''select count(*) from requests'\'')" && echo "$count"'
allowed 'for col in session_id id; do eval "v_$col=\$(sqlite3 stack.db \"select $col from requests limit 1\")"; done; echo "$v_id"'
allowed 'while IFS== read -r k v; do eval "$k=\$v"; done <<< "$(sqlite3 stack.db "select '\''SESSION_ID='\'' || session_id from requests")"; echo "$SESSION_ID"'
allowed 'while IFS== read -r k v; do eval "$k=\${v}"; done < <(sqlite3 stack.db "select '\''SESSION_ID='\'' || session_id from requests"); echo "$SESSION_ID $REQUEST_ID"'
allowed 'sqlite3 stack.db "select '\''SESSION_ID='\'' || session_id from requests" | { while IFS== read -r k v; do eval "$k=\$v"; done; echo "$SESSION_ID"; }'
# The reported shape: an eval in a loop body assigns query results, and the
# ids are written to a helper file.
allowed 'for t in sessions requests; do eval "id_$t=\$(sqlite3 stack.db \"select id from $t limit 1\")"; done; printf '\''SID=%s\nRID=%s\n'\'' "$id_sessions" "$id_requests" > ids.txt; cat ids.txt'
allowed 'while IFS== read -r k v; do eval "$k=\$v"; printf '\''%s=%s\n'\'' "$k" "$v" >> ids.txt; done < <(sqlite3 stack.db "select '\''SESSION_ID='\'' || session_id from requests"); cat ids.txt'
allowed 'for t in sessions; do eval "sid=\$(sqlite3 stack.db \"select id from $t limit 1\")"; echo "SID=$sid" > helper.sh; done; cat helper.sh'
# Shapes main already allowed stay allowed.
allowed 'eval "$(sqlite3 stack.db "select '\''SESSION_ID='\'' || session_id from requests")"; echo "$SESSION_ID"'
allowed 'eval "sid=$(sqlite3 stack.db '\''select id from sessions limit 1'\'')"; echo "$sid"'

# A variable name built at run time inside the eval text reads a value the
# command never names: blocked, and bash really prints the canary.
indirect 'eval "echo \$$n"'
indirect 'eval echo \$$n'
indirect 'eval "x=\${$n}"; echo "$x"'
indirect 'eval echo \$\{$n\}'
indirect 'eval "x=\$A$m"; echo "$x"'
indirect 'eval "x=\$A"$m; echo "$x"'
indirect 'eval "x=\$A""$m"; echo "$x"'
indirect 'eval "x=\${!n}"; echo "$x"'
indirect 'k=x; eval "$k=\$$n"; echo "$x"'
indirect 'eval "printf %s \"\$$n\""'
# A deferred expansion that is not an assignment value runs a command the
# text never names.
indirect 'c=print; eval "\${c}env"'
indirect 'c=print; eval "x=\$(\${c}env)"; echo "$x"'
check 2 'eval "\$cmd"'
check 2 'eval "\$c AWS_SECRET_ACCESS_KEY"'
check 2 'eval \$c'
# Shell-specific or erroring forms stay blocked without a ground-truth run.
check 2 'eval "x=\${(P)n}"'
check 2 'eval "x=\$(($n))"'
check 2 'eval "x=\$a[$n]"'

# Secret sources stay blocked directly, through a command substitution, and
# through eval of a deferred substitution or of their output.
while IFS= read -r src; do
  [ -n "$src" ] || continue
  check 2 "x=\$($src)"
  check 2 "eval \"x=\\\$($src)\""
  check 2 "eval \"\$($src)\""
done <<'SOURCES'
cat .env
cat ./.env.local
set -a; . ./.env; set +a
cat ~/.ssh/id_ed25519
cat ~/.aws/credentials
cat ~/.pgpass
cat secrets/server.key
sqlite3 stack.db '.read .env'
op read op://vault/item/password
op item get app --fields password
vault kv get -field=password secret/app
aws secretsmanager get-secret-value --secret-id app --query SecretString --output text
gcloud secrets versions access latest --secret=app
kubectl get secret app -o jsonpath='{.data.password}'
printenv
printenv AWS_SECRET_ACCESS_KEY
env
docker exec stack-db printenv
printf 'protocol=https\nhost=github.com\n\n' | git credential fill
SOURCES
check 2 'while IFS== read -r k v; do eval "$k=\$v"; done < .env'
check 2 'eval "$(printenv | sed '\''s/^/export /'\'')"'

[ "$n" -ge 100 ] && ok "ran $n rows" || bad "ran only $n rows"
printf '# pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

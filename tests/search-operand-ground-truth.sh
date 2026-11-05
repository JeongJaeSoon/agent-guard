#!/bin/sh
# Ground truth for the Bash path match leaving out grep/rg search patterns and
# new openssl output paths: each command is judged by the hook, then run in a
# sandbox whose protected files hold a canary. An allowed command must not
# print the canary; a `read` command must both be blocked and print it when
# run, which proves the harness can see a leak.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-search-operand.XXXXXX")
trap 'rm -rf "$CASE"' 0
W="$CASE/w"
mkdir -p "$W/src" "$W/sub"
canary=agcanary$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
for f in .env .env.local state.env tls.key; do
  printf 'VALUE=%s\n' "$canary" >"$W/$f"
done
printf '%s\n' .env x.pem notes VALUE >"$W/list.txt"
printf 'const p = process.env.PORT\n' >"$W/src/a.ts"
printf 'see https://example.net/docs\n' >"$W/notes.txt"

pass=0 fail=0 n=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

gate() {
  n=$((n + 1))
  jq -nc --arg c "$1" --arg d "$W" --arg s "search-operand-$$-$n" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' \
    | AGENT_GUARD_HOOK_HOST=claude "$BIN" hook-pre-tool >/dev/null 2>"$CASE/err"
}

runs_here() {
  case "$1" in
    rg\ *|*'| rg '*) command -v rg >/dev/null 2>&1 ;;
    *openssl*) command -v openssl >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

while read -r kind cmd; do
  [ -n "$kind" ] || continue
  gate "$cmd"
  status=$?
  case "$kind" in
    allow)
      if [ "$status" -eq 0 ]; then ok "allowed: $cmd"; else bad "allowed (got $status): $cmd"; sed 's/^/  /' "$CASE/err"; fi
      runs_here "$cmd" || { ok "# skip run, tool missing: $cmd"; continue; }
      (cd "$W" && sh -c "$cmd") </dev/null >"$CASE/out" 2>&1
      if grep -Fq "$canary" "$CASE/out"; then bad "allowed command printed protected content: $cmd"; else ok "no protected content: $cmd"; fi
      ;;
    read)
      if [ "$status" -eq 2 ] && grep -Fq 'reason=bash_protected_path_text_match' "$CASE/err"; then
        ok "blocked read: $cmd"
      else
        bad "blocked read (got $status): $cmd"
      fi
      (cd "$W" && sh -c "$cmd") </dev/null >"$CASE/out" 2>&1
      if grep -Fq "$canary" "$CASE/out"; then ok "control reads protected content: $cmd"; else bad "control did not read protected content: $cmd"; fi
      ;;
    held)
      if [ "$status" -eq 2 ]; then ok "still blocked: $cmd"; else bad "still blocked (got $status): $cmd"; fi
      ;;
  esac
done <<'CASES'
allow ls -a . | grep -E '^\.env'
allow grep -n "process.env\|import.meta.main" src/a.ts
allow grep -rn '\.env\*' src
allow grep -E '\.pem$' list.txt
allow grep -oE 'example\.net[a-z]*' notes.txt
allow for c in a b; do echo "== $c"; done; ls -a . | grep -E '^\.env'
allow grep -e '\.env' -e '\.pem' list.txt
allow grep --regexp='\.env' list.txt
allow grep -rn --include='*.ts' -A3 'process\.env' src 2>/dev/null | head
allow LC_ALL=C cat list.txt | grep -c -- '\.env'
allow echo x; grep -E '\.env'
allow rg --no-config -n 'process\.env\.PORT' src
allow rg --no-config -n -g '*.ts' 'process\.env' src
allow cd ./sub && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=t -keyout tls-up.key -out tls-up.crt
allow openssl genrsa -out fresh.key 2048
read cat .env
read grep -E '^VALUE=' .env
read cut -d= -f2 state.env
read grep -e VALUE .env
read grep -E '\.env|VALUE' .env.local
read grep -r --include='*.env' VALUE .
read grep VALUE .env*
read grep -h VALUE list.txt .env
read cat .env | grep -E '\.env|VALUE'
read grep -f list.txt .env
read grep VALUE < .env
held grep -f .env list.txt
held grep --file=.env list.txt
held grep pat list.txt -e .env
held grep .env -e VALUE
held grep -flist.txt .env
held grep --file=list.txt .env
held grep -e "`cat .env >&2`" list.txt
held grep -e "$(cat .env >&2)" list.txt
held grep <.env VALUE
held grep "$(cat .env)" list.txt
held grep `cat .env` list.txt
held grep $p .env
held grep {x,.env} list.txt
held PATH=/tmp/x grep .env list.txt
held PATH=/tmp/x; grep .env list.txt
held export PATH=/tmp/x; grep .env list.txt
held alias grep=cat; grep .env
held command hash -p /bin/cat grep; grep .env
held noglob hash grep=/bin/cat; grep .env
held mkdir -p d && ln -sf /bin/cat d/grep; for PATH in d; do :; done; grep .env
held for PATH in d; do echo; done; grep .env
held echo d > p; read PATH < p; grep .env
held echo d > p; read PATH < p && grep .env
held printf -v PATH %s d; grep .env
held command export PATH=d; grep .env
held for c in a; do hash -p /bin/cat grep; done; grep .env
held hash -p /bin/cat grep; grep .env
held rg --pre /bin/sh x ./swap; grep .env
held rg --pre=/bin/sh x ./swap; grep .env
held rg --hostname-bin ./swap x notes.txt; grep .env
held RIPGREP_CONFIG_PATH=./rgconfig rg x notes.txt; grep .env
held LD_PRELOAD=./x.so cat notes.txt; grep .env
held LC_ALL=/tmp/x cat notes.txt; grep .env
held stat -A path +name /tmp/x; grep .env
held LC_ALL=C LD_PRELOAD=./x.so cat notes.txt; grep .env
held test -v 'path[$(cp ./reader ./grep)1]'; grep .env
held [ -v 'path[$(cp ./reader ./grep)1]' ]; grep .env
held functions[grep]='cat $1'; grep .env
held grep() { cat "$@"; }; grep .env
held cat list.txt >&grep .env
held cat list.txt & grep .env
held sudo grep VALUE .env
held xargs grep .env < list.txt
held rg -n 'process\.env' src
held rg --pre cat VALUE .env
held rg -g '*.env' VALUE .
held cd sub && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=t -keyout fresh2.key -out t.crt
held openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=t -keyout tls.key -out t.crt
held openssl req -x509 -key tls.key -out t.crt -subj /CN=t
held openssl x509 -in t.crt -out fresh3.key
held chmod 644 fresh.key
held sed -n 's/x/y/p' notes.txt .env
held git restore . && grep .env
held echo x >p; grep .env
held cat list.txt >p | grep .env
held touch p; grep .env
held sort -o p list.txt; grep .env
held mkdir -p d; grep .env
held find . -name p -delete; grep .env
CASES

# Options from the environment come first and can make the pattern a file.
printf -- '--regexp=VALUE\n' >"$CASE/rgrc"
status=0
(RIPGREP_CONFIG_PATH="$CASE/rgrc"; export RIPGREP_CONFIG_PATH; gate 'rg .env') || status=$?
if [ "$status" -eq 2 ]; then ok "rg pattern kept without --no-config"; else bad "rg pattern kept without --no-config (got $status)"; fi
if command -v rg >/dev/null 2>&1; then
  (cd "$W" && RIPGREP_CONFIG_PATH="$CASE/rgrc" rg .env) </dev/null >"$CASE/out" 2>&1
  if grep -Fq "$canary" "$CASE/out"; then ok "control: a ripgrep config makes the pattern a path"; else bad "control: a ripgrep config makes the pattern a path"; fi
fi
status=0
gate 'grep .env' || status=$?
if [ "$status" -eq 0 ]; then ok "grep pattern alone allowed"; else bad "grep pattern alone allowed (got $status)"; fi
status=0
(GREP_OPTIONS='-e VALUE'; export GREP_OPTIONS; gate 'grep .env') || status=$?
if [ "$status" -eq 2 ]; then ok "grep pattern kept under GREP_OPTIONS"; else bad "grep pattern kept under GREP_OPTIONS (got $status)"; fi

# A segment before the search can rewrite a file that a PATH entry resolves
# the later command name to. PATH is changed only for the run, not the hook.
mkdir -p "$W/pbin"
printf '#!/bin/sh\nexit 0\n' >"$W/pbin/grep"
chmod +x "$W/pbin/grep"
printf '#!/bin/sh\ncat "$1"\n' >"$W/shim"
status=0
gate 'cat shim >pbin/grep; grep .env' || status=$?
if [ "$status" -eq 2 ]; then ok "pattern kept after a segment that writes a file"; else bad "pattern kept after a segment that writes a file (got $status)"; fi
(cd "$W" && PATH="$W/pbin:$PATH" sh -c 'cat shim >pbin/grep; grep .env') </dev/null >"$CASE/out" 2>&1
if grep -Fq "$canary" "$CASE/out"; then ok "control: a rewritten PATH entry makes grep read its pattern"; else bad "control: a rewritten PATH entry makes grep read its pattern"; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

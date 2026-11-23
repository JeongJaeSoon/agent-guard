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
printf '{"a":{"key":1}}\n' >"$W/s.json"
printf 'cat .env\n' >"$W/cmds.txt"
# A repository of its own for the git rows, with a dotenv file in its index.
mkdir -p "$W/g/src"
printf 'const p = process.env.PORT\n' >"$W/g/src/a.ts"
printf 'VALUE=%s\n' "$canary" >"$W/g/.env"
(cd "$W/g" && git init -q . && git add -f .) >/dev/null 2>&1 || { printf 'not ok - could not build the git fixture\n'; exit 1; }

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
allow mkdir -p d; grep .env
allow cp notes.txt n2.txt && grep -E '\.pem$' list.txt
allow grep --regexp='\.env' list.txt
allow grep -rn --include='*.ts' -A3 'process\.env' src 2>/dev/null | head
allow LC_ALL=C cat list.txt | grep -c -- '\.env'
allow echo x; grep -E '\.env'
allow rg --no-config -n 'process\.env\.PORT' src
allow rg --no-config -n -g '*.ts' 'process\.env' src
allow cd ./sub && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=t -keyout tls-up.key -out tls-up.crt
allow openssl genrsa -out fresh.key 2048
allow sed 's/^d2-gate\t[^\t]*\t//' notes.txt
allow cut -c1-40 notes.txt | sed -E 's/^([^\t]*)\t[^\t]*/\1/' | head -3
allow sed -n 's/.env/x/p' list.txt
allow echo x; sed 's/^d2-gate\t[^\t]*\t//' notes.txt
allow ls -a . && sed -n 's/.env/x/p' list.txt
allow echo x; jq -n '{a: 1} | .tls.key'
allow jq -r '.a.key, .b.p8, .c.env' s.json
allow command jq -r '.tls.key' s.json
allow grep -n -E '//|/\*\*|^\s*\* ' src/a.ts | sed -n 1,400p | awk -F: '$1>300'
allow ls -a . | grep -E '^\.env' | awk '{print $1}'
allow grep -E '\.pem$' list.txt | awk -F. -v n=1 '{ print $n }'
allow grep -c -- '\.env' list.txt | awk '$1 > 0'
allow grep -E '\.env' list.txt | awk -F : '{ printf "%s\n", $1 }' | head -3
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
read sed 's/^x\t[^\t]*//' .env
read sed 's/.env/x/' list.txt .env
read echo x; sed 's/^x\t[^\t]*//' .env
read echo x; jq -R . tls.key
read jq -R '. // .tls.key' tls.key
read command jq -R . tls.key
read ls -a . | grep -E '^\.env$' | awk '{ while ((getline l < $0) > 0) print l }'
read ls -a . | grep -E '^\.env$' | awk '{ system("cat " $0) }'
read ls -a . | grep -E '^\.env$' | awk '{ print | "xargs cat" }'
read ls -a . | grep -E '^\.env$' | awk '{ "cat " $0 | getline l; print l }'
read ls -a . | grep -E '^\.env$' | awk '{ getline l < $0; print l }'
held ls -a . | grep -E '^\.env$' | sort -o out.txt
held ls -a . | grep -E '^\.env$' | awk '{ ARGV[ARGC++] = $0 }'
held ls -a . | grep -E '^\.env$' | awk -v a=ARGV '{ SYMTAB[a][1] = $0 }'
held ls -a . | grep -E '^\.env$' | awk '{ SYMTAB["AR" "GV"][1] = $0 }'
held ls -a . | grep -E '^\.env$' | awk -f prog.awk
held ls -a . | grep -E '^\.env$' | awk -fprog.awk
held ls -a . | grep -E '^\.env$' | awk --file=prog.awk
held ls -a . | grep -E '^\.env$' | awk -i lib '{ print }'
held ls -a . | grep -E '^\.env$' | awk '@include "lib"; { print }'
held ls -a . | grep -E '^\.env$' | awk '{ print > $0 }'
held ls -a . | grep -E '^\.env$' | awk '{ print >> "out" }'
held ls -a . | grep -E '^\.env$' | awk -F : 'NR>0 { printf "%s\n", $1 }'
held ls -a . | grep -E '^\.env$' | awk "{ $P }"
held ls -a . | grep -E '^\.env$' | awk $PROG
held ls -a . | grep -E '^\.env$' | gawk '{ print }'
held ls -a . | grep -E '^\.env$' | awk '{ print }' | xargs cat
held ls -a . | grep -E '^\.env$' | awk
held grep -e '\.env' -e VALUE; cat $_
held ls -a . | grep -E '^\.env$' | awk '{print}'; cat $_
held jq -n '.env'; cat "${_}"
held sed -n 's/.env/x/p' list.txt; cat $_.local
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
held sed -f list.txt 's/.env/x/'
held sed 's/.env/x/' -e p
held sed 's/.env/x/w .env' notes.txt
held sed '/.env/r .env' list.txt
held cp notes.txt n2.txt; sed 's/.env/x/' n2.txt
held S=a; sed 's/.env/x/' list.txt
held echo $S; sed 's/.env/x/' list.txt
held gh api x; jq -n '.tls.key'
held git restore . && grep .env
held echo x >p; grep .env
held cat list.txt >p | grep .env
held touch p; grep .env
held sort -o p list.txt; grep .env
held cp shim pbin/grep; grep .env
held cp notes.txt /tmp/n2.txt; grep .env
held find . -name p -delete; grep .env
allow cd g && git grep -n 'process\.env' -- src
allow cd g && git grep -n -E 'state\.env|tls\.key' -- src | head -5
allow cd g && git grep -h -oE 'process\.env\.[A-Z]+' -- src | sort | uniq -c
allow cd g && git grep -n "process.env" -A2 -- src | head; git grep -c '\.env' -- src
allow cd g && git diff -U0 -- src | grep -E 'process\.env|tls\.key'
allow cd g && git diff --stat -- src 2>/dev/null | grep -c '\.env'
allow for f in src/a.ts notes.txt; do grep -n 'process\.env' $f | head -3; done
allow for f in src/a.ts notes.txt; do echo "== $f"; grep -c "\.env" "$f"; done
allow if grep -q '\.env' list.txt; then echo yes; fi
allow A=src; grep -n "process.env\|x" $A/a.ts | grep -o "process.env" | head -30
allow D=src; grep -rn 'process\.env' "$D" | head
allow sed -n 1,3p list.txt | grep -o "\.env" | head; grep -rn "\.pem" -o list.txt | head -20
allow grep -n "\.env$" list.txt
allow grep -rli "process.env\|x" --include=*.ts -l . 2>/dev/null | grep -v node_modules | head
allow ls src sub 2>/dev/null; grep -n "process.env" src/a.ts
allow find . -maxdepth 2 -not -path "*/.env*" -not -name "*.key" -not -name "*.env" | head -20
allow for d in src sub; do echo "== $d"; find "$d" -maxdepth 3 -not -path "*/secrets*" -not -name "*.env" | head -20; stat -f "%z" "$d"; done
allow find src -type f ! -name '*.pem' | wc -l
allow ls src | sort | uniq -c | head; grep -n "process.env" src/a.ts
allow find . -maxdepth 1 -not -name ".env" -print | head
allow rg --no-config -n 'process\.env' src; grep -c '\.env' list.txt
read cd g && git grep -n VALUE -- .env
read cd g && git grep -h -e VALUE .env
held cd g && git grep .env -e VALUE
read git diff --no-index /dev/null .env | grep VALUE
read for f in .env; do grep VALUE $f; done
read for f in -e; do grep .env $f VALUE; done
read for f in -e; do true; done; grep .env $f VALUE
read for i in 1 2; do grep .env $A VALUE; A=-e; done
read for f in a; do grep -o 'cat \.env' cmds.txt; done | sh
read if true; then true; grep -o 'cat \.env' cmds.txt; fi | sh
read A=-e; grep .env $A VALUE
read A="-e VALUE"; grep .env $A
read grep .env -f list.txt
read grep VALUE -r . --include=*.env
read find . -maxdepth 1 -name ".env" | xargs cat
read find . -maxdepth 1 ! ! -name .env | xargs cat
read find . -maxdepth 1 -not -name ".env" | xargs cat
held cd g && git grep -f .env
held cd g && git grep -O .env VALUE
held git -c core.pager=cat grep '\.env'
held cd g && git grep -l '\.env' | xargs cat
held cd g && git grep -n -e .env; cat $_
held git diff --output=p -- src | grep '\.env'
held git -c diff.external=./shim diff -- src | grep '\.env'
held for i in 1 2; do grep -e .env list.txt; hash -p /bin/cat grep; done
held for f in a b; do grep -c '\.env' list.txt; done > p
held A=x/-e; grep .env $A:t VALUE
held IFS=x; grep .env list.txt
held A=$HOME; grep .env $A/list.txt
held grep -n "$HOME.env" list.txt
held find . -not -path "*/.env*" -o -name "*.key"
held find . \( -not -name ".env" \)
held find . -maxdepth 1 -not -name ".env" -delete
held find . -newer ! -name .env
held find . -print -not -name .env
held ls src | uniq - p; grep .env list.txt
held ls src | sort -o p; grep .env list.txt
held rg --no-config VALUE *; grep .env
held cd g && git grep -n 'process' -- *; grep .env
held find $X -maxdepth 1 -not -name .env
held find . -maxdepth 1 -name ".env" -not -name "*.ts"
held find . -maxdepth 1 -not -name .env; cat $_
held A=src; grep -e .env; cat $_
held ls src 2>/dev/null; grep -e .env; cat "$_"
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

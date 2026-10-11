#!/usr/bin/env sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BIN:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
MOCK_GITLEAKS="$ROOT/tests/fixtures/mock-gitleaks"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-mask-allow.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'chmod -R u+rwx "$CASE" 2>/dev/null; rm -rf "$CASE"' 0
export AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export HOME="$CASE/home"
unset AI_AGENT AGENT_GUARD_DENY_READ_MODE AGENT_GUARD_INFRA_FAILURE_MODE AGENT_GUARD_MASK_DENY_VALUES \
  XDG_CONFIG_HOME
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
hex() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
show() {
  sed 's/^/  stdout: /' "$CASE/out"
  sed 's/^/  stderr: /' "$CASE/err"
}

# Counts the scans of the masked view: at most two per hook.
mkdir -p "$CASE/bin"
printf '#!/bin/sh\n[ "${1:-}" != stdin ] || echo scan >>"%s"\nexec "%s" "$@"\n' \
  "$CASE/scans" "$MOCK_GITLEAKS" >"$CASE/bin/gitleaks"
chmod 755 "$CASE/bin/gitleaks"
export AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks"

API=$(hex); TOKEN=$(hex); ORG=ORGTOK-$(hex)
HIDDEN="$API $TOKEN $ORG"

W="$CASE/work"
mkdir -p "$W"
DOT=".en""v"
printf 'LOG_LEVEL=debug\nAPI_KEY=%s\n' "$API" >"$W/$DOT"
printf 'server:\n  port: 8080\n  token: %s\n' "$TOKEN" >"$W/secrets.yaml"
printf '{"db":{"port":5432,"dsn":"%s"},"hosts":["a","b"]}\n' "$API" >"$W/secrets.json"
printf '[server]\nport=80\nkey=%s\n' "$TOKEN" >"$W/.npmrc"

ALLOW_DIR="$HOME/.config/agent-guard"
ALLOW="$ALLOW_DIR/mask-allow-keys.txt"
mkdir -p "$ALLOW_DIR"
chmod 700 "$HOME" "$HOME/.config" "$ALLOW_DIR"
allow() { printf '%s\n' "$@" >"$ALLOW"; chmod 600 "$ALLOW"; }

# A git work tree with the protected file in a subdirectory, so the work tree
# root and the working directory differ.
R="$CASE/repo"
mkdir -p "$R/sub"
git init -q "$R"
cp "$W/$DOT" "$R/sub/$DOT"

HEAD="agent-guard: blocked sensitive file access:"
HEADER="agent-guard: masked view follows (values replaced with [MASKED]; the file itself was not read by the tool)"
SCANNED="the view showing the mask-allow-keys.txt values contains secret-like text or could not be scanned"

# hook HOST JSON [VAR=VALUE...], run from RUN_DIR.
hook() {
  hook_host=$1 hook_json=$2
  shift 2
  : >"$CASE/scans"
  (
    cd "${RUN_DIR:-$CASE}" || exit 99
    printf '%s' "$hook_json" | env AGENT_GUARD_HOOK_HOST="$hook_host" \
      AGENT_GUARD_DENY_READ_MODE="${MODE-mask}" "$@" "$GUARD" hook-pre-tool
  ) >"$CASE/out" 2>"$CASE/err"
  status=$?
  scans=$(wc -l <"$CASE/scans" | tr -d ' ')
}
# The working directory is WORK unless NO_CWD is set.
read_json() {
  if [ -n "${NO_CWD:-}" ]; then
    jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p},session_id:"mask-allow"}'
  else
    jq -nc --arg p "$1" --arg d "${WORK:-$W}" \
      '{tool_name:"Read",tool_input:{file_path:$p},cwd:$d,session_id:"mask-allow"}'
  fi
}
bash_json() {
  if [ -n "${NO_CWD:-}" ]; then
    jq -nc --arg c "cat $1" '{tool_name:"Bash",tool_input:{command:$c},session_id:"mask-allow"}'
  else
    jq -nc --arg c "cat $1" --arg d "${WORK:-$W}" \
      '{tool_name:"Bash",tool_input:{command:$c,workdir:$d},session_id:"mask-allow"}'
  fi
}

# None of $HIDDEN may reach stdout or stderr, and no rule text in $RULES a
# message line. A rule can equal a key, which the view itself shows.
RULES=
clean() {
  for v in $HIDDEN; do
    grep -Fq -- "$v" "$CASE/out" "$CASE/err" && return 1
  done
  grep '^agent-guard:' "$CASE/err" >"$CASE/messages"
  printf '%s\n' "$RULES" >"$CASE/rule-texts"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    grep -Fq -- "$r" "$CASE/messages" && return 1
  done <"$CASE/rule-texts"
  return 0
}

# expect NAME EXPECTED_STDERR FILE [VAR=VALUE...]: Read and cat of FILE on
# both hosts block with exactly EXPECTED_STDERR, nothing hidden, and at most
# SCANS (default 1) scans of the view.
expect() {
  ex_name=$1 ex_err=$2 ex_file=$3
  shift 3
  for host in claude codex; do
    for form in read cat; do
      case $form in
        read) hook "$host" "$(read_json "$ex_file")" "$@" ;;
        cat) hook "$host" "$(bash_json "$ex_file")" "$@" ;;
      esac
      if [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ] && [ "$scans" -eq "${SCANS:-1}" ] \
         && printf '%s\n' "$ex_err" | cmp -s - "$CASE/err" && clean; then
        ok "$host $form: $ex_name"
      else
        bad "$host $form: $ex_name (status $status, scans $scans)"
        show
      fi
    done
  done
}
view() { printf '%s %s\n%s\n%s' "$HEAD" "$1" "$HEADER" "$2"; }
warned() { printf '%s %s\nagent-guard: %s; every value stays masked\n%s\n%s' "$HEAD" "$1" "$2" "$HEADER" "$3"; }
ENV_SHOWN='LOG_LEVEL=debug
API_KEY=[MASKED]
'
ENV_MASKED='LOG_LEVEL=[MASKED]
API_KEY=[MASKED]
'

# MUST-PASS: an accepted file shows exactly the values its rules name.
RULES='^LOG_LEVEL$'
{ printf '# values safe to show\n\n'; printf '%s\n' '^LOG_LEVEL$'; } >"$ALLOW"
chmod 600 "$ALLOW"
expect "a dotenv key the allow list names is shown" "$(view "$W/$DOT" "$ENV_SHOWN")" "$W/$DOT"

RULES='^server\.port$'
allow "$RULES"
expect "a yaml key path the allow list names is shown" "$(view "$W/secrets.yaml" "server:
  port: 8080
  token: [MASKED]
")" "$W/secrets.yaml"
expect "an ini section.key the allow list names is shown" "$(view "$W/.npmrc" "[server]
port=80
key=[MASKED]
")" "$W/.npmrc"

RULES='^db\.port$
^hosts\.1$'
allow '^db\.port$' '^hosts\.1$'
expect "json key paths and array indexes the allow list names are shown" "$(view "$W/secrets.json" '{
  "db": {
    "port": 5432,
    "dsn": "[MASKED]"
  },
  "hosts": [
    "[MASKED]",
    "b"
  ]
}
')" "$W/secrets.json"

RULES='^LOG_LEVEL$'
allow "$RULES"
NO_CWD=1; RUN_DIR=$W
expect "with no workdir the current directory is used" \
  "$(view "$W/$DOT" "$ENV_SHOWN")" "$W/$DOT"
unset NO_CWD RUN_DIR

# A symlink to a private file outside any work tree is followed.
mkdir -p "$CASE/private"
chmod 700 "$CASE/private"
mv "$ALLOW" "$CASE/private/allow.txt"
ln -s "$CASE/private/allow.txt" "$ALLOW"
expect "an allow file symlinked to a private file elsewhere is used" \
  "$(view "$W/$DOT" "$ENV_SHOWN")" "$W/$DOT"
rm -f "$ALLOW"

# MUST-FAIL: the allow list comes only from HOME, never from a variable.
mkdir -p "$CASE/xdg/agent-guard"
printf '%s\n' '^LOG_LEVEL$' >"$CASE/xdg/agent-guard/mask-allow-keys.txt"
expect "a variable-only allow list is ignored" "$(view "$W/$DOT" "$ENV_MASKED")" "$W/$DOT" \
  XDG_CONFIG_HOME="$CASE/xdg" AGENT_GUARD_MASK_ALLOW_KEYS="$CASE/xdg/agent-guard/mask-allow-keys.txt"

# MUST-FAIL: an allow file a repository could have written is not used.
INSIDE='mask-allow-keys.txt is inside the repository or the working directory'
mkdir -p "$R/home/.config/agent-guard"
chmod 700 "$R/home" "$R/home/.config" "$R/home/.config/agent-guard"
printf '%s\n' '^LOG_LEVEL$' >"$R/home/.config/agent-guard/mask-allow-keys.txt"
chmod 600 "$R/home/.config/agent-guard/mask-allow-keys.txt"
WORK="$R/sub"
expect "HOME inside the work tree above the workdir" \
  "$(warned "$R/sub/$DOT" "$INSIDE" "$ENV_MASKED")" "$R/sub/$DOT" HOME="$R/home"
unset WORK
NO_CWD=1; RUN_DIR="$R/sub"
expect "HOME inside the work tree of the current directory" \
  "$(warned "$R/sub/$DOT" "$INSIDE" "$ENV_MASKED")" "$R/sub/$DOT" HOME="$R/home"
unset NO_CWD RUN_DIR
# The agent picks the directory a tool runs in, so a HOME moved into a work
# tree is refused from anywhere else too, for a file inside or outside it.
mkdir -p "$CASE/elsewhere"
WORK="$CASE/elsewhere"
expect "HOME inside a work tree, run from outside it" \
  "$(warned "$R/sub/$DOT" "$INSIDE" "$ENV_MASKED")" "$R/sub/$DOT" HOME="$R/home"
expect "HOME inside a work tree, reading a file outside it" \
  "$(warned "$W/$DOT" "$INSIDE" "$ENV_MASKED")" "$W/$DOT" HOME="$R/home"
unset WORK
mkdir -p "$W/home/.config/agent-guard"
chmod 700 "$W/home" "$W/home/.config" "$W/home/.config/agent-guard"
cp "$R/home/.config/agent-guard/mask-allow-keys.txt" "$W/home/.config/agent-guard/"
chmod 600 "$W/home/.config/agent-guard/mask-allow-keys.txt"
expect "HOME inside a workdir that is not a work tree" \
  "$(warned "$W/$DOT" "$INSIDE" "$ENV_MASKED")" "$W/$DOT" HOME="$W/home"

printf '%s\n' '^LOG_LEVEL$' >"$R/allow.txt"
chmod 600 "$R/allow.txt"
ln -s "$R/allow.txt" "$ALLOW"
WORK="$R/sub"
expect "a symlink to a file in the work tree" \
  "$(warned "$R/sub/$DOT" "$INSIDE" "$ENV_MASKED")" "$R/sub/$DOT"
unset WORK
expect "a symlink to a file in another work tree" \
  "$(warned "$W/$DOT" "$INSIDE" "$ENV_MASKED")" "$W/$DOT"
rm -f "$ALLOW"
mv "$ALLOW_DIR" "$CASE/allow-dir-away"
mkdir -p "$R/cfg"
chmod 700 "$R/cfg"
cp "$R/allow.txt" "$R/cfg/mask-allow-keys.txt"
ln -s "$R/cfg" "$ALLOW_DIR"
WORK="$R/sub"
expect "a symlinked config directory in the work tree" \
  "$(warned "$R/sub/$DOT" "$INSIDE" "$ENV_MASKED")" "$R/sub/$DOT"
unset WORK
rm -f "$ALLOW_DIR"
mv "$CASE/allow-dir-away" "$ALLOW_DIR"

# git cannot answer for a .git it does not understand, so nothing is guessed.
mkdir -p "$CASE/broken"
: >"$CASE/broken/.git"
cp "$W/$DOT" "$CASE/broken/$DOT"
allow '^LOG_LEVEL$'
WORK="$CASE/broken"
expect "a workdir git cannot place in a work tree" \
  "$(warned "$CASE/broken/$DOT" 'mask-allow-keys.txt could not be checked' "$ENV_MASKED")" \
  "$CASE/broken/$DOT"
unset WORK

# MUST-FAIL: ownership and write permission.
WRITABLE='mask-allow-keys.txt or its directory is writable by group or others'
for mode in 620 602; do
  chmod "$mode" "$ALLOW"
  expect "an allow file with mode $mode" "$(warned "$W/$DOT" "$WRITABLE" "$ENV_MASKED")" "$W/$DOT"
done
chmod 600 "$ALLOW"
chmod 770 "$ALLOW_DIR"
expect "an allow file directory with mode 770" "$(warned "$W/$DOT" "$WRITABLE" "$ENV_MASKED")" "$W/$DOT"
chmod 700 "$ALLOW_DIR"
chmod 770 "$HOME/.config"
expect "a directory above the allow file with mode 770" "$(warned "$W/$DOT" \
  'a directory above mask-allow-keys.txt is writable by group or others' "$ENV_MASKED")" "$W/$DOT"
chmod 1777 "$HOME/.config"
expect "a sticky directory above the allow file that others can write" \
  "$(view "$W/$DOT" "$ENV_SHOWN")" "$W/$DOT"
chmod 700 "$HOME/.config"

# An access control list can let others write whatever the mode says.
ACL='an access control list on mask-allow-keys.txt or a directory above it lets others write'
if [ "$(uname -s)" = Darwin ]; then
  for node in "$ALLOW" "$HOME/.config"; do
    chmod +a "everyone allow write" "$node"
    expect "an access control list on ${node#"$HOME"/}" "$(warned "$W/$DOT" "$ACL" "$ENV_MASKED")" "$W/$DOT"
    chmod -N "$node"
  done
  chmod +a "everyone deny delete" "$HOME/.config"
  expect "a deny-only access control list, as on a macOS home" "$(view "$W/$DOT" "$ENV_SHOWN")" "$W/$DOT"
  chmod -N "$HOME/.config"
elif command -v setfacl >/dev/null 2>&1 && setfacl -m "u:$(id -u):rw" "$ALLOW" 2>/dev/null; then
  expect "an access control list on the allow file" "$(warned "$W/$DOT" "$ACL" "$ENV_MASKED")" "$W/$DOT"
  setfacl -b "$ALLOW"
  chmod 600 "$ALLOW"
else
  ok "# skip access control lists: no chmod +a or working setfacl"
fi

# Another owner cannot be made without root, so stat answers for one.
mkdir -p "$CASE/stat-other" "$CASE/stat-fail"
printf '#!/bin/sh\necho 4242:600\n' >"$CASE/stat-other/stat"
printf '#!/bin/sh\nexit 1\n' >"$CASE/stat-fail/stat"
chmod 755 "$CASE/stat-other/stat" "$CASE/stat-fail/stat"
expect "an allow file owned by another user" "$(warned "$W/$DOT" \
  'mask-allow-keys.txt or its directory is not owned by the current user' "$ENV_MASKED")" "$W/$DOT" \
  PATH="$CASE/stat-other:$PATH"
expect "an allow file whose owner cannot be read" "$(warned "$W/$DOT" \
  'mask-allow-keys.txt could not be checked' "$ENV_MASKED")" "$W/$DOT" PATH="$CASE/stat-fail:$PATH"

chmod 000 "$ALLOW"
if [ -r "$ALLOW" ]; then
  ok "# skip unreadable allow file: running as a user who can read mode 000"
else
  expect "an unreadable allow file" "$(warned "$W/$DOT" 'mask-allow-keys.txt could not be read' \
    "$ENV_MASKED")" "$W/$DOT"
fi
rm -f "$ALLOW"
ln -s "$CASE/missing" "$ALLOW"
expect "a dangling allow file symlink" "$(warned "$W/$DOT" 'mask-allow-keys.txt could not be checked' \
  "$ENV_MASKED")" "$W/$DOT"
rm -f "$ALLOW"

# MUST-FAIL: a refused rule drops the whole list with only its line and reason.
LONG=$(awk 'BEGIN { while (n++ < 300) printf "L" }')
while IFS='~' read -r rule why; do
  RULES=$rule
  allow '^API_KEY_UNUSED$' "$rule"
  expect "rule refused: $rule" "$(warned "$W/$DOT" "mask-allow-keys.txt line 2: the rule $why" \
    "$ENV_MASKED")" "$W/$DOT"
done <<EOF
.*~matches empty text
^.*\$~matches empty text
^~matches empty text
^.+\$~matches a probe key, so it would match almost any key
^[A-Z0-9_]+\$~matches a probe key, so it would match almost any key
^AGENT|X\$~matches a probe key, so it would match almost any key
LOG_LEVEL~does not start with ^ and end with \$
^LOG_LEVEL~does not start with ^ and end with \$
LOG_LEVEL\$~does not start with ^ and end with \$
^LOG_LEVEL\\\$~does not start with ^ and end with \$
^LOG_(\$~is not a valid extended regular expression
^(LOG)\\1\$~uses a back-reference
^(L+)+\$~repeats an expression that already repeats
^(L|LO)*G\$~repeats a group that contains |
^L{300}\$~repeats more than 255 times
^${LONG}\$~is longer than 256 bytes
EOF
RULES=
awk 'BEGIN { for (i = 0; i < 65; i++) print "^K" i "$" }' >"$ALLOW"
expect "more than 64 rules" "$(warned "$W/$DOT" \
  'mask-allow-keys.txt line 65: the rule is past the limit of 64 rules' "$ENV_MASKED")" "$W/$DOT"
awk 'BEGIN { for (i = 0; i < 63; i++) print "^K" i "$"; print "^LOG_LEVEL$" }' >"$ALLOW"
expect "64 rules are accepted" "$(view "$W/$DOT" "$ENV_SHOWN")" "$W/$DOT"

# MUST-FAIL: a deny-value rule beats the allow list, from either rule file.
printf 'LOG_LEVEL=%s\nPORT=8080\n' "$ORG" >"$W/deny.env"
allow '^LOG_LEVEL$' '^PORT$'
printf '%s\n' 'ORGTOK-[0-9a-f]{24}' >"$ALLOW_DIR/mask-deny-values.txt"
RULES='ORGTOK-[0-9a-f]{24}'
expect "a value a deny-value rule matches stays masked" "$(view "$W/deny.env" 'LOG_LEVEL=[MASKED]
PORT=8080
')" "$W/deny.env"
rm -f "$ALLOW_DIR/mask-deny-values.txt"
printf '%s\n' 'ORGTOK-[0-9a-f]{24}' >"$CASE/env-deny"
expect "a deny-value rule from the variable also wins" "$(view "$W/deny.env" 'LOG_LEVEL=[MASKED]
PORT=8080
')" "$W/deny.env" AGENT_GUARD_MASK_DENY_VALUES="$CASE/env-deny"
RULES=

# MUST-FAIL: a shown value the scanner flags is masked again, with one more
# scan; a view still flagged after that is refused.
MARK=AGENT_GUARD_TEST_SECRET
printf 'LOG_LEVEL=%s-%s\nPORT=8080\n' "$MARK" "$API" >"$W/flagged.env"
SCANS=2
expect "a shown value the scanner flags is masked again" "$(warned "$W/flagged.env" "$SCANNED" \
  'LOG_LEVEL=[MASKED]
PORT=[MASKED]
')" "$W/flagged.env"
unset SCANS
printf '# %s\nPORT=8080\n' "$MARK" >"$W/comment.env"
SCANS=2
expect "a view flagged with and without shown values is refused" "$(printf '%s %s\nagent-guard: %s; every value stays masked\nagent-guard: no masked view: the masked view still contains secret-like text\n' \
  "$HEAD" "$W/comment.env" "$SCANNED")" "$W/comment.env"
unset SCANS

# MUST-FAIL: a key path that reads more than one way is never shown.
printf 'A.B=dotted-%s\nAB=plain\n' "$API" >"$W/dots.env"
allow '^A\.B$' '^AB$'
expect "a dotenv key holding a dot is not shown" "$(view "$W/dots.env" 'A.B=[MASKED]
AB=plain
')" "$W/dots.env"
printf 'a:\n  b: nested\n"a.b": flat-%s\nm:\n  "0": zero-%s\ns:\n  - first\n' "$API" "$TOKEN" \
  >"$W/secrets.yml"
allow '^a\.b$' '^m\.0$' '^s\.0$'
expect "yaml keys holding a dot or only digits are not shown" "$(view "$W/secrets.yml" 'a:
  b: nested
"a.b": [MASKED]
m:
  "0": [MASKED]
s:
  - first
')" "$W/secrets.yml"
printf '{"a":{"b":"nested"},"a.b":"flat-%s","m":{"0":"zero-%s"},"s":["first"],"":{"x":"e-%s"}}\n' \
  "$API" "$TOKEN" "$API" >"$W/credentials.json"
allow '^a\.b$' '^m\.0$' '^s\.0$' '^\.x$'
expect "json keys holding a dot, only digits or nothing are not shown" "$(view "$W/credentials.json" '{
  "a": {
    "b": "nested"
  },
  "a.b": "[MASKED]",
  "m": {
    "0": "[MASKED]"
  },
  "s": [
    "first"
  ],
  "": {
    "x": "[MASKED]"
  }
}
')" "$W/credentials.json"

# Block mode never reads the allow list.
allow '^LOG_LEVEL$'
for mode in "" block; do
  MODE=$mode
  hook claude "$(read_json "$W/$DOT")"
  if [ "$status" -eq 2 ] && [ "$(cat "$CASE/err")" = "$HEAD $W/$DOT" ]; then
    ok "mode '${mode:-unset}' blocks as before with an allow list"
  else
    bad "mode '${mode:-unset}' blocks as before with an allow list (status $status)"
    show
  fi
done
unset MODE

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

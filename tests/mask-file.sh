#!/usr/bin/env sh
# mask-file engine: format by resolved file name, byte-exact masked views and
# key paths per format (must-pass), and empty stdout with a non-zero status for
# every unsupported name, construct, size and file type (must-fail). Fixture
# values are generated per run so no literal value is committed, and every one
# is searched for in the output.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-mask.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
export AGENT_GUARD_LOG_MODE=off
# Every invocation's temp files must land here and be gone afterwards.
mkdir "$CASE/tmp"
export TMPDIR="$CASE/tmp"
F="$CASE/files"
mkdir "$F"
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
rand() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
VALUES=

# gen NAME...: a fresh random value in each NAME, remembered in VALUES.
gen() {
  for gen_name in "$@"; do
    gen_v=$(rand)
    eval "$gen_name=\$gen_v"
    VALUES="$VALUES $gen_v"
  done
}

mask() { "$GUARD" mask-file "$@" >"$CASE/out" 2>"$CASE/err"; }

show() {
  sed 's/^/  stdout: /' "$CASE/out"
  sed 's/^/  stderr: /' "$CASE/err"
}

expect_output() {
  label=$1
  expected=$2
  shift 2
  if mask "$@" && printf '%s' "$expected" | cmp -s - "$CASE/out"; then
    ok "$label"
  else
    bad "$label"
    show
  fi
}

expect_fail() {
  label=$1
  shift
  mask "$@"
  status=$?
  # One fixed-vocabulary line: no path, no content.
  if [ "$status" -ne 0 ] && [ ! -s "$CASE/out" ] \
     && [ "$(wc -l <"$CASE/err" | tr -d ' ')" = 1 ] \
     && grep -Eq '^agent-guard: (mask-file: [A-Za-z0-9 ]+|required command not found: [a-z]+)$' "$CASE/err"; then
    ok "$label"
  else
    bad "$label (status $status)"
    show
  fi
}

# Every generated value is absent from both views and from stderr.
expect_no_values() {
  label=$1
  file=$2
  "$GUARD" mask-file "$file" >"$CASE/leak" 2>&1
  "$GUARD" mask-file --key-paths "$file" >>"$CASE/leak" 2>&1
  leaked=0
  for v in $VALUES; do
    if grep -Fq "$v" "$file" && grep -Fq "$v" "$CASE/leak"; then
      leaked=1
    fi
  done
  if [ "$leaked" -eq 0 ] && [ -s "$CASE/leak" ]; then
    ok "$label"
  else
    bad "$label"
  fi
}

# --- format by file name -------------------------------------------------
# Each body parses as exactly one format, so the output names the format that
# was chosen.
json_body='{"k":"v"}'
json_view='{
  "k": "[MASKED]"
}
'
yaml_body='k: v
'
yaml_view='k: [MASKED]
'
ini_body='[s]
k=v
'
ini_view='[s]
k=[MASKED]
'
# Indented, so the ini parser rejects it.
dotenv_body='  K=v
'
dotenv_view='  K=[MASKED]
'

mkdir "$F/names" "$F/names/.aws" "$F/names/plain"
for spec in \
  json:x.json json:.env.json \
  yaml:x.yaml yaml:x.yml yaml:.env.yaml \
  ini:x.ini ini:x.cfg ini:x.cnf ini:x.conf ini:.npmrc ini:.pypirc \
  ini:.aws/credentials ini:.aws/config \
  dotenv:.env dotenv:.env.local dotenv:x.env dotenv:.envrc dotenv:x.envrc \
  dotenv:.flaskenv dotenv:.flaskenv.dev dotenv:.dev.vars dotenv:.dev.vars.prod; do
  format=${spec%%:*}
  name=${spec#*:}
  eval "body=\$${format}_body view=\$${format}_view"
  printf '%s' "$body" >"$F/names/$name"
  expect_output "name $name is read as $format" "$view" "$F/names/$name"
done

for name in x.pem .netrc x.toml x.tfvars x.txt x.key id_rsa .envx config credentials; do
  printf '%s' "$dotenv_body" >"$F/names/plain/$name"
  expect_fail "name $name is an unsupported format" "$F/names/plain/$name"
done

# The resolved name decides: a link named like dotenv to a .txt is refused, a
# .txt link to a dotenv file is read as dotenv.
printf '%s' "$dotenv_body" >"$F/names/notes.txt"
ln -s notes.txt "$F/names/linked.env"
expect_fail "symlink is judged by its target name" "$F/names/linked.env"
ln -s .env.local "$F/names/link.txt"
expect_output "symlink to a dotenv file is read as dotenv" "$dotenv_view" "$F/names/link.txt"

# --- dotenv --------------------------------------------------------------
VALUES=
gen d1 d2 d3 d4 d5 d6 d7
{
  printf '# comment line\n\n'
  printf 'export API_KEY=%s\n' "$d1"
  printf 'SPACED = %s\n' "$d2"
  printf 'DQ="%s with \\" quote" # trailing note\n' "$d3"
  printf "SQ='%s'\n" "$d4"
  printf 'EMPTY=\n'
  printf '  INDENTED=%s\n' "$d5"
  printf 'dotted.key=%s # inline %s\n' "$d6" "$d7"
} >"$F/app.env"
expect_output "dotenv view keeps keys, comments and blank lines" '# comment line

export API_KEY=[MASKED]
SPACED = [MASKED]
DQ=[MASKED]
SQ=[MASKED]
EMPTY=
  INDENTED=[MASKED]
dotted.key=[MASKED]
' "$F/app.env"
expect_output "dotenv key paths" 'API_KEY
SPACED
DQ
SQ
INDENTED
dotted.key
' --key-paths "$F/app.env"
expect_no_values "dotenv output carries no original value" "$F/app.env"

mkdir "$F/dotenv-bad"
dotenv_fail() {
  printf 'OK=%s\n%s\n' "$(rand)" "$2" >"$F/dotenv-bad/$1.env"
  expect_fail "dotenv rejects $1" "$F/dotenv-bad/$1.env"
}
dotenv_fail unclosed-double "A=\"$(rand)"
dotenv_fail unclosed-single "A='$(rand)"
dotenv_fail multi-line-value "A=\"$(rand)
continued\""
dotenv_fail text-after-quote "A=\"$(rand)\"tail"
dotenv_fail bad-key-name "A-B=$(rand)"
dotenv_fail no-equals "JUST_A_WORD"

# --- ini -----------------------------------------------------------------
VALUES=
gen i1 i2 i3 i4
{
  printf '; comment\n# another\ntop = %s\n\n' "$i1"
  printf '[profile dev]\naws_access_key_id = %s\n' "$i2"
  printf 'region=%s ; inline\nempty =\n' "$i3"
  printf '//registry.example/:_authToken=%s\n' "$i4"
} >"$F/app.ini"
expect_output "ini view keeps sections, keys and comments" '; comment
# another
top = [MASKED]

[profile dev]
aws_access_key_id = [MASKED]
region=[MASKED]
empty =
//registry.example/:_authToken=[MASKED]
' "$F/app.ini"
expect_output "ini key paths are section.key" 'top
profile dev.aws_access_key_id
profile dev.region
profile dev.//registry.example/:_authToken
' --key-paths "$F/app.ini"
expect_no_values "ini output carries no original value" "$F/app.ini"

mkdir "$F/npm"
gen n1 n2
printf '//registry.example/:_authToken=%s\nregistry=https://registry.example/%s\n' "$n1" "$n2" >"$F/npm/.npmrc"
expect_output ".npmrc auth token line is masked" '//registry.example/:_authToken=[MASKED]
registry=[MASKED]
' "$F/npm/.npmrc"
expect_output ".npmrc key paths" '//registry.example/:_authToken
registry
' --key-paths "$F/npm/.npmrc"
expect_no_values ".npmrc output carries no original value" "$F/npm/.npmrc"

mkdir "$F/ini-bad"
printf '[s]\nk = %s\nno equals here\n' "$(rand)" >"$F/ini-bad/no-equals.ini"
expect_fail "ini rejects a line without =" "$F/ini-bad/no-equals.ini"
printf '[s]\nk = %s\n  continued\n' "$(rand)" >"$F/ini-bad/continuation.ini"
expect_fail "ini rejects an indented continuation line" "$F/ini-bad/continuation.ini"
printf '[s\nk = %s\n' "$(rand)" >"$F/ini-bad/header.ini"
expect_fail "ini rejects an unclosed section header" "$F/ini-bad/header.ini"

# --- json ----------------------------------------------------------------
VALUES=
gen j1 j2 j3
j4=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
VALUES="$VALUES $j4"
printf '{"db":{"host":"%s","port":%s,"ok":false,"none":null},"servers":[{"host":"%s"},"%s"],"empty":{},"list":[]}' \
  "$j1" "$j4" "$j2" "$j3" >"$F/app.json"
expect_output "json view uses jq default indentation" '{
  "db": {
    "host": "[MASKED]",
    "port": "[MASKED]",
    "ok": "[MASKED]",
    "none": "[MASKED]"
  },
  "servers": [
    {
      "host": "[MASKED]"
    },
    "[MASKED]"
  ],
  "empty": {},
  "list": []
}
' "$F/app.json"
if mask "$F/app.json" \
   && [ "$(jq -c '[paths]' "$CASE/out")" = "$(jq -c '[paths]' "$F/app.json")" ] \
   && jq -e '[.. | scalars] | length == 6 and all(. == "[MASKED]")' "$CASE/out" >/dev/null; then
  ok "json view keeps every path and masks every scalar"
else
  bad "json view keeps every path and masks every scalar"
fi
expect_output "json key paths" 'db.host
db.port
db.ok
db.none
servers.0.host
servers.1
' --key-paths "$F/app.json"
expect_no_values "json output carries no original value" "$F/app.json"

mkdir "$F/json-bad"
printf '{"a":"%s"' "$(rand)" >"$F/json-bad/broken.json"
expect_fail "json rejects a broken document" "$F/json-bad/broken.json"
printf '{"a":"%s"}\n{"b":1}\n' "$(rand)" >"$F/json-bad/two.json"
expect_fail "json rejects a second document" "$F/json-bad/two.json"
: >"$F/json-bad/empty.json"
expect_fail "json rejects an empty file" "$F/json-bad/empty.json"
printf '{"a\\nforged":"%s"}' "$(rand)" >"$F/json-bad/newline-key.json"
expect_fail "json key paths reject a key with a newline" --key-paths "$F/json-bad/newline-key.json"

# --- yaml ----------------------------------------------------------------
VALUES=
gen y1 y2 y3 y4 y5 y6 y7 y8 y9 y10 y11
{
  printf -- '---\n# top comment\ndb:\n'
  printf '  host: %s   # inline\n' "$y1"
  printf '  "quoted key": '"'"'%s it'"''"'s'"'"'\n' "$y2"
  printf '  dq: "%s \\" quote"\n' "$y3"
  printf "  'it''s': %s\n\n" "$y11"
  printf 'servers:\n- name: %s\n  tags:\n    - %s\n    - "%s"\n' "$y4" "$y5" "$y6"
  printf -- '- name: %s\nempty:\nlist:\n  - %s\n  - k: %s\n    k2: %s\n' "$y7" "$y8" "$y9" "$y10"
  printf 'url: https://example.test:8443/x\n'
} >"$F/app.yaml"
expect_output "yaml view keeps keys, sequences and comments" '---
# top comment
db:
  host: [MASKED]
  "quoted key": [MASKED]
  dq: [MASKED]
  '"'it''s'"': [MASKED]

servers:
- name: [MASKED]
  tags:
    - [MASKED]
    - [MASKED]
- name: [MASKED]
empty:
list:
  - [MASKED]
  - k: [MASKED]
    k2: [MASKED]
url: [MASKED]
' "$F/app.yaml"
expect_output "yaml key paths" 'db.host
db.quoted key
db.dq
db.it'"'"'s
servers.0.name
servers.0.tags.0
servers.0.tags.1
servers.1.name
list.0
list.1.k
list.1.k2
url
' --key-paths "$F/app.yaml"
expect_no_values "yaml output carries no original value" "$F/app.yaml"

mkdir "$F/yaml-bad"
yaml_fail() {
  printf 'ok: %s\n%s\n' "$(rand)" "$2" >"$F/yaml-bad/$1.yaml"
  expect_fail "yaml rejects $1" "$F/yaml-bad/$1.yaml"
}
tab=$(printf '\t')
yaml_fail tab-indent "a:
${tab}b: $(rand)"
yaml_fail literal-block "a: |
  $(rand)"
yaml_fail folded-block "a: >
  $(rand)"
yaml_fail flow-mapping "a: {b: $(rand)}"
yaml_fail flow-sequence "a: [$(rand)]"
yaml_fail anchor "a: &x $(rand)"
yaml_fail alias "a: *x"
yaml_fail tag "a: !!str $(rand)"
yaml_fail merge-key "a:
  <<: $(rand)"
yaml_fail complex-key "? $(rand)
: b"
yaml_fail second-document "---
a: $(rand)"
yaml_fail document-end "...
a: $(rand)"
yaml_fail directive "%YAML 1.2"
yaml_fail multi-line-plain "a: $(rand)
  continued"
yaml_fail multi-line-quoted "a: \"$(rand)
  continued\""
yaml_fail deeper-after-value "a: $(rand)
  b: c"
yaml_fail top-level-scalar "$(rand)"
yaml_fail escaped-quoted-key "\"a\\u005fb\": $(rand)"

# --- size and file type --------------------------------------------------
mkdir "$F/size"
awk 'BEGIN { for (i = 0; i < 1024; i++) printf "#%062d\n", 0 }' >"$F/size/at-limit.env"
expect_output "a 64 KiB file is accepted" "$(cat "$F/size/at-limit.env")
" "$F/size/at-limit.env"
{ cat "$F/size/at-limit.env"; printf '\n'; } >"$F/size/over-limit.env"
if [ "$(wc -c <"$F/size/over-limit.env" | tr -d ' ')" = 65537 ]; then
  expect_fail "a 64 KiB + 1 byte file is refused" "$F/size/over-limit.env"
else
  bad "over-limit fixture is 65537 bytes"
fi

mkdir "$F/types" "$F/types/dir.env"
expect_fail "a directory is refused" "$F/types/dir.env"
expect_fail "a missing file is refused" "$F/types/missing.env"
if mkfifo "$F/types/pipe.env" 2>/dev/null; then
  expect_fail "a FIFO is refused without being opened" "$F/types/pipe.env"
fi

# --- CLI contract --------------------------------------------------------
for args in '' '--bogus' 'a b'; do
  # Intentional word splitting: each entry is an argument list.
  mask $args
  status=$?
  if [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ] && grep -Fq 'Usage:' "$CASE/err"; then
    ok "usage error for arguments '$args'"
  else
    bad "usage error for arguments '$args' (status $status)"
  fi
done
if "$GUARD" help 2>&1 | grep -Fq 'mask-file [--key-paths]'; then
  ok "help lists mask-file"
else
  bad "help lists mask-file"
fi
if [ -z "$(ls -A "$CASE/tmp")" ]; then
  ok "no temp file is left behind"
else
  bad "no temp file is left behind"
fi

printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

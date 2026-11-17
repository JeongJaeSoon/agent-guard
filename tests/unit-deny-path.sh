#!/bin/sh
# Private regex producer contracts; expectations are literal, not a second encoder.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-deny-path.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" \
  deny_path_char_hex_pattern deny_path_shell_expansion_char_pattern deny_path_pin_char_pattern \
  jq_filter_without_field_names sed_script_without_regex
for function in deny_path_char_hex_pattern deny_path_shell_expansion_char_pattern deny_path_pin_char_pattern \
  jq_filter_without_field_names sed_script_without_regex; do
  . "$CASE/$function.sh"
done
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
while read -r char expected; do
  status=0
  deny_path_char_hex_pattern "$char" >"$CASE/out" 2>"$CASE/err" || status=$?
  if [ "$status" -eq 0 ] && [ "$sx_hex" = "$expected" ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ]; then
    ok "deny-path hex $char"
  else
    bad "deny-path hex $char"
  fi
done <<'CASES'
0 3[0]
1 3[1]
2 3[2]
3 3[3]
4 3[4]
5 3[5]
6 3[6]
7 3[7]
8 3[8]
9 3[9]
a 6[1]
b 6[2]
c 6[3]
d 6[4]
e 6[5]
f 6[6]
g 6[7]
h 6[8]
i 6[9]
j 6[aA]
k 6[bB]
l 6[cC]
m 6[dD]
n 6[eE]
o 6[fF]
p 7[0]
q 7[1]
r 7[2]
s 7[3]
t 7[4]
u 7[5]
v 7[6]
w 7[7]
x 7[8]
y 7[9]
z 7[aA]
A 6[1]
B 6[2]
C 6[3]
D 6[4]
E 6[5]
F 6[6]
G 6[7]
H 6[8]
I 6[9]
J 6[aA]
K 6[bB]
L 6[cC]
M 6[dD]
N 6[eE]
O 6[fF]
P 7[0]
Q 7[1]
R 7[2]
S 7[3]
T 7[4]
U 7[5]
V 7[6]
W 7[7]
X 7[8]
Y 7[9]
Z 7[aA]
. 2[eE]
_ 5[fF]
- 2[dD]
CASES
for char in '' '/' '?' '\' 'é' '日本語' 'ab' '
'; do
  sx_hex=stale
  status=0
  deny_path_char_hex_pattern "$char" >"$CASE/out" 2>"$CASE/err" || status=$?
  if [ "$status" -eq 1 ] && [ -z "$sx_hex" ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ]; then
    ok 'deny-path unsupported hex clears prior output'
  else
    bad 'deny-path unsupported hex clears prior output'
  fi
done
check_char() {
  label=$1 expected=$3
  ch=caller literal=caller hex=caller sx_rest=caller sx_n=caller
  status=0
  deny_path_shell_expansion_char_pattern "$2" >"$CASE/out" 2>"$CASE/err" || status=$?
  if [ "$status" -eq 0 ] && [ "$sx_char" = "$expected" ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ] \
      && [ "$ch:$literal:$hex:$sx_rest:$sx_n" = caller:caller:caller:caller:caller ]; then
    ok "deny-path character $label"
  else
    bad "deny-path character $label"
  fi
}
check_char letter a '(a|\\x6[1]|\?|\*|\[[^]]*[^]0-9-][^]]*\])'
check_char uppercase Q '(Q|\\x7[1]|\?|\*|\[[^]]*[^]0-9-][^]]*\])'
check_char digit 5 '(5|\\x3[5]|\?|\*|\[[^]]+\])'
check_char dot . '(\.|\\x2[eE])'
check_char slash / /
check_char question '?' '(\?|\?|\*|\[[^]]+\])'
check_char quote "'" "('|\?|\*|\[[^]]+\])"
check_char empty '' '(|\?|\*|\[[^]]+\])'
check_char unicode 'é' '(é|\?|\*|\[[^]]+\])'
check_char newline '
' '(
|\?|\*|\[[^]]+\])'
sx_pin=stale
deny_path_pin_char_pattern a >"$CASE/out" 2>"$CASE/err"
if [ "$sx_pin" = '(a|\[[^]]*a[^]]*\]|\\x6[1])' ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ]; then
  ok 'deny-path pin ASCII exact bytes'
else
  bad 'deny-path pin ASCII exact bytes'
fi
deny_path_pin_char_pattern 'é' >"$CASE/out" 2>"$CASE/err"
if [ "$sx_pin" = '(é|\[[^]]*é[^]]*\])' ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ]; then
  ok 'deny-path pin Unicode clears earlier hex'
else
  bad 'deny-path pin Unicode clears earlier hex'
fi
tab=$(printf '\t')
while IFS=$tab read -r filter expected; do
  actual=$(jq_filter_without_field_names "$filter" 2>"$CASE/err")
  if [ "$actual" = "$expected" ] && [ ! -s "$CASE/err" ]; then
    ok "jq filter field names: $filter"
  else
    bad "jq filter field names: $filter (got $actual)"
  fi
done <<'CASES'
.key	.
.data.key	.
select(.key|test("^AG_"))	select(.|test("^AG_"))
.[] | {name: .name, key: .key}	.[] | {name: ., key: .}
.items[0].key, .meta?.key	.[0]., .?.
env.AWS_REGION	env
{v: env.HOME}	{v: env}
"\(env.HOME)/x"	"\(env)/x"
myenv.HOME	myenv.HOME
$env.HOME	$env.HOME
"env.HOME"	"env.HOME"
$ENV.HOME	$ENV.HOME
$x.key	$x.key
"server.key"	"server.key"
..key	..key
.	.
import ".env" as $x; $x.key	import ".env" as $x; $x.key
"\(.key) \"q\" .key" | .key	"\(.) \"q\" .key" | .
.a # "x" .key	. # "x" .key
CASES
# A comment in an interpolation can hide its ")"; the filter stays unchanged.
filter='"\(1 # ) "
)env.local" | .key'
actual=$(jq_filter_without_field_names "$filter" 2>"$CASE/err")
if [ "$actual" = "$filter" ] && [ ! -s "$CASE/err" ]; then
  ok "jq filter field names: a comment in an interpolation"
else
  bad "jq filter field names: a comment in an interpolation (got $actual)"
fi
# `!` marks a script that must be refused and printed as nothing.
while IFS=$tab read -r script expected; do
  status=0
  actual=$(sed_script_without_regex "$script" 2>"$CASE/err") || status=$?
  if [ "$expected" = '!' ]; then
    if [ "$status" -ne 0 ] && [ -z "$actual" ]; then
      ok "sed script refused: $script"
    else
      bad "sed script refused: $script (got $actual)"
    fi
  elif [ "$status" -eq 0 ] && [ "$actual" = "$expected" ] && [ ! -s "$CASE/err" ]; then
    ok "sed script regex removed: $script"
  else
    bad "sed script regex removed: $script (got $status $actual)"
  fi
done <<'CASES'
s/a/b/	s//b/
s/^d2-gate\t[^\t]*\t//	s///
s/^([^\t]*)\t[^\t]*\t[^ ]+ /\1 | /	s//\1 | /
s|a/b|c|g	s||c|g
s/x\/y/z/2p	s//z/2p
s/a/b/; s/[[:space:]]*$//g	s//b/;s///g
s/[]x]*//	s///
s/[^]x]*//I	s///I
s/a/\//	s//\//
s/a/b/w out	!
s/a/b/e	!
r x	!
p	p
/a/s/b/c/	//s//c/
s/a/b/;p	s//b/;p
1,50p	1,50p
/secrets.json/,+5p	//,+5p
/a/,/b/d	//,//d
$=	$=
/a/w out	!
/a/r x	!
/a/!d	!
/a/I p	!
1,	!
/[/]/p	!
/a	!
s/[/]//	!
s/[\]]//	!
s/[[:/:]]//	!
s/[a//	!
s/a	!
s/a/b	!
sxaxbx	!
CASES
nl='
'
status=0
sed_script_without_regex "s/a/b/${nl}p" >/dev/null 2>&1 || status=$?
if [ "$status" -ne 0 ]; then ok "sed script refused: a newline"; else bad "sed script refused: a newline"; fi
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

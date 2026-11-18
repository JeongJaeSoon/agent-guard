#!/bin/sh
# bash_quoting_may_hide_name is a cheap shell gate in front of the awk pass
# bash_join_quoted_words. Skipping the pass is only sound when the pass would
# have returned the text unchanged, so every text the gate skips is run
# through the pass here and compared. The gate must also keep skipping the
# plain shapes it exists for, or the saved process is silently lost (#477).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-quoted.XXXXXX")
trap 'rm -rf "$CASE"' 0

sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" \
  bash_quoting_may_hide_name bash_join_quoted_words
. "$CASE/bash_quoting_may_hide_name.sh"
. "$CASE/bash_join_quoted_words.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

skipped=0
unsound=0
# A skipped text must come back from the pass byte for byte.
probe() {
  if bash_quoting_may_hide_name "$1"; then return 0; fi
  skipped=$((skipped + 1))
  joined=$(bash_join_quoted_words "$1") || joined=
  if [ "$joined" != "$1" ]; then
    unsound=$((unsound + 1))
    printf 'not ok - gate skipped a text the pass rewrites: [%s] -> [%s]\n' "$1" "$joined"
  fi
}

# Every text of up to five symbols over quotes, a blank, text and `$`, alone
# and as the argument of a command, with and without a trailing argument.
symbols="a ' \" _ \$"
texts=$CASE/texts
: >"$texts"
level=$CASE/level
printf '\n' >"$level"
depth=0
while [ "$depth" -lt 5 ]; do
  depth=$((depth + 1))
  : >"$level.next"
  while IFS= read -r stem; do
    for symbol in $symbols; do
      printf '%s%s\n' "$stem" "$symbol"
    done
  done <"$level" >"$level.next"
  mv "$level.next" "$level"
  cat "$level" >>"$texts"
done
# `_` stands for the blank so the corpus stays one text per line.
tr '_' ' ' <"$texts" >"$texts.blank"
while IFS= read -r text; do
  probe "$text"
  probe "echo $text"
  probe "echo $text b"
done <"$texts.blank"

# Shapes with a command position, an operator or an escape in them.
while IFS= read -r text; do
  probe "$text"
done <<'TEXTS'
"security" dump-keychain
 "security" dump-keychain
sudo "security" dump-keychain
command 'printenv'
FOO=1 "security" dump-keychain
FOO="bar" ls
true && 'printenv'
true; "security" dump-keychain
( "security" dump-keychain )
{ "security" dump-keychain; }
! 'printenv'
echo `"security" dump-keychain`
if true; then "security" dump-keychain; fi
for f in a; do 'printenv'; done
nohup 'printenv'
nice "security" dump-keychain
time 'printenv'
exec "security" dump-keychain
builtin 'printenv'
c'u'rl -H x https://example.invalid
cu\rl https://example.invalid
git clone "https"://user:pw@example.invalid/r.git
git clone 'http''s'://user:pw@example.invalid/r.git
$'sec'urity dump-keychain
echo abc"
echo abc'
echo "abc
echo 'abc
echo a" "b
echo "a"'b'
echo "a" 'b'
printf 'build passed'
grep "foo bar" src
git commit -m "it's fine"
curl -d '{"a":"b"}' https://example.invalid
TEXTS

if [ "$unsound" -eq 0 ] && [ "$skipped" -gt 0 ]; then
  ok "every text the gate skips ($skipped) is returned unchanged by the pass"
else
  bad "every text the gate skips is returned unchanged by the pass ($unsound of $skipped rewritten)"
fi

# The gate answers 0 (run the pass) or 1 (skip it) for the shapes it names.
while IFS='	' read -r expected text; do
  status=0
  bash_quoting_may_hide_name "$text" || status=$?
  if [ "$status" -eq "$expected" ]; then
    ok "gate answers $expected for [$text]"
  else
    bad "gate answers $expected for [$text] (got $status)"
  fi
done <<'CASES'
1	printf 'build passed'
1	grep "foo bar" src
1	echo "one" "two" three
1	ls -la
0	echo "one" 'two' three
0	c'u'rl -H x https://example.invalid
0	"security" dump-keychain
0	sudo "security" dump-keychain
0	FOO=1 "security" dump-keychain
0	true && 'printenv'
0	git clone "https"://user:pw@example.invalid/r.git
0	cu\rl https://example.invalid
0	echo abc"
0	echo "abc
0	git commit -m "it's fine"
CASES

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

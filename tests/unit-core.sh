#!/bin/sh
# Exercise production function bodies without running CLI initialization.
# An alternate source is for test-harness mutation checks, never a CLI bypass.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-core.XXXXXX")
trap 'rm -rf "$CASE"' 0

# Fail on missing/duplicate definitions or a changed extraction boundary.
# Only these named bodies are sourced: the CLI has initialization side effects.
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" sh_squote version_newer
. "$CASE/sh_squote.sh"
. "$CASE/version_newer.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

# Independent numeric triplet expectations: equal, greater and less at every
# component, with earlier components dominating later ones. Inputs are already
# validated version triplets at production call sites; this is not a validator.
while read -r expected left right; do
  status=0
  version_newer "$left" "$right" >"$CASE/version.out" 2>"$CASE/version.err" || status=$?
  if [ "$status" -eq "$expected" ] && [ ! -s "$CASE/version.out" ] && [ ! -s "$CASE/version.err" ]; then
    ok "version $left > $right returns $expected without output"
  else
    bad "version $left > $right returns $expected without output"
  fi
done <<'CASES'
1 0.0.0 0.0.0
1 3.6.4 3.6.4
0 1.0.0 0.99.99
1 0.99.99 1.0.0
0 3.7.0 3.6.99
1 3.6.99 3.7.0
0 3.6.5 3.6.4
1 3.6.4 3.6.5
0 10.0.0 9.99.99
1 9.99.99 10.0.0
0 1.10.0 1.9.99
1 1.9.99 1.10.0
0 1.2.10 1.2.9
1 1.2.9 1.2.10
1 01.02.003 1.2.3
CASES

# Exact output checks are independent of a shell round trip.
check_quote() {
  name=$1 value=$2 expected=$3
  sh_squote "$value" >"$CASE/quoted"
  printf '%s' "$expected" >"$CASE/expected"
  if cmp -s "$CASE/quoted" "$CASE/expected"; then
    ok "quote $name exact bytes"
  else
    bad "quote $name exact bytes"
  fi
  # Execute only the emitted single word in a private directory. Fixed synthetic
  # metacharacters below must stay data, with exactly one argument and no files
  # created by command substitution. Compare files to preserve trailing LFs.
  {
    printf 'set -- '
    cat "$CASE/quoted"
    printf '\n[ "$#" -eq 1 ] || exit 9\nprintf "%%s" "$1"\n'
  } >"$CASE/roundtrip.sh"
  printf '%s' "$value" >"$CASE/value"
  if (cd "$CASE" && sh roundtrip.sh) >"$CASE/actual" 2>"$CASE/roundtrip.err" \
      && cmp -s "$CASE/value" "$CASE/actual" && [ ! -s "$CASE/roundtrip.err" ] \
      && [ ! -e "$CASE/injected" ]; then
    ok "quote $name is one literal shell argument"
  else
    bad "quote $name is one literal shell argument"
  fi
}
check_quote empty '' "''"
check_quote spaces 'two words' "'two words'"
check_quote apostrophe "a'b" "'a'\\''b'"
check_quote adjacent-quotes "''" "''\\'''\\'''"
check_quote backslash 'a\b' "'a\b'"
check_quote expansion '$(touch injected); `touch injected` $HOME * ? [ab]' \
  "'\$(touch injected); \`touch injected\` \$HOME * ? [ab]'"
check_quote option '-n' "'-n'"
check_quote unicode '日本語🙂' "'日本語🙂'"
value=$(printf 'a\tb'); check_quote tab "$value" "'$value'"
value='first
second

'; check_quote newlines "$value" "'$value'"
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

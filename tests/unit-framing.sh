#!/bin/sh
# Direct producer contracts: expected bytes do not reuse the encoder/decoder.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-framing.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" frame_json_string_leaves frame_plaintext_leaf
. "$CASE/frame_json_string_leaves.sh"
. "$CASE/frame_plaintext_leaf.sh"
pass=0 fail=0
check() {
  name=$1 function=$2 expected_status=${3:-0}
  status=0
  "$function" <"$CASE/input" >"$CASE/actual" 2>"$CASE/error" || status=$?
  if [ "$status" -eq "$expected_status" ] && cmp -s "$CASE/expected" "$CASE/actual" && [ ! -s "$CASE/error" ]; then
    pass=$((pass + 1)); printf 'ok - %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'not ok - %s (status %s)\n' "$name" "$status"
  fi
}
json_case() {
  printf '%s' "$2" >"$CASE/input"
  printf '%b' "$3" >"$CASE/expected"
  check "$1" frame_json_string_leaves
}
json_case 'JSON no string leaves' '{"n":1,"b":true,"z":null,"a":[]}' ''
json_case 'JSON empty string is a leaf' '""' '\036\n'
json_case 'JSON scalar string' '"alpha"' 'alpha\036\n'
json_case 'JSON nested values exclude keys and nonstrings' '{"key":"alpha","a":[false,"beta",{"n":""}]}' 'alpha\036\nbeta\036\n\036\n'
json_case 'JSON physical newline remains within leaf' '["first\nsecond\n","last"]' 'first\nsecond\n\036\nlast\036\n'
json_case 'JSON RS and US escape order' '["\u001e\u001f\u001f\u001e"]' '\037\036\037\037\037\037\037\036\036\n'
json_case 'JSON Unicode bytes' '["日本語🙂"]' '日本語🙂\036\n'
json_case 'JSON decoded quote backslash tab CR' '["a\"b\\c\t\r"]' 'a"b\\c\t\r\036\n'
plain_case() {
  printf '%b' "$2" >"$CASE/input"
  printf '%b' "$3" >"$CASE/expected"
  check "$1" frame_plaintext_leaf
}
plain_case 'plaintext empty input is one leaf' '' '\036'
plain_case 'plaintext no final newline' 'alpha' 'alpha\036'
# awk record semantics: one final LF terminates a record; preceding LFs remain.
plain_case 'plaintext single final LF terminates record' 'alpha\n' 'alpha\036'
plain_case 'plaintext interior LF preserved' 'first\nsecond' 'first\nsecond\036'
plain_case 'plaintext extra final LF preserved' 'alpha\n\n' 'alpha\n\036'
plain_case 'plaintext RS and US escape order' '\036\037\037\036' '\037\036\037\037\037\037\037\036\036'
plain_case 'plaintext invalid UTF-8 and Unicode bytes' '\377日本語🙂' '\377日本語🙂\036'
plain_case 'plaintext CR remains while final LF terminates' 'alpha\r\n' 'alpha\r\036'

# Real framing must propagate a failed producer even after partial output.
mkdir "$CASE/bin"
for tool in jq awk; do
  printf '#!/bin/sh\nprintf partial\nexit 23\n' >"$CASE/bin/$tool"
  chmod +x "$CASE/bin/$tool"
done
: >"$CASE/input"
printf partial >"$CASE/expected"
PATH="$CASE/bin:$PATH" check 'JSON producer error and partial output' frame_json_string_leaves 23
PATH="$CASE/bin:$PATH" check 'plaintext producer error and partial output' frame_plaintext_leaf 23
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

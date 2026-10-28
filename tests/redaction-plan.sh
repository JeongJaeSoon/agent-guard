#!/bin/sh
# Independent output contracts for a response-wide literal replacement plan.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-redaction-plan.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" redact_tool_response_json
sed -n "/^JQ_SHAPE_SAFE_WALK='/,/^'$/p" "$SOURCE" >"$CASE/walk.sh"
. "$CASE/walk.sh"
. "$CASE/redact_tool_response_json.sh"
count=0
check() {
  redact_tool_response_json "$2" "$3" >"$CASE/actual"
  printf '%s' "$4" | jq -cS . >"$CASE/expected"
  jq -cS . <"$CASE/actual" >"$CASE/normalized"
  cmp "$CASE/expected" "$CASE/normalized"
  count=$((count + 1))
  printf 'ok - %s\n' "$1"
}
check 'longest literal first across nested leaves' \
  '{"outer":["abcd-long abcd",{"tail":"abcd-long"}],"n":7,"empty":""}' \
  '["abcd","abcd-long"]' \
  '{"outer":["[REDACTED] [REDACTED]",{"tail":"[REDACTED]"}],"n":7,"empty":""}'
check 'contextual replacement precedes ordinary replacement' \
  '["abcd more","abcde","abcd\nnext","abcd,abcd;abcd\tabcd"]' \
  '["abcd",{"literal":"abcd","replacement":"context","contextual":true}]' \
  '["context more","[REDACTED]e","context\nnext","context,context;context\tcontext"]'
check 'keys and protocol discriminators preserve shape' \
  '{"text":"text","type":"text","nested":{"type":"abcd"},"abcd":"abcd"}' \
  '["text","abcd"]' \
  '{"text":"[REDACTED]","type":"text","nested":{"type":"[REDACTED]"},"abcd":"[REDACTED]"}'
check 'equal length replacement order remains stable' \
  '["aaaa bbbb",{"s":"aaaa"}]' \
  '[{"literal":"aaaa","replacement":"bbbb"},{"literal":"bbbb","replacement":"done"}]' \
  '["bbbb done",{"s":"bbbb"}]'
check 'equal length contextual order remains stable across leaves' \
  '["aaaa bbbb",{"s":"aaaa"}]' \
  '[{"literal":"aaaa","replacement":"bbbb","contextual":true},{"literal":"bbbb","replacement":"done","contextual":true}]' \
  '["bbbb done",{"s":"bbbb"}]'
check 'empty literal does not insert replacements' '["",null,false,"clean"]' '[""]' '["",null,false,"clean"]'
specs=$(jq -nc '[range(257) | "literal-" + tostring]')
check 'record budget preserves conservative shape' \
  '{"type":"text","text":"clean","empty":"","n":7}' "$specs" \
  '{"type":"text","text":"[REDACTED]","empty":"","n":7}'
response=$(jq -nc '[range(500) | {type:"text",text:"abcd-long abcd"}]')
expected=$(jq -nc '[range(500) | {type:"text",text:"[REDACTED] [REDACTED]"}]')
check 'one plan applies to every leaf' "$response" '["abcd","abcd-long"]' "$expected"
printf 'passed: %s\n' "$count"

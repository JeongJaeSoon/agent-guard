#!/bin/sh
# The same NUL contract must hold on jq 1.6 and newer jq releases.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-nul-unit.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" redact_nul_response_json
sed -n "/^JQ_WALK='/,/^'$/p" "$SOURCE" >"$CASE/walk.sh"
. "$CASE/walk.sh"
. "$CASE/redact_nul_response_json.sh"
if [ -n "${AGENT_GUARD_TEST_JQ:-}" ]; then
  mkdir "$CASE/bin"
  printf '#!/bin/sh\nexec "$AGENT_GUARD_TEST_JQ" "$@"\n' >"$CASE/bin/jq"
  chmod +x "$CASE/bin/jq"
  PATH="$CASE/bin:$PATH"
  export PATH AGENT_GUARD_TEST_JQ
fi
check() {
  redact_nul_response_json "$1" >"$CASE/actual"
  printf '%s' "$2" | jq -cS . >"$CASE/expected"
  jq -cS . <"$CASE/actual" >"$CASE/normalized"
  cmp "$CASE/expected" "$CASE/normalized"
}
check '["clean","",null,false,0,"한글 😀"]' '["clean","",null,false,0,"한글 😀"]'
check '{"stdout":"prefix\u0000secret","clean":"visible","nested":["safe","\u0000"],"key\u0000":"value"}' \
  '{"stdout":"[REDACTED]","clean":"visible","nested":["safe","[REDACTED]"],"key\u0000":"value"}'
check '["left\u0000middle\u0000right","\\u0000"]' '["[REDACTED]","\\u0000"]'
printf 'passed: 3\nfailed: 0\n'

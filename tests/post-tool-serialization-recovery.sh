#!/bin/sh
# A successful jq exit does not guarantee a complete deep JSON serialization.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-serialization.XXXXXX")
trap 'rm -rf "$CASE"' 0
REAL_JQ=${AGENT_GUARD_TEST_JQ:-$(command -v jq)}
export REAL_JQ
mkdir "$CASE/bin" "$CASE/private" "$CASE/truncate"
cp "$ROOT/tests/fixtures/mock-gitleaks" "$CASE/bin/gitleaks"
printf '#!/bin/sh\nexec "$REAL_JQ" "$@"\n' >"$CASE/bin/jq"
cat >"$CASE/truncate/jq" <<'SH'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = -c ] && [ "$2" = '.tool_response // empty' ]; then
  cat >/dev/null
  printf '%s\n' '[[<skipped: too deep>]]'
  exit 0
fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$CASE/bin/gitleaks" "$CASE/bin/jq" "$CASE/truncate/jq"
PATH="$CASE/bin:$PATH"
export PATH
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/private"
CLI=${AGENT_GUARD_TEST_CLI:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
input=$(printf '%s%s%s%s%s%s' \
  '{"tool_name":"Read","tool_input":{},"tool_response":[["' \
  'PASS' 'WORD=' 'K7mQ2vN9xR4c' 'T8pL6sW3' '"]]}')
for host in claude codex; do
  printf '%s' "$input" | PATH="$CASE/truncate:$PATH" AGENT_GUARD_HOOK_HOST="$host" \
    "$CLI" hook-post-tool >"$CASE/actual" 2>"$CASE/stderr"
  case "$host" in
    claude)
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":[["[REDACTED]"]]}}' >"$CASE/expected"
      ;;
    codex)
      printf '%s\n' '{"decision":"block","reason":"Agent Guard blocked the original tool output because it contained sensitive values; use the sanitized replacement in additionalContext.","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Agent Guard sanitized tool output:\n[[\"[REDACTED]\"]]"}}' >"$CASE/expected"
      ;;
  esac
  cmp "$CASE/expected" "$CASE/actual"
  grep -q 'primary PostToolUse JSON processing failed' "$CASE/stderr"
  printf 'ok - %s recovers the original shape after successful but invalid serialization\n' "$host"
done

# The marker can occur as ordinary text; it must not itself trigger masking.
printf '%s' '{"tool_name":"Read","tool_input":{},"tool_response":"documentation: <skipped: too deep>"}' \
  | "$CLI" hook-post-tool >"$CASE/actual" 2>"$CASE/stderr"
test ! -s "$CASE/actual"
test ! -s "$CASE/stderr"
printf 'ok - literal truncation-marker text remains clean\n'

# Real jq 1.8.1 emits its marker at depth 257 with status 0. Other versions may
# reject the input or preserve it. Compare complete bytes without that parser.
{
  printf '%s' '{"tool_name":"Read","tool_input":{},"tool_response":'
  awk 'BEGIN { for (i=0; i<2000; i++) printf "[" }'
  printf '"%s%s%s%s"' 'PASS' 'WORD=' 'K7mQ2vN9xR4c' 'T8pL6sW3'
  awk 'BEGIN { for (i=0; i<2000; i++) printf "]" }'
  printf '%s' '}'
} | "$CLI" hook-post-tool >"$CASE/actual" 2>"$CASE/stderr"
for leaf in '[REDACTED]' 'PASSWORD=[REDACTED]'; do
  {
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedToolOutput":'
    awk 'BEGIN { for (i=0; i<2000; i++) printf "[" }'
    printf '"%s"' "$leaf"
    awk 'BEGIN { for (i=0; i<2000; i++) printf "]" }'
    printf '%s\n' '}}'
  } >"$CASE/expected"
  if cmp -s "$CASE/expected" "$CASE/actual"; then
    printf 'ok - real jq preserves the full depth-2000 replacement shape\n'
    printf 'passed: 4\nfailed: 0\n'
    exit 0
  fi
done
printf 'not ok - real jq lost the depth-2000 replacement shape\n' >&2
exit 1

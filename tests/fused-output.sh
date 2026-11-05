#!/bin/sh
# A failed prepare helper must not contaminate the completed detector records.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
cat >"$CASE/scanner" <<'SCANNER'
#!/bin/sh
case "$1" in
  version) printf '8.30.1\n' ;;
  stdin)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --report-path ]; then shift; report=$1; fi
      shift
    done
    cat >"$SCANNED_INPUT"
    printf '[{"Secret":"report-synthetic-value"}]\n' >"$report"
    exit 1 ;;
  *) exit 2 ;;
esac
SCANNER
cat >"$CASE/partial" <<'PREPARE'
#!/bin/sh
printf 'untrusted partial scanner input' >"$2"
printf 'untrusted partial frames' >"$3"
printf 'prepared-v1\n'
exit 2
PREPARE
chmod +x "$CASE/scanner" "$CASE/partial"
export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused
export AGENT_GUARD_GITLEAKS_BIN="$CASE/scanner"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_OUTPUT_REDACT=mask
export SCANNED_INPUT="$CASE/scanned"
unset AI_AGENT
pass=0
mkdir -p "$CASE/no-module/bin"
cp "$ROOT/plugins/agent-guard/bin/agent-guard" "$CASE/no-module/bin/agent-guard"
cp -R "$ROOT/plugins/agent-guard/config" "$CASE/no-module/config"
for host in claude codex; do
  export AGENT_GUARD_HOOK_HOST=$host
  for helper in "$CASE/partial" "$CASE/missing" no-module; do
    export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN=$helper
    guard="$ROOT/plugins/agent-guard/bin/agent-guard"
    if [ "$helper" = no-module ]; then guard="$CASE/no-module/bin/agent-guard"; fi
    printf '%s' '{"tool_name":"mcp__report__read","tool_response":{"type":"text","text":"before report-synthetic-value after","clean":"visible"}}' \
      | "$guard" hook-post-tool >"$CASE/out" 2>"$CASE/err"
    printf 'text\nbefore report-synthetic-value after\nvisible' >"$CASE/expected-scan"
    cmp "$CASE/scanned" "$CASE/expected-scan"
    if [ "$host" = claude ]; then
      jq -e '.hookSpecificOutput.updatedToolOutput == {type:"text",text:"before [REDACTED] after",clean:"visible"}' "$CASE/out" >/dev/null
    else
      jq -e '.decision == "block" and .hookSpecificOutput.hookEventName == "PostToolUse" and
        (.hookSpecificOutput.additionalContext | ltrimstr("Agent Guard sanitized tool output:\n") | fromjson) ==
        {type:"text",text:"before [REDACTED] after",clean:"visible"}' "$CASE/out" >/dev/null
    fi
    pass=$((pass + 1))
  done
done
printf 'passed: %s; partial/missing prepare and missing module preserve independent scanner input and precise host output\n' "$pass"

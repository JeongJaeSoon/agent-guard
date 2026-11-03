#!/bin/sh
# Invalid/empty scanner reports must never be accepted as a clean detection.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BIN:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-scanner-report.XXXXXX")
trap 'rm -rf "$CASE"' 0
cat >"$CASE/scanner" <<'SCANNER'
#!/bin/sh
case $1 in
  version) printf '8.30.1\n' ;;
  stdin)
    shift
    report=
    while [ "$#" -gt 0 ]; do
      case $1 in --report-path) shift; report=$1 ;; esac
      shift
    done
    cat >/dev/null
    [ -z "$report" ] || cp "$REPORT_FIXTURE" "$report"
    exit "$REPORT_STATUS"
    ;;
  *) exit 2 ;;
esac
SCANNER
chmod +x "$CASE/scanner"
export AGENT_GUARD_GITLEAKS_BIN="$CASE/scanner"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_OUTPUT_REDACT=mask
export REPORT_FIXTURE="$CASE/report" REPORT_STATUS=0
unset AI_AGENT
pass=0 fail=0
check() {
  name=$1 report=$2 expected=$3
  printf '%s' "$report" >"$REPORT_FIXTURE"
  status=0
  printf '%s' '{"tool_name":"mcp__report__read","tool_response":{"type":"text","text":"before report-synthetic-value after"}}' \
    | "$GUARD" hook-post-tool >"$CASE/out" 2>"$CASE/err" || status=$?
  valid=no
  case $expected in
    clean) [ -s "$CASE/out" ] || valid=yes ;;
    whole|precise)
      text='[REDACTED]'
      [ "$expected" != precise ] || text='before [REDACTED] after'
      jq -e --arg text "$text" '
        .hookSpecificOutput.hookEventName == "PostToolUse" and
        .hookSpecificOutput.updatedToolOutput == {type:"text",text:$text}
      ' "$CASE/out" >/dev/null 2>&1 && valid=yes
      ;;
  esac
  if [ "$status" -eq 0 ] && [ "$valid" = yes ]; then
    pass=$((pass + 1)); printf 'ok - %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'not ok - %s (status %s)\n' "$name" "$status"
  fi
}
check 'empty report fails closed' '' whole
check 'whitespace-only report fails closed' '   ' whole
check 'non-array report fails closed' '{}' whole
check 'partially written report fails closed' '[{"Secret":"report-synthetic-value"}' whole
check 'mixed report document types fail closed' '[] {}' whole
check 'valid empty array stays clean' '[]' clean
REPORT_STATUS=1
check 'valid finding keeps precise replacement' '[{"Secret":"report-synthetic-value"}]' precise
REPORT_STATUS=2
check 'scanner failure fails closed with a valid empty array' '[]' whole
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

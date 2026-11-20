#!/usr/bin/env sh
set -u

# Every tool a shipped PreToolUse matcher sends to the guard must reach a check:
# for each listed name, an input carrying something that tool kind must not
# pass is blocked. A name added to a matcher without a row here fails, so
# widening host coverage forces a decision about what the guard checks for it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
PLUGIN=${AGENT_GUARD_TEST_PLUGIN_ROOT:-$ROOT/plugins/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-tool-coverage.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" "$CASE/repo" || exit 1
cd "$CASE/repo" || exit 1
git init -q || exit 1
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_OUTPUT_REDACT AI_AGENT
S=AGENT_GUARD_TEST_SECRET
passed=0
failed=0

# planted TOOL prints a tool_input the guard must block for that tool.
planted() {
  case $1 in
    Write) printf '{"file_path":"a.ts","content":"%s"}' "$S" ;;
    Edit) printf '{"file_path":"a.ts","old_string":"x","new_string":"%s"}' "$S" ;;
    MultiEdit) printf '{"file_path":"a.ts","edits":[{"new_string":"%s"}]}' "$S" ;;
    NotebookEdit) printf '{"notebook_path":"n.ipynb","new_source":"%s"}' "$S" ;;
    apply_patch) printf '{"command":"*** Begin Patch\\n*** Add File: x\\n+%s\\n*** End Patch"}' "$S" ;;
    Read) printf '{"file_path":".env"}' ;;
    NotebookRead) printf '{"notebook_path":".env"}' ;;
    Grep) printf '{"pattern":"TODO","path":".env"}' ;;
    Glob) printf '{"pattern":"*.pem"}' ;;
    Bash) printf '{"command":"printf %s > leaked.txt"}' "$S" ;;
    WebFetch) printf '{"url":"https://example.invalid/?k=%s","prompt":"x"}' "$S" ;;
    WebSearch) printf '{"query":"%s"}' "$S" ;;
    Agent|Task) printf '{"description":"x","prompt":"use %s"}' "$S" ;;
    mcp__*) printf '{"arg":"%s"}' "$S" ;;
    *) return 1 ;;
  esac
}

# matcher_names FILE prints each alternative of the PreToolUse matcher, with a
# regex-shaped MCP entry turned into a concrete tool name.
matcher_names() {
  jq -r '.hooks.PreToolUse[0].matcher' "$1" \
    | sed 's/^\^(//; s/)\$$//' | tr '|' '\n' \
    | sed 's/^mcp__\.\*$/mcp__probe__call/'
}

for host in claude codex; do
  case $host in
    claude) manifest=$PLUGIN/hooks/hooks.json ;;
    codex) manifest=$PLUGIN/hooks.json ;;
  esac
  names=$(matcher_names "$manifest") || exit 1
  count=0
  for name in $names; do
    count=$((count + 1))
    if ! tool_input=$(planted "$name"); then
      failed=$((failed + 1))
      printf 'not ok - %s matcher sends %s, which has no planted input here\n' "$host" "$name"
      continue
    fi
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$name" "$tool_input" \
      | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
    status=$?
    if [ "$status" -eq 2 ]; then passed=$((passed + 1)); else
      failed=$((failed + 1))
      printf 'not ok - %s %s reaches no check (status %s)\n' "$host" "$name" "$status"
      sed 's/^/  stderr: /' "$CASE/err"
    fi
  done
  # An empty or unparsed matcher would pass the loop vacuously.
  if [ "$count" -ge 5 ]; then passed=$((passed + 1)); else
    failed=$((failed + 1)); printf 'not ok - %s matcher lists %s tools\n' "$host" "$count"
  fi
done

printf 'tool coverage assertions: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0

#!/usr/bin/env sh
# Synthetic hook inputs only: nothing in the fixtures is executed.
# A subagent report that names a credential setting without its value (a
# variable reference, an empty value, a placeholder) is not a secret: the
# prompt guard must pass it and the output masker must keep it. A report that
# carries a real value stays blocked and masked.
#
# Each fixture row is checked in three host shapes: a Claude UserPromptSubmit
# carrying the `[Subagent hand-back]` frame, a Codex UserPromptSubmit with the
# plain report, and a Claude PostToolUse for the Agent tool. A `{{SECRET}}`
# or `{{DIGITS}}` token is replaced at run time with random characters, so the
# repository holds no credential-shaped literal.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURES=${AGENT_GUARD_TEST_FIXTURES:-$(ls "$ROOT"/tests/fixtures/handback-*.json)}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-handback.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' EXIT HUP INT TERM
mkdir "$CASE/home" "$CASE/work"
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_PROMPT_GUARD_MODE=block
export AGENT_GUARD_INFRA_FAILURE_MODE=open AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
unset AGENT_GUARD_OUTPUT_REDACT AI_AGENT
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
if [ -n "$GITLEAKS" ]; then
  unset AGENT_GUARD_GITLEAKS_BIN
  PATH="$(dirname "$GITLEAKS"):$PATH"
else
  export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
fi
secret=$(od -An -N18 -tu1 /dev/urandom \
  | awk '{ for (i = 1; i <= NF; i++) printf "%c", (i % 3 == 0 ? 48 + $i % 10 : (i % 3 == 1 ? 65 : 97) + $i % 26) }')
digits=$(od -An -N6 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) printf "%d", $i % 10 }')
failed=0
checked=0
result() {
  checked=$((checked + 1))
  if [ "$1" = ok ]; then printf 'ok - %s\n' "$2"
  else
    printf 'not ok - %s\n' "$2"
    sed 's/^/#   /' "$CASE/err"
    failed=$((failed + 1))
  fi
}
for fixture in $FIXTURES; do
  jq -e 'type == "array" and length > 0' "$fixture" >/dev/null || {
    printf 'not ok - %s is not a non-empty array\n' "$fixture"
    failed=$((failed + 1))
    continue
  }
  jq -c '.[]' "$fixture" >"$CASE/rows" || exit 1
  while IFS= read -r row; do
    expected=$(printf '%s' "$row" | jq -r '.expected')
    name=$(printf '%s' "$row" | jq -r '.id + " (" + .classification + "): " + .description')
    text=$(printf '%s' "$row" | jq -r --arg s "$secret" --arg d "$digits" \
      '.text | gsub("\\{\\{SECRET\\}\\}"; $s) | gsub("\\{\\{DIGITS\\}\\}"; $d)')
    # A must-fail value that is not a generated token names the text that
    # must not survive the Agent result masking.
    gone=$(printf '%s' "$row" | jq -r '.gone // empty')
    case "$expected" in pass) want=0 ;; *) want=2 ;; esac

    jq -nc --arg p "$(printf '<agent-message from="a1b2c3d4">\n[Subagent hand-back] The report follows:\n%s\n' "$text")" \
      '{hook_event_name:"UserPromptSubmit",prompt:$p}' \
      | AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
    status=$?
    [ "$status" -eq "$want" ] && r=ok || r=bad
    result "$r" "[claude hand-back prompt] $name (expected $want, got $status)"

    jq -nc --arg p "$text" '{hook_event_name:"UserPromptSubmit",prompt:$p}' \
      | AGENT_GUARD_HOOK_HOST=codex "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
    status=$?
    [ "$status" -eq "$want" ] && r=ok || r=bad
    result "$r" "[codex prompt] $name (expected $want, got $status)"

    jq -nc --arg t "$text" \
      '{hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"Explore",prompt:"report"},tool_response:{content:[{type:"text",text:$t}]}}' \
      | (cd "$CASE/work" && AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-post-tool) >"$CASE/out" 2>"$CASE/err"
    status=$?
    if [ "$expected" = pass ]; then
      [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ] && r=ok || r=bad
      result "$r" "[claude Agent result] $name is left unmasked (status $status)"
    else
      [ "$status" -eq 0 ] && [ -s "$CASE/out" ] && ! grep -Fq -- "$secret" "$CASE/out" \
        && { [ -z "$gone" ] || ! grep -Fq -- "$gone" "$CASE/out"; } && r=ok || r=bad
      result "$r" "[claude Agent result] $name is masked (status $status)"
    fi
  done <"$CASE/rows"
done
printf '%s hand-back value checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

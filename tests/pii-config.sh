#!/usr/bin/env sh
set -u

# A PII setting the guard cannot honor must stop every entry point with exit 2
# and no output, never fall back to unmasked or ungated text. Each misconfigured
# value below goes through every command that reads it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-pii-config.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" "$CASE/repo" || exit 1
git -C "$CASE/repo" init -q || exit 1
cd "$CASE/repo" || exit 1
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_HOOK_HOST=claude
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_PII_HOOK_MODE AGENT_GUARD_PII_SKIP AGENT_GUARD_PII_PROVIDER
unset AGENT_GUARD_PII_REDACT_URL AGENT_GUARD_OUTPUT_REDACT AI_AGENT
passed=0
failed=0

# run_entry ENTRY ENV... runs one entry point with PII input under ENV.
run_entry() {
  entry=$1
  shift
  case $entry in
    pre) printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"card 4111 1111 1111 1111"}}' \
      | env "$@" "$GUARD" hook-pre-tool ;;
    post) printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"m"},"tool_response":"mail x@y.io"}' \
      | env "$@" "$GUARD" hook-post-tool ;;
    prompt) printf '%s' '{"session_id":"t","prompt":"card 4111 1111 1111 1111"}' \
      | env "$@" "$GUARD" hook-user-prompt ;;
    exec) env "$@" "$GUARD" exec -- printf 'mail x@y.io\n' </dev/null ;;
    filter) printf '%s' 'mail x@y.io' | env "$@" "$GUARD" pii-filter ;;
    check) env "$@" "$GUARD" pii-filter --check </dev/null ;;
  esac
}

# expect_refusal NAME ENTRY MESSAGE ENV...
expect_refusal() {
  name=$1 entry=$2 message=$3
  shift 3
  run_entry "$entry" "$@" >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ] && grep -q -- "$message" "$CASE/err"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'not ok - %s at %s (status %s)\n' "$name" "$entry" "$status"
    sed 's/^/  stdout: /' "$CASE/out"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
}

for entry in pre post prompt exec; do
  for mode in bogus MASK 'mask '; do
    expect_refusal "unsupported hook mode '$mode'" "$entry" 'unsupported PII hook mode' \
      AGENT_GUARD_PII_HOOK_MODE="$mode"
  done
  # Checked even when the gate itself is off, so a later switch to mask cannot
  # be the first time the setting is read.
  for mode in off mask block; do
    expect_refusal "Tier-2 skip with mode $mode" "$entry" 'AGENT_GUARD_PII_SKIP' \
      AGENT_GUARD_PII_HOOK_MODE="$mode" AGENT_GUARD_PII_SKIP=CREDIT_CARD
  done
done

for entry in filter check; do
  for skip in CREDIT_CARD SSN KR_RRN BOGUS ip_address 'EMAIL,SSN'; do
    expect_refusal "skip '$skip'" "$entry" 'AGENT_GUARD_PII_SKIP' AGENT_GUARD_PII_SKIP="$skip"
  done
  for provider in bogus REGEX ' regex'; do
    expect_refusal "provider '$provider'" "$entry" 'unsupported provider' \
      AGENT_GUARD_PII_PROVIDER="$provider"
  done
  # An endpoint provider redacts server-side and never receives the skip set.
  for provider in http pleno; do
    expect_refusal "skip with provider $provider" "$entry" 'AGENT_GUARD_PII_SKIP' \
      AGENT_GUARD_PII_SKIP=IP_ADDRESS AGENT_GUARD_PII_PROVIDER="$provider" \
      AGENT_GUARD_PII_REDACT_URL=http://127.0.0.1:1
  done
done

# Must-pass: valid settings reach the masker at each entry point.
out=$(printf '%s' 'mail x@y.io ip 8.8.8.8' | env AGENT_GUARD_PII_SKIP='IP_ADDRESS EMAIL' "$GUARD" pii-filter 2>"$CASE/err")
if [ "$out" = 'mail x@y.io ip 8.8.8.8' ]; then passed=$((passed + 1)); else
  failed=$((failed + 1)); printf 'not ok - space-separated skip set masks nothing it names: %s\n' "$out"
fi
out=$(env AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_PII_SKIP=IP_ADDRESS \
  "$GUARD" exec -- printf 'ip 8.8.8.8 mail x@y.io\n' 2>"$CASE/err")
if [ "$out" = 'ip 8.8.8.8 mail [PII:EMAIL]' ]; then passed=$((passed + 1)); else
  failed=$((failed + 1)); printf 'not ok - exec masks with a valid skip set: %s\n' "$out"
fi
out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"m"},"tool_response":"mail x@y.io"}' \
  | env AGENT_GUARD_PII_HOOK_MODE=mask "$GUARD" hook-post-tool 2>"$CASE/err" \
  | jq -r '.hookSpecificOutput.updatedToolOutput // empty')
if [ "$out" = 'mail [PII:EMAIL]' ]; then passed=$((passed + 1)); else
  failed=$((failed + 1)); printf 'not ok - hook-post-tool masks in mask mode: %s\n' "$out"
fi
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"a.ts","content":"card 4111 1111 1111 1111"}}' \
  | env AGENT_GUARD_PII_HOOK_MODE=mask "$GUARD" hook-pre-tool >/dev/null 2>"$CASE/err"
status=$?
if [ "$status" -eq 2 ] && grep -q 'high-sensitivity PII' "$CASE/err"; then passed=$((passed + 1)); else
  failed=$((failed + 1)); printf 'not ok - mask mode blocks a card on the way in (status %s)\n' "$status"
fi

printf 'PII config assertions: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0

#!/usr/bin/env sh
set -u

# A prose line can name a function that ends in Secret, then a colon and an
# issue-tracker id (`ABC-123`, `94S-1654`). The id is a reference, not a
# credential, so the prompt guard must pass it and the output masker must keep
# it. The exemption needs a camelCase Secret name, a colon, an unquoted or
# backticked uppercase id, and prose after it: the same id under another
# credential key, as a YAML scalar, after `=` or in a quoted field, a
# lowercase or longer id, and random or vendor-prefixed values after the same
# key stay blocked and masked.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE="$ROOT/tests/fixtures/prompt-issue-reference.txt"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-issue-ref.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' EXIT INT TERM
mkdir "$CASE/home"
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_PROMPT_GUARD_MODE=block AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
unset AGENT_GUARD_OUTPUT_REDACT AI_AGENT
# Prefer the real scanner so a pass is end to end; the mock still exercises
# the assignment probe, which is what this file is about.
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
if [ -n "$GITLEAKS" ]; then
  unset AGENT_GUARD_GITLEAKS_BIN
  PATH="$(dirname "$GITLEAKS"):$PATH"
else
  export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
fi
# Assembled at run time, as tests/run.sh does, so the repository's own scan
# finds no credential-shaped literal here. Nothing below prints these values.
rnd=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
pat="$(printf '%s%s' gh p_)${rnd}${rnd}abcd"
pw=$(printf '%s%s' pass word)
env_key=$(printf '%s%s' CLIENT _SECRET)
json_key=$(printf '%s%s' client Secret)
setter=$(printf '%s%s' setClient Secret)
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

prompt_case() {
  expected=$1 label=$2 prompt=$3
  jq -nc --arg p "$prompt" '{prompt:$p, hook_event_name:"UserPromptSubmit"}' \
    | "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then ok "prompt: $label"
  else bad "prompt: $label: expected $expected got $status"; fi
}

# Ground truth is the rewritten tool output, not the hook status: the id must
# survive and a real value in the same output must not.
mask_case() {
  label=$1 text=$2 keep=$3 gone=$4
  jq -nc --arg t "$text" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"cat notes"},tool_response:{stdout:$t,stderr:"",interrupted:false}}' \
    | "$GUARD" hook-post-tool >"$CASE/out" 2>"$CASE/err"
  if [ ! -s "$CASE/out" ]; then
    bad "mask: $label: no rewritten output"
    return
  fi
  if [ -n "$keep" ] && ! grep -Fq -- "$keep" "$CASE/out"; then
    bad "mask: $label: kept text was masked"
    return
  fi
  if grep -Fq -- "$gone" "$CASE/out"; then
    bad "mask: $label: secret survived"
    return
  fi
  ok "mask: $label"
}

[ -s "$FIXTURE" ] || { bad "fixture is missing"; exit 1; }
prompt_case 0 'reported spec line with a ticket id after a Secret-suffixed name' \
  "$(cat "$FIXTURE")"
prompt_case 0 'getter name, team key, Korean prose' '- getSecret: PROJ-42 이슈를 참고한다.'
prompt_case 0 'ticket id with a particle' '- setClientSecret: 94S-1654의 수용 조건'
prompt_case 0 'backticked ticket id' 'clientSecret: `WERFT-9` follow-up'
# The passing side of each limit, so an off-by-one tightening shows up.
prompt_case 0 'ten-character team key' "${setter}: WORKSPACES-12 참고"
prompt_case 0 'six-digit number' "${setter}: AB-123456 참고"
prompt_case 0 'two-syllable particle' "${setter}: AB-12에서 확인"
prompt_case 0 'backticked id with a trailing comma' "${setter}: \`AB-12,\` 참고"

# Must still block: real secret shapes after the same key, and id-shaped values
# outside the narrow colon form.
prompt_case 2 'random value after the same key' "- setClientSecret: ${rnd}Zq 인수 조건"
prompt_case 2 'vendor token prefix after the same key' "- setClientSecret: ${pat} 인수 조건"
prompt_case 2 'id-shaped value in an env assignment' "${env_key}=ABC-1234"
prompt_case 2 'id-shaped value in a quoted JSON field' "{\"${json_key}\": \"ABC-1234\"}"
prompt_case 2 'id-shaped value in single quotes' "${pw}: 'ABC-1234'"
prompt_case 2 'random value in backticks' "${pw}: \`${rnd}Zq\`"
prompt_case 2 'lowercase id-shaped value' "${pw}: hunter-1234"
prompt_case 2 'mixed-case id-shaped value' "${pw}: Hunter-1234"
prompt_case 2 'id with a long digit run' "${pw}: AB-12345678"
prompt_case 2 'id with a long prefix' "${pw}: ABCDEFGHIJK-12"
prompt_case 2 'id with a trailing letter' "${pw}: ABC-123x"
prompt_case 2 'id with a leading zero number' "${pw}: ABC-0123 참고"
# The id shape alone is not enough: only a camelCase Secret name followed by
# prose qualifies. Other credential keys, and a YAML scalar, stay blocked.
prompt_case 2 'id shape under a password key, YAML scalar' "${pw}: ABC-2024"
prompt_case 2 'id shape under a password key, then prose' "${pw}: ABC-2024 참고"
prompt_case 2 'id shape under an env-style key in YAML' "  ${env_key}: ABC-2024"
prompt_case 2 'id shape under a lowercase secret key' "${json_key%Secret}_secret: ABC-2024 참고"
prompt_case 2 'id shape under a Secret name at line end' 'setClientSecret: ABC-2024'
prompt_case 2 'id shape under a Secret name before a comment' 'clientSecret: ABC-2024 # rotate'
prompt_case 2 'backticked id shape under a password key' "${pw}: \`ABC-2024\` 참고"
# The blocking side of each value limit, under a qualifying name and prose, so
# loosening any one of them fails here.
prompt_case 2 'eleven-character team key' "${setter}: WORKSPACESX-12 참고"
prompt_case 2 'seven-digit number' "${setter}: AB-1234567 참고"
prompt_case 2 'leading-zero number' "${setter}: AB-0123 참고"
prompt_case 2 'all-digit team key' "${setter}: 2024-1234 참고"
prompt_case 2 'lowercase id' "${setter}: ab-1234 참고"
prompt_case 2 'id in single quotes' "${setter}: 'AB-1234' 참고"
prompt_case 2 'id in double quotes' "${setter}: \"AB-1234\" 참고"
prompt_case 2 'two particles' "${setter}: AB-1234의의 참고"
# What follows must be a word: a flow mapping, a comment or punctuation is not.
prompt_case 2 'flow mapping' "{${setter}: AB-1234, next: x}"
prompt_case 2 'slash comment' "${setter}: AB-1234 // rotate"
prompt_case 2 'semicolon comment' "${setter}: AB-1234 ; rotate"
prompt_case 2 'dash after the value' "${setter}: AB-1234 - rotate"

mask_case 'ticket id stays, real value is masked' \
  "setClientSecret: 94S-1654 adds a check
api_secret: ${rnd}Zq" '94S-1654' "${rnd}Zq"
mask_case 'backticked ticket id stays, real value is masked' \
  "clientSecret: \`WERFT-9\` follow-up
api_secret: ${rnd}Zq" 'WERFT-9' "${rnd}Zq"
mask_case 'id shape in a YAML password field is masked' \
  "${pw}: ABC-2024" '' 'ABC-2024'
mask_case 'env assignment of an id-shaped value is masked' \
  "${env_key}=ABC-1234" '' 'ABC-1234'

printf '%s issue-reference checks, %s failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]

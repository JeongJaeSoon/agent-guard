#!/usr/bin/env sh
set -u

# A prose line can say what happens to a secret instead of giving it
# (`client secret: must be rotated monthly`). After a colon, an unquoted value
# that opens with a listed modal or subordinator word and goes on with at
# least two lowercase words is a sentence, not a credential, so the prompt
# guard must pass it and the output masker must keep it. A backticked or
# quoted value, the `=` form, prose without a listed lead word, a single
# token, a tail word with a digit, an uppercase letter or a symbol, and a
# bare passphrase stay blocked and masked.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE="$ROOT/tests/fixtures/prompt-prose-reference.txt"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-prose-ref.XXXXXX") || exit 1
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
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
if [ -n "$GITLEAKS" ]; then
  unset AGENT_GUARD_GITLEAKS_BIN
  PATH="$(dirname "$GITLEAKS"):$PATH"
else
  export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
fi
# Assembled at run time so the repository's own scan finds no
# credential-shaped literal here. Nothing below prints these values.
hex=$(od -An -N20 -tx1 /dev/urandom | tr -d ' \n')
low=$(od -An -N28 -tu1 /dev/urandom \
  | awk '{ for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
word=$(printf '%s%s' sec ret)
pw=$(printf '%s%s' pass word)
weak=$(printf '%s%s' hunter 2)
key="client ${word}"
snake_key="client_${word}"
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

prompt_case() {
  expected=$1 label=$2 prompt=$3 host=${4:-claude}
  jq -nc --arg p "$prompt" '{prompt:$p, hook_event_name:"UserPromptSubmit"}' \
    | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then ok "prompt ($host): $label"
  else bad "prompt ($host): $label: expected $expected got $status"; fi
}

# Ground truth is the rewritten tool output, not the hook status: the prose
# must survive and a real value in the same output must not.
mask_case() {
  label=$1 text=$2 keep=$3 gone=$4 host=${5:-claude}
  jq -nc --arg t "$text" \
    '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"cat notes"},tool_response:{stdout:$t,stderr:"",interrupted:false}}' \
    | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-post-tool >"$CASE/out" 2>"$CASE/err"
  if [ ! -s "$CASE/out" ]; then
    bad "mask ($host): $label: no rewritten output"
    return
  fi
  if [ -n "$keep" ] && ! grep -Fq -- "$keep" "$CASE/out"; then
    bad "mask ($host): $label: kept text was masked"
    return
  fi
  if grep -Fq -- "$gone" "$CASE/out"; then
    bad "mask ($host): $label: secret survived"
    return
  fi
  ok "mask ($host): $label"
}

[ -s "$FIXTURE" ] || { bad "fixture is missing"; exit 1; }
# The generated values must look like credentials, or the blocking cases
# below prove nothing.
[ "${#hex}" -eq 40 ] || { bad "generated hex value is short"; exit 1; }
[ "${#low}" -eq 28 ] || { bad "generated letter run is short"; exit 1; }

for host in claude codex; do
  prompt_case 0 'reported line: modal sentence after a secret label' "$(cat "$FIXTURE")" "$host"
  prompt_case 0 'must and three words' "${key}: must be rotated monthly" "$host"
  prompt_case 0 'list item, should and four words' "- ${pw}: should not be logged anywhere" "$host"
  prompt_case 0 'will and five words' "token: will be issued by the auth server" "$host"
done
prompt_case 0 'exactly two words after the lead' "${key}: must be rotated"
prompt_case 0 'one final period' "${key}: must be rotated monthly."
prompt_case 0 'trailing spaces after the period' "${key}: must be rotated monthly.  "
prompt_case 0 'passphrase key, accepted residual' "passphrase: must have more coffee"
prompt_case 0 'when as the lead word' "${snake_key}: when the vault is sealed"

# Realistic shapes under the same key, in each form.
prompt_case 2 'quoted random value' "${snake_key}: \"${hex}\""
prompt_case 2 'unquoted random value' "${key}: ${hex} must be rotated"
prompt_case 2 'random value inside the sentence' "${key}: must be ${hex} rotated"
prompt_case 2 'random value as the last word' "${key}: must be rotated ${hex}"
# A long single-case letter run is only credential-shaped when each word is
# judged on its own, so this fails if the tail is only matched as a pattern.
prompt_case 2 'lowercase run inside the sentence' "${key}: must be ${low} rotated"
prompt_case 2 'single word' "${pw}: ${weak}"
prompt_case 2 'single word and a comment' "${pw}: ${weak} # staging"
prompt_case 2 'passphrase' "passphrase: correct horse battery staple"
prompt_case 2 'backticked passphrase' "passphrase: \`correct horse battery staple\`"
# Boundaries of the prose shape: loosening any one of them fails here.
prompt_case 2 'backticked sentence' "${key}: \`must be rotated monthly\`"
prompt_case 2 'double-quoted sentence' "${key}: \"must be rotated monthly\""
prompt_case 2 'single-quoted sentence' "${key}: 'must be rotated monthly'"
prompt_case 2 'env assignment of a sentence' "${snake_key}=must be rotated monthly"
prompt_case 2 'only one word after the lead' "${key}: must rotate"
prompt_case 2 'digit in a following word' "${key}: must be rotated2 monthly"
prompt_case 2 'quoted JSON-style key' "\"${pw}\": must be rotated monthly"
prompt_case 2 'flow mapping' "{${pw}: must be rotated monthly}"
# Only one sentence mark comes off the edge of a word, so a word that ends
# in two keeps a mark and is not a word of letters (#587).
prompt_case 2 'two final periods' "${key}: must be rotated monthly.."
# A sentence needs a marker word (#587 shape 6): a word of two letters or
# fewer is not one, since a passphrase can hold it.
prompt_case 2 'no listed lead word' "${key}: rotated monthly by the team"
# A hyphenated word is not a word of letters, as a passphrase can be one.
prompt_case 2 'symbol in a following word' "${key}: must be rotated-now monthly"
# Three or more words with a marker word read as a sentence (#587 shape 6),
# so these loosened shapes pass too.
prompt_case 0 'capitalized lead word' "${key}: Must be rotated monthly"
prompt_case 0 'uppercase in a following word' "${key}: must be Rotated monthly"
prompt_case 0 'comma before more text' "${key}: must be rotated monthly, then logged"
prompt_case 0 'double space' "${key}: must be  rotated monthly"
prompt_case 0 'tab between words' "${key}: must be	rotated monthly"

for host in claude codex; do
  mask_case 'prose stays, real value is masked' \
    "${key}: must be rotated monthly
api_${word}: ${hex}" "${key}: must be rotated monthly" "${hex}" "$host"
done
# Unquoted, the masker replaces the first token, as it did before this
# exception; what matters is that the line is no longer left as written.
mask_case 'sentence with a random value is masked' \
  "${key}: must be ${hex} rotated" '' "${key}: must be ${hex}"
mask_case 'backticked sentence is masked' \
  "${key}: \`must be ${low} rotated\`" '' "${low}"

printf '%s prose-reference checks, %s failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]

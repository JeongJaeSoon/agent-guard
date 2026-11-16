#!/usr/bin/env sh
set -u

# A prose line can describe a secret by the endpoint that sets it
# (`client secret: `PUT /v1/providers/:id/client-secret``). An HTTP method and
# a path, or a path of two or more segments, after a colon names a route, not
# a credential, so the prompt guard must pass it and the output masker must
# keep it. A random value, a path with a credential-shaped or long numeric
# segment, a query string, a one-segment path, the `=` form and a quoted
# field stay blocked and masked.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE="$ROOT/tests/fixtures/prompt-route-reference.txt"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-route-ref.XXXXXX") || exit 1
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
b64=$(head -c 24 /dev/urandom | base64 | tr -d '+/=\n')
low=$(od -An -N28 -tu1 /dev/urandom \
  | awk '{ for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
word=$(printf '%s%s' sec ret)
key="client ${word}"
snake_key="client_${word}"
env_key=$(printf '%s%s' CLIENT _SECRET)
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

# Ground truth is the rewritten tool output, not the hook status: the route
# must survive and a real value in the same output must not.
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
# The generated values must look like credentials, or the blocking cases
# below prove nothing.
case "$b64" in *[a-z]*[A-Z]*|*[A-Z]*[a-z]*) ;; *) bad "generated value is not mixed case"; exit 1 ;; esac
[ "${#hex}" -eq 40 ] || { bad "generated hex value is short"; exit 1; }
[ "${#low}" -eq 28 ] || { bad "generated letter run is short"; exit 1; }

prompt_case 0 'reported line: method and path after a secret label' "$(cat "$FIXTURE")"
prompt_case 0 'POST and a one-segment path' "${key}: \`POST /users\` creates it"
prompt_case 0 'path with a brace parameter' "${key}: \`PATCH /v2/apps/{app_id}/${word}\` rotates it"
prompt_case 0 'unquoted path of two segments' "${key}: /v1/login-providers/:id/client-${word} sets it"
prompt_case 0 'unquoted PATCH and a path' "${key}: PATCH /v1/providers/:id rotates it"
prompt_case 0 'unquoted DELETE and a path' "${key}: DELETE /v1/providers/:id/client-${word} removes it"
prompt_case 0 'unquoted OPTIONS and a path at line end' "${key}: OPTIONS /v1/providers"
prompt_case 0 'unquoted POST and a path before a comma' "${key}: POST /v1/providers, then GET"
prompt_case 0 'backticked path with a trailing slash' "${key}: \`/api/providers/\` lists them"
prompt_case 0 'redaction placeholder' "${key}: \`[REDACTED]\` must store the new value"

# Realistic random shapes under the same key, in each form.
prompt_case 2 'quoted random value' "${snake_key}: \"${hex}\""
prompt_case 2 'backticked random value' "${key}: \`${b64}\` must store"
prompt_case 2 'unquoted random value' "${key}: ${b64} must store"
prompt_case 2 'random value as a path segment' "${key}: \`PUT /v1/providers/${hex}\`"
prompt_case 2 'mixed-case random path segment' "${key}: /v1/${b64} sets it"
prompt_case 2 'random value as a brace parameter' "${key}: \`PUT /v1/{${hex}}\`"
prompt_case 2 'random value after a colon parameter' "${key}: \`PUT /v1/:${b64}\`"
prompt_case 2 'random value in a query string' "${key}: \`PUT /v1/providers?k=${hex}\`"
prompt_case 2 'word value in a query string' "${key}: \`GET /v1/callback?state=rotation\`"
# A long single-case letter run is only credential-shaped without the
# parameter decoration, so these fail if the decoration is judged as is.
prompt_case 2 'lowercase run as a path segment' "${key}: \`PUT /v1/${low}\`"
prompt_case 2 'lowercase run after a colon parameter' "${key}: \`PUT /v1/:${low}\`"
prompt_case 2 'lowercase run as a brace parameter' "${key}: \`PUT /v1/{${low}}\`"
prompt_case 2 'random value after the method' "${key}: \`PUT ${hex}\`"
prompt_case 2 'unquoted method, random path segment' "${key}: PATCH /v1/providers/${hex} rotates it"
prompt_case 2 'unquoted method, random query value' "${key}: DELETE /v1/providers?k=${b64}"
prompt_case 2 'unquoted method, one word after it' "${key}: PATCH rotation"
prompt_case 2 'unquoted method after a tab' "${key}: PATCH	/v1/providers"
prompt_case 2 'unquoted method word with a closer' "${key}: PATCH) /v1/providers"
# Boundaries of the route shape: loosening any one of them fails here.
prompt_case 2 'one-segment path without a method' "${key}: \`/rotation\` is set"
prompt_case 2 'lowercase method' "${key}: \`put /v1/providers\`"
prompt_case 2 'ten-digit segment' "${key}: \`PUT /v1/4829105736\`"
prompt_case 2 'path in double quotes' "${snake_key}: \"/v1/providers/rotation\""
prompt_case 2 'env assignment of a path' "${env_key}=/v1/providers/rotation"
prompt_case 2 'prose before the path' "${key}: \`use PUT /v1/providers\`"
prompt_case 2 'two methods' "${key}: \`PUT PUT /v1/providers\`"

mask_case 'route stays, real value is masked' \
  "${key}: \`PUT /v1/login-providers/:id/client-${word}\` sets it
api_${word}: ${hex}" '/v1/login-providers/:id/client-' "${hex}"
mask_case 'unquoted method stays, real value is masked' \
  "${key}: OPTIONS /v1/providers/:id lists it
api_${word}: ${hex}" 'OPTIONS /v1/providers/:id' "${hex}"
mask_case 'path with a random segment is masked' \
  "${key}: \`PUT /v1/providers/${hex}\`" '' "${hex}"

printf '%s route-reference checks, %s failed\n' "$((pass + fail))" "$fail"
[ "$fail" -eq 0 ]

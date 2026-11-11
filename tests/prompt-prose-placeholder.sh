#!/usr/bin/env sh
# Synthetic prompts only. A secret-bearing key next to a status word in bold
# markdown, or next to an angle placeholder that ends in a placeholder noun, is
# prose; a random value and an arbitrary phrase stay blocked.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-prose-ph.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_HOOK_HOST=claude
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
# Random per run, so no literal in this file looks like a credential.
rnd=$(od -An -N20 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
failed=0
checked=0
check() {
  expected=$1
  label=$2
  prompt=$3
  checked=$((checked + 1))
  jq -nc --arg p "$prompt" '{prompt:$p}' \
    | "$GUARD" hook-user-prompt > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'ok - prompt prose %s: %s\n' "$checked" "$label"
  else
    printf 'not ok - prompt prose %s: %s: expected %s got %s\n' "$checked" "$label" "$expected" "$status"
    failed=$((failed + 1))
  fi
}

check 0 "bold label with a bold status word" '- **Repo secret**: **cannot verify**'
check 0 "bold status word alone" '- **Deploy token**: **missing**'
check 0 "underscore emphasis" '- api_secret: _unknown_'
check 0 "plain status word" '- Repo secret: present'
check 0 "export of a named placeholder" 'export DEPLOY_PAT=<acme-pat>'
check 0 "named token placeholder" 'export API_TOKEN=<acme-token>'

check 2 "status word glued to random text" "export API_SECRET=missing$rnd"
check 2 "arbitrary phrase in brackets" 'export API_TOKEN=<correct-horse-battery>'
check 2 "bracket phrase ending in another word" 'export API_TOKEN=<acme-pat-extra>'
check 2 "random value" "export API_TOKEN=$rnd"
# A quoted command substitution blocks unless nothing inside can be a literal.
check 2 "echo of a literal in a substitution" "DB_PASSWORD=\"\$(echo Q7$rnd)\""
check 2 "printf of a literal in a substitution" "export API_TOKEN=\"\$(printf %s S3$rnd | base64)\""
check 2 "long argument in a substitution" "password: \"\$(werft login $rnd)\""
check 2 "unlisted argument word in a substitution" 'TOKEN="$(werft token hunterpass)"'
check 2 "word after a credential option in a substitution" 'TOKEN="$(cmd -p hunter)"'
check 0 "command with subcommand words" 'export WERFT_TOKEN="$(werft token create)"'

printf '%s prompt prose checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

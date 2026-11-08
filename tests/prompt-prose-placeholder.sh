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

check 0 "descriptive plural noun after a key in a sentence" 'Think about inputs that carry a secret: values that start with a dollar sign.'
check 0 "descriptive noun in a sentence that has an earlier colon" 'Review the patch itself: think about inputs that carry a secret: values that start with a dollar sign.'
check 0 "descriptive noun after a token key" 'Report each token: keys that were rotated.'

check 2 "descriptive noun with a random suffix" "Think about inputs that carry a secret: values${rnd} that start with a dollar sign."
check 2 "descriptive noun with a digit suffix" 'a secret: values2 that start with a dollar sign'
check 2 "bare descriptive noun as an env assignment value" 'export API_SECRET=values'
check 2 "quoted descriptive noun as an env assignment value" 'export API_SECRET="values"'
check 2 "single-quoted descriptive noun as an assignment value" "export API_SECRET='tokens'"
check 2 "descriptive noun ending the line after two plain words" 'INFO auth password: values'
check 2 "descriptive noun with a Korean particle" 'Think about a secret: values가 start here'
check 2 "descriptive noun with a trailing quote" "Think about a secret: values' that start here"
check 2 "descriptive noun followed by an assignment token" 'Think about a secret: values x=1'
check 2 "descriptive noun followed by a mixed token" 'Think about a secret: values a123'
check 2 "config line with a descriptive noun at line start" 'password: values'
check 2 "indented config line with a descriptive noun" '  password: values'
check 2 "config line with no space after the colon" 'password:values'
check 2 "quoted config key with a descriptive noun" '"password": values'
check 2 "YAML list item with a descriptive noun" '- password: values'
check 2 "flow map with a descriptive noun" '{password: values}'
check 2 "nested config line after another key" 'db: password: values'
check 2 "random value after a key in a sentence" "Think about inputs that carry a secret: ${rnd} in a sentence."
check 2 "descriptive noun does not exempt an env assignment value" "export API_SECRET=values${rnd}"
check 2 "status word glued to random text" "export API_SECRET=missing$rnd"
check 2 "arbitrary phrase in brackets" 'export API_TOKEN=<correct-horse-battery>'
check 2 "bracket phrase ending in another word" 'export API_TOKEN=<acme-pat-extra>'
check 2 "random value" "export API_TOKEN=$rnd"

# Log lines: a real credential equal to a descriptive noun, followed by a plain
# word, is not a sentence. Both the prompt guard and output masking must catch
# it; the same noun inside a descriptive sentence stays allowed.
postcheck() {
  expected=$1
  label=$2
  text=$3
  checked=$((checked + 1))
  jq -nc --arg o "$text" --arg d "$ROOT" \
    '{tool_name:"Bash",tool_input:{command:"cat app.log"},
      tool_response:{stdout:$o,stderr:"",interrupted:false},cwd:$d}' \
    | "$GUARD" hook-post-tool > "$CASE_ROOT/post" 2> "$CASE_ROOT/err"
  if [ -s "$CASE_ROOT/post" ]; then masked=1; else masked=0; fi
  if [ "$masked" -eq "$expected" ]; then
    printf 'ok - output masking %s: %s\n' "$checked" "$label"
  else
    printf 'not ok - output masking %s: %s: expected masked=%s got %s\n' "$checked" "$label" "$expected" "$masked"
    failed=$((failed + 1))
  fi
}
for log_line in \
  'INFO auth password: values accepted' \
  'INFO auth token: tokens issued' \
  '2026-11-08 ok login secret: secrets rotated' \
  'INFO the password: values accepted' \
  'INFO the password: values was rotated' \
  'INFO auth received the password: values was rotated' \
  '2026-11-08 INFO auth rotated a password: values that was accepted' \
  '2026-11-08 12:00:01 INFO auth: the password: values were rotated' \
  'received the password: values was rotated at 123' \
  'received the password: values was rotated user=alice' \
  'received the password: values was rotated INFO' \
  '2026-11-08 INFO auth. the password: values was rotated' \
  '2026-11-08 INFO auth; the password: values was rotated'; do
  check 2 "log line with a descriptive noun value blocks the prompt: $log_line" "$log_line"
  postcheck 1 "log line with a descriptive noun value is masked: $log_line" "$log_line"
done
postcheck 0 "descriptive sentence is not masked" 'Think about inputs that carry a secret: values that start with a dollar sign.'

printf '%s prompt prose checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

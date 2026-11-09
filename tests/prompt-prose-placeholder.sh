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
  '2026-11-08 INFO auth; the password: values was rotated' \
  '2026-11-08 info auth. Received the password: values was rotated' \
  'received the password: values was rotated. INFO user=alice 123' \
  'INFO api_token: true received the password: values was rotated' \
  'info auth. The password: values that start here.' \
  'WARN auth. The password: tokens that were issued.' \
  'Nov 08 12:00:01 auth. The password: values was rotated' \
  'received the password: values was rotated. user=alice' \
  'auth api_token: true received the password: values was rotated' \
  'error: rotation failed. The password: values was rejected' \
  'ALERT auth. The password: passwords was rotated' \
  'user = alice. The password: passwords was rotated' \
  'The PASSWORD: passwords was rotated'; do
  check 2 "log line with a descriptive noun value blocks the prompt: $log_line" "$log_line"
  postcheck 1 "log line with a descriptive noun value is masked: $log_line" "$log_line"
done
for outside_scope in \
  '"account the password": values that start here.' \
  'Think about a password: vAlUeS that start here.' \
  'Think about a password: Values that start here.' \
  '- the password: values that start here.' \
  '  - the password: values that start here.' \
  '* the password: values that start here.' \
  '1. the password: values that start here.' \
  '  2) the password: values that start here.'; do
  check 2 "outside the accepted noun scope blocks the prompt: $outside_scope" "$outside_scope"
  postcheck 1 "outside the accepted noun scope is masked: $outside_scope" "$outside_scope"
done
# Generated controls: the exemption applies to a line only when it starts with
# a letter, or with a numbered-list marker followed by a capitalised word. Every
# other line-start marker, in any indentation, keeps the block and the mask.
tab=$(printf '\t')
printf '%s\n' '-' '*' '+' '#' '##' '>' '|' '1.' '1)' '"' '`' \
  "${tab}-" '  -' '    -' '  #' '  >' ' |' "${tab}1." '  1)' \
  '"note.' '`note.' '- note.' '# note.' '> note.' > "$CASE_ROOT/prefixes"
printf '%s\n' \
  'the password: values that start here.' \
  'a secret: values that start here.' \
  'each token: keys that were rotated.' > "$CASE_ROOT/keys"
while IFS= read -r prefix; do
  while IFS= read -r key; do
    check 2 "marker line blocks the prompt: $prefix $key" "$prefix $key"
    postcheck 1 "marker line is masked: $prefix $key" "$prefix $key"
  done < "$CASE_ROOT/keys"
done < "$CASE_ROOT/prefixes"
check 2 "numbered item with a lower-case word blocks the prompt" '1) the password: values that start here.'
postcheck 1 "numbered item with a lower-case word is masked" '1) the password: values that start here.'
check 0 "numbered item with a capitalised sentence" '2. Review the patch itself: think about inputs that carry a secret: values that start with a dollar sign.'
postcheck 0 "numbered item with a capitalised sentence is not masked" '2. Review the patch itself: think about inputs that carry a secret: values that start with a dollar sign.'
# Generated controls: text after an unterminated quote is scanned again, and the
# exemption must not apply there, whatever opens the original line.
for rescan_prefix in '-' '1.' '#' '>' '|'; do
  for rescan_noun in value values secrets tokens keys passwords credentials; do
    rescan_line="$rescan_prefix error: password: 'The password: $rescan_noun that start here."
    check 2 "quoted rescan blocks the prompt: $rescan_line" "$rescan_line"
    postcheck 1 "quoted rescan is masked: $rescan_line" "$rescan_line"
  done
done
# Known limits, pending the owner's decision: a log line that carries none of
# the line-wide log shapes reads as prose. Pinned so a change to them is seen.
for known_limit in \
  'auth service: the password: values was rotated' \
  'user alice reset the password: values that were issued' \
  'auth 42 failed. The password: values was rotated'; do
  check 0 "known limit passes the prompt: $known_limit" "$known_limit"
  postcheck 0 "known limit is not masked: $known_limit" "$known_limit"
done
# Known limit (owner decision, 2026-11-08, r12): a numbered item that is a
# capitalised sentence passes.
check 0 "accepted residual: numbered capitalised sentence" '2. The password: values that start here.'
# The reported prompt line: a commit sha and an acronym on the same line must
# not withdraw the exemption.
fp_line='2. Review the PR patch itself: `git diff 85a38d451dfba6401722e46de9e1582156408e7a cb05ea165927abe817832bf21b34a88485e06421` (merge-base to old head) — is the change correct and minimal? Think about inputs that look like `$name` but carry a secret: values that start with `$` yet are literal secrets, `$name` glued to other characters.'
check 0 "reported review prompt line" "$fp_line"
postcheck 0 "reported review prompt line is not masked" "$fp_line"
postcheck 0 "descriptive sentence is not masked" 'Think about inputs that carry a secret: values that start with a dollar sign.'

printf '%s prompt prose checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

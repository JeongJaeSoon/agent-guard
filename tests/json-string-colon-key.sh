#!/usr/bin/env sh
# Synthetic text only (#657). A colon key at the very start of a JSON string
# value is read as an assignment, as the same member is with a space after
# its colon. Each row goes through Claude Bash PostToolUse, and the verdict is
# what the model would see: a masked row no longer holds its values and is
# otherwise the row, a kept row comes back unchanged. The prompt guard reads
# the same shape.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-json-colon.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" || exit 1
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings" AGENT_GUARD_HOOK_HOST=claude
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
unset AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_KEY_NAME_REDACT AI_AGENT

# Assembled at run time so no literal here looks like a credential; each row
# draws its own values, since the guard masks every copy of a value it finds.
draw() { printf 'q7%s' "$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"; }
weak=$(printf '%s%s' hunter 2)
kw=pass$(printf word)
lab=Pass$(printf word)
tk=tok$(printf en)
ak=api_$(printf key)
nl='
'
failed=0
checked=0
result() {
  checked=$((checked + 1))
  if [ "$1" -eq 0 ]; then
    printf 'ok - json string colon key %s: %s\n' "$checked" "$2"
  else
    printf 'not ok - json string colon key %s: %s\n' "$checked" "$2"
    failed=$((failed + 1))
  fi
}
# seen TEXT: what the model would see for TEXT as Bash output, in $CASE/got.
seen() {
  printf '%s' "$1" >"$CASE/in"
  jq -nc --rawfile t "$CASE/in" \
    '{session_id:"json-colon",hook_event_name:"PostToolUse",tool_name:"Bash",
      tool_input:{command:"jq -c . events.json"},
      tool_response:{stdout:$t,stderr:"",interrupted:false}}' >"$CASE/event" || return 1
  "$GUARD" hook-post-tool <"$CASE/event" >"$CASE/out" 2>"$CASE/err" || return 1
  if [ -s "$CASE/out" ]; then
    jq -j '.hookSpecificOutput.updatedToolOutput.stdout | strings' <"$CASE/out" >"$CASE/got"
  else
    cp "$CASE/in" "$CASE/got"
  fi
}
# masked LABEL TEMPLATE VALUE...: the row is TEMPLATE with %1 and %2 replaced
# by the values, and must come back with each of them replaced by the mask.
masked() {
  label=$1 template=$2 a=$3 b=${4-}
  text=$(printf '%s' "$template" | sed "s|%1|$a|g; s|%2|$b|g")
  want=$(printf '%s' "$template" | sed 's|%[12]|[REDACTED]|g')
  if seen "$text" && [ "$(cat "$CASE/got")" = "$want" ]; then result 0 "$label"
  else result 1 "$label: the row did not come back with only its values masked"; fi
}
kept() {
  label=$1 text=$2
  if seen "$text" && cmp -s "$CASE/in" "$CASE/got"; then result 0 "$label"
  else result 1 "$label: the row changed"; fi
}
prompt() {
  expected=$1 label=$2
  jq -nc --arg p "$3" '{session_id:"json-colon",hook_event_name:"UserPromptSubmit",prompt:$p}' \
    | AGENT_GUARD_PROMPT_GUARD_MODE=block "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then result 0 "$label"
  else result 1 "$label: expected $expected got $status"; fi
}

# The key opens the string value of a one-line JSON member.
masked "a key that opens a member value" "{\"text\":\"$kw: %1\"}" "$(draw)"
masked "a key that opens a member value, after other members" \
  "{\"path\":\"config/app.yml\",\"line\":2,\"text\":\"$kw: %1\"}" "$(draw)"
masked "a short human value" "{\"level\":\"info\",\"msg\":\"$kw: %1\"}" "$weak"
masked "a dotted key" "{\"text\":\"spring.datasource.$kw: %1\"}" "$(draw)"
masked "no space after the delimiter" "{\"text\":\"$kw:%1\"}" "$(draw)"
masked "a single-quoted value in the string" "{\"text\":\"$kw: '%1'\"}" "$(draw)"
masked "a member name without quotes" "{text:\"$kw: %1\"}" "$(draw)"
masked "a value in escaped quotes" "{\"text\":\"$kw: \\\"%1\\\"\"}" "$(draw)"
masked "a value in escaped quotes behind a line locator" \
  "3:{\"text\":\"$kw: \\\"%1\\\"\"}" "$(draw)"
# The members around it are still read: the leftmost key goes first.
masked "a secret member after the string" "{\"text\":\"$kw: %1\",\"$tk\":\"%2\"}" "$(draw)" "$(draw)"
masked "a secret member before the string" "{\"$tk\":\"%2\",\"text\":\"$kw: %1\"}" "$(draw)" "$(draw)"
masked "two such members on one line" "{\"a\":\"$kw: %1\",\"b\":\"$ak: %2\"}" "$(draw)" "$(draw)"
# Controls: the shapes main already read.
masked "control: a space after the member colon" "{\"text\": \"$kw: %1\"}" "$(draw)"
masked "control: an equals key in the same place (#178)" "{\"text\":\"$kw=%1\"}" "$(draw)"

# Just outside: not a secret name, an empty value, and text that is no value.
kept "a key that is not a secret name" "{\"text\":\"color: $(draw)\"}"
kept "a label whose string closes after the delimiter" \
  "{\"label\":\"$lab:\"}$nl""status ready \"done\""
kept "a label, a space, then the closing quote" \
  "{\"prompt\":\"$lab: \"}$nl{\"text\":\"done\"}"
kept "a label behind a line locator" \
  "3:{\"label\":\"$lab:\"}$nl""4:{\"text\":\"done\"}"
kept "a label next to an escaped quote" \
  "{\"label\":\"$lab:\",\"note\":\"say \\\"hi\\\" twice\"}$nl{\"text\":\"done\"}"
kept "an empty value in escaped quotes" "{\"text\":\"$kw: \\\"\\\"\"}"
kept "an angle placeholder" "{\"text\":\"$kw: <your-$kw>\"}"
kept "a shell reference" "{\"text\":\"$kw: \${DB_SECRET}\"}"
kept "a key after a colon without the quote" "{\"url\":\"https://example.com/a:$kw: $(draw)\"}"

prompt 2 "the prompt guard blocks a key that opens a member value" "{\"text\":\"$kw: $(draw)\"}"
prompt 0 "the prompt guard passes a label whose string closes after the delimiter" \
  "Here is the form: {\"label\":\"$lab:\"}"
prompt 0 "the prompt guard passes a key that is not a secret name" "{\"text\":\"color: $(draw)\"}"

printf '%s json string colon key checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

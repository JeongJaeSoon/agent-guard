#!/usr/bin/env sh
# Synthetic text only (94S-1888). A credential-named field whose value is an
# identifier that repeats the field name is source code, so output masking
# leaves it and the prompt guard passes it. Every such `pass` line sits next
# to a `mask` line that must stay masked, and the config-shaped literals in
# `still_masked` stay masked whatever their entropy. Each case runs on both
# hosts: Claude PostToolUse rewrites updatedToolOutput, Codex PostToolUse
# blocks and returns the same sanitized text in additionalContext, and
# UserPromptSubmit decides the same text the same way on both.
# AGENT_GUARD_KEY_NAME_REDACT=on restores masking by key name alone.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=$ROOT/tests/fixtures/key-name-masking.json
DIFF_FIXTURE=$ROOT/tests/fixtures/key-name-masking-diff.txt
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-key-name.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
mkdir "$CASE_ROOT/home"
export HOME="$CASE_ROOT/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_PROMPT_GUARD_MODE=block
export AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE_ROOT/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
unset AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_KEY_NAME_REDACT AI_AGENT
# Assembled at run time so the repository's own scan finds no
# credential-shaped literal here. Nothing below prints these values.
rnd=$(od -An -N12 -tu1 /dev/urandom | awk '{ printf "q7"; for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
hex=$(od -An -N20 -tx1 /dev/urandom | tr -d ' \n')
vendor=$(printf '%s_%s' ghp "$(od -An -N36 -tu1 /dev/urandom \
  | awk '{ for (i = 1; i <= NF; i++) printf "%c", ($i % 36 < 10 ? 48 + $i % 36 : 87 + $i % 36) }' | tr -d '\n')")
weak=$(printf '%s%s' hunter 2)
marker=$(printf '%s_%s_%s_%s' AGENT GUARD TEST SECRET)
failed=0
checked=0
ok() { checked=$((checked + 1)); printf 'ok - key name %s: %s\n' "$checked" "$1"; }
fail() {
  checked=$((checked + 1))
  failed=$((failed + 1))
  printf 'not ok - key name %s: %s\n' "$checked" "$1"
}
[ "${#rnd}" -eq 14 ] && [ "${#hex}" -eq 40 ] && [ "${#vendor}" -eq 40 ] \
  || { fail "generated values have the wrong length"; exit 1; }

# $1 host, $2 label, $3 text, $4 expected stdout (empty: left untouched).
post_case() {
  jq -nc --arg t "$3" \
    '{session_id:"key-name",hook_event_name:"PostToolUse",tool_name:"Bash",
      tool_input:{command:"git diff"},
      tool_response:{stdout:$t,stderr:"",interrupted:false}}' \
    | AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-post-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "$1 post-tool $2: exit $status"
  elif [ -z "$4" ]; then
    if [ -s "$CASE_ROOT/out" ]; then fail "$1 post-tool $2: expected the output untouched"
    else ok "$1 post-tool $2 is left untouched"; fi
  else
    if [ "$1" = claude ]; then
      jq -e --arg m "$4" '.hookSpecificOutput.updatedToolOutput.stdout == $m' \
        "$CASE_ROOT/out" >/dev/null 2>&1
    else
      jq -e --arg m "$4" \
        '.decision == "block"
         and ((.hookSpecificOutput.additionalContext
               | sub("^Agent Guard sanitized tool output:\n"; "")
               | fromjson | .stdout) == $m)' \
        "$CASE_ROOT/out" >/dev/null 2>&1
    fi
    if [ $? -eq 0 ]; then ok "$1 post-tool $2 is masked"
    else fail "$1 post-tool $2: masked text differs"; fi
  fi
}
# $1 host, $2 label, $3 text, $4 expected exit status.
prompt_case() {
  jq -nc --arg p "$3" '{session_id:"key-name",hook_event_name:"UserPromptSubmit",prompt:$p}' \
    | AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-user-prompt >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$4" ]; then ok "$1 prompt $2 exits $4"
  else fail "$1 prompt $2: expected $4 got $status"; fi
}
fill() {
  jq -r --arg r "$rnd" --arg h "$hex" --arg v "$vendor" --arg w "$weak" --arg g "$marker" \
    "$1"' | gsub("%R%"; $r) | gsub("%H%"; $h) | gsub("%V%"; $v)
        | gsub("%W%"; $w) | gsub("%G%"; $g)' "$FIXTURE"
}

# Every must-pass line has a must-still-mask line beside it.
if jq -e '(.pairs | length) > 0 and all(.pairs[];
            (.pass | type) == "string" and (.mask | type) == "string"
            and (.masked | type) == "string" and (.legacy | type) == "string"
            and .pass != .mask and .mask != .masked and .pass != .legacy)
          and (.still_masked | length) > 0' "$FIXTURE" >/dev/null; then
  ok "every pass line is paired with a line that stays masked"
else
  fail "fixture pairs are incomplete"
  exit 1
fi

count=$(jq '.pairs | length' "$FIXTURE") || exit 1
i=0
while [ "$i" -lt "$count" ]; do
  label=$(jq -r ".pairs[$i].label" "$FIXTURE")
  pass=$(fill ".pairs[$i].pass")
  legacy=$(fill ".pairs[$i].legacy")
  mask=$(fill ".pairs[$i].mask")
  masked=$(fill ".pairs[$i].masked")
  for host in claude codex; do
    post_case "$host" "$label (pass)" "$pass" ""
    prompt_case "$host" "$label (pass)" "$pass" 0
    post_case "$host" "$label (mask)" "$mask" "$masked"
    prompt_case "$host" "$label (mask)" "$mask" 2
    # The opt-in setting masks by key name alone again, and adds nothing to
    # a line that was already masked.
    AGENT_GUARD_KEY_NAME_REDACT=on
    export AGENT_GUARD_KEY_NAME_REDACT
    post_case "$host" "$label (pass, key-name masking on)" "$pass" "$legacy"
    prompt_case "$host" "$label (pass, key-name masking on)" "$pass" 2
    post_case "$host" "$label (mask, key-name masking on)" "$mask" "$masked"
    unset AGENT_GUARD_KEY_NAME_REDACT
  done
  i=$((i + 1))
done

count=$(jq '.still_masked | length' "$FIXTURE") || exit 1
i=0
while [ "$i" -lt "$count" ]; do
  label=$(jq -r ".still_masked[$i].label" "$FIXTURE")
  text=$(fill ".still_masked[$i].stdout")
  masked=$(fill ".still_masked[$i].masked")
  for host in claude codex; do
    post_case "$host" "$label" "$text" "$masked"
    prompt_case "$host" "$label" "$text" 2
  done
  i=$((i + 1))
done

# The reported shape: a diff of schema code whose field is named credential.
# The whole diff stays readable; one literal added to it is still masked and
# the field lines around it are not.
[ -s "$DIFF_FIXTURE" ] || { fail "diff fixture is missing"; exit 1; }
diff_text=$(cat "$DIFF_FIXTURE")
leak_line="+  credential: \"$rnd\","
# A context line: the detector does not read a key glued to a diff `+`.
env_line=" PASSWORD=$weak"
for host in claude codex; do
  post_case "$host" "schema diff" "$diff_text" ""
  prompt_case "$host" "schema diff" "$diff_text" 0
  post_case "$host" "schema diff with a literal" \
    "$diff_text
$leak_line
$env_line" \
    "$diff_text
+  credential: \"[REDACTED]\",
 PASSWORD=[REDACTED]"
  prompt_case "$host" "schema diff with a literal" "$diff_text
$leak_line" 2
done
# Only an unset, empty or exact `off` value keeps the default; a typo selects
# the stricter masking instead of silently keeping the looser one.
for value in '' off; do
  AGENT_GUARD_KEY_NAME_REDACT=$value
  export AGENT_GUARD_KEY_NAME_REDACT
  post_case claude "schema diff (setting '$value')" "$diff_text" ""
done
for value in on ON true 1 onn; do
  AGENT_GUARD_KEY_NAME_REDACT=$value
  export AGENT_GUARD_KEY_NAME_REDACT
  prompt_case claude "schema diff (setting '$value')" "$diff_text" 2
done
unset AGENT_GUARD_KEY_NAME_REDACT

# `agent-guard exec` masks plaintext through the same detector.
printf '%s\n' "$diff_text" >"$CASE_ROOT/exec-in"
if [ "$("$GUARD" exec -- cat "$CASE_ROOT/exec-in" 2>/dev/null)" = "$diff_text" ]; then
  ok "exec leaves the schema diff untouched"
else
  fail "exec changed the schema diff"
fi
printf '%s\n%s\n' "$diff_text" "$env_line" >"$CASE_ROOT/exec-in"
if "$GUARD" exec -- cat "$CASE_ROOT/exec-in" 2>/dev/null | grep -Fq -- "$weak"; then
  fail "exec left the password literal visible"
else
  ok "exec masks the password literal next to the schema diff"
fi

# Record level, production detector only: mawk, gawk and busybox awk must
# give the same records for every fixture line, in both settings. The
# detector calls `awk` from PATH, so each variant is pinned through a shim.
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE_ROOT" \
  secretish_env_values frame_plaintext_leaf || exit 1
{
  fill '.pairs[] | .pass, .mask'
  fill '.still_masked[].stdout'
  cat "$DIFF_FIXTURE"
  printf '  credential: Credential,\r\n'
} >"$CASE_ROOT/lines"
records() (
  PATH="$1:$PATH"
  . "$CASE_ROOT/secretish_env_values.sh"
  . "$CASE_ROOT/frame_plaintext_leaf.sh"
  for mode in json framed probe; do
    for setting in off on; do
      AGENT_GUARD_KEY_NAME_REDACT=$setting
      export AGENT_GUARD_KEY_NAME_REDACT
      while IFS= read -r line; do
        printf '%s %s ' "$mode" "$setting"
        printf '%s' "$line" | frame_plaintext_leaf \
          | secretish_env_values "$mode" 2>&1 | tr '\036\n' '  '
        printf '\n'
      done <"$CASE_ROOT/lines"
    done
  done
)
mkdir "$CASE_ROOT/default-bin"
records "$CASE_ROOT/default-bin" >"$CASE_ROOT/records-default"
if [ -s "$CASE_ROOT/records-default" ] \
   && grep -q '^json off $' "$CASE_ROOT/records-default" \
   && grep -q '^json on .' "$CASE_ROOT/records-default"; then
  ok "detector records differ between the two settings"
else
  fail "detector records are empty or the setting changes nothing"
fi
compared=0
for variant in mawk gawk 'busybox awk'; do
  command -v "${variant%% *}" >/dev/null 2>&1 || continue
  mkdir "$CASE_ROOT/awk-bin"
  printf '#!/bin/sh\nexec %s "$@"\n' "$variant" >"$CASE_ROOT/awk-bin/awk"
  chmod +x "$CASE_ROOT/awk-bin/awk"
  records "$CASE_ROOT/awk-bin" >"$CASE_ROOT/records-variant"
  rm -rf "$CASE_ROOT/awk-bin"
  compared=$((compared + 1))
  if cmp -s "$CASE_ROOT/records-default" "$CASE_ROOT/records-variant"; then
    ok "$variant gives the same records as the default awk"
  else
    fail "$variant gives different records from the default awk"
  fi
done
# Report which variants ran; the legacy-tools workflow requires all three.
printf '# awk variants compared: %s\n' "$compared"
if [ "${AGENT_GUARD_TEST_REQUIRE_AWK_VARIANTS:-0}" = 1 ] && [ "$compared" -ne 3 ]; then
  fail "expected mawk, gawk and busybox awk, compared $compared"
fi

printf '1..%s\n' "$checked"
[ "$failed" -eq 0 ]

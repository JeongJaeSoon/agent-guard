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
# `tr` under LC_ALL=C reads the random bytes one at a time on GNU, BSD and
# busybox alike. Its input is a fixed 8 KiB, so the pipeline ends even where
# SIGPIPE is ignored: reading /dev/urandom directly left `tr` running on the
# macOS runner after `head` had what it needed, and the job hit its limit.
# 8 KiB gives several hundred characters of the narrowest set; the length
# check below reports each length if a value comes up short.
draw() { head -c 8192 /dev/urandom | LC_ALL=C tr -dc "$1" 2>/dev/null | head -c "$2"; }
rnd=q7$(draw a-z 12)
hex=$(draw a-f0-9 40)
vendor=$(printf '%s_%s' ghp "$(draw a-z0-9 36)")
weak=$(printf '%s%s' hunter 2)
long=my$(printf '%s%s' Pass word)$(draw a-z 80)
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
  && [ "${#long}" -eq 90 ] \
  || { fail "generated values have the wrong length: ${#rnd} ${#hex} ${#vendor} ${#long}"; exit 1; }

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
    --arg l "$long" \
    "$1"' | gsub("%R%"; $r) | gsub("%H%"; $h) | gsub("%V%"; $v)
        | gsub("%W%"; $w) | gsub("%G%"; $g) | gsub("%L%"; $l)' "$FIXTURE"
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

# The suite has two halves. `hooks` drives the real hook entry points on both
# hosts; `records` compares the detector records across awk implementations.
# AGENT_GUARD_TEST_KEY_NAME_PART picks one half so that a CI job with a short
# limit can run each half on its own runner. Unset or empty runs both, as
# tests/run.sh does. Any other value fails: a typo must not run nothing and
# pass. Both halves run the fixture pairing check above.
part=${AGENT_GUARD_TEST_KEY_NAME_PART:-all}
case $part in
  all|hooks|records) ;;
  *) fail "AGENT_GUARD_TEST_KEY_NAME_PART must be hooks or records, got: $part"; exit 1 ;;
esac

if [ "$part" != records ]; then
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

# A field far into its line is in mid-line, so the exemption stops at 1024
# bytes of text before the value. The limit also bounds the work: without it
# the line-start pattern tried every start position of a long line, and one
# 260 KB line kept the hook busy for minutes instead of well under a second.
near=$(printf '%1000s' '')
far=$(printf '%1100s' '')
for host in claude codex; do
  post_case "$host" "field 1,000 bytes into its line" "${near}credential: CredentialSchema," ""
  post_case "$host" "field 1,100 bytes into its line" \
    "${far}credential: CredentialSchema," "${far}credential: [REDACTED],"
done
# The line goes through files: one argument cannot hold 260 KB.
head -c 260000 /dev/zero | LC_ALL=C tr '\0' a >"$CASE_ROOT/long-line"
[ "$(wc -c <"$CASE_ROOT/long-line" | tr -d ' ')" -eq 260000 ] \
  || { fail "long line has the wrong length"; exit 1; }
{ cat "$CASE_ROOT/long-line"; printf ' API_KEY=%s' "$rnd"; } >"$CASE_ROOT/long-in"
{ cat "$CASE_ROOT/long-line"; printf ' API_KEY=[REDACTED]'; } >"$CASE_ROOT/long-want"
jq -nc --rawfile t "$CASE_ROOT/long-in" \
  '{session_id:"key-name",hook_event_name:"PostToolUse",tool_name:"Bash",
    tool_input:{command:"cat bundle.min.js"},
    tool_response:{stdout:$t,stderr:"",interrupted:false}}' >"$CASE_ROOT/long-event"
long_start=$(date +%s)
long_ok=1
for host in claude codex; do
  AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-post-tool \
    <"$CASE_ROOT/long-event" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  if [ "$host" = claude ]; then
    jq -e --rawfile m "$CASE_ROOT/long-want" \
      '.hookSpecificOutput.updatedToolOutput.stdout == $m' "$CASE_ROOT/out" >/dev/null 2>&1
  else
    jq -e --rawfile m "$CASE_ROOT/long-want" \
      '.decision == "block"
       and ((.hookSpecificOutput.additionalContext
             | sub("^Agent Guard sanitized tool output:\n"; "")
             | fromjson | .stdout) == $m)' "$CASE_ROOT/out" >/dev/null 2>&1
  fi
  if [ $? -eq 0 ] && [ "$status" -eq 0 ]; then
    ok "$host post-tool assignment at the end of a 260 KB line is masked"
  else
    long_ok=0
    fail "$host post-tool assignment at the end of a 260 KB line: exit $status or masked text differs"
  fi
done
# The prompt guard reads the same line through the same detector.
jq -nc --rawfile p "$CASE_ROOT/long-in" \
  '{session_id:"key-name",hook_event_name:"UserPromptSubmit",prompt:$p}' >"$CASE_ROOT/long-prompt"
AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-user-prompt \
  <"$CASE_ROOT/long-prompt" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ]; then
  ok "claude prompt assignment at the end of a 260 KB line exits 2"
else
  long_ok=0
  fail "claude prompt assignment at the end of a 260 KB line: expected 2 got $status"
fi
long_elapsed=$(( $(date +%s) - long_start ))
if [ "$long_ok" -eq 1 ] && [ "$long_elapsed" -le 30 ]; then
  ok "a 260 KB line is handled by both hooks within 30 seconds (${long_elapsed}s)"
else
  fail "a 260 KB line took ${long_elapsed}s over three hook runs (at most 30 expected) or was not handled"
fi

# Many lines that each stay under the limit. The line-start test runs on
# every one of them, so it has to be linear in the line: as two patterns it
# was quadratic under mawk, and 310 such lines took ten seconds a hook, the
# length of the prompt hook's whole budget. The control has the same lines
# with the value past the limit, where the test does not run at all. Both
# are timed the same way, so the comparison does not depend on the runner.
awk -v v="$rnd" 'BEGIN {
  under = sprintf("%1014s", ""); gsub(/ /, "a", under)
  over = sprintf("%1100s", ""); gsub(/ /, "a", over)
  for (i = 0; i < 280; i++) {
    printf "%s API_KEY=%s\n", under, v > ARGV[1]
    printf "%s API_KEY=%s\n", over, v > ARGV[2]
  }
}' "$CASE_ROOT/under-in" "$CASE_ROOT/over-in"
many_seconds() {
  jq -nc --rawfile t "$1" \
    '{session_id:"key-name",hook_event_name:"PostToolUse",tool_name:"Bash",
      tool_input:{command:"cat dump.txt"},
      tool_response:{stdout:$t,stderr:"",interrupted:false}}' >"$CASE_ROOT/many-event"
  jq -nc --rawfile p "$1" \
    '{session_id:"key-name",hook_event_name:"UserPromptSubmit",prompt:$p}' >"$CASE_ROOT/many-prompt"
  many_start=$(date +%s)
  many_ok=1
  for many_round in 1 2; do
    AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-post-tool \
      <"$CASE_ROOT/many-event" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || many_ok=0
    jq -e --arg r "$rnd" \
      '.hookSpecificOutput.updatedToolOutput.stdout | contains($r) | not' \
      "$CASE_ROOT/out" >/dev/null 2>&1 || many_ok=0
    AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-user-prompt \
      <"$CASE_ROOT/many-prompt" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
    [ $? -eq 2 ] || many_ok=0
  done
  many_elapsed=$(( $(date +%s) - many_start ))
}
many_seconds "$CASE_ROOT/over-in"
control_ok=$many_ok
control_elapsed=$many_elapsed
many_seconds "$CASE_ROOT/under-in"
if [ "$control_ok" -eq 1 ] && [ "$many_ok" -eq 1 ]; then
  ok "280 long lines are masked and blocked on both sides of the limit"
else
  fail "280 long lines: a value stayed visible or a prompt passed (control $control_ok, under the limit $many_ok)"
fi
if [ "$many_elapsed" -le $(( control_elapsed * 3 + 5 )) ]; then
  ok "280 lines under the limit cost about what the control costs (${many_elapsed}s against ${control_elapsed}s)"
else
  fail "280 lines under the limit took ${many_elapsed}s against ${control_elapsed}s for the control"
fi
fi # end of the hooks half

if [ "$part" != hooks ]; then
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
fi # end of the records half

printf '1..%s\n' "$checked"
[ "$failed" -eq 0 ]

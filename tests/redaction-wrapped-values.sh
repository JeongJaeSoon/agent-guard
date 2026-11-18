#!/usr/bin/env sh
# Synthetic tool output only (#508). A value wrapped in brackets masks whole,
# a spaced `<...>` placeholder is judged as one value, and a real value in
# angle brackets masks every word. Each case runs on both hosts: Claude
# PostToolUse rewrites updatedToolOutput, Codex PostToolUse blocks and returns
# the same sanitized text in additionalContext, and UserPromptSubmit decides
# the same text the same way on both.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE=$ROOT/tests/fixtures/redaction-wrapped-values.json
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-wrapped.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
# Random per run: a letter, then letters and digits with a digit next to a
# letter, so the value is credential-shaped without being a fixed literal.
rnd=$(od -An -N12 -tu1 /dev/urandom | awk '{ printf "q7"; for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
failed=0
checked=0
fail() {
  printf 'not ok - wrapped value %s: %s\n' "$checked" "$1"
  sed 's/^/  out: /' "$CASE_ROOT/out"
  failed=$((failed + 1))
}
count=$(jq '.cases | length' "$FIXTURE") || exit 1
i=0
while [ "$i" -lt "$count" ]; do
  jq -c --argjson i "$i" --arg r "$rnd" \
    '.cases[$i] | .stdout |= gsub("%R%"; $r)
     | .masked |= (if . == null then null else gsub("%R%"; $r) end)' \
    "$FIXTURE" >"$CASE_ROOT/case" || exit 1
  label=$(jq -r .label "$CASE_ROOT/case")
  for host in claude codex; do
    checked=$((checked + 1))
    jq -c '{session_id:"wrapped",hook_event_name:"PostToolUse",tool_name:"Bash",
            tool_input:{command:"cat notes.txt"},
            tool_response:{stdout:.stdout,stderr:"",interrupted:false}}' \
      "$CASE_ROOT/case" \
      | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-post-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
    status=$?
    if [ "$status" -ne 0 ]; then
      fail "$host post-tool $label: exit $status"
    elif jq -e '.masked == null' "$CASE_ROOT/case" >/dev/null; then
      if [ -s "$CASE_ROOT/out" ]; then
        fail "$host post-tool $label: expected the output untouched"
      else
        printf 'ok - wrapped value %s: %s post-tool %s\n' "$checked" "$host" "$label"
      fi
    else
      if [ "$host" = claude ]; then
        jq -e --slurpfile c "$CASE_ROOT/case" \
          '.hookSpecificOutput.updatedToolOutput.stdout == $c[0].masked' \
          "$CASE_ROOT/out" >/dev/null 2>&1
      else
        jq -e --slurpfile c "$CASE_ROOT/case" \
          '.decision == "block"
           and ((.hookSpecificOutput.additionalContext
                 | sub("^Agent Guard sanitized tool output:\n"; "")
                 | fromjson | .stdout) == $c[0].masked)' \
          "$CASE_ROOT/out" >/dev/null 2>&1
      fi
      if [ $? -eq 0 ]; then
        printf 'ok - wrapped value %s: %s post-tool %s\n' "$checked" "$host" "$label"
      else
        fail "$host post-tool $label: expected $(jq -c .masked "$CASE_ROOT/case")"
      fi
    fi
    checked=$((checked + 1))
    expected=$(jq -r .prompt "$CASE_ROOT/case")
    jq -c '{session_id:"wrapped",hook_event_name:"UserPromptSubmit",prompt:.stdout}' \
      "$CASE_ROOT/case" \
      | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-user-prompt >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
    status=$?
    if [ "$status" -eq "$expected" ]; then
      printf 'ok - wrapped value %s: %s prompt %s\n' "$checked" "$host" "$label"
    else
      fail "$host prompt $label: expected $expected got $status"
    fi
  done
  i=$((i + 1))
done
# Record level, production detector only. A wider extent never goes out as an
# ordinary literal: JSON records flag it for bundle settlement, and framed
# records (the exec raw path, which applies the bundle literals afterwards)
# carry none, so that path masks exactly as before.
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE_ROOT" \
  secretish_env_values frame_plaintext_leaf || exit 1
. "$CASE_ROOT/secretish_env_values.sh"
. "$CASE_ROOT/frame_plaintext_leaf.sh"
records() {
  mode=$1
  shift
  printf '%s\n' "$@" | frame_plaintext_leaf \
    | secretish_env_values "$mode" 2>/dev/null \
    | tr '\036' '\n' | LC_ALL=C sort
}
record_check() {
  checked=$((checked + 1))
  if [ "$2" = "$3" ]; then
    printf 'ok - wrapped value %s: records %s\n' "$checked" "$1"
  else
    printf 'not ok - wrapped value %s: records %s\n' "$checked" "$1"
    printf '  expected: %s\n  actual: %s\n' "$2" "$3"
    failed=$((failed + 1))
  fi
}
record_check "json flags the bracket extent" \
  "$(printf '"[%s"\n{"literal":"[%s]","replacement":"[REDACTED]","agent_guard_extent":true}' "$rnd" "$rnd" | LC_ALL=C sort)" \
  "$(records json "token: [$rnd]")"
record_check "json flags the angle extent" \
  "$(printf '"<hunter2"\n{"literal":"<hunter2 Summer>","replacement":"[REDACTED]","agent_guard_extent":true}' | LC_ALL=C sort)" \
  "$(records json "API_KEY=<hunter2 Summer>")"
record_check "json gives a spaced placeholder no record" "" \
  "$(records json "API_KEY=<your key>")"
record_check "framed carries no extent" "S<hunter2" \
  "$(records framed "API_KEY=<hunter2 Summer>" | grep .)"
record_check "probe answers once for an extent" "x" \
  "$(records probe "token: [$rnd]")"

# `agent-guard exec` masks plaintext through the same bundle, ordered by
# bytes rather than characters; settlement must hold for that order too.
exec_check() {
  checked=$((checked + 1))
  printf '%s\n' "$2" >"$CASE_ROOT/exec-in"
  actual=$("$GUARD" exec -- cat "$CASE_ROOT/exec-in" 2>/dev/null)
  if [ "$actual" = "$3" ]; then
    printf 'ok - wrapped value %s: exec %s\n' "$checked" "$1"
  else
    printf 'not ok - wrapped value %s: exec %s\n  expected: %s\n  actual: %s\n' \
      "$checked" "$1" "$3" "$actual"
    failed=$((failed + 1))
  fi
}
exec_check "bracketed status word" 'Token: [hidden]' 'Token: [REDACTED]'
exec_check "two words in angle brackets" 'API_KEY=<hunter2 Summer>' 'API_KEY=[REDACTED]'
exec_check "spaced placeholder" 'API_KEY=<your key>' 'API_KEY=<your key>'
# The password literal has more characters but fewer bytes than the extent.
wide=$(printf '\303\204\303\204\303\204\303\204\303\204\303\204\303\204\303\204')
exec_check "shorter secret in byte order keeps the masking of main" \
  "password=\") q7abcdefgh\"
token=($wide) q7abcdefgh" \
  'password="[REDACTED]"
token=[REDACTED][REDACTED]'

# Settlement is linear in the bundle: a long bracketed value next to another
# secret masks well inside the PostToolUse budget (20 s) on both hosts. A
# quadratic overlap test took about 18 s for 30000 characters.
long=$(od -An -N30000 -tu1 /dev/urandom | awk '{ for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
for host in claude codex; do
  checked=$((checked + 1))
  started=$(date +%s)
  jq -nc --arg s "token=[q7$long]
password=q7$rnd" \
    '{session_id:"wrapped",hook_event_name:"PostToolUse",tool_name:"Bash",
      tool_input:{command:"cat notes.txt"},
      tool_response:{stdout:$s,stderr:"",interrupted:false}}' \
    | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-post-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  elapsed=$(( $(date +%s) - started ))
  if [ "$status" -eq 0 ] && [ "$elapsed" -le 8 ] \
     && grep -q 'password=\[REDACTED\]' "$CASE_ROOT/out" \
     && ! grep -q "$rnd" "$CASE_ROOT/out"; then
    printf 'ok - wrapped value %s: %s long bracketed value masks in %ss\n' "$checked" "$host" "$elapsed"
  else
    fail "$host long bracketed value: exit $status after ${elapsed}s"
  fi
done

printf '%s wrapped value checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

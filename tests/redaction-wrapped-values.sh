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
printf '%s wrapped value checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

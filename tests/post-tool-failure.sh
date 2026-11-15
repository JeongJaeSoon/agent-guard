#!/usr/bin/env sh
# Claude PostToolUseFailure: the host cannot replace a failed tool's error
# text, so hook-post-tool-failure only reports. Verify that a finding reaches
# the model as additionalContext without the value, that a clean scan and a
# scan that could not run stay distinct, and that unknown or malformed input
# passes through. Synthetic scanner and payloads only.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-post-tool-failure.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
# The audit directory refuses a symlinked component (macOS /var -> /private/var).
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
mkdir "$CASE/cwd" "$CASE/home"
cd "$CASE/cwd" || exit 1
export HOME="$CASE/home" AGENT_GUARD_RELEASE_CHECK=off
export XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=on
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_PII_HOOK_MODE=off
unset AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_INFRA_FAILURE_MODE AI_AGENT AGENT_GUARD_HOOK_HOST
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  sed 's/^/  stdout: /' "$CASE/out"
  sed 's/^/  stderr: /' "$CASE/err"
}
SECRET=AGENT_GUARD_TEST_SECRET
ASSIGNMENT_VALUE=K7mQ2vN9xR4cT8pL6sW3
ASSIGNMENT="DB_PASSWORD=$ASSIGNMENT_VALUE"

# $1 = case name (also the session id), $2 = payload; extra env via caller.
run_hook() {
  AGENT_GUARD_WARNING_DIR="$CASE/warnings-$1" \
    "$GUARD" hook-post-tool-failure >"$CASE/out" 2>"$CASE/err" <<EOF
$2
EOF
}

failure_payload() {
  jq -nc --arg e "$1" --arg s "$2" \
    '{session_id: $s, hook_event_name: "PostToolUseFailure", tool_name: "Bash",
      tool_input: {command: "deploy"}, tool_use_id: "toolu_1",
      error: $e, is_interrupt: false}'
}

leaks_value() {
  LC_ALL=C grep -Fq "$SECRET" "$CASE/out" "$CASE/err" \
    || LC_ALL=C grep -Fq "$ASSIGNMENT_VALUE" "$CASE/out" "$CASE/err"
}

# One valid PostToolUseFailure context object and nothing else on stdout.
single_context() {
  jq -se --arg want "$1" 'length == 1 and (.[0] | keys == ["hookSpecificOutput"])
    and (.[0].hookSpecificOutput | keys == ["additionalContext", "hookEventName"]
         and .hookEventName == "PostToolUseFailure"
         and (.additionalContext | contains($want)))' "$CASE/out" >/dev/null 2>&1
}

# Findings: gitleaks rule and assignment probe, as a string and as a non-string
# error value. The context names the category and the host limit, never a value.
for kind in rule assignment structured; do
  case $kind in
    rule) payload=$(failure_payload "Exit code 1
token: $SECRET" "finding-$kind") ;;
    assignment) payload=$(failure_payload "Exit code 1
$ASSIGNMENT" "finding-$kind") ;;
    structured) payload=$(jq -nc --arg s "$SECRET" \
      '{session_id: "finding-structured", tool_name: "mcp__srv__tool",
        error: {message: "failed", detail: $s}}') ;;
  esac
  status=0
  run_hook "finding-$kind" "$payload" || status=$?
  if [ "$status" -eq 0 ] && single_context 'was NOT masked' \
    && single_context 'may need rotating' \
    && single_context 'anthropics/claude-code#97278' \
    && ! leaks_value; then
    ok "$kind finding is reported as additionalContext without the value"
  else
    bad "$kind finding is reported as additionalContext without the value (status $status)"
  fi
done

status=0
run_hook clean "$(failure_payload 'Exit code 1
Error: Cannot find module express' clean)" || status=$?
if [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ]; then
  ok "clean failure output passes silently"
else
  bad "clean failure output passes silently (status $status)"
fi

# Unknown and malformed events: nothing to block, so exit 0 and no stdout.
for kind in no-error null-error empty-error array scalar text empty; do
  case $kind in
    no-error) payload='{"session_id":"x","tool_name":"Bash","tool_input":{}}' ;;
    null-error) payload='{"tool_name":"Bash","error":null}' ;;
    empty-error) payload='{"tool_name":"Bash","error":""}' ;;
    array) payload="[\"$SECRET\"]" ;;
    scalar) payload="\"$SECRET\"" ;;
    text) payload="not json $SECRET" ;;
    empty) payload= ;;
  esac
  status=0
  run_hook "passthrough-$kind" "$payload" || status=$?
  if [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ] && ! leaks_value; then
    ok "$kind input passes through without output"
  else
    bad "$kind input passes through without output (status $status)"
  fi
done

status=0
AGENT_GUARD_OUTPUT_REDACT=off run_hook redact-off \
  "$(failure_payload "$SECRET" redact-off)" || status=$?
if [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ] && [ ! -s "$CASE/err" ]; then
  ok "AGENT_GUARD_OUTPUT_REDACT=off skips the failure scan"
else
  bad "AGENT_GUARD_OUTPUT_REDACT=off skips the failure scan (status $status)"
fi

# A scan that could not run is never reported as clean. Open warns once per
# session, closed warns every time; neither can block, so both exit 0.
for policy in open closed; do
  for attempt in 1 2; do
    status=0
    AGENT_GUARD_INFRA_FAILURE_MODE=$policy \
      AGENT_GUARD_GITLEAKS_BIN="$CASE/no-scanner" \
      AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/no-private-bin" \
      PATH="$CASE/no-path:$(dirname "$(command -v jq)"):/usr/bin:/bin" \
      run_hook "unavailable-$policy" "$(failure_payload "$SECRET" "unavailable-$policy")" \
      || status=$?
    case "$policy:$attempt" in
      open:1) expect=context want='AGENT_GUARD_INFRA_FAILURE_MODE=open' ;;
      open:2) expect=silent want= ;;
      closed:*) expect=context want='was NOT checked for secret-like values' ;;
    esac
    matched=yes
    [ "$status" -eq 0 ] || matched=no
    case $expect in
      context) single_context "$want" || matched=no ;;
      silent) [ ! -s "$CASE/out" ] || matched=no ;;
    esac
    ! leaks_value || matched=no
    if [ "$matched" = yes ]; then
      ok "$policy policy reports an unavailable scanner (attempt $attempt)"
    else
      bad "$policy policy reports an unavailable scanner (attempt $attempt, status $status)"
    fi
  done
done

# The support log shows the exposure as its own command with outcome warned.
"$GUARD" logs export >"$CASE/export" 2>"$CASE/err"
if jq -es 'any(.[]; .command == "hook-post-tool-failure" and .phase == "finished"
             and .outcome == "warned")
           and any(.[]; .command == "hook-post-tool-failure" and .phase == "finished"
             and .outcome == "degraded")' "$CASE/export" >/dev/null 2>&1 \
  && ! LC_ALL=C grep -Fq "$SECRET" "$CASE/export"; then
  ok "logs export records the finding as warned and the unavailable scan as degraded"
else
  bad "logs export records the finding as warned and the unavailable scan as degraded"
fi

# Only the Claude manifests register the event, with the PostToolUse matcher
# and timeout; Codex has no equivalent event.
for manifest in "$ROOT/plugins/agent-guard/hooks/hooks.json" \
  "$ROOT/examples/claude/settings.project.json"; do
  if jq -e '.hooks.PostToolUseFailure[0].matcher == .hooks.PostToolUse[0].matcher
            and .hooks.PostToolUseFailure[0].hooks[0].timeout == .hooks.PostToolUse[0].hooks[0].timeout
            and (.hooks.PostToolUseFailure[0].hooks[0].command | endswith(" hook-post-tool-failure")
                 or endswith(" hook-post-tool-failure'"'"'"))' "$manifest" >/dev/null 2>&1; then
    ok "PostToolUseFailure is registered like PostToolUse in $manifest"
  else
    bad "PostToolUseFailure is registered like PostToolUse in $manifest"
  fi
done
# The shipped Claude command resolves the plugin root and reaches the CLI.
manifest_command=$(jq -r '.hooks.PostToolUseFailure[0].hooks[0].command' \
  "$ROOT/plugins/agent-guard/hooks/hooks.json")
status=0
failure_payload "$SECRET" manifest \
  | CLAUDE_PLUGIN_ROOT="$ROOT/plugins/agent-guard" \
    AGENT_GUARD_WARNING_DIR="$CASE/warnings-manifest" \
    sh -c "$manifest_command" >"$CASE/out" 2>"$CASE/err" || status=$?
if [ "$status" -eq 0 ] && single_context 'was NOT masked' && ! leaks_value; then
  ok "the Claude plugin manifest command reports a failure-output finding"
else
  bad "the Claude plugin manifest command reports a failure-output finding (status $status)"
fi

for manifest in "$ROOT/plugins/agent-guard/hooks.json" "$ROOT/examples/codex/hooks.json"; do
  if jq -e '.hooks | has("PostToolUseFailure") | not' "$manifest" >/dev/null 2>&1; then
    ok "Codex manifest $manifest does not register PostToolUseFailure"
  else
    bad "Codex manifest $manifest does not register PostToolUseFailure"
  fi
done

printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

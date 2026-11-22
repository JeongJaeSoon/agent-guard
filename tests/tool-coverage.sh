#!/usr/bin/env sh
set -u

# Every tool a shipped matcher sends to the guard must reach a check.
# PreToolUse: for each listed name, an input carrying something that tool kind
# must not pass is blocked. PostToolUse: for each listed name, an output
# carrying a planted value comes back with the value gone and the shape kept,
# and under the closed policy with no scanner the whole output is withheld in
# that shape. A name added to a matcher without a row here fails, so widening
# host coverage forces a decision about what the guard checks for it.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
PLUGIN=${AGENT_GUARD_TEST_PLUGIN_ROOT:-$ROOT/plugins/agent-guard}
FIXTURE=$ROOT/tests/fixtures/code-mode-post-tool.json
OUTPUTS=$ROOT/tests/fixtures/claude-tool-outputs.json
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-tool-coverage.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$CASE/home" "$CASE/repo" || exit 1
cd "$CASE/repo" || exit 1
git init -q || exit 1
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_INFRA_FAILURE_MODE AI_AGENT
S=AGENT_GUARD_TEST_SECRET
passed=0
failed=0

ok() { passed=$((passed + 1)); }
not_ok() {
  failed=$((failed + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE/err" ] || sed 's/^/  stderr: /' "$CASE/err"
}

# planted TOOL prints a tool_input the guard must block for that tool.
planted() {
  case $1 in
    Write) printf '{"file_path":"a.ts","content":"%s"}' "$S" ;;
    Edit) printf '{"file_path":"a.ts","old_string":"x","new_string":"%s"}' "$S" ;;
    MultiEdit) printf '{"file_path":"a.ts","edits":[{"new_string":"%s"}]}' "$S" ;;
    NotebookEdit) printf '{"notebook_path":"n.ipynb","new_source":"%s"}' "$S" ;;
    apply_patch) printf '{"command":"*** Begin Patch\\n*** Add File: x\\n+%s\\n*** End Patch"}' "$S" ;;
    Read) printf '{"file_path":".env"}' ;;
    NotebookRead) printf '{"notebook_path":".env"}' ;;
    Grep) printf '{"pattern":"TODO","path":".env"}' ;;
    Glob) printf '{"pattern":"*.pem"}' ;;
    Bash) printf '{"command":"printf %s > leaked.txt"}' "$S" ;;
    WebFetch) printf '{"url":"https://example.invalid/?k=%s","prompt":"x"}' "$S" ;;
    WebSearch) printf '{"query":"%s"}' "$S" ;;
    Agent|Task) printf '{"description":"x","prompt":"use %s"}' "$S" ;;
    mcp__*) printf '{"arg":"%s"}' "$S" ;;
    *) return 1 ;;
  esac
}

# planted_output TOOL prints a tool_response carrying the marker. A tool in the
# outputs fixture has the shape Claude Code returns for it; the others stand in
# with one string leaf among fields of other types.
planted_output() {
  if jq -e --arg tool "$1" '.tools | has($tool)' "$OUTPUTS" >/dev/null 2>&1; then
    jq -c --arg tool "$1" --arg s "$S" '
      def plant: if type == "object" then with_entries(.value |= plant)
        elif type == "array" then map(plant)
        elif type == "string" then (split("{{SECRET}}") | join($s)) else . end;
      .tools[$tool].output | plant
    ' "$OUTPUTS"
    return
  fi
  case $1 in
    PowerShell) printf '{"stdout":"%s","stderr":"","interrupted":false,"isImage":false}' "$S" ;;
    NotebookRead) printf '{"type":"text","file":{"filePath":"a.txt","content":"%s","numLines":1}}' "$S" ;;
    MultiEdit) printf '{"filePath":"a.ts","oldString":"x","newString":"%s"}' "$S" ;;
    WebFetch) printf '{"code":200,"result":"%s"}' "$S" ;;
    WebSearch) printf '{"query":"q","results":["%s"]}' "$S" ;;
    Agent|Task) printf '{"content":[{"type":"text","text":"%s"}]}' "$S" ;;
    apply_patch|LSP|ListMcpResourcesTool|ReadMcpResourceTool|mcp__*)
      printf '{"result":"%s"}' "$S" ;;
    *) return 1 ;;
  esac
}

# clean_input TOOL prints a tool_input with nothing to find, for an event whose
# output is what the guard must look at. A write names a path that is absent.
clean_input() {
  case $1 in
    Write|Edit|MultiEdit) printf '{"file_path":"absent.ts"}' ;;
    NotebookEdit) printf '{"notebook_path":"absent.ipynb"}' ;;
    apply_patch) printf '{"command":"*** Begin Patch\\n*** Add File: absent.txt\\n+clean\\n*** End Patch"}' ;;
    *) printf '{}' ;;
  esac
}

# matcher_names FILE EVENT prints each alternative of that event's matcher, with
# a regex-shaped MCP entry turned into a concrete tool name.
matcher_names() {
  jq -r --arg event "$2" '.hooks[$event][0].matcher' "$1" \
    | sed 's/^\^(//; s/)\$$//' | tr '|' '\n' \
    | sed 's/^mcp__\.\*$/mcp__probe__call/'
}

# post_event TOOL SESSION prints a PostToolUse event whose output carries the marker.
post_event() {
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":%s,"tool_response":%s}' \
    "$2" "$1" "$(clean_input "$1")" "$(planted_output "$1")"
}

# run_post HOST EVENT [NAME=VALUE...] feeds one PostToolUse event to the guard.
run_post() {
  rp_host=$1
  rp_event=$2
  shift 2
  printf '%s' "$rp_event" \
    | env "$@" AGENT_GUARD_HOOK_HOST="$rp_host" "$GUARD" hook-post-tool >"$CASE/out" 2>"$CASE/err"
}

JQ_SHAPE='def shape: if type == "object" then with_entries(.value |= shape)
  elif type == "array" then map(shape) else type end;
def swap($s): if type == "object" then with_entries(.value |= swap($s))
  elif type == "array" then map(swap($s))
  elif type == "string" then (split($s) | join("[REDACTED]")) else . end;
def withheld($key; $own): if type == "object"
  then with_entries(.key as $k | .value |= withheld($k; $own))
  elif type == "array" then map(withheld(null; $own))
  elif type == "string" and length > 0
       and ((["type", "mode", "cell_type"] | index([$key])) == null)
       and (. as $v | (["filePath", "notebook_path"] | index([$key])) == null
            or ($own | index([$v])) == null)
  then "[REDACTED]" else . end;'

# One Claude response on stdout whose replacement keeps the event's shape and
# no longer holds the marker.
claude_replaced_in_shape() {  # $1 = event
  jq -e -n --argjson event "$1" --arg s "$S" --slurpfile out "$CASE/out" "$JQ_SHAPE"'
    ($out | length) == 1
    and $out[0].hookSpecificOutput.hookEventName == "PostToolUse"
    and ($out[0].hookSpecificOutput.updatedToolOutput as $u
         | ($u | shape) == ($event.tool_response | shape)
           and ($u | tojson | contains($s) | not)
           and ($u | tojson | contains("[REDACTED]")))
  ' >/dev/null 2>&1
}

codex_blocked_without_marker() {
  jq -e '.decision == "block"' "$CASE/out" >/dev/null 2>&1 && ! grep -Fq "$S" "$CASE/out"
}

for host in claude codex; do
  case $host in
    claude) manifest=$PLUGIN/hooks/hooks.json ;;
    codex) manifest=$PLUGIN/hooks.json ;;
  esac
  names=$(matcher_names "$manifest" PreToolUse) || exit 1
  count=0
  for name in $names; do
    count=$((count + 1))
    if ! tool_input=$(planted "$name"); then
      failed=$((failed + 1))
      printf 'not ok - %s matcher sends %s, which has no planted input here\n' "$host" "$name"
      continue
    fi
    printf '{"hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$name" "$tool_input" \
      | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
    status=$?
    if [ "$status" -eq 2 ]; then passed=$((passed + 1)); else
      failed=$((failed + 1))
      printf 'not ok - %s %s reaches no check (status %s)\n' "$host" "$name" "$status"
      sed 's/^/  stderr: /' "$CASE/err"
    fi
  done
  # An empty or unparsed matcher would pass the loop vacuously.
  if [ "$count" -ge 5 ]; then passed=$((passed + 1)); else
    failed=$((failed + 1)); printf 'not ok - %s matcher lists %s tools\n' "$host" "$count"
  fi

  names=$(matcher_names "$manifest" PostToolUse) || exit 1
  count=0
  for name in $names; do
    count=$((count + 1))
    if ! planted_output "$name" >/dev/null; then
      failed=$((failed + 1))
      printf 'not ok - %s PostToolUse matcher sends %s, which has no planted output here\n' "$host" "$name"
      continue
    fi

    event=$(post_event "$name" "tool-coverage-$host-$name")
    run_post "$host" "$event"
    status=$?
    case $host in
      claude) [ "$status" -eq 0 ] && claude_replaced_in_shape "$event" ;;
      codex) [ "$status" -eq 0 ] && codex_blocked_without_marker ;;
    esac
    if [ "$?" -eq 0 ]; then ok; else
      not_ok "$host $name output is masked in its own shape (status $status)"
    fi

    # No scanner under the closed policy: Claude takes a replacement beside
    # exit 2, so the unchecked output is withheld in its shape. A field the
    # host reads as one of a few words stays, since changing it would make the
    # host drop the replacement, and so does the path the model asked for.
    # Codex takes none, and its exit 2 stays as it was.
    event=$(post_event "$name" "tool-coverage-$host-$name-closed")
    run_post "$host" "$event" AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      AGENT_GUARD_GITLEAKS_BIN="$CASE/no-gitleaks"
    status=$?
    case $host in
      claude)
        [ "$status" -eq 2 ] && claude_replaced_in_shape "$event" \
          && jq -e -n --argjson event "$event" --slurpfile out "$CASE/out" "$JQ_SHAPE"'
               ([$event.tool_input | objects | .file_path, .notebook_path | strings]) as $own
               | $out[0].hookSpecificOutput.updatedToolOutput == ($event.tool_response | withheld(null; $own))
             ' >/dev/null 2>&1 \
          && grep -Fq 'AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$CASE/err"
        ;;
      codex) [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ] ;;
    esac
    if [ "$?" -eq 0 ]; then ok; else
      not_ok "$host $name closed policy without a scanner (status $status)"
    fi
  done
  if [ "$count" -ge 5 ]; then ok; else
    not_ok "$host PostToolUse matcher lists $count tools"
  fi
done

# The open policy keeps its contract: a notice, and no replacement.
event=$(post_event REPL tool-coverage-open)
run_post claude "$event" AGENT_GUARD_INFRA_FAILURE_MODE=open \
  AGENT_GUARD_GITLEAKS_BIN="$CASE/no-gitleaks"
status=$?
if [ "$status" -eq 0 ] \
   && jq -e '.hookSpecificOutput.updatedToolOutput == null and (.systemMessage | type) == "string"' \
        "$CASE/out" >/dev/null 2>&1; then ok; else
  not_ok "open policy without a scanner warns and replaces nothing (status $status)"
fi

# The switch that turns output masking off turns the closed withhold off too.
event=$(post_event REPL tool-coverage-redact-off)
run_post claude "$event" AGENT_GUARD_INFRA_FAILURE_MODE=closed \
  AGENT_GUARD_GITLEAKS_BIN="$CASE/no-gitleaks" AGENT_GUARD_OUTPUT_REDACT=off
status=$?
if [ "$status" -eq 2 ] && [ ! -s "$CASE/out" ]; then ok; else
  not_ok "closed policy with output masking off withholds nothing (status $status)"
fi

# Code Mode events in the shapes a live Claude Code hook received.
cases=$(jq '.cases | length' "$FIXTURE") || exit 1
index=0
while [ "$index" -lt "$cases" ]; do
  label=$(jq -r --argjson i "$index" '.cases[$i].label' "$FIXTURE")
  masked=$(jq -r --argjson i "$index" '.cases[$i].masked' "$FIXTURE")
  for host in claude codex; do
    event=$(jq -c --argjson i "$index" --arg s "$S" --arg id "tool-coverage-fixture-$host-$index" '
      def plant: if type == "object" then with_entries(.value |= plant)
        elif type == "array" then map(plant)
        elif type == "string" then (split("{{SECRET}}") | join($s)) else . end;
      .cases[$i]
      | {session_id: $id, hook_event_name: "PostToolUse", tool_name: .tool,
         tool_input: .tool_input, tool_response: (.tool_response | plant)}
    ' "$FIXTURE") || exit 1
    run_post "$host" "$event"
    status=$?
    case "$masked:$host" in
      true:claude)
        # Only the planted value changes: every other character and field stays.
        [ "$status" -eq 0 ] \
          && jq -e -n --argjson event "$event" --arg s "$S" --slurpfile out "$CASE/out" "$JQ_SHAPE"'
               ($out | length) == 1
               and $out[0].hookSpecificOutput.updatedToolOutput == ($event.tool_response | swap($s))
             ' >/dev/null 2>&1
        ;;
      true:codex) [ "$status" -eq 0 ] && codex_blocked_without_marker ;;
      false:*) [ "$status" -eq 0 ] && [ ! -s "$CASE/out" ] ;;
      *) false ;;
    esac
    if [ "$?" -eq 0 ]; then ok; else
      not_ok "$host fixture: $label (status $status)"
    fi
  done
  index=$((index + 1))
done
if [ "$cases" -ge 6 ]; then ok; else not_ok "Code Mode fixture lists $cases cases"; fi

# When neither jq nor the awk parser can rewrite the response, the fixed
# replacement must still have the tool's shape: Claude Code drops a bare string
# for a built-in tool and gives the model the original. Every tool in the
# outputs fixture gets its fixed object, which has the keys, the kinds of value
# and the host-read words of that tool's output. A tool with no recorded
# output, WebSearch here, still gets the bare string.
REAL_JQ=$(command -v jq) || exit 1
REAL_CAT=$(command -v cat) || exit 1
mkdir "$CASE/broken" || exit 1
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'for arg in "$@"; do case $arg in *shape_safe_walk*) exit 1 ;; esac; done'
  printf '%s\n' "exec \"$REAL_JQ\" \"\$@\""
} >"$CASE/broken/jq"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'if [ "$#" -eq 1 ]; then case $1 in */agent-guard.*) exit 2 ;; esac; fi'
  printf '%s\n' "exec \"$REAL_CAT\" \"\$@\""
} >"$CASE/broken/cat"
chmod +x "$CASE/broken/jq" "$CASE/broken/cat"
fixed_tools=$(jq -r '.tools | keys[]' "$OUTPUTS") || exit 1
count=0
for name in $fixed_tools WebSearch; do
  if fixed=$(jq -ce --arg tool "$name" '.tools[$tool].fixed // empty' "$OUTPUTS" 2>/dev/null); then
    count=$((count + 1))
    if jq -e --arg tool "$name" '
         def kinds: if type == "object" then with_entries(.value |= kinds)
           elif type == "array" then "array" else type end;
         def words: {type, mode, cell_type, edit_mode};
         .tools[$tool] | (.fixed | kinds) == (.output | kinds) and (.fixed | words) == (.output | words)
       ' "$OUTPUTS" >/dev/null 2>&1; then ok; else
      not_ok "claude $name fixed replacement has the keys, value kinds and host-read words of its output"
    fi
  else
    fixed='"[REDACTED]"'
  fi
  event=$(post_event "$name" "tool-coverage-fixed-$name")
  run_post claude "$event" PATH="$CASE/broken:$PATH" AGENT_GUARD_INFRA_FAILURE_MODE=closed \
    AGENT_GUARD_GITLEAKS_BIN="$CASE/no-gitleaks"
  status=$?
  if [ "$status" -eq 2 ] \
     && jq -e -n --argjson fixed "$fixed" --slurpfile out "$CASE/out" '
          ($out | length) == 1 and $out[0].hookSpecificOutput.updatedToolOutput == $fixed
        ' >/dev/null 2>&1; then ok; else
    not_ok "claude $name fixed replacement when no parser can rewrite (status $status)"
  fi
done
if [ "$count" -ge 11 ]; then ok; else not_ok "outputs fixture lists $count tools with a fixed replacement"; fi

# Each rewrite path keeps the fields the host checks in built-in tool outputs.
if sh "$ROOT/tests/output-shape.sh" >"$CASE/shape" 2>&1; then ok; else
  not_ok "built-in tool outputs keep their shape when masked"
  sed 's/^/  /' "$CASE/shape"
fi

printf 'tool coverage assertions: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0

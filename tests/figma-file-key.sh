#!/usr/bin/env sh
set -u

# A Figma file key names a document; opening it still needs a Figma login with
# access to the file. On a Figma MCP server, a 22-character key in a
# `fileKey`/`file_key` field must pass the MCP input check and the output
# masker, and so must its copy in the file URL. The same value under another
# field, in a URL query, on another MCP server, or a value of another length
# keeps its finding, on Claude and Codex.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-figma-key.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' EXIT INT TERM
mkdir "$CASE/cwd" "$CASE/home"
# A host that passes the variable empty means "no real gitleaks".
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
if [ -z "$GITLEAKS" ]; then
  printf 'skip - real gitleaks is not installed\n'
  exit 0
fi
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_PII_HOOK_MODE=off
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_OUTPUT_REDACT AGENT_GUARD_INFRA_FAILURE_MODE AI_AGENT
PATH="$(dirname "$GITLEAKS"):$PATH"
pass=0
fail=0
n=0

ok() {
  pass=$((pass + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  sed -e "s/$KEY/<key>/g" -e 's/^/  stdout: /' "$CASE/out"
  sed -e "s/$KEY/<key>/g" -e 's/^/  stderr: /' "$CASE/err"
}

# Fixed, not random: a low-entropy key would fall under generic-api-key's
# entropy floor and turn every must-keep-finding case into a silent pass. It
# is built at run time so this file holds no literal finding.
KEY=$(printf '%s%s%s' Qm7Rt2 Xa9Lp4Vb K8Hn3Wz6)
LONG_KEY="${KEY}J"
VENDOR=$(printf 'gh%s_%s%s' p "$KEY" "$KEY" | cut -c1-40)
FIG=mcp__claude_ai_Figma__create_new_file
FIG_SESSION=mcp__claude_ai_Figma__create_session
FIG_LOCAL=mcp__figma__use_figma
OTHER=mcp__notes__read
OTHER_NAMED=mcp__notes__figma_export
URL="https://www.figma.com/design/$KEY/Untitled"
# Built with jq: macOS /bin/sh (bash 3.2) brace-expands `{a,b}` text passed
# inside "$(...)", which would split one response into two.
RESPONSE=$(jq -nc --arg k "$KEY" --arg u "$URL" '{file_key:$k,file_url:$u,message:"Created"}')
FIGMA_QUERY=$(jq -nc --arg k "$KEY" --arg u "$URL?api_key=$KEY" '{file_key:$k,file_url:$u}')
OTHER_QUERY=$(jq -nc --arg k "$KEY" --arg u "$URL" '{file_url:$u,next:("https://example.com/cb?api_key=" + $k)}')
CODE_ASSIGNMENT=$(jq -nc --arg k "$KEY" '{fileKey:$k,code:("api_key=" + $k)}')

leaks() {
  LC_ALL=C grep -Fq "$1" "$CASE/out" "$CASE/err"
}

# $1 host, $2 tool, $3 tool_response JSON. Status in $hook_status.
post_hook() {
  n=$((n + 1))
  jq -nc --arg t "$2" --argjson r "$3" --arg d "$CASE/cwd" --arg s "figma-key-$n" \
    '{session_id:$s,hook_event_name:"PostToolUse",tool_name:$t,tool_input:{},tool_response:$r,cwd:$d}' |
    (cd "$CASE/cwd" && AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-post-tool) >"$CASE/out" 2>"$CASE/err"
  hook_status=$?
}

text_response() {
  jq -nc --arg t "$1" '[{type:"text",text:$t}]'
}

# $1 host, $2 label, $3 tool, $4 tool_response JSON: the result reaches the
# model unchanged (no rewrite at all).
post_passes() {
  post_hook "$1" "$3" "$4"
  if [ "$hook_status" -eq 0 ] && [ ! -s "$CASE/out" ]; then
    ok "$1 PostToolUse keeps: $2"
  else
    not_ok "$1 PostToolUse keeps: $2 (status $hook_status, stdout $(wc -c <"$CASE/out") bytes)"
  fi
}

# $1 host, $2 label, $3 tool, $4 tool_response JSON, $5 value that must not
# survive anywhere in the rewritten result.
post_masks() {
  post_hook "$1" "$3" "$4"
  case $1 in
    claude) contract='.hookSpecificOutput.updatedToolOutput != null' ;;
    codex) contract='.decision == "block" and (.hookSpecificOutput.additionalContext | contains("[REDACTED]"))' ;;
  esac
  if [ "$hook_status" -eq 0 ] && jq -e "$contract" "$CASE/out" >/dev/null 2>&1 \
    && ! leaks "$5"; then
    ok "$1 PostToolUse masks: $2"
  else
    not_ok "$1 PostToolUse masks: $2 (status $hook_status)"
  fi
}

# $1 host, $2 expected status, $3 label, $4 tool, $5 tool_input JSON.
pre_case() {
  n=$((n + 1))
  jq -nc --arg t "$4" --argjson i "$5" --arg d "$CASE/cwd" --arg s "figma-key-$n" \
    '{session_id:$s,hook_event_name:"PreToolUse",tool_name:$t,tool_input:$i,cwd:$d}' |
    (cd "$CASE/cwd" && AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-pre-tool) >"$CASE/out" 2>"$CASE/err"
  hook_status=$?
  if [ "$hook_status" -ne "$2" ]; then
    not_ok "$1 PreToolUse: $3 (expected $2, got $hook_status)"
  elif [ "$2" -eq 2 ] && ! grep -q 'secret-like value detected in MCP tool input' "$CASE/err"; then
    not_ok "$1 PreToolUse: $3 (blocked without the MCP input scan message)"
  else
    ok "$1 PreToolUse: $3"
  fi
}

for host in claude codex; do
  # The Figma result: the key and its copy in the file URL reach the model.
  post_passes "$host" "create_new_file file_key and file URL" "$FIG" "$(text_response "$RESPONSE")"
  post_passes "$host" "structured file_key on a local Figma server" "$FIG_LOCAL" \
    "$(jq -nc --arg k "$KEY" --arg u "$URL" '{file_key:$k,file_url:$u}')"
  # Controls: the same text from another server, or a server that only names a
  # tool after Figma, is masked, URL copy included.
  post_masks "$host" "same result from another MCP server" "$OTHER" "$(text_response "$RESPONSE")" "$KEY"
  post_masks "$host" "figma in the tool name only" "$OTHER_NAMED" "$(text_response "$RESPONSE")" "$KEY"
  # The same value elsewhere in a Figma result is a finding, so every copy,
  # including file_key and the URL path, is masked.
  post_masks "$host" "key also in a figma.com URL query" "$FIG" \
    "$(text_response "$FIGMA_QUERY")" "$KEY"
  post_masks "$host" "key also in another domain's URL query" "$FIG" \
    "$(text_response "$OTHER_QUERY")" "$KEY"
  post_masks "$host" "same-length value under a token field" "$FIG" \
    "$(text_response "{\"access_token\":\"$KEY\"}")" "$KEY"
  post_masks "$host" "longer value under file_key" "$FIG" \
    "$(text_response "{\"file_key\":\"$LONG_KEY\"}")" "$LONG_KEY"
  post_masks "$host" "vendor token under file_key" "$FIG" \
    "$(text_response "{\"file_key\":\"$VENDOR\"}")" "$VENDOR"

  pre_case "$host" 0 "create_session fileKey" "$FIG_SESSION" \
    "$(jq -nc --arg k "$KEY" '{fileKey:$k,description:"Build the library"}')"
  pre_case "$host" 0 "use_figma fileKey with code" "$FIG_LOCAL" \
    "$(jq -nc --arg k "$KEY" '{fileKey:$k,code:"figma.currentPage.name"}')"
  pre_case "$host" 2 "fileKey on another MCP server" "$OTHER" \
    "$(jq -nc --arg k "$KEY" '{fileKey:$k}')"
  pre_case "$host" 2 "same value in another Figma argument" "$FIG_SESSION" \
    "$(jq -nc --arg k "$KEY" '{fileKey:$k,apiKey:$k}')"
  pre_case "$host" 2 "same value as a key assignment in Figma code" "$FIG_LOCAL" \
    "$CODE_ASSIGNMENT"
  pre_case "$host" 2 "longer fileKey" "$FIG_SESSION" \
    "$(jq -nc --arg k "$LONG_KEY" '{fileKey:$k}')"
  pre_case "$host" 2 "vendor token as fileKey" "$FIG_SESSION" \
    "$(jq -nc --arg k "$VENDOR" '{fileKey:$k}')"
done

# PostToolUseFailure only reports; a Figma error carrying its key stays quiet
# while the same error from another server is reported.
failure_case() {
  n=$((n + 1))
  jq -nc --arg t "$2" --arg e "Error: {\"file_key\":\"$KEY\"}" --arg s "figma-key-$n" \
    '{session_id:$s,hook_event_name:"PostToolUseFailure",tool_name:$t,tool_input:{},error:$e}' |
    (cd "$CASE/cwd" && AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_WARNING_DIR="$CASE/warn-$n" \
      "$GUARD" hook-post-tool-failure) >"$CASE/out" 2>"$CASE/err"
  hook_status=$?
  if [ "$hook_status" -eq 0 ] && { if [ "$1" = quiet ]; then [ ! -s "$CASE/out" ]; else grep -q 'was NOT masked' "$CASE/out"; fi; } \
    && ! leaks "$KEY"; then
    ok "PostToolUseFailure: $3"
  else
    not_ok "PostToolUseFailure: $3 (status $hook_status)"
  fi
}
failure_case quiet "$FIG" "Figma error with its file key is not reported"
failure_case report "$OTHER" "the same error from another server is reported"

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]

#!/usr/bin/env sh
# Render every committed hook manifest from ONE set of tables.
#
# Every event's matcher, timeout, statusMessage, and hook subcommand must agree
# across all four manifests; only the command string, the Claude-only
# PreToolUse onFailure key, and the Claude-only PostToolUseFailure event
# legitimately differ. Codex titles each hook in `/hooks` with statusMessage
# ("Unnamed hook" without it); both hosts also show it while the hook runs.
# Editing them by hand
# meant twenty copies kept in lockstep, so this script is the single source of
# truth: edit the tables below, run it, and commit the result.
#
#   scripts/render-hook-manifests.sh          # rewrite all four manifests
#   scripts/render-hook-manifests.sh --check  # fail if committed files drift
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"

CODEX_HOOKS="$PLUGIN_ROOT/hooks.json"
CLAUDE_HOOKS="$PLUGIN_ROOT/hooks/hooks.json"
CODEX_EXAMPLE="$ROOT/examples/codex/hooks.json"
CLAUDE_EXAMPLE="$ROOT/examples/claude/settings.project.json"

# Shared by each host's plugin manifest and its example, so a coverage change
# cannot land in one and miss the other.
CODEX_PRE_MATCHER='Bash|apply_patch|Agent|Task|mcp__.*'
CODEX_POST_MATCHER='Bash|apply_patch|Agent|Task|mcp__.*'
CLAUDE_PRE_MATCHER='Write|Edit|MultiEdit|NotebookEdit|Read|NotebookRead|Grep|Glob|Bash|WebFetch|WebSearch|apply_patch|Agent|Task|mcp__.*'
# Anchors keep Claude in JavaScript-regex mode while restricting coverage to
# exact built-in names plus the MCP namespace. Every relied-on built-in is
# explicit; no tool is covered only because its name contains a listed token.
# REPL and Poll are the Code Mode tools whose result is what the model reads:
# REPL fires when a script ends or throws, Poll when its output is delivered.
# Eval is the REPL tool's other name in Claude Code 2.1.330 (its li() check);
# no recorded transcript has an Eval event yet.
CLAUDE_POST_MATCHER='^(Write|Edit|MultiEdit|NotebookEdit|Bash|PowerShell|apply_patch|Read|NotebookRead|Grep|Glob|WebFetch|WebSearch|Agent|Task|Skill|Monitor|LSP|ListMcpResourcesTool|ReadMcpResourceTool|REPL|Eval|Poll|mcp__.*)$'

# Plugin command: the host exports a versioned plugin-cache root. The command
# only finds a v1 launcher (hooks/launch.sh) in that root, then in `current`,
# then in any semver sibling, and execs it with the ORIGINAL root: the launcher
# owns root selection, deleted-root recovery, the no-substitution rule for an
# existing incomplete root, the host pin and the once-per-session warning.
# The inline policy runs only when no launcher exists anywhere (root unset or
# cache gone): it drains stdin, warns on EVERY call when it continues, and
# exits 2 with the reason when it blocks. Unset blocks, except for Stop and
# SessionStart, whose events carry no text to the agent; open and closed
# apply to every event, as in the launcher. The line has to stay short, so it
# tells those two by their subcommands being the only ones that start with
# hook-s (tests/hook-launcher.sh checks every event's default). Keep `${@ROOT_VAR@:-}`: Claude substitutes
# the exact text `${CLAUDE_PLUGIN_ROOT}` before running the command, and the
# `:-` form never matches it, so the path arrives only through the environment
# and cannot break the single-quoted script. The command itself only execs;
# the launcher stays as the binary's parent for a hook that blocks.
# @ROOT_VAR@ = plugin-root env var the host exports, @HOST@ = hook-contract
# host tag, @SUB@ = agent-guard hook subcommand for the event.
PLUGIN_TEMPLATE=$(cat <<'EOF'
sh -c 'r=${@ROOT_VAR@:-}; [ -n "$r" ] && for q in "$r" "${r%/*}/current" "${r%/*}"/[0-9]*.[0-9]*.[0-9]*; do [ -f "$q/hooks/launch.sh" ] && exec sh "$q/hooks/launch.sh" @HOST@ @SUB@ "$r"; done; while read -r l; do :; done; m=${AGENT_GUARD_INFRA_FAILURE_MODE:-}; case $m:@SUB@ in open:*|closed:*) ;; *:hook-s*) m=open ;; *) m=unset ;; esac; a=blocking; [ $m = open ] && a=continuing; echo "agent-guard: @ROOT_VAR@ env not set or no hook launcher was found; $a because AGENT_GUARD_INFRA_FAILURE_MODE=$m" >&2; [ $m = open ] && exit 0; exit 2'
EOF
)

# Example commands: a standalone install points at the binary directly, so there
# is no plugin cache to resolve. Claude omits AGENT_GUARD_HOOK_HOST because
# `claude` is the binary's default host; Codex must set it.
CLAUDE_EXAMPLE_TEMPLATE='/absolute/path/to/agent-guard/plugins/agent-guard/bin/agent-guard @SUB@'
CODEX_EXAMPLE_TEMPLATE='AGENT_GUARD_HOOK_HOST=codex ./plugins/agent-guard/bin/agent-guard @SUB@'

render_command() { # $1 = root env var, $2 = host tag, $3 = hook subcommand, $4 = plugin|example
  case "$4:$2" in
    plugin:*) template=$PLUGIN_TEMPLATE ;;
    example:claude) template=$CLAUDE_EXAMPLE_TEMPLATE ;;
    example:codex) template=$CODEX_EXAMPLE_TEMPLATE ;;
    *)
      printf '%s\n' "render-hook-manifests: no $4 template for host $2" >&2
      return 1
      ;;
  esac
  rendered=$(printf '%s\n' "$template" \
    | sed -e "s/@ROOT_VAR@/$1/g" -e "s/@HOST@/$2/g" -e "s/@SUB@/$3/g") || return 1
  # A sed that fails to substitute exits 0, so also refuse an empty result or a
  # leftover placeholder: silently rendering a broken hook command would
  # disable the protections these manifests install.
  case "$rendered" in
    ''|*@ROOT_VAR@*|*@HOST@*|*@SUB@*)
      printf '%s\n' "render-hook-manifests: bad render for $2 $3" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$rendered"
}

render_manifest() { # $1 = root env var, $2 = host tag, $3/$4 = pre/post matcher, $5 = style
  # Claude lets a PreToolUse hook that times out, crashes, exits other than
  # 0/2, or prints invalid JSON through unchecked unless onFailure is "block"
  # (Claude Code 2.1.295+).
  # Codex has no such key, so its manifests leave it out.
  # Claude fires PostToolUseFailure instead of PostToolUse when a tool fails,
  # so the failure output needs its own registration with the same matcher.
  # Codex has no such event.
  case "$2" in
    claude) pre_on_failure=block; with_failure=1 ;;
    *) pre_on_failure=; with_failure= ;;
  esac
  # Status-checked assignments: a render_command failure inside a jq argument's
  # command substitution would otherwise be discarded while jq still exits 0.
  pre=$(render_command "$1" "$2" hook-pre-tool "$5") || return 1
  post=$(render_command "$1" "$2" hook-post-tool "$5") || return 1
  failure=
  if [ -n "$with_failure" ]; then
    failure=$(render_command "$1" "$2" hook-post-tool-failure "$5") || return 1
  fi
  stop=$(render_command "$1" "$2" hook-stop "$5") || return 1
  session=$(render_command "$1" "$2" hook-session-start "$5") || return 1
  prompt=$(render_command "$1" "$2" hook-user-prompt "$5") || return 1
  jq -n \
    --arg pre_matcher "$3" \
    --arg post_matcher "$4" \
    --arg pre "$pre" \
    --arg pre_on_failure "$pre_on_failure" \
    --arg post "$post" \
    --arg failure "$failure" \
    --arg stop "$stop" \
    --arg session "$session" \
    --arg prompt "$prompt" \
    '{hooks: ({
       PreToolUse: [{matcher: $pre_matcher,
                     hooks: [{type: "command", command: $pre, timeout: 60,
                              statusMessage: "agent-guard: checking tool call"}
                             + (if $pre_on_failure == "" then {}
                                else {onFailure: $pre_on_failure} end)]}],
       PostToolUse: [{matcher: $post_matcher,
                      hooks: [{type: "command", command: $post, timeout: 20,
                               statusMessage: "agent-guard: scanning tool output"}]}]}
     + (if $failure == "" then {}
        else {PostToolUseFailure: [{matcher: $post_matcher,
                                    hooks: [{type: "command", command: $failure,
                                             timeout: 20,
                                             statusMessage: "agent-guard: scanning failed tool output"}]}]} end)
     + {
       Stop: [{matcher: "",
               hooks: [{type: "command", command: $stop, timeout: 20,
                        statusMessage: "agent-guard: scanning changes"}]}],
       SessionStart: [{matcher: "startup|resume|clear|compact",
                       hooks: [{type: "command", command: $session, timeout: 5,
                                statusMessage: "agent-guard: checking setup"}]}],
       UserPromptSubmit: [{matcher: "",
                           hooks: [{type: "command", command: $prompt, timeout: 10,
                                    statusMessage: "agent-guard: scanning prompt"}]}]
     })}'
}

render_target() { # $1 = one of the four committed manifest paths
  case "$1" in
    "$CODEX_HOOKS")
      render_manifest PLUGIN_ROOT codex \
        "$CODEX_PRE_MATCHER" "$CODEX_POST_MATCHER" plugin
      ;;
    "$CLAUDE_HOOKS")
      render_manifest CLAUDE_PLUGIN_ROOT claude \
        "$CLAUDE_PRE_MATCHER" "$CLAUDE_POST_MATCHER" plugin
      ;;
    "$CODEX_EXAMPLE")
      render_manifest PLUGIN_ROOT codex \
        "$CODEX_PRE_MATCHER" "$CODEX_POST_MATCHER" example
      ;;
    "$CLAUDE_EXAMPLE")
      render_manifest CLAUDE_PLUGIN_ROOT claude \
        "$CLAUDE_PRE_MATCHER" "$CLAUDE_POST_MATCHER" example
      ;;
    *)
      printf '%s\n' "render-hook-manifests: unknown target $1" >&2
      return 1
      ;;
  esac
}

case "${1:-write}" in
  write)
    # Render all four manifests fully before replacing any committed file, so a
    # failing jq/sed cannot leave a truncated or half-updated set behind.
    tmp_codex=$(mktemp "$CODEX_HOOKS.XXXXXX")
    tmp_claude=$(mktemp "$CLAUDE_HOOKS.XXXXXX")
    tmp_codex_example=$(mktemp "$CODEX_EXAMPLE.XXXXXX")
    tmp_claude_example=$(mktemp "$CLAUDE_EXAMPLE.XXXXXX")
    trap 'rm -f "$tmp_codex" "$tmp_claude" "$tmp_codex_example" "$tmp_claude_example"' \
      EXIT INT TERM
    render_target "$CODEX_HOOKS" >"$tmp_codex"
    render_target "$CLAUDE_HOOKS" >"$tmp_claude"
    render_target "$CODEX_EXAMPLE" >"$tmp_codex_example"
    render_target "$CLAUDE_EXAMPLE" >"$tmp_claude_example"
    chmod 644 "$tmp_codex" "$tmp_claude" "$tmp_codex_example" "$tmp_claude_example"
    mv "$tmp_codex" "$CODEX_HOOKS"
    mv "$tmp_claude" "$CLAUDE_HOOKS"
    mv "$tmp_codex_example" "$CODEX_EXAMPLE"
    mv "$tmp_claude_example" "$CLAUDE_EXAMPLE"
    printf 'rendered %s, %s, %s and %s\n' \
      "$CODEX_HOOKS" "$CLAUDE_HOOKS" "$CODEX_EXAMPLE" "$CLAUDE_EXAMPLE" >&2
    ;;
  --check)
    status=0
    for target in "$CODEX_HOOKS" "$CLAUDE_HOOKS" "$CODEX_EXAMPLE" "$CLAUDE_EXAMPLE"; do
      render_target "$target" | diff -u "$target" - >&2 || status=1
    done
    [ "$status" -eq 0 ] || {
      printf '%s\n' 'hook manifests drifted from the renderer; run scripts/render-hook-manifests.sh' >&2
      exit 1
    }
    ;;
  *)
    printf 'usage: %s [--check]\n' "$0" >&2
    exit 2
    ;;
esac

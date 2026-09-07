#!/usr/bin/env sh
# Render every committed hook manifest from ONE set of tables.
#
# Four files carry the same hook wiring and differ only in how they name the
# binary:
#
#   plugins/agent-guard/hooks.json         Codex plugin  (resolver one-liner)
#   plugins/agent-guard/hooks/hooks.json   Claude plugin (resolver one-liner)
#   examples/codex/hooks.json              standalone Codex example
#   examples/claude/settings.project.json  standalone Claude example
#
# Every event's matcher, timeout, and hook subcommand must agree across all
# four; only the command string legitimately differs. Editing them by hand meant
# twenty copies kept in lockstep, so this script is the single source of truth:
# edit the tables below, run it, and commit the result.
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

# Tool matchers, per host. Shared by that host's plugin manifest and example so
# a coverage change cannot land in one and miss the other.
CODEX_PRE_MATCHER='Bash|apply_patch|Agent|Task|mcp__.*'
CODEX_POST_MATCHER='Bash|apply_patch|Agent|Task|mcp__.*'
CLAUDE_PRE_MATCHER='Write|Edit|MultiEdit|NotebookEdit|Read|NotebookRead|Grep|Glob|Bash|WebFetch|WebSearch|apply_patch|Agent|Task|mcp__.*'
CLAUDE_POST_MATCHER='Write|Edit|MultiEdit|NotebookEdit|Bash|apply_patch|Read|NotebookRead|Grep|Glob|WebFetch|WebSearch|Agent|Task|mcp__.*'

# Plugin command: the host exports a versioned plugin-cache root, so the hook has
# to resolve a complete, executable payload itself before dispatching.
# @ROOT_VAR@ = plugin-root env var the host exports, @HOST@ = hook-contract
# host tag, @SUB@ = agent-guard hook subcommand for the event.
PLUGIN_TEMPLATE=$(cat <<'EOF'
sh -c 'r=${@ROOT_VAR@:-}; b=${r%/*}; x=; semver() { case ${1:-} in ""|*[!0-9.]*) return 1 ;; esac; o=$IFS; IFS=.; set -- $1; IFS=$o; [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]; }; root_ok() { q=$1; e=${2:-}; z="$q/bin/agent-guard"; [ -x "$z" ] && [ -r "$q/config/gitleaks.toml" ] && [ -r "$q/config/deny-read-paths.txt" ] && [ -r "$q/config/deny-bash-patterns.txt" ] || return 1; u=; while IFS= read -r l; do case "$l" in VERSION=*) u=${l#VERSION=}; break ;; esac; done <"$z"; [ -n "$u" ] && { [ -z "$e" ] || [ "$u" = "$e" ]; }; }; if [ -n "$r" ]; then v=${r##*/}; semver "$v" || v=; if root_ok "$r" "$v"; then x="$r/bin/agent-guard"; elif [ ! -e "$r" ]; then c="$b/current"; t=; [ -L "$c" ] && t=$(readlink "$c" 2>/dev/null) || :; if semver "$t" && root_ok "$c" "$t"; then x="$c/bin/agent-guard"; else x=$(for z in "$b"/*/bin/agent-guard; do [ -x "$z" ] || continue; q=${z%/bin/agent-guard}; v=${q##*/}; semver "$v" || continue; root_ok "$q" "$v" || continue; printf "%s\\t%s\\n" "$v" "$z"; done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -f 2-); fi; fi; fi; if [ ! -x "$x" ]; then mode=${AGENT_GUARD_INFRA_FAILURE_MODE:-open}; case "$mode" in closed) action=blocking ;; *) mode=open; action=continuing ;; esac; d=${AGENT_GUARD_WARNING_DIR:-${TMPDIR:-/tmp}/agent-guard-warnings-${UID:-user}}; p=; while IFS= read -r line || [ -n "$line" ]; do p=$p$line; done; i=${AGENT_GUARD_SESSION_ID:-}; if [ -z "$i" ] && command -v jq >/dev/null 2>&1; then i=$(printf %s "$p" | jq -r ".session_id // empty" 2>/dev/null); fi; if [ -z "$i" ]; then case "$p" in *\"session_id\":\"*) i=${p#*\"session_id\":\"}; i=${i%%\"*}; case "$i" in ""|*[!A-Za-z0-9._:-]*) i= ;; esac ;; esac; fi; if [ -n "$i" ]; then i=$(printf %s "$i" | cksum); else i=ppid-${PPID:-0}; fi; k="$d/manifest-@HOST@-$i-$mode"; warn=1; if mkdir -p "$d" 2>/dev/null; then (umask 077; set -C; : >"$k") 2>/dev/null || warn=0; fi; [ "$warn" -eq 0 ] || echo "agent-guard: @ROOT_VAR@ env not set, selected root was incomplete, or no installed binary was found; $action because AGENT_GUARD_INFRA_FAILURE_MODE=$mode" >&2; [ "$mode" = closed ] && exit 2; exit 0; fi; AGENT_GUARD_HOOK_HOST=@HOST@ "$x" @SUB@'
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
  # Status-checked assignments: a render_command failure inside a jq argument's
  # command substitution would otherwise be discarded while jq still exits 0.
  pre=$(render_command "$1" "$2" hook-pre-tool "$5") || return 1
  post=$(render_command "$1" "$2" hook-post-tool "$5") || return 1
  stop=$(render_command "$1" "$2" hook-stop "$5") || return 1
  session=$(render_command "$1" "$2" hook-session-start "$5") || return 1
  prompt=$(render_command "$1" "$2" hook-user-prompt "$5") || return 1
  jq -n \
    --arg pre_matcher "$3" \
    --arg post_matcher "$4" \
    --arg pre "$pre" \
    --arg post "$post" \
    --arg stop "$stop" \
    --arg session "$session" \
    --arg prompt "$prompt" \
    '{hooks: {
       PreToolUse: [{matcher: $pre_matcher,
                     hooks: [{type: "command", command: $pre, timeout: 10}]}],
       PostToolUse: [{matcher: $post_matcher,
                      hooks: [{type: "command", command: $post, timeout: 20}]}],
       Stop: [{matcher: "",
               hooks: [{type: "command", command: $stop, timeout: 20}]}],
       SessionStart: [{matcher: "startup|resume|clear|compact",
                       hooks: [{type: "command", command: $session, timeout: 5}]}],
       UserPromptSubmit: [{matcher: "",
                           hooks: [{type: "command", command: $prompt, timeout: 10}]}]
     }}'
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

#!/usr/bin/env sh
# Render the canonical plugin hook manifests from ONE command template.
#
# plugins/agent-guard/hooks.json (Codex) and plugins/agent-guard/hooks/
# hooks.json (Claude) embed the same binary-resolver one-liner once per hook
# event — eight copies that previously had to be edited by hand in lockstep
# (they differ only in the plugin-root env var, the host tag, and the trailing
# hook subcommand). This script is the single source of truth: edit TEMPLATE or
# the per-host tables below, run it, and commit the result.
#
#   scripts/render-hook-manifests.sh          # rewrite both manifests
#   scripts/render-hook-manifests.sh --check  # fail if committed files drift
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"

# @ROOT_VAR@ = plugin-root env var the host exports, @HOST@ = hook-contract
# host tag, @SUB@ = agent-guard hook subcommand for the event.
TEMPLATE=$(cat <<'EOF'
sh -c 'r=${@ROOT_VAR@:-}; b=${r%/*}; s="$b/current/bin/agent-guard"; x=; if [ -n "$r" ]; then x=$(for c in "$b"/*/bin/agent-guard; do [ -x "$c" ] || continue; v=${c%/bin/agent-guard}; printf "%s\\t%s\\n" "${v##*/}" "$c"; done | awk -F "\\t" "\$1 ~ /^[0-9]+\\.[0-9]+\\.[0-9]+$/" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -f 2-); fi; if [ -x "$x" ]; then v=${x%/bin/agent-guard}; v=${v##*/}; if [ ! -e "$b/current" ] || [ -L "$b/current" ]; then ln -sfn "$v" "$b/current" 2>/dev/null || :; fi; [ -L "$b/current" ] && [ -x "$s" ] && x="$s"; fi; if [ ! -x "$x" ] && [ -x "$r/bin/agent-guard" ]; then x="$r/bin/agent-guard"; fi; if [ ! -x "$x" ]; then mode=${AGENT_GUARD_INFRA_FAILURE_MODE:-open}; case "$mode" in closed) action=blocking ;; *) mode=open; action=continuing ;; esac; d=${AGENT_GUARD_WARNING_DIR:-${TMPDIR:-/tmp}/agent-guard-warnings-${UID:-user}}; p=; while IFS= read -r line || [ -n "$line" ]; do p=$p$line; done; i=${AGENT_GUARD_SESSION_ID:-}; if [ -z "$i" ] && command -v jq >/dev/null 2>&1; then i=$(printf %s "$p" | jq -r ".session_id // empty" 2>/dev/null); fi; if [ -z "$i" ]; then case "$p" in *\"session_id\":\"*) i=${p#*\"session_id\":\"}; i=${i%%\"*}; case "$i" in ""|*[!A-Za-z0-9._:-]*) i= ;; esac ;; esac; fi; if [ -n "$i" ]; then i=$(printf %s "$i" | cksum); else i=ppid-${PPID:-0}; fi; k="$d/manifest-@HOST@-$i-$mode"; warn=1; if mkdir -p "$d" 2>/dev/null; then (umask 077; set -C; : >"$k") 2>/dev/null || warn=0; fi; [ "$warn" -eq 0 ] || echo "agent-guard: @ROOT_VAR@ env not set or no installed binary was found; $action because AGENT_GUARD_INFRA_FAILURE_MODE=$mode" >&2; [ "$mode" = closed ] && exit 2; exit 0; fi; AGENT_GUARD_HOOK_HOST=@HOST@ "$x" @SUB@'
EOF
)

render_command() { # $1 = root env var, $2 = host tag, $3 = hook subcommand
  printf '%s\n' "$TEMPLATE" \
    | sed -e "s/@ROOT_VAR@/$1/g" -e "s/@HOST@/$2/g" -e "s/@SUB@/$3/g"
}

render_manifest() { # $1 = root env var, $2 = host tag, $3/$4 = pre/post matcher
  jq -n \
    --arg pre_matcher "$3" \
    --arg post_matcher "$4" \
    --arg pre "$(render_command "$1" "$2" hook-pre-tool)" \
    --arg post "$(render_command "$1" "$2" hook-post-tool)" \
    --arg stop "$(render_command "$1" "$2" hook-stop)" \
    --arg session "$(render_command "$1" "$2" hook-session-start)" \
    '{hooks: {
       PreToolUse: [{matcher: $pre_matcher,
                     hooks: [{type: "command", command: $pre, timeout: 10}]}],
       PostToolUse: [{matcher: $post_matcher,
                      hooks: [{type: "command", command: $post, timeout: 20}]}],
       Stop: [{matcher: "",
               hooks: [{type: "command", command: $stop, timeout: 20}]}],
       SessionStart: [{matcher: "startup|resume|clear|compact",
                       hooks: [{type: "command", command: $session, timeout: 5}]}]
     }}'
}

render_codex() {
  render_manifest PLUGIN_ROOT codex \
    'Bash|apply_patch|mcp__.*' \
    'Bash|apply_patch|mcp__.*'
}

render_claude() {
  render_manifest CLAUDE_PLUGIN_ROOT claude \
    'Write|Edit|MultiEdit|NotebookEdit|Read|NotebookRead|Grep|Glob|Bash|WebFetch|WebSearch|apply_patch|mcp__.*' \
    'Write|Edit|MultiEdit|NotebookEdit|Bash|apply_patch|Read|NotebookRead|Grep|Glob|WebFetch|WebSearch|mcp__.*'
}

case "${1:-write}" in
  write)
    # Render both manifests fully before replacing either committed file, so a
    # failing jq/sed cannot leave a truncated or half-updated pair behind.
    tmp_codex=$(mktemp "$PLUGIN_ROOT/hooks.json.XXXXXX")
    tmp_claude=$(mktemp "$PLUGIN_ROOT/hooks/hooks.json.XXXXXX")
    trap 'rm -f "$tmp_codex" "$tmp_claude"' EXIT INT TERM
    render_codex >"$tmp_codex"
    render_claude >"$tmp_claude"
    chmod 644 "$tmp_codex" "$tmp_claude"
    mv "$tmp_codex" "$PLUGIN_ROOT/hooks.json"
    mv "$tmp_claude" "$PLUGIN_ROOT/hooks/hooks.json"
    printf 'rendered %s and %s\n' \
      "$PLUGIN_ROOT/hooks.json" "$PLUGIN_ROOT/hooks/hooks.json" >&2
    ;;
  --check)
    status=0
    render_codex | diff -u "$PLUGIN_ROOT/hooks.json" - >&2 || status=1
    render_claude | diff -u "$PLUGIN_ROOT/hooks/hooks.json" - >&2 || status=1
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

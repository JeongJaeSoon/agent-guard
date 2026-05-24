#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-layout.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT INT TERM

failures=0

ok() {
  printf 'ok: %s\n' "$1"
}

fail() {
  printf 'not ok: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  if [ -f "$1" ]; then
    ok "$1 exists"
  else
    fail "$1 exists"
  fi
}

require_json() {
  require_file "$1"
  if [ -f "$1" ] && jq -e . "$1" >/dev/null; then
    ok "$1 is valid JSON"
  else
    fail "$1 is valid JSON"
  fi
}

has_generic_plugin_root() {
  printf '%s\n' "$1" | grep -Eq '(^|[^A-Z_])PLUGIN_ROOT([^A-Z_]|$)'
}

validate_hook_commands() {
  manifest=$1
  host=$2
  required=$3

  command_list="$tmpdir/$host-commands.txt"
  jq -r '.hooks | to_entries[] | .value[] | .hooks[]? | select(.type == "command") | .command' "$manifest" >"$command_list"
  if [ -s "$command_list" ]; then
    ok "$host hook commands are declared"
  else
    fail "$host hook commands are declared"
    return
  fi

  while IFS= read -r command; do
    case "$required" in
      PLUGIN_ROOT)
        if has_generic_plugin_root "$command"; then
          ok "$host hook command uses PLUGIN_ROOT"
        else
          fail "$host hook command uses PLUGIN_ROOT"
        fi
        case "$command" in
          *CLAUDE_PLUGIN_ROOT*|*CODEX_PLUGIN_ROOT*) fail "$host hook command avoids CLAUDE_PLUGIN_ROOT and CODEX_PLUGIN_ROOT" ;;
          *) ok "$host hook command avoids CLAUDE_PLUGIN_ROOT and CODEX_PLUGIN_ROOT" ;;
        esac
        ;;
      *)
        case "$command" in
          *"$required"*) ok "$host hook command uses $required" ;;
          *) fail "$host hook command uses $required" ;;
        esac
        case "$command" in
          *CODEX_PLUGIN_ROOT*) fail "$host hook command avoids CODEX_PLUGIN_ROOT" ;;
          *) ok "$host hook command avoids CODEX_PLUGIN_ROOT" ;;
        esac
        if has_generic_plugin_root "$command"; then
          fail "$host hook command avoids generic PLUGIN_ROOT"
        else
          ok "$host hook command avoids generic PLUGIN_ROOT"
        fi
        ;;
    esac
  done <"$command_list"
}

validate_archive_contains() {
  archive=$1
  path=$2

  if grep -Fxq "$path" "$archive.list"; then
    ok "release archive includes $path"
  else
    fail "release archive includes $path"
  fi
}

require_json "$PLUGIN_ROOT/.codex-plugin/plugin.json"
require_json "$PLUGIN_ROOT/hooks.json"
require_json "$PLUGIN_ROOT/hooks/hooks.json"
require_json "$ROOT/.agents/plugins/marketplace.json"
require_json "$ROOT/.claude-plugin/marketplace.json"

if jq -e 'has("hooks") or has("apps") or has("mcpServers")' "$PLUGIN_ROOT/.codex-plugin/plugin.json" >/dev/null; then
  fail "Codex plugin manifest does not declare unsupported companion fields"
else
  ok "Codex plugin manifest does not declare unsupported companion fields"
fi

validate_hook_commands "$PLUGIN_ROOT/hooks.json" "Codex" "PLUGIN_ROOT"
validate_hook_commands "$PLUGIN_ROOT/hooks/hooks.json" "Claude" "CLAUDE_PLUGIN_ROOT"

command_count=0
for command_file in "$PLUGIN_ROOT"/commands/*.md; do
  [ -e "$command_file" ] || continue
  command_count=$((command_count + 1))
  if grep -q 'CLAUDE_PLUGIN_ROOT' "$command_file"; then
    ok "$command_file uses CLAUDE_PLUGIN_ROOT"
  else
    fail "$command_file uses CLAUDE_PLUGIN_ROOT"
  fi
done

if [ "$command_count" -gt 0 ]; then
  ok "Claude slash command markdown files are present"
else
  fail "Claude slash command markdown files are present"
fi

if jq -e '.plugins[] | select(.name == "agent-guard" and .source.path == "./plugins/agent-guard")' "$ROOT/.agents/plugins/marketplace.json" >/dev/null; then
  ok "Codex marketplace points to ./plugins/agent-guard"
else
  fail "Codex marketplace points to ./plugins/agent-guard"
fi

if jq -e '.plugins[] | select(.name == "agent-guard" and .source == "./plugins/agent-guard")' "$ROOT/.claude-plugin/marketplace.json" >/dev/null; then
  ok "Claude marketplace points to ./plugins/agent-guard"
else
  fail "Claude marketplace points to ./plugins/agent-guard"
fi

archive="$tmpdir/agent-guard-validation.tar.gz"

"$ROOT/scripts/build-release-tarball.sh" 0.0.0 "$archive"
tar -tzf "$archive" | sed 's#^\./##' >"$archive.list"

validate_archive_contains "$archive" ".codex-plugin/plugin.json"
validate_archive_contains "$archive" ".claude-plugin/plugin.json"
validate_archive_contains "$archive" "hooks.json"
validate_archive_contains "$archive" "hooks/hooks.json"

archive_command_count=$(find "$PLUGIN_ROOT/commands" -type f -name '*.md' | wc -l | tr -d ' ')
if [ "$archive_command_count" -gt 0 ]; then
  for command_file in "$PLUGIN_ROOT"/commands/*.md; do
    command_name=${command_file#"$PLUGIN_ROOT/"}
    validate_archive_contains "$archive" "$command_name"
  done
else
  fail "release archive has command markdown files to validate"
fi

if [ "$failures" -eq 0 ]; then
  printf 'plugin layout validation passed\n'
else
  printf 'plugin layout validation failed: %s issue(s)\n' "$failures" >&2
  exit 1
fi

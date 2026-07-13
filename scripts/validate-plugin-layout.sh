#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-layout.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT INT TERM

failures=0
run_codex=0
run_claude=0
run_marketplace=0
run_archive=0

usage() {
  printf 'usage: %s [--all|--codex|--claude|--marketplace|--archive]\n' "$0" >&2
}

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

contains_shell_variable_reference() {
  value=$1
  name=$2
  pattern=$(printf '\\$\\{%s([^A-Za-z0-9_]|$)|\\$%s([^A-Za-z0-9_]|$)' "$name" "$name")

  printf '%s\n' "$value" | grep -Eq "($pattern)"
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
        if contains_shell_variable_reference "$command" PLUGIN_ROOT; then
          ok "$host hook command uses PLUGIN_ROOT"
        else
          fail "$host hook command uses PLUGIN_ROOT"
        fi
        if contains_shell_variable_reference "$command" CLAUDE_PLUGIN_ROOT || contains_shell_variable_reference "$command" CODEX_PLUGIN_ROOT; then
          fail "$host hook command avoids CLAUDE_PLUGIN_ROOT and CODEX_PLUGIN_ROOT"
        else
          ok "$host hook command avoids CLAUDE_PLUGIN_ROOT and CODEX_PLUGIN_ROOT"
        fi
        ;;
      *)
        if contains_shell_variable_reference "$command" "$required"; then
          ok "$host hook command uses $required"
        else
          fail "$host hook command uses $required"
        fi
        if contains_shell_variable_reference "$command" CODEX_PLUGIN_ROOT; then
          fail "$host hook command avoids CODEX_PLUGIN_ROOT"
        else
          ok "$host hook command avoids CODEX_PLUGIN_ROOT"
        fi
        if contains_shell_variable_reference "$command" PLUGIN_ROOT; then
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

validate_setup_skill() {
  skill="$PLUGIN_ROOT/skills/setup-agent-guard/SKILL.md"
  metadata="$PLUGIN_ROOT/skills/setup-agent-guard/agents/openai.yaml"

  require_file "$skill"
  require_file "$metadata"
  if [ -f "$skill" ] \
     && [ "$(sed -n '1p' "$skill")" = "---" ] \
     && [ "$(sed -n '2p' "$skill")" = "name: setup-agent-guard" ] \
     && sed -n '3p' "$skill" | grep -Eq '^description: .+' \
     && [ "$(sed -n '4p' "$skill")" = "---" ]; then
    ok "setup-agent-guard skill has valid required frontmatter"
  else
    fail "setup-agent-guard skill has valid required frontmatter"
  fi
  if [ -f "$metadata" ] \
     && grep -Eq '^[[:space:]]*display_name:[[:space:]]+"?.+"?$' "$metadata" \
     && grep -Eq '^[[:space:]]*short_description:[[:space:]]+"?.+"?$' "$metadata" \
     && grep -Fq '$setup-agent-guard' "$metadata"; then
    ok "setup-agent-guard UI metadata is complete"
  else
    fail "setup-agent-guard UI metadata is complete"
  fi
}

validate_codex() {
  require_json "$PLUGIN_ROOT/.codex-plugin/plugin.json"
  require_json "$PLUGIN_ROOT/hooks.json"
  validate_setup_skill

  if jq -e '.hooks == "./hooks.json" and .skills == "./skills/"' "$PLUGIN_ROOT/.codex-plugin/plugin.json" >/dev/null; then
    ok "Codex plugin manifest declares hook and skill paths"
  else
    fail "Codex plugin manifest declares hook and skill paths"
  fi

  validate_hook_commands "$PLUGIN_ROOT/hooks.json" "Codex" "PLUGIN_ROOT"
}

validate_claude() {
  require_json "$PLUGIN_ROOT/hooks/hooks.json"
  validate_hook_commands "$PLUGIN_ROOT/hooks/hooks.json" "Claude" "CLAUDE_PLUGIN_ROOT"

  command_count=0
  for command_file in "$PLUGIN_ROOT"/commands/*.md; do
    [ -e "$command_file" ] || continue
    command_count=$((command_count + 1))
    if grep -Eq '(\$\{CLAUDE_PLUGIN_ROOT([^A-Za-z0-9_]|$)|\$CLAUDE_PLUGIN_ROOT([^A-Za-z0-9_]|$))' "$command_file"; then
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
}

validate_marketplace() {
  require_json "$ROOT/.agents/plugins/marketplace.json"
  require_json "$ROOT/.claude-plugin/marketplace.json"

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
}

validate_archive() {
  archive="$tmpdir/agent-guard-validation.tar.gz"

  "$ROOT/scripts/build-release-tarball.sh" 0.0.0 "$archive"
  tar -tzf "$archive" | sed 's#^\./##' >"$archive.list"

  validate_archive_contains "$archive" ".codex-plugin/plugin.json"
  validate_archive_contains "$archive" ".claude-plugin/plugin.json"
  validate_archive_contains "$archive" "hooks.json"
  validate_archive_contains "$archive" "hooks/hooks.json"
  validate_archive_contains "$archive" "skills/setup-agent-guard/SKILL.md"
  validate_archive_contains "$archive" "skills/setup-agent-guard/agents/openai.yaml"

  if [ -d "$PLUGIN_ROOT/commands" ]; then
    archive_command_count=$(find "$PLUGIN_ROOT/commands" -type f -name '*.md' | wc -l | tr -d ' ')
  else
    archive_command_count=0
  fi
  if [ "$archive_command_count" -gt 0 ]; then
    for command_file in "$PLUGIN_ROOT"/commands/*.md; do
      command_name=${command_file#"$PLUGIN_ROOT/"}
      validate_archive_contains "$archive" "$command_name"
    done
  else
    fail "release archive has command markdown files to validate"
  fi
}

if [ "$#" -eq 0 ]; then
  run_codex=1
  run_claude=1
  run_marketplace=1
  run_archive=1
fi

for mode in "$@"; do
  case "$mode" in
    --all)
      run_codex=1
      run_claude=1
      run_marketplace=1
      run_archive=1
      ;;
    --codex) run_codex=1 ;;
    --claude) run_claude=1 ;;
    --marketplace) run_marketplace=1 ;;
    --archive) run_archive=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ "$run_codex" -eq 1 ] && validate_codex
[ "$run_claude" -eq 1 ] && validate_claude
[ "$run_marketplace" -eq 1 ] && validate_marketplace
[ "$run_archive" -eq 1 ] && validate_archive

if [ "$failures" -eq 0 ]; then
  printf 'plugin layout validation passed\n'
else
  printf 'plugin layout validation failed: %s issue(s)\n' "$failures" >&2
  exit 1
fi

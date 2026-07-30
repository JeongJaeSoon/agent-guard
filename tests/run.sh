#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
TMP_ROOT=${TMPDIR:-/tmp}/agent-guard-tests.$$
# Unique, non-predictable temp files for hook stdout/stderr capture. Using a
# mktemp-created directory (instead of fixed /tmp/... paths) avoids the
# insecure-temp-file / TOCTOU class (CWE-377): a local actor cannot pre-create
# or symlink a known path to race or corrupt the contents, and parallel runs of
# this suite no longer collide.
TESTTMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-test.XXXXXX")
OUT="$TESTTMP/out"
ERR="$TESTTMP/err"
MOCK_BIN="$TMP_ROOT/bin"
ORIGINAL_PATH=$PATH
REAL_GITLEAKS=$(command -v gitleaks 2>/dev/null || true)
REAL_GIT=$(command -v git)
REAL_CAT=$(command -v cat)
REAL_CURL=$(command -v curl 2>/dev/null || true)
REAL_JQ=$(command -v jq)
REAL_SH=$(command -v sh)
REAL_DIRNAME=$(command -v dirname)
REAL_PWD=$(command -v pwd)
PATH="$MOCK_BIN:$PATH"
export PATH
export AGENT_GUARD_GITLEAKS_CONFIG="$PLUGIN_ROOT/config/gitleaks.toml"

# Isolate git from the developer's global config so inherited values like
# core.hooksPath or init.templateDir cannot leak into freshly-initialised
# repos and silently invalidate the install.sh safety tests.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

pass=0
fail=0

say() {
  printf '%s\n' "$*"
}

ok() {
  pass=$((pass + 1))
  say "ok - $*"
}

not_ok() {
  fail=$((fail + 1))
  say "not ok - $*"
}

run_expect() {
  expected=$1
  name=$2
  shift 2
  "$@" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    ok "$name"
  else
    not_ok "$name (expected $expected, got $status)"
    sed 's/^/  stdout: /' "$OUT"
    sed 's/^/  stderr: /' "$ERR"
  fi
}

json_to() {
  printf '%s' "$1" | "$PLUGIN_ROOT/bin/agent-guard" "$2" >"$OUT" 2>"$ERR"
}

expect_json_status() {
  expected=$1
  name=$2
  json=$3
  cmd=$4
  json_to "$json" "$cmd"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    ok "$name"
  else
    not_ok "$name (expected $expected, got $status)"
    sed 's/^/  stdout: /' "$OUT"
    sed 's/^/  stderr: /' "$ERR"
  fi
}

cleanup() {
  rm -rf "$TMP_ROOT" "$TESTTMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$MOCK_BIN"

if [ ! -e "$PLUGIN_ROOT/commands/setup-shell.md" ]; then
  ok "setup-shell has a single skill implementation"
else
  not_ok "setup-shell has a single skill implementation"
fi

setup_shell_skill="$PLUGIN_ROOT/skills/setup-shell/SKILL.md"
setup_shell_metadata="$PLUGIN_ROOT/skills/setup-shell/agents/openai.yaml"
if grep -Fq '../../bin/agent-guard' "$setup_shell_skill" \
  && grep -Fq 'Obtain host approval' "$setup_shell_skill" \
  && grep -Fq 'is separate from plugin' "$setup_shell_skill" \
  && grep -Fq 'Do not retry the same blocked write' "$setup_shell_skill" \
  && grep -Fq 'terminal, wait for confirmation' "$setup_shell_skill" \
  && grep -Fq 'restart the shell' "$setup_shell_skill" \
  && grep -Fq 'agent sessions launched from that shell' "$setup_shell_skill" \
  && ! grep -Eq 'Claude Code|Codex' "$setup_shell_skill" \
  && ! grep -Eq 'Claude Code|Codex' "$setup_shell_metadata"; then
  ok "setup-shell skill stays host-neutral with approval and fallback guidance"
else
  not_ok "setup-shell skill stays host-neutral with approval and fallback guidance"
fi
cp "$ROOT/tests/fixtures/mock-gitleaks" "$MOCK_BIN/gitleaks"
chmod +x "$MOCK_BIN/gitleaks"

for file in \
  "$PLUGIN_ROOT/bin/agent-guard" \
  "$ROOT/install.sh" \
  "$ROOT/bootstrap.sh" \
  "$ROOT/scripts/build-release-tarball.sh" \
  "$ROOT/githooks/pre-commit" \
  "$PLUGIN_ROOT/scripts/gitleaks-checksum.sh" \
  "$ROOT/tests/run.sh"; do
  run_expect 0 "shell syntax: $file" sh -n "$file"
done

if grep -Fq 'AGENT_GUARD_PII_HOOK_MODE' "$ROOT/deployment/claude-managed-settings.example.json"; then
  not_ok "managed Claude settings do not force the opt-in PII hook mode"
else
  ok "managed Claude settings do not force the opt-in PII hook mode"
fi

if [ "$(jq -r '.extraKnownMarketplaces["agent-guard"].autoUpdate' "$ROOT/deployment/claude-managed-settings.example.json")" = "false" ]; then
  ok "managed Claude settings require an intentional marketplace update"
else
  not_ok "managed Claude settings require an intentional marketplace update"
fi
if [ "$(jq -r '.extraKnownMarketplaces["agent-guard"].source.sha // "missing"' "$ROOT/deployment/claude-managed-settings.example.json")" = "missing" ]; then
  ok "managed Claude settings do not claim unsupported marketplace SHA pinning"
else
  not_ok "managed Claude settings do not claim unsupported marketplace SHA pinning"
fi

# The direct installer must leave command wrapping active on a fresh install,
# while AGENT_GUARD_COMMAND_WRAPPING=off is a persistent install-time opt-out.
# Stub only the release downloads; archive verification, extraction, linking,
# setup-shell, and rc generation all run through the real implementation.
bootstrap_fixture="$TESTTMP/bootstrap-fixture"
mkdir -p "$bootstrap_fixture/bin"
"$ROOT/scripts/build-release-tarball.sh" 2.0.0 "$bootstrap_fixture/agent-guard-2.0.0.tar.gz"
(
  cd "$bootstrap_fixture" || exit 1
  shasum -a 256 agent-guard-2.0.0.tar.gz >agent-guard-2.0.0.tar.gz.sha256
)
cat >"$bootstrap_fixture/bin/curl" <<'STUB'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; out=${1:-} ;;
  esac
  shift
done
case "$out" in
  *.tar.gz) cp "$BOOTSTRAP_FIXTURE/agent-guard-2.0.0.tar.gz" "$out" ;;
  *.tar.gz.sha256) cp "$BOOTSTRAP_FIXTURE/agent-guard-2.0.0.tar.gz.sha256" "$out" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$bootstrap_fixture/bin/curl"

for bootstrap_mode in on off; do
  bootstrap_home="$TESTTMP/bootstrap-$bootstrap_mode"
  mkdir -p "$bootstrap_home"
  if [ "$bootstrap_mode" = off ]; then
    bootstrap_toggle=off
  else
    bootstrap_toggle=on
  fi
  BOOTSTRAP_FIXTURE="$bootstrap_fixture" \
  AGENT_GUARD_VERSION=2.0.0 \
  AGENT_GUARD_HOME="$bootstrap_home/agent-guard" \
  AGENT_GUARD_BIN_DIR="$bootstrap_home/bin" \
  AGENT_GUARD_COMMAND_WRAPPING="$bootstrap_toggle" \
  HOME="$bootstrap_home" SHELL=/bin/zsh \
  PATH="$bootstrap_fixture/bin:/usr/bin:/bin" \
    sh "$ROOT/bootstrap.sh" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ] && [ -x "$bootstrap_home/bin/agent-guard" ]; then
    ok "bootstrap installs Agent Guard with command wrapping $bootstrap_mode"
  else
    not_ok "bootstrap installs Agent Guard with command wrapping $bootstrap_mode (status $status)"
  fi
  if [ "$bootstrap_mode" = on ]; then
    if grep -q 'agent-guard shell-init' "$bootstrap_home/.zshrc" 2>/dev/null \
       && ! grep -q -- '--no-command-wrapping' "$bootstrap_home/.zshrc" 2>/dev/null; then
      ok "bootstrap enables command wrapping by default"
    else
      not_ok "bootstrap enables command wrapping by default"
    fi
  elif grep -q 'shell-init --no-command-wrapping' "$bootstrap_home/.zshrc" 2>/dev/null; then
    ok "bootstrap persists AGENT_GUARD_COMMAND_WRAPPING=off"
  else
    not_ok "bootstrap persists AGENT_GUARD_COMMAND_WRAPPING=off"
  fi
done

for file in \
  "$PLUGIN_ROOT/hooks.json" \
  "$PLUGIN_ROOT/hooks/hooks.json" \
  "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  "$ROOT/.claude-plugin/marketplace.json" \
  "$PLUGIN_ROOT/.codex-plugin/plugin.json" \
  "$ROOT/.agents/plugins/marketplace.json" \
  "$ROOT/examples/claude/settings.project.json" \
  "$ROOT/examples/codex/hooks.json" \
  "$ROOT/deployment/claude-managed-settings.example.json"; do
  run_expect 0 "json syntax: $file" jq -e . "$file"
done

if grep -Fq 'legacy_v1_before=$(git ls-remote origin refs/tags/v1' "$ROOT/.github/workflows/release.yml" \
   && grep -Fq 'legacy_v1_after=$(git ls-remote origin refs/tags/v1' "$ROOT/.github/workflows/release.yml" \
   && grep -Fq 'if [ "$legacy_v1_after" != "$legacy_v1_before" ]' "$ROOT/.github/workflows/release.yml"; then
  ok "release automation preserves the v1 moving tag when publishing v2+"
else
  not_ok "release automation preserves the v1 moving tag when publishing v2+"
fi

if jq -e '.hooks == "./hooks.json" and .skills == "./skills/"' "$PLUGIN_ROOT/.codex-plugin/plugin.json" >/dev/null; then
  ok "Codex plugin manifest explicitly declares hook and skill paths"
else
  not_ok "Codex plugin manifest explicitly declares hook and skill paths"
fi

# Guided setup must verify the installed plugin itself and select the active
# host's live hook boundary. A standalone PATH binary or a passing binary smoke
# test is not proof that plugin hooks are trusted or dispatched by either host.
setup_skill="$PLUGIN_ROOT/skills/setup-agent-guard/SKILL.md"
if grep -Fq '../../bin/agent-guard' "$setup_skill" \
   && grep -Fq 'Compare its `version` with the plugin binary' "$setup_skill" \
   && grep -Fq 'Identify the active host' "$setup_skill" \
   && grep -Fq 'Settings > Hooks' "$setup_skill" \
   && grep -Fq '`Untrusted` and `Modified` as inactive' "$setup_skill" \
   && grep -Fq 'Claude Code does not use that trust workflow' "$setup_skill" \
   && grep -Fq 'normal `Bash` tool' "$setup_skill" \
   && grep -Fq 'Do not apply one host' "$setup_skill" \
   && grep -Fq 'AGENT_GUARD_LIVE_PRE_TOOL_PROBE' "$setup_skill" \
   && grep -Fq 'AGENT_GUARD_LIVE_POST_TOOL_PROBE' "$setup_skill" \
   && ! grep -Fq 'cat .env' "$setup_skill" \
   && grep -Fq '`functions.exec`' "$setup_skill" \
   && grep -Fq 'blocked by the host sandbox' "$setup_skill" \
   && grep -Fq 'Do not retry the same blocked write' "$setup_skill" \
   && grep -Fq 'run in a separate terminal' "$setup_skill" \
   && grep -Fq 'rerun the read-only' "$setup_skill" \
   && grep -Fq 'They do not prove that the host is dispatching plugin hooks' "$setup_skill"; then
  ok "shared setup skill selects host-specific trust and live-hook layers"
else
  not_ok "shared setup skill selects host-specific trust and live-hook layers"
fi

for event in PreToolUse PostToolUse Stop; do
  claude_canonical=$(jq -r ".hooks.${event}[0].matcher" "$PLUGIN_ROOT/hooks/hooks.json")
  codex_canonical=$(jq -r ".hooks.${event}[0].matcher" "$PLUGIN_ROOT/hooks.json")
  claude_example=$(jq -r ".hooks.${event}[0].matcher" "$ROOT/examples/claude/settings.project.json")
  codex_example=$(jq -r ".hooks.${event}[0].matcher" "$ROOT/examples/codex/hooks.json")
  [ "$claude_example" = "$claude_canonical" ] \
    && ok "$event matcher in Claude example matches Claude plugin hooks" \
    || not_ok "$event matcher in Claude example matches Claude plugin hooks (got: $claude_example)"
  [ "$codex_example" = "$codex_canonical" ] \
    && ok "$event matcher in Codex example matches Codex plugin hooks" \
    || not_ok "$event matcher in Codex example matches Codex plugin hooks (got: $codex_example)"
done

# Full hook-object parity: type, timeout, and the trailing hook-* subcommand
# must agree across all four manifests. Command STRINGS legitimately differ by
# host (CLAUDE_PLUGIN_ROOT vs PLUGIN_ROOT vs relative/absolute paths), so only
# the stable trailing subcommand token is compared, not the whole command. This
# catches a copy-paste swap (e.g. Stop wired to hook-post-tool, or a 10/20
# timeout mismatch) that the matcher-only check above misses.
hook_subcommand() {
  jq -r ".hooks.${2}[0].hooks[0].command" "$1" \
    | grep -oE 'hook-(pre-tool|post-tool|stop)' | tail -n1
}

for event in PreToolUse PostToolUse Stop; do
  case "$event" in
    PreToolUse)  expected_sub=hook-pre-tool;  expected_timeout=10 ;;
    PostToolUse) expected_sub=hook-post-tool; expected_timeout=20 ;;
    Stop)        expected_sub=hook-stop;      expected_timeout=20 ;;
  esac

  claude_type=$(jq -r ".hooks.${event}[0].hooks[0].type" "$PLUGIN_ROOT/hooks/hooks.json")
  claude_timeout=$(jq -r ".hooks.${event}[0].hooks[0].timeout" "$PLUGIN_ROOT/hooks/hooks.json")
  claude_sub=$(hook_subcommand "$PLUGIN_ROOT/hooks/hooks.json" "$event")

  if [ "$claude_type" = "command" ]; then
    ok "$event hook type is command in hooks/hooks.json"
  else
    not_ok "$event hook type is command in hooks/hooks.json (got: $claude_type)"
  fi
  if [ "$claude_timeout" = "$expected_timeout" ]; then
    ok "$event timeout is $expected_timeout in hooks/hooks.json"
  else
    not_ok "$event timeout is $expected_timeout in hooks/hooks.json (got: $claude_timeout)"
  fi
  if [ "$claude_sub" = "$expected_sub" ]; then
    ok "$event command invokes $expected_sub in hooks/hooks.json"
  else
    not_ok "$event command invokes $expected_sub in hooks/hooks.json (got: $claude_sub)"
  fi

  for file in \
    "$PLUGIN_ROOT/hooks.json" \
    "$ROOT/examples/claude/settings.project.json" \
    "$ROOT/examples/codex/hooks.json"; do
    actual_type=$(jq -r ".hooks.${event}[0].hooks[0].type" "$file")
    actual_timeout=$(jq -r ".hooks.${event}[0].hooks[0].timeout" "$file")
    actual_sub=$(hook_subcommand "$file" "$event")
    if [ "$actual_type" = "$claude_type" ]; then
      ok "$event hook type in $file matches hooks/hooks.json"
    else
      not_ok "$event hook type in $file matches hooks/hooks.json (got: $actual_type)"
    fi
    if [ "$actual_timeout" = "$claude_timeout" ]; then
      ok "$event timeout in $file matches hooks/hooks.json"
    else
      not_ok "$event timeout in $file matches hooks/hooks.json (got: $actual_timeout)"
    fi
    if [ "$actual_sub" = "$claude_sub" ]; then
      ok "$event command subcommand in $file matches hooks/hooks.json"
    else
      not_ok "$event command subcommand in $file matches hooks/hooks.json (got: $actual_sub)"
    fi
  done
done

# SessionStart reports dependency readiness on both hosts and version drift for
# the Claude shell integration.
ss_hook_matcher=$(jq -r '.hooks.SessionStart[0].matcher' "$PLUGIN_ROOT/hooks/hooks.json")
ss_hook_command=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")
ss_hook_timeout=$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$PLUGIN_ROOT/hooks/hooks.json")
if [ "$ss_hook_matcher" = "startup|resume|clear|compact" ]; then
  ok "SessionStart matcher covers startup/resume/clear/compact in hooks/hooks.json"
else
  not_ok "SessionStart matcher covers startup/resume/clear/compact in hooks/hooks.json (got: $ss_hook_matcher)"
fi
codex_ss_matcher=$(jq -r '.hooks.SessionStart[0].matcher' "$PLUGIN_ROOT/hooks.json")
[ "$codex_ss_matcher" = "$ss_hook_matcher" ] \
  && ok "Codex SessionStart matcher matches the supported lifecycle set" \
  || not_ok "Codex SessionStart matcher matches the supported lifecycle set (got: $codex_ss_matcher)"
case "$ss_hook_command" in
  *'CLAUDE_PLUGIN_ROOT'*'/current/bin/agent-guard'*'hook-session-start'*)
    ok "SessionStart command resolves hook-session-start through the stable current path" ;;
  *)
    not_ok "SessionStart command resolves hook-session-start through the stable current path (got: $ss_hook_command)" ;;
esac
if [ "$ss_hook_timeout" = 5 ]; then
  ok "SessionStart timeout is 5 in hooks/hooks.json"
else
  not_ok "SessionStart timeout is 5 in hooks/hooks.json (got: $ss_hook_timeout)"
fi

claude_pre_tool_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")
case "$claude_pre_tool_command" in
  *'CLAUDE_PLUGIN_ROOT'*'/current/bin/agent-guard'*'awk -F'*'/^[0-9]+'*'/bin/agent-guard'*)
    ok "Claude hook command uses the stable current path with a version-glob fallback"
    ;;
  *)
    not_ok "Claude hook command uses the stable current path with a version-glob fallback"
    ;;
esac
case "$claude_pre_tool_command" in
  *'CODEX_PLUGIN_ROOT'*|*'${PLUGIN_ROOT'*)
    not_ok "Claude hook command does not depend on Codex or generic plugin root env vars"
    ;;
  *)
    ok "Claude hook command does not depend on Codex or generic plugin root env vars"
    ;;
esac

codex_pre_tool_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_ROOT/hooks.json")
case "$codex_pre_tool_command" in
  *'PLUGIN_ROOT'*'/current/bin/agent-guard'*'awk -F'*'/^[0-9]+'*'/bin/agent-guard'*)
    ok "Codex hook command uses the stable current path with a version-glob fallback"
    ;;
  *)
    not_ok "Codex hook command uses the stable current path with a version-glob fallback"
    ;;
esac
case "$codex_pre_tool_command" in
  *'CLAUDE_PLUGIN_ROOT'*|*'CODEX_PLUGIN_ROOT'*)
    not_ok "Codex hook command does not depend on host-specific plugin root env vars"
    ;;
  *)
    ok "Codex hook command does not depend on host-specific plugin root env vars"
    ;;
esac

read_env_payload='{"tool_name":"Read","tool_input":{"file_path":".env"}}'
printf '%s' "$read_env_payload" \
  | (cd "$PLUGIN_ROOT" && env -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT sh -c "$claude_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ]; then
  ok "Claude hook command follows the default open infrastructure policy without CLAUDE_PLUGIN_ROOT"
else
  not_ok "Claude hook command follows the default open infrastructure policy without CLAUDE_PLUGIN_ROOT (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
if grep -q 'CLAUDE_PLUGIN_ROOT env not set' "$ERR"; then
  ok "Claude hook command explains missing CLAUDE_PLUGIN_ROOT"
else
  not_ok "Claude hook command explains missing CLAUDE_PLUGIN_ROOT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$PLUGIN_ROOT" && AGENT_GUARD_INFRA_FAILURE_MODE=closed env -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT sh -c "$claude_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Claude hook command supports opt-in closed infrastructure policy"
else
  not_ok "Claude hook command supports opt-in closed infrastructure policy (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$claude_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Claude hook command honors CLAUDE_PLUGIN_ROOT"
else
  not_ok "Claude hook command honors CLAUDE_PLUGIN_ROOT (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$claude_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if grep -q 'CLAUDE_PLUGIN_ROOT env not set' "$ERR"; then
  ok "Claude hook command ignores CODEX_PLUGIN_ROOT"
else
  not_ok "Claude hook command ignores CODEX_PLUGIN_ROOT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$PLUGIN_ROOT" && env -u PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT sh -c "$codex_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ]; then
  ok "Codex hook command follows the default open infrastructure policy without PLUGIN_ROOT"
else
  not_ok "Codex hook command follows the default open infrastructure policy without PLUGIN_ROOT (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
if grep -q 'PLUGIN_ROOT env not set' "$ERR"; then
  ok "Codex hook command explains missing PLUGIN_ROOT"
else
  not_ok "Codex hook command explains missing PLUGIN_ROOT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$PLUGIN_ROOT" && AGENT_GUARD_INFRA_FAILURE_MODE=closed env -u PLUGIN_ROOT -u CODEX_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT sh -c "$codex_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Codex hook command supports opt-in closed infrastructure policy"
else
  not_ok "Codex hook command supports opt-in closed infrastructure policy (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$codex_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Codex hook command honors PLUGIN_ROOT"
else
  not_ok "Codex hook command honors PLUGIN_ROOT (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$codex_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if grep -q 'PLUGIN_ROOT env not set' "$ERR"; then
  ok "Codex hook command ignores CODEX_PLUGIN_ROOT"
else
  not_ok "Codex hook command ignores CODEX_PLUGIN_ROOT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$codex_pre_tool_command") \
  >"$OUT" 2>"$ERR"
status=$?
if grep -q 'PLUGIN_ROOT env not set' "$ERR"; then
  ok "Codex hook command ignores CLAUDE_PLUGIN_ROOT"
else
  not_ok "Codex hook command ignores CLAUDE_PLUGIN_ROOT"
  sed 's/^/  stderr: /' "$ERR"
fi

# A stale hook can retain a removed version directory in PLUGIN_ROOT. The
# manifest-level resolver must select the highest installed semantic version,
# not rely on lexical glob order (where 3.0.9 sorts after 3.0.10).
HOOK_CACHE="$TESTTMP/hook-cache"
for hook_ver in 3.0.9 3.0.10 99.0.0beta; do
  mkdir -p "$HOOK_CACHE/$hook_ver/bin"
  cat >"$HOOK_CACHE/$hook_ver/bin/agent-guard" <<EOF
#!/usr/bin/env sh
printf '%s\n' 'selected-$hook_ver'
EOF
  chmod +x "$HOOK_CACHE/$hook_ver/bin/agent-guard"
done
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo clean"}}' \
  | PLUGIN_ROOT="$HOOK_CACHE/3.0.0" sh -c "$codex_pre_tool_command" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -qx 'selected-3.0.10' "$OUT" \
   && [ "$(readlink "$HOOK_CACHE/current" 2>/dev/null)" = 3.0.10 ]; then
  ok "Codex hook resolver falls back from a removed version to the latest installed version"
else
  not_ok "Codex hook resolver falls back from a removed version to the latest installed version"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

cat >"$HOOK_CACHE/3.0.10/bin/agent-guard" <<'EOF'
#!/usr/bin/env sh
cat
EOF
chmod +x "$HOOK_CACHE/3.0.10/bin/agent-guard"
manifest_payload='{"session_id":"manifest-input","tool_name":"Bash","tool_input":{"command":"echo clean"}}'
for manifest_host in codex claude; do
  case "$manifest_host" in
    codex) manifest_file="$PLUGIN_ROOT/hooks.json"; manifest_root=PLUGIN_ROOT ;;
    *) manifest_file="$PLUGIN_ROOT/hooks/hooks.json"; manifest_root=CLAUDE_PLUGIN_ROOT ;;
  esac
  manifest_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$manifest_file")
  printf '%s' "$manifest_payload" \
    | env "$manifest_root=$HOOK_CACHE/3.0.0" sh -c "$manifest_command" >"$OUT" 2>"$ERR"
  if [ "$(cat "$OUT")" = "$manifest_payload" ]; then
    ok "$manifest_host manifest resolver preserves hook input when a binary exists"
  else
    not_ok "$manifest_host manifest resolver preserves hook input when a binary exists"
    sed 's/^/  stdout: /' "$OUT"
    sed 's/^/  stderr: /' "$ERR"
  fi
done

MANIFEST_NO_JQ_PATH="$TESTTMP/manifest-no-jq-path"
mkdir -p "$MANIFEST_NO_JQ_PATH"
for manifest_utility in sh awk sort tail cut cksum mkdir; do
  manifest_utility_path=$(command -v "$manifest_utility")
  ln -s "$manifest_utility_path" "$MANIFEST_NO_JQ_PATH/$manifest_utility"
done

# When no binary resolves, every event shares one best-effort host/session
# marker. The warning names the selected policy, including closed mode.
for manifest_host in codex claude; do
  case "$manifest_host" in
    codex) manifest_file="$PLUGIN_ROOT/hooks.json"; manifest_root=PLUGIN_ROOT ;;
    *) manifest_file="$PLUGIN_ROOT/hooks/hooks.json"; manifest_root=CLAUDE_PLUGIN_ROOT ;;
  esac
  manifest_warning_dir="$TESTTMP/manifest-warning-$manifest_host"
  : >"$ERR"
  for manifest_event in PreToolUse PostToolUse Stop SessionStart; do
    manifest_command=$(jq -r --arg event "$manifest_event" '.hooks[$event][0].hooks[0].command' "$manifest_file")
    printf '%s' '{"session_id":"manifest-session"}' \
      | env "$manifest_root=$TESTTMP/missing-plugin/0.0.0" \
          AGENT_GUARD_WARNING_DIR="$manifest_warning_dir" \
          sh -c "$manifest_command; :" >/dev/null 2>>"$ERR"
  done
  warning_count=$(grep -c 'no installed binary was found' "$ERR" 2>/dev/null || true)
  if [ "$warning_count" -eq 1 ] && grep -q 'AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
    ok "$manifest_host manifest warning is deduplicated by session across Linux-like changing parents"
  else
    not_ok "$manifest_host manifest warning is session-deduplicated across changing parents (count $warning_count)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  : >"$ERR"
  for override_event in PreToolUse PostToolUse; do
    manifest_command=$(jq -r --arg event "$override_event" '.hooks[$event][0].hooks[0].command' "$manifest_file")
    printf '{"session_id":"payload-%s"}' "$override_event" \
      | env "$manifest_root=$TESTTMP/missing-plugin/0.0.0" \
          AGENT_GUARD_SESSION_ID=manifest-override \
          AGENT_GUARD_WARNING_DIR="$TESTTMP/manifest-override-$manifest_host" \
          sh -c "$manifest_command; :" >/dev/null 2>>"$ERR"
  done
  override_warning_count=$(grep -c 'no installed binary was found' "$ERR" 2>/dev/null || true)
  if [ "$override_warning_count" -eq 1 ]; then
    ok "$manifest_host manifest warning honors AGENT_GUARD_SESSION_ID override"
  else
    not_ok "$manifest_host manifest warning honors AGENT_GUARD_SESSION_ID override (count $override_warning_count)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  : >"$ERR"
  for no_jq_event in PreToolUse PostToolUse Stop SessionStart; do
    manifest_command=$(jq -r --arg event "$no_jq_event" '.hooks[$event][0].hooks[0].command' "$manifest_file")
    printf '%s' '{"session_id":"manifest-no-jq"}' \
      | env PATH="$MANIFEST_NO_JQ_PATH" \
          "$manifest_root=$TESTTMP/missing-plugin/0.0.0" \
          AGENT_GUARD_WARNING_DIR="$TESTTMP/manifest-no-jq-$manifest_host" \
          /bin/sh -c "$manifest_command; :" >/dev/null 2>>"$ERR"
  done
  no_jq_warning_count=$(grep -c 'no installed binary was found' "$ERR" 2>/dev/null || true)
  if [ "$no_jq_warning_count" -eq 1 ]; then
    ok "$manifest_host manifest warning uses compact session_id without jq"
  else
    not_ok "$manifest_host manifest warning uses compact session_id without jq (count $no_jq_warning_count)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  manifest_command=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$manifest_file")
  printf '%s' '{}' \
    | env "$manifest_root=$TESTTMP/missing-plugin/0.0.0" \
        AGENT_GUARD_WARNING_DIR="$TESTTMP/manifest-closed-$manifest_host" \
        AGENT_GUARD_INFRA_FAILURE_MODE=closed \
        sh -c "$manifest_command" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ] && grep -q 'blocking because AGENT_GUARD_INFRA_FAILURE_MODE=closed' "$ERR"; then
    ok "$manifest_host manifest missing-binary warning reports closed mode"
  else
    not_ok "$manifest_host manifest missing-binary warning reports closed mode (status $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi
done

# Pinned gitleaks default version is duplicated across three surfaces (the
# CLI's setup --install default, the checksum helper's lookup default, and
# the GitHub Action input default). They must stay in lock-step; otherwise
# a user who copies the checksum from one channel into another silently
# installs a different binary than the bundled rules expect.
bin_ver=$(awk -F= '/^GITLEAKS_DEFAULT_VERSION=/ {print $2; exit}' "$PLUGIN_ROOT/bin/agent-guard")
script_ver=$(awk -F= '/^DEFAULT_VERSION=/ {print $2; exit}' "$PLUGIN_ROOT/scripts/gitleaks-checksum.sh")
action_ver=$(awk '
  /^[[:space:]]*gitleaks-version:/ { in_block=1; next }
  in_block && /^[[:space:]]*default:/ {
    sub(/.*default:[[:space:]]*/, "")
    sub(/[[:space:]]+#.*/, "")
    gsub(/"/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    print
    exit
  }
' "$ROOT/action.yml")
if [ -n "$bin_ver" ] && [ "$bin_ver" = "$script_ver" ] && [ "$bin_ver" = "$action_ver" ]; then
  ok "gitleaks default version in sync across bin/agent-guard, gitleaks-checksum.sh, and action.yml ($bin_ver)"
else
  not_ok "gitleaks default version drift: bin=$bin_ver script=$script_ver action=$action_ver"
fi

# Release version is consumed independently by both plugin hosts and the Claude
# marketplace. Keep every published surface aligned with the executable, and
# require the latest changelog entry to describe that same release.
plugin_ver=$(awk -F= '/^VERSION=/ {print $2; exit}' "$PLUGIN_ROOT/bin/agent-guard")
claude_ver=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")
codex_ver=$(jq -r '.version' "$PLUGIN_ROOT/.codex-plugin/plugin.json")
market_ver=$(jq -r '.plugins[] | select(.name == "agent-guard") | .version' "$ROOT/.claude-plugin/marketplace.json")
managed_claude_ref=$(jq -r '.extraKnownMarketplaces["agent-guard"].source.ref' "$ROOT/deployment/claude-managed-settings.example.json")
changelog_ver=$(sed -n 's/^## v\([^ ]*\) .*/\1/p' "$ROOT/CHANGELOG.md" | head -n1)
if [ -n "$plugin_ver" ] && [ "$plugin_ver" = "$claude_ver" ] \
   && [ "$plugin_ver" = "$codex_ver" ] && [ "$plugin_ver" = "$market_ver" ] \
   && [ "v$plugin_ver" = "$managed_claude_ref" ] \
   && [ "$plugin_ver" = "$changelog_ver" ]; then
  ok "release version in sync across binary, plugin manifests, marketplace, managed settings, and changelog ($plugin_ver)"
else
  not_ok "release version drift: bin=$plugin_ver claude=$claude_ver codex=$codex_ver marketplace=$market_ver managed=$managed_claude_ref changelog=$changelog_ver"
fi

# --- submission-readiness pinned-SHA drift ---------------------------------
# The official marketplace entry template pins .source.sha, but validating only
# its 40-hex format lets the pin rot: reviewers approve one snapshot while the
# payload silently moves on. Build a self-contained mirror of the current tree
# (running THIS worktree's copy of the validator, which carries the fix) so we
# can drive the pin to a matching, stale, and absent commit deterministically,
# without touching the repo's real pinned value.
SUBMIRROR="$TMP_ROOT/submission-mirror"
SUBENTRY="$SUBMIRROR/docs/submission/claude-plugins-official/marketplace-entry.template.json"
SUBVALIDATOR="$SUBMIRROR/scripts/validate-submission-readiness.sh"
mkdir -p "$SUBMIRROR"
if git -C "$ROOT" archive HEAD | tar -x -C "$SUBMIRROR" 2>/dev/null; then
  # Run the working-tree validator (the fix under test), not HEAD's committed copy.
  cp "$ROOT/scripts/validate-submission-readiness.sh" "$SUBVALIDATOR"
  (
    cd "$SUBMIRROR" || exit 2
    git init -q
    git config user.email test@example.com
    git config user.name test
    git add -A
    git commit -q -m mirror-base
  )
  match_sha=$(git -C "$SUBMIRROR" rev-parse HEAD)
  # Pin the template at the current HEAD → tree matches payload → must pass.
  jq --arg sha "$match_sha" '.source.sha = $sha' "$SUBENTRY" >"$SUBENTRY.tmp" && mv "$SUBENTRY.tmp" "$SUBENTRY"
  run_expect 0 "submission validator accepts a pin whose plugins/agent-guard tree matches HEAD" \
    env -u AGENT_GUARD_SUBMISSION_SHA "$SUBVALIDATOR"

  # Advance HEAD so the pinned (now-parent) commit's payload no longer matches.
  printf 'drift\n' >"$SUBMIRROR/plugins/agent-guard/DRIFT_MARKER"
  (cd "$SUBMIRROR" && git add -A && git commit -q -m drift)
  run_expect 1 "submission validator rejects a stale pin whose plugins/agent-guard tree differs from HEAD" \
    env -u AGENT_GUARD_SUBMISSION_SHA "$SUBVALIDATOR"
  if grep -q 'differs from current payload' "$ERR"; then
    ok "stale-pin rejection names the payload drift and tells the maintainer to re-pin"
  else
    not_ok "stale-pin rejection names the payload drift and tells the maintainer to re-pin"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # A syntactically valid SHA that is not a local commit (shallow / submission
  # checkout) must FAIL closed: "could not verify" is not a pass. Warning and
  # skipping would print "validation passed" for a run that checked nothing —
  # exactly the stale-pin scenario this guard exists to catch.
  absent_sha=1234567890123456789012345678901234567890
  jq --arg sha "$absent_sha" '.source.sha = $sha' "$SUBENTRY" >"$SUBENTRY.tmp" && mv "$SUBENTRY.tmp" "$SUBENTRY"
  run_expect 1 "submission validator fails closed when the pinned commit is not available locally" \
    env -u AGENT_GUARD_SUBMISSION_SHA "$SUBVALIDATOR"
  if grep -q 'is not present locally' "$OUT" "$ERR"; then
    ok "history-unavailable pin fails with an actionable full-history message"
  else
    not_ok "history-unavailable pin fails with an actionable full-history message"
    sed 's/^/  stdout: /' "$OUT"; sed 's/^/  stderr: /' "$ERR"
  fi
else
  say "git archive unavailable; skipped submission-readiness drift tests"
fi

expect_json_status 2 "Claude Write secret is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"app.txt","content":"AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 0 "safe example token is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"app.txt","content":"example_token"}}' \
  hook-pre-tool

expect_json_status 2 "Codex apply_patch added secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Add File: x\n+AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "Codex canonical apply_patch command field is scanned" \
  '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Add File: x\n+AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 0 "Codex apply_patch deleted secret is allowed" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: x\n-AGENT_GUARD_TEST_SECRET\n+example_token\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "sensitive read path is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":".env.local"}}' \
  hook-pre-tool

expect_json_status 2 "risky Bash command is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}' \
  hook-pre-tool

expect_json_status 2 "Bash sed bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"sed -n p .env"}}' \
  hook-pre-tool

expect_json_status 2 "Bash head bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"head -c 200 .env"}}' \
  hook-pre-tool

expect_json_status 2 "Bash redirect bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat < .env"}}' \
  hook-pre-tool

expect_json_status 2 "Bash command-substitution bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"git config user.email \"$(cat .env)\""}}' \
  hook-pre-tool

expect_json_status 2 "Bash dd-on-private-key bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"dd if=id_rsa of=/tmp/x"}}' \
  hook-pre-tool

expect_json_status 2 "Bash absolute-path .env access is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"awk 1 /tmp/.env"}}' \
  hook-pre-tool

expect_json_status 2 "Bash quoted path fragment bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .e\"nv"}}' \
  hook-pre-tool

expect_json_status 2 "Bash escaped path fragment bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .e\\nv"}}' \
  hook-pre-tool

expect_json_status 2 "Bash ANSI-C quoted path bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat $'\''.e\\x6ev'\''"}}' \
  hook-pre-tool

expect_json_status 2 "Bash glob bracket path bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .e[n]v"}}' \
  hook-pre-tool

expect_json_status 2 "Bash glob wildcard path bypass is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .e?v"}}' \
  hook-pre-tool

expect_json_status 0 "Bash benign glob remains allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"ls *.md"}}' \
  hook-pre-tool

expect_json_status 0 "ripgrep negative glob over a denied extension is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"rg --files -g '\''!*.pem'\''"}}' \
  hook-pre-tool

expect_json_status 0 "command-wrapped ripgrep negative glob is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"command rg --files --glob='\''!*.pem'\''"}}' \
  hook-pre-tool

expect_json_status 2 "ripgrep positive glob over a denied extension remains blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"rg --files -g '\''*.pem'\''"}}' \
  hook-pre-tool

expect_json_status 2 "literal bang-prefixed denied path remains blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat '\''!secret.pem'\''"}}' \
  hook-pre-tool

expect_json_status 2 "negative glob does not hide a chained denied read" \
  '{"tool_name":"Bash","tool_input":{"command":"rg --files -g '\''!*.pem'\'' && cat secret.pem"}}' \
  hook-pre-tool

expect_json_status 2 "Bash command literal secret is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"printf AGENT_GUARD_TEST_SECRET > leaked.txt"}}' \
  hook-pre-tool

expect_json_status 0 "myenv-like substring is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"echo myenvironment"}}' \
  hook-pre-tool

expect_json_status 0 "env VAR=value command form is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"env CGO_ENABLED=0 go build"}}' \
  hook-pre-tool

expect_json_status 2 "bare env is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"env"}}' \
  hook-pre-tool

expect_json_status 2 "git --no-verify is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m x"}}' \
  hook-pre-tool

expect_json_status 0 "git word plus commit text is not treated as git commit" \
  '{"tool_name":"Bash","tool_input":{"command":"git status && echo commit"}}' \
  hook-pre-tool

expect_json_status 2 "Read on tilde-path .env is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"~/.env.local"}}' \
  hook-pre-tool

expect_json_status 2 "Read with leading ./ is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"./.env"}}' \
  hook-pre-tool

expect_json_status 2 "NotebookRead on sensitive path is blocked" \
  '{"tool_name":"NotebookRead","tool_input":{"notebook_path":".env"}}' \
  hook-pre-tool

expect_json_status 2 "Grep on explicit sensitive path is blocked" \
  '{"tool_name":"Grep","tool_input":{"pattern":"API_KEY","path":".env"}}' \
  hook-pre-tool

expect_json_status 2 "broad Grep content search for secrets is blocked" \
  '{"tool_name":"Grep","tool_input":{"pattern":"API_KEY","path":".","output_mode":"content"}}' \
  hook-pre-tool

expect_json_status 0 "broad Grep files-only search for secrets is allowed" \
  '{"tool_name":"Grep","tool_input":{"pattern":"API_KEY","path":".","output_mode":"files_with_matches"}}' \
  hook-pre-tool

expect_json_status 0 "broad Grep content search for benign text is allowed" \
  '{"tool_name":"Grep","tool_input":{"pattern":"TODO","path":".","output_mode":"content"}}' \
  hook-pre-tool

expect_json_status 2 "Codex Add File payload secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Add File: x\nAGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "Codex double-plus added secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: x\n@@\n++AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

# Issue #128: the unified-diff fallback (no *** Add/Update File: envelope) told a
# `+++ b/path` header from added content by SHAPE, so an added line whose content
# is `++ SECRET` — which git prefixes to `+++ SECRET` — was skipped as a header
# and never scanned. Drive the real hook with a plain unified diff so the fallback
# branch runs.
expect_json_status 2 "apply_patch unified-diff double-plus added secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"diff --git a/secrets.txt b/secrets.txt\n--- a/secrets.txt\n+++ b/secrets.txt\n@@ -0,0 +1 @@\n+++ AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 2 "apply_patch unified-diff plain added secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"diff --git a/secrets.txt b/secrets.txt\n--- a/secrets.txt\n+++ b/secrets.txt\n@@ -0,0 +1 @@\n+AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 0 "apply_patch unified-diff clean added content is allowed" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"diff --git a/secrets.txt b/secrets.txt\n--- a/secrets.txt\n+++ b/secrets.txt\n@@ -0,0 +1 @@\n+example_token"}}' \
  hook-pre-tool

expect_json_status 2 "apply_patch Add File double-plus secret stays blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Add File: x\n+++ AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 0 "apply_patch Add File double-plus clean content stays allowed" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Add File: x\n+++ example_token\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "MCP input secret is blocked" \
  '{"tool_name":"mcp__server__tool","tool_input":{"token":"AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 2 "WebFetch file URL to sensitive path is blocked" \
  '{"tool_name":"WebFetch","tool_input":{"url":"file:///.env","prompt":"summarize"}}' \
  hook-pre-tool

expect_json_status 2 "WebSearch query with secret is blocked" \
  '{"tool_name":"WebSearch","tool_input":{"query":"AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 0 "WebSearch benign query is allowed" \
  '{"tool_name":"WebSearch","tool_input":{"query":"agent guard documentation"}}' \
  hook-pre-tool

# --- Detection calibration & robustness (PR 1) ----------------------------
# Rank 1: reading the process environment via /proc is an env-dump bypass.
expect_json_status 2 "Bash /proc/self/environ read is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat /proc/self/environ"}}' \
  hook-pre-tool

expect_json_status 2 "Bash /proc/<pid>/environ with a shell PID is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat /proc/$$/environ"}}' \
  hook-pre-tool

expect_json_status 0 "Bash /proc/cpuinfo read is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"cat /proc/cpuinfo"}}' \
  hook-pre-tool

expect_json_status 2 "Read /proc/self/environ is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"/proc/self/environ"}}' \
  hook-pre-tool

# Rank 2: see through no-op wrappers / assignments before the git check, so a
# hook-disabling commit cannot hide behind `env` or a `FOO=bar` prefix.
expect_json_status 2 "env-wrapped git --no-verify is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"env git commit --no-verify -m x"}}' \
  hook-pre-tool

expect_json_status 2 "assignment-prefixed git --no-verify is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"FOO=bar git commit --no-verify -m x"}}' \
  hook-pre-tool

# Rank 3: cloud / secrets-manager credential-dump siblings.
expect_json_status 2 "gcloud auth print-access-token is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"gcloud auth print-access-token"}}' \
  hook-pre-tool

expect_json_status 2 "az account get-access-token is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"az account get-access-token"}}' \
  hook-pre-tool

expect_json_status 2 "aws configure export-credentials is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"aws configure export-credentials"}}' \
  hook-pre-tool

expect_json_status 2 "kubectl get secret -o yaml is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secret db -o yaml"}}' \
  hook-pre-tool

expect_json_status 0 "kubectl get secrets (names only) is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secrets"}}' \
  hook-pre-tool

expect_json_status 2 "kubectl get secret -o=yaml (equals form) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secret db -o=yaml"}}' \
  hook-pre-tool

expect_json_status 2 "kubectl get secret --output yaml (long flag) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secret db --output yaml"}}' \
  hook-pre-tool

expect_json_status 2 "kubectl get secret/name -o yaml (resource/name) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secret/db -o yaml"}}' \
  hook-pre-tool

expect_json_status 2 "kubectl get secret -o go-template is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secret db -o go-template={{.data}}"}}' \
  hook-pre-tool

expect_json_status 0 "kubectl get secret -o name (names only) is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get secret db -o name"}}' \
  hook-pre-tool

# Output flag may precede the resource (kubectl get [(-o ...)] TYPE); both orders
# must block, but a name merely containing "secret" must not false-positive.
expect_json_status 2 "kubectl get -o yaml secret/name (flag before resource) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get -o yaml secret/my-secret"}}' \
  hook-pre-tool

expect_json_status 2 "kubectl get -o json secrets (flag before plural type) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get -o json secrets"}}' \
  hook-pre-tool

expect_json_status 0 "kubectl get configmap app-secret -o yaml (name contains secret) is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get configmap app-secret -o yaml"}}' \
  hook-pre-tool

expect_json_status 0 "kubectl get pods -o yaml (no secret resource) is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"kubectl get pods -o yaml"}}' \
  hook-pre-tool

expect_json_status 0 "gcloud auth login is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"gcloud auth login"}}' \
  hook-pre-tool

# Rank 6: env-dump FP fix — `env` inside a quoted alternation must not block.
expect_json_status 2 "env piped to a sink is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"env | grep PATH"}}' \
  hook-pre-tool

expect_json_status 0 "env inside a quoted regex alternation is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"grep -E \"a|env|b\" notes.txt"}}' \
  hook-pre-tool

expect_json_status 0 "python venv creation is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"python -m venv .venv"}}' \
  hook-pre-tool

expect_json_status 2 "env redirected to a file is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"env > dump.txt"}}' \
  hook-pre-tool

expect_json_status 2 "env piped to a non-listed sink (gzip) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"env | gzip"}}' \
  hook-pre-tool

expect_json_status 0 "env VAR=x cmd piped (wrapped command, not bare env) is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"env FOO=bar printf %s done | cat"}}' \
  hook-pre-tool

# Rank 7: allow committed .env templates, but never a real .env.
expect_json_status 0 "Read .env.example template is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":".env.example"}}' \
  hook-pre-tool

expect_json_status 0 "Read .env.sample template is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":".env.sample"}}' \
  hook-pre-tool

expect_json_status 2 "Read bare .env is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":".env"}}' \
  hook-pre-tool

expect_json_status 0 "Bash cat .env.example is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.example"}}' \
  hook-pre-tool

expect_json_status 2 "Bash cat of a template plus a real .env still blocks" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.example .env"}}' \
  hook-pre-tool

expect_json_status 2 "Bash cp of a template to .env.local still blocks" \
  '{"tool_name":"Bash","tool_input":{"command":"cp .env.example .env.local"}}' \
  hook-pre-tool

expect_json_status 2 "Bash cat of .env.local (not a template) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.local"}}' \
  hook-pre-tool

# Suffix rule: any `.env*` basename ending with a template suffix is allowed,
# but the suffix must be final and the bare names stay blocked.
expect_json_status 0 "Read .envrc.sample template is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":".envrc.sample"}}' \
  hook-pre-tool

expect_json_status 0 "Read .env.local.example template is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":".env.local.example"}}' \
  hook-pre-tool

expect_json_status 2 "Read bare .envrc is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":".envrc"}}' \
  hook-pre-tool

expect_json_status 2 "Read .env.example.bak (suffix not final) is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":".env.example.bak"}}' \
  hook-pre-tool

expect_json_status 0 "Bash cat .envrc.sample is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .envrc.sample"}}' \
  hook-pre-tool

expect_json_status 0 "Bash cat .env.local.example is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.local.example"}}' \
  hook-pre-tool

expect_json_status 2 "Bash cat .envrc is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .envrc"}}' \
  hook-pre-tool

expect_json_status 2 "Bash cat .env.example.bak (suffix not final) is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.example.bak"}}' \
  hook-pre-tool

# Path-prefixed candidates go through basename stripping before the suffix match.
expect_json_status 0 "Read config/.env.local.example (path-prefixed template) is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":"config/.env.local.example"}}' \
  hook-pre-tool

expect_json_status 0 "Bash cat config/.envrc.sample (path-prefixed template) is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"cat config/.envrc.sample"}}' \
  hook-pre-tool

expect_json_status 2 "Read config/.env.local (path-prefixed, not a template) is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"config/.env.local"}}' \
  hook-pre-tool

# A template basename never exempts a file inside a deny-listed directory.
expect_json_status 2 "Read template inside a deny-listed directory is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":".env.production/.envrc.sample"}}' \
  hook-pre-tool

expect_json_status 2 "Read template under a deny-listed mid-path component is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"app/.env/.env.local.example"}}' \
  hook-pre-tool

expect_json_status 2 "Bash cat of a template inside a deny-listed directory is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env.production/.envrc.sample"}}' \
  hook-pre-tool

# Rank 8: shell builtins that print the whole environment.
expect_json_status 2 "export -p is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"export -p"}}' \
  hook-pre-tool

expect_json_status 2 "declare -p is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"declare -p"}}' \
  hook-pre-tool

expect_json_status 2 "bare set is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"set"}}' \
  hook-pre-tool

expect_json_status 0 "set -e is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"set -e"}}' \
  hook-pre-tool

expect_json_status 0 "set -o pipefail is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"set -o pipefail"}}' \
  hook-pre-tool

expect_json_status 0 "export of a single variable is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"export FOO=bar"}}' \
  hook-pre-tool

# Rank 9: additional high-value secret file types.
expect_json_status 2 "Read a PKCS#8 .p8 key is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"AuthKey.p8"}}' \
  hook-pre-tool

expect_json_status 2 "Read terraform state is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"terraform.tfstate"}}' \
  hook-pre-tool

expect_json_status 2 "Read .pgpass is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":".pgpass"}}' \
  hook-pre-tool

expect_json_status 0 "Read a terraform module file is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":"main.tf"}}' \
  hook-pre-tool

expect_json_status 0 "PII hook mode defaults off" \
  '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"email jane@example.com"}}' \
  hook-pre-tool

printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"email jane@example.com"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=block "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "PII hook block mode blocks proposed Write content"
else
  not_ok "PII hook block mode blocks proposed Write content (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"nb.ipynb","new_source":"contact jane@example.com"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=block "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "PII hook block mode blocks proposed NotebookEdit content"
else
  not_ok "PII hook block mode blocks proposed NotebookEdit content (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"tool_name":"WebSearch","tool_input":{"query":"look up 203.0.113.42"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=block "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "PII hook block mode blocks WebSearch input"
else
  not_ok "PII hook block mode blocks WebSearch input (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"tool_name":"mcp__server__tool","tool_input":{"note":"call 555-123-4567"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=block "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "PII hook block mode blocks MCP input"
else
  not_ok "PII hook block mode blocks MCP input (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"AGENT_GUARD_TEST_SECRET jane@example.com"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=block "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && grep -q 'secret-like' "$ERR"; then
  ok "secret scanning runs before PII hook scanning"
else
  not_ok "secret scanning runs before PII hook scanning (expected secret-like block, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# mask mode: clean input passes through (nothing to block on the way in).
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"clean"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ]; then
  ok "PII mask mode allows clean input"
else
  not_ok "PII mask mode allows clean input (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# mask mode: Tier-1 PII (email) is allowed IN — it gets masked on output instead.
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"contact jane@example.com"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ]; then
  ok "PII mask mode allows Tier-1 PII (email) input"
else
  not_ok "PII mask mode allows Tier-1 PII (email) input (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# mask mode: Tier-2 PII (KR resident registration number) is hard-blocked on input.
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"id 900101-1234567"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && grep -q 'high-sensitivity PII' "$ERR"; then
  ok "PII mask mode blocks Tier-2 PII (resident reg. no.) input"
else
  not_ok "PII mask mode blocks Tier-2 PII input (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# mask mode: Tier-2 credit card is hard-blocked on input.
# (Card number assembled at runtime so this test file holds no contiguous PAN.)
cc="4111 1111 ""1111 1111"
printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"note.txt\",\"content\":\"card $cc\"}}" \
  | AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && grep -q 'high-sensitivity PII' "$ERR"; then
  ok "PII mask mode blocks Tier-2 PII (credit card) input"
else
  not_ok "PII mask mode blocks Tier-2 PII (credit card) input (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# mask mode: a 15-digit Amex card is hard-blocked on input (not just 16-digit).
# (Assembled at runtime so this test file holds no contiguous PAN.)
amex="3782 ""822463 ""10005"
printf '%s' "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"note.txt\",\"content\":\"card $amex\"}}" \
  | AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && grep -q 'high-sensitivity PII' "$ERR"; then
  ok "PII mask mode blocks Tier-2 PII (15-digit Amex) input"
else
  not_ok "PII mask mode blocks Tier-2 PII (15-digit Amex) input (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# mask mode: Tier-2 US SSN is hard-blocked on input.
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"note.txt","content":"ssn 123-45-6789"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && grep -q 'high-sensitivity PII' "$ERR"; then
  ok "PII mask mode blocks Tier-2 PII (US SSN) input"
else
  not_ok "PII mask mode blocks Tier-2 PII (US SSN) input (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

TEST_REPO="$TMP_ROOT/repo"
mkdir -p "$TEST_REPO"
(
  cd "$TEST_REPO" || exit 2
  git init -q
  git config user.email test@example.com
  git config user.name test
  printf '%s\n' "clean" > README.md
  git add README.md
  git commit -q -m init

  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > staged.txt
  git add staged.txt
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-staged detects staged secret"
else
  not_ok "scan-staged detects staged secret (expected 1, got $status)"
fi

(
  cd "$TEST_REPO" || exit 2
  git reset -q
  rm -f staged.txt
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > untracked.txt
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree detects untracked secret"
else
  not_ok "scan-working-tree detects untracked secret (expected 1, got $status)"
fi

# A staged line whose own content begins with "++ " reaches git diff as
# "+++ ..." — the added-line filter must scan it, not mistake it for a
# "+++ b/path" file header and drop it.
(
  cd "$TEST_REPO" || exit 2
  git reset -q
  rm -f staged.txt untracked.txt
  printf '%s\n' "++ AGENT_GUARD_TEST_SECRET" > plusplus.txt
  sed 's|^++ |++ b/|' plusplus.txt > plusplus.tmp
  mv plusplus.tmp plusplus.txt
  git add plusplus.txt
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-staged scans an added line whose content starts with '++ '"
else
  not_ok "scan-staged scans an added line whose content starts with '++ ' (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# Same "++ " line, exercised through the working-tree diff path (a tracked
# modification, not an untracked file which takes the cat path instead).
(
  cd "$TEST_REPO" || exit 2
  git reset -q
  printf '%s\n' "benign baseline" > plusplus.txt
  git add plusplus.txt
  git commit -q -m plusplus-baseline
  printf '%s\n' "benign baseline" "++ AGENT_GUARD_TEST_SECRET" > plusplus.txt
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree scans a tracked '++ ' line in a modified file"
else
  not_ok "scan-working-tree scans a tracked '++ ' line in a modified file (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
(
  cd "$TEST_REPO" || exit 2
  git rm -q plusplus.txt >/dev/null 2>&1
  git commit -q -m drop-plusplus >/dev/null 2>&1
)

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"stop_hook_active":true}' | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "hook-stop loop protection allows active stop hook"
else
  not_ok "hook-stop loop protection allows active stop hook (expected 0, got $status)"
fi

(
  cd "$TEST_REPO" || exit 2
  git reset -q
  rm -f staged.txt untracked.txt
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leak.txt
  git add leak.txt
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git -c user.name=x commit -m leak"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "git -c option-form commit with staged secret is intercepted"
else
  not_ok "git -c option-form commit with staged secret is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git -C . push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "git -C option-form push with staged secret is intercepted"
else
  not_ok "git -C option-form push with staged secret is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# `git -C` is relative to the command's execution directory, not the hook's
# process cwd. The target repo must win over a clean hook cwd.
(
  cd "$TMP_ROOT" || exit 2
  test_repo_rel=${TEST_REPO#"$TMP_ROOT"/}
  jq -nc --arg command "git -C $test_repo_rel commit -m leak" --arg workdir "$TMP_ROOT" \
    '{tool_name:"Bash",tool_input:{command:$command,workdir:$workdir}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ] && grep -q 'staged changes contain secret-like values' "$ERR"; then
  ok "git -C resolves relative to tool_input.workdir before staged scanning"
else
  not_ok "git -C resolves relative to tool_input.workdir (expected staged-secret block, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# Quoted and backslash-escaped -C values are one shell word. Preserve that word
# while resolving the repository instead of splitting it at the embedded space.
ln -s "$TEST_REPO" "$TMP_ROOT/git-c target"
jq -nc --arg command "git -C 'git-c'\\ target commit -m leak" --arg workdir "$TMP_ROOT" \
  '{tool_name:"Bash",tool_input:{command:$command,workdir:$workdir}}' \
  | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "git -C preserves quoted and escaped paths while scanning staged changes"
else
  not_ok "git -C preserves quoted and escaped paths (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# env changes cwd before launching git. Apply its -C/--chdir first so a clean
# repo at the unadjusted path cannot hide a staged secret in the real target.
mkdir -p "$TMP_ROOT/env-c-parent/base" "$TMP_ROOT/target"
ln -s "$TEST_REPO" "$TMP_ROOT/env-c-parent/base/target"
(cd "$TMP_ROOT/target" && git init -q)
jq -nc \
  --arg command 'env -C env-c-parent env --chdir=base git -C target commit -m leak' \
  --arg workdir "$TMP_ROOT" \
  '{tool_name:"Bash",tool_input:{command:$command,workdir:$workdir}}' \
  | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "env cwd options are applied before git -C staged scanning"
else
  not_ok "env cwd options are applied before git -C (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git -C \"$REPO\" commit -m leak"}}' \
  | AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && grep -q 'could not be resolved safely' "$ERR"; then
  ok "dynamic git cwd follows the configured infrastructure failure policy"
else
  not_ok "dynamic git cwd follows infrastructure policy (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# Codex runs hooks from the task root, which can differ from exec_command's
# workdir. Honor the tool payload so the staged scan runs in the target repo.
(
  cd "$TMP_ROOT" || exit 2
  jq -nc --arg workdir "$TEST_REPO" \
    '{tool_name:"Bash",tool_input:{command:"git commit -m leak",workdir:$workdir}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ] && grep -q 'staged changes contain secret-like values' "$ERR"; then
  ok "Codex hook scans staged changes from tool_input.workdir"
else
  not_ok "Codex hook scans staged changes from tool_input.workdir (expected staged-secret block, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$TMP_ROOT" || exit 2
  jq -nc --arg cwd "$TEST_REPO" \
    '{tool_name:"Bash",cwd:$cwd,tool_input:{command:"git push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ] && grep -q 'staged changes contain secret-like values' "$ERR"; then
  ok "host hook scans staged changes from top-level cwd"
else
  not_ok "host hook scans staged changes from top-level cwd (expected staged-secret block, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# A linked worktree stores .git as a gitdir pointer file. Exercise the real
# commit and push after PreToolUse runs from a non-repository sandbox cwd; a
# clean staged change must be scanned in tool_input.workdir and allowed.
LINKED_BASE="$TMP_ROOT/linked-base"
LINKED_WT="$TMP_ROOT/linked-worktree"
LINKED_REMOTE="$TMP_ROOT/linked-remote.git"
mkdir -p "$LINKED_BASE"
(
  cd "$LINKED_BASE" || exit 2
  git init -q
  git config user.email linked@example.com
  git config user.name linked
  printf '%s\n' "baseline" > README.md
  git add README.md
  git commit -q -m init
  git worktree add -q -b linked-clean "$LINKED_WT"
  git init -q --bare "$LINKED_REMOTE"
  git remote add origin "$LINKED_REMOTE"
)
if [ -f "$LINKED_WT/.git" ]; then
  ok "linked worktree fixture uses a gitdir pointer file"
else
  not_ok "linked worktree fixture uses a gitdir pointer file"
fi
printf '%s\n' "clean linked change" >"$LINKED_WT/clean.txt"
git -C "$LINKED_WT" add clean.txt
(
  cd "$TMP_ROOT" || exit 2
  jq -nc --arg workdir "$LINKED_WT" \
    '{session_id:"linked-session",tool_name:"Bash",tool_input:{command:"git commit -m clean",workdir:$workdir}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && git -C "$LINKED_WT" commit -q -m clean; then
  ok "commit passes after a clean linked-worktree scan from a different hook cwd"
else
  not_ok "commit passes after a clean linked-worktree scan from a different hook cwd (hook status $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
(
  cd "$TMP_ROOT" || exit 2
  jq -nc --arg workdir "$LINKED_WT" \
    '{session_id:"linked-session",tool_name:"Bash",tool_input:{command:"git push -u origin linked-clean",workdir:$workdir}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && git -C "$LINKED_WT" push -q -u origin linked-clean; then
  ok "push passes after a clean linked-worktree scan from a different hook cwd"
else
  not_ok "push passes after a clean linked-worktree scan from a different hook cwd (hook status $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status && git -C . push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "chained git push after non-mutating git command is intercepted"
else
  not_ok "chained git push after non-mutating git command is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status&&git -C . push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "chained git push without separator spaces is intercepted"
else
  not_ok "chained git push without separator spaces is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

expect_json_status 2 "git hook bypass without separator spaces is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify&&echo done"}}' \
  hook-pre-tool

expect_json_status 2 "quoted git hook bypass option is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit '\''--no-verify'\''"}}' \
  hook-pre-tool

# #127: is_git_commit_or_push reset its command_start flag only on `; && || |`,
# so a `git commit` after a bare `&`, a newline, or inside `( )` grouping was
# never recognized as a command head -- both the staged scan and the
# --no-verify block were skipped. These drive the real hook end to end.
expect_json_status 2 "git commit after bare & is detected (--no-verify blocked)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo ok & git commit --no-verify"}}' \
  hook-pre-tool
expect_json_status 2 "git commit inside ( ) grouping is detected (--no-verify blocked)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo ok; ( git commit --no-verify )"}}' \
  hook-pre-tool
# The newline form is the one #127/#138 called out as the most natural way to
# write a two-line command. It needed a second fix beyond the detector:
# check_bash_command's global `cmd` was clobbered by bash_matches_deny_path /
# bash_matches_deny_path_mode (POSIX sh has no local scope), whose strip helpers
# rejoin tokens with single spaces -- collapsing the newline to a space before
# check_git_command ran. A bare `&` survives that rejoin as its own token, which
# is why `&` worked while the newline silently leaked. check_bash_command now
# keeps a pristine `raw_cmd` for every downstream check.
expect_json_status 2 "git commit after a newline is detected (--no-verify blocked)" \
  '{"tool_name":"Bash","tool_input":{"command":"echo ok\ngit commit --no-verify"}}' \
  hook-pre-tool
# Control: a newline-separated command with no git commit stays allowed, so the
# pristine-cmd change does not turn newlines themselves into a block signal.
expect_json_status 0 "newline-separated non-commit command stays allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"echo ok\ngit status"}}' \
  hook-pre-tool
# Control: boundary normalization must not over-detect. `echo commit` after
# `git status &&` is a separate command head, not a `git commit`.
expect_json_status 0 "git status followed by echo commit is not a git commit" \
  '{"tool_name":"Bash","tool_input":{"command":"git status && echo commit"}}' \
  hook-pre-tool

# R2: wrapper/assignment-prefixed commits with NO --no-verify must still reach
# the staged scan via is_git_commit_or_push (not via the hook-bypass shortcut).
# leak.txt is still staged from the harness above.
(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"env git commit -m leak"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "env-wrapped git commit with staged secret triggers staged scan"
else
  not_ok "env-wrapped git commit with staged secret triggers staged scan (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"FOO=bar git commit -m leak"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "assignment-prefixed git commit with staged secret triggers staged scan"
else
  not_ok "assignment-prefixed git commit with staged secret triggers staged scan (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"env -u HOME git commit -m leak"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "env-with-option-wrapped git commit with staged secret triggers staged scan"
else
  not_ok "env-with-option-wrapped git commit with staged secret triggers staged scan (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# NOTE (#127/#138): a plain `git commit` on its own line reaching the staged
# scan is NOT covered here for the same reason as the newline --no-verify case
# above -- check_bash_command clobbers `cmd` via bash_matches_deny_path and the
# newline is collapsed to a space before check_git_command / is_git_commit_or_push
# ever run. Belongs to the separate #138 effort (preserve pristine cmd upstream).

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"env git status"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "env-wrapped git status (not commit/push) is allowed"
else
  not_ok "env-wrapped git status (not commit/push) is allowed (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

SYMLINK_REPO="$TMP_ROOT/symlink-repo"
mkdir -p "$SYMLINK_REPO"
(
  cd "$SYMLINK_REPO" || exit 2
  printf '%s\n' "sensitive fixture" > blocked-target.txt
  ln -s blocked-target.txt safe-link
)
SYMLINK_DENY="$TESTTMP/symlink-deny-paths.txt"
printf '%s\n' 'blocked-target.txt' >"$SYMLINK_DENY"
if [ -L "$SYMLINK_REPO/safe-link" ]; then
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$SYMLINK_REPO"'/safe-link"}}'
  printf '%s' "$payload" \
    | AGENT_GUARD_DENY_READ_PATHS="$SYMLINK_DENY" "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "symlink to a deny-listed target is blocked via realpath resolution"
  else
    not_ok "symlink to a deny-listed target is blocked via realpath resolution (expected 2, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi
else
  say "skipping symlink test: filesystem does not support symlinks"
fi

# --- #132: a template-named symlink to a real secret must not bypass the Bash
# path-deny gate. The Bash strip step used to drop `.env.example` by name before
# resolving it, while the Read gate already resolves the symlink and blocks. This
# asserts the Bash gate now mirrors the Read gate, while a genuine regular-file
# .env.example template keeps working (no false positive). Uses the default
# `.env*` deny policy so it exercises the shipped rule.
TEMPLATE_SYMLINK_REPO="$TMP_ROOT/template-symlink-repo"
mkdir -p "$TEMPLATE_SYMLINK_REPO"
(
  cd "$TEMPLATE_SYMLINK_REPO" || exit 2
  # Real secret file with a runtime-generated value (never a committed literal).
  printf 'API_TOKEN=agtest-%s-%s\n' "$$" "${RANDOM:-0}" > .env
  # Template-named symlink pointing at the real secret -> the #132 bypass shape.
  ln -s .env .env.example
)
# Genuine regular-file template in a separate dir: must stay allowed. Ordinary
# example content, not a symlink, no real secret alongside it.
GENUINE_TEMPLATE_REPO="$TMP_ROOT/genuine-template-repo"
mkdir -p "$GENUINE_TEMPLATE_REPO"
printf 'API_TOKEN=your-token-here\n' > "$GENUINE_TEMPLATE_REPO/.env.example"

if [ -L "$TEMPLATE_SYMLINK_REPO/.env.example" ]; then
  # Repro: cat of the template-named symlink must now be BLOCKED (#132).
  payload='{"tool_name":"Bash","tool_input":{"command":"cat '"$TEMPLATE_SYMLINK_REPO"'/.env.example"}}'
  printf '%s' "$payload" \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "Bash cat of a template-named symlink to a real secret is blocked (#132)"
  else
    not_ok "Bash cat of a template-named symlink to a real secret is blocked (#132) (expected 2, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # Control (must-pass): the real name behind the symlink is blocked regardless.
  payload='{"tool_name":"Bash","tool_input":{"command":"cat '"$TEMPLATE_SYMLINK_REPO"'/.env"}}'
  printf '%s' "$payload" \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "Bash cat of the real .env behind the symlink is blocked"
  else
    not_ok "Bash cat of the real .env behind the symlink is blocked (expected 2, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # Parity: the Read gate already blocks the same symlink (confirms the Bash gate
  # now matches the Read gate's resolved-target behavior).
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$TEMPLATE_SYMLINK_REPO"'/.env.example"}}'
  printf '%s' "$payload" \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "Read of the template-named symlink is blocked (parity with Bash gate)"
  else
    not_ok "Read of the template-named symlink is blocked (parity with Bash gate) (expected 2, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # #132 gap: a RELATIVE template token resolves with realpath against the cwd
  # the deny-path check runs in. If the host dispatches the hook from a different
  # directory than the command targets, resolving `.env.example` against the
  # process cwd finds nothing, the symlink check no-ops, and the bypass reopens.
  # The gate must scan in the event workdir. Drive a relative `cat .env.example`
  # with workdir=<repo> while the hook process cwd is deliberately elsewhere.
  payload='{"tool_name":"Bash","tool_input":{"command":"cat .env.example","workdir":"'"$TEMPLATE_SYMLINK_REPO"'"}}'
  ( cd / && printf '%s' "$payload" \
      | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR" )
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "Bash cat of a relative template symlink is blocked when workdir differs from cwd (#132)"
  else
    not_ok "Bash cat of a relative template symlink is blocked when workdir differs from cwd (#132) (expected 2, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # Control: the same relative form in a workdir with a GENUINE regular-file
  # template must stay allowed — the workdir cd must not itself become a block.
  payload='{"tool_name":"Bash","tool_input":{"command":"cat .env.example","workdir":"'"$GENUINE_TEMPLATE_REPO"'"}}'
  ( cd / && printf '%s' "$payload" \
      | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR" )
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "Bash cat of a relative genuine template stays allowed across workdir cd"
  else
    not_ok "Bash cat of a relative genuine template stays allowed across workdir cd (expected 0, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi
else
  say "skipping #132 template-symlink test: filesystem does not support symlinks"
fi

# Control (must-fail as a block -> must stay ALLOWED): a genuine regular-file
# .env.example template is not a symlink to a secret and must keep working.
payload='{"tool_name":"Bash","tool_input":{"command":"cat '"$GENUINE_TEMPLATE_REPO"'/.env.example"}}'
printf '%s' "$payload" \
  | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ]; then
  ok "Bash cat of a genuine regular-file .env.example template stays allowed"
else
  not_ok "Bash cat of a genuine regular-file .env.example template stays allowed (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# action.yml shell-injection regression for AGENT_GUARD_PATHS.
INJECTION_CANARY="$TMP_ROOT/inject-canary"
rm -f "$INJECTION_CANARY"
AGENT_GUARD_PATHS=". && touch $INJECTION_CANARY" sh -c '
  set -u
  # If path splitting leaked into command execution, the canary would appear.
  set -- -- $AGENT_GUARD_PATHS
  for arg in "$@"; do
    : "$arg"
  done
' 2>/dev/null
if [ -e "$INJECTION_CANARY" ]; then
  not_ok "action.yml env-var paths pattern still allows shell injection (canary fired)"
else
  ok "action.yml env-var paths pattern resists shell injection"
fi
rm -f "$INJECTION_CANARY"

# --- CLI dispatch ----------------------------------------------------------

run_expect 0 "version subcommand prints program/version" \
  "$PLUGIN_ROOT/bin/agent-guard" version
case "$(cat "$OUT")" in
  agent-guard*) ok "version output starts with program name" ;;
  *) not_ok "version output unexpected: $(cat "$OUT")" ;;
esac

run_expect 0 "help subcommand exits 0" "$PLUGIN_ROOT/bin/agent-guard" help
run_expect 0 "no args exits 0 with usage on stderr" "$PLUGIN_ROOT/bin/agent-guard"
run_expect 2 "unknown subcommand exits 2" "$PLUGIN_ROOT/bin/agent-guard" not-a-command
if "$PLUGIN_ROOT/bin/agent-guard" help 2>&1 | grep -q 'smoke-test'; then
  ok "help lists smoke-test"
else
  not_ok "help lists smoke-test"
fi
if "$PLUGIN_ROOT/bin/agent-guard" help 2>&1 | grep -q 'pii-filter'; then
  ok "help lists pii-filter"
else
  not_ok "help lists pii-filter"
fi

run_expect 0 "check passes when deps and configs exist" "$PLUGIN_ROOT/bin/agent-guard" check

# --- pii-filter -----------------------------------------------------------

PII_SAMPLE='Contact jane@example.com at +1 (415) 555-0199, card 4111 1111 1111 1111, ssn 123-45-6789, ip 203.0.113.42.'
PII_EXPECTED='Contact [PII:EMAIL] at [PII:PHONE], card [PII:CREDIT_CARD], ssn [PII:SSN], ip [PII:IP_ADDRESS].'
printf '%s\n' "$PII_SAMPLE" | "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "$PII_EXPECTED" ]; then
  ok "pii-filter regex provider masks common PII"
else
  not_ok "pii-filter regex provider masks common PII (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

PII_CLEAN='No identifiers in this line.'
printf '%s\n' "$PII_CLEAN" | "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "$PII_CLEAN" ]; then
  ok "pii-filter leaves clean text unchanged"
else
  not_ok "pii-filter leaves clean text unchanged (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' "$PII_CLEAN" | "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "$PII_CLEAN" ]; then
  ok "pii-filter preserves clean text without trailing newline"
else
  not_ok "pii-filter preserves clean text without trailing newline (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' 'Email jane@example.com' | "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = 'Email [PII:EMAIL]' ]; then
  ok "pii-filter preserves masked text without trailing newline"
else
  not_ok "pii-filter preserves masked text without trailing newline (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

run_expect 0 "pii-filter --check passes for default regex provider" \
  "$PLUGIN_ROOT/bin/agent-guard" pii-filter --check

printf '%s' 'x' | AGENT_GUARD_PII_PROVIDER=bogus "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "pii-filter rejects unknown providers"
else
  not_ok "pii-filter rejects unknown providers (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

PII_MOCK_CURL_DIR="$TMP_ROOT/pii-curl-bin"
PII_REQUEST_FILE="$TMP_ROOT/pii-request.json"
PII_URL_FILE="$TMP_ROOT/pii-url.txt"
mkdir -p "$PII_MOCK_CURL_DIR"
cat > "$PII_MOCK_CURL_DIR/curl" <<'EOSH'
#!/usr/bin/env sh
last=
for arg do
  last=$arg
done
if [ -n "${PII_MOCK_CURL_URL:-}" ]; then
  printf '%s\n' "$last" >"$PII_MOCK_CURL_URL"
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--data|--data-raw|--data-binary)
      shift
      if [ "${1:-}" = "@-" ]; then
        cat >"$PII_MOCK_CURL_REQUEST"
      fi
      ;;
  esac
  [ "$#" -gt 0 ] || break
  shift
done
case "${PII_MOCK_CURL_MODE:-ok}" in
  ok) printf '%s\n' '{"redacted_text":"masked by endpoint"}' ;;
  data) printf '%s\n' '{"data":{"redacted_text":"masked by nested endpoint"}}' ;;
  bad-json) printf '%s\n' 'not json' ;;
  bad-response) printf '%s\n' '{"unexpected":"value"}' ;;
  fail) printf '%s\n' 'synthetic curl failure' >&2; exit 7 ;;
esac
EOSH
chmod +x "$PII_MOCK_CURL_DIR/curl"

printf '%s' 'endpoint text jane@example.com' \
  | PATH="$PII_MOCK_CURL_DIR:$PATH" \
    AGENT_GUARD_PII_PROVIDER=pleno \
    AGENT_GUARD_PII_REDACT_URL='http://127.0.0.1:8080/api/redact' \
    PII_MOCK_CURL_REQUEST="$PII_REQUEST_FILE" \
    PII_MOCK_CURL_URL="$PII_URL_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = "masked by endpoint" ]; then
  ok "pii-filter pleno provider uses endpoint adapter response"
else
  not_ok "pii-filter pleno provider uses endpoint adapter response (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi
if jq -e '.text == "endpoint text jane@example.com"' "$PII_REQUEST_FILE" >/dev/null 2>&1; then
  ok "pii-filter endpoint adapter sends text JSON payload"
else
  not_ok "pii-filter endpoint adapter sends text JSON payload"
  sed 's/^/  request: /' "$PII_REQUEST_FILE"
fi
if [ "$(cat "$PII_URL_FILE")" = "http://127.0.0.1:8080/api/redact" ]; then
  ok "pii-filter endpoint adapter uses AGENT_GUARD_PII_REDACT_URL"
else
  not_ok "pii-filter endpoint adapter uses AGENT_GUARD_PII_REDACT_URL"
fi

PATH="$PII_MOCK_CURL_DIR:$PATH" \
  AGENT_GUARD_PII_PROVIDER=http \
  AGENT_GUARD_PII_REDACT_URL='http://127.0.0.1:8080/api/redact' \
  PII_MOCK_CURL_REQUEST="$PII_REQUEST_FILE" \
  PII_MOCK_CURL_MODE=data \
  "$PLUGIN_ROOT/bin/agent-guard" pii-filter --check \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ]; then
  ok "pii-filter http provider passes endpoint check"
else
  not_ok "pii-filter http provider passes endpoint check (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' 'x' \
  | env -u AGENT_GUARD_PII_REDACT_URL AGENT_GUARD_PII_PROVIDER=pleno \
    "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "pii-filter endpoint provider fails closed when URL is missing"
else
  not_ok "pii-filter endpoint provider fails closed when URL is missing (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' 'x' \
  | PATH="$PII_MOCK_CURL_DIR:$PATH" \
    AGENT_GUARD_PII_PROVIDER=pleno \
    AGENT_GUARD_PII_REDACT_URL='http://127.0.0.1:8080/api/redact' \
    PII_MOCK_CURL_REQUEST="$PII_REQUEST_FILE" \
    PII_MOCK_CURL_MODE=fail \
    "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "pii-filter endpoint provider fails closed on HTTP failure"
else
  not_ok "pii-filter endpoint provider fails closed on HTTP failure (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' 'x' \
  | PATH="$PII_MOCK_CURL_DIR:$PATH" \
    AGENT_GUARD_PII_PROVIDER=pleno \
    AGENT_GUARD_PII_REDACT_URL='http://127.0.0.1:8080/api/redact' \
    PII_MOCK_CURL_REQUEST="$PII_REQUEST_FILE" \
    PII_MOCK_CURL_MODE=bad-response \
    "$PLUGIN_ROOT/bin/agent-guard" pii-filter \
    >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "pii-filter endpoint provider fails closed on bad response shape"
else
  not_ok "pii-filter endpoint provider fails closed on bad response shape (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

NO_CURL_BIN="$TMP_ROOT/no-curl-bin"
mkdir -p "$NO_CURL_BIN"
ln -s "$REAL_SH" "$NO_CURL_BIN/sh"
ln -s "$REAL_DIRNAME" "$NO_CURL_BIN/dirname"
ln -s "$REAL_PWD" "$NO_CURL_BIN/pwd"
ln -s "$REAL_JQ" "$NO_CURL_BIN/jq"
PATH="$NO_CURL_BIN" \
  AGENT_GUARD_PII_PROVIDER=pleno \
  AGENT_GUARD_PII_REDACT_URL='http://127.0.0.1:8080/api/redact' \
  "$PLUGIN_ROOT/bin/agent-guard" pii-filter --check \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "pii-filter endpoint provider fails closed when curl is missing"
else
  not_ok "pii-filter endpoint provider fails closed when curl is missing (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

if [ -n "$REAL_CURL" ]; then
  NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
  mkdir -p "$NO_JQ_BIN"
  ln -s "$REAL_SH" "$NO_JQ_BIN/sh"
  ln -s "$REAL_DIRNAME" "$NO_JQ_BIN/dirname"
  ln -s "$REAL_PWD" "$NO_JQ_BIN/pwd"
  ln -s "$REAL_CURL" "$NO_JQ_BIN/curl"
  PATH="$NO_JQ_BIN" \
    AGENT_GUARD_PII_PROVIDER=pleno \
    AGENT_GUARD_PII_REDACT_URL='http://127.0.0.1:8080/api/redact' \
    "$PLUGIN_ROOT/bin/agent-guard" pii-filter --check \
    >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "pii-filter endpoint provider fails closed when jq is missing"
  else
    not_ok "pii-filter endpoint provider fails closed when jq is missing (expected 2, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi
else
  say "real curl not available; skipped missing-jq endpoint dependency test"
fi

# --- setup -----------------------------------------------------------------

run_expect 0 "setup --help exits 0" "$PLUGIN_ROOT/bin/agent-guard" setup --help
run_expect 2 "setup unknown flag exits 2" "$PLUGIN_ROOT/bin/agent-guard" setup --bogus
run_expect 0 "setup with all deps present exits 0" "$PLUGIN_ROOT/bin/agent-guard" setup

# --- scan-path -------------------------------------------------------------

CLEAN_DIR="$TMP_ROOT/clean-dir"
mkdir -p "$CLEAN_DIR"
printf '%s\n' "ok content" > "$CLEAN_DIR/safe.txt"
run_expect 0 "scan-path is clean for benign directory" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR"

DIRTY_DIR="$TMP_ROOT/dirty-dir"
mkdir -p "$DIRTY_DIR"
printf '%s\n' "AGENT_GUARD_TEST_SECRET" > "$DIRTY_DIR/leak.txt"
run_expect 1 "scan-path detects secret via mock gitleaks" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$DIRTY_DIR"

run_expect 1 "scan-path with multiple paths returns 1 if any has a leak" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" "$DIRTY_DIR"

run_expect 0 "scan-path accepts -- arg terminator before paths" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path -- "$CLEAN_DIR"

run_expect 2 "scan-path dies when given a missing path" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$TMP_ROOT/does-not-exist"

run_expect 2 "scan-path dies with no paths" "$PLUGIN_ROOT/bin/agent-guard" scan-path

# --- hook_pre_tool routing & passthroughs ---------------------------------

expect_json_status 0 "empty stdin to hook-pre-tool is allowed" "" hook-pre-tool
expect_json_status 0 "unknown tool name passes through hook-pre-tool" \
  '{"tool_name":"FutureTool","tool_input":{"x":1}}' \
  hook-pre-tool

expect_json_status 0 "Read on benign path passes" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/app.ts"}}' \
  hook-pre-tool

expect_json_status 0 "Bash on benign command passes" \
  '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  hook-pre-tool

expect_json_status 2 "live PreToolUse sentinel is blocked before execution" \
  '{"tool_name":"Bash","tool_input":{"command":"printf %s AGENT_GUARD_LIVE_PRE_TOOL_PROBE"}}' \
  hook-pre-tool

expect_json_status 2 "MultiEdit with one secret edit is blocked" \
  '{"tool_name":"MultiEdit","tool_input":{"edits":[{"new_string":"clean line"},{"new_string":"AGENT_GUARD_TEST_SECRET"}]}}' \
  hook-pre-tool

expect_json_status 0 "MultiEdit with all-clean edits passes" \
  '{"tool_name":"MultiEdit","tool_input":{"edits":[{"new_string":"alpha"},{"new_string":"beta"}]}}' \
  hook-pre-tool

expect_json_status 0 "Write with no content key passes" \
  '{"tool_name":"Write","tool_input":{"file_path":"x.txt"}}' \
  hook-pre-tool

expect_json_status 0 "Edit with clean new_string passes" \
  '{"tool_name":"Edit","tool_input":{"new_string":"const x = 1"}}' \
  hook-pre-tool

expect_json_status 2 "NotebookEdit with secret new_source is blocked" \
  '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"nb.ipynb","new_source":"AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 0 "NotebookEdit with clean new_source passes" \
  '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"nb.ipynb","new_source":"print(1)"}}' \
  hook-pre-tool

# --- hook_post_tool routing -----------------------------------------------

POST_REPO="$TMP_ROOT/post-repo"
mkdir -p "$POST_REPO"
(
  cd "$POST_REPO" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf '%s\n' "ok" > README.md
  git add README.md
  git commit -q -m init
)

(
  cd "$POST_REPO" || exit 2
  printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "hook-post-tool ignores non-mutation tools"
else
  not_ok "hook-post-tool ignores non-mutation tools (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$POST_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leaked.txt
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"leaked.txt"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-post-tool blocks when working tree has a new secret"
else
  not_ok "hook-post-tool blocks when working tree has a new secret (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- hook_stop ------------------------------------------------------------

(
  cd "$POST_REPO" || exit 2
  rm -f leaked.txt
  printf '%s' '{"stop_hook_active":false}' | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "hook-stop allows clean working tree when not active"
else
  not_ok "hook-stop allows clean working tree when not active (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$POST_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > stop-leak.txt
  printf '%s' '{"stop_hook_active":false}' | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-stop blocks when working tree has a secret and not active"
else
  not_ok "hook-stop blocks when working tree has a secret and not active (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- hook silent-skip outside a git work tree ------------------------------
# Regression: when the agent runs in a non-git cwd (e.g. ~), hook-post-tool
# and hook-stop must exit 0 silently instead of erroring on every Stop event.

NO_GIT_DIR="$TMP_ROOT/no-git"
mkdir -p "$NO_GIT_DIR"

(
  cd "$NO_GIT_DIR" || exit 2
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x.txt","content":"x"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && [ ! -s "$ERR" ]; then
  ok "hook-post-tool silently skips when cwd is not a git work tree"
else
  not_ok "hook-post-tool silently skips when cwd is not a git work tree (expected 0 + empty stderr, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

(
  cd "$NO_GIT_DIR" || exit 2
  printf '%s' '{"stop_hook_active":false}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && [ ! -s "$ERR" ]; then
  ok "hook-stop silently skips when cwd is not a git work tree"
else
  not_ok "hook-stop silently skips when cwd is not a git work tree (expected 0 + empty stderr, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# PostToolUse and Stop honor the payload workdir, and scans started in a nested
# directory cover the whole repository instead of only `-- .` below that cwd.
mkdir -p "$POST_REPO/nested/deeper"
printf '%s\n' "AGENT_GUARD_TEST_SECRET" >"$POST_REPO/root-leak.txt"
(
  cd "$TMP_ROOT" || exit 2
  jq -nc --arg cwd "$POST_REPO/nested/deeper" \
    '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:"clean.txt"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-post-tool scans the repository root from payload cwd subdirectories"
else
  not_ok "hook-post-tool scans the repository root from payload cwd (expected 2, got $status)"
fi
(
  cd "$TMP_ROOT" || exit 2
  jq -nc --arg workdir "$POST_REPO/nested/deeper" \
    '{stop_hook_active:false,tool_input:{workdir:$workdir}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-stop scans the repository root from payload workdir subdirectories"
else
  not_ok "hook-stop scans the repository root from payload workdir (expected 2, got $status)"
fi
rm -f "$POST_REPO/root-leak.txt"

# A failed git diff means the scanner did not run. Direct scan commands expose
# status 3 so hook callers can apply the configured infrastructure policy.
DIFF_FAIL_BIN="$TESTTMP/diff-fail-bin"
mkdir -p "$DIFF_FAIL_BIN"
cat >"$DIFF_FAIL_BIN/git" <<'EOSH'
#!/usr/bin/env sh
if [ "${1:-}" = diff ]; then
  exit 42
fi
exec "$AGENT_GUARD_TEST_REAL_GIT" "$@"
EOSH
chmod +x "$DIFF_FAIL_BIN/git"
(
  cd "$TEST_REPO" || exit 2
  PATH="$DIFF_FAIL_BIN:$PATH" AGENT_GUARD_TEST_REAL_GIT="$REAL_GIT" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 3 ]; then
  ok "scan-staged reports unavailable when git diff fails"
else
  not_ok "scan-staged reports unavailable on git diff failure (expected 3, got $status)"
fi
(
  cd "$TEST_REPO" || exit 2
  PATH="$DIFF_FAIL_BIN:$PATH" AGENT_GUARD_TEST_REAL_GIT="$REAL_GIT" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 3 ]; then
  ok "scan-working-tree reports unavailable when git diff fails"
else
  not_ok "scan-working-tree reports unavailable on git diff failure (expected 3, got $status)"
fi

# Git is required only for the repository backstop. PreTool secret checks and
# PostTool output redaction continue to work when git itself is absent.
NO_GIT_BIN="$TESTTMP/no-git-bin"
NO_GIT_WARN_DIR="$TESTTMP/no-git-warnings"
mkdir -p "$NO_GIT_BIN" "$NO_GIT_WARN_DIR"
for no_git_cmd in sh dirname pwd readlink jq sed awk grep cat mktemp mkdir chmod rm sort tail cut head; do
  no_git_path=$(command -v "$no_git_cmd" 2>/dev/null || true)
  [ -n "$no_git_path" ] && ln -s "$no_git_path" "$NO_GIT_BIN/$no_git_cmd"
done
cp "$MOCK_BIN/gitleaks" "$NO_GIT_BIN/gitleaks"
PATH="$NO_GIT_BIN" printf '%s' \
  '{"tool_name":"Write","tool_input":{"content":"AGENT_GUARD_TEST_SECRET"}}' \
  | PATH="$NO_GIT_BIN" AGENT_GUARD_WARNING_DIR="$NO_GIT_WARN_DIR" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "non-git PreTool secret checks remain active when git is unavailable"
else
  not_ok "non-git PreTool secret checks remain active without git (expected 2, got $status)"
fi
printf '%s' \
  '{"session_id":"pre-git-missing-open","tool_name":"Bash","tool_input":{"command":"git commit -m clean"}}' \
  | PATH="$NO_GIT_BIN" AGENT_GUARD_WARNING_DIR="$NO_GIT_WARN_DIR" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -q 'AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
  ok "git-only PreTool gating follows the default open policy when git is unavailable"
else
  not_ok "git-only PreTool gating follows open policy without git (status $status)"
fi
printf '%s' \
  '{"session_id":"pre-git-missing-closed","tool_name":"Bash","tool_input":{"command":"git push"}}' \
  | PATH="$NO_GIT_BIN" AGENT_GUARD_WARNING_DIR="$NO_GIT_WARN_DIR" \
      AGENT_GUARD_INFRA_FAILURE_MODE=closed \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "git-only PreTool gating supports closed policy when git is unavailable"
else
  not_ok "git-only PreTool gating supports closed policy without git (expected 2, got $status)"
fi
printf '%s' \
  '{"session_id":"post-no-git","tool_name":"Write","tool_input":{"file_path":"note.txt"},"tool_response":"AGENT_GUARD_TEST_SECRET"}' \
  | PATH="$NO_GIT_BIN" AGENT_GUARD_WARNING_DIR="$NO_GIT_WARN_DIR" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -q '\[REDACTED\]' "$OUT" \
   && grep -q 'AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
  ok "PostTool repository gating follows open policy and output redaction remains active without git"
else
  not_ok "PostTool output redaction remains active without git (status $status)"
fi

# --- #125: scan_* fail CLOSED on a git-diff-specific failure ----------------
# POSIX sh has no pipefail, so `git diff | extract_added_lines` used to take
# awk's exit, not git's. A git-diff error therefore looked like an empty (clean)
# diff and the scan passed OPEN. A fake `git` that fails ONLY on `diff` (repo and
# HEAD checks still succeed) must now make the scan fail closed, not report clean.
REAL_GIT_125=$(command -v git)
FAIL125_GITDIR="$TMP_ROOT/fail125-fakegit"
mkdir -p "$FAIL125_GITDIR"
cat >"$FAIL125_GITDIR/git" <<EOF
#!/usr/bin/env sh
[ "\${1:-}" = "diff" ] && exit 7
exec "$REAL_GIT_125" "\$@"
EOF
chmod +x "$FAIL125_GITDIR/git"

FAIL125_REPO="$TMP_ROOT/fail125-repo"
mkdir -p "$FAIL125_REPO"
(
  cd "$FAIL125_REPO" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf '%s\n' "clean" > README.md
  git add README.md
  git commit -q -m init
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > staged.txt
  git add staged.txt
)

# MUST-PASS control: real git + staged secret is caught.
(
  cd "$FAIL125_REPO" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "#125 control: scan-staged catches a staged secret with real git"
else
  not_ok "#125 control: scan-staged catches a staged secret with real git (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# REGRESSION: only `git diff` fails -> must fail closed (SCAN_STATUS_UNAVAILABLE=3),
# never report clean (0).
(
  cd "$FAIL125_REPO" || exit 2
  PATH="$FAIL125_GITDIR:$PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 3 ]; then
  ok "#125 scan-staged fails closed when git diff fails"
else
  not_ok "#125 scan-staged fails closed when git diff fails (expected 3, got $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

# scan_working_tree, tracked-modification path: same targeted git-diff failure.
(
  cd "$FAIL125_REPO" || exit 2
  git reset -q
  rm -f staged.txt
  printf '%s\n' "baseline" > tracked.txt
  git add tracked.txt
  git commit -q -m base
  printf '%s\n' "baseline" "AGENT_GUARD_TEST_SECRET" > tracked.txt
)
# MUST-PASS control: real git catches the tracked-modification secret.
(
  cd "$FAIL125_REPO" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "#125 control: scan-working-tree catches a tracked-mod secret with real git"
else
  not_ok "#125 control: scan-working-tree catches a tracked-mod secret with real git (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
# REGRESSION: git diff fails -> fail closed.
(
  cd "$FAIL125_REPO" || exit 2
  PATH="$FAIL125_GITDIR:$PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 3 ]; then
  ok "#125 scan-working-tree fails closed when git diff fails"
else
  not_ok "#125 scan-working-tree fails closed when git diff fails (expected 3, got $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi
# MUST-FAIL control: clean tree with real git is allowed.
(
  cd "$FAIL125_REPO" || exit 2
  git checkout -q -- tracked.txt
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "#125 control: scan-working-tree allows a clean tree with real git"
else
  not_ok "#125 control: scan-working-tree allows a clean tree with real git (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- #126: scans cover the repo ROOT, not just the caller's cwd subtree -----
# Historically the diffs used `-- .` (cwd subtree) and ls-files ran in the raw
# cwd, so a secret staged/untracked OUTSIDE the caller's subdir was never seen,
# and the Stop/PostToolUse backstops scanned the process cwd instead of the
# event workdir. Both must now resolve the repo root and honor the event cwd.
ROOT126="$TMP_ROOT/root126"
mkdir -p "$ROOT126"
(
  cd "$ROOT126" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf '%s\n' "clean" > README.md
  git add README.md
  git commit -q -m init
  mkdir -p sub
  printf '%s\n' "hello" > sub/other.txt
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > root-secret.txt
  git add root-secret.txt
)

# REGRESSION: scan-staged run from a subdir must catch a secret staged at root.
(
  cd "$ROOT126/sub" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "#126 scan-staged from a subdir catches a secret staged at repo root"
else
  not_ok "#126 scan-staged from a subdir catches a secret staged at repo root (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# MUST-FAIL control: same subdir, clean tree -> allowed.
(
  cd "$ROOT126" || exit 2
  git reset -q
  rm -f root-secret.txt
)
(
  cd "$ROOT126/sub" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "#126 control: scan-staged from a subdir allows a clean tree"
else
  not_ok "#126 control: scan-staged from a subdir allows a clean tree (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# REGRESSION: scan-working-tree from a subdir must catch an untracked secret at root.
(
  cd "$ROOT126" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > root-untracked.txt
)
(
  cd "$ROOT126/sub" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "#126 scan-working-tree from a subdir catches an untracked secret at repo root"
else
  not_ok "#126 scan-working-tree from a subdir catches an untracked secret at repo root (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
rm -f "$ROOT126/root-untracked.txt"

# REGRESSION: commit gate driven from a subdir (no workdir in payload) must
# block a secret staged at repo root -> proves scan_staged is repo-root-scoped.
(
  cd "$ROOT126" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > root-secret.txt
  git add root-secret.txt
)
(
  cd "$ROOT126/sub" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ] && grep -q 'staged changes contain secret-like values' "$ERR"; then
  ok "#126 commit gate from a subdir blocks a secret staged at repo root"
else
  not_ok "#126 commit gate from a subdir blocks a secret staged at repo root (expected 2 + block msg, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
(
  cd "$ROOT126" || exit 2
  git reset -q
  rm -f root-secret.txt
)

# REGRESSION: hook_post_tool must honor the event workdir. Process cwd is a
# non-repo dir; the repo (with a secret) is named only in tool_input.workdir.
POST126="$TMP_ROOT/post126"
POST126_OTHER="$TMP_ROOT/post126-elsewhere"
mkdir -p "$POST126" "$POST126_OTHER"
(
  cd "$POST126" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf '%s\n' "clean" > README.md
  git add README.md
  git commit -q -m init
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leaked.txt
)
(
  cd "$POST126_OTHER" || exit 2
  jq -nc --arg wd "$POST126" \
    '{tool_name:"Write",tool_input:{file_path:"leaked.txt",workdir:$wd}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ] && grep -q 'changed files contain secret-like values' "$ERR"; then
  ok "#126 hook-post-tool scans the event workdir repo, not the process cwd"
else
  not_ok "#126 hook-post-tool scans the event workdir repo, not the process cwd (expected 2 + block msg, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
# MUST-FAIL control: clean event-workdir repo -> allowed (exit 0).
(
  cd "$POST126" || exit 2
  rm -f leaked.txt
)
(
  cd "$POST126_OTHER" || exit 2
  jq -nc --arg wd "$POST126" \
    '{tool_name:"Write",tool_input:{file_path:"README.md",workdir:$wd}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "#126 control: hook-post-tool allows a clean event-workdir repo"
else
  not_ok "#126 control: hook-post-tool allows a clean event-workdir repo (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# REGRESSION: hook_stop must honor the event workdir. Process cwd is a subdir of
# the repo; the event cwd (top-level .cwd) is the repo root; the secret is at
# root, outside the subdir subtree -> Stop must block.
(
  cd "$ROOT126" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > root-untracked.txt
)
(
  cd "$ROOT126/sub" || exit 2
  jq -nc --arg cwd "$ROOT126" '{stop_hook_active:false,cwd:$cwd}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ] && grep -q 'changed files contain secret-like values' "$ERR"; then
  ok "#126 hook-stop scans the event workdir root, not the process cwd subdir"
else
  not_ok "#126 hook-stop scans the event workdir root, not the process cwd subdir (expected 2 + block msg, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
# MUST-FAIL control: clean repo via event cwd -> allowed.
(
  cd "$ROOT126" || exit 2
  rm -f root-untracked.txt
)
(
  cd "$ROOT126/sub" || exit 2
  jq -nc --arg cwd "$ROOT126" '{stop_hook_active:false,cwd:$cwd}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "#126 control: hook-stop allows a clean event-workdir repo"
else
  not_ok "#126 control: hook-stop allows a clean event-workdir repo (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- gitleaks fail-closed when scanner errors ------------------------------

ERROR_BIN="$TMP_ROOT/error-bin"
mkdir -p "$ERROR_BIN"
cat > "$ERROR_BIN/gitleaks" <<'EOSH'
#!/usr/bin/env sh
echo "synthetic gitleaks failure" >&2
exit 3
EOSH
chmod +x "$ERROR_BIN/gitleaks"

PATH="$ERROR_BIN:$PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-path fail-closes when gitleaks itself errors"
else
  not_ok "scan-path fail-closes when gitleaks itself errors (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

ERROR_ZERO_BIN="$TMP_ROOT/error-zero-bin"
mkdir -p "$ERROR_ZERO_BIN"
cat > "$ERROR_ZERO_BIN/gitleaks" <<'EOSH'
#!/usr/bin/env sh
echo "ERR skipping file: synthetic unreadable fixture" >&2
exit 0
EOSH
chmod +x "$ERROR_ZERO_BIN/gitleaks"

PATH="$ERROR_ZERO_BIN:$PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-path fail-closes when gitleaks exits 0 but reports an error"
else
  not_ok "scan-path fail-closes on gitleaks exit-0 error output (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

PATH="$ERROR_BIN:$PATH" sh -c '
  printf "%s" "{\"session_id\":\"scanner-error-open\",\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"x\"}}" \
    | AGENT_GUARD_WARNING_DIR="'"$TESTTMP"'/scanner-error-warnings" \
      "'"$PLUGIN_ROOT"'/bin/agent-guard" hook-pre-tool
' >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -q 'AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
  ok "hook-pre-tool follows the default open policy when gitleaks errors"
else
  not_ok "hook-pre-tool follows the default open policy when gitleaks errors (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

PATH="$ERROR_BIN:$PATH" AGENT_GUARD_INFRA_FAILURE_MODE=closed sh -c '
  printf "%s" "{\"session_id\":\"scanner-error-closed\",\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"x\"}}" \
    | AGENT_GUARD_WARNING_DIR="'"$TESTTMP"'/scanner-error-warnings" \
      "'"$PLUGIN_ROOT"'/bin/agent-guard" hook-pre-tool
' >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-pre-tool supports opt-in closed policy when gitleaks errors"
else
  not_ok "hook-pre-tool supports opt-in closed policy when gitleaks errors (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- deny-bash-patterns fail-closed on invalid ERE -------------------------
# Regression guard: an invalid line in a custom deny file must NOT silently
# disable the rest of the policy. The combined `grep -f` exits with status 2,
# which we translate to a hard block instead of treating it as "no match".
BAD_PATTERNS_FILE="$TMP_ROOT/bad-deny-bash.txt"
printf '%s\n' '[unterminated-bracket' >"$BAD_PATTERNS_FILE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | AGENT_GUARD_DENY_BASH_PATTERNS="$BAD_PATTERNS_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "deny-bash-patterns invalid ERE fails closed"
else
  not_ok "deny-bash-patterns invalid ERE fails closed (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- deny-read-paths Bash scan fail-closed on invalid generated ERE --------
# Parity with the deny-bash guard above: a custom deny-read entry that converts
# to a grep-rejected ERE (here a trailing backslash) must hard-block during a
# Bash command scan, not silently allow the rest of the deny-read check.
BAD_READ_FILE="$TMP_ROOT/bad-deny-read.txt"
printf '%s\n' 'x\' >"$BAD_READ_FILE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | AGENT_GUARD_DENY_READ_PATHS="$BAD_READ_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "deny-read-paths invalid generated ERE fails closed in Bash scan"
else
  not_ok "deny-read-paths invalid generated ERE fails closed in Bash scan (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# No-regression: a valid custom deny-read file must still allow benign commands
# and still block a deny-listed path, so the fail-closed change does not over-block.
GOOD_READ_FILE="$TMP_ROOT/good-deny-read.txt"
printf '%s\n' '.env' >"$GOOD_READ_FILE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | AGENT_GUARD_DENY_READ_PATHS="$GOOD_READ_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/dev/null 2>&1
status=$?
if [ "$status" -eq 0 ]; then
  ok "valid deny-read file still allows a benign Bash command"
else
  not_ok "valid deny-read file still allows a benign Bash command (expected 0, got $status)"
fi
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}' \
  | AGENT_GUARD_DENY_READ_PATHS="$GOOD_READ_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  ok "valid deny-read file still blocks a deny-listed path in a Bash command"
else
  not_ok "valid deny-read file still blocks a deny-listed path in a Bash command (expected 2, got $status)"
fi

# Loop-level fail-closed: a bad-ERE entry placed AFTER a valid one must still
# hard-block, even for a command that matches neither entry. This distinguishes
# the real behavior (the scan reaches the bad entry and exits 2) from a
# silent-skip regression where the bad entry is `continue`d and the command,
# matching no valid entry, would slip through allowed.
MULTI_READ_FILE="$TMP_ROOT/multi-deny-read.txt"
printf '%s\n' '.env' 'x\' >"$MULTI_READ_FILE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | AGENT_GUARD_DENY_READ_PATHS="$MULTI_READ_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  ok "deny-read-paths loop fails closed when a bad entry follows a valid one"
else
  not_ok "deny-read-paths loop fails closed when a bad entry follows a valid one (expected 2, got $status)"
fi

# --- string-encoded tool_input is normalized, not silently skipped ----------
# A host may serialize tool_input as a JSON string. Without normalization every
# .tool_input.<field> extraction errors and yields empty, so the scan no-ops
# (fail-open). hook_pre_tool decodes a string tool_input back into an object so
# the existing checks still see the real fields. These cases take plain JSON, a
# single subcommand, and assert only on exit status, so they use the
# expect_json_status helper like the rest of the hook-pre-tool table.
expect_json_status 2 "object tool_input blocks a deny pattern (baseline)" \
  '{"tool_name":"Bash","tool_input":{"command":"printenv"}}' \
  hook-pre-tool
expect_json_status 2 "string-encoded tool_input blocks a deny pattern (no fail-open)" \
  '{"tool_name":"Bash","tool_input":"{\"command\":\"printenv\"}"}' \
  hook-pre-tool
# The normalization lives in hook_pre_tool before the per-tool dispatch, so it
# must also rescue content-scanning tools, not just Bash. A string-encoded Write
# whose decoded content holds a secret must block (without the fix, extracting
# .tool_input.content errors -> empty content -> scan finds nothing -> fail-open).
expect_json_status 2 "string-encoded Write tool_input with a secret is blocked" \
  '{"tool_name":"Write","tool_input":"{\"file_path\":\"app.txt\",\"content\":\"AGENT_GUARD_TEST_SECRET\"}"}' \
  hook-pre-tool
# Benign string-encoded commands/writes stay allowed (normalization does not over-block).
expect_json_status 0 "benign string-encoded tool_input is allowed" \
  '{"tool_name":"Bash","tool_input":"{\"command\":\"ls\"}"}' \
  hook-pre-tool
expect_json_status 0 "benign string-encoded Write tool_input is allowed" \
  '{"tool_name":"Write","tool_input":"{\"file_path\":\"app.txt\",\"content\":\"example_token\"}"}' \
  hook-pre-tool
# Only a string that decodes to an *object* is substituted. A non-object string
# (plain text, or JSON decoding to an array/scalar) is left UNCHANGED -- coercing
# it to {} would drop the leaf for the generic `.tool_input // {} | .. | strings`
# scanners (see the regression guard below). For Bash the precise .command
# extractor simply finds no field on a raw string, so there is nothing to scan.
expect_json_status 0 "non-JSON string Bash tool_input is allowed (no command to scan)" \
  '{"tool_name":"Bash","tool_input":"not json at all"}' \
  hook-pre-tool
expect_json_status 0 "array-decoding string Bash tool_input is allowed (no command to scan)" \
  '{"tool_name":"Bash","tool_input":"[1,2,3]"}' \
  hook-pre-tool
# Regression guard (P1, PR #60 review): a raw-string tool_input MUST still reach
# the generic scanners. mcp__*/WebFetch/WebSearch route through
# `.tool_input // {} | .. | strings`, which inspects the raw string leaf, so a
# string-encoded secret -- whether plain text or a JSON array/scalar that does
# not decode to an object -- must still block. Coercing such input to {} (the
# original R12 attempt) dropped the leaf and let a bare secret through.
expect_json_status 2 "raw-string MCP tool_input with a secret is blocked (no coerce-to-{} fail-open)" \
  '{"tool_name":"mcp__server__tool","tool_input":"AGENT_GUARD_TEST_SECRET"}' \
  hook-pre-tool
expect_json_status 2 "array-encoded-string MCP tool_input with a secret is blocked" \
  '{"tool_name":"mcp__server__tool","tool_input":"[\"AGENT_GUARD_TEST_SECRET\"]"}' \
  hook-pre-tool

# --- gitleaks not installed -----------------------------------------------

NO_GITLEAKS_BIN="$TMP_ROOT/no-gitleaks-bin"
mkdir -p "$NO_GITLEAKS_BIN"
ln -s "$REAL_SH" "$NO_GITLEAKS_BIN/sh"
ln -s "$REAL_DIRNAME" "$NO_GITLEAKS_BIN/dirname"
ln -s "$REAL_PWD" "$NO_GITLEAKS_BIN/pwd"
AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-path dies when gitleaks is unavailable"
else
  not_ok "scan-path dies when gitleaks is unavailable (expected 2, got $status)"
fi

# Reuse NO_GITLEAKS_BIN: jq must remain reachable so setup can report jq ok
# while gitleaks is missing.
ln -sf "$(command -v jq)" "$NO_GITLEAKS_BIN/jq"
ln -sf "$(command -v git)" "$NO_GITLEAKS_BIN/git"
ln -sf "$(command -v head)" "$NO_GITLEAKS_BIN/head"
ln -sf "$(command -v command)" "$NO_GITLEAKS_BIN/command" 2>/dev/null || true
ln -sf "$(command -v uname)" "$NO_GITLEAKS_BIN/uname" 2>/dev/null || true

AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
  "$PLUGIN_ROOT/bin/agent-guard" setup >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "setup exits 1 when gitleaks missing"
else
  not_ok "setup exits 1 when gitleaks missing (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
  "$PLUGIN_ROOT/bin/agent-guard" setup --install >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "setup --install without --gitleaks-checksum exits 2"
else
  not_ok "setup --install without --gitleaks-checksum exits 2 (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

DEGRADED_WARNING_DIR="$TESTTMP/degraded-warnings"
mkdir -p "$DEGRADED_WARNING_DIR"
printf '%s' '{"session_id":"degraded-session","tool_name":"Bash","tool_input":{"command":"brew install gitleaks"}}' \
  | AGENT_GUARD_WARNING_DIR="$DEGRADED_WARNING_DIR" \
    AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -q 'DEGRADED' "$ERR" && grep -q 'setup-agent-guard' "$ERR" \
   && grep -q 'AGENT_GUARD_INFRA_FAILURE_MODE=open' "$ERR"; then
  ok "hook degrades open with an actionable setup warning when dependencies are missing"
else
  not_ok "hook degrades open with an actionable setup warning (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

codex_setup_ref="\$setup-agent-guard"
claude_setup_ref='agent-guard:setup-agent-guard'

printf '%s' '{"tool_name":"Bash","tool_input":{"command":"brew install gitleaks"}}' \
  | AGENT_GUARD_HOOK_HOST=codex AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] \
   && grep -q 'DEGRADED' "$ERR" \
   && grep -Fq "$codex_setup_ref" "$ERR" \
   && ! grep -Fq "$claude_setup_ref" "$ERR"; then
  ok "Codex hook degrades open with Codex setup guidance"
else
  not_ok "Codex hook degraded mode uses Codex setup guidance (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"tool_name":"Bash","tool_input":{"command":"brew install gitleaks"}}' \
  | AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] \
   && grep -q 'DEGRADED' "$ERR" \
   && grep -Fq "$claude_setup_ref" "$ERR" \
   && ! grep -Fq "$codex_setup_ref" "$ERR"; then
  ok "Claude hook degrades open with Claude setup guidance"
else
  not_ok "Claude hook degraded mode uses Claude setup guidance (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"session_id":"degraded-session","tool_name":"Bash","tool_input":{"command":"echo clean"}}' \
  | AGENT_GUARD_WARNING_DIR="$DEGRADED_WARNING_DIR" \
    AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ ! -s "$ERR" ]; then
  ok "degraded dependency warning is emitted only once per session"
else
  not_ok "degraded dependency warning is emitted only once per session"
  sed 's/^/  stderr: /' "$ERR"
fi

printf '%s' '{"session_id":"degraded-closed","tool_name":"Bash","tool_input":{"command":"echo clean"}}' \
  | AGENT_GUARD_WARNING_DIR="$DEGRADED_WARNING_DIR" \
    AGENT_GUARD_INFRA_FAILURE_MODE=closed \
    AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "missing hook dependencies follow the opt-in closed infrastructure policy"
else
  not_ok "missing hook dependencies follow the opt-in closed infrastructure policy (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

EXEC_NOT_RUN="$TESTTMP/exec-not-run.txt"
AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c 'printf ran >"$1"' _ "$EXEC_NOT_RUN" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && [ ! -e "$EXEC_NOT_RUN" ]; then
  ok "exec fails closed before running a command when masking dependencies are missing"
else
  not_ok "exec missing-dependency preflight prevents execution (status $status)"
fi

PRIVATE_GL_DIR="$TESTTMP/private-gitleaks-bin"
mkdir -p "$PRIVATE_GL_DIR"
cp "$ROOT/tests/fixtures/mock-gitleaks" "$PRIVATE_GL_DIR/gitleaks"
chmod +x "$PRIVATE_GL_DIR/gitleaks"
AGENT_GUARD_GITLEAKS_BIN_DIR="$PRIVATE_GL_DIR" PATH="$NO_GITLEAKS_BIN" \
  "$PLUGIN_ROOT/bin/agent-guard" check >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -q 'gitleaks 0.0.0-mock' "$ERR"; then
  ok "check discovers gitleaks in Agent Guard's private install directory"
else
  not_ok "check discovers privately installed gitleaks (status $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- extract_patch_added_lines via apply_patch dialects -------------------

expect_json_status 0 "*** Delete File: hunk produces no scannable content" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Delete File: secrets.json\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "*** Update File: hunk added line is scanned" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: x\n@@\n context\n+AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 0 "*** Update File: context-only hunk is allowed" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: x\n@@\n context line\n-removed\n*** End Patch"}}' \
  hook-pre-tool

# --- MCP edge cases -------------------------------------------------------

expect_json_status 0 "MCP input without secret passes" \
  '{"tool_name":"mcp__server__tool","tool_input":{"prompt":"hello"}}' \
  hook-pre-tool

expect_json_status 2 "MCP input with secret in nested object is blocked" \
  '{"tool_name":"mcp__server__tool","tool_input":{"config":{"auth":{"token":"AGENT_GUARD_TEST_SECRET"}}}}' \
  hook-pre-tool

# --- "could not scan" is distinguishable from "found a secret" -------------
# Direct scan commands retain exit 3. At a hook boundary, infrastructure
# failures follow AGENT_GUARD_INFRA_FAILURE_MODE (open by default, closed when
# explicitly selected), while a real detection always blocks.

mkdir -p "$TMP_ROOT/not-a-repo"
# Canonicalize: $TMPDIR often ends in a slash, so "$TMP_ROOT/not-a-repo" can
# carry a `//` that the binary's own `pwd` normalizes away. Compare like for
# like, otherwise the message assertion below fails on punctuation.
NON_REPO_DIR=$(CDPATH= cd -- "$TMP_ROOT/not-a-repo" && pwd)
(
  cd "$NON_REPO_DIR" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 3 ]; then
  ok "scan-staged exits 3 (cannot scan) outside a git work tree"
else
  not_ok "scan-staged exits 3 (cannot scan) outside a git work tree (expected 3, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

CANNOT_SCAN_ERR="$TESTTMP/cannot-scan-err"
CANNOT_SCAN_ERR_SECOND="$TESTTMP/cannot-scan-err-second"
CANNOT_SCAN_WARN_DIR="$TESTTMP/cannot-scan-warnings"
(
  cd "$NON_REPO_DIR" || exit 2
  jq -nc --arg cwd "$NON_REPO_DIR" \
    '{session_id:"cannot-scan-session",tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$cwd}' \
    | AGENT_GUARD_WARNING_DIR="$CANNOT_SCAN_WARN_DIR" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$CANNOT_SCAN_ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "commit from a non-repo cwd follows the default open infrastructure policy"
else
  not_ok "commit from a non-repo cwd follows the default open infrastructure policy (expected 0, got $status)"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR"
fi

if grep -q 'could not scan' "$CANNOT_SCAN_ERR" \
  && grep -Fq "$NON_REPO_DIR" "$CANNOT_SCAN_ERR"; then
  ok "unscannable commit names the reason and the directory"
else
  not_ok "unscannable commit names the reason and the directory"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR"
fi

# Operators filter stderr on the `agent-guard: ` prefix, so a message that drops
# the colon is invisible to them no matter how well worded it is.
if grep -q '^agent-guard: could not scan' "$CANNOT_SCAN_ERR"; then
  ok "unscannable commit message keeps the agent-guard: prefix"
else
  not_ok "unscannable commit message keeps the agent-guard: prefix"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR"
fi

if grep -q 'scan-staged' "$CANNOT_SCAN_ERR"; then
  not_ok "unscannable commit message does not name an internal subcommand"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR"
else
  ok "unscannable commit message does not name an internal subcommand"
fi

if grep -q 'secret-like' "$CANNOT_SCAN_ERR"; then
  not_ok "unscannable commit is not reported as a secret detection"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR"
else
  ok "unscannable commit is not reported as a secret detection"
fi

if grep -q 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$CANNOT_SCAN_ERR"; then
  ok "default open infrastructure policy is explicit in the warning"
else
  not_ok "default open infrastructure policy is explicit in the warning"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR"
fi

(
  cd "$NON_REPO_DIR" || exit 2
  jq -nc --arg cwd "$NON_REPO_DIR" \
    '{session_id:"cannot-scan-session",tool_name:"Bash",tool_input:{command:"git push origin main"},cwd:$cwd}' \
    | AGENT_GUARD_WARNING_DIR="$CANNOT_SCAN_WARN_DIR" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$CANNOT_SCAN_ERR_SECOND"
)
status=$?
if [ "$status" -eq 0 ] \
   && ! grep -q 'continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open' "$CANNOT_SCAN_ERR_SECOND"; then
  ok "infrastructure policy warning is deduplicated once per session"
else
  not_ok "infrastructure policy warning is deduplicated once per session"
  sed 's/^/  stderr: /' "$CANNOT_SCAN_ERR_SECOND"
fi

(
  cd "$NON_REPO_DIR" || exit 2
  jq -nc --arg cwd "$NON_REPO_DIR" \
    '{session_id:"cannot-scan-closed",tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$cwd}' \
    | AGENT_GUARD_WARNING_DIR="$CANNOT_SCAN_WARN_DIR" \
      AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "closed infrastructure policy blocks an unscannable commit"
else
  not_ok "closed infrastructure policy blocks an unscannable commit (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

DETECTION_REPO="$TMP_ROOT/detection-repo"
DETECTION_ERR="$TESTTMP/detection-err"
mkdir -p "$DETECTION_REPO"
(
  cd "$DETECTION_REPO" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leak.txt
  git add leak.txt
  jq -nc --arg cwd "$DETECTION_REPO" \
    '{tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$cwd}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$DETECTION_ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "commit with a staged secret is still blocked"
else
  not_ok "commit with a staged secret is still blocked (expected 2, got $status)"
  sed 's/^/  stderr: /' "$DETECTION_ERR"
fi

if grep -q 'secret-like' "$DETECTION_ERR" \
  && ! grep -q 'could not scan' "$DETECTION_ERR"; then
  ok "secret detection is reported as a detection, not as a scan failure"
else
  not_ok "secret detection is reported as a detection, not as a scan failure"
  sed 's/^/  stderr: /' "$DETECTION_ERR"
fi

# --- install.sh git-hooks safety ------------------------------------------

EMPTY_TEMPLATE="$TMP_ROOT/empty-git-template"
mkdir -p "$EMPTY_TEMPLATE"

INSTALL_REPO="$TMP_ROOT/install-repo"
mkdir -p "$INSTALL_REPO"
(
  cd "$INSTALL_REPO" || exit 2
  # Use an empty template so this case validates the no-existing-hook path.
  git init -q --template="$EMPTY_TEMPLATE"
  git config user.email t@e
  git config user.name t
  "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "install.sh git-hooks succeeds in a clean repo"
else
  not_ok "install.sh git-hooks succeeds in a clean repo (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
configured=$(cd "$INSTALL_REPO" && git config --get core.hooksPath || true)
if [ "$configured" = "githooks" ]; then
  ok "install.sh sets core.hooksPath=githooks"
else
  not_ok "install.sh sets core.hooksPath=githooks (got: $configured)"
fi
if [ -x "$INSTALL_REPO/githooks/pre-commit" ]; then
  ok "install.sh writes an executable githooks/pre-commit"
else
  not_ok "install.sh writes an executable githooks/pre-commit"
fi
(
  cd "$INSTALL_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leak.txt
  git add leak.txt
  git commit -m leak >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -ne 0 ]; then
  ok "installed native git hook blocks a staged secret"
else
  not_ok "installed native git hook blocks a staged secret"
fi

QUOTE_SOURCE="$TMP_ROOT/source-with-quote\"dir"
QUOTE_REPO="$TMP_ROOT/quote-install-repo"
mkdir -p "$QUOTE_SOURCE/plugins/agent-guard/bin" "$QUOTE_REPO"
ln -s "$ROOT/install.sh" "$QUOTE_SOURCE/install.sh"
ln -s "$PLUGIN_ROOT/bin/agent-guard" "$QUOTE_SOURCE/plugins/agent-guard/bin/agent-guard"
(
  cd "$QUOTE_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config user.email t@e
  git config user.name t
  "$QUOTE_SOURCE/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && sh -n "$QUOTE_REPO/githooks/pre-commit"; then
  ok "install.sh quotes generated hook paths safely"
else
  not_ok "install.sh quotes generated hook paths safely (expected install success and shell syntax ok)"
  sed 's/^/  stderr: /' "$ERR"
fi
(
  cd "$QUOTE_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leak.txt
  git add leak.txt
  git commit -m leak >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -ne 0 ]; then
  ok "installed hook works when agent path contains a quote"
else
  not_ok "installed hook works when agent path contains a quote"
fi

CONFLICT_REPO="$TMP_ROOT/conflict-repo"
mkdir -p "$CONFLICT_REPO"
(
  cd "$CONFLICT_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config core.hooksPath someone-elses-hooks
  "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "install.sh refuses to overwrite an existing core.hooksPath"
else
  not_ok "install.sh refuses to overwrite an existing core.hooksPath (expected 2, got $status)"
fi

PRECOMMIT_REPO="$TMP_ROOT/precommit-repo"
PRECOMMIT_CANARY="$TMP_ROOT/precommit-canary"
mkdir -p "$PRECOMMIT_REPO"
(
  cd "$PRECOMMIT_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config user.email t@e
  git config user.name t
  mkdir -p .git/hooks
  {
    printf '%s\n' '#!/bin/sh'
    printf 'printf %%s legacy-ran > "%s"\n' "$PRECOMMIT_CANARY"
  } > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "install.sh chains an existing .git/hooks/pre-commit"
else
  not_ok "install.sh chains an existing .git/hooks/pre-commit (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
(
  cd "$PRECOMMIT_REPO" || exit 2
  printf '%s\n' ok > README.md
  git add README.md
  git commit -m init >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$PRECOMMIT_CANARY" 2>/dev/null)" = "legacy-ran" ]; then
  ok "installed hook runs the pre-existing pre-commit hook"
else
  not_ok "installed hook runs the pre-existing pre-commit hook"
  sed 's/^/  stderr: /' "$ERR"
fi

# Regression: refreshing our own hook must not DROP the legacy chain. The chain
# block is only generated when core.hooksPath was unset, and `git rev-parse
# --git-path hooks/pre-commit` honors core.hooksPath — so a second run cannot
# re-derive the legacy path (it would resolve to THIS hook and chain it to
# itself). The refresh therefore has to preserve the existing block. Ground truth
# is the canary: run install.sh again, commit for real, require the legacy hook
# to still fire.
rm -f "$PRECOMMIT_CANARY"
(
  cd "$PRECOMMIT_REPO" || exit 2
  "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "install.sh git-hooks re-run succeeds on an already-installed repo"
else
  not_ok "install.sh git-hooks re-run succeeds on an already-installed repo (expected 0, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
(
  cd "$PRECOMMIT_REPO" || exit 2
  printf '%s\n' ok > SECOND.md
  git add SECOND.md
  git commit -m second >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$PRECOMMIT_CANARY" 2>/dev/null)" = "legacy-ran" ]; then
  ok "re-running install.sh keeps the legacy pre-commit chained"
else
  not_ok "re-running install.sh keeps the legacy pre-commit chained (status $status, canary '$(cat "$PRECOMMIT_CANARY" 2>/dev/null)')"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- install.sh refreshes a stale hook and fails closed on a bad config write --
# Regression for #129: a matched-but-stale hook was left byte-identical (no-op
# `:`), and an unchecked `git config core.hooksPath` write printed success even
# when it failed.

# (1) A pre-existing hook that carries our marker but embeds a broken binary
# path must be regenerated in place to point at the freshly-resolved binary.
STALE_HOOK_REPO="$TMP_ROOT/stale-hook-repo"
mkdir -p "$STALE_HOOK_REPO"
(
  cd "$STALE_HOOK_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config user.email t@e
  git config user.name t
  mkdir -p githooks
  {
    printf '%s\n' '#!/usr/bin/env sh'
    printf '%s\n' 'set -u'
    printf '%s\n' "exec '/nonexistent/agent-guard' scan-staged"
  } > githooks/pre-commit
  chmod +x githooks/pre-commit
  "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
resolved_bin="$ROOT/plugins/agent-guard/bin/agent-guard"
if [ "$status" -eq 0 ] \
   && grep -Fq "$resolved_bin" "$STALE_HOOK_REPO/githooks/pre-commit" \
   && ! grep -Fq '/nonexistent/agent-guard' "$STALE_HOOK_REPO/githooks/pre-commit" \
   && [ -x "$STALE_HOOK_REPO/githooks/pre-commit" ]; then
  ok "install.sh refreshes a stale matched hook to the resolved binary"
else
  not_ok "install.sh refreshes a stale matched hook to the resolved binary (status $status)"
  sed 's/^/  hook: /' "$STALE_HOOK_REPO/githooks/pre-commit" 2>/dev/null
  sed 's/^/  stderr: /' "$ERR"
fi

# Regression: the refreshed hook (rewritten through a mktemp temp file, 0600)
# must end up readable AND executable by group/other, not just the owner. `chmod
# +x` alone would leave it at 711, and a `#!` hook needs read permission to run,
# so in a shared repo other users would hit "Permission denied". The owner-only
# `[ -x ]` check above cannot catch that; assert the full 755 mode here.
hook_mode=$(ls -l "$STALE_HOOK_REPO/githooks/pre-commit" 2>/dev/null | cut -c1-10)
if [ "$hook_mode" = "-rwxr-xr-x" ]; then
  ok "refreshed hook is group/other readable and executable (755, not 711)"
else
  not_ok "refreshed hook is group/other readable and executable (755): got '$hook_mode'"
fi

# (2) A failed `git config core.hooksPath` write must fail closed: non-zero exit
# and no false "configured/installed" success line. The stub forwards every git
# call to the real binary except the one config write, which it fails.
CONFIG_FAIL_REPO="$TMP_ROOT/config-fail-repo"
CONFIG_FAIL_STUB="$TMP_ROOT/config-fail-stub"
mkdir -p "$CONFIG_FAIL_REPO" "$CONFIG_FAIL_STUB"
real_git=$(command -v git)
cat >"$CONFIG_FAIL_STUB/git" <<'STUB'
#!/bin/sh
if [ "$1" = config ] && [ "$2" = core.hooksPath ] && [ "$3" = githooks ]; then
  echo "stub git: simulated config write failure" >&2
  exit 1
fi
exec "$REAL_GIT_BIN" "$@"
STUB
chmod +x "$CONFIG_FAIL_STUB/git"
(
  cd "$CONFIG_FAIL_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config user.email t@e
  git config user.name t
  REAL_GIT_BIN="$real_git" PATH="$CONFIG_FAIL_STUB:$PATH" \
    "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
config_fail_value=$("$real_git" -C "$CONFIG_FAIL_REPO" config --get core.hooksPath 2>/dev/null || true)
if [ "$status" -ne 0 ] \
   && [ -z "$config_fail_value" ] \
   && ! grep -q 'configured core.hooksPath' "$OUT"; then
  ok "install.sh fails closed when the core.hooksPath write fails"
else
  not_ok "install.sh fails closed when the core.hooksPath write fails (status $status, hooksPath '$config_fail_value')"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi

# (control) A clean fresh install must still succeed and wire core.hooksPath, so
# the two guards above cannot pass by simply rejecting every install.
CONTROL_REPO="$TMP_ROOT/control-install-repo"
mkdir -p "$CONTROL_REPO"
(
  cd "$CONTROL_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config user.email t@e
  git config user.name t
  "$ROOT/install.sh" git-hooks >"$OUT" 2>"$ERR"
)
status=$?
control_value=$(cd "$CONTROL_REPO" && git config --get core.hooksPath || true)
if [ "$status" -eq 0 ] && [ "$control_value" = "githooks" ] \
   && [ -x "$CONTROL_REPO/githooks/pre-commit" ]; then
  ok "install.sh clean fresh install still succeeds and wires core.hooksPath"
else
  not_ok "install.sh clean fresh install still succeeds and wires core.hooksPath (status $status, hooksPath '$control_value')"
  sed 's/^/  stderr: /' "$ERR"
fi

run_expect 2 "install.sh unknown subcommand exits 2" "$ROOT/install.sh" not-a-command
run_expect 0 "install.sh check passes" "$ROOT/install.sh" check

RELEASE_TARBALL_DIR="$TMP_ROOT/release-tarball"
mkdir -p "$RELEASE_TARBALL_DIR/out"
run_expect 0 "release tarball builder succeeds" \
  "$ROOT/scripts/build-release-tarball.sh" test "$RELEASE_TARBALL_DIR/agent-guard-test.tar.gz"
tar -xzf "$RELEASE_TARBALL_DIR/agent-guard-test.tar.gz" -C "$RELEASE_TARBALL_DIR/out"
if [ -x "$RELEASE_TARBALL_DIR/out/bin/agent-guard" ] \
   && [ -x "$RELEASE_TARBALL_DIR/out/install.sh" ] \
   && [ -f "$RELEASE_TARBALL_DIR/out/deployment/claude-managed-settings.example.json" ]; then
  ok "release tarball contains the CLI, installer, and managed settings example"
else
  not_ok "release tarball contains the CLI, installer, and managed settings example"
fi

# --- githooks/pre-commit invokes scan-staged ------------------------------

HOOK_REPO="$TMP_ROOT/hook-repo"
mkdir -p "$HOOK_REPO"
(
  cd "$HOOK_REPO" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leak.txt
  git add leak.txt
  "$ROOT/githooks/pre-commit" >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "githooks/pre-commit blocks commits with staged secrets"
else
  not_ok "githooks/pre-commit blocks commits with staged secrets (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- Codex full-payload routing -------------------------------------------
# Lock the contract against openai/codex's pre-tool-use input schema:
# event keys are PascalCase, payload keys are snake_case, and unknown keys
# (model, permission_mode, session_id, …) must not break routing.
# Bash and apply_patch are the two hook-visible tool_names Codex registers
# in core/src/tools/hook_names.rs; both must route correctly.
expect_json_status 2 "Codex full-payload Bash on .env is blocked" \
  '{"cwd":"/tmp","hook_event_name":"PreToolUse","model":"gpt-5","permission_mode":"default","session_id":"s1","tool_input":{"command":"cat .env"},"tool_name":"Bash","tool_use_id":"u1","transcript_path":null,"turn_id":"t1"}' \
  hook-pre-tool

expect_json_status 2 "Codex full-payload apply_patch with secret is blocked" \
  '{"cwd":"/tmp","hook_event_name":"PreToolUse","model":"gpt-5","permission_mode":"default","session_id":"s1","tool_input":{"patch":"*** Begin Patch\n*** Add File: leak.txt\n+AGENT_GUARD_TEST_SECRET\n*** End Patch"},"tool_name":"apply_patch","tool_use_id":"u2","transcript_path":null,"turn_id":"t1"}' \
  hook-pre-tool

# --- Untracked single-shot scan -------------------------------------------
SHOT_REPO="$TMP_ROOT/shot-repo"
mkdir -p "$SHOT_REPO"
(
  cd "$SHOT_REPO" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf 'ok\n' > README.md
  git add README.md
  git commit -q -m init
  for i in 1 2 3 4 5; do
    printf 'lorem ipsum %d\n' "$i" > "untracked_$i.txt"
  done
  printf 'AGENT_GUARD_TEST_SECRET\n' >> untracked_3.txt
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree single-shot detects a secret among 5 untracked files"
else
  not_ok "scan-working-tree single-shot detects a secret among 5 untracked files (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
if grep -q 'untracked files' "$ERR"; then
  ok "single-shot scan reports an 'untracked files' label"
else
  not_ok "single-shot scan reports an 'untracked files' label"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- Untracked scan is NUL-safe for non-ASCII filenames (Rank 4) ----------
# git ls-files quotes non-ASCII paths unless core.quotePath=false; a newline
# read loop would also mangle them. The scan must still see this file's secret.
UTF8_REPO="$TMP_ROOT/utf8-repo"
mkdir -p "$UTF8_REPO"
(
  cd "$UTF8_REPO" || exit 2
  git init -q
  git config user.email t@e
  git config user.name t
  printf 'ok\n' > README.md
  git add README.md
  git commit -q -m init
  printf 'AGENT_GUARD_TEST_SECRET\n' > 'café-secret.txt'
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >"$OUT" 2>"$ERR"
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree detects a secret in a non-ASCII untracked filename"
else
  not_ok "scan-working-tree detects a secret in a non-ASCII untracked filename (expected 1, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi

# --- agent-guard check announces gitleaks version ------------------------
"$PLUGIN_ROOT/bin/agent-guard" check >"$OUT" 2>"$ERR"
if grep -q 'gitleaks' "$ERR"; then
  ok "check prints a gitleaks version line"
else
  not_ok "check prints a gitleaks version line"
  sed 's/^/  stderr: /' "$ERR"
fi

# Context-free mutation/diff fragments cannot safely inherit structural
# lockfile checksum filtering. This scanner stub models a supported custom rule
# that treats nested 64-hex and h1-shaped values after api_token as findings;
# the bundled default rules do not independently flag these exact samples.
LOCK_FRAGMENT_HEX=$(printf '%s%s' \
  'b112c9dc389ca44de72cc0d3a732746a' \
  '423354b9fffedbc467449a8601ea3269')
LOCK_FRAGMENT_H1_BODY=$(awk 'BEGIN { for (i = 0; i < 43; i++) printf "A" }')
LOCK_FRAGMENT_H1="h1:$LOCK_FRAGMENT_H1_BODY="
LOCK_FRAGMENT_SHA512="${LOCK_FRAGMENT_H1_BODY}${LOCK_FRAGMENT_H1_BODY}=="
LOCK_FRAGMENT_BIN="$TMP_ROOT/lockfile-fragment-bin"
mkdir -p "$LOCK_FRAGMENT_BIN"
cat >"$LOCK_FRAGMENT_BIN/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in
  stdin)
    input=$(cat)
    if printf '%s\n' "$input" \
      | grep -Eq 'api_token.*(checksum[[:space:]]*=[[:space:]]*"[0-9a-f]{64}"|hash[[:space:]]*=[[:space:]]*"sha256:[0-9a-f]{64}"|h1:[A-Za-z0-9+/]{43}=)|integrity"[[:space:]]*:[[:space:]]*"sha512-[A-Za-z0-9+/]{86}=="' \
      || printf '%s\n' "$input" | awk '
        $0 == "[credentials]" {
          inside_credentials = 1
          next
        }
        /^[[:space:]]*\[/ {
          inside_credentials = 0
        }
        inside_credentials \
            && /^checksum[[:space:]]*=[[:space:]]*"[0-9a-f]+"/ {
          value = $0
          sub(/^checksum[[:space:]]*=[[:space:]]*"/, "", value)
          sub(/".*$/, "", value)
          if (length(value) == 64 && value !~ /[^0-9a-f]/)
            found = 1
        }
        inside_credentials \
            && /hash[[:space:]]*=[[:space:]]*"sha256:[0-9a-f]+"/ {
          value = $0
          sub(/^.*hash[[:space:]]*=[[:space:]]*"sha256:/, "", value)
          sub(/".*$/, "", value)
          if (length(value) == 64 && value !~ /[^0-9a-f]/)
            found = 1
        }
        END { exit found ? 0 : 1 }
      '; then
      printf '%s\n' 'Finding: REDACTED'
      exit 1
    fi
    exit 0
    ;;
  version) printf '%s\n' '0.0.0-lock-fragment-test' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$LOCK_FRAGMENT_BIN/gitleaks"

LOCK_FRAGMENT_REPO="$TMP_ROOT/lockfile-fragment-git-dir"
mkdir -p "$LOCK_FRAGMENT_REPO"
(
  cd "$LOCK_FRAGMENT_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Agent Guard Tests"
  printf '%s\n%s\n%s\n' 'note = """' baseline '"""' >Cargo.lock
  git add Cargo.lock
  git commit -q -m init
  printf '%s\n%s\n%s\n%s\n' 'note = """' baseline \
    "api_token = { checksum = \"$LOCK_FRAGMENT_HEX\" }" '"""' >Cargo.lock
  git add Cargo.lock
)
(
  cd "$LOCK_FRAGMENT_REPO"
  AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-staged
) >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-staged scans TOML fragments without guessing multiline-string context"
else
  not_ok "scan-staged blocks a checksum-shaped credential in an unchanged multiline string (expected 1, got $status)"
fi

lock_fragment="api_token = { checksum = \"$LOCK_FRAGMENT_HEX\" }"
lock_full_cargo=$(printf '%s\n%s\n%s' '[credentials]' \
  'api_token = "marker"' "checksum = \"$LOCK_FRAGMENT_HEX\"")
lock_full_uv=$(printf '%s\n%s\n%s' '[credentials]' \
  'api_token = "marker"' \
  "sdist = { url = \"https://example.invalid/a\", hash = \"sha256:$LOCK_FRAGMENT_HEX\" }")
lock_full_package=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' '{' \
  '  "packages": {' \
  '    "node_modules/example": {' \
  '      "api_token": {' \
  "        \"integrity\": \"sha512-$LOCK_FRAGMENT_SHA512\"" \
  '      }' \
  '    }' \
  '  }' '}')
lock_structural_package=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' '{' \
  '  "packages": {' \
  '    "node_modules/example": {' \
  "      \"integrity\": \"sha512-$LOCK_FRAGMENT_SHA512\"" \
  '    }' \
  '  }' '}')
lock_truncated_package=$(printf '%s\n%s\n%s\n%s' '{' \
  '  "packages": {' \
  '    "node_modules/example": {' \
  "      \"integrity\": \"sha512-$LOCK_FRAGMENT_SHA512\"")
lock_package_fragment=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' '{' \
  '  "api_token": {' \
  '    "packages": {' \
  '      "node_modules/example": {' \
  "        \"integrity\": \"sha512-$LOCK_FRAGMENT_SHA512\"" \
  '      }' \
  '    }' \
  '  }' '}')
lock_edit_input=$(jq -nc --arg content "$lock_fragment" \
  '{tool_name:"Edit",tool_input:{file_path:"Cargo.lock",new_string:$content}}')
printf '%s' "$lock_edit_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Edit scans a structural TOML-looking fragment conservatively"
else
  not_ok "Edit blocks a checksum-shaped credential without surrounding TOML context (expected 2, got $status)"
fi

lock_uv_fragment="api_token = { hash = \"sha256:$LOCK_FRAGMENT_HEX\" }"
lock_uv_edit_input=$(jq -nc --arg content "$lock_uv_fragment" \
  '{tool_name:"Edit",tool_input:{file_path:"uv.lock",new_string:$content}}')
printf '%s' "$lock_uv_edit_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Edit scans a structural uv.lock fragment conservatively"
else
  not_ok "Edit blocks a hash-shaped credential without surrounding uv.lock context (expected 2, got $status)"
fi

lock_go_fragment="api_token v1.2.3 $LOCK_FRAGMENT_H1"
lock_go_edit_input=$(jq -nc --arg content "$lock_go_fragment" \
  '{tool_name:"Edit",tool_input:{file_path:"go.sum",new_string:$content}}')
printf '%s' "$lock_go_edit_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Edit does not infer a complete go.sum record from a replacement fragment"
else
  not_ok "Edit preserves a checksum-shaped custom finding without earlier go.sum context (expected 2, got $status)"
fi

lock_multi_edit_input=$(jq -nc --arg content "$lock_fragment" \
  '{tool_name:"MultiEdit",tool_input:{file_path:"Cargo.lock",edits:[{new_string:$content}]}}')
printf '%s' "$lock_multi_edit_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "MultiEdit scans structural TOML-looking fragments conservatively"
else
  not_ok "MultiEdit blocks a checksum-shaped credential without surrounding TOML context (expected 2, got $status)"
fi

lock_fragment_patch=$(printf '%s\n%s\n%s\n%s\n%s\n' \
  '*** Begin Patch' '*** Update File: Cargo.lock' '@@' \
  "+$lock_fragment" '*** End Patch')
lock_fragment_patch_input=$(jq -nc --arg patch "$lock_fragment_patch" \
  '{tool_name:"apply_patch",tool_input:{patch:$patch}}')
printf '%s' "$lock_fragment_patch_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "apply_patch scans structural TOML-looking fragments conservatively"
else
  not_ok "apply_patch blocks a checksum-shaped credential without surrounding TOML context (expected 2, got $status)"
fi

lock_package_fragment_patch=$(printf '%s\n' \
  '*** Begin Patch' '*** Update File: package-lock.json' '@@' \
  '+{' '+  "api_token": {' '+    "packages": {' \
  '+      "node_modules/example": {' \
  "+        \"integrity\": \"sha512-$LOCK_FRAGMENT_SHA512\"" \
  '+      }' '+    }' '+  }' '+}' '*** End Patch')
lock_package_fragment_patch_input=$(jq -nc \
  --arg patch "$lock_package_fragment_patch" \
  '{tool_name:"apply_patch",tool_input:{patch:$patch}}')
printf '%s' "$lock_package_fragment_patch_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "apply_patch scans package-lock fragments without guessing JSON depth"
else
  not_ok "apply_patch keeps fragmentary package-lock integrity scannable (expected 2, got $status)"
fi

# Complete lockfiles have parser context, but checksum/hash neutralization must
# still be limited to fields that the actual Cargo and uv schemas generate.
lock_write_input=$(jq -nc --arg content "$lock_full_cargo" \
  '{tool_name:"Write",tool_input:{file_path:"Cargo.lock",content:$content}}')
printf '%s' "$lock_write_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Write preserves Cargo checksum values outside dependency tables"
else
  not_ok "Write keeps non-schema Cargo checksum fields scannable (expected 2, got $status)"
fi

LOCK_FULL_CONTEXT_DIR="$TMP_ROOT/lockfile-full-context-dir"
mkdir -p "$LOCK_FULL_CONTEXT_DIR"
printf '%s\n' "$lock_full_cargo" >"$LOCK_FULL_CONTEXT_DIR/Cargo.lock"
AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$LOCK_FULL_CONTEXT_DIR" \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-path preserves Cargo checksum values outside dependency tables"
else
  not_ok "scan-path keeps non-schema Cargo checksum fields scannable (expected 1, got $status)"
fi

lock_uv_write_input=$(jq -nc --arg content "$lock_full_uv" \
  '{tool_name:"Write",tool_input:{file_path:"uv.lock",content:$content}}')
printf '%s' "$lock_uv_write_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Write preserves uv hash values outside artifact records"
else
  not_ok "Write keeps non-schema uv hash fields scannable (expected 2, got $status)"
fi

printf '%s\n' "$lock_full_uv" >"$LOCK_FULL_CONTEXT_DIR/uv.lock"
AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path "$LOCK_FULL_CONTEXT_DIR/uv.lock" \
  >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-path preserves uv hash values outside artifact records"
else
  not_ok "scan-path keeps non-schema uv hash fields scannable (expected 1, got $status)"
fi

lock_package_write_input=$(jq -nc --arg content "$lock_full_package" \
  '{tool_name:"Write",tool_input:{file_path:"package-lock.json",content:$content}}')
printf '%s' "$lock_package_write_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Write preserves package-lock integrity values outside package maps"
else
  not_ok "Write keeps non-schema package-lock integrity fields scannable (expected 2, got $status)"
fi

printf '%s\n' "$lock_full_package" >"$LOCK_FULL_CONTEXT_DIR/package-lock.json"
AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path \
    "$LOCK_FULL_CONTEXT_DIR/package-lock.json" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-path preserves package-lock integrity values outside package maps"
else
  not_ok "scan-path keeps non-schema package-lock integrity fields scannable (expected 1, got $status)"
fi

lock_truncated_write_input=$(jq -nc --arg content "$lock_truncated_package" \
  '{tool_name:"Write",tool_input:{file_path:"package-lock.json",content:$content}}')
printf '%s' "$lock_truncated_write_input" \
  | AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "Write scans malformed package-lock content without early neutralization"
else
  not_ok "Write keeps malformed package-lock integrity scannable (expected 2, got $status)"
fi

LOCK_SNAPSHOT_FAIL_BIN="$TMP_ROOT/package-lock-snapshot-fail-bin"
LOCK_SNAPSHOT_FAIL_MARKER="$TMP_ROOT/package-lock-snapshot-fail-marker"
mkdir -p "$LOCK_SNAPSHOT_FAIL_BIN"
cat >"$LOCK_SNAPSHOT_FAIL_BIN/cat" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "--" ] && [ ! -e "$AG_TEST_CAT_FAIL_MARKER" ]; then
  : >"$AG_TEST_CAT_FAIL_MARKER"
  exit 1
fi
exec "$AG_TEST_REAL_CAT" "$@"
STUB
chmod +x "$LOCK_SNAPSHOT_FAIL_BIN/cat"
lock_snapshot_fail_write_input=$(jq -nc --arg content "$lock_structural_package" \
  '{tool_name:"Write",tool_input:{file_path:"package-lock.json",content:$content}}')
printf '%s' "$lock_snapshot_fail_write_input" \
  | AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
      AG_TEST_CAT_FAIL_MARKER="$LOCK_SNAPSHOT_FAIL_MARKER" \
      AG_TEST_REAL_CAT="$REAL_CAT" \
      PATH="$LOCK_SNAPSHOT_FAIL_BIN:$PATH" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ] && [ -e "$LOCK_SNAPSHOT_FAIL_MARKER" ]; then
  ok "Write scans raw package-lock content when snapshot copying fails"
else
  not_ok "Write does not treat package-lock snapshot failure as clean (expected 2, got $status)"
fi

printf '%s\n' "$lock_truncated_package" \
  >"$LOCK_FULL_CONTEXT_DIR/package-lock.json"
AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
  "$PLUGIN_ROOT/bin/agent-guard" scan-path \
    "$LOCK_FULL_CONTEXT_DIR/package-lock.json" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-path preserves malformed package-lock integrity values"
else
  not_ok "scan-path keeps malformed package-lock integrity scannable (expected 1, got $status)"
fi

LOCK_PACKAGE_FRAGMENT_REPO="$TMP_ROOT/package-lock-fragment-git-dir"
mkdir -p "$LOCK_PACKAGE_FRAGMENT_REPO"
(
  cd "$LOCK_PACKAGE_FRAGMENT_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Agent Guard Tests"
  printf '%s\n' '{"api_token":null}' >package-lock.json
  git add package-lock.json
  git commit -q -m init
  printf '%s\n' "$lock_package_fragment" >package-lock.json
  git add package-lock.json
  AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-staged
) >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-staged scans package-lock fragments without guessing JSON depth"
else
  not_ok "scan-staged keeps fragmentary package-lock integrity scannable (expected 1, got $status)"
fi

LOCK_FULL_CONTEXT_REPO="$TMP_ROOT/lockfile-full-context-repo"
mkdir -p "$LOCK_FULL_CONTEXT_REPO"
(
  cd "$LOCK_FULL_CONTEXT_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Agent Guard Tests"
  printf '%s\n' clean >README.md
  git add README.md
  git commit -q -m init
  printf '%s\n' "$lock_full_cargo" >Cargo.lock
  AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree
) >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "untracked scanning preserves Cargo checksum values outside dependency tables"
else
  not_ok "untracked Cargo content keeps non-schema checksum fields scannable (expected 1, got $status)"
fi

LOCK_INVALID_PACKAGE_REPO="$TMP_ROOT/package-lock-invalid-git-dir"
mkdir -p "$LOCK_INVALID_PACKAGE_REPO"
(
  cd "$LOCK_INVALID_PACKAGE_REPO"
  git init -q
  git config user.email test@example.com
  git config user.name "Agent Guard Tests"
  printf '%s\n' clean >README.md
  git add README.md
  git commit -q -m init
  printf '%s\n' "$lock_truncated_package" >package-lock.json
  AGENT_GUARD_GITLEAKS_BIN="$LOCK_FRAGMENT_BIN/gitleaks" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree
) >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 1 ]; then
  ok "untracked scanning preserves malformed package-lock integrity values"
else
  not_ok "untracked malformed package-lock integrity remains scannable (expected 1, got $status)"
fi

LOCK_INCOMPLETE_TOML_DIR="$TMP_ROOT/lockfile-incomplete-toml-dir"
mkdir -p "$LOCK_INCOMPLETE_TOML_DIR"
{
  printf '%s\n' '[[package]]'
  printf 'checksum = "%s"\n' "$LOCK_FRAGMENT_HEX"
  printf '%s\n' 'note = """'
  printf '%s\n' 'unterminated'
} >"$LOCK_INCOMPLETE_TOML_DIR/Cargo.lock"
{
  printf '%s\n' '[[package]]'
  printf 'sdist = { url = "https://example.invalid/pkg", hash = "sha256:%s" }\n' \
    "$LOCK_FRAGMENT_HEX"
  printf "%s\n" "note = '''"
  printf '%s\n' 'unterminated'
} >"$LOCK_INCOMPLETE_TOML_DIR/uv.lock"

LOCK_INCOMPLETE_QUOTE_DIR="$TMP_ROOT/lockfile-incomplete-quote-dir"
LOCK_INCOMPLETE_INLINE_DIR="$TMP_ROOT/lockfile-incomplete-inline-dir"
LOCK_INCOMPLETE_ARRAY_DIR="$TMP_ROOT/lockfile-incomplete-array-dir"
mkdir -p "$LOCK_INCOMPLETE_QUOTE_DIR" "$LOCK_INCOMPLETE_INLINE_DIR" \
  "$LOCK_INCOMPLETE_ARRAY_DIR"
for incomplete_toml_dir in "$LOCK_INCOMPLETE_QUOTE_DIR" \
    "$LOCK_INCOMPLETE_INLINE_DIR" "$LOCK_INCOMPLETE_ARRAY_DIR"; do
  case "$incomplete_toml_dir" in
    "$LOCK_INCOMPLETE_QUOTE_DIR") incomplete_toml_tail='note = "unterminated' ;;
    "$LOCK_INCOMPLETE_INLINE_DIR") incomplete_toml_tail='note = { key = "value"' ;;
    "$LOCK_INCOMPLETE_ARRAY_DIR") incomplete_toml_tail='note = [1, 2' ;;
  esac
  {
    printf '%s\n' '[[package]]'
    printf 'checksum = "%s"\n' "$LOCK_FRAGMENT_HEX"
    printf '%s\n' "$incomplete_toml_tail"
  } >"$incomplete_toml_dir/Cargo.lock"
  {
    printf '%s\n' '[[package]]'
    printf 'sdist = { url = "https://example.invalid/pkg", hash = "sha256:%s" }\n' \
      "$LOCK_FRAGMENT_HEX"
    printf '%s\n' "$incomplete_toml_tail"
  } >"$incomplete_toml_dir/uv.lock"
done

for incomplete_toml_dir in "$LOCK_INCOMPLETE_TOML_DIR" \
    "$LOCK_INCOMPLETE_QUOTE_DIR" "$LOCK_INCOMPLETE_INLINE_DIR" \
    "$LOCK_INCOMPLETE_ARRAY_DIR"; do
  incomplete_toml_case=${incomplete_toml_dir##*lockfile-incomplete-}
  incomplete_toml_case=${incomplete_toml_case%-dir}
  for incomplete_toml_name in Cargo.lock uv.lock; do
    incomplete_toml_path="$incomplete_toml_dir/$incomplete_toml_name"
    incomplete_toml_filtered="$incomplete_toml_dir/$incomplete_toml_name.filtered"
    "$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
      "$incomplete_toml_path" "$incomplete_toml_path" >"$incomplete_toml_filtered"
    status=$?
    if [ "$status" -eq 0 ] \
        && cmp -s "$incomplete_toml_path" "$incomplete_toml_filtered"; then
      ok "$incomplete_toml_name filtering falls back for incomplete $incomplete_toml_case TOML"
    else
      not_ok "$incomplete_toml_name filtering must preserve incomplete $incomplete_toml_case TOML"
    fi
  done
done

LOCK_INCOMPLETE_TOML_BIN="$TMP_ROOT/lockfile-incomplete-toml-bin"
mkdir -p "$LOCK_INCOMPLETE_TOML_BIN"
cat >"$LOCK_INCOMPLETE_TOML_BIN/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in
  stdin)
    if grep -Eq '[0-9a-f]{64}|h1:[A-Za-z0-9+/]{43}=|sha512-[A-Za-z0-9+/]{86}=='; then
      printf '%s\n' 'Finding: REDACTED'
      exit 1
    fi
    exit 0
    ;;
  version) printf '%s\n' '0.0.0-incomplete-toml-test' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$LOCK_INCOMPLETE_TOML_BIN/gitleaks"
for incomplete_toml_dir in "$LOCK_INCOMPLETE_TOML_DIR" \
    "$LOCK_INCOMPLETE_QUOTE_DIR" "$LOCK_INCOMPLETE_INLINE_DIR" \
    "$LOCK_INCOMPLETE_ARRAY_DIR"; do
  incomplete_toml_case=${incomplete_toml_dir##*lockfile-incomplete-}
  incomplete_toml_case=${incomplete_toml_case%-dir}
  for incomplete_toml_name in Cargo.lock uv.lock; do
    AGENT_GUARD_GITLEAKS_BIN="$LOCK_INCOMPLETE_TOML_BIN/gitleaks" \
      "$PLUGIN_ROOT/bin/agent-guard" scan-path \
        "$incomplete_toml_dir/$incomplete_toml_name" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 1 ]; then
      ok "scan-path keeps incomplete $incomplete_toml_case $incomplete_toml_name scannable"
    else
      not_ok "scan-path must detect bytes in incomplete $incomplete_toml_case $incomplete_toml_name (expected 1, got $status)"
    fi
  done
done

LOCK_MALFORMED_TAIL_DIR="$TMP_ROOT/lockfile-malformed-tail-dir"
mkdir -p "$LOCK_MALFORMED_TAIL_DIR"
printf 'example.com/module v1.0.0 %s trailing-junk\n' \
  "$LOCK_FRAGMENT_H1" >"$LOCK_MALFORMED_TAIL_DIR/go.sum"
printf '  integrity sha512-%s trailing-junk\n' \
  "$LOCK_FRAGMENT_SHA512" >"$LOCK_MALFORMED_TAIL_DIR/yarn.lock"
{
  printf '%s\n' '[[package]]'
  printf 'checksum = "%s", trailing-junk\n' "$LOCK_FRAGMENT_HEX"
} >"$LOCK_MALFORMED_TAIL_DIR/Cargo.lock"
for malformed_tail_name in go.sum yarn.lock Cargo.lock; do
  malformed_tail_path="$LOCK_MALFORMED_TAIL_DIR/$malformed_tail_name"
  malformed_tail_filtered="$LOCK_MALFORMED_TAIL_DIR/$malformed_tail_name.filtered"
  "$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$malformed_tail_path" "$malformed_tail_path" >"$malformed_tail_filtered"
  status=$?
  if [ "$status" -eq 0 ] \
      && cmp -s "$malformed_tail_path" "$malformed_tail_filtered"; then
    ok "$malformed_tail_name filtering preserves malformed trailing data"
  else
    not_ok "$malformed_tail_name filtering must not neutralize before trailing data"
  fi
  AGENT_GUARD_GITLEAKS_BIN="$LOCK_INCOMPLETE_TOML_BIN/gitleaks" \
    "$PLUGIN_ROOT/bin/agent-guard" scan-path "$malformed_tail_path" \
      >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-path keeps malformed $malformed_tail_name checksum bytes scannable"
  else
    not_ok "scan-path must detect checksum bytes before trailing data in $malformed_tail_name (expected 1, got $status)"
  fi
done

LOCK_SCHEMA_DIR="$TMP_ROOT/lockfile-schema-dir"
mkdir -p "$LOCK_SCHEMA_DIR"
{
  printf '%s\n' '[[package]]'
  printf 'checksum = "%s"\n' "$LOCK_FRAGMENT_HEX"
  printf '%s\n' '[root]'
  printf 'checksum = "%s"\n' "$LOCK_FRAGMENT_HEX"
  printf '%s\n' '[[patch.unused]]'
  printf 'checksum = "%s"\n' "$LOCK_FRAGMENT_HEX"
  printf '%s\n' '[credentials]'
  printf '%s\n' 'api_token = "marker"'
  printf 'checksum = "%s"\n' "$LOCK_FRAGMENT_HEX"
} >"$LOCK_SCHEMA_DIR/Cargo.lock"
cargo_schema_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  "$LOCK_SCHEMA_DIR/Cargo.lock" "$LOCK_SCHEMA_DIR/Cargo.lock")
cargo_schema_expected=$(printf '[[package]]\nchecksum = "CHECKSUM"\n[root]\nchecksum = "CHECKSUM"\n[[patch.unused]]\nchecksum = "CHECKSUM"\n[credentials]\napi_token = "marker"\nchecksum = "%s"' \
  "$LOCK_FRAGMENT_HEX")
if [ "$cargo_schema_filtered" = "$cargo_schema_expected" ]; then
  ok "Cargo.lock filtering is limited to dependency checksum tables"
else
  not_ok "Cargo.lock filtering preserves checksum fields outside its generated schema"
fi

{
  printf '%s\n' '[[package]]'
  printf 'sdist = { url = "https://example.invalid/sdist", hash = "sha256:%s" }\n' \
    "$LOCK_FRAGMENT_HEX"
  printf '%s\n' 'wheels = ['
  printf '    { url = "https://example.invalid/a", hash = "sha256:%s" },\n' \
    "$LOCK_FRAGMENT_HEX"
  printf '    { url = "https://example.invalid/b", hash = "sha256:%s" },\n' \
    "$LOCK_FRAGMENT_HEX"
  printf '%s\n' ']'
  printf '%s\n' '[[distribution]]'
  printf 'sdist = { url = "https://example.invalid/legacy", hash = "sha256:%s" }\n' \
    "$LOCK_FRAGMENT_HEX"
  printf '%s\n' '[credentials]'
  printf '%s\n' 'api_token = "marker"'
  printf 'sdist = { url = "https://example.invalid/forged", hash = "sha256:%s" }\n' \
    "$LOCK_FRAGMENT_HEX"
} >"$LOCK_SCHEMA_DIR/uv.lock"
uv_schema_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  "$LOCK_SCHEMA_DIR/uv.lock" "$LOCK_SCHEMA_DIR/uv.lock")
uv_schema_expected=$(printf '[[package]]\nsdist = { url = "https://example.invalid/sdist", hash = "sha256:CHECKSUM" }\nwheels = [\n    { url = "https://example.invalid/a", hash = "sha256:CHECKSUM" },\n    { url = "https://example.invalid/b", hash = "sha256:CHECKSUM" },\n]\n[[distribution]]\nsdist = { url = "https://example.invalid/legacy", hash = "sha256:CHECKSUM" }\n[credentials]\napi_token = "marker"\nsdist = { url = "https://example.invalid/forged", hash = "sha256:%s" }' \
  "$LOCK_FRAGMENT_HEX")
if [ "$uv_schema_filtered" = "$uv_schema_expected" ]; then
  ok "uv.lock filtering is limited to URL-bearing artifact records"
else
  not_ok "uv.lock filtering preserves hash fields outside generated artifact records"
fi

LOCK_NUL_UV="$LOCK_SCHEMA_DIR/uv-nul.lock"
LOCK_NUL_FILTERED="$LOCK_SCHEMA_DIR/uv-nul.filtered"
{
  printf '%s\n' '[[package]]'
  printf 'sdist = { url = "https://example.invalid/nul", hash = "sha256:%s" }' \
    "$LOCK_FRAGMENT_HEX"
  printf '\000api_token = "%s"\n' "$LOCK_FRAGMENT_HEX"
} >"$LOCK_NUL_UV"
"$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  uv.lock "$LOCK_NUL_UV" >"$LOCK_NUL_FILTERED"
if cmp -s "$LOCK_NUL_UV" "$LOCK_NUL_FILTERED"; then
  ok "lockfile filtering preserves NUL-bearing input byte-for-byte"
else
  not_ok "lockfile filtering must not let awk discard bytes after NUL"
fi

LOCK_INVALID_UTF8_UV="$LOCK_SCHEMA_DIR/uv-invalid-utf8.lock"
LOCK_INVALID_UTF8_FILTERED="$LOCK_SCHEMA_DIR/uv-invalid-utf8.filtered"
LOCK_INVALID_UTF8_EXPECTED="$LOCK_SCHEMA_DIR/uv-invalid-utf8.expected"
{
  printf '%s\n' '[[package]]'
  printf 'sdist = { url = "https://example.invalid/invalid", hash = "sha256:%s" }' \
    "$LOCK_FRAGMENT_HEX"
  printf '\377api_token = "%s"\n' "$LOCK_FRAGMENT_HEX"
} >"$LOCK_INVALID_UTF8_UV"
{
  printf '%s\n' '[[package]]'
  printf '%s' \
    'sdist = { url = "https://example.invalid/invalid", hash = "sha256:CHECKSUM" }'
  printf '\377api_token = "%s"\n' "$LOCK_FRAGMENT_HEX"
} >"$LOCK_INVALID_UTF8_EXPECTED"
"$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  uv.lock "$LOCK_INVALID_UTF8_UV" >"$LOCK_INVALID_UTF8_FILTERED"
status=$?
if [ "$status" -eq 0 ] \
    && cmp -s "$LOCK_INVALID_UTF8_EXPECTED" "$LOCK_INVALID_UTF8_FILTERED"; then
  ok "lockfile filtering preserves invalid UTF-8 bytes and their credential suffix"
else
  not_ok "lockfile filtering must parse invalid UTF-8 in the byte locale"
fi

{
  printf '%s\n' '{'
  printf '%s\n' '  "packages": {'
  printf '%s\n' '    "node_modules/example": {'
  printf '      "integrity": "sha512-%s",\n' "$LOCK_FRAGMENT_SHA512"
  printf '%s\n' '      "api_token": {'
  printf '        "integrity": "sha512-%s"\n' "$LOCK_FRAGMENT_SHA512"
  printf '%s\n' '      }'
  printf '%s\n' '    }'
  printf '%s\n' '  },'
  printf '%s\n' '  "dependencies": {'
  printf '%s\n' '    "example": {'
  printf '      "integrity": "sha512-%s",\n' "$LOCK_FRAGMENT_SHA512"
  printf '%s\n' '      "dependencies": {'
  printf '%s\n' '        "nested": {'
  printf '          "integrity": "sha512-%s"\n' "$LOCK_FRAGMENT_SHA512"
  printf '%s\n' '        }'
  printf '%s\n' '      }'
  printf '%s\n' '    }'
  printf '%s\n' '  },'
  printf '%s\n' '  "api_token": {'
  printf '    "integrity": "sha512-%s"\n' "$LOCK_FRAGMENT_SHA512"
  printf '%s\n' '  }'
  printf '%s\n' '}'
} >"$LOCK_SCHEMA_DIR/package-lock.json"
package_schema_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  "$LOCK_SCHEMA_DIR/package-lock.json" "$LOCK_SCHEMA_DIR/package-lock.json")
package_schema_expected=$(printf '{\n  "packages": {\n    "node_modules/example": {\n      "integrity": "CHECKSUM",\n      "api_token": {\n        "integrity": "sha512-%s"\n      }\n    }\n  },\n  "dependencies": {\n    "example": {\n      "integrity": "CHECKSUM",\n      "dependencies": {\n        "nested": {\n          "integrity": "CHECKSUM"\n        }\n      }\n    }\n  },\n  "api_token": {\n    "integrity": "sha512-%s"\n  }\n}' \
  "$LOCK_FRAGMENT_SHA512" "$LOCK_FRAGMENT_SHA512")
if [ "$package_schema_filtered" = "$package_schema_expected" ]; then
  ok "package-lock filtering is limited to package dependency maps"
else
  not_ok "package-lock filtering preserves integrity fields outside its generated schema"
fi

LOCK_JSON_TRUNCATED="$LOCK_SCHEMA_DIR/package-lock-truncated.json"
{
  printf '%s\n' '{'
  printf '%s\n' '  "packages": {'
  printf '%s\n' '    "node_modules/example": {'
  printf '      "integrity": "sha512-%s"\n' "$LOCK_FRAGMENT_SHA512"
} >"$LOCK_JSON_TRUNCATED"
truncated_json_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  package-lock.json "$LOCK_JSON_TRUNCATED")
truncated_json_expected=$(cat "$LOCK_JSON_TRUNCATED")
if [ "$truncated_json_filtered" = "$truncated_json_expected" ]; then
  ok "package-lock filtering preserves malformed JSON for conservative scanning"
else
  not_ok "package-lock filtering does not neutralize integrity before full JSON validation"
fi

LOCK_JSON_SWAP_BIN="$LOCK_SCHEMA_DIR/package-lock-swap-bin"
LOCK_JSON_SWAP_SOURCE="$LOCK_SCHEMA_DIR/package-lock-swap.json"
LOCK_JSON_SWAP_REPLACEMENT="$LOCK_SCHEMA_DIR/package-lock-swap-replacement.json"
mkdir -p "$LOCK_JSON_SWAP_BIN"
cat >"$LOCK_JSON_SWAP_BIN/jq" <<'STUB'
#!/bin/sh
"$AG_TEST_REAL_JQ" "$@"
status=$?
if [ "$status" -eq 0 ]; then
  mv "$AG_TEST_SWAP_REPLACEMENT" "$AG_TEST_SWAP_SOURCE"
fi
exit "$status"
STUB
chmod +x "$LOCK_JSON_SWAP_BIN/jq"
cp "$LOCK_SCHEMA_DIR/package-lock.json" "$LOCK_JSON_SWAP_SOURCE"
cp "$LOCK_JSON_TRUNCATED" "$LOCK_JSON_SWAP_REPLACEMENT"
swap_json_filtered=$(AG_TEST_REAL_JQ="$REAL_JQ" \
  AG_TEST_SWAP_SOURCE="$LOCK_JSON_SWAP_SOURCE" \
  AG_TEST_SWAP_REPLACEMENT="$LOCK_JSON_SWAP_REPLACEMENT" \
  PATH="$LOCK_JSON_SWAP_BIN:$PATH" \
  "$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    package-lock.json "$LOCK_JSON_SWAP_SOURCE")
swap_json_source=$(cat "$LOCK_JSON_SWAP_SOURCE")
if [ "$swap_json_filtered" = "$package_schema_expected" ] \
    && [ "$swap_json_source" = "$truncated_json_expected" ]; then
  ok "package-lock validation and filtering use one immutable snapshot"
else
  not_ok "package-lock path replacement cannot swap bytes after validation"
fi

LOCK_JSON_DEEP="$LOCK_SCHEMA_DIR/package-lock-deep.json"
{
  json_depth_i=0
  while [ "$json_depth_i" -lt 260 ]; do
    printf '%s\n' '{'
    json_depth_i=$((json_depth_i + 1))
  done
  printf '"integrity": "sha512-%s"\n' "$LOCK_FRAGMENT_SHA512"
} >"$LOCK_JSON_DEEP"
deep_json_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
  package-lock.json "$LOCK_JSON_DEEP")
deep_json_lines=$(wc -l <"$LOCK_JSON_DEEP" | tr -d ' ')
deep_json_filtered_lines=$(printf '%s\n' "$deep_json_filtered" | wc -l | tr -d ' ')
if printf '%s' "$deep_json_filtered" \
     | grep -Fq "sha512-$LOCK_FRAGMENT_SHA512" \
   && [ "$deep_json_filtered_lines" -eq "$deep_json_lines" ]; then
  ok "package-lock filtering fails conservative beyond bounded JSON depth"
else
  not_ok "package-lock filtering bounds nested parser state without dropping content"
fi

if [ -n "$REAL_GITLEAKS" ]; then
  # Synthetic PEM fixtures: gitleaks default rules match on the BEGIN/END
  # headers, so the body content is irrelevant for detection. We split the
  # header literal across two printf arguments so this script itself never
  # contains "BEGIN <KIND> PRIVATE KEY-----" on a single line — that keeps
  # the test source clean to upstream secret scanners. The body is an
  # obvious placeholder string ("...AGENT-GUARD-FIXTURE-NEVER-A-REAL-KEY...")
  # so a casual reader cannot mistake it for a leaked key.
  PEM_BODY='AGENT-GUARD-FIXTURE-NEVER-A-REAL-KEY'
  PEM_BODY="${PEM_BODY}-${PEM_BODY}-${PEM_BODY}-${PEM_BODY}"

  RSA_FIXTURE_DIR="$TMP_ROOT/rsa-fixture-dir"
  mkdir -p "$RSA_FIXTURE_DIR"
  {
    printf '%s%s\n' '-----BEGIN RSA ' 'PRIVATE KEY-----'
    printf '%s\n' "$PEM_BODY"
    printf '%s%s\n' '-----END RSA ' 'PRIVATE KEY-----'
  } > "$RSA_FIXTURE_DIR/rsa-private-key-fixture.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$RSA_FIXTURE_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks detects an RSA private key through scan-path"
  else
    not_ok "real gitleaks detects an RSA private key through scan-path (expected 1, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  OPENSSH_FIXTURE_DIR="$TMP_ROOT/openssh-fixture-dir"
  mkdir -p "$OPENSSH_FIXTURE_DIR"
  {
    printf '%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----'
    printf '%s\n' "$PEM_BODY"
    printf '%s%s\n' '-----END OPENSSH ' 'PRIVATE KEY-----'
  } > "$OPENSSH_FIXTURE_DIR/openssh-private-key-fixture.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$OPENSSH_FIXTURE_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks detects an OpenSSH private key through scan-path"
  else
    not_ok "real gitleaks detects an OpenSSH private key through scan-path (expected 1, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # Rank 5: the anchored allowlist no longer suppresses a real secret that
  # merely contains a long run of x's. The PAT is assembled at runtime so this
  # script never holds a contiguous `ghp_`-shaped literal that upstream scanners
  # would flag; the 36-char body carries a 12-x run the old `x{8,}` regex masked.
  PAT_HEAD='ghp_'
  PAT_BODY='0123456789'
  PAT_XRUN='xxxxxxxxxxxx'
  PAT_TAIL='0123456789ABCD'
  XRUN_FIXTURE_DIR="$TMP_ROOT/xrun-fixture-dir"
  mkdir -p "$XRUN_FIXTURE_DIR"
  printf 'token = %s%s%s%s\n' "$PAT_HEAD" "$PAT_BODY" "$PAT_XRUN" "$PAT_TAIL" \
    > "$XRUN_FIXTURE_DIR/conf.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$XRUN_FIXTURE_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks still flags a PAT containing a 12-x run (anchored allowlist)"
  else
    not_ok "real gitleaks still flags a PAT containing a 12-x run (expected 1, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # The word-placeholder allowlist is anchored to the whole secret too: a real
  # vendor token that merely embeds `example_token` / `dummy_secret` keeps its
  # finding, while a bare placeholder stays exempt. Assembled at runtime so this
  # file never holds a contiguous vendor-shaped literal.
  EMBED_HEAD='sk-proj-'
  EMBED_TOKEN=$(printf '%sAAAAAAA%sBBBBBBBBCCCCCC' "$EMBED_HEAD" 'example_token')
  EMBED_FIXTURE_DIR="$TMP_ROOT/embed-placeholder-dir"
  mkdir -p "$EMBED_FIXTURE_DIR"
  printf 'value = %s\n' "$EMBED_TOKEN" > "$EMBED_FIXTURE_DIR/conf.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$EMBED_FIXTURE_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks flags a real token that merely embeds an example_token substring"
  else
    not_ok "real gitleaks flags a token embedding example_token (expected 1, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  PLACEHOLDER_WORD_DIR="$TMP_ROOT/placeholder-word-dir"
  mkdir -p "$PLACEHOLDER_WORD_DIR"
  {
    printf 'a = %s\n' 'example_token'
    printf 'b = %s\n' 'dummy_secret'
    printf 'c = %s\n' 'not-a-real-token'
  } > "$PLACEHOLDER_WORD_DIR/conf.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$PLACEHOLDER_WORD_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "bare word placeholders stay exempt (example_token, dummy_secret, not-a-real-token)"
  else
    not_ok "bare word placeholders stay exempt (expected 0, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # Issue #98: the vendor-token shape rule catches a LOW-entropy token under a
  # generic variable name. Every alternation branch gets a fixture (a typo in
  # one branch must not ship green), and the bodies are low-entropy on purpose
  # so the default entropy-gated rules stay silent — each CAUGHT verdict is
  # attributable to the shape rule alone. Assembled at runtime so this file
  # never holds a contiguous token-shaped literal.
  LOWPAT_HEAD='ghp_'
  LOWPAT_BODY='1212121212121212121212121212121212ab'
  SHAPE_B35='121212121212121212121212121212121ab'
  SHAPE_B20='121212121212121212ab'
  SHAPE_B16='ABABABABABABAB12'
  SHAPE_B82="${LOWPAT_BODY}_${LOWPAT_BODY}12121212a"
  SHAPE_B64="12121212121212121212121212121212121212121212121212121212121212ab"
  SHAPE_FIXTURE_DIR="$TMP_ROOT/shape-fixture-dir"
  mkdir -p "$SHAPE_FIXTURE_DIR"
  for shape_case in \
    "github-classic ${LOWPAT_HEAD} ${LOWPAT_BODY}" \
    "github-embedded-x-run ${LOWPAT_HEAD} 121212121212xxxxxxxxxxxx121212121212" \
    "github-oauth gho_ ${LOWPAT_BODY}" \
    "github-user ghu_ ${LOWPAT_BODY}" \
    "github-app ghs_ ${LOWPAT_BODY}" \
    "github-refresh ghr_ ${LOWPAT_BODY}" \
    "github-fine-grained github_pat_ ${SHAPE_B82}" \
    "aws-a3t A3TA ${SHAPE_B16}" \
    "aws-akia AKIA ${SHAPE_B16}" \
    "aws-asia ASIA ${SHAPE_B16}" \
    "aws-abia ABIA ${SHAPE_B16}" \
    "aws-acca ACCA ${SHAPE_B16}" \
    "anthropic sk-ant- ${SHAPE_B20}" \
    "openai-project sk-proj- ${SHAPE_B20}" \
    "openai-service-account sk-svcacct- ${SHAPE_B20}" \
    "openai-admin sk-admin- ${SHAPE_B20}" \
    "npm npm_ ${LOWPAT_BODY}" \
    "gcp-api-key AIza ${SHAPE_B35}" \
    "slack-bot xoxb- 1212121212-1212121212121-abababababababababababab" \
    "slack-refresh xoxe- 1-1212121212-abababababababababababab" \
    "gitlab glpat- ${SHAPE_B20}" \
    "digitalocean dop_v1_ ${SHAPE_B64}"; do
    shape_label=${shape_case%% *}
    shape_rest=${shape_case#* }
    shape_head=${shape_rest%% *}
    shape_body=${shape_rest#* }
    printf 'AGDEMO_VAR=%s%s\n' "$shape_head" "$shape_body" > "$SHAPE_FIXTURE_DIR/conf.txt"
    PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$SHAPE_FIXTURE_DIR" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 1 ]; then
      ok "shape rule flags a low-entropy $shape_label token under a generic key"
    else
      not_ok "shape rule flags a low-entropy $shape_label token under a generic key (expected 1, got $status)"
      sed 's/^/  stderr: /' "$ERR"
    fi
  done

  # ...and `exec` masks the same value end-to-end (the shell-escape path the
  # issue was reported against).
  exec_shape=$(PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" exec -- printf 'AGDEMO_VAR=%s%s\n' "$LOWPAT_HEAD" "$LOWPAT_BODY" 2>/dev/null)
  if printf '%s' "$exec_shape" | grep -q '\[REDACTED\]' \
     && ! printf '%s' "$exec_shape" | grep -q "$LOWPAT_BODY"; then
    ok "exec masks a low-entropy vendor-prefixed token under a generic key"
  else
    not_ok "exec masks a low-entropy vendor-prefixed token under a generic key"
    printf '%s\n' "  out: $exec_shape"
  fi

  # Docs placeholders stay exempt from the shape rule: a body that is one
  # x-run through the end of the token (the anchored rule-scoped allowlist —
  # an x-run merely EMBEDDED in a token does not exempt it, covered by the
  # github-embedded-x-run fixture above) and the AWS documentation key ending
  # in EXAMPLE.
  PLACEHOLDER_FIXTURE_DIR="$TMP_ROOT/shape-placeholder-dir"
  mkdir -p "$PLACEHOLDER_FIXTURE_DIR"
  {
    printf 'AGDEMO_VAR=%sxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$LOWPAT_HEAD"
    printf 'AGDEMO_AWS=%s%s\n' 'AKIA' 'IOSFODNN7EXAMPLE'
  } > "$PLACEHOLDER_FIXTURE_DIR/conf.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$PLACEHOLDER_FIXTURE_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "shape rule leaves x-run and AWS-docs EXAMPLE placeholders alone"
  else
    not_ok "shape rule leaves x-run and AWS-docs EXAMPLE placeholders alone (expected 0, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  # Lockfile checksum allowlists are path + field combinations. A go.sum line
  # whose module name ends in `api` reproduces the default generic-api-key false
  # positive, while the identical line outside go.sum and a credential mixed
  # into go.sum must remain findings.
  LOCK_SUM=$(printf '%s%s%s' 'h1:QmvMAjj2aEICy' 'tGiWzmxoE0x2KZvE' '0fvmqMOfy2tjT8=')
  LOCK_B64=${LOCK_SUM#h1:}
  LOCK_B64_BODY=${LOCK_B64%=}
  LOCK_SHA512="${LOCK_B64_BODY}${LOCK_B64_BODY}=="
  LOCK_SECRET=$(printf '%s%s' 'A1b2C3d4E5f6G7h8' 'I9j0K1l2M3n4O5p6')
  LOCK_PATH_SECRET="${LOWPAT_HEAD}${LOWPAT_BODY}"
  LOCK_HEX=$(printf '%s%s' '0123456789abcdef0123456789abcdef' 'fedcba9876543210fedcba9876543210')
  LOCKFILE_FIXTURE_DIR="$TMP_ROOT/lockfile-hash-dir"
  mkdir -p "$LOCKFILE_FIXTURE_DIR"
  printf 'example.com/clientapi v1.2.3 %s\n' "$LOCK_SUM" >"$LOCKFILE_FIXTURE_DIR/go.sum"
  {
    printf '%s\n' '{'
    printf '%s\n' '  "packages": {'
    printf '%s\n' '    "node_modules/example": {'
    printf '      "integrity": "sha512-%s"\n' "$LOCK_SHA512"
    printf '%s\n' '    }'
    printf '%s\n' '  }'
    printf '%s\n' '}'
  } >"$LOCKFILE_FIXTURE_DIR/package-lock.json"
  printf '  integrity sha512-%s\n' "$LOCK_SHA512" >"$LOCKFILE_FIXTURE_DIR/yarn.lock"
  printf '[[package]]\nchecksum = "%s"\n' \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/Cargo.lock"
  printf '[[package]]\nsdist = { url = "https://example.invalid/pkg", hash = "sha256:%s" }\n' \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "lockfile checksum fields are exempt only in recognized lockfile paths"
  else
    not_ok "recognized lockfile checksum fields stay clean (expected 0, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  {
    printf '%s\n' '[[package]]'
    printf 'sdist = { url = "https://example.invalid/nul", hash = "sha256:%s" }' \
      "$LOCK_HEX"
    printf '\000AGDEMO_VAR=%s\n' "$LOCK_PATH_SECRET"
  } >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR/uv.lock" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-path detects a credential after NUL in a recognized lockfile"
  else
    not_ok "NUL-bearing lockfile input remains fully scannable (expected 1, got $status)"
  fi

  {
    printf '%s\n' '[[package]]'
    printf 'sdist = { url = "https://example.invalid/invalid", hash = "sha256:%s" }' \
      "$LOCK_HEX"
    printf '\377AGDEMO_VAR=%s\n' "$LOCK_PATH_SECRET"
  } >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR/uv.lock" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-path detects a credential after invalid UTF-8 in a recognized lockfile"
  else
    not_ok "invalid-UTF-8 lockfile input remains fully scannable (expected 1, got $status)"
  fi

  LOCK_BINARY_UNTRACKED_REPO="$TMP_ROOT/lockfile-binary-untracked-git-dir"
  mkdir -p "$LOCK_BINARY_UNTRACKED_REPO"
  (
    cd "$LOCK_BINARY_UNTRACKED_REPO"
    git init -q
    git config user.email test@example.com
    git config user.name "Agent Guard Tests"
    printf '%s\n' clean >README.md
    git add README.md
    git commit -q -m init
    {
      printf '%s\n' '[[package]]'
      printf 'sdist = { url = "https://example.invalid/untracked", hash = "sha256:%s" }' \
        "$LOCK_HEX"
      printf '\377AGDEMO_VAR=%s\n' "$LOCK_PATH_SECRET"
    } >uv.lock
    PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
      "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree
  ) >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "untracked scanning detects a credential after invalid UTF-8 in a lockfile"
  else
    not_ok "binary-safe untracked lockfile preparation preserves findings (expected 1, got $status)"
  fi

  # go.sum checksums are the third field. An h1-shaped secret in the module
  # token must not be mistaken for that checksum and erased.
  LOCK_HARMLESS_BODY=$(awk 'BEGIN { for (i = 0; i < 43; i++) printf "A" }')
  printf 'clientapi-h1:%s= v1.2.3 h1:%s=\n' \
    "$LOCK_B64_BODY" "$LOCK_HARMLESS_BODY" >"$LOCKFILE_FIXTURE_DIR/go.sum"
  go_field_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/go.sum" "$LOCKFILE_FIXTURE_DIR/go.sum")
  if printf '%s' "$go_field_filtered" | grep -Fq "clientapi-h1:$LOCK_B64_BODY=" \
     && printf '%s' "$go_field_filtered" | grep -Fq 'v1.2.3 h1:CHECKSUM'; then
    ok "go.sum filter neutralizes only the third checksum field"
  else
    not_ok "go.sum filter preserves h1-shaped module text"
  fi
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR/go.sum" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-path detects an h1-shaped credential in the go.sum module field"
  else
    not_ok "go.sum checksum filtering keeps earlier fields scannable (expected 1, got $status)"
  fi
  printf 'example.com/clientapi v1.2.3 %s\n' "$LOCK_SUM" >"$LOCKFILE_FIXTURE_DIR/go.sum"

  # Field names must be exact. Preserve prefixed user fields byte-for-byte even
  # when their suffix resembles an allowlisted checksum field.
  {
    printf 'api_integrity sha512-%s\n' "$LOCK_SHA512"
    printf 'api checksum: %s\n' "$LOCK_HEX"
  } >"$LOCKFILE_FIXTURE_DIR/yarn.lock"
  printf 'api_checksum = "%s"\n' "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/Cargo.lock"
  printf '[[package]]\napi_hash = "sha256:%s"\n' \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  prefixed_yarn=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/yarn.lock" "$LOCKFILE_FIXTURE_DIR/yarn.lock")
  prefixed_cargo=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/Cargo.lock" "$LOCKFILE_FIXTURE_DIR/Cargo.lock")
  prefixed_uv=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/uv.lock" "$LOCKFILE_FIXTURE_DIR/uv.lock")
  prefixed_yarn_expected=$(printf 'api_integrity sha512-%s\napi checksum: %s' \
    "$LOCK_SHA512" "$LOCK_HEX")
  if [ "$prefixed_yarn" = "$prefixed_yarn_expected" ] \
     && [ "$prefixed_cargo" = "api_checksum = \"$LOCK_HEX\"" ] \
     && [ "$prefixed_uv" = "$(printf '[[package]]\napi_hash = "sha256:%s"' "$LOCK_HEX")" ]; then
    ok "lockfile filter does not neutralize prefixed checksum-like fields"
  else
    not_ok "lockfile filter preserves prefixed checksum-like fields byte-for-byte"
  fi

  # Checksum-shaped text inside a quoted note or comment is not a structural
  # lockfile field. It can itself be the value of a credential assignment, so
  # neutralizing it would erase a real finding before gitleaks sees the record.
  printf "note = 'api_token = { checksum = \"%s\" }'\n" \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/Cargo.lock"
  printf "[[package]]\nnote = 'api_token = { hash = \"sha256:%s\" }'\n" \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  printf 'note "api_token = { integrity sha512-%s }"\n' \
    "$LOCK_SHA512" >"$LOCKFILE_FIXTURE_DIR/yarn.lock"
  quoted_cargo_expected=$(cat "$LOCKFILE_FIXTURE_DIR/Cargo.lock")
  quoted_uv_expected=$(cat "$LOCKFILE_FIXTURE_DIR/uv.lock")
  quoted_yarn_expected=$(cat "$LOCKFILE_FIXTURE_DIR/yarn.lock")
  quoted_cargo=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/Cargo.lock" "$LOCKFILE_FIXTURE_DIR/Cargo.lock")
  quoted_uv=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/uv.lock" "$LOCKFILE_FIXTURE_DIR/uv.lock")
  quoted_yarn=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/yarn.lock" "$LOCKFILE_FIXTURE_DIR/yarn.lock")
  if [ "$quoted_cargo" = "$quoted_cargo_expected" ] \
     && [ "$quoted_uv" = "$quoted_uv_expected" ] \
     && [ "$quoted_yarn" = "$quoted_yarn_expected" ]; then
    ok "lockfile filter preserves checksum-shaped text inside quoted values"
  else
    not_ok "lockfile filter does not treat quoted checksum text as structural fields"
  fi

  LOCK_CONTEXT_DIR="$TMP_ROOT/lockfile-context-dir"
  mkdir -p "$LOCK_CONTEXT_DIR"
  {
    printf '%s\n' '[[package]]'
    printf 'sdist = { url = "https://example.invalid/pkg?api_token=%s", hash = "sha256:%s" }\n' \
      "$LOCK_SECRET" "$LOCK_HEX"
    printf 'sdist = { url = "quoted%s", hash = "sha256:%s" }\n' "\\\\" "$LOCK_HEX"
  } >"$LOCK_CONTEXT_DIR/uv.lock"
  context_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCK_CONTEXT_DIR/uv.lock" "$LOCK_CONTEXT_DIR/uv.lock")
  context_expected=$(printf "[[package]]\nsdist = { url = \"https://example.invalid/pkg?api_token=%s\", hash = \"sha256:CHECKSUM\" }\nsdist = { url = \"quoted%s\", hash = \"sha256:CHECKSUM\" }" \
    "$LOCK_SECRET" "\\\\")
  if [ "$context_filtered" = "$context_expected" ]; then
    ok "uv.lock filter continues after quoted text and honors even backslash parity"
  else
    not_ok "uv.lock quote context finds real hash fields after valid escaped text"
  fi

  LOCK_MULTILINE_DIR="$TMP_ROOT/lockfile-multiline-dir"
  mkdir -p "$LOCK_MULTILINE_DIR"
  {
    printf '%s\n' '[[package]]'
    printf '%s\n' 'note = """'
    printf 'api_token = { checksum = "%s" }\n' "$LOCK_HEX"
    printf '%s\n' '"""'
    printf 'checksum = "%s"\n' "$LOCK_HEX"
  } >"$LOCK_MULTILINE_DIR/Cargo.lock"
  {
    printf '%s\n' '[[package]]'
    printf "%s\n" "note = '''"
    printf 'api_token = { hash = "sha256:%s" }\n' "$LOCK_HEX"
    printf "%s\n" "'''"
    printf 'sdist = { url = "https://example.invalid/pkg", hash = "sha256:%s" }\n' \
      "$LOCK_HEX"
  } >"$LOCK_MULTILINE_DIR/uv.lock"
  multiline_cargo=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCK_MULTILINE_DIR/Cargo.lock" "$LOCK_MULTILINE_DIR/Cargo.lock")
  multiline_uv=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCK_MULTILINE_DIR/uv.lock" "$LOCK_MULTILINE_DIR/uv.lock")
  multiline_cargo_expected=$(printf '[[package]]\nnote = """\napi_token = { checksum = "%s" }\n"""\nchecksum = "CHECKSUM"' \
    "$LOCK_HEX")
  multiline_uv_expected=$(printf "[[package]]\nnote = '''\napi_token = { hash = \"sha256:%s\" }\n'''\nsdist = { url = \"https://example.invalid/pkg\", hash = \"sha256:CHECKSUM\" }" \
    "$LOCK_HEX")
  if [ "$multiline_cargo" = "$multiline_cargo_expected" ] \
     && [ "$multiline_uv" = "$multiline_uv_expected" ]; then
    ok "lockfile filter preserves TOML multiline strings across physical records"
  else
    not_ok "lockfile filter keeps multiline basic and literal string content scannable"
  fi

  # Use shapes that gitleaks actually recognizes to prove the exact-boundary
  # guard does not create a bypass in an allowlisted path.
  for lock_negative in yarn-checksum yarn-spaced-checksum cargo-checksum; do
    case "$lock_negative" in
      yarn-checksum)
        lock_negative_path="$LOCKFILE_FIXTURE_DIR/yarn.lock"
        printf 'api_checksum: %s\n' "$LOCK_HEX" >"$lock_negative_path"
        ;;
      yarn-spaced-checksum)
        lock_negative_path="$LOCKFILE_FIXTURE_DIR/yarn.lock"
        printf 'api checksum: %s\n' "$LOCK_HEX" >"$lock_negative_path"
        ;;
      cargo-checksum)
        lock_negative_path="$LOCKFILE_FIXTURE_DIR/Cargo.lock"
        printf 'api_checksum = "%s"\n' "$LOCK_HEX" >"$lock_negative_path"
        ;;
    esac
    PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
      scan-path "$lock_negative_path" >"$OUT" 2>"$ERR"
    status=$?
    if [ "$status" -eq 1 ]; then
      ok "lockfile filter keeps prefixed field $lock_negative scannable"
    else
      not_ok "lockfile filter does not allowlist prefixed field $lock_negative (expected 1, got $status)"
    fi
  done

  # A valid-length checksum prefix followed by another value byte is not a
  # complete checksum field and must remain unchanged.
  {
    printf 'checksum: %sa\n' "$LOCK_HEX"
    printf 'integrity sha512-%sA\n' "$LOCK_SHA512"
  } >"$LOCKFILE_FIXTURE_DIR/yarn.lock"
  trailing_yarn=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/yarn.lock" "$LOCKFILE_FIXTURE_DIR/yarn.lock")
  trailing_yarn_expected=$(printf 'checksum: %sa\nintegrity sha512-%sA' \
    "$LOCK_HEX" "$LOCK_SHA512")
  if [ "$trailing_yarn" = "$trailing_yarn_expected" ]; then
    ok "lockfile filter requires a delimiter after a checksum value"
  else
    not_ok "lockfile filter does not neutralize a checksum-length prefix"
  fi
  printf '  integrity sha512-%s\n' "$LOCK_SHA512" >"$LOCKFILE_FIXTURE_DIR/yarn.lock"
  printf '[[package]]\nchecksum = "%s"\n' \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/Cargo.lock"
  printf '[[package]]\nsdist = { url = "https://example.invalid/pkg", hash = "sha256:%s" }\n' \
    "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"

  # Compact lockfile records can contain more than one recognized hash field.
  # Neutralize every field, not only the first, while preserving both URLs.
  printf '[[package]]\nwheels = [{ url = "https://example.invalid/a", hash = "sha256:%s" }, { url = "https://example.invalid/b", hash = "sha256:%s" }]\n' \
    "$LOCK_HEX" "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  multi_hash_filtered=$("$PLUGIN_ROOT/bin/agent-guard" filter-lockfile-hashes \
    "$LOCKFILE_FIXTURE_DIR/uv.lock" "$LOCKFILE_FIXTURE_DIR/uv.lock")
  multi_hash_count=$(printf '%s' "$multi_hash_filtered" \
    | awk -F 'sha256:CHECKSUM' '{ total += NF - 1 } END { print total + 0 }')
  if [ "$multi_hash_count" -eq 2 ] \
     && printf '%s' "$multi_hash_filtered" | grep -Fq 'https://example.invalid/a' \
     && printf '%s' "$multi_hash_filtered" | grep -Fq 'https://example.invalid/b' \
     && ! printf '%s' "$multi_hash_filtered" | grep -Fq "$LOCK_HEX"; then
    ok "lockfile filter neutralizes every checksum field on a compact record"
  else
    not_ok "lockfile filter neutralizes all compact-record checksums without dropping other text"
  fi
  printf 'hash = "sha256:%s"\n' "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"

  printf '[[package]]\nsdist = { url = "https://example.invalid/pkg?api_token=%s", hash = "sha256:%s", size = 1 }\n' \
    "$LOCK_SECRET" "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR/uv.lock" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-path rescans a credential beside an inline uv.lock checksum"
  else
    not_ok "scan-path preserves non-checksum text on an inline uv.lock record (expected 1, got $status)"
  fi
  printf 'hash = "sha256:%s"\n' "$LOCK_HEX" >"$LOCKFILE_FIXTURE_DIR/uv.lock"

  cp "$LOCKFILE_FIXTURE_DIR/go.sum" "$TMP_ROOT/safe-go-sum"
  printf 'api_token = "%s"\n' "$LOCK_SECRET" >>"$LOCKFILE_FIXTURE_DIR/go.sum"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR/go.sum" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-path still detects a credential mixed into a recognized lockfile"
  else
    not_ok "scan-path keeps non-checksum lockfile content scannable (expected 1, got $status)"
  fi
  cp "$TMP_ROOT/safe-go-sum" "$LOCKFILE_FIXTURE_DIR/go.sum"

  cp "$LOCKFILE_FIXTURE_DIR/go.sum" "$LOCKFILE_FIXTURE_DIR/not-a-lockfile.txt"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" \
    scan-path "$LOCKFILE_FIXTURE_DIR/not-a-lockfile.txt" >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "go.sum-shaped checksum outside go.sum remains a generic-api-key finding"
  else
    not_ok "lockfile checksum allowlist remains path-scoped (expected 1, got $status)"
  fi

  LOCK_GIT_DIR="$TMP_ROOT/lockfile-git-dir"
  mkdir -p "$LOCK_GIT_DIR"
  (
    cd "$LOCK_GIT_DIR"
    git init -q
    git config user.email test@example.com
    git config user.name "Agent Guard Tests"
    cp "$LOCKFILE_FIXTURE_DIR/go.sum" go.sum
    git add go.sum
  )
  (
    cd "$LOCK_GIT_DIR"
    PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
      "$PLUGIN_ROOT/bin/agent-guard" scan-staged
  ) >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "scan-staged preserves go.sum path context for checksum allowlisting"
  else
    not_ok "scan-staged allows a go.sum checksum (expected 0, got $status)"
    sed 's/^/  stderr: /' "$ERR"
  fi

  printf 'example.com/%s/client v1.2.3 %s\n' "$LOCK_PATH_SECRET" "$LOCK_SUM" \
    >"$LOCK_GIT_DIR/go.sum"
  (cd "$LOCK_GIT_DIR" && git add go.sum)
  (
    cd "$LOCK_GIT_DIR"
    PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
      "$PLUGIN_ROOT/bin/agent-guard" scan-staged
  ) >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-staged rescans a credential beside a go.sum checksum"
  else
    not_ok "scan-staged preserves non-checksum text on a go.sum line (expected 1, got $status)"
  fi
  cp "$TMP_ROOT/safe-go-sum" "$LOCK_GIT_DIR/go.sum"
  (cd "$LOCK_GIT_DIR" && git add go.sum)

  printf 'api_token = "%s"\n' "$LOCK_SECRET" >>"$LOCK_GIT_DIR/go.sum"
  (cd "$LOCK_GIT_DIR" && git add go.sum)
  (
    cd "$LOCK_GIT_DIR"
    PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
      "$PLUGIN_ROOT/bin/agent-guard" scan-staged
  ) >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "scan-staged still detects a credential mixed into go.sum"
  else
    not_ok "credential in go.sum remains detectable (expected 1, got $status)"
  fi

  LOCK_SUM_LINE="example.com/clientapi v1.2.3 $LOCK_SUM"
  lock_write=$(jq -nc --arg content "$LOCK_SUM_LINE" \
    '{tool_name:"Write",tool_input:{file_path:"go.sum",content:$content}}')
  printf '%s' "$lock_write" \
    | AGENT_GUARD_GITLEAKS_BIN="$REAL_GITLEAKS" PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
        "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "Write scanning preserves go.sum path context for checksum allowlisting"
  else
    not_ok "Write allows a go.sum checksum (expected 0, got $status)"
  fi

  lock_write=$(jq -nc --arg content "example.com/$LOCK_PATH_SECRET/client v1.2.3 $LOCK_SUM" \
    '{tool_name:"Write",tool_input:{file_path:"go.sum",content:$content}}')
  printf '%s' "$lock_write" \
    | AGENT_GUARD_GITLEAKS_BIN="$REAL_GITLEAKS" PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
        "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "Write rescans a credential beside a go.sum checksum"
  else
    not_ok "Write preserves non-checksum text on a go.sum line (expected 2, got $status)"
  fi

  lock_patch=$(printf '%s\n%s\n%s\n%s\n%s\n' \
    '*** Begin Patch' '*** Update File: go.sum' '@@' "+$LOCK_SUM_LINE" '*** End Patch')
  lock_patch_input=$(jq -nc --arg patch "$lock_patch" \
    '{tool_name:"apply_patch",tool_input:{patch:$patch}}')
  printf '%s' "$lock_patch_input" \
    | AGENT_GUARD_GITLEAKS_BIN="$REAL_GITLEAKS" PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" \
        "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
  status=$?
  if [ "$status" -eq 0 ]; then
    ok "apply_patch scanning preserves go.sum path context for checksum allowlisting"
  else
    not_ok "apply_patch allows a go.sum checksum (expected 0, got $status)"
  fi

else
  say "real gitleaks not available; skipped real-gitleaks integration tests"
fi

checksum_help_out=$("$PLUGIN_ROOT/bin/agent-guard" checksum --help 2>&1)
if printf '%s\n' "$checksum_help_out" | grep -q 'Usage: gitleaks-checksum.sh'; then
  ok "checksum --help prints usage from the helper script"
else
  not_ok "checksum --help did not surface helper script usage"
  printf '%s\n' "$checksum_help_out" | sed 's/^/  /'
fi

mock_checksums_url="file://$ROOT/tests/fixtures/gitleaks-checksums-mock.txt"
checksum_out=$(AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="$mock_checksums_url" "$PLUGIN_ROOT/bin/agent-guard" checksum 8.30.1 2>&1)
checksum_status=$?
if [ "$checksum_status" -eq 0 ] \
   && printf '%s\n' "$checksum_out" | grep -q 'darwin/arm64:' \
   && printf '%s\n' "$checksum_out" | grep -q 'darwin/x64:' \
   && printf '%s\n' "$checksum_out" | grep -q 'linux/arm64:' \
   && printf '%s\n' "$checksum_out" | grep -q 'linux/x64:' \
   && printf '%s\n' "$checksum_out" | grep -q 'gitleaks-checksum:' \
   && printf '%s\n' "$checksum_out" | grep -q 'agent-guard setup --install'; then
  ok "checksum subcommand prints all four platforms with paste-ready snippets"
else
  not_ok "checksum subcommand mock fetch failed (exit $checksum_status)"
  printf '%s\n' "$checksum_out" | sed 's/^/  /'
fi

missing_url="file://$ROOT/tests/fixtures/does-not-exist-checksums.txt"
AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="$missing_url" "$PLUGIN_ROOT/bin/agent-guard" checksum 8.30.1 \
  >"$OUT" 2>"$ERR"
checksum_missing_status=$?
if [ "$checksum_missing_status" -eq 2 ] && grep -q 'failed to fetch' "$ERR"; then
  ok "checksum subcommand exits 2 when the source URL is unreachable"
else
  not_ok "checksum subcommand fetch-failure path returned status $checksum_missing_status"
  sed 's/^/  /' "$ERR"
fi

# --- Tool-output secret redaction (PostToolUse updatedToolOutput) ----------
# Masks secret-like values in a tool's RESULT before the model sees it. Run from
# a non-git dir so the mutation-tool working-tree backstop stays inert and these
# assertions isolate the redaction path. The harness mock gitleaks flags
# AGENT_GUARD_TEST_SECRET; the env-assignment heuristic catches KEY=value dumps.
post_tool_out() {
  printf '%s' "$1" | (cd "$TMP_ROOT" && "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) \
    >"$OUT" 2>"$ERR"
}

post_tool_out '{"tool_name":"Bash","tool_input":{"command":"loadsecrets"},"tool_response":{"stdout":"token AGENT_GUARD_TEST_SECRET here\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -q 'AGENT_GUARD_TEST_SECRET' \
   && printf '%s' "$post_out" | jq -e '.hookSpecificOutput.updatedToolOutput | has("stdout") and has("stderr") and has("interrupted") and has("isImage")' >/dev/null 2>&1; then
  ok "post-tool masks a gitleaks-detected secret in Bash stdout (shape preserved)"
else
  not_ok "post-tool masks a gitleaks-detected secret in Bash stdout (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

post_tool_out '{"tool_name":"Bash","tool_input":{"command":"printf sentinel"},"tool_response":{"stdout":"AGENT_GUARD_LIVE_POST_TOOL_PROBE\n","stderr":"","interrupted":false,"isImage":false}}'
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -q 'AGENT_GUARD_LIVE_POST_TOOL_PROBE'; then
  ok "live PostToolUse sentinel is rewritten before reaching the model"
else
  not_ok "live PostToolUse sentinel is rewritten before reaching the model"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

printf '%s' '{"tool_name":"Bash","tool_input":{"command":"loadsecrets"},"tool_response":{"stdout":"token AGENT_GUARD_TEST_SECRET here\n","stderr":"","interrupted":false,"isImage":false}}' \
  | (cd "$TMP_ROOT" && AGENT_GUARD_HOOK_HOST=codex "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) \
    >"$OUT" 2>"$ERR"
codex_post_status=$?
codex_post_out=$(cat "$OUT")
if [ "$codex_post_status" -eq 0 ] \
   && printf '%s' "$codex_post_out" | jq -e '.decision == "block" and (.reason | type == "string") and (.hookSpecificOutput.additionalContext | contains("[REDACTED]"))' >/dev/null 2>&1 \
   && ! printf '%s' "$codex_post_out" | grep -q 'AGENT_GUARD_TEST_SECRET'; then
  ok "Codex post-tool uses decision block plus sanitized additionalContext"
else
  not_ok "Codex post-tool emits the supported sanitized-output contract (status $codex_post_status)"
  printf '%s\n' "$codex_post_out" | sed 's/^/  out: /'
fi

post_tool_out '{"tool_name":"Bash","tool_input":{"command":"printenv-like"},"tool_response":{"stdout":"DATABASE_PASSWORD=hunter2-long-value\n","stderr":"","interrupted":false,"isImage":false}}'
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -q 'hunter2-long-value'; then
  ok "post-tool env-assignment heuristic masks KEY=value gitleaks misses"
else
  not_ok "post-tool env-assignment heuristic masks KEY=value gitleaks misses"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Display redaction replaces only the assignment value token. Text after it is
# preserved, metadata keys with secret-ish prefixes are not values, and a prose
# colon must not be interpreted as a YAML/JSON secret assignment.
DISPLAY_SECRET=$(printf '%s%s' 'hunter2-' 'long-value')
DISPLAY_SHARED_LITERAL=$(printf '%s%s' 'PASSWORD=' 'abc)')
DISPLAY_SHARED_LINE=$(printf '%s API_TOKEN="%s" status=ok' \
  "$DISPLAY_SHARED_LITERAL" "$DISPLAY_SHARED_LITERAL")
display_input=$(jq -nc --arg stdout "DATABASE_PASSWORD=$DISPLAY_SECRET status=ok" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
display_expected=$(printf 'DATABASE_PASSWORD=[%s] status=ok' 'REDACTED')
if printf '%s' "$post_out" \
  | jq -e --arg expected "$display_expected" \
      '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
  ok "post-tool masks only the matched assignment value and preserves adjacent text"
else
  not_ok "post-tool value redaction preserves adjacent text"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

for display_closing in '}' ']' ')'; do
  display_input=$(jq -nc \
    --arg stdout "API_TOKEN=${DISPLAY_SECRET}${display_closing}" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
      {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
  post_tool_out "$display_input"
  post_out=$(cat "$OUT")
  display_expected="API_TOKEN=[REDACTED]${display_closing}"
  if printf '%s' "$post_out" \
    | jq -e --arg expected "$display_expected" \
        '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
    ok "post-tool preserves closing punctuation after an unquoted secret"
  else
    not_ok "post-tool keeps structural punctuation outside the redacted value"
    printf '%s\n' "$post_out" | sed 's/^/  out: /'
  fi
done

for display_short in 'abc)' '))))'; do
  display_input=$(jq -nc \
    --arg stdout "PASSWORD=${display_short}" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
      {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
  post_tool_out "$display_input"
  post_out=$(cat "$OUT")
  case "$display_short" in
    'abc)') display_expected='PASSWORD=[REDACTED])' ;;
    '))))') display_expected='PASSWORD=[REDACTED]))))' ;;
  esac
  if printf '%s' "$post_out" \
    | jq -e --arg expected "$display_expected" \
        '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
    ok "post-tool masks short unquoted values before structural punctuation"
  else
    not_ok "post-tool does not leak short values beside structural punctuation"
    printf '%s\n' "$post_out" | sed 's/^/  out: /'
  fi
done

display_input=$(jq -nc \
  --arg stdout 'PASSWORD=a))) status=available abc ab a ))) PASSWORD=abcdef' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
            == "PASSWORD=[REDACTED]))) status=available abc ab a ))) PASSWORD=[REDACTED]"' \
      >/dev/null 2>&1; then
  ok "post-tool scopes a short secret without stranding a longer value"
else
  not_ok "post-tool avoids short-literal prefix replacement"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout 'PASSWORD=)))) benign=))) PASSWORD=off' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
            == "PASSWORD=[REDACTED])))) benign=))) PASSWORD=off"' \
      >/dev/null 2>&1; then
  ok "post-tool scopes an all-closer secret to its assignment"
else
  not_ok "post-tool preserves unrelated punctuation and short values"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout 'PASSWORD=abc) PASSWORD=abc)evil status=ok' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
            == "PASSWORD=[REDACTED]) PASSWORD=[REDACTED] status=ok"' \
      >/dev/null 2>&1; then
  ok "post-tool requires a boundary after a contextual token"
else
  not_ok "post-tool does not strand a longer assignment suffix"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout 'API_TOKEN="abc)" PASSWORD=abc)' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
            == "API_TOKEN=\"[REDACTED]\" PASSWORD=[REDACTED])"' \
      >/dev/null 2>&1; then
  ok "post-tool preserves a contextual closer shared with a quoted secret"
else
  not_ok "post-tool composes contextual and ordinary secret replacement"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout "$(printf 'PASSWORD=abc)\nstatus=available')" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
display_expected=$(printf 'PASSWORD=[REDACTED])\nstatus=available')
if printf '%s' "$post_out" \
  | jq -e --arg expected "$display_expected" \
      '(.hookSpecificOutput.updatedToolOutput.stdout == $expected)
       and (.hookSpecificOutput.updatedToolOutput.stderr == "")' \
      >/dev/null 2>&1; then
  ok "post-tool treats a newline as a contextual token boundary"
else
  not_ok "post-tool masks a short secret at physical line end"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout "$DISPLAY_SHARED_LINE" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput
            == {stdout:"PASSWORD=[REDACTED]) API_TOKEN=\"[REDACTED]\" status=ok",
                stderr:"",interrupted:false,isImage:false}' \
      >/dev/null 2>&1; then
  ok "post-tool keeps contextual and ordinary meanings for one literal"
else
  not_ok "post-tool masks a shared contextual and quoted literal"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout 'PASSWORD=[REDACTED]' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if [ -z "$post_out" ]; then
  ok "post-tool keeps an existing redaction sentinel idempotent"
else
  not_ok "post-tool does not corrupt an existing redaction sentinel"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg stdout 'PASSWORD=[REDACTED]]evil-suffix' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
            == "PASSWORD=[REDACTED]"' >/dev/null 2>&1; then
  ok "post-tool does not treat a redaction-prefix secret as sanitized"
else
  not_ok "post-tool keeps redaction-sentinel skipping narrowly scoped"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

for display_closing in '}' ']' ')'; do
  display_input=$(jq -nc \
    --arg stdout "API_TOKEN=${DISPLAY_SECRET}${display_closing}suffix-value" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
      {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
  post_tool_out "$display_input"
  post_out=$(cat "$OUT")
  if printf '%s' "$post_out" \
    | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
              == "API_TOKEN=[REDACTED]"' >/dev/null 2>&1; then
    ok "post-tool masks through punctuation inside an unquoted secret"
  else
    not_ok "post-tool does not expose a suffix after internal punctuation"
    printf '%s\n' "$post_out" | sed 's/^/  out: /'
  fi
done

DISPLAY_QUOTED_KEY=$(printf '%s%s' 'DATABASE_' 'PASSWORD')
DISPLAY_QUOTED_HEAD=$(printf '%s%s' 'alpha-long-' 'value')
DISPLAY_QUOTED_TAIL=$(printf '%s%s' 'omega-secret-' 'tail')
display_double=$(printf '%s="%s\\"%s" status=ok' \
  "$DISPLAY_QUOTED_KEY" "$DISPLAY_QUOTED_HEAD" "$DISPLAY_QUOTED_TAIL")
display_input=$(jq -nc --arg stdout "$display_double" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
display_expected=$(printf '%s="[%s]" status=ok' "$DISPLAY_QUOTED_KEY" 'REDACTED')
if printf '%s' "$post_out" \
  | jq -e --arg expected "$display_expected" \
      '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
  ok "post-tool masks through an escaped double quote without leaking a suffix"
else
  not_ok "post-tool handles escaped double-quoted assignment delimiters"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_single=$(printf "%s='%s%s%s' status=ok" \
  "$DISPLAY_QUOTED_KEY" "$DISPLAY_QUOTED_HEAD" "\\'" "$DISPLAY_QUOTED_TAIL")
display_input=$(jq -nc --arg stdout "$display_single" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
display_expected=$(printf "%s='[%s]' status=ok" "$DISPLAY_QUOTED_KEY" 'REDACTED')
if printf '%s' "$post_out" \
  | jq -e --arg expected "$display_expected" \
      '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
  ok "post-tool masks through an escaped single quote without leaking a suffix"
else
  not_ok "post-tool handles escaped single-quoted assignment delimiters"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

for display_quote in '"' "'"; do
  display_multiline=$(printf '%s=%s%s\n%s%s status=ok' \
    "$DISPLAY_QUOTED_KEY" "$display_quote" "$DISPLAY_QUOTED_HEAD" \
    "$DISPLAY_QUOTED_TAIL" "$display_quote")
  display_input=$(jq -nc --arg stdout "$display_multiline" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
  post_tool_out "$display_input"
  post_out=$(cat "$OUT")
  display_expected=$(printf '%s=%s[%s]%s status=ok' \
    "$DISPLAY_QUOTED_KEY" "$display_quote" 'REDACTED' "$display_quote")
  if printf '%s' "$post_out" \
    | jq -e --arg expected "$display_expected" \
        '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
    ok "post-tool masks a multiline quoted assignment as one complete value"
  else
    not_ok "post-tool masks the complete multiline quoted assignment"
    printf '%s\n' "$post_out" | sed 's/^/  out: /'
  fi
done

display_input=$(jq -nc \
  --arg stdout "${DISPLAY_QUOTED_KEY}=\"${DISPLAY_QUOTED_HEAD}" \
  --arg stderr "API_TOKEN=${DISPLAY_QUOTED_TAIL}" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:$stdout,stderr:$stderr,interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | jq -e \
  --arg stdout "${DISPLAY_QUOTED_KEY}=\"[REDACTED]" \
  '.hookSpecificOutput.updatedToolOutput.stdout == $stdout
   and .hookSpecificOutput.updatedToolOutput.stderr == "API_TOKEN=[REDACTED]"' \
  >/dev/null 2>&1; then
  ok "post-tool keeps multiline quote state inside each object string leaf"
else
  not_ok "post-tool prevents multiline quote state from crossing object leaves"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc \
  --arg first "${DISPLAY_QUOTED_KEY}=\"${DISPLAY_QUOTED_HEAD}" \
  --arg second "API_TOKEN=${DISPLAY_QUOTED_TAIL}" \
  '{tool_name:"Read",tool_input:{file_path:"memo.txt"},tool_response:[$first,$second]}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput
            == ["DATABASE_PASSWORD=\"[REDACTED]","API_TOKEN=[REDACTED]"]' \
      >/dev/null 2>&1; then
  ok "post-tool keeps multiline quote state inside each array string leaf"
else
  not_ok "post-tool prevents multiline quote state from crossing array leaves"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc --arg secret "API_TOKEN=${DISPLAY_QUOTED_TAIL}" '
  {tool_name:"Read",tool_input:{file_path:"memo.txt"},
   tool_response:([range(0;4000) | "x"] + [$secret])}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput
            | length == 4001 and .[0] == "x" and .[-1] == "API_TOKEN=[REDACTED]"' \
      >/dev/null 2>&1; then
  ok "post-tool scans thousands of sibling leaves in one framed stream"
else
  not_ok "post-tool keeps many-leaf secret scanning within the hook boundary"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc --arg head "$DISPLAY_QUOTED_HEAD" --arg tail "$DISPLAY_QUOTED_TAIL" '
  {tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:("PASSWORD=\"" + $head + "\u0000" + $tail + "\""),
     stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout == "[REDACTED]"' \
      >/dev/null 2>&1; then
  ok "post-tool conservatively masks a NUL-bearing string leaf"
else
  not_ok "post-tool does not pass NUL-bearing string leaves through shell variables"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_input=$(jq -nc --arg head "$DISPLAY_QUOTED_HEAD" --arg tail "$DISPLAY_QUOTED_TAIL" '
  {tool_name:"Bash",tool_input:{command:"x"},tool_response:
    {stdout:("PASSWORD=\"" + $head + "\u001e" + $tail + "\" alpha status omega"),
     stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout
            == "PASSWORD=\"[REDACTED]\" alpha status omega"' >/dev/null 2>&1; then
  ok "post-tool treats an ASCII RS inside a secret as data"
else
  not_ok "post-tool preserves benign text around an ASCII-RS-bearing secret"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_backtick=$(printf '%s=`%s\\`%s` status=ok' \
  "$DISPLAY_QUOTED_KEY" "$DISPLAY_QUOTED_HEAD" "$DISPLAY_QUOTED_TAIL")
display_input=$(jq -nc --arg stdout "$display_backtick" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
display_expected=$(printf '%s=`[%s]` status=ok' "$DISPLAY_QUOTED_KEY" 'REDACTED')
if printf '%s' "$post_out" \
  | jq -e --arg expected "$display_expected" \
      '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
  ok "post-tool masks through an escaped backtick without leaking a suffix"
else
  not_ok "post-tool handles escaped backtick assignment delimiters"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

display_even="${DISPLAY_QUOTED_KEY}=\"${DISPLAY_QUOTED_HEAD}\\\\\" status=ok"
display_input=$(jq -nc --arg stdout "$display_even" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
display_expected=$(printf '%s="[%s]" status=ok' "$DISPLAY_QUOTED_KEY" 'REDACTED')
if printf '%s' "$post_out" \
  | jq -e --arg expected "$display_expected" \
      '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
  ok "post-tool treats a quote after an even backslash run as closing"
else
  not_ok "post-tool handles even backslashes before a quoted delimiter"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Truncated tool output may lose the closing delimiter. Fail safe by masking
# the entire remainder for every supported quote style.
for display_quote in '"' "'" '`'; do
  display_unterminated="${DISPLAY_QUOTED_KEY}=${display_quote}${DISPLAY_QUOTED_HEAD}-${DISPLAY_QUOTED_TAIL}"
  display_expected="${DISPLAY_QUOTED_KEY}=${display_quote}[REDACTED]"
  display_input=$(jq -nc --arg stdout "$display_unterminated" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
  post_tool_out "$display_input"
  post_out=$(cat "$OUT")
  if printf '%s' "$post_out" \
    | jq -e --arg expected "$display_expected" \
        '.hookSpecificOutput.updatedToolOutput.stdout == $expected' >/dev/null 2>&1; then
    ok "post-tool masks an unterminated quoted assignment"
  else
    not_ok "post-tool masks the remainder of an unterminated quoted assignment"
    printf '%s\n' "$post_out" | sed 's/^/  out: /'
  fi
done

post_tool_out '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"password_policy=disabled\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
if [ "$post_status" -eq 0 ] && [ ! -s "$OUT" ]; then
  ok "post-tool does not mask metadata keys that merely begin with a secret keyword"
else
  not_ok "post-tool leaves password_policy metadata untouched"
  sed 's/^/  out: /' "$OUT"
fi

post_tool_out '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"error: password: authentication is disabled\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
if [ "$post_status" -eq 0 ] && [ ! -s "$OUT" ]; then
  ok "post-tool does not treat a prose colon as a secret assignment"
else
  not_ok "post-tool leaves prose after a secret-like key name untouched"
  sed 's/^/  out: /' "$OUT"
fi

display_input=$(jq -nc --arg stdout "- password: $DISPLAY_SECRET" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" \
  | jq -e '.hookSpecificOutput.updatedToolOutput.stdout == "- password: [REDACTED]"' >/dev/null 2>&1; then
  ok "post-tool keeps YAML sequence mapping redaction covered"
else
  not_ok "post-tool masks a secret value in a YAML sequence mapping"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Suffix-qualified real credential keys must still mask: requiring the secret
# term to be terminal dropped AWS_*_KEY_ID / *_VALUE / *_HASH names entirely.
for display_case in \
  'AWS_SECRET_ACCESS_KEY_ID=wJalrX-fake-example-key-id' \
  'API_KEY_VALUE=supersecret-value-9876' \
  'DB_PASSWORD_HASH=deadbeefdeadbeefcafe'; do
  display_key=${display_case%%=*}
  display_val=${display_case#*=}
  display_input=$(jq -nc --arg stdout "$display_case" \
    '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
  post_tool_out "$display_input"
  post_out=$(cat "$OUT")
  if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
     && ! printf '%s' "$post_out" | grep -Fq "$display_val"; then
    ok "post-tool masks suffix-qualified credential key $display_key"
  else
    not_ok "post-tool masks suffix-qualified credential key $display_key"
    printf '%s\n' "$post_out" | sed 's/^/  out: /'
  fi
done

# A colon assignment after plain whitespace (a timestamped log line) is a real
# leak, not prose: only the value token is masked, the timestamp survives.
display_input=$(jq -nc --arg stdout '2026-07-26 10:00:00 password: hunter2-timestamped-value' \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:$stdout,stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$display_input"
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && printf '%s' "$post_out" | grep -q '2026-07-26 10:00:00' \
   && ! printf '%s' "$post_out" | grep -q 'hunter2-timestamped-value'; then
  ok "post-tool masks a whitespace-prefixed colon assignment in a log line"
else
  not_ok "post-tool masks a whitespace-prefixed colon assignment in a log line"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Control: a word merely containing a secret term with a non-qualifier tail
# (tokenizer) is not an assignment key.
post_tool_out '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"tokenizer=whitespace-mode\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
if [ "$post_status" -eq 0 ] && [ ! -s "$OUT" ]; then
  ok "post-tool does not mask non-credential words that merely contain a secret term"
else
  not_ok "post-tool leaves tokenizer=... untouched"
  sed 's/^/  out: /' "$OUT"
fi

post_tool_out '{"tool_name":"Read","tool_input":{"file_path":"memo.txt"},"tool_response":"API_KEY=supersecretvalue123\n"}'
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | jq -e '.hookSpecificOutput.updatedToolOutput | type == "string"' >/dev/null 2>&1 \
   && ! printf '%s' "$post_out" | grep -q 'supersecretvalue123'; then
  ok "post-tool masks secrets in Read string output (shape stays string)"
else
  not_ok "post-tool masks secrets in Read string output"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

post_tool_out '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"stdout":"hello world\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] && [ -z "$post_out" ]; then
  ok "post-tool leaves clean output untouched (no rewrite emitted)"
else
  not_ok "post-tool leaves clean output untouched (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"memo.txt"},"tool_response":"API_KEY=supersecretvalue123\n"}' \
  | (cd "$TMP_ROOT" && AGENT_GUARD_OUTPUT_REDACT=off "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) \
  >"$OUT" 2>"$ERR"
post_status=$?
if [ "$post_status" -eq 0 ] && [ ! -s "$OUT" ]; then
  ok "post-tool redaction disabled via AGENT_GUARD_OUTPUT_REDACT=off"
else
  not_ok "post-tool redaction disabled via AGENT_GUARD_OUTPUT_REDACT=off (status $post_status)"
  sed 's/^/  out: /' "$OUT"
fi

# Overlapping secrets: when one detected value is a prefix of another, redaction
# must scrub both. Lexicographic order would replace the prefix first and strand
# the longer secret's suffix (UNIQUESUFFIX) — longest-first ordering prevents it.
post_tool_out '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"AWS_SECRET=abcdwxyzcommonpart\nAWS_SECRET_KEY=abcdwxyzcommonpartUNIQUESUFFIX\n","stderr":"","interrupted":false,"isImage":false}}'
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -q 'abcdwxyzcommonpart' \
   && ! printf '%s' "$post_out" | grep -q 'UNIQUESUFFIX'; then
  ok "post-tool redacts overlapping secrets without leaking the longer suffix"
else
  not_ok "post-tool redacts overlapping secrets without leaking the longer suffix"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Bound adversarial high-cardinality output below the 20-second PostToolUse
# manifest timeout. Per-literal tree walks are quadratic here; once the work cap
# is exceeded, every nonempty string leaf is conservatively masked in one walk.
high_cardinality_input=$(jq -nc '
  [range(0; 2500) | "PASSWORD=value-unique-\(.)-abcdefgh"] as $stdout
  | {tool_name:"Bash",tool_input:{command:"x"},tool_response:
      {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}
')
high_cardinality_started=$(date +%s)
post_tool_out "$high_cardinality_input"
high_cardinality_status=$?
high_cardinality_elapsed=$(($(date +%s) - high_cardinality_started))
post_out=$(cat "$OUT")
if [ "$high_cardinality_status" -eq 0 ] \
   && [ "$high_cardinality_elapsed" -lt 15 ] \
   && printf '%s' "$post_out" \
        | jq -e '
            .hookSpecificOutput.updatedToolOutput as $out
            | ($out.stdout | length) == 2500
            and ($out.stdout | all(. == "[REDACTED]"))
            and $out.stderr == ""
            and $out.interrupted == false
            and $out.isImage == false
          ' >/dev/null 2>&1 \
   && ! printf '%s' "$post_out" | grep -q 'value-unique-'; then
  ok "post-tool bounds high-cardinality redaction below the hook timeout"
else
  not_ok "post-tool fail-closes high-cardinality output in bounded time (${high_cardinality_elapsed}s)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Empty leaves still incur per-spec traversal unless they are counted in the
# work estimate and skipped in the precise path. This sparse shape previously
# stayed below a character-only cap and exhausted the same 20-second timeout.
sparse_cardinality_input=$(jq -nc '
  ([range(0; 256) | "PASSWORD=value-sparse-\(.)-abcdefgh"]
   + [range(0; 50000) | ""]) as $stdout
  | {tool_name:"Bash",tool_input:{command:"x"},tool_response:
      {stdout:$stdout,stderr:"",interrupted:false,isImage:false}}
')
sparse_cardinality_started=$(date +%s)
post_tool_out "$sparse_cardinality_input"
sparse_cardinality_status=$?
sparse_cardinality_elapsed=$(($(date +%s) - sparse_cardinality_started))
post_out=$(cat "$OUT")
if [ "$sparse_cardinality_status" -eq 0 ] \
   && [ "$sparse_cardinality_elapsed" -lt 15 ] \
   && printf '%s' "$post_out" \
        | jq -e '
            .hookSpecificOutput.updatedToolOutput as $out
            | ($out.stdout | length) == 50256
            and ($out.stdout[0:256] | all(. == "[REDACTED]"))
            and ($out.stdout[256:] | all(. == ""))
            and $out.stderr == ""
          ' >/dev/null 2>&1 \
   && ! printf '%s' "$post_out" | grep -q 'value-sparse-'; then
  ok "post-tool counts empty-leaf traversal in the redaction work cap"
else
  not_ok "post-tool bounds sparse high-cardinality output (${sparse_cardinality_elapsed}s)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Detection itself must also stay below the hook deadline for very large
# assignment dumps. A streaming preflight confirms the secret-bearing shape
# before skipping unique-literal collection and masking nonempty leaves once.
large_detection_input=$(jq -nc '
  [range(0; 30000) | "PASSWORD=value-detection-\(.)-abcdefgh"] as $stdout
  | {tool_name:"Read",tool_input:{file_path:"dump.json"},
     tool_response:$stdout}
')
large_detection_started=$(date +%s)
post_tool_out "$large_detection_input"
large_detection_status=$?
large_detection_elapsed=$(($(date +%s) - large_detection_started))
post_out=$(cat "$OUT")
if [ "$large_detection_status" -eq 0 ] \
   && [ "$large_detection_elapsed" -lt 15 ] \
   && printf '%s' "$post_out" \
        | jq -e '
            .hookSpecificOutput.updatedToolOutput as $out
            | ($out | length) == 30000
            and ($out | all(. == "[REDACTED]"))
          ' >/dev/null 2>&1 \
   && ! printf '%s' "$post_out" | grep -q 'value-detection-'; then
  ok "post-tool bounds large high-cardinality secret detection"
else
  not_ok "post-tool bounds large secret detection (${large_detection_elapsed}s)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Assignment-shaped output has a dedicated streaming preflight, but every
# detector source must be bounded before its records are aggregated. Unique
# Bearer tokens exercise the non-assignment path and would otherwise build a
# secrets argv beyond Linux's per-argument limit before the whole-leaf fallback.
large_bearer_input=$(jq -nc '
  [range(0; 10000)
   | "Authorization: Bearer token-unique-\(.)-abcdefgh"] as $stdout
  | {tool_name:"Read",tool_input:{file_path:"bearer-dump.txt"},
     tool_response:$stdout}
')
large_bearer_started=$(date +%s)
post_tool_out "$large_bearer_input"
large_bearer_status=$?
large_bearer_elapsed=$(($(date +%s) - large_bearer_started))
post_out=$(cat "$OUT")
if [ "$large_bearer_status" -eq 0 ] \
   && [ "$large_bearer_elapsed" -lt 15 ] \
   && printf '%s' "$post_out" \
        | jq -e '
            .hookSpecificOutput.updatedToolOutput as $out
            | ($out | length) == 10000
            and ($out | all(. == "[REDACTED]"))
          ' >/dev/null 2>&1 \
   && ! printf '%s' "$post_out" | grep -q 'token-unique-'; then
  ok "post-tool bounds non-assignment secret aggregation"
else
  not_ok "post-tool bounds non-assignment secret aggregation (${large_bearer_elapsed}s)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

large_clean_input=$(jq -nc '
  {tool_name:"Read",tool_input:{file_path:"clean.txt"},
   tool_response:("a" * 300000)}
')
large_clean_started=$(date +%s)
post_tool_out "$large_clean_input"
large_clean_status=$?
large_clean_elapsed=$(($(date +%s) - large_clean_started))
if [ "$large_clean_status" -eq 0 ] \
   && [ "$large_clean_elapsed" -lt 15 ] \
   && [ ! -s "$OUT" ]; then
  ok "post-tool leaves large clean output unchanged"
else
  not_ok "post-tool preserves large clean output (${large_clean_elapsed}s)"
  sed 's/^/  out: /' "$OUT"
fi

# Gitleaks work must be bounded before it scans or writes a high-cardinality
# report. The stub records stdin-mode invocation and can emit a report above the
# 64 KiB cap without using assignment, JWT, or Bearer-shaped fixture content.
BOUNDED_GL_DIR="$TMP_ROOT/bounded-gitleaks"
BOUNDED_GL="$BOUNDED_GL_DIR/gitleaks"
BOUNDED_GL_MARKER="$TMP_ROOT/bounded-gitleaks.stdin"
mkdir -p "$BOUNDED_GL_DIR"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'mode=${1:-}'
  printf '%s\n' 'case "$mode" in'
  printf '%s\n' '  version) printf "%s\n" "0.0.0-bounded-test"; exit 0 ;;'
  printf '%s\n' '  stdin)'
  printf '%s\n' '    shift; report='
  printf '%s\n' '    while [ "$#" -gt 0 ]; do'
  printf '%s\n' '      case "$1" in'
  printf '%s\n' '        --report-path) shift; report=${1:-} ;;'
  printf '%s\n' '        --report-path=*) report=${1#--report-path=} ;;'
  printf '%s\n' '      esac'
  printf '%s\n' '      shift'
  printf '%s\n' '    done'
  printf '%s\n' '    cat >/dev/null'
  printf '%s\n' '    : >"${AGENT_GUARD_TEST_GITLEAKS_MARKER:?}"'
  printf '%s\n' '    if [ "${AGENT_GUARD_TEST_GITLEAKS_MODE:-empty}" = huge-report ]; then'
  printf '%s\n' '      awk '\''BEGIN {'
  printf '%s\n' '        printf "["'
  printf '%s\n' '        for (i = 0; i < 5000; i++) {'
  printf '%s\n' '          if (i) printf ","'
  printf '%s\n' '          printf "{\"Secret\":\"opaque-%06d-abcdefgh\"}", i'
  printf '%s\n' '        }'
  printf '%s\n' '        print "]"'
  printf '%s\n' '      }'\'' >"$report"'
  printf '%s\n' '    else'
  printf '%s\n' '      printf "%s\n" "[]" >"$report"'
  printf '%s\n' '    fi'
  printf '%s\n' '    exit 0'
  printf '%s\n' '    ;;'
  printf '%s\n' 'esac'
  printf '%s\n' 'exit 2'
} >"$BOUNDED_GL"
chmod +x "$BOUNDED_GL"

rm -f "$BOUNDED_GL_MARKER"
large_gitleaks_input=$(jq -nc '
  {tool_name:"Read",tool_input:{file_path:"opaque-dump.txt"},
   tool_response:("opaque-material-" + ("a" * 340000))}
')
large_gitleaks_started=$(date +%s)
printf '%s' "$large_gitleaks_input" \
  | (cd "$TMP_ROOT" \
      && AGENT_GUARD_GITLEAKS_BIN="$BOUNDED_GL" \
         AGENT_GUARD_TEST_GITLEAKS_MARKER="$BOUNDED_GL_MARKER" \
         "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) >"$OUT" 2>"$ERR"
large_gitleaks_status=$?
large_gitleaks_elapsed=$(($(date +%s) - large_gitleaks_started))
post_out=$(cat "$OUT")
if [ "$large_gitleaks_status" -eq 0 ] \
   && [ "$large_gitleaks_elapsed" -lt 15 ] \
   && [ ! -e "$BOUNDED_GL_MARKER" ] \
   && printf '%s' "$post_out" \
        | jq -e '.hookSpecificOutput.updatedToolOutput == "[REDACTED]"' \
          >/dev/null 2>&1; then
  ok "post-tool bounds oversized output before invoking gitleaks"
else
  not_ok "post-tool lets oversized output reach gitleaks (${large_gitleaks_elapsed}s)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

rm -f "$BOUNDED_GL_MARKER"
small_gitleaks_input=$(jq -nc '
  {tool_name:"Read",tool_input:{file_path:"opaque-small.txt"},
   tool_response:"opaque material with no heuristic token shape"}
')
printf '%s' "$small_gitleaks_input" \
  | (cd "$TMP_ROOT" \
      && AGENT_GUARD_GITLEAKS_BIN="$BOUNDED_GL" \
         AGENT_GUARD_TEST_GITLEAKS_MARKER="$BOUNDED_GL_MARKER" \
         AGENT_GUARD_TEST_GITLEAKS_MODE=huge-report \
         "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) >"$OUT" 2>"$ERR"
small_gitleaks_status=$?
post_out=$(cat "$OUT")
if [ "$small_gitleaks_status" -eq 0 ] \
   && [ -e "$BOUNDED_GL_MARKER" ] \
   && printf '%s' "$post_out" \
        | jq -e '.hookSpecificOutput.updatedToolOutput == "[REDACTED]"' \
          >/dev/null 2>&1; then
  ok "post-tool fails closed when the gitleaks report exceeds its cap"
else
  not_ok "post-tool trusts an oversized or truncated gitleaks report"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# A newline-heavy leaf previously missed the escape-free single-record fast
# path and repeatedly copied the accumulated leaf before its final boundary.
# The shared cap must fire before that probe, including when the credential is
# only at the very end of the response.
newline_heavy_input=$(jq -nc '
  {tool_name:"Read",tool_input:{file_path:"newline-dump.txt"},
   tool_response:(([range(0; 50000) | "clean"] +
                   ["PASSWORD=abcdefghijklmnop"]) | join("\n"))}
')
newline_heavy_started=$(date +%s)
post_tool_out "$newline_heavy_input"
newline_heavy_status=$?
newline_heavy_elapsed=$(($(date +%s) - newline_heavy_started))
post_out=$(cat "$OUT")
if [ "$newline_heavy_status" -eq 0 ] \
   && [ "$newline_heavy_elapsed" -lt 15 ] \
   && printf '%s' "$post_out" \
        | jq -e '.hookSpecificOutput.updatedToolOutput == "[REDACTED]"' \
          >/dev/null 2>&1 \
   && ! printf '%s' "$post_out" | grep -q 'abcdefghijklmnop'; then
  ok "post-tool preflights newline-heavy leaves before assignment probing"
else
  not_ok "post-tool scans newline-heavy over-cap leaves quadratically (${newline_heavy_elapsed}s)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# If the shape-preserving whole-leaf jq transform itself fails, mandatory
# redaction must still reach both host envelopes as a JSON string sentinel.
FAIL_WHOLE_JQ_DIR="$TMP_ROOT/fail-whole-jq"
FAIL_WHOLE_JQ="$FAIL_WHOLE_JQ_DIR/jq"
mkdir -p "$FAIL_WHOLE_JQ_DIR"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'case " $* " in'
  printf '%s\n' '  *"length > 0"*) exit 2 ;;'
  printf '%s\n' 'esac'
  printf '%s\n' 'exec "${AGENT_GUARD_TEST_REAL_JQ:?}" "$@"'
} >"$FAIL_WHOLE_JQ"
chmod +x "$FAIL_WHOLE_JQ"

printf '%s' "$large_gitleaks_input" \
  | (cd "$TMP_ROOT" \
      && PATH="$FAIL_WHOLE_JQ_DIR:$PATH" \
         AGENT_GUARD_TEST_REAL_JQ="$REAL_JQ" \
         "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) >"$OUT" 2>"$ERR"
failed_whole_claude_status=$?
failed_whole_claude_out=$(cat "$OUT")
if [ "$failed_whole_claude_status" -eq 0 ] \
   && printf '%s' "$failed_whole_claude_out" \
        | jq -e '.hookSpecificOutput.updatedToolOutput == "[REDACTED]"' \
          >/dev/null 2>&1 \
   && ! printf '%s' "$failed_whole_claude_out" | grep -q 'opaque-material-'; then
  ok "post-tool fail-closes a failed whole-leaf rewrite for Claude"
else
  not_ok "post-tool leaks over-cap output when the Claude whole-leaf rewrite fails"
  printf '%s\n' "$failed_whole_claude_out" | sed 's/^/  out: /'
fi

printf '%s' "$large_gitleaks_input" \
  | (cd "$TMP_ROOT" \
      && PATH="$FAIL_WHOLE_JQ_DIR:$PATH" \
         AGENT_GUARD_TEST_REAL_JQ="$REAL_JQ" \
         AGENT_GUARD_HOOK_HOST=codex \
         "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) >"$OUT" 2>"$ERR"
failed_whole_codex_status=$?
failed_whole_codex_out=$(cat "$OUT")
if [ "$failed_whole_codex_status" -eq 0 ] \
   && printf '%s' "$failed_whole_codex_out" \
        | jq -e '.decision == "block"
                 and (.hookSpecificOutput.additionalContext
                      | contains("[REDACTED]"))' >/dev/null 2>&1 \
   && ! printf '%s' "$failed_whole_codex_out" | grep -q 'opaque-material-'; then
  ok "post-tool fail-closes a failed whole-leaf rewrite for Codex"
else
  not_ok "post-tool leaks over-cap output when the Codex whole-leaf rewrite fails"
  printf '%s\n' "$failed_whole_codex_out" | sed 's/^/  out: /'
fi

# The large-response assignment probe consumes framed leaves. A sanitized value
# must be checked after removing the transport boundary or `[REDACTED]` plus RS
# is mistaken for a new secret and unrelated clean leaves are over-masked.
large_sanitized_input=$(jq -nc '
  {tool_name:"Read",tool_input:{file_path:"sanitized-dump.txt"},
   tool_response:["PASSWORD=[REDACTED]", ("a" * 300000)]}
')
post_tool_out "$large_sanitized_input"
if [ ! -s "$OUT" ]; then
  ok "post-tool large probe preserves already-sanitized assignments"
else
  not_ok "post-tool large probe over-masks an already-sanitized assignment"
  sed 's/^/  out: /' "$OUT"
fi

# Log/timestamp prefix must not hijack the env-heuristic split: the value is
# anchored to the matched key's delimiter, not the first ":" (here inside the
# "12:00:00" timestamp). A clean copy in a SEPARATE leaf (stderr) only gets
# masked if the extracted literal is the real value, so this catches a mis-slice.
post_tool_out '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"2026-06-30T12:00:00Z level=info password=SuperSecretLogValue\n","stderr":"echoed SuperSecretLogValue\n","interrupted":false,"isImage":false}}'
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -q 'SuperSecretLogValue'; then
  ok "post-tool anchors env value past a log prefix and masks it across leaves"
else
  not_ok "post-tool anchors env value past a log prefix and masks it across leaves"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# JWT (three base64url segments, first two start `eyJ`) is masked whole. The
# token is glued from fragments at runtime so this file holds no contiguous
# JWT-shaped literal an upstream scanner would flag. gitleaks is not relied on
# here (the mock only flags AGENT_GUARD_TEST_SECRET) — the JWT producer detects it.
jwt_h='eyJ''hbGciOiJIUzI1NiJ9'
jwt_p='eyJ''zdWIiOiJhZ2VudCJ9'
jwt_s='sig''NatureVal_ABC-123xyz'
jwt_tok="$jwt_h.$jwt_p.$jwt_s"
jwt_in=$(jq -nc --arg s "cached session token $jwt_tok in memory" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($s+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$jwt_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$jwt_tok" \
   && printf '%s' "$post_out" | jq -e '.hookSpecificOutput.updatedToolOutput | has("stdout") and has("stderr") and has("interrupted") and has("isImage")' >/dev/null 2>&1; then
  ok "post-tool masks a JWT in tool output (shape preserved)"
else
  not_ok "post-tool masks a JWT in tool output (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Bearer credential: only the token is masked, the `Authorization: Bearer ` label
# survives. Token glued from fragments so no contiguous credential sits in-file.
bear_tok='abcDEF123''_bearer-token-value'
bear_in=$(jq -nc --arg s "Authorization: Bearer $bear_tok" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($s+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$bear_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$bear_tok" \
   && printf '%s' "$post_out" | grep -q 'Authorization: Bearer' \
   && printf '%s' "$post_out" | jq -e '.hookSpecificOutput.updatedToolOutput | has("stdout") and has("stderr")' >/dev/null 2>&1; then
  ok "post-tool masks a Bearer token but keeps the Authorization label"
else
  not_ok "post-tool masks a Bearer token but keeps the Authorization label (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Newly-covered env key: SESSION_KEY= (value glued from fragments).
sk_val='s3ssion''-key-secret-value-xyz'
sk_in=$(jq -nc --arg s "SESSION_KEY=$sk_val" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($s+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$sk_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$sk_val" \
   && printf '%s' "$post_out" | jq -e '.hookSpecificOutput.updatedToolOutput | has("stdout")' >/dev/null 2>&1; then
  ok "post-tool env heuristic masks a newly-covered SESSION_KEY= value"
else
  not_ok "post-tool env heuristic masks a newly-covered SESSION_KEY= value (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Over-masking guard: a benign sentence that merely contains the word "token"
# (no key delimiter, no secret shape) must survive VERBATIM even when a real
# secret on another line forces a rewrite. Catches regex creep that would mask
# ordinary prose. PASSPHRASE= value glued from fragments.
benign_line='The deployment token is rotated every 90 days.'
pp_val='correct''-horse-battery-staple-7'
guard_in=$(jq -nc --arg b "$benign_line" --arg v "PASSPHRASE=$pp_val" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($b+"\n"+$v+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$guard_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$pp_val" \
   && printf '%s' "$post_out" | grep -Fq "$benign_line"; then
  ok "post-tool does not over-mask benign prose containing the word token"
else
  not_ok "post-tool does not over-mask benign prose containing the word token (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Bearer token containing base64/base64url payload chars (+ / = ~) must be masked
# WHOLE, not truncated at the first `+`. Regression for the char-class fix. The
# distinctive tail must not survive (it would if the match stopped early).
b64_tok='abcDEF123''+/tailXYZ=='
b64_in=$(jq -nc --arg s "Authorization: Bearer $b64_tok" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($s+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$b64_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$b64_tok" \
   && ! printf '%s' "$post_out" | grep -Fq 'tailXYZ' \
   && printf '%s' "$post_out" | grep -q 'Authorization: Bearer'; then
  ok "post-tool masks a Bearer token whole when it holds base64 chars"
else
  not_ok "post-tool masks a Bearer token whole when it holds base64 chars (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# All-caps BEARER (HTTP auth scheme is case-insensitive) must still be caught.
caps_tok='ZYXwvu987''_caps-bearer-tok'
caps_in=$(jq -nc --arg s "authorization: BEARER $caps_tok" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($s+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$caps_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$caps_tok"; then
  ok "post-tool masks an all-caps BEARER token"
else
  not_ok "post-tool masks an all-caps BEARER token (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Over-masking guard for the pat/pwd suffix rule: benign keys that merely START
# with pat/pwd after an underscore (NODE_PATH=, FILE_PATTERN=) must survive
# verbatim, even when a real secret on another line forces a rewrite. Regression
# for anchoring `_pat`/`_pwd` to the delimiter.
np_line='NODE_PATH=/usr/lib/node_modules'
fp_line='FILE_PATTERN=*.md'
pat_secret='s3ssion''-key-secret-value-xyz'
pat_in=$(jq -nc --arg a "$np_line" --arg b "$fp_line" --arg s "SESSION_KEY=$pat_secret" \
  '{tool_name:"Bash",tool_input:{command:"x"},tool_response:{stdout:($a+"\n"+$b+"\n"+$s+"\n"),stderr:"",interrupted:false,isImage:false}}')
post_tool_out "$pat_in"
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$post_out" | grep -Fq "$pat_secret" \
   && printf '%s' "$post_out" | grep -Fq "$np_line" \
   && printf '%s' "$post_out" | grep -Fq "$fp_line"; then
  ok "post-tool does not over-mask NODE_PATH= / FILE_PATTERN= benign keys"
else
  not_ok "post-tool does not over-mask NODE_PATH= / FILE_PATTERN= benign keys (status $post_status)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# --- PII output masking (PostToolUse, AGENT_GUARD_PII_HOOK_MODE=mask) ---------
# Masks PII in a tool's RESULT (parallel to secret redaction). Run from the
# non-git TMP_ROOT so the mutation backstop stays inert.
post_tool_pii() {
  printf '%s' "$1" | (cd "$TMP_ROOT" && AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool) \
    >"$OUT" 2>"$ERR"
}

post_tool_pii '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"user jane@example.com ip 10.1.2.3 id 900101-1234567\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] \
   && printf '%s' "$post_out" | grep -q '\[PII:EMAIL\]' \
   && printf '%s' "$post_out" | grep -q '\[PII:IP_ADDRESS\]' \
   && printf '%s' "$post_out" | grep -q '\[PII:KR_RRN\]' \
   && ! printf '%s' "$post_out" | grep -q 'jane@example.com' \
   && printf '%s' "$post_out" | jq -e '.hookSpecificOutput.updatedToolOutput | has("stdout") and has("stderr")' >/dev/null 2>&1; then
  ok "post-tool mask mode masks email/IP/KR-RRN in output (shape preserved)"
else
  not_ok "post-tool mask mode masks PII in output"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Without mask mode, PII in output is left untouched (no rewrite emitted).
post_tool_out '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"user jane@example.com\n","stderr":"","interrupted":false,"isImage":false}}'
post_status=$?
post_out=$(cat "$OUT")
if [ "$post_status" -eq 0 ] && [ -z "$post_out" ]; then
  ok "post-tool leaves PII untouched without mask mode (default)"
else
  not_ok "post-tool leaves PII untouched without mask mode (default)"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# Secret redaction and PII masking compose into one updatedToolOutput across leaves.
post_tool_pii '{"tool_name":"Bash","tool_input":{"command":"x"},"tool_response":{"stdout":"DATABASE_PASSWORD=hunter2longvalue\n","stderr":"notified jane@example.com\n","interrupted":false,"isImage":false}}'
post_out=$(cat "$OUT")
if printf '%s' "$post_out" | grep -q '\[REDACTED\]' \
   && printf '%s' "$post_out" | grep -q '\[PII:EMAIL\]' \
   && ! printf '%s' "$post_out" | grep -q 'jane@example.com'; then
  ok "post-tool composes secret redaction and PII masking in one rewrite"
else
  not_ok "post-tool composes secret redaction and PII masking in one rewrite"
  printf '%s\n' "$post_out" | sed 's/^/  out: /'
fi

# CLI pii-filter (regex adapter) masks Korean PII: resident reg. no. and mobile.
pii_cli=$(printf 'rrn 900101-1234567 mob 010-1234-5678\n' | "$PLUGIN_ROOT/bin/agent-guard" pii-filter 2>/dev/null)
if printf '%s' "$pii_cli" | grep -q '\[PII:KR_RRN\]' \
   && printf '%s' "$pii_cli" | grep -q '\[PII:PHONE\]' \
   && ! printf '%s' "$pii_cli" | grep -q '900101-1234567'; then
  ok "pii-filter masks Korean resident reg. no. and mobile"
else
  not_ok "pii-filter masks Korean resident reg. no. and mobile"
  printf '%s\n' "$pii_cli" | sed 's/^/  out: /'
fi

# The CLI regex adapter and the hook output masker must mask the SAME sample
# identically — credit card and SSN are included so a drift in either Tier-2 rule
# (pii_regex_adapter_filter vs mask_pii_response_json vs pii_tier2_present) is caught.
# Card assembled at runtime so this test file holds no contiguous PAN.
sync_cc="4111 1111 ""1111 1111"
sync_amex="3782 ""822463 ""10005"
sync_sample="card $sync_cc amex $sync_amex ssn 123-45-6789 ip 8.8.8.8 mail x@y.io rrn 900101-1234567 mob 010-1234-5678"
sync_cli=$(printf '%s\n' "$sync_sample" | "$PLUGIN_ROOT/bin/agent-guard" pii-filter 2>/dev/null)
sync_hin=$(printf '{"tool_name":"Read","tool_input":{"file_path":"m"},"tool_response":%s}' "$(printf '%s' "$sync_sample" | jq -Rs .)")
sync_hook=$(printf '%s' "$sync_hin" | (cd "$TMP_ROOT" && AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool 2>/dev/null) | jq -r '.hookSpecificOutput.updatedToolOutput')
if [ -n "$sync_hook" ] && [ "$sync_cli" = "$sync_hook" ] \
   && printf '%s' "$sync_hook" | grep -q '\[PII:CREDIT_CARD\]' \
   && printf '%s' "$sync_hook" | grep -q '\[PII:SSN\]'; then
  ok "CLI pii-filter and hook output masker mask identically (incl. card + SSN)"
else
  not_ok "CLI pii-filter and hook output masker mask identically"
  printf '%s\n' "  cli : $sync_cli" "  hook: $sync_hook"
fi

# --- agent-guard exec (shell-escape output masking) --------------------------
# `agent-guard exec` runs a command and masks secret-like values in its captured
# output before printing. Secret VALUE assembled at runtime from fragments so this
# file never holds a contiguous `token=...`-shaped literal upstream scanners flag.
EXEC_KEY='to''ken='
EXEC_VAL='abcd1234efgh5678ijkl9012mnop3456'
EXEC_LINE="${EXEC_KEY}${EXEC_VAL}"

exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- printf '%s\n' "$EXEC_LINE" 2>/dev/null)
if printf '%s' "$exec_out" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$exec_out" | grep -q "$EXEC_VAL"; then
  ok "exec masks a secret in a command's output"
else
  not_ok "exec masks a secret in a command's output"
  printf '%s\n' "  out: $exec_out"
fi

exec_large_started=$(date +%s)
exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  awk 'BEGIN {
    for (i = 0; i < 10000; i++)
      printf "Authorization: Bearer token-unique-%d-abcdefgh\n", i
  }' 2>/dev/null)
exec_large_status=$?
exec_large_elapsed=$(($(date +%s) - exec_large_started))
if [ "$exec_large_status" -eq 0 ] \
   && [ "$exec_large_elapsed" -lt 15 ] \
   && [ "$exec_out" = "[REDACTED]" ]; then
  ok "exec bounds high-cardinality non-assignment redaction"
else
  not_ok "exec bounds high-cardinality non-assignment redaction (${exec_large_elapsed}s)"
  printf '%s\n' "  out: $exec_out"
fi

EXEC_MULTILINE=$(printf 'PASSWORD="%s\n%s" status=ok' \
  "$DISPLAY_QUOTED_HEAD" "$DISPLAY_QUOTED_TAIL")
exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- printf '%s\n' "$EXEC_MULTILINE" 2>/dev/null)
exec_expected='PASSWORD="[REDACTED]" status=ok'
if [ "$exec_out" = "$exec_expected" ]; then
  ok "exec masks a multiline quoted assignment as one complete value"
else
  not_ok "exec masks the complete multiline quoted assignment"
  printf '%s\n' "  out: $exec_out"
fi

exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  printf '%s\n' \
    'PASSWORD=a))) status=available abc ab a ))) PASSWORD=abcdef' 2>/dev/null)
if [ "$exec_out" = \
  'PASSWORD=[REDACTED]))) status=available abc ab a ))) PASSWORD=[REDACTED]' ]; then
  ok "exec scopes a short secret without stranding a longer value"
else
  not_ok "exec avoids short-literal prefix replacement"
  printf '%s\n' "  out: $exec_out"
fi

exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  printf '%s\n' 'PASSWORD=abc) PASSWORD=abc)evil status=ok' 2>/dev/null)
if [ "$exec_out" = \
  'PASSWORD=[REDACTED]) PASSWORD=[REDACTED] status=ok' ]; then
  ok "exec requires a boundary after a contextual token"
else
  not_ok "exec does not strand a longer assignment suffix"
  printf '%s\n' "  out: $exec_out"
fi

exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  printf 'PASSWORD=abc)\nstatus=available\n' 2>/dev/null)
exec_expected=$(printf 'PASSWORD=[REDACTED])\nstatus=available')
if [ "$exec_out" = "$exec_expected" ]; then
  ok "exec treats a newline as a contextual token boundary"
else
  not_ok "exec masks a short secret at physical line end"
  printf '%s\n' "  out: $exec_out"
fi

exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  printf '%s\n' "$DISPLAY_SHARED_LINE" 2>/dev/null)
if [ "$exec_out" = \
  'PASSWORD=[REDACTED]) API_TOKEN="[REDACTED]" status=ok' ]; then
  ok "exec keeps contextual and ordinary meanings for one literal"
else
  not_ok "exec masks a shared contextual and quoted literal"
  printf '%s\n' "  out: $exec_out"
fi

EXEC_FRAMED_SECRET=$(printf 'abcd\036efgh\037tail')
exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  printf 'PASSWORD=%s\n' "$EXEC_FRAMED_SECRET" 2>/dev/null)
if [ "$exec_out" = 'PASSWORD=[REDACTED]' ]; then
  ok "exec treats framed control bytes as secret data"
else
  not_ok "exec does not lose framed control bytes during masking"
  printf '%s' "$exec_out" | LC_ALL=C od -An -tx1c | sed 's/^/  hex: /'
fi

# Plaintext replacement must not transcode unrelated non-UTF-8 bytes when a
# later credential triggers redaction.
"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\nPASSWORD=%s\n" "$1"' _ "$EXEC_VAL" >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
if [ "$exec_first_byte" = ff ] \
   && grep -a -q '\[REDACTED\]' "$OUT" \
   && ! grep -a -Fq "$EXEC_VAL" "$OUT"; then
  ok "exec preserves unrelated non-UTF-8 bytes while masking a secret"
else
  not_ok "exec keeps plaintext redaction byte-preserving"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

# Detection must also stay byte-exact when the invalid byte is part of the
# assignment value rather than unrelated output.
"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "PASSWORD=\"abc\377defghijklmnop\" status=ok\n"' >"$OUT" 2>/dev/null
exec_out=$(LC_ALL=C sed -n '1p' "$OUT")
if [ "$exec_out" = 'PASSWORD="[REDACTED]" status=ok' ]; then
  ok "exec masks a secret containing a non-UTF-8 byte"
else
  not_ok "exec keeps secret detection byte-preserving"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

# Invalid UTF-8 disables the lossy JSON assignment pass. If the byte-preserving
# path cannot allocate its secret-record file, it must mask the complete output
# instead of silently skipping the only assignment detector that can match it.
NO_MKTEMP_BIN="$TMP_ROOT/no-mktemp-bin"
mkdir -p "$NO_MKTEMP_BIN"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$NO_MKTEMP_BIN/mktemp"
chmod +x "$NO_MKTEMP_BIN/mktemp"
PATH="$NO_MKTEMP_BIN:$PATH" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
    'printf "PASSWORD=abcdefgh\377ijklmnop\n"' >"$OUT" 2>/dev/null
exec_out=$(LC_ALL=C sed -n '1p' "$OUT")
if [ "$exec_out" = '[REDACTED]' ]; then
  ok "exec fails closed when raw-byte temp allocation fails"
else
  not_ok "exec leaks invalid-byte assignments when temp allocation fails"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\nPASSWORD=)))) benign=))) PASSWORD=off\n"' >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
exec_last_line=$(LC_ALL=C sed -n '2p' "$OUT")
if [ "$exec_first_byte" = ff ] \
   && [ "$exec_last_line" = \
     'PASSWORD=[REDACTED])))) benign=))) PASSWORD=off' ]; then
  ok "exec scopes an all-closer secret on the raw byte path"
else
  not_ok "exec preserves unrelated punctuation and values on the raw byte path"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\nPASSWORD=abc) PASSWORD=abc)evil status=ok\n"' >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
exec_last_line=$(LC_ALL=C sed -n '2p' "$OUT")
if [ "$exec_first_byte" = ff ] \
   && [ "$exec_last_line" = \
     'PASSWORD=[REDACTED]) PASSWORD=[REDACTED] status=ok' ]; then
  ok "exec enforces a contextual boundary on the raw byte path"
else
  not_ok "exec raw masking does not strand a longer assignment suffix"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\nPASSWORD=abc)\nstatus=available\n"' >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
exec_second_line=$(LC_ALL=C sed -n '2p' "$OUT")
exec_third_line=$(LC_ALL=C sed -n '3p' "$OUT")
if [ "$exec_first_byte" = ff ] \
   && [ "$exec_second_line" = 'PASSWORD=[REDACTED])' ] \
   && [ "$exec_third_line" = 'status=available' ]; then
  ok "exec accepts a raw newline as a contextual token boundary"
else
  not_ok "exec raw masking catches a short secret at physical line end"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\n%s\n" "$1"' _ "$DISPLAY_SHARED_LINE" >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
exec_last_line=$(LC_ALL=C sed -n '2p' "$OUT")
if [ "$exec_first_byte" = ff ] \
   && [ "$exec_last_line" = \
     'PASSWORD=[REDACTED]) API_TOKEN="[REDACTED]" status=ok' ]; then
  ok "exec raw masking keeps contextual and ordinary meanings for one literal"
else
  not_ok "exec raw masking preserves both shared-literal records"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\nPASSWORD=abcd\036efgh\037tail\n"' >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
exec_last_line=$(LC_ALL=C sed -n '2p' "$OUT")
if [ "$exec_first_byte" = ff ] \
   && [ "$exec_last_line" = 'PASSWORD=[REDACTED]' ]; then
  ok "exec raw masking treats framed control bytes as secret data"
else
  not_ok "exec raw masking preserves framed control bytes"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

exec_out=$("$PLUGIN_ROOT/bin/agent-guard" exec -- \
  printf '%s\n' 'PASSWORD=[REDACTED]' 2>/dev/null)
if [ "$exec_out" = 'PASSWORD=[REDACTED]' ]; then
  ok "exec keeps an existing redaction sentinel idempotent"
else
  not_ok "exec does not corrupt an existing redaction sentinel"
  printf '%s\n' "  out: $exec_out"
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c \
  'printf "\377\nPASSWORD=[REDACTED]\n"' >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
exec_last_line=$(LC_ALL=C sed -n '2p' "$OUT")
if [ "$exec_first_byte" = ff ] \
   && [ "$exec_last_line" = 'PASSWORD=[REDACTED]' ]; then
  ok "exec keeps a redaction sentinel idempotent on the raw byte path"
else
  not_ok "exec does not corrupt a redaction sentinel on the raw byte path"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

INVALID_PRINTENV_VAL=$(printf 'abc\377defghijklmnop')
DEMO_TOKEN="${INVALID_PRINTENV_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv DEMO_TOKEN >"$OUT" 2>/dev/null
if [ "$(cat "$OUT")" = '[REDACTED]' ]; then
  ok "exec masks an invalid-byte printenv value by secret-bearing name"
else
  not_ok "exec does not leak an invalid-byte printenv value"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

PRINTENV_PUBLIC='public-value' DEMO_TOKEN="${INVALID_PRINTENV_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- \
    printenv DEMO_TOKEN PRINTENV_PUBLIC >"$OUT" 2>/dev/null
if [ "$(cat "$OUT")" = '[REDACTED]' ]; then
  ok "exec conservatively masks multi-name invalid-byte printenv output"
else
  not_ok "exec does not leak invalid bytes from multi-name printenv"
  LC_ALL=C od -An -tx1 "$OUT" | sed 's/^/  hex: /'
fi

# One invalid byte can force the raw fallback. Bound secret-bearing assignment
# dumps without hiding equally large benign binary-ish output.
"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c '
  printf "\377\n"
  awk "BEGIN { for (i = 0; i < 5000; i++) print \"PASSWORD=value-1234567890-\" i }"
' >"$OUT" 2>/dev/null
if [ "$(cat "$OUT")" = '[REDACTED]' ]; then
  ok "exec conservatively bounds oversized invalid-byte output"
else
  not_ok "exec bounds the invalid-byte redaction fallback"
  LC_ALL=C wc -c "$OUT" | sed 's/^/  bytes: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c '
  printf "\377\n"
  awk "BEGIN { for (i = 0; i < 70000; i++) printf \"x\" }"
' >"$OUT" 2>/dev/null
exec_first_byte=$(LC_ALL=C od -An -tx1 "$OUT" | awk 'NR == 1 { print $1 }')
if [ "$exec_first_byte" = ff ] \
   && [ "$(LC_ALL=C wc -c <"$OUT" | tr -d ' ')" -gt 65536 ] \
   && ! grep -a -q '\[REDACTED\]' "$OUT"; then
  ok "exec preserves oversized invalid-byte output without secret records"
else
  not_ok "exec does not over-mask oversized benign invalid-byte output"
  LC_ALL=C wc -c "$OUT" | sed 's/^/  bytes: /'
fi

# The oversized raw probe must keep one quote state across physical records.
# A sanitized-looking prefix is not proof that a multiline continuation is safe.
"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c '
  printf "PASSWORD=\"[REDACTED]\n"
  printf "credential-continuation-should-not-leak"
  awk "BEGIN { for (i = 0; i < 70000; i++) printf \"x\" }"
  printf "\377\n"
' >"$OUT" 2>/dev/null
if [ "$(cat "$OUT")" = '[REDACTED]' ]; then
  ok "exec raw probe retains multiline quote state across records"
else
  not_ok "exec raw probe does not trust a sanitized multiline prefix"
  LC_ALL=C wc -c "$OUT" | sed 's/^/  bytes: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c '
  printf "\377\n"
  awk "BEGIN { for (i = 0; i < 5000; i++) print \"PASSWORD=[REDACTED]\" }"
' >"$OUT" 2>/dev/null
if [ "$(grep -ac '^PASSWORD=\[REDACTED\]$' "$OUT")" -eq 5000 ]; then
  ok "exec keeps oversized invalid-byte redaction sentinels idempotent"
else
  not_ok "exec does not treat sanitized oversized output as a new secret"
  LC_ALL=C wc -c "$OUT" | sed 's/^/  bytes: /'
fi

"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c '
  printf "\377\n"
  awk "BEGIN {
    for (i = 0; i < 5000; i++)
      print \"error: password: authentication is disabled\"
  }"
' >"$OUT" 2>/dev/null
if [ "$(grep -ac '^error: password: authentication is disabled$' "$OUT")" -eq 5000 ]; then
  ok "exec preserves oversized invalid-byte prose metadata"
else
  not_ok "exec does not over-mask oversized invalid-byte prose metadata"
  LC_ALL=C wc -c "$OUT" | sed 's/^/  bytes: /'
fi

# `printenv NAME` emits a bare value. Preserve the variable-name context so a
# low-entropy or documented fake value under a secret-bearing key is still
# masked by exec and by the Claude command wrapper.
PRINTENV_KEY='DEMO_TOKEN'
# Keep the value deliberately non-vendor-shaped: this regression proves that
# the variable name supplies the missing secret context for bare printenv output.
PRINTENV_VAL='documented-fake-printenv-value-123456'
exec_printenv=$(DEMO_TOKEN="${PRINTENV_VAL}" "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv "$PRINTENV_KEY" 2>/dev/null)
if printf '%s' "$exec_printenv" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$exec_printenv" | grep -q "$PRINTENV_VAL"; then
  ok "exec masks a bare printenv value using its variable-name context"
else
  not_ok "exec masks a bare printenv value using its variable-name context"
  printf '%s\n' "  out: $exec_printenv"
fi

# Keep the captured JSON response out of argv: quote-heavy values can remain
# below the plaintext cap while their JSON encoding exceeds Linux MAX_ARG_STRLEN.
PRINTENV_QUOTE_VAL=$(awk 'BEGIN { for (i = 0; i < 70000; i++) printf "\"" }')
PASSWORD="${PRINTENV_QUOTE_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv PASSWORD >"$OUT" 2>/dev/null
if [ "$(cat "$OUT")" = '[REDACTED]' ]; then
  ok "exec streams a quote-heavy printenv response into jq"
else
  not_ok "exec does not leak printenv output whose JSON exceeds one argv entry"
  LC_ALL=C wc -c "$OUT" | sed 's/^/  bytes: /'
fi

exec_printenv=$(DEMO_TOKEN="${PRINTENV_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv -- "$PRINTENV_KEY" 2>/dev/null)
if [ "$exec_printenv" = '[REDACTED]' ]; then
  ok "exec masks a bare printenv value after an option terminator"
else
  not_ok "exec preserves printenv variable context after an option terminator"
  printf '%s\n' "  out: $exec_printenv"
fi

PRINTENV_QUOTED_KEY='TRUNCATED_PASSWORD'
PRINTENV_QUOTED_VAL="\"${DISPLAY_QUOTED_HEAD}-${DISPLAY_QUOTED_TAIL}"
exec_printenv=$(TRUNCATED_PASSWORD="${PRINTENV_QUOTED_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv "$PRINTENV_QUOTED_KEY" 2>/dev/null)
if [ "$exec_printenv" = '[REDACTED]' ]; then
  ok "exec masks a complete unterminated quoted printenv value"
else
  not_ok "exec matches the reconstructed printenv secret to the captured output"
  printf '%s\n' "  out: $exec_printenv"
fi

PRINTENV_LEADING_VAL=$(printf '\n%s-%s' "$DISPLAY_QUOTED_HEAD" "$DISPLAY_QUOTED_TAIL")
PRINTENV_INTERNAL_VAL=$(printf '%s\n%s' "$DISPLAY_QUOTED_HEAD" "$DISPLAY_QUOTED_TAIL")
PRINTENV_TRAILING_VAL=$(printf '%s-%s\nx' "$DISPLAY_QUOTED_HEAD" "$DISPLAY_QUOTED_TAIL")
PRINTENV_TRAILING_VAL=${PRINTENV_TRAILING_VAL%x}
for PRINTENV_MULTILINE_VAL in \
  "$PRINTENV_LEADING_VAL" "$PRINTENV_INTERNAL_VAL" "$PRINTENV_TRAILING_VAL"; do
  exec_printenv=$(DEMO_TOKEN="${PRINTENV_MULTILINE_VAL}" \
    "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv DEMO_TOKEN 2>/dev/null)
  if [ "$exec_printenv" = '[REDACTED]' ]; then
    ok "exec masks a newline-bearing printenv value as one complete secret"
  else
    not_ok "exec preserves the complete newline-bearing printenv value"
    printf '%s\n' "  out: $exec_printenv"
  fi
done

PRINTENV_SECOND_KEY='SECONDARY_PASSWORD'
PRINTENV_SECOND_VAL="${DISPLAY_QUOTED_TAIL}-${DISPLAY_QUOTED_HEAD}"
printenv_raw=$(DEMO_TOKEN="${PRINTENV_VAL}" SECONDARY_PASSWORD="${PRINTENV_SECOND_VAL}" \
  printenv "$PRINTENV_KEY" AGENT_GUARD_TEST_UNSET_PASSWORD "$PRINTENV_SECOND_KEY" \
  2>/dev/null)
printenv_raw_status=$?
exec_printenv=$(DEMO_TOKEN="${PRINTENV_VAL}" SECONDARY_PASSWORD="${PRINTENV_SECOND_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- \
    printenv "$PRINTENV_KEY" AGENT_GUARD_TEST_UNSET_PASSWORD "$PRINTENV_SECOND_KEY" \
    2>/dev/null)
exec_printenv_status=$?
printenv_gnu_output=$(printf '%s\n%s' "$PRINTENV_VAL" "$PRINTENV_SECOND_VAL")
case "$printenv_raw" in
  "$PRINTENV_VAL") exec_expected='[REDACTED]' ;;
  "$printenv_gnu_output") exec_expected=$(printf '[REDACTED]\n[REDACTED]') ;;
  *) exec_expected='unexpected-printenv-output' ;;
esac
if [ "$exec_printenv" = "$exec_expected" ] \
   && [ "$exec_printenv_status" -eq "$printenv_raw_status" ]; then
  ok "exec follows host printenv argument semantics and masks every emitted value"
else
  not_ok "exec preserves host printenv argument and exit-status behavior"
  printf '%s\n' "  raw: $printenv_raw (status $printenv_raw_status)"
  printf '%s\n' "  out: $exec_printenv (status $exec_printenv_status)"
fi

printenv_fixture_dir="$TESTTMP/gnu-printenv"
mkdir -p "$printenv_fixture_dir"
cat >"$printenv_fixture_dir/printenv" <<'STUB'
#!/bin/sh
status=0
for name in "$@"; do
  "$REAL_PRINTENV" "$name" || status=1
done
exit "$status"
STUB
chmod +x "$printenv_fixture_dir/printenv"
PRINTENV_PREFIX_VAL=$(printf '%s\nx' "$DISPLAY_QUOTED_HEAD")
PRINTENV_PREFIX_VAL=${PRINTENV_PREFIX_VAL%x}
PRINTENV_PUBLIC_VAL=$DISPLAY_QUOTED_HEAD
exec_printenv=$(REAL_PRINTENV=$(command -v printenv) \
  FIRST_TOKEN="${PRINTENV_PREFIX_VAL}" PUBLIC_INFO="${PRINTENV_PUBLIC_VAL}" \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- \
    "$printenv_fixture_dir/printenv" FIRST_TOKEN PUBLIC_INFO 2>/dev/null)
exec_expected=$(printf '[REDACTED]\n%s' "$PRINTENV_PUBLIC_VAL")
if [ "$exec_printenv" = "$exec_expected" ]; then
  ok "exec does not over-mask a later benign printenv value with a stripped prefix"
else
  not_ok "exec strips trailing newlines only when the full secret was not emitted"
  printf '%s\n' "  out: $exec_printenv"
fi

exec_printenv=$(EMPTY_PASSWORD='' \
  "$PLUGIN_ROOT/bin/agent-guard" exec -- printenv EMPTY_PASSWORD 2>/dev/null)
exec_printenv_status=$?
if [ "$exec_printenv_status" -eq 0 ] && [ -z "$exec_printenv" ]; then
  ok "exec leaves an empty requested printenv value empty"
else
  not_ok "exec preserves an empty printenv value and exit status"
  printf '%s\n' "  out: $exec_printenv (status $exec_printenv_status)"
fi

# Exit-code passthrough: the wrapped command's status propagates.
"$PLUGIN_ROOT/bin/agent-guard" exec -- sh -c 'exit 7' >/dev/null 2>&1
if [ "$?" -eq 7 ]; then
  ok "exec propagates the wrapped command's exit code (7)"
else
  not_ok "exec propagates the wrapped command's exit code (7)"
fi

exec_hi=$("$PLUGIN_ROOT/bin/agent-guard" exec -- printf hi 2>/dev/null)
exec_hi_status=$?
if [ "$exec_hi_status" -eq 0 ] && [ "$exec_hi" = "hi" ]; then
  ok "exec prints clean output and exits 0"
else
  not_ok "exec prints clean output and exits 0 (out=$exec_hi status=$exec_hi_status)"
fi

# A leading `--` is stripped; with no command, usage goes to stderr and exit is 2.
"$PLUGIN_ROOT/bin/agent-guard" exec >"$OUT" 2>"$ERR"
if [ "$?" -eq 2 ] && grep -q 'Usage:' "$ERR"; then
  ok "exec with no command prints usage to stderr and exits 2"
else
  not_ok "exec with no command prints usage to stderr and exits 2"
fi

# AGENT_GUARD_OUTPUT_REDACT=off disables secret redaction (raw passthrough).
exec_off=$(AGENT_GUARD_OUTPUT_REDACT=off "$PLUGIN_ROOT/bin/agent-guard" exec -- printf '%s\n' "$EXEC_LINE" 2>/dev/null)
if printf '%s' "$exec_off" | grep -q "$EXEC_VAL" \
   && ! printf '%s' "$exec_off" | grep -q '\[REDACTED\]'; then
  ok "exec with AGENT_GUARD_OUTPUT_REDACT=off passes the secret through unmasked"
else
  not_ok "exec with AGENT_GUARD_OUTPUT_REDACT=off passes the secret through unmasked"
  printf '%s\n' "  out: $exec_off"
fi

# PII masking composes when AGENT_GUARD_PII_HOOK_MODE=mask.
exec_pii=$(AGENT_GUARD_PII_HOOK_MODE=mask "$PLUGIN_ROOT/bin/agent-guard" exec -- printf 'ssn 123-45-6789\n' 2>/dev/null)
if printf '%s' "$exec_pii" | grep -q '\[PII:SSN\]' \
   && ! printf '%s' "$exec_pii" | grep -q '123-45-6789'; then
  ok "exec masks PII when AGENT_GUARD_PII_HOOK_MODE=mask"
else
  not_ok "exec masks PII when AGENT_GUARD_PII_HOOK_MODE=mask"
  printf '%s\n' "  out: $exec_pii"
fi

# --- agent-guard shell-init (rc snippet) -------------------------------------
# The emitted snippet must define `agx` and parse cleanly in the target shell.
shellinit_bash=$("$PLUGIN_ROOT/bin/agent-guard" shell-init --bash 2>/dev/null)
if printf '%s' "$shellinit_bash" | grep -q 'agx()'; then
  ok "shell-init --bash defines the agx wrapper"
else
  not_ok "shell-init --bash defines the agx wrapper"
fi
if printf '%s\n' "$shellinit_bash" | sh -n - 2>"$ERR"; then
  ok "shell-init --bash snippet parses under sh -n"
else
  not_ok "shell-init --bash snippet parses under sh -n"
  sed 's/^/  stderr: /' "$ERR"
fi

if command -v zsh >/dev/null 2>&1; then
  if "$PLUGIN_ROOT/bin/agent-guard" shell-init --zsh 2>/dev/null | zsh -n - 2>"$ERR"; then
    ok "shell-init --zsh snippet parses under zsh -n"
  else
    not_ok "shell-init --zsh snippet parses under zsh -n"
    sed 's/^/  stderr: /' "$ERR"
  fi
else
  say "zsh not available; skipped shell-init --zsh parse test"
fi

# With no flag, shell-init emits an auto snippet that detects the shell at
# SOURCE time — it must carry BOTH hooks and still parse under sh -n.
shellinit_auto=$("$PLUGIN_ROOT/bin/agent-guard" shell-init 2>/dev/null)
if printf '%s' "$shellinit_auto" | grep -q 'ZSH_VERSION' \
   && printf '%s' "$shellinit_auto" | grep -q 'BASH_VERSION'; then
  ok "shell-init (auto) emits a source-time shell detector"
else
  not_ok "shell-init (auto) emits a source-time shell detector"
fi
if printf '%s\n' "$shellinit_auto" | sh -n - 2>"$ERR"; then
  ok "shell-init (auto) snippet parses under sh -n"
else
  not_ok "shell-init (auto) snippet parses under sh -n"
  sed 's/^/  stderr: /' "$ERR"
fi

# The bash hook must CHAIN onto a pre-existing DEBUG trap, not clobber it. The
# install is deferred to PROMPT_COMMAND, so simulate the first prompt tick by
# eval-ing PROMPT_COMMAND at top level (where the trap is actually visible).
printf '%s\n' "$shellinit_bash" > "$TESTTMP/shellinit.sh"
chain_out=$(bash -c '
  trap "true PRIOR_MARKER" DEBUG
  __agentguard_nudge() { :; }
  . "$1"
  eval "${PROMPT_COMMAND:-:}"   # first prompt: deferred installer runs, chains
  case "$(trap -p DEBUG)" in *PRIOR_MARKER*) m=kept ;; *) m=lost ;; esac
  case "$(trap -p DEBUG)" in *__agentguard_nudge*) n=chained ;; *) n=missing ;; esac
  printf "%s-%s\n" "$m" "$n"
' _ "$TESTTMP/shellinit.sh" 2>/dev/null)
if [ "$chain_out" = kept-chained ]; then
  ok "shell-init bash hook chains onto an existing DEBUG trap"
else
  not_ok "shell-init bash hook chains onto an existing DEBUG trap (got: $chain_out)"
fi
# With no pre-existing DEBUG trap, the deferred installer still installs cleanly.
fresh_out=$(bash -c '
  __agentguard_nudge() { :; }
  . "$1"
  eval "${PROMPT_COMMAND:-:}"
  case "$(trap -p DEBUG)" in *__agentguard_nudge*) printf installed ;; *) printf missing ;; esac
' _ "$TESTTMP/shellinit.sh" 2>/dev/null)
if [ "$fresh_out" = installed ]; then
  ok "shell-init bash hook installs the nudge when no DEBUG trap exists"
else
  not_ok "shell-init bash hook installs the nudge when no DEBUG trap exists (got: $fresh_out)"
fi

# --- shell-init nudge behavior (warn-only, non-blocking) ---------------------
# Source the emitted bash snippet in an isolated subshell, drop the DEBUG trap
# it installs (so it cannot fire on our explicit probe calls), then invoke the
# nudge directly. The idiom is assembled at runtime so no contiguous
# secret-loading literal sits in a command line.
nudge_idiom="print""env"
printf '%s\n' "$shellinit_bash" > "$TESTTMP/shellinit.sh"
nudge_probe() {
  np_out=$(bash -c '. "$1"; trap - DEBUG; __agentguard_nudge "$2"' _ "$TESTTMP/shellinit.sh" "$1" 2>&1 >/dev/null)
  [ -n "$np_out" ] && printf 'warn\n' || printf 'silent\n'
}

if [ "$(nudge_probe "$nudge_idiom")" = warn ]; then
  ok "shell-init nudge warns on a bare secret-loading idiom"
else
  not_ok "shell-init nudge warns on a bare secret-loading idiom"
fi
if [ "$(nudge_probe "agx $nudge_idiom")" = silent ]; then
  ok "shell-init nudge stays silent when the command is wrapped with agx"
else
  not_ok "shell-init nudge stays silent when the command is wrapped with agx"
fi
if [ "$(nudge_probe "$nudge_idiom >/dev/null 2>&1")" = silent ]; then
  ok "shell-init nudge stays silent when BOTH streams are discarded"
else
  not_ok "shell-init nudge stays silent when BOTH streams are discarded"
fi
if [ "$(nudge_probe "$nudge_idiom >/dev/null")" = warn ]; then
  ok "shell-init nudge still warns on a bare stdout-only redirect (stderr leaks)"
else
  not_ok "shell-init nudge still warns on a bare stdout-only redirect (stderr leaks)"
fi
if [ "$(nudge_probe "$nudge_idiom 2>/dev/null")" = warn ]; then
  ok "shell-init nudge still warns on a bare stderr-only redirect (stdout leaks)"
else
  not_ok "shell-init nudge still warns on a bare stderr-only redirect (stdout leaks)"
fi
if [ "$(nudge_probe "ls -la")" = silent ]; then
  ok "shell-init nudge stays silent on a benign command"
else
  not_ok "shell-init nudge stays silent on a benign command"
fi

# --- shell-init Claude command wrapping (stable, default-on overrides) --------
# The default snippet overrides cat/head/printenv inside Claude Code. A durable
# opt-out omits those functions, while both 1.x flags remain hidden compatibility
# shims so an existing managed rc keeps working during upgrade.
shellinit_wrap=$shellinit_auto
if printf '%s' "$shellinit_wrap" | grep -q '__agentguard_wrap_command'; then
  ok "shell-init enables Claude command wrapping by default"
else
  not_ok "shell-init enables Claude command wrapping by default"
fi
shellinit_no_wrap=$("$PLUGIN_ROOT/bin/agent-guard" shell-init --no-command-wrapping 2>/dev/null)
if printf '%s' "$shellinit_no_wrap" | grep -q '__agentguard_wrap_command'; then
  not_ok "shell-init --no-command-wrapping omits automatic command overrides"
else
  ok "shell-init --no-command-wrapping omits automatic command overrides"
fi
shellinit_v1_stable=$("$PLUGIN_ROOT/bin/agent-guard" shell-init --claude-bang-guard 2>/dev/null)
shellinit_v1_experimental=$("$PLUGIN_ROOT/bin/agent-guard" shell-init --experimental-bang-guard 2>/dev/null)
if printf '%s' "$shellinit_v1_stable" | grep -q '__agentguard_wrap_command' \
   && printf '%s' "$shellinit_v1_experimental" | grep -q '__agentguard_wrap_command'; then
  ok "shell-init keeps hidden compatibility for 1.x command-wrapper flags"
else
  not_ok "shell-init keeps hidden compatibility for 1.x command-wrapper flags"
fi
shellinit_help=$("$PLUGIN_ROOT/bin/agent-guard" shell-init --help 2>&1)
if printf '%s' "$shellinit_help" | grep -q -- '--no-command-wrapping' \
   && ! printf '%s' "$shellinit_help" | grep -q -- '--claude-bang-guard' \
   && ! printf '%s' "$shellinit_help" | grep -q -- '--experimental-bang-guard'; then
  ok "shell-init help exposes only the 2.x command-wrapping option"
else
  not_ok "shell-init help exposes only the 2.x command-wrapping option"
fi
if printf '%s\n' "$shellinit_wrap" | sh -n - 2>"$ERR"; then
  ok "command-wrapping snippet parses under sh -n"
else
  not_ok "command-wrapping snippet parses under sh -n"; sed 's/^/  stderr: /' "$ERR"
fi
if command -v zsh >/dev/null 2>&1; then
  if printf '%s\n' "$shellinit_wrap" | zsh -n - 2>"$ERR"; then
    ok "command-wrapping snippet parses under zsh -n"
  else
    not_ok "command-wrapping snippet parses under zsh -n"; sed 's/^/  stderr: /' "$ERR"
  fi
fi

# Behavioral routing: use a PATH stub `agent-guard` that only echoes a marker, so
# the test asserts the gating decision (route vs. passthrough) without depending
# on the real masker (covered by the exec tests above).
bg_dir="$TESTTMP/bangguard"
mkdir -p "$bg_dir/bin"
cat >"$bg_dir/bin/agent-guard" <<'STUB'
#!/bin/sh
[ "$1" = exec ] && { printf 'ROUTED\n'; exit 0; }
exit 0
STUB
chmod +x "$bg_dir/bin/agent-guard"
printf 'hello-plain\n' >"$bg_dir/file.txt"
printf '%s\n' "$shellinit_wrap" >"$bg_dir/guard.sh"
bg_in_cc=$(PATH="$bg_dir/bin:$PATH" CLAUDECODE=1 AGENT_GUARD_BIN="$bg_dir/bin/agent-guard" \
  sh -c '. "$1"; cat "$2"' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
if [ "$bg_in_cc" = ROUTED ]; then
  ok "command wrapping routes dump commands through agent-guard exec inside Claude Code"
else
  not_ok "command wrapping routes through exec inside Claude Code (got: $bg_in_cc)"
fi
bg_out_cc=$(PATH="$bg_dir/bin:$PATH" sh -c 'unset CLAUDECODE; . "$1"; cat "$2"' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
if [ "$bg_out_cc" = hello-plain ]; then
  ok "command wrapping is inert (passthrough) outside Claude Code"
else
  not_ok "command-wrapping passthrough outside Claude Code (got: $bg_out_cc)"
fi
bg_disabled=$(PATH="$bg_dir/bin:$PATH" CLAUDECODE=1 AGENT_GUARD_COMMAND_WRAPPING=off \
  sh -c '. "$1"; cat "$2"' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
if [ "$bg_disabled" = hello-plain ]; then
  ok "AGENT_GUARD_COMMAND_WRAPPING=off disables wrapping at runtime"
else
  not_ok "runtime command-wrapping opt-out (got: $bg_disabled)"
fi

bg_printenv=$(DEMO_TOKEN="${PRINTENV_VAL}" AGENT_GUARD_BIN="$PLUGIN_ROOT/bin/agent-guard" \
  CLAUDECODE=1 sh -c '. "$1"; printenv DEMO_TOKEN' _ "$bg_dir/guard.sh" 2>/dev/null)
if printf '%s' "$bg_printenv" | grep -q '\[REDACTED\]' \
   && ! printf '%s' "$bg_printenv" | grep -q "$PRINTENV_VAL"; then
  ok "Claude command wrapping masks a bare printenv value"
else
  not_ok "Claude command wrapping masks a bare printenv value"
  printf '%s\n' "  out: $bg_printenv"
fi

AGENT_GUARD_BIN="$PLUGIN_ROOT/bin/agent-guard" \
AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks \
CLAUDECODE=1 sh -c '. "$1"; cat "$2"' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$OUT")" = hello-plain ] \
   && grep -q 'dependencies are not ready' "$ERR"; then
  ok "transparent command wrapping fails open with a loud warning when masking is unavailable"
else
  not_ok "transparent command wrapping degraded mode preserves command behavior with a warning (status $status)"
  sed 's/^/  stdout: /' "$OUT"
  sed 's/^/  stderr: /' "$ERR"
fi
# Regression: preserve a pre-existing alias in the normal shell, while keeping
# the wrapper function underneath it for Claude Code's `unalias -a` snapshot.
# Only reproducible in shells that expand aliases.
for bg_sh in bash zsh; do
  command -v "$bg_sh" >/dev/null 2>&1 || continue
  bg_alias_normal=$(PATH="$bg_dir/bin:$PATH" "$bg_sh" -c '
    [ -n "$BASH_VERSION" ] && shopt -s expand_aliases
    alias cat="printf ALIASED"
    . "$1"
    eval "cat \"\$2\""
  ' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
  if [ "$bg_alias_normal" = ALIASED ]; then
    ok "command wrapping preserves a pre-existing cat alias under $bg_sh"
  else
    not_ok "command wrapping preserves a pre-existing cat alias under $bg_sh (got: $bg_alias_normal)"
  fi
  bg_alias_snapshot=$(PATH="$bg_dir/bin:$PATH" CLAUDECODE=1 \
    AGENT_GUARD_BIN="$bg_dir/bin/agent-guard" "$bg_sh" -c '
    [ -n "$BASH_VERSION" ] && shopt -s expand_aliases
    alias cat="printf ALIASED"
    . "$1"
    unalias -a
    cat "$2"
  ' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
  if [ "$bg_alias_snapshot" = ROUTED ]; then
    ok "command wrapping survives Claude alias cleanup under $bg_sh"
  else
    not_ok "command wrapping after Claude alias cleanup under $bg_sh (got: $bg_alias_snapshot)"
  fi
done

# --- CLI-less operation: baked path + resolver (no agent-guard on $PATH) ------
# A plugin-only install never symlinks agent-guard onto $PATH, so the wrappers
# must resolve it via the absolute path baked into the snippet. These tests strip
# $PATH down to a minimal set (no agent-guard) to prove that fallback.
if printf '%s' "$shellinit_wrap" | grep -q '^__agentguard_bin='; then
  ok "shell-init bakes the absolute binary path (__agentguard_bin)"
else
  not_ok "shell-init bakes the absolute binary path (__agentguard_bin)"
fi
if printf '%s' "$shellinit_wrap" | grep -q '__agentguard_exe()'; then
  ok "shell-init emits the __agentguard_exe resolver"
else
  not_ok "shell-init emits the __agentguard_exe resolver"
fi

# Route via the BAKED path when agent-guard is not on $PATH: point the baked line
# at the stub and drop $PATH so `command -v agent-guard` cannot find anything.
bg_baked="$bg_dir/guard-baked.sh"
sed "s#^__agentguard_bin=.*#__agentguard_bin='$bg_dir/bin/agent-guard'#" "$bg_dir/guard.sh" >"$bg_baked"
bg_nopath=$(PATH=/usr/bin:/bin CLAUDECODE=1 sh -c '. "$1"; cat "$2"' _ "$bg_baked" "$bg_dir/file.txt" 2>/dev/null)
if [ "$bg_nopath" = ROUTED ]; then
  ok "command wrapping routes via the baked path when agent-guard is off \$PATH"
else
  not_ok "command wrapping routes via baked path off \$PATH (got: $bg_nopath)"
fi

# $AGENT_GUARD_BIN wins over both $PATH and the baked path.
cat >"$bg_dir/bin/ag-override" <<'STUB'
#!/bin/sh
[ "$1" = exec ] && { printf 'ENVROUTED\n'; exit 0; }
exit 0
STUB
chmod +x "$bg_dir/bin/ag-override"
bg_env=$(PATH="$bg_dir/bin:$PATH" CLAUDECODE=1 AGENT_GUARD_BIN="$bg_dir/bin/ag-override" \
  sh -c '. "$1"; cat "$2"' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
if [ "$bg_env" = ENVROUTED ]; then
  ok "\$AGENT_GUARD_BIN takes priority in the resolver"
else
  not_ok "\$AGENT_GUARD_BIN priority in the resolver (got: $bg_env)"
fi

# When NO binary resolves (stale baked path, nothing on $PATH), the TRANSPARENT
# command wrapping follows the shared infrastructure policy. Default open runs
# the command, and the warning is emitted only once in the shell session.
bg_none="$bg_dir/guard-none.sh"
sed -e "s#^__agentguard_bin=.*#__agentguard_bin='/nonexistent/agent-guard'#" \
    -e "s#^__agentguard_plugin_base=.*#__agentguard_plugin_base='/nonexistent/plugin-cache'#" \
    "$bg_dir/guard.sh" >"$bg_none"
bg_open=$(PATH=/usr/bin:/bin CLAUDECODE=1 sh -c '. "$1"; cat "$2"; cat "$2"' _ "$bg_none" "$bg_dir/file.txt" 2>"$ERR")
if [ "$bg_open" = "hello-plain
hello-plain" ]; then
  ok "command wrapping fails OPEN (runs the command) when no binary resolves"
else
  not_ok "command wrapping fail-open passthrough when no binary resolves (got: $bg_open)"
fi
if [ "$(grep -c 'NOT masked' "$ERR")" -eq 1 ]; then
  ok "command wrapping warns only once per shell session when it cannot mask"
else
  not_ok "command wrapping warns only once per shell session when it cannot mask"
  sed 's/^/  stderr: /' "$ERR"
fi

# agx uses the same default-open policy as transparent command wrapping.
agx_out=$(PATH=/usr/bin:/bin sh -c '. "$1"; agx cat "$2"' _ "$bg_none" "$bg_dir/file.txt" 2>/dev/null)
case "$agx_out" in
  hello-plain) ok "agx follows the default open policy when no binary resolves" ;;
  *)           not_ok "agx follows the default open policy when no binary resolves (got: $agx_out)" ;;
esac

agx_closed=$(PATH=/usr/bin:/bin AGENT_GUARD_INFRA_FAILURE_MODE=closed \
  sh -c '. "$1"; agx cat "$2"; printf "rc=%s" "$?"' _ "$bg_none" "$bg_dir/file.txt" 2>/dev/null)
case "$agx_closed" in
  *hello-plain*) not_ok "agx closed policy does not run the unmasked command (leaked: $agx_closed)" ;;
  *rc=127*)      ok "agx closed policy refuses to run when no binary resolves" ;;
  *)             not_ok "agx closed policy return code (got: $agx_closed)" ;;
esac

wrap_closed=$(PATH=/usr/bin:/bin CLAUDECODE=1 AGENT_GUARD_INFRA_FAILURE_MODE=closed \
  sh -c '. "$1"; cat "$2"; printf "rc=%s" "$?"' _ "$bg_none" "$bg_dir/file.txt" 2>/dev/null)
case "$wrap_closed" in
  *hello-plain*) not_ok "transparent wrapping closed policy does not run unmasked output (leaked: $wrap_closed)" ;;
  *rc=127*)      ok "transparent wrapping supports the opt-in closed infrastructure policy" ;;
  *)             not_ok "transparent wrapping closed policy return code (got: $wrap_closed)" ;;
esac

# --- hook-session-start: drift warning driven by the shell-init marker --------
# The hook no longer re-derives the CLI: it compares the plugin's own VERSION
# against $AGENT_GUARD_SHELL_INIT_VERSION, which the shell-init snippet exports
# at rc-eval time (ground truth for whatever binary actually masks). These tests
# drive the hook purely by that env var; the plugin binary is invoked by
# absolute path with a minimal PATH so nothing else leaks in.
AG_VERSION=$(sed -n 's/^VERSION=//p' "$PLUGIN_ROOT/bin/agent-guard" | head -n1)

run_session_start() {  # $1 = value for the marker env ('' => marker unset)
  sh -c 'unset AGENT_GUARD_SHELL_INIT_VERSION
         [ -n "$1" ] && export AGENT_GUARD_SHELL_INIT_VERSION="$1"
         AGENT_GUARD_GITLEAKS_BIN="$3" PATH="$4" exec "$2" hook-session-start' \
    _ "$1" "$PLUGIN_ROOT/bin/agent-guard" "$MOCK_BIN/gitleaks" "$MOCK_BIN:$ORIGINAL_PATH"
}

vd_out=$(run_session_start 0.0.1 2>"$ERR")
vd_status=$?
if [ "$vd_status" -eq 0 ] && printf '%s' "$vd_out" | jq -e '.systemMessage' >/dev/null 2>&1; then
  ok "hook-session-start emits a systemMessage JSON warning on marker mismatch"
else
  not_ok "hook-session-start systemMessage on mismatch (status $vd_status, got: $vd_out)"
fi
case "$vd_out" in
  *"$AG_VERSION"*0.0.1*) ok "drift warning names both the plugin and the masking version" ;;
  *) not_ok "drift warning names both versions (got: $vd_out)" ;;
esac

vd_out=$(run_session_start "$AG_VERSION" 2>"$ERR")
if [ $? -eq 0 ] && [ -z "$vd_out" ]; then
  ok "hook-session-start is silent when the marker matches the plugin version"
else
  not_ok "hook-session-start silent on marker match (got: $vd_out)"
fi

vd_out=$(run_session_start "" 2>"$ERR")
if [ $? -eq 0 ] \
   && printf '%s' "$vd_out" | jq -e '.systemMessage | contains("/agent-guard:setup-shell")' >/dev/null 2>&1; then
  ok "Claude SessionStart guides default command-wrapping setup when the marker is absent"
else
  not_ok "Claude SessionStart guides command-wrapping setup with no marker (got: $vd_out)"
fi

vd_out=$(AGENT_GUARD_HOOK_HOST=codex AGENT_GUARD_GITLEAKS_BIN="$MOCK_BIN/gitleaks" \
  PATH="$MOCK_BIN:$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>"$ERR")
if [ $? -eq 0 ] && [ -z "$vd_out" ]; then
  ok "Codex SessionStart does not request Claude command-wrapping setup"
else
  not_ok "Codex SessionStart stays scoped to Codex setup (got: $vd_out)"
fi

vd_out=$(AGENT_GUARD_HOOK_HOST=codex AGENT_GUARD_SHELL_INIT_VERSION=0.0.1 \
  AGENT_GUARD_GITLEAKS_BIN="$MOCK_BIN/gitleaks" PATH="$MOCK_BIN:$ORIGINAL_PATH" \
  "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>"$ERR")
if [ $? -eq 0 ] && [ -z "$vd_out" ]; then
  ok "Codex SessionStart ignores Claude shell-integration version drift"
else
  not_ok "Codex SessionStart ignores Claude shell-integration drift (got: $vd_out)"
fi

vd_out=$(run_session_start 'not a version' 2>"$ERR")
if [ $? -eq 0 ] && [ -z "$vd_out" ]; then
  ok "hook-session-start is silent when the marker cannot be parsed"
else
  not_ok "hook-session-start silent on unparseable marker (got: $vd_out)"
fi

vd_out=$(AGENT_GUARD_HOOK_HOST=codex AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks \
  PATH="$NO_GITLEAKS_BIN" "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>"$ERR")
if [ $? -eq 0 ] \
   && printf '%s' "$vd_out" | jq -e \
        --arg expected "$codex_setup_ref" \
        --arg unexpected "$claude_setup_ref" \
        '.systemMessage | contains($expected) and (contains($unexpected) | not)' \
        >/dev/null 2>&1; then
  ok "Codex SessionStart uses Codex dependency setup guidance"
else
  not_ok "Codex SessionStart emits host-appropriate degraded guidance (got: $vd_out)"
fi

vd_out=$(AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks \
  PATH="$NO_GITLEAKS_BIN" "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>"$ERR")
if [ $? -eq 0 ] \
   && printf '%s' "$vd_out" | jq -e \
        --arg expected "$claude_setup_ref" \
        --arg unexpected "$codex_setup_ref" \
        '.systemMessage | contains($expected) and (contains($unexpected) | not)' \
        >/dev/null 2>&1; then
  ok "Claude SessionStart uses Claude dependency setup guidance"
else
  not_ok "Claude SessionStart emits host-appropriate degraded guidance (got: $vd_out)"
fi

# --- shell-init exports the resolved binary's version as the marker -----------
# The snippet must export AGENT_GUARD_SHELL_INIT_VERSION = the VERSION of the
# binary __agentguard_exe actually resolves, across all three paths. Stubs whose
# `version` subcommand prints a known string stand in for the resolved binary;
# sourcing the snippet must set the marker to that string.
shellinit_plain=$("$PLUGIN_ROOT/bin/agent-guard" shell-init 2>/dev/null)
if printf '%s' "$shellinit_plain" | grep -q 'AGENT_GUARD_SHELL_INIT_VERSION'; then
  ok "shell-init snippet exports the AGENT_GUARD_SHELL_INIT_VERSION marker"
else
  not_ok "shell-init snippet exports the marker"
fi
if printf '%s\n' "$shellinit_plain" | sh -n - 2>"$ERR"; then
  ok "shell-init (marker) snippet parses under sh -n"
else
  not_ok "shell-init (marker) snippet parses under sh -n"; sed 's/^/  stderr: /' "$ERR"
fi

mk_dir="$TESTTMP/marker"
mkdir -p "$mk_dir/bin"
# Two version stubs: the one $PATH/baked resolution finds, and the one only
# $AGENT_GUARD_BIN points at (distinct version proves precedence).
printf '#!/bin/sh\n[ "$1" = version ] && { printf "agent-guard 9.9.9\\n"; exit 0; }\nexit 0\n' >"$mk_dir/bin/agent-guard"
printf '#!/bin/sh\n[ "$1" = version ] && { printf "agent-guard 7.7.7\\n"; exit 0; }\nexit 0\n' >"$mk_dir/bin/ag-env"
chmod +x "$mk_dir/bin/agent-guard" "$mk_dir/bin/ag-env"
printf '%s\n' "$shellinit_plain" >"$mk_dir/guard.sh"
# Source a snippet in a clean external shell and echo the resulting marker (or
# UNSET). PATH and AGENT_GUARD_BIN are passed as args and set INSIDE the `sh -c`
# (an external command, so the assignments cannot leak into this test process) —
# the single point of variation between the resolution-path cases below.
source_marker() {  # $1 = snippet file  $2 = PATH  $3 = AGENT_GUARD_BIN ('' => unset)
  sh -c 'unset AGENT_GUARD_SHELL_INIT_VERSION
         PATH=$2
         if [ -n "$3" ]; then AGENT_GUARD_BIN=$3; export AGENT_GUARD_BIN; else unset AGENT_GUARD_BIN; fi
         . "$1"; printf %s "${AGENT_GUARD_SHELL_INIT_VERSION:-UNSET}"' _ "$1" "$2" "$3" 2>/dev/null
}

# (a) resolved via $PATH when no stable/plugin binary is available
mk_path_guard="$mk_dir/guard-path.sh"
sed "s#^__agentguard_bin=.*#__agentguard_bin='/nonexistent/agent-guard'#" "$mk_dir/guard.sh" >"$mk_path_guard"
mk_path=$(source_marker "$mk_path_guard" "$mk_dir/bin:/usr/bin:/bin" "")
if [ "$mk_path" = 9.9.9 ]; then
  ok "shell-init marker reflects the version resolved via \$PATH"
else
  not_ok "shell-init marker via \$PATH (got: $mk_path)"
fi

# (b) resolved via the BAKED path when agent-guard is off $PATH (plugin-only)
mk_baked="$mk_dir/guard-baked.sh"
sed "s#^__agentguard_bin=.*#__agentguard_bin='$mk_dir/bin/agent-guard'#" "$mk_dir/guard.sh" >"$mk_baked"
mk_bakedver=$(source_marker "$mk_baked" "/usr/bin:/bin" "")
if [ "$mk_bakedver" = 9.9.9 ]; then
  ok "shell-init marker reflects the version resolved via the baked path (plugin-only)"
else
  not_ok "shell-init marker via baked path (got: $mk_bakedver)"
fi

# (c) $AGENT_GUARD_BIN outranks both $PATH and the baked path
mk_env=$(source_marker "$mk_dir/guard.sh" "$mk_dir/bin:/usr/bin:/bin" "$mk_dir/bin/ag-env")
if [ "$mk_env" = 7.7.7 ]; then
  ok "shell-init marker honors \$AGENT_GUARD_BIN over \$PATH and the baked path"
else
  not_ok "shell-init marker \$AGENT_GUARD_BIN precedence (got: $mk_env)"
fi

# (d) no binary resolves anywhere => marker stays unset (hook then silent)
mk_none="$mk_dir/guard-none.sh"
sed "s#^__agentguard_bin=.*#__agentguard_bin='/nonexistent/agent-guard'#" "$mk_dir/guard.sh" >"$mk_none"
mk_unset=$(source_marker "$mk_none" "/usr/bin:/bin" "")
if [ "$mk_unset" = UNSET ]; then
  ok "shell-init leaves the marker unset when no binary resolves"
else
  not_ok "shell-init marker unset when nothing resolves (got: $mk_unset)"
fi

# (e) a STALE inherited marker is cleared when this shell's resolution fails, so
# each rc-eval is authoritative ("present iff loaded", not inherited from parent)
mk_reset=$(sh -c 'export AGENT_GUARD_SHELL_INIT_VERSION=1.2.3
  PATH=/usr/bin:/bin; unset AGENT_GUARD_BIN
  . "$1"; printf %s "${AGENT_GUARD_SHELL_INIT_VERSION:-UNSET}"' _ "$mk_none" 2>/dev/null)
if [ "$mk_reset" = UNSET ]; then
  ok "shell-init clears a stale inherited marker when nothing resolves"
else
  not_ok "shell-init clears stale inherited marker on resolution failure (got: $mk_reset)"
fi

# --- setup-shell: write the shell-init line into an rc, idempotently ----------
ss_rc="$TESTTMP/setup.rc"
ss_output=$("$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_rc" 2>&1)
if grep -q '>>> agent-guard shell-init >>>' "$ss_rc" 2>/dev/null; then
  ok "setup-shell writes a managed shell-init block into the rc"
else
  not_ok "setup-shell writes a managed shell-init block into the rc"
fi
if printf '%s' "$ss_output" | grep -Eq 'Claude Code|Codex'; then
  not_ok "setup-shell output stays host-neutral"
else
  ok "setup-shell output stays host-neutral"
fi
"$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_rc" >/dev/null 2>&1
ss_markers=$(grep -c '>>> agent-guard shell-init >>>' "$ss_rc" 2>/dev/null)
if [ "$ss_markers" = 1 ]; then
  ok "setup-shell is idempotent (one managed block after two runs)"
else
  not_ok "setup-shell idempotent (begin-marker count: $ss_markers)"
fi
printf 'export AG_TEST_KEEP=1\n' >>"$ss_rc"
"$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_rc" >/dev/null 2>&1
if grep -q 'export AG_TEST_KEEP=1' "$ss_rc" 2>/dev/null; then
  ok "setup-shell preserves unrelated rc lines"
else
  not_ok "setup-shell preserves unrelated rc lines"
fi
if grep -q 'agent-guard shell-init' "$ss_rc" 2>/dev/null \
   && ! grep -q -- '--no-command-wrapping' "$ss_rc" 2>/dev/null; then
  ok "setup-shell enables command wrapping by default"
else
  not_ok "setup-shell enables command wrapping by default"
fi
ss_off="$TESTTMP/setup-off.rc"
"$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_off" --no-command-wrapping >/dev/null 2>&1
if grep -q 'shell-init --no-command-wrapping' "$ss_off" 2>/dev/null; then
  ok "setup-shell persists the command-wrapping opt-out"
else
  not_ok "setup-shell persists the command-wrapping opt-out"
fi
for ss_v1_flag in --claude-bang-guard --experimental-bang-guard; do
  ss_v1="$TESTTMP/setup-v1-${ss_v1_flag#--}.rc"
  "$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_v1" "$ss_v1_flag" >/dev/null 2>&1
  if ! grep -q -- '--claude-bang-guard' "$ss_v1" 2>/dev/null \
     && ! grep -q -- '--experimental-bang-guard' "$ss_v1" 2>/dev/null \
     && ! grep -q -- '--no-command-wrapping' "$ss_v1" 2>/dev/null; then
    ok "setup-shell normalizes the 1.x flag $ss_v1_flag to the 2.x default"
  else
    not_ok "setup-shell normalizes the 1.x flag $ss_v1_flag to the 2.x default"
  fi
done
setup_shell_help=$("$PLUGIN_ROOT/bin/agent-guard" setup-shell --help 2>&1)
if printf '%s' "$setup_shell_help" | grep -q -- '--no-command-wrapping' \
   && ! printf '%s' "$setup_shell_help" | grep -q -- '--claude-bang-guard' \
   && ! printf '%s' "$setup_shell_help" | grep -q -- '--experimental-bang-guard' \
   && ! printf '%s' "$setup_shell_help" | grep -Eq 'Claude Code|Codex'; then
  ok "setup-shell help exposes only the 2.x command-wrapping option"
else
  not_ok "setup-shell help exposes only the 2.x command-wrapping option"
fi
# Self-healing invocation: the rc line prefers the stable absolute path and
# keeps an output-checked PATH fallback for standalone installs.
ss_heal="$TESTTMP/setup-heal.rc"
"$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_heal" >/dev/null 2>&1
if grep -q '_agbin=' "$ss_heal" 2>/dev/null \
   && grep -Fq '_agi=$("$_agbin" shell-init' "$ss_heal" 2>/dev/null \
   && grep -q 'command -v agent-guard' "$ss_heal" 2>/dev/null; then
  ok "setup-shell bakes the stable invocation with resolver fallbacks"
else
  not_ok "setup-shell bakes the stable invocation with resolver fallbacks"
fi
# Regression for the exact leak found in live testing: with agent-guard NOT on
# $PATH, a bare-name invocation would fail command-not-found and install NOTHING.
# The baked absolute fallback must still generate the snippet, so `agx` gets defined.
heal=$(PATH=/usr/bin:/bin sh -c '. "$1"; command -v agx >/dev/null 2>&1 && echo INSTALLED || echo MISSING' _ "$ss_heal" 2>/dev/null)
if [ "$heal" = INSTALLED ]; then
  ok "setup-shell rc line installs the guard even with agent-guard off \$PATH"
else
  not_ok "setup-shell rc line installs the guard off \$PATH (got: $heal)"
fi
# Regression for CodeRabbit's P2: a STALE/STUB `agent-guard` earlier on $PATH whose
# `shell-init` emits nothing (or errors) must NOT shadow the baked fallback. The
# output probe falls back to $SELF_BIN, so `agx` still gets defined rather than the
# guard silently vanishing.
heal_stub_dir="$TESTTMP/heal-stub-bin"
mkdir -p "$heal_stub_dir"
cat >"$heal_stub_dir/agent-guard" <<'STUB'
#!/bin/sh
# Older/stub build: does not know shell-init, emits nothing and exits nonzero.
exit 3
STUB
chmod +x "$heal_stub_dir/agent-guard"
heal_stub=$(PATH="$heal_stub_dir:/usr/bin:/bin" sh -c '. "$1"; command -v agx >/dev/null 2>&1 && echo INSTALLED || echo MISSING' _ "$ss_heal" 2>/dev/null)
if [ "$heal_stub" = INSTALLED ]; then
  ok "setup-shell rc line falls back to the baked path when a stub agent-guard shadows \$PATH"
else
  not_ok "setup-shell rc line falls back past a stub agent-guard (got: $heal_stub)"
fi
if "$PLUGIN_ROOT/bin/agent-guard" setup-shell --bogus >/dev/null 2>&1; then
  not_ok "setup-shell rejects an unknown option"
else
  ok "setup-shell rejects an unknown option"
fi
# An unbalanced managed block (begin marker, no matching end) must make
# setup-shell REFUSE and leave the rc untouched — never silently drop the
# user content that follows the orphaned marker.
ss_bad="$TESTTMP/setup-bad.rc"
{
  printf '%s\n' 'export AG_BEFORE=1'
  printf '%s\n' '# >>> agent-guard shell-init >>>'
  printf '%s\n' 'export AG_ORPHAN_KEEP=1'
} >"$ss_bad"
ss_bad_before=$(cat "$ss_bad")
if "$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_bad" >/dev/null 2>&1; then
  not_ok "setup-shell refuses an rc with an unbalanced managed-block marker"
else
  ok "setup-shell refuses an rc with an unbalanced managed-block marker"
fi
if [ "$(cat "$ss_bad")" = "$ss_bad_before" ]; then
  ok "setup-shell leaves the rc untouched when it refuses"
else
  not_ok "setup-shell leaves the rc untouched when it refuses"
fi
# A symlinked rc is written THROUGH to its target (dotfiles workflow): the link
# stays a link and the real file gets the managed block + keeps its content.
if ln -s "$TESTTMP/real-rc" "$TESTTMP/link-rc" 2>/dev/null; then
  printf 'export AG_DOTFILES=1\n' >"$TESTTMP/real-rc"
  "$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$TESTTMP/link-rc" >/dev/null 2>&1
  if [ -L "$TESTTMP/link-rc" ] && grep -q '>>> agent-guard shell-init >>>' "$TESTTMP/real-rc" 2>/dev/null; then
    ok "setup-shell writes through a symlinked rc (link preserved, target updated)"
  else
    not_ok "setup-shell writes through a symlinked rc (link preserved, target updated)"
  fi
  if grep -q 'export AG_DOTFILES=1' "$TESTTMP/real-rc" 2>/dev/null; then
    ok "setup-shell preserves target content when writing through a symlink"
  else
    not_ok "setup-shell preserves target content when writing through a symlink"
  fi
else
  say "symlinks not supported here; skipped setup-shell symlink test"
fi

# --- clean-home plugin install -> upgrade -> existing stable PATH -----------
# Model the host cache layout without touching the real HOME. The first plugin
# execution creates `current`, setup-shell writes only that stable path, and an
# upgrade retargets it before the old version directory disappears.
CLEAN_HOME="$TESTTMP/clean-home"
CLEAN_CACHE="$CLEAN_HOME/.claude/plugins/cache/agent-guard/agent-guard"
CLEAN_RC="$CLEAN_HOME/.zshrc"
mkdir -p "$CLEAN_CACHE/3.0.0/bin"
CLEAN_CACHE=$(CDPATH= cd -- "$CLEAN_CACHE" && pwd -P)
cp "$PLUGIN_ROOT/bin/agent-guard" "$CLEAN_CACHE/3.0.0/bin/agent-guard"
chmod +x "$CLEAN_CACHE/3.0.0/bin/agent-guard"
HOME="$CLEAN_HOME" "$CLEAN_CACHE/3.0.0/bin/agent-guard" version >/dev/null 2>&1
HOME="$CLEAN_HOME" "$CLEAN_CACHE/3.0.0/bin/agent-guard" setup-shell --rc "$CLEAN_RC" >/dev/null 2>&1
if [ "$(readlink "$CLEAN_CACHE/current" 2>/dev/null)" = 3.0.0 ]; then
  ok "fresh plugin execution creates the stable current symlink"
else
  not_ok "fresh plugin execution creates the stable current symlink"
fi
if grep -Fq "$CLEAN_CACHE/current/bin/agent-guard" "$CLEAN_RC" \
   && ! grep -Fq "$CLEAN_CACHE/3.0.0/bin/agent-guard" "$CLEAN_RC"; then
  ok "setup-shell records only the stable plugin path"
else
  not_ok "setup-shell records only the stable plugin path"
fi

mkdir -p "$CLEAN_CACHE/3.0.1/bin"
cp "$PLUGIN_ROOT/bin/agent-guard" "$CLEAN_CACHE/3.0.1/bin/agent-guard"
chmod +x "$CLEAN_CACHE/3.0.1/bin/agent-guard"
HOME="$CLEAN_HOME" "$CLEAN_CACHE/3.0.1/bin/agent-guard" version >/dev/null 2>&1
rm -rf "$CLEAN_CACHE/3.0.0"
if [ "$(readlink "$CLEAN_CACHE/current" 2>/dev/null)" = 3.0.1 \
   ] && PATH="$CLEAN_CACHE/current/bin:/usr/bin:/bin" command -v agent-guard >/dev/null 2>&1; then
  ok "upgrade retargets the stable PATH before the old version is removed"
else
  not_ok "upgrade retargets the stable PATH before the old version is removed"
fi
clean_snapshot_bin=$(HOME="$CLEAN_HOME" PATH=/usr/bin:/bin sh -c '. "$1"; __agentguard_exe' _ "$CLEAN_RC" 2>/dev/null)
if [ "$clean_snapshot_bin" = "$CLEAN_CACHE/current/bin/agent-guard" ]; then
  ok "pre-upgrade shell integration resolves through current after upgrade"
else
  not_ok "pre-upgrade shell integration resolves through current after upgrade (got: $clean_snapshot_bin)"
fi
clean_path_bin=$(HOME="$CLEAN_HOME" PATH=/usr/bin:/bin sh -c '. "$1"; command -v agent-guard' _ "$CLEAN_RC" 2>/dev/null)
if [ "$clean_path_bin" = "$CLEAN_CACHE/current/bin/agent-guard" ]; then
  ok "setup-shell makes the stable binary discoverable without manual PATH injection"
else
  not_ok "setup-shell adds current/bin to PATH (got: $clean_path_bin)"
fi

# A stale version may still be executing in an old session after a newer plugin
# is installed. It must not roll `current` backward, and non-numeric lookalike
# directories must never win the resolver sort.
mkdir -p "$CLEAN_CACHE/3.0.0/bin" "$CLEAN_CACHE/3.0.2/bin" "$CLEAN_CACHE/9.9.9beta/bin"
for clean_version in 3.0.0 3.0.2 9.9.9beta; do
  cp "$PLUGIN_ROOT/bin/agent-guard" "$CLEAN_CACHE/$clean_version/bin/agent-guard"
  chmod +x "$CLEAN_CACHE/$clean_version/bin/agent-guard"
done
HOME="$CLEAN_HOME" "$CLEAN_CACHE/3.0.0/bin/agent-guard" version >/dev/null 2>&1
if [ "$(readlink "$CLEAN_CACHE/current" 2>/dev/null)" = 3.0.2 ]; then
  ok "stale binaries keep current on the highest strictly numeric installed version"
else
  not_ok "stale binary does not roll current backward (got: $(readlink "$CLEAN_CACHE/current" 2>/dev/null))"
fi

# --- temp cleanup on abrupt termination (#131) -----------------------------
# PRIVACY.md promises scan temp files are removed when the operation exits.
# The realistic un-clean exits are catchable signals: SIGTERM when the host
# kills the PostToolUse/Stop hook at its timeout, SIGINT on Ctrl-C (delivered to
# the whole foreground process group). Prove a temp file whose owning scan is
# interrupted mid-run is still removed on exit by the centralized trap, rather
# than leaking because the per-return `rm -f` never got to run. SIGKILL is
# un-trappable and intentionally NOT covered.
#
# Note: the scan runs `... | run_gitleaks_stdin`, so the temp file is created and
# normally removed inside a *pipeline subshell*. To reproduce the leak we kill
# the main process AND that scan subshell while it is still blocked waiting on
# the slow gitleaks — matching a host that kills the hook's process tree / a
# group-delivered SIGINT. We deliberately do NOT signal the gitleaks child: that
# would let the subshell's wait return and run its own `rm -f`, masking the leak.
SIGTMP=$(mktemp -d "${TMPDIR:-/tmp}/ag-sigtest.XXXXXX")
SIG_READY="$SIGTMP/ready"
SIG_RUN="$SIGTMP/run"
mkdir -p "$SIG_RUN"
SIG_GL="$SIGTMP/gitleaks"
# Slow gitleaks: on the stdin scan (reached only AFTER agent-guard has created
# its temp file) signal readiness, then block so the tree is guaranteed alive
# and mid-scan when we kill it.
cat >"$SIG_GL" <<EOSH
#!/usr/bin/env sh
case "\${1:-}" in
  stdin) : >"$SIG_READY"; sleep 3; exit 0 ;;
  *) exit 0 ;;
esac
EOSH
chmod +x "$SIG_GL"

# Fresh TMPDIR (SIG_RUN, a neutrally-named dir so the -maxdepth 1 root never
# matches the glob) so the only agent-guard* artifacts found are this
# invocation's. The glob matches both the old flat name (agent-guard.XXXXXX) and
# the new rundir (agent-guard-run.XXXXXX), keeping the assertion version-agnostic.
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x.txt","content":"benign body"}}' \
  | TMPDIR="$SIG_RUN" AGENT_GUARD_GITLEAKS_BIN="$SIG_GL" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/dev/null 2>&1 &
sig_pid=$!

sig_i=0
while [ ! -f "$SIG_READY" ] && [ "$sig_i" -lt 100 ]; do
  sig_i=$((sig_i + 1))
  sleep 0.1 2>/dev/null || sleep 1
done

if find "$SIG_RUN" -maxdepth 1 -name 'agent-guard*' 2>/dev/null | grep -q .; then
  ok "scan temp exists mid-flight (precondition for the cleanup test)"
else
  not_ok "scan temp exists mid-flight (precondition for the cleanup test)"
fi

# Enumerate the scan subshell (a direct child of main) BEFORE killing anything:
# killing main reparents its children and hides them from pgrep. Requires pgrep
# (present on macOS and Linux). Then SIGTERM main and the subshell together,
# leaving the gitleaks child orphaned (it exits on its own via the short sleep).
sig_children=$(pgrep -P "$sig_pid" 2>/dev/null)
# shellcheck disable=SC2086
kill -TERM "$sig_pid" $sig_children 2>/dev/null
wait "$sig_pid" 2>/dev/null
# Give the exit/term trap a bounded moment to remove the rundir.
sig_i=0
while find "$SIG_RUN" -maxdepth 1 -name 'agent-guard*' 2>/dev/null | grep -q . \
  && [ "$sig_i" -lt 20 ]; do
  sig_i=$((sig_i + 1))
  sleep 0.1 2>/dev/null || sleep 1
done

sig_leftover=$(find "$SIG_RUN" -maxdepth 1 -name 'agent-guard*' 2>/dev/null)
if [ -z "$sig_leftover" ]; then
  ok "interrupted scan leaves no leftover scan temp (#131)"
else
  not_ok "interrupted scan leaves no leftover scan temp (#131): $sig_leftover"
fi
rm -rf "$SIGTMP"

# Normal completion must also leave nothing behind: the EXIT trap removes the
# rundir itself (the manual per-file rm only clears its contents).
NORM_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/ag-normtest.XXXXXX")
NORM_RUN="$NORM_PARENT/run"
mkdir -p "$NORM_RUN"
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x.txt","content":"benign body"}}' \
  | TMPDIR="$NORM_RUN" "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/dev/null 2>&1
norm_leftover=$(find "$NORM_RUN" -maxdepth 1 -name 'agent-guard*' 2>/dev/null)
if [ -z "$norm_leftover" ]; then
  ok "normal hook completion leaves no leftover scan temp"
else
  not_ok "normal hook completion leaves no leftover scan temp: $norm_leftover"
fi
rm -rf "$NORM_PARENT"

say "passed: $pass"
say "failed: $fail"

[ "$fail" -eq 0 ]

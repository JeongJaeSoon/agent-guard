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

# Guided setup must verify the installed plugin itself and the live Codex hook
# boundary. A standalone PATH binary or a passing binary smoke test is not proof
# that the plugin hooks are trusted or dispatched by the host.
setup_skill="$PLUGIN_ROOT/skills/setup-agent-guard/SKILL.md"
if grep -Fq '../../bin/agent-guard' "$setup_skill" \
   && grep -Fq 'Compare its `version` with the plugin binary' "$setup_skill" \
   && grep -Fq 'Settings > Hooks' "$setup_skill" \
   && grep -Fq '`Untrusted` and `Modified` as inactive' "$setup_skill" \
   && grep -Fq 'AGENT_GUARD_LIVE_PRE_TOOL_PROBE' "$setup_skill" \
   && grep -Fq 'AGENT_GUARD_LIVE_POST_TOOL_PROBE' "$setup_skill" \
   && ! grep -Fq 'cat .env' "$setup_skill" \
   && grep -Fq '`functions.exec`' "$setup_skill" \
   && grep -Fq 'They do not prove that the host is dispatching plugin hooks' "$setup_skill"; then
  ok "Codex setup skill verifies plugin-local, trust, and live-hook layers"
else
  not_ok "Codex setup skill verifies plugin-local, trust, and live-hook layers"
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
  *'CLAUDE_PLUGIN_ROOT'*'hook-session-start'*)
    ok "SessionStart command invokes hook-session-start via CLAUDE_PLUGIN_ROOT" ;;
  *)
    not_ok "SessionStart command invokes hook-session-start via CLAUDE_PLUGIN_ROOT (got: $ss_hook_command)" ;;
esac
if [ "$ss_hook_timeout" = 5 ]; then
  ok "SessionStart timeout is 5 in hooks/hooks.json"
else
  not_ok "SessionStart timeout is 5 in hooks/hooks.json (got: $ss_hook_timeout)"
fi

claude_pre_tool_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")
case "$claude_pre_tool_command" in
  *'CLAUDE_PLUGIN_ROOT'*)
    ok "Claude hook command uses CLAUDE_PLUGIN_ROOT"
    ;;
  *)
    not_ok "Claude hook command uses CLAUDE_PLUGIN_ROOT"
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
  *'PLUGIN_ROOT'*)
    ok "Codex hook command uses PLUGIN_ROOT"
    ;;
  *)
    not_ok "Codex hook command uses PLUGIN_ROOT"
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
if [ "$status" -eq 2 ]; then
  ok "Claude hook command fails closed without CLAUDE_PLUGIN_ROOT"
else
  not_ok "Claude hook command fails closed without CLAUDE_PLUGIN_ROOT (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
if grep -q 'CLAUDE_PLUGIN_ROOT env not set' "$ERR"; then
  ok "Claude hook command explains missing CLAUDE_PLUGIN_ROOT"
else
  not_ok "Claude hook command explains missing CLAUDE_PLUGIN_ROOT"
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
if [ "$status" -eq 2 ]; then
  ok "Codex hook command fails closed without PLUGIN_ROOT"
else
  not_ok "Codex hook command fails closed without PLUGIN_ROOT (expected 2, got $status)"
  sed 's/^/  stderr: /' "$ERR"
fi
if grep -q 'PLUGIN_ROOT env not set' "$ERR"; then
  ok "Codex hook command explains missing PLUGIN_ROOT"
else
  not_ok "Codex hook command explains missing PLUGIN_ROOT"
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
  printf "%s" "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"x\"}}" \
    | "'"$PLUGIN_ROOT"'/bin/agent-guard" hook-pre-tool
' >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-pre-tool fail-closes when gitleaks errors during a Write scan"
else
  not_ok "hook-pre-tool fail-closes when gitleaks errors during a Write scan (expected 2, got $status)"
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

printf '%s' '{"tool_name":"Bash","tool_input":{"command":"brew install gitleaks"}}' \
  | AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks PATH="$NO_GITLEAKS_BIN" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$ERR"
status=$?
if [ "$status" -eq 0 ] && grep -q 'DEGRADED' "$ERR" && grep -q '\$setup-agent-guard' "$ERR"; then
  ok "hook degrades open with an actionable setup warning when dependencies are missing"
else
  not_ok "hook degraded mode allows setup commands with a warning (status $status)"
  sed 's/^/  stdout: /' "$OUT"
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
# Both fail closed, and at the hook boundary both must exit 2 because that is
# the host's only block signal. So the MESSAGE is what has to tell an operator
# which of the two happened: a secret in their staged changes, or a scan that
# never ran. The assertions below pin both directions of that distinction.

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
(
  cd "$NON_REPO_DIR" || exit 2
  jq -nc --arg cwd "$NON_REPO_DIR" \
    '{tool_name:"Bash",tool_input:{command:"git commit -m x"},cwd:$cwd}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >"$OUT" 2>"$CANNOT_SCAN_ERR"
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "commit from a non-repo cwd still fails closed"
else
  not_ok "commit from a non-repo cwd still fails closed (expected 2, got $status)"
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
bg_in_cc=$(PATH="$bg_dir/bin:$PATH" CLAUDECODE=1 sh -c '. "$1"; cat "$2"' _ "$bg_dir/guard.sh" "$bg_dir/file.txt" 2>/dev/null)
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
  bg_alias_snapshot=$(PATH="$bg_dir/bin:$PATH" CLAUDECODE=1 "$bg_sh" -c '
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
# command wrapping fails OPEN — it still runs the command — but warns loudly on stderr.
bg_none="$bg_dir/guard-none.sh"
sed "s#^__agentguard_bin=.*#__agentguard_bin='/nonexistent/agent-guard'#" "$bg_dir/guard.sh" >"$bg_none"
bg_open=$(PATH=/usr/bin:/bin CLAUDECODE=1 sh -c '. "$1"; cat "$2"' _ "$bg_none" "$bg_dir/file.txt" 2>"$ERR")
if [ "$bg_open" = hello-plain ]; then
  ok "command wrapping fails OPEN (runs the command) when no binary resolves"
else
  not_ok "command wrapping fail-open passthrough when no binary resolves (got: $bg_open)"
fi
if grep -q 'NOT masked' "$ERR"; then
  ok "command wrapping warns loudly on stderr when it cannot mask"
else
  not_ok "command wrapping warns loudly on stderr when it cannot mask"
fi

# agx is an EXPLICIT mask request, so it fails CLOSED — it must NOT run the
# command unmasked when the binary is missing; it returns 127 instead.
agx_out=$(PATH=/usr/bin:/bin sh -c '. "$1"; agx cat "$2"; printf "rc=%s" "$?"' _ "$bg_none" "$bg_dir/file.txt" 2>/dev/null)
case "$agx_out" in
  *hello-plain*) not_ok "agx fails CLOSED when no binary resolves (leaked: $agx_out)" ;;
  *rc=127*)      ok "agx fails CLOSED (rc=127, does not run) when no binary resolves" ;;
  *)             not_ok "agx fail-closed return code (got: $agx_out)" ;;
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

vd_out=$(run_session_start 'not a version' 2>"$ERR")
if [ $? -eq 0 ] && [ -z "$vd_out" ]; then
  ok "hook-session-start is silent when the marker cannot be parsed"
else
  not_ok "hook-session-start silent on unparseable marker (got: $vd_out)"
fi

vd_out=$(AGENT_GUARD_GITLEAKS_BIN=/nonexistent/gitleaks \
  PATH="$NO_GITLEAKS_BIN" "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>"$ERR")
if [ $? -eq 0 ] \
   && printf '%s' "$vd_out" | jq -e '.systemMessage | contains("DEGRADED")' >/dev/null 2>&1 \
   && printf '%s' "$vd_out" | grep -q '\$setup-agent-guard'; then
  ok "hook-session-start guides dependency setup while protection is degraded"
else
  not_ok "hook-session-start emits an actionable degraded-mode warning (got: $vd_out)"
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

# (a) resolved via $PATH
mk_path=$(source_marker "$mk_dir/guard.sh" "$mk_dir/bin:/usr/bin:/bin" "")
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
"$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_rc" >/dev/null 2>&1
if grep -q '>>> agent-guard shell-init >>>' "$ss_rc" 2>/dev/null; then
  ok "setup-shell writes a managed shell-init block into the rc"
else
  not_ok "setup-shell writes a managed shell-init block into the rc"
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
   && ! printf '%s' "$setup_shell_help" | grep -q -- '--experimental-bang-guard'; then
  ok "setup-shell help exposes only the 2.x command-wrapping option"
else
  not_ok "setup-shell help exposes only the 2.x command-wrapping option"
fi
# Self-healing invocation: the rc line prefers `agent-guard` on $PATH but bakes an
# absolute-path fallback keyed on OUTPUT (not mere presence), so it stays a valid
# generator even if the bare name later leaves $PATH or a stale binary emits nothing.
ss_heal="$TESTTMP/setup-heal.rc"
"$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$ss_heal" >/dev/null 2>&1
if grep -q '_agi=$(agent-guard shell-init' "$ss_heal" 2>/dev/null \
   && grep -q 'if \[ -n "$_agi" \]' "$ss_heal" 2>/dev/null; then
  ok "setup-shell bakes a self-healing invocation (output probe + absolute fallback)"
else
  not_ok "setup-shell bakes a self-healing invocation (output probe + absolute fallback)"
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

say "passed: $pass"
say "failed: $fail"

[ "$fail" -eq 0 ]

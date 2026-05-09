#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
TMP_ROOT=${TMPDIR:-/tmp}/agent-guard-tests.$$
MOCK_BIN="$TMP_ROOT/bin"
ORIGINAL_PATH=$PATH
REAL_GITLEAKS=$(command -v gitleaks 2>/dev/null || true)
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
  "$@" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
  status=$?
  if [ "$status" -eq "$expected" ]; then
    ok "$name"
  else
    not_ok "$name (expected $expected, got $status)"
    sed 's/^/  stdout: /' /tmp/agent-guard-test.out
    sed 's/^/  stderr: /' /tmp/agent-guard-test.err
  fi
}

json_to() {
  printf '%s' "$1" | "$PLUGIN_ROOT/bin/agent-guard" "$2" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    sed 's/^/  stdout: /' /tmp/agent-guard-test.out
    sed 's/^/  stderr: /' /tmp/agent-guard-test.err
  fi
}

cleanup() {
  rm -rf "$TMP_ROOT"
  rm -f /tmp/agent-guard-test.out /tmp/agent-guard-test.err
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

for file in \
  "$PLUGIN_ROOT/hooks/hooks.json" \
  "$PLUGIN_ROOT/.claude-plugin/plugin.json" \
  "$ROOT/.claude-plugin/marketplace.json" \
  "$PLUGIN_ROOT/.codex-plugin/plugin.json" \
  "$ROOT/.agents/plugins/marketplace.json" \
  "$ROOT/examples/claude/settings.project.json" \
  "$ROOT/examples/codex/hooks.json"; do
  run_expect 0 "json syntax: $file" jq -e . "$file"
done

for event in PreToolUse PostToolUse; do
  canonical=$(jq -r ".hooks.${event}[0].matcher" "$PLUGIN_ROOT/hooks/hooks.json")
  for file in \
    "$ROOT/examples/claude/settings.project.json" \
    "$ROOT/examples/codex/hooks.json"; do
    actual=$(jq -r ".hooks.${event}[0].matcher" "$file")
    if [ "$actual" = "$canonical" ]; then
      ok "$event matcher in $file matches hooks/hooks.json"
    else
      not_ok "$event matcher in $file matches hooks/hooks.json (got: $actual)"
    fi
  done
done

pre_tool_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$PLUGIN_ROOT/hooks/hooks.json")
read_env_payload='{"tool_name":"Read","tool_input":{"file_path":".env"}}'
printf '%s' "$read_env_payload" \
  | (cd "$PLUGIN_ROOT" && env -u CLAUDE_PLUGIN_ROOT -u CODEX_PLUGIN_ROOT sh -c "$pre_tool_command") \
  >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "plugin hook command fails closed without root env vars"
else
  not_ok "plugin hook command fails closed without root env vars (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi
if grep -q 'plugin root env not set' /tmp/agent-guard-test.err; then
  ok "plugin hook command explains missing root env vars"
else
  not_ok "plugin hook command explains missing root env vars"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$pre_tool_command") \
  >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "plugin hook command honors CLAUDE_PLUGIN_ROOT"
else
  not_ok "plugin hook command honors CLAUDE_PLUGIN_ROOT (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

printf '%s' "$read_env_payload" \
  | (cd "$TMP_ROOT" && CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" sh -c "$pre_tool_command") \
  >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "plugin hook command honors CODEX_PLUGIN_ROOT"
else
  not_ok "plugin hook command honors CODEX_PLUGIN_ROOT (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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

expect_json_status 2 "Claude Write secret is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"app.txt","content":"AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

expect_json_status 0 "safe example token is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"app.txt","content":"example_token"}}' \
  hook-pre-tool

expect_json_status 2 "Codex apply_patch added secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Add File: x\n+AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
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

expect_json_status 2 "Codex Add File payload secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Add File: x\nAGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "Codex double-plus added secret is blocked" \
  '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: x\n@@\n++AGENT_GUARD_TEST_SECRET\n*** End Patch"}}' \
  hook-pre-tool

expect_json_status 2 "MCP input secret is blocked" \
  '{"tool_name":"mcp__server__tool","tool_input":{"token":"AGENT_GUARD_TEST_SECRET"}}' \
  hook-pre-tool

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
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree detects untracked secret"
else
  not_ok "scan-working-tree detects untracked secret (expected 1, got $status)"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"stop_hook_active":true}' | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "git -c option-form commit with staged secret is intercepted"
else
  not_ok "git -c option-form commit with staged secret is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git -C . push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "git -C option-form push with staged secret is intercepted"
else
  not_ok "git -C option-form push with staged secret is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status && git -C . push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "chained git push after non-mutating git command is intercepted"
else
  not_ok "chained git push after non-mutating git command is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status&&git -C . push origin main"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "chained git push without separator spaces is intercepted"
else
  not_ok "chained git push without separator spaces is intercepted (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

expect_json_status 2 "git hook bypass without separator spaces is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify&&echo done"}}' \
  hook-pre-tool

SYMLINK_REPO="$TMP_ROOT/symlink-repo"
mkdir -p "$SYMLINK_REPO"
(
  cd "$SYMLINK_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > .env
  ln -s .env safe-link
)
if [ -L "$SYMLINK_REPO/safe-link" ]; then
  payload='{"tool_name":"Read","tool_input":{"file_path":"'"$SYMLINK_REPO"'/safe-link"}}'
  printf '%s' "$payload" | "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
  status=$?
  if [ "$status" -eq 2 ]; then
    ok "symlink to .env is blocked via realpath resolution"
  else
    not_ok "symlink to .env is blocked via realpath resolution (expected 2, got $status)"
    sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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
case "$(cat /tmp/agent-guard-test.out)" in
  agent-guard*) ok "version output starts with program name" ;;
  *) not_ok "version output unexpected: $(cat /tmp/agent-guard-test.out)" ;;
esac

run_expect 0 "help subcommand exits 0" "$PLUGIN_ROOT/bin/agent-guard" help
run_expect 0 "no args exits 0 with usage on stderr" "$PLUGIN_ROOT/bin/agent-guard"
run_expect 2 "unknown subcommand exits 2" "$PLUGIN_ROOT/bin/agent-guard" not-a-command
if "$PLUGIN_ROOT/bin/agent-guard" help 2>&1 | grep -q 'smoke-test'; then
  ok "help lists smoke-test"
else
  not_ok "help lists smoke-test"
fi

run_expect 0 "check passes when deps and configs exist" "$PLUGIN_ROOT/bin/agent-guard" check

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
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "hook-post-tool ignores non-mutation tools"
else
  not_ok "hook-post-tool ignores non-mutation tools (expected 0, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

(
  cd "$POST_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > leaked.txt
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"leaked.txt"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-post-tool blocks when working tree has a new secret"
else
  not_ok "hook-post-tool blocks when working tree has a new secret (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

# --- hook_stop ------------------------------------------------------------

(
  cd "$POST_REPO" || exit 2
  rm -f leaked.txt
  printf '%s' '{"stop_hook_active":false}' | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "hook-stop allows clean working tree when not active"
else
  not_ok "hook-stop allows clean working tree when not active (expected 0, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

(
  cd "$POST_REPO" || exit 2
  printf '%s\n' "AGENT_GUARD_TEST_SECRET" > stop-leak.txt
  printf '%s' '{"stop_hook_active":false}' | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-stop blocks when working tree has a secret and not active"
else
  not_ok "hook-stop blocks when working tree has a secret and not active (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

# --- hook silent-skip outside a git work tree ------------------------------
# Regression: when the agent runs in a non-git cwd (e.g. ~), hook-post-tool
# and hook-stop must exit 0 silently instead of erroring on every Stop event.

NO_GIT_DIR="$TMP_ROOT/no-git"
mkdir -p "$NO_GIT_DIR"

(
  cd "$NO_GIT_DIR" || exit 2
  printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x.txt","content":"x"}}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-post-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ] && [ ! -s /tmp/agent-guard-test.err ]; then
  ok "hook-post-tool silently skips when cwd is not a git work tree"
else
  not_ok "hook-post-tool silently skips when cwd is not a git work tree (expected 0 + empty stderr, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

(
  cd "$NO_GIT_DIR" || exit 2
  printf '%s' '{"stop_hook_active":false}' \
    | "$PLUGIN_ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ] && [ ! -s /tmp/agent-guard-test.err ]; then
  ok "hook-stop silently skips when cwd is not a git work tree"
else
  not_ok "hook-stop silently skips when cwd is not a git work tree (expected 0 + empty stderr, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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

PATH="$ERROR_BIN:$PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-path fail-closes when gitleaks itself errors"
else
  not_ok "scan-path fail-closes when gitleaks itself errors (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

PATH="$ERROR_BIN:$PATH" sh -c '
  printf "%s" "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"x\"}}" \
    | "'"$PLUGIN_ROOT"'/bin/agent-guard" hook-pre-tool
' >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-pre-tool fail-closes when gitleaks errors during a Write scan"
else
  not_ok "hook-pre-tool fail-closes when gitleaks errors during a Write scan (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

# --- deny-bash-patterns fail-closed on invalid ERE -------------------------
# Regression guard: an invalid line in a custom deny file must NOT silently
# disable the rest of the policy. The combined `grep -f` exits with status 2,
# which we translate to a hard block instead of treating it as "no match".
BAD_PATTERNS_FILE="$TMP_ROOT/bad-deny-bash.txt"
printf '%s\n' '[unterminated-bracket' >"$BAD_PATTERNS_FILE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
  | AGENT_GUARD_DENY_BASH_PATTERNS="$BAD_PATTERNS_FILE" \
    "$PLUGIN_ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "deny-bash-patterns invalid ERE fails closed"
else
  not_ok "deny-bash-patterns invalid ERE fails closed (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

# --- gitleaks not installed -----------------------------------------------

NO_GITLEAKS_BIN="$TMP_ROOT/no-gitleaks-bin"
mkdir -p "$NO_GITLEAKS_BIN"
ln -s "$REAL_SH" "$NO_GITLEAKS_BIN/sh"
ln -s "$REAL_DIRNAME" "$NO_GITLEAKS_BIN/dirname"
ln -s "$REAL_PWD" "$NO_GITLEAKS_BIN/pwd"
PATH="$NO_GITLEAKS_BIN" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
ln -sf "$(command -v command)" "$NO_GITLEAKS_BIN/command" 2>/dev/null || true
ln -sf "$(command -v uname)" "$NO_GITLEAKS_BIN/uname" 2>/dev/null || true

PATH="$NO_GITLEAKS_BIN" "$PLUGIN_ROOT/bin/agent-guard" setup >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 1 ]; then
  ok "setup exits 1 when gitleaks missing"
else
  not_ok "setup exits 1 when gitleaks missing (expected 1, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

PATH="$NO_GITLEAKS_BIN" "$PLUGIN_ROOT/bin/agent-guard" setup --install >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "setup --install without --gitleaks-checksum exits 2"
else
  not_ok "setup --install without --gitleaks-checksum exits 2 (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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

# --- scan_staged outside a git work tree ----------------------------------

NON_REPO_DIR="$TMP_ROOT/not-a-repo"
mkdir -p "$NON_REPO_DIR"
(
  cd "$NON_REPO_DIR" || exit 2
  "$PLUGIN_ROOT/bin/agent-guard" scan-staged >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-staged dies outside a git work tree"
else
  not_ok "scan-staged dies outside a git work tree (expected 2, got $status)"
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
  "$ROOT/install.sh" git-hooks >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "install.sh git-hooks succeeds in a clean repo"
else
  not_ok "install.sh git-hooks succeeds in a clean repo (expected 0, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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
  git commit -m leak >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -ne 0 ]; then
  ok "installed native git hook blocks a staged secret"
else
  not_ok "installed native git hook blocks a staged secret"
fi

CONFLICT_REPO="$TMP_ROOT/conflict-repo"
mkdir -p "$CONFLICT_REPO"
(
  cd "$CONFLICT_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  git config core.hooksPath someone-elses-hooks
  "$ROOT/install.sh" git-hooks >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  "$ROOT/install.sh" git-hooks >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ]; then
  ok "install.sh chains an existing .git/hooks/pre-commit"
else
  not_ok "install.sh chains an existing .git/hooks/pre-commit (expected 0, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi
(
  cd "$PRECOMMIT_REPO" || exit 2
  printf '%s\n' ok > README.md
  git add README.md
  git commit -m init >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 0 ] && [ "$(cat "$PRECOMMIT_CANARY" 2>/dev/null)" = "legacy-ran" ]; then
  ok "installed hook runs the pre-existing pre-commit hook"
else
  not_ok "installed hook runs the pre-existing pre-commit hook"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

run_expect 2 "install.sh unknown subcommand exits 2" "$ROOT/install.sh" not-a-command
run_expect 0 "install.sh check passes" "$ROOT/install.sh" check

RELEASE_TARBALL_DIR="$TMP_ROOT/release-tarball"
mkdir -p "$RELEASE_TARBALL_DIR/out"
run_expect 0 "release tarball builder succeeds" \
  "$ROOT/scripts/build-release-tarball.sh" test "$RELEASE_TARBALL_DIR/agent-guard-test.tar.gz"
tar -xzf "$RELEASE_TARBALL_DIR/agent-guard-test.tar.gz" -C "$RELEASE_TARBALL_DIR/out"
if [ -x "$RELEASE_TARBALL_DIR/out/bin/agent-guard" ] && [ -x "$RELEASE_TARBALL_DIR/out/install.sh" ]; then
  ok "release tarball contains bin/agent-guard and install.sh"
else
  not_ok "release tarball contains bin/agent-guard and install.sh"
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
  "$ROOT/githooks/pre-commit" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "githooks/pre-commit blocks commits with staged secrets"
else
  not_ok "githooks/pre-commit blocks commits with staged secrets (expected 1, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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
  "$PLUGIN_ROOT/bin/agent-guard" scan-working-tree >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree single-shot detects a secret among 5 untracked files"
else
  not_ok "scan-working-tree single-shot detects a secret among 5 untracked files (expected 1, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi
if grep -q 'untracked files' /tmp/agent-guard-test.err; then
  ok "single-shot scan reports an 'untracked files' label"
else
  not_ok "single-shot scan reports an 'untracked files' label"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

# --- agent-guard check announces gitleaks version ------------------------
"$PLUGIN_ROOT/bin/agent-guard" check >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
if grep -q 'gitleaks' /tmp/agent-guard-test.err; then
  ok "check prints a gitleaks version line"
else
  not_ok "check prints a gitleaks version line"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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
  } > "$RSA_FIXTURE_DIR/key.pem"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$RSA_FIXTURE_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks detects an RSA private key through scan-path"
  else
    not_ok "real gitleaks detects an RSA private key through scan-path (expected 1, got $status)"
    sed 's/^/  stderr: /' /tmp/agent-guard-test.err
  fi

  OPENSSH_FIXTURE_DIR="$TMP_ROOT/openssh-fixture-dir"
  mkdir -p "$OPENSSH_FIXTURE_DIR"
  {
    printf '%s%s\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----'
    printf '%s\n' "$PEM_BODY"
    printf '%s%s\n' '-----END OPENSSH ' 'PRIVATE KEY-----'
  } > "$OPENSSH_FIXTURE_DIR/openssh.key"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$PLUGIN_ROOT/bin/agent-guard" scan-path "$OPENSSH_FIXTURE_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks detects an OpenSSH private key through scan-path"
  else
    not_ok "real gitleaks detects an OpenSSH private key through scan-path (expected 1, got $status)"
    sed 's/^/  stderr: /' /tmp/agent-guard-test.err
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
  >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
checksum_missing_status=$?
if [ "$checksum_missing_status" -eq 2 ] && grep -q 'failed to fetch' /tmp/agent-guard-test.err; then
  ok "checksum subcommand exits 2 when the source URL is unreachable"
else
  not_ok "checksum subcommand fetch-failure path returned status $checksum_missing_status"
  sed 's/^/  /' /tmp/agent-guard-test.err
fi

say "passed: $pass"
say "failed: $fail"

[ "$fail" -eq 0 ]

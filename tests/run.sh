#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TMP_ROOT=${TMPDIR:-/tmp}/agent-guard-tests.$$
MOCK_BIN="$TMP_ROOT/bin"
ORIGINAL_PATH=$PATH
REAL_GITLEAKS=$(command -v gitleaks 2>/dev/null || true)
REAL_SH=$(command -v sh)
REAL_DIRNAME=$(command -v dirname)
REAL_PWD=$(command -v pwd)
PATH="$MOCK_BIN:$PATH"
export PATH
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/config/gitleaks.toml"

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
  printf '%s' "$1" | "$ROOT/bin/agent-guard" "$2" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  "$ROOT/bin/agent-guard" \
  "$ROOT/install.sh" \
  "$ROOT/githooks/pre-commit" \
  "$ROOT/tests/run.sh"; do
  run_expect 0 "shell syntax: $file" sh -n "$file"
done

for file in \
  "$ROOT/hooks/hooks.json" \
  "$ROOT/.claude-plugin/plugin.json" \
  "$ROOT/.claude-plugin/marketplace.json" \
  "$ROOT/.codex-plugin/plugin.json" \
  "$ROOT/.agents/plugins/marketplace.json" \
  "$ROOT/examples/claude/settings.project.json" \
  "$ROOT/examples/codex/hooks.json"; do
  run_expect 0 "json syntax: $file" jq -e . "$file"
done

for event in PreToolUse PostToolUse; do
  canonical=$(jq -r ".hooks.${event}[0].matcher" "$ROOT/hooks/hooks.json")
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
  "$ROOT/bin/agent-guard" scan-staged >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  "$ROOT/bin/agent-guard" scan-working-tree >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 1 ]; then
  ok "scan-working-tree detects untracked secret"
else
  not_ok "scan-working-tree detects untracked secret (expected 1, got $status)"
fi

(
  cd "$TEST_REPO" || exit 2
  printf '%s' '{"stop_hook_active":true}' | "$ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    | "$ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    | "$ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    | "$ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    | "$ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  printf '%s' "$payload" | "$ROOT/bin/agent-guard" hook-pre-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  "$ROOT/bin/agent-guard" version
case "$(cat /tmp/agent-guard-test.out)" in
  agent-guard*) ok "version output starts with program name" ;;
  *) not_ok "version output unexpected: $(cat /tmp/agent-guard-test.out)" ;;
esac

run_expect 0 "help subcommand exits 0" "$ROOT/bin/agent-guard" help
run_expect 0 "no args exits 0 with usage on stderr" "$ROOT/bin/agent-guard"
run_expect 2 "unknown subcommand exits 2" "$ROOT/bin/agent-guard" not-a-command

run_expect 0 "check passes when deps and configs exist" "$ROOT/bin/agent-guard" check

# --- scan-path -------------------------------------------------------------

CLEAN_DIR="$TMP_ROOT/clean-dir"
mkdir -p "$CLEAN_DIR"
printf '%s\n' "ok content" > "$CLEAN_DIR/safe.txt"
run_expect 0 "scan-path is clean for benign directory" \
  "$ROOT/bin/agent-guard" scan-path "$CLEAN_DIR"

DIRTY_DIR="$TMP_ROOT/dirty-dir"
mkdir -p "$DIRTY_DIR"
printf '%s\n' "AGENT_GUARD_TEST_SECRET" > "$DIRTY_DIR/leak.txt"
run_expect 1 "scan-path detects secret via mock gitleaks" \
  "$ROOT/bin/agent-guard" scan-path "$DIRTY_DIR"

run_expect 1 "scan-path with multiple paths returns 1 if any has a leak" \
  "$ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" "$DIRTY_DIR"

run_expect 0 "scan-path accepts -- arg terminator before paths" \
  "$ROOT/bin/agent-guard" scan-path -- "$CLEAN_DIR"

run_expect 2 "scan-path dies when given a missing path" \
  "$ROOT/bin/agent-guard" scan-path "$TMP_ROOT/does-not-exist"

run_expect 2 "scan-path dies with no paths" "$ROOT/bin/agent-guard" scan-path

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
    | "$ROOT/bin/agent-guard" hook-post-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
    | "$ROOT/bin/agent-guard" hook-post-tool >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  printf '%s' '{"stop_hook_active":false}' | "$ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  printf '%s' '{"stop_hook_active":false}' | "$ROOT/bin/agent-guard" hook-stop >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-stop blocks when working tree has a secret and not active"
else
  not_ok "hook-stop blocks when working tree has a secret and not active (expected 2, got $status)"
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

PATH="$ERROR_BIN:$PATH" "$ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-path fail-closes when gitleaks itself errors"
else
  not_ok "scan-path fail-closes when gitleaks itself errors (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

PATH="$ERROR_BIN:$PATH" sh -c '
  printf "%s" "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"x\"}}" \
    | "'"$ROOT"'/bin/agent-guard" hook-pre-tool
' >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "hook-pre-tool fail-closes when gitleaks errors during a Write scan"
else
  not_ok "hook-pre-tool fail-closes when gitleaks errors during a Write scan (expected 2, got $status)"
  sed 's/^/  stderr: /' /tmp/agent-guard-test.err
fi

# --- gitleaks not installed -----------------------------------------------

NO_GITLEAKS_BIN="$TMP_ROOT/no-gitleaks-bin"
mkdir -p "$NO_GITLEAKS_BIN"
ln -s "$REAL_SH" "$NO_GITLEAKS_BIN/sh"
ln -s "$REAL_DIRNAME" "$NO_GITLEAKS_BIN/dirname"
ln -s "$REAL_PWD" "$NO_GITLEAKS_BIN/pwd"
PATH="$NO_GITLEAKS_BIN" "$ROOT/bin/agent-guard" scan-path "$CLEAN_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
status=$?
if [ "$status" -eq 2 ]; then
  ok "scan-path dies when gitleaks is unavailable"
else
  not_ok "scan-path dies when gitleaks is unavailable (expected 2, got $status)"
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
  "$ROOT/bin/agent-guard" scan-staged >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
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
  # Use an empty template so the user's global init.templateDir cannot drop
  # a stray pre-commit hook that the install safety check would refuse.
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
mkdir -p "$PRECOMMIT_REPO"
(
  cd "$PRECOMMIT_REPO" || exit 2
  git init -q --template="$EMPTY_TEMPLATE"
  mkdir -p .git/hooks
  printf '%s\n' '#!/bin/sh' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  "$ROOT/install.sh" git-hooks >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
)
status=$?
if [ "$status" -eq 2 ]; then
  ok "install.sh refuses to overwrite an existing .git/hooks/pre-commit"
else
  not_ok "install.sh refuses to overwrite an existing .git/hooks/pre-commit (expected 2, got $status)"
fi

run_expect 2 "install.sh unknown subcommand exits 2" "$ROOT/install.sh" not-a-command
run_expect 0 "install.sh check passes" "$ROOT/install.sh" check

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

if [ -n "$REAL_GITLEAKS" ]; then
  REAL_DIRTY_DIR="$TMP_ROOT/real-dirty-dir"
  mkdir -p "$REAL_DIRTY_DIR"
  {
    printf '%s%s\n' '-----BEGIN RSA ' 'PRIVATE KEY-----'
    printf '%s\n' 'MIIEpAIBAAKCAQEAwH6yqpN5f7c7k4KQkKtQ3Rvy9zfrlWvLq8Vbkg=='
    printf '%s%s\n' '-----END RSA ' 'PRIVATE KEY-----'
  } > "$REAL_DIRTY_DIR/key.pem"
  PATH="$(dirname "$REAL_GITLEAKS"):$ORIGINAL_PATH" "$ROOT/bin/agent-guard" scan-path "$REAL_DIRTY_DIR" >/tmp/agent-guard-test.out 2>/tmp/agent-guard-test.err
  status=$?
  if [ "$status" -eq 1 ]; then
    ok "real gitleaks detects a private key through scan-path"
  else
    not_ok "real gitleaks detects a private key through scan-path (expected 1, got $status)"
    sed 's/^/  stderr: /' /tmp/agent-guard-test.err
  fi
else
  say "real gitleaks not available; skipped real-gitleaks integration tests"
fi

say "passed: $pass"
say "failed: $fail"

[ "$fail" -eq 0 ]

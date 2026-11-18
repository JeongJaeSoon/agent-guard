#!/usr/bin/env sh
# Guidance that asks the user to run this CLI must name a command that runs.
# A plugin-only install puts nothing on PATH, so it names the executable path;
# an `agent-guard` on PATH that is this installation keeps the short name.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-cli-guidance.XXXXXX") || exit 1
[ -n "$CASE_ROOT" ] || exit 1
CASE_ROOT=$(CDPATH= cd -- "$CASE_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail=0
ok() { printf 'ok - %s\n' "$*"; }
not_ok() { fail=1; printf 'not ok - %s\n' "$*"; }
REAL_JQ=$(command -v jq) || { echo 'jq is required' >&2; exit 1; }
# PATH without any agent-guard or gitleaks: the system tool directories as one
# link farm (one ln per directory), plus jq for parsing.
SYS_BIN="$CASE_ROOT/sys-bin"
mkdir -p "$SYS_BIN"
ln -s /usr/bin/* "$SYS_BIN/" 2>/dev/null
ln -s /bin/* "$SYS_BIN/" 2>/dev/null
rm -f "$SYS_BIN/agent-guard" "$SYS_BIN/gitleaks" "$SYS_BIN/jq"
ln -s "$REAL_JQ" "$SYS_BIN/jq"
BASE_PATH=$SYS_BIN
export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE_ROOT/no-gitleaks"
HOME_DIR="$CASE_ROOT/home"
mkdir -p "$HOME_DIR"

# A plugin cache version directory, with a space in its path. The payload is
# this checkout; the embedded version need not match the directory for these
# messages, so the CLI names its own path when `current` cannot be selected.
CACHE="$CASE_ROOT/plugin cache/agent-guard/agent-guard"
ROOT_V="$CACHE/2.0.0"
mkdir -p "$ROOT_V"
cp -R "$PLUGIN_ROOT/." "$ROOT_V/"
AG="$ROOT_V/bin/agent-guard"
QUOTED="\"$AG\""
ag() { env HOME="$HOME_DIR" PATH="$BASE_PATH" AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_LOG_MODE=off "$@"; }

ag "$AG" update >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq "run '$QUOTED plugin update --host claude' (or --host codex)" "$CASE_ROOT/err"; then
  ok "plugin update refusal names the quoted plugin executable, exit 2 unchanged"
else
  not_ok "plugin update refusal names the quoted plugin executable (status $status): $(cat "$CASE_ROOT/err")"
fi
# Run the advice as a user would paste it; a missing command exits 127.
advice=$(sed -n "s/.*run '\(.*\)' (or --host codex).*/\1/p" "$CASE_ROOT/err")
ag sh -c "$advice --help" >/dev/null 2>&1
status=$?
if [ -n "$advice" ] && [ "$status" -ne 127 ] && [ "$status" -ne 126 ]; then
  ok "pasted plugin update advice runs (exit $status, not command-not-found)"
else
  not_ok "pasted plugin update advice runs: '$advice' exit $status"
fi

ag "$AG" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
if grep -Fq "gitleaks (run: $QUOTED setup)" "$CASE_ROOT/err"; then
  ok "check names the plugin executable for setup"
else
  not_ok "check names the plugin executable for setup: $(cat "$CASE_ROOT/err")"
fi

ag "$AG" setup-shell --bogus >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] && grep -Fq "(see: $QUOTED setup-shell --help)" "$CASE_ROOT/err"; then
  ok "setup-shell option error names the plugin executable"
else
  not_ok "setup-shell option error names the plugin executable (status $status): $(cat "$CASE_ROOT/err")"
fi

ag env AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="file://$ROOT/tests/fixtures/gitleaks-checksums-mock.txt" \
  "$AG" checksum 8.30.1 >"$CASE_ROOT/out" 2>&1
if grep -Fq "  $QUOTED setup --install --gitleaks-checksum" "$CASE_ROOT/out"; then
  ok "checksum prints a setup --install snippet with the plugin executable"
else
  not_ok "checksum prints a setup --install snippet with the plugin executable: $(cat "$CASE_ROOT/out")"
fi

# SessionStart output reaches the host as JSON; the path must survive it.
ag env AGENT_GUARD_HOOK_HOST=claude SHELL=/bin/zsh "$AG" hook-session-start </dev/null >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
message=$(jq -r .systemMessage "$CASE_ROOT/out" 2>/dev/null) || message=
case "$message" in
  *"(or $QUOTED setup), approve"*"verify with $QUOTED check and smoke-test"*"/agent-guard:setup-shell (or $QUOTED setup-shell), then restart"*)
    case "$message" in
      *"for a standalone install"*) not_ok "SessionStart drops the standalone-only wording for a plugin path: $message" ;;
      *) ok "SessionStart names the plugin executable in valid JSON" ;;
    esac ;;
  *) not_ok "SessionStart names the plugin executable in valid JSON: $(cat "$CASE_ROOT/out")" ;;
esac

# doctor's shell-integration notice for a resolver file without a stamp.
mkdir -p "$HOME_DIR/.agent-guard"
printf '%s\n' '# unstamped' 'true' >"$HOME_DIR/.agent-guard/shell-init.sh"
ag env SHELL=/bin/zsh "$AG" doctor >"$CASE_ROOT/out" 2>&1
if grep -Fq "rerun $QUOTED setup-shell (or /agent-guard:setup-shell)" "$CASE_ROOT/out"; then
  ok "doctor names the plugin executable in its shell-integration notice"
else
  not_ok "doctor names the plugin executable: $(grep 'shell integration' "$CASE_ROOT/out")"
fi
rm -f "$HOME_DIR/.agent-guard/shell-init.sh"

# A complete cache version whose embedded version matches gets the `current`
# link; advice then names that stable path, which survives a plugin update.
CLI_VERSION=$(sed -n 's/^VERSION=//p' "$PLUGIN_ROOT/bin/agent-guard" | head -n 1)
STABLE_V="$CASE_ROOT/stable cache/agent-guard/agent-guard/$CLI_VERSION"
mkdir -p "$STABLE_V"
cp -R "$PLUGIN_ROOT/." "$STABLE_V/"
ag "$STABLE_V/bin/agent-guard" update >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
if [ -L "$CASE_ROOT/stable cache/agent-guard/agent-guard/current" ] \
   && grep -Fq "run '\"$CASE_ROOT/stable cache/agent-guard/agent-guard/current/bin/agent-guard\" plugin update" "$CASE_ROOT/err"; then
  ok "advice names the plugin cache current link when it is usable"
else
  not_ok "advice names the plugin cache current link: $(cat "$CASE_ROOT/err")"
fi

# `agent-guard` on PATH that IS this installation keeps the short name.
mkdir -p "$CASE_ROOT/path-bin"
ln -s "$AG" "$CASE_ROOT/path-bin/agent-guard"
env HOME="$HOME_DIR" PATH="$CASE_ROOT/path-bin:$BASE_PATH" "$AG" update >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] && grep -Fq "run 'agent-guard plugin update --host claude'" "$CASE_ROOT/err"; then
  ok "plugin executable on PATH keeps the short command name"
else
  not_ok "plugin executable on PATH keeps the short command name (status $status): $(cat "$CASE_ROOT/err")"
fi
# A different agent-guard on PATH is not this plugin; name the plugin path.
mkdir -p "$CASE_ROOT/other-bin"
printf '#!/bin/sh\nexit 0\n' >"$CASE_ROOT/other-bin/agent-guard"
chmod +x "$CASE_ROOT/other-bin/agent-guard"
env HOME="$HOME_DIR" PATH="$CASE_ROOT/other-bin:$BASE_PATH" "$AG" update >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
if grep -Fq "run '$QUOTED plugin update" "$CASE_ROOT/err"; then
  ok "an unrelated agent-guard on PATH does not replace the plugin path"
else
  not_ok "an unrelated agent-guard on PATH does not replace the plugin path: $(cat "$CASE_ROOT/err")"
fi

# Standalone (non-plugin) install with agent-guard on PATH: unchanged wording.
env HOME="$HOME_DIR" PATH="$CASE_ROOT/other-bin:$BASE_PATH" "$PLUGIN_ROOT/bin/agent-guard" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
if grep -Fq "gitleaks (run: agent-guard setup)" "$CASE_ROOT/err"; then
  ok "standalone install with agent-guard on PATH keeps the short command name"
else
  not_ok "standalone install with agent-guard on PATH keeps the short command name: $(cat "$CASE_ROOT/err")"
fi
env HOME="$HOME_DIR" PATH="$CASE_ROOT/other-bin:$BASE_PATH" AGENT_GUARD_HOOK_HOST=claude SHELL=/bin/zsh \
  "$PLUGIN_ROOT/bin/agent-guard" hook-session-start </dev/null >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
message=$(jq -r .systemMessage "$CASE_ROOT/out" 2>/dev/null) || message=
case "$message" in
  *"(or agent-guard setup), approve"*"(or agent-guard setup-shell for a standalone install)"*)
    ok "standalone SessionStart wording is unchanged" ;;
  *) not_ok "standalone SessionStart wording is unchanged: $(cat "$CASE_ROOT/out")" ;;
esac

# Characters that double quotes would not keep literal switch to single
# quoting, and JSON output escapes what the shell word contains.
ODD_V="$CASE_ROOT/odd \"\$dir\"/agent-guard/agent-guard/2.0.0"
mkdir -p "$ODD_V"
cp -R "$PLUGIN_ROOT/." "$ODD_V/"
ODD="$ODD_V/bin/agent-guard"
ag "$ODD" update >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
advice=$(sed -n "s/.*run '\(.*\)' (or --host codex).*/\1/p" "$CASE_ROOT/err")
case "$advice" in
  "'$ODD' plugin update --host claude") ok "a path with quotes or \$ is single-quoted" ;;
  *) not_ok "a path with quotes or \$ is single-quoted: $advice" ;;
esac
ag env AGENT_GUARD_HOOK_HOST=claude SHELL=/bin/zsh "$ODD" hook-session-start </dev/null >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
message=$(jq -r .systemMessage "$CASE_ROOT/out" 2>/dev/null) || message=
case "$message" in
  *"(or '$ODD' setup), approve"*) ok "SessionStart JSON escapes a quoted path" ;;
  *) not_ok "SessionStart JSON escapes a quoted path: $(cat "$CASE_ROOT/out")" ;;
esac

[ "$fail" -eq 0 ]

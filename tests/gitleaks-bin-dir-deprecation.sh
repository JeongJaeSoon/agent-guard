#!/bin/sh
# O-1: AGENT_GUARD_BIN_DIR is the installer's public link directory. The CLI
# stops reading it as the private gitleaks directory; during the deprecation
# period a gitleaks already in it is still used, with a notice that names the
# settings but never their values. Every case runs a real hook scan through a
# logging stand-in gitleaks, so the scanner that ran is observed, not inferred.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/ag-bindir.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() {
  fail=$((fail + 1)); printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE/err" ] || sed 's/^/  stderr: /' "$CASE/err"
  [ ! -s "$CASE/out" ] || sed 's/^/  stdout: /' "$CASE/out"
}
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
VERSION=$(sed -n 's/^VERSION=//p' "$GUARD")

# Tools without any gitleaks, so only the directories under test can supply one.
TOOLS="$CASE/tools"
mkdir -p "$TOOLS"
for tool in sh dirname pwd jq git awk mktemp rm mkdir rmdir wc tr sleep head tail grep sed cat chmod \
  uname shasum tar mv cp ln date env od cut sort tee touch setsid perl gzip ps kill basename stat id find xargs; do
  tool_path=$(command -v "$tool" 2>/dev/null || true)
  case $tool_path in /*) ln -s "$tool_path" "$TOOLS/$tool" ;; esac
done

make_gitleaks() { # $1 directory
  mkdir -p "$1"
  cat >"$1/gitleaks" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$0" "${1:-}" >>"$AG_TEST_GITLEAKS_LOG"
case "${1:-}" in
  version) printf '%s\n' 8.30.1 ;;
  stdin) cat >/dev/null ;;
esac
exit 0
STUB
  chmod +x "$1/gitleaks"
}

LEGACY="$CASE/legacy-bin"      # holds gitleaks; set only as AGENT_GUARD_BIN_DIR
LINKS="$CASE/public-links"     # an installer link directory without gitleaks
NEW="$CASE/new-bin"            # set as AGENT_GUARD_GITLEAKS_BIN_DIR
make_gitleaks "$LEGACY"
make_gitleaks "$NEW"
mkdir -p "$LINKS"

run() { # $1 home, then settings; the command follows "--"
  home=$1; shift
  rm -rf "$CASE/state"; mkdir -p "$CASE/state" "$home"
  : >"$CASE/log"
  set -- env -u AGENT_GUARD_BIN_DIR -u AGENT_GUARD_GITLEAKS_BIN_DIR -u AGENT_GUARD_GITLEAKS_BIN \
    -u AGENT_GUARD_GITLEAKS_HELPER -u AGENT_GUARD_SHELL_INIT_VERSION -u AGENT_GUARD_INFRA_FAILURE_MODE \
    HOME="$home" XDG_STATE_HOME="$CASE/state" PATH="$TOOLS" AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_CODEX_TRUST_CHECK=off AG_TEST_GITLEAKS_LOG="$CASE/log" \
    AGENT_GUARD_WARNING_DIR="$CASE/warn" "$@"
  "$@" >"$CASE/out" 2>"$CASE/err" </dev/null
  echo "$?" >"$CASE/status"
}
scan() { # settings... -> runs one PreToolUse Write scan
  rm -rf "$CASE/warn"
  printf '%s' '{"session_id":"bindir-'"$$"'-'"$pass$fail"'","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
    >"$CASE/in"
  home=$1; shift
  rm -rf "$CASE/state"; mkdir -p "$CASE/state" "$home"
  : >"$CASE/log"
  env -u AGENT_GUARD_BIN_DIR -u AGENT_GUARD_GITLEAKS_BIN_DIR -u AGENT_GUARD_GITLEAKS_BIN \
    -u AGENT_GUARD_GITLEAKS_HELPER -u AGENT_GUARD_INFRA_FAILURE_MODE \
    HOME="$home" XDG_STATE_HOME="$CASE/state" PATH="$TOOLS" AGENT_GUARD_LOG_MODE=off \
    AG_TEST_GITLEAKS_LOG="$CASE/log" AGENT_GUARD_WARNING_DIR="$CASE/warn" "$@" \
    "$GUARD" hook-pre-tool <"$CASE/in" >"$CASE/out" 2>"$CASE/err"
  echo "$?" >"$CASE/status"
}
scanned_with() { [ "$(cat "$CASE/status")" = 0 ] && grep -qxF "$1/gitleaks stdin" "$CASE/log" \
  && ! grep -v "^$1/gitleaks " "$CASE/log" | grep -q .; }
notice() { grep -F 'AGENT_GUARD_BIN_DIR' "$1"; }
# The notice names both settings and never a directory it was given.
notice_is_value_free() {
  notice "$1" | grep -qF AGENT_GUARD_GITLEAKS_BIN_DIR && ! notice "$1" | grep -qF "$CASE"
}

# --- which gitleaks a hook scan runs ---------------------------------------
H="$CASE/home-a"
scan "$H" AGENT_GUARD_BIN_DIR="$LEGACY"
expect "deprecated: a gitleaks already in AGENT_GUARD_BIN_DIR is still the one scans run" 'scanned_with "$LEGACY"'

H="$CASE/home-b"
make_gitleaks "$H/.agent-guard/bin"
scan "$H" AGENT_GUARD_BIN_DIR="$LINKS"
expect "an AGENT_GUARD_BIN_DIR without gitleaks is not the gitleaks directory: the default private one is used" \
  'scanned_with "$H/.agent-guard/bin"'

H="$CASE/home-c"
scan "$H" AGENT_GUARD_BIN_DIR="$LEGACY" AGENT_GUARD_GITLEAKS_BIN_DIR="$NEW"
expect "with both set, AGENT_GUARD_GITLEAKS_BIN_DIR is used, as before" 'scanned_with "$NEW"'

H="$CASE/home-d"
make_gitleaks "$H/.agent-guard/bin"
scan "$H"
expect "control: with neither set the default private directory is used" 'scanned_with "$H/.agent-guard/bin"'

# --- SessionStart notice, both hosts ----------------------------------------
for host in claude codex; do
  H="$CASE/home-ss-$host"
  make_gitleaks "$H/.agent-guard/bin"
  run "$H" AGENT_GUARD_HOOK_HOST=$host AGENT_GUARD_SHELL_INIT_VERSION="$VERSION" AGENT_GUARD_BIN_DIR="$LEGACY" \
    "$GUARD" hook-session-start
  expect "$host SessionStart tells a user of the deprecated directory to move to AGENT_GUARD_GITLEAKS_BIN_DIR" \
    '[ "$(cat "$CASE/status")" = 0 ] && jq -e .systemMessage "$CASE/out" >/dev/null && notice_is_value_free "$CASE/out"'
  if [ "$host" = codex ]; then
    expect "codex SessionStart context carries the same value-free notice" \
      'jq -r .hookSpecificOutput.additionalContext "$CASE/out" | grep -qF AGENT_GUARD_GITLEAKS_BIN_DIR'
  fi
  run "$H" AGENT_GUARD_HOOK_HOST=$host AGENT_GUARD_SHELL_INIT_VERSION="$VERSION" AGENT_GUARD_BIN_DIR="$LINKS" \
    "$GUARD" hook-session-start
  expect "$host SessionStart stays quiet for an installer link directory without gitleaks" \
    '[ "$(cat "$CASE/status")" = 0 ] && [ ! -s "$CASE/out" ]'
  run "$H" AGENT_GUARD_HOOK_HOST=$host AGENT_GUARD_SHELL_INIT_VERSION="$VERSION" AGENT_GUARD_BIN_DIR="$LEGACY" \
    AGENT_GUARD_GITLEAKS_BIN_DIR="$NEW" "$GUARD" hook-session-start
  expect "$host SessionStart stays quiet when AGENT_GUARD_GITLEAKS_BIN_DIR is set" \
    '[ "$(cat "$CASE/status")" = 0 ] && [ ! -s "$CASE/out" ]'
done

# --- CLI commands that read it -----------------------------------------------
H="$CASE/home-cli"
for command in setup doctor; do
  run "$H" AGENT_GUARD_BIN_DIR="$LEGACY" "$GUARD" $command
  expect "$command warns about the deprecated directory and says setup --install still installs there" \
    'notice_is_value_free "$CASE/err" && notice "$CASE/err" | grep -qF "setup --install"'
  run "$H" "$GUARD" $command
  expect "control: $command without AGENT_GUARD_BIN_DIR has no notice" '! notice "$CASE/err"'
done
mkdir -p "$CASE/clean"
run "$H" AGENT_GUARD_BIN_DIR="$LEGACY" "$GUARD" scan-path "$CASE/clean"
expect "scan-path warns about the deprecated directory and still scans with it" \
  '[ "$(cat "$CASE/status")" = 0 ] && notice_is_value_free "$CASE/err" && grep -qxF "$LEGACY/gitleaks dir" "$CASE/log"'
run "$H" AGENT_GUARD_GITLEAKS_BIN_DIR="$NEW" sh -e "$GUARD" scan-path "$CASE/clean"
expect "control: scan-path without a notice keeps the scanner's status under sh -e" '[ "$(cat "$CASE/status")" = 0 ]'
run "$H" AGENT_GUARD_BIN_DIR="$LINKS" "$GUARD" scan-path "$CASE/clean"
expect "control: scan-path with an installer link directory has no notice" '! notice "$CASE/err"'
run "$H" AGENT_GUARD_BIN_DIR="$LINKS" "$GUARD" setup
expect "control: setup that installs nothing has no notice for an installer link directory" '! notice "$CASE/err"'
env -u HOME PATH="$TOOLS" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=off AG_TEST_GITLEAKS_LOG="$CASE/log" \
  AGENT_GUARD_BIN_DIR="$LINKS" AGENT_GUARD_GITLEAKS_BIN="$NEW/gitleaks" \
  "$GUARD" scan-path "$CASE/clean" >"$CASE/out" 2>"$CASE/err"
no_home_status=$?
expect "without HOME an installer link directory does not stop a scan with a selected gitleaks" \
  '[ "$no_home_status" = 0 ] && grep -qxF "$NEW/gitleaks dir" "$CASE/log"'

# --- setup --install: where gitleaks goes ------------------------------------
ARCH="$CASE/archive"
make_gitleaks "$ARCH/payload"
tar -czf "$ARCH/gitleaks.tar.gz" -C "$ARCH/payload" gitleaks
SUM=$(shasum -a 256 "$ARCH/gitleaks.tar.gz" | awk '{print $1}')
cat >"$TOOLS/curl" <<STUB
#!/bin/sh
while [ "\$#" -gt 0 ]; do [ "\$1" = -o ] && { shift; exec cp '$ARCH/gitleaks.tar.gz' "\$1"; }; shift; done
exit 2
STUB
chmod +x "$TOOLS/curl"
H="$CASE/home-install"
run "$H" AGENT_GUARD_BIN_DIR="$LINKS" AGENT_GUARD_GITLEAKS_HELPER=off \
  "$GUARD" setup --install --gitleaks-version 8.30.1 --gitleaks-checksum "$SUM"
expect "setup --install puts gitleaks in the default private directory, not the installer link directory" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ -x "$H/.agent-guard/bin/gitleaks" ] && [ ! -e "$LINKS/gitleaks" ]'
expect "and says that AGENT_GUARD_BIN_DIR no longer chooses where it goes" \
  'notice_is_value_free "$CASE/err" && notice "$CASE/err" | grep -qF "setup --install"'
H="$CASE/home-install-helper-only"
HELPER_ONLY="$CASE/helper-only-bin"
mkdir -p "$HELPER_ONLY/gitleaks-helper"
: >"$HELPER_ONLY/gitleaks-helper/SHA256SUMS"
run "$H" AGENT_GUARD_BIN_DIR="$HELPER_ONLY" AGENT_GUARD_GITLEAKS_HELPER=off \
  "$GUARD" setup --install --gitleaks-version 8.30.1 --gitleaks-checksum "$SUM"
expect "deprecated: a directory with only a helper installed earlier stays the gitleaks directory, with the notice" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ -x "$HELPER_ONLY/gitleaks" ] && [ ! -e "$H/.agent-guard/bin/gitleaks" ] \
   && notice_is_value_free "$CASE/err" && notice "$CASE/err" | grep -qF "is deprecated"'
H="$CASE/home-install-empty-helper"
EMPTY_HELPER="$CASE/empty-helper-bin"
mkdir -p "$EMPTY_HELPER/gitleaks-helper"
make_gitleaks "$H/.agent-guard/bin"
scan "$H" AGENT_GUARD_BIN_DIR="$EMPTY_HELPER"
expect "an empty helper directory left in AGENT_GUARD_BIN_DIR does not make it the gitleaks directory" \
  'scanned_with "$H/.agent-guard/bin"'
NO_HOME_LINKS="$CASE/no-home-links"
mkdir -p "$NO_HOME_LINKS"
env -u HOME -u AGENT_GUARD_GITLEAKS_BIN_DIR PATH="$TOOLS" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_GITLEAKS_HELPER=off AGENT_GUARD_BIN_DIR="$NO_HOME_LINKS" \
  "$GUARD" setup --install --gitleaks-version 8.30.1 --gitleaks-checksum "$SUM" >"$CASE/out" 2>"$CASE/err"
no_home_install=$?
expect "without HOME setup --install refuses rather than install into the installer link directory" \
  '[ "$no_home_install" -ne 0 ] && [ ! -e "$NO_HOME_LINKS/gitleaks" ] && grep -qF "set AGENT_GUARD_GITLEAKS_BIN_DIR" "$CASE/err"'
H="$CASE/home-install-new"
run "$H" AGENT_GUARD_BIN_DIR="$LINKS" AGENT_GUARD_GITLEAKS_BIN_DIR="$NEW-install" AGENT_GUARD_GITLEAKS_HELPER=off \
  "$GUARD" setup --install --gitleaks-version 8.30.1 --gitleaks-checksum "$SUM"
expect "control: setup --install follows AGENT_GUARD_GITLEAKS_BIN_DIR without a notice" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ -x "$NEW-install/gitleaks" ] && ! notice "$CASE/err"'

# --- the installer keeps its meaning ------------------------------------------
expect "bootstrap.sh still documents AGENT_GUARD_BIN_DIR as the link directory" \
  'grep -qF "AGENT_GUARD_BIN_DIR   directory the agent-guard symlink lives in" "$ROOT/bootstrap.sh"'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

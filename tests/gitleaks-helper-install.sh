#!/bin/sh
# #569: `agent-guard setup --install-gitleaks-helper` downloads the released
# warm gitleaks helper for this platform and installs it only when both
# binaries match the checksums this CLI pins; the CLI then preloads gitleaks
# through it by default.
#
# Without arguments it runs a copy of the plugin with its own pin file, a
# stand-in helper and a stand-in curl: no Go, no network. With the released
# artifacts and the official gitleaks it installs the real archive under the
# repository's pins and checks that a hook is answered by the warm helper:
#
#   AGENT_GUARD_NATIVE_ARTIFACT_DIR=/abs/artifacts AGENT_GUARD_TEST_REAL_GITLEAKS=/abs/gitleaks \
#     sh tests/gitleaks-helper-install.sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
# A socket path must fit sun_path (104 bytes on macOS), so not $TMPDIR.
CASE=$(mktemp -d /tmp/aghi.XXXXXX) || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
REAL_DIR=${AGENT_GUARD_NATIVE_ARTIFACT_DIR:-}
REAL_GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS:-}
helper_pids() { pgrep -f "agent-guard-gitleaks-helper serve --state-dir $CASE/xs/agent-guard" 2>/dev/null; }
cleanup() {
  for pid in $(helper_pids); do kill "$pid" 2>/dev/null; done
  rm -rf "$CASE"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

mkdir -p "$CASE/bin" "$CASE/http-bin" "$CASE/download" "$CASE/home" "$CASE/xs" "$CASE/work" "$CASE/payload"
cp -R "$ROOT/plugins/agent-guard" "$CASE/plugin"
GUARD="$CASE/plugin/bin/agent-guard"
PINS="$CASE/plugin/config/gitleaks-helper.sha256"
version=$(sed -n 's/^VERSION=//p' "$GUARD")
case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64) target=x86_64-unknown-linux-musl ;;
  Linux:aarch64|Linux:arm64) target=aarch64-unknown-linux-musl ;;
  Darwin:arm64) target=aarch64-apple-darwin ;;
  *) target= ;;
esac
asset="agent-guard-gitleaks-helper-$target.tar.gz"
PRIV="$CASE/priv"
INST="$PRIV/gitleaks-helper"
CALLS="$CASE/calls"
URLS="$CASE/urls"
: >"$CALLS"
: >"$URLS"

# The stand-in curl serves $CASE/download by the URL's file name and records
# every URL it was asked for.
cat >"$CASE/http-bin/curl" <<'HTTP'
#!/bin/sh
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; out=$1 ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$AG_INSTALL_URLS"
[ -f "$AG_INSTALL_DOWNLOAD/${url##*/}" ] || exit 22
cp "$AG_INSTALL_DOWNLOAD/${url##*/}" "$out"
HTTP
chmod 755 "$CASE/http-bin/curl"
if [ -n "$REAL_GITLEAKS" ]; then
  cp "$REAL_GITLEAKS" "$CASE/bin/gitleaks"
else
  cp "$ROOT/tests/fixtures/mock-gitleaks" "$CASE/bin/gitleaks"
fi
chmod +x "$CASE/bin/gitleaks"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/xs" PATH="$CASE/http-bin:$CASE/bin:$PATH"
export AGENT_GUARD_GITLEAKS_BIN_DIR="$PRIV" AGENT_GUARD_RELEASE_CHECK=off
export AG_INSTALL_URLS="$URLS" AG_INSTALL_DOWNLOAD="$CASE/download" AG_ROUTING_CALLS="$CALLS"
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_GITLEAKS_CONFIG AGENT_GUARD_LOG_MODE AGENT_GUARD_GITLEAKS_HELPER \
  AGENT_GUARD_INFRA_FAILURE_MODE AGENT_GUARD_GITLEAKS_HELPER_TRACE
setup() { "$GUARD" setup "$@" >"$CASE/s.out" 2>"$CASE/s.err"; echo "$?" >"$CASE/s.status"; }
status() { cat "$CASE/s.status"; }
pre() { jq -nc --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}'; }
hook() { # $1 command text, then VAR=value settings -> h.status
  ag_command=$1
  shift
  (cd "$CASE/work" && pre "$ag_command" | env AG_X=1 "$@" "$GUARD" hook-pre-tool >"$CASE/h.out" 2>"$CASE/h.err")
  echo "$?" >"$CASE/h.status"
}

if [ -z "$target" ]; then
  setup --install-gitleaks-helper
  expect "a platform without a released helper is refused and nothing is downloaded" \
    '[ "$(status)" != 0 ] && [ ! -s "$URLS" ] && [ ! -e "$INST" ]'
  printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

if [ -n "$REAL_DIR" ]; then
  # The released archive under the repository's own pins.
  [ -n "$REAL_GITLEAKS" ] || { echo 'the official gitleaks is required with released artifacts' >&2; exit 1; }
  cp "$REAL_DIR/$asset" "$CASE/download/$asset" || exit 1
else
  # A stand-in helper: the client records its arguments and runs gitleaks, as
  # the real client does when no helper answers.
  cat >"$CASE/payload/agent-guard-scan" <<'EOF'
#!/bin/sh
printf '%s|' "$@" >>"$AG_ROUTING_CALLS"
printf '\n' >>"$AG_ROUTING_CALLS"
gitleaks=$2
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$gitleaks" "$@"
EOF
  printf '#!/bin/sh\nexit 0\n' >"$CASE/payload/agent-guard-gitleaks-helper"
  chmod 755 "$CASE/payload/agent-guard-scan" "$CASE/payload/agent-guard-gitleaks-helper"
  (cd "$CASE/payload" && shasum -a 256 agent-guard-gitleaks-helper agent-guard-scan >SHA256SUMS) || exit 1
  awk -v target="$target" '{ print $1 "  " target "/" $2 }' "$CASE/payload/SHA256SUMS" >"$PINS"
  tar -C "$CASE/payload" -czf "$CASE/download/$asset" agent-guard-gitleaks-helper agent-guard-scan SHA256SUMS || exit 1
fi
cp "$CASE/download/$asset" "$CASE/good.tar.gz"

# Helper missing: nothing installed yet.
setup
expect "missing: setup reports the helper as not installed and names the command" \
  'grep -q "gitleaks helper  not installed" "$CASE/s.err" && grep -q "setup --install-gitleaks-helper" "$CASE/s.err"'
marker="AGENT_GUARD_TEST_""SECRET"
[ -z "$REAL_GITLEAKS" ] || marker="gh""p_$(printf 'a1B2c3D4e5F6g7H8i9J0a1B2c3D4e5F6g7H8')"
hook "echo $marker"
missing_status=$(cat "$CASE/h.status")
expect "missing: a secret command is denied by gitleaks alone" '[ "$missing_status" = 2 ] && [ ! -s "$CALLS" ]'

# A download that fails, or that does not match the pins, installs nothing.
mv "$CASE/download/$asset" "$CASE/download/held"
setup --install-gitleaks-helper
expect "a failed download installs nothing" '[ "$(status)" != 0 ] && [ ! -e "$INST" ]'
mkdir "$CASE/tampered"
tar -xzf "$CASE/good.tar.gz" -C "$CASE/tampered"
printf 'x' >>"$CASE/tampered/agent-guard-gitleaks-helper"
tar -C "$CASE/tampered" -czf "$CASE/download/$asset" agent-guard-gitleaks-helper agent-guard-scan SHA256SUMS
setup --install-gitleaks-helper
expect "a helper binary that differs from the pin installs nothing" \
  '[ "$(status)" != 0 ] && grep -qi "checksum" "$CASE/s.err" && [ ! -e "$INST" ]'
rm -rf "$CASE/tampered" && mkdir "$CASE/tampered"
tar -xzf "$CASE/good.tar.gz" -C "$CASE/tampered"
mv "$CASE/tampered/agent-guard-scan" "$CASE/tampered/real-scan"
ln -s real-scan "$CASE/tampered/agent-guard-scan"
tar -C "$CASE/tampered" -czf "$CASE/download/$asset" agent-guard-gitleaks-helper agent-guard-scan real-scan SHA256SUMS
setup --install-gitleaks-helper
expect "a symlinked member is refused even when its target matches the pin" '[ "$(status)" != 0 ] && [ ! -e "$INST" ]'
cp "$PINS" "$CASE/pins.keep"
grep -v "  $target/" "$CASE/pins.keep" >"$PINS"
: >"$URLS"
cp "$CASE/good.tar.gz" "$CASE/download/$asset"
setup --install-gitleaks-helper
expect "a CLI without pins for this platform refuses before any download" \
  '[ "$(status)" != 0 ] && [ ! -s "$URLS" ] && [ ! -e "$INST" ]'
cp "$CASE/pins.keep" "$PINS"

# The matching archive is installed, from this version's release.
: >"$URLS"
setup --install-gitleaks-helper
expect "the pinned helper is installed" '[ "$(status)" = 0 ] && [ -x "$INST/agent-guard-scan" ] && [ -x "$INST/agent-guard-gitleaks-helper" ]'
expect "the download is this version's release asset for this platform, and nothing else" \
  '[ "$(cat "$URLS")" = "https://github.com/JeongJaeSoon/agent-guard/releases/download/v$version/$asset" ]'
expect "the installed files are regular, private to the user's directory, and match their recorded sums" \
  '[ ! -L "$INST/agent-guard-scan" ] && [ ! -L "$INST/agent-guard-gitleaks-helper" ] \
   && [ "$(ls -ld "$INST" | cut -c1-10)" = drwx------ ] && (cd "$INST" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1)'
expect "setup then reports the helper as installed, with the condition for its use" \
  'grep -q "gitleaks helper  installed  (.*official gitleaks .* release build" "$CASE/s.err"'
# The status line reads files only: setup never runs the client, so a client
# that hangs or fails cannot stall setup or be reported as answering.
: >"$CALLS"
setup
expect "setup's status line does not run the client or start a helper" \
  '[ "$(status)" = 0 ] && [ ! -s "$CALLS" ] && [ -z "$(helper_pids)" ] && grep -q "gitleaks helper  installed" "$CASE/s.err"'

# On by default, off by the documented switch.
if [ -n "$REAL_GITLEAKS" ]; then
  TRACE="$CASE/trace"
  hook "echo $marker" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$TRACE"
  expect "on: the first scan runs gitleaks and starts the helper, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && grep -qx "spawned" "$TRACE" && grep -qx "real:cold" "$TRACE"'
  n=0
  while ! ls "$CASE/xs/agent-guard/gitleaks-helper"/*.sock >/dev/null 2>&1 && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  expect "on: exactly one helper is running" '[ "$(helper_pids | grep -c .)" = 1 ]'
  : >"$TRACE"
  hook "echo $marker again" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$TRACE"
  expect "on: the next scan is answered by the warm helper, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && [ "$(cat "$TRACE")" = helper ]'
  : >"$TRACE"
  hook "ls -la src" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$TRACE"
  expect "on: a clean command is allowed by the warm helper" '[ "$(cat "$CASE/h.status")" = 0 ] && [ "$(cat "$TRACE")" = helper ]'
  : >"$TRACE"
  hook "echo $marker off" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$TRACE" AGENT_GUARD_GITLEAKS_HELPER=off
  expect "off: AGENT_GUARD_GITLEAKS_HELPER=off runs gitleaks alone, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && [ ! -s "$TRACE" ]'
  rm "$INST/agent-guard-gitleaks-helper"
  : >"$TRACE"
  rm -f "$CASE/xs/agent-guard/gitleaks-helper"/*
  for pid in $(helper_pids); do kill "$pid" 2>/dev/null; done
  hook "echo $marker missing" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$TRACE"
  expect "missing: a client without its helper binary runs gitleaks, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && [ "$(cat "$TRACE")" = real:helper-missing ]'
else
  : >"$CALLS"
  hook "echo $marker"
  expect "on: with the variable unset the installed client gets the scan, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && grep -qF -- "--gitleaks|$CASE/bin/gitleaks|" "$CALLS"'
  : >"$CALLS"
  hook "echo $marker" AGENT_GUARD_GITLEAKS_HELPER=off
  expect "off: AGENT_GUARD_GITLEAKS_HELPER=off runs gitleaks alone, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && [ ! -s "$CALLS" ]'
  expect "off: setup reports the helper as off" \
    'AGENT_GUARD_GITLEAKS_HELPER=off "$GUARD" setup 2>&1 | grep -q "gitleaks helper  off"'
  # An explicit client that only fails, and one that would never return: the
  # status line names the path without running it.
  printf '#!/bin/sh\nprintf x >>"$AG_ROUTING_CALLS"\nexit 2\n' >"$CASE/failing-client"
  # exec keeps one process, whose ID the stand-in records for the cleanup below.
  printf '#!/bin/sh\nprintf x >>"$AG_ROUTING_CALLS"\necho "$$" >>"%s"\nexec sleep 600\n' "$CASE/client-pids" >"$CASE/hanging-client"
  : >"$CASE/client-pids"
  chmod 755 "$CASE/failing-client" "$CASE/hanging-client"
  for client in failing-client hanging-client; do
    : >"$CALLS"
    # In the background with a deadline: a setup that ran the hanging client
    # must fail this check, not stall the suite.
    AGENT_GUARD_GITLEAKS_HELPER="$CASE/$client" "$GUARD" setup >"$CASE/s.out" 2>"$CASE/s.err" &
    setup_pid=$!
    n=0
    while kill -0 "$setup_pid" 2>/dev/null && [ "$n" -lt 300 ]; do sleep 0.2; n=$((n + 1)); done
    returned=1
    if kill -0 "$setup_pid" 2>/dev/null; then
      returned=0
      # Stop what this test started, by process ID: setup, and the client it
      # ran (the stand-in records its own ID).
      kill "$setup_pid" 2>/dev/null
      while IFS= read -r client_pid; do kill "$client_pid" 2>/dev/null; done <"$CASE/client-pids"
    fi
    wait "$setup_pid" 2>/dev/null
    expect "setup with a $client returns without running it and does not call it answering" \
      '[ "$returned" = 1 ] && [ ! -s "$CALLS" ] \
       && grep -q "gitleaks helper  selected  (AGENT_GUARD_GITLEAKS_HELPER: $CASE/$client" "$CASE/s.err" \
       && ! grep -Eq "gitleaks helper  (on|installed)" "$CASE/s.err"'
  done
fi

# The private directory follows the gitleaks one: AGENT_GUARD_GITLEAKS_BIN_DIR,
# else AGENT_GUARD_BIN_DIR, else ~/.agent-guard/bin. With only the second set,
# the helper is installed under it, and found there.
if [ -z "$REAL_GITLEAKS" ]; then
  cp "$CASE/good.tar.gz" "$CASE/download/$asset"
  (
    unset AGENT_GUARD_GITLEAKS_BIN_DIR
    export AGENT_GUARD_BIN_DIR="$CASE/other-bin"
    "$GUARD" setup --install-gitleaks-helper >"$CASE/o.out" 2>"$CASE/o.err"
    echo "$?" >"$CASE/o.status"
    : >"$CALLS"
    (cd "$CASE/work" && pre "echo $marker" | "$GUARD" hook-pre-tool >/dev/null 2>&1)
    echo "$?" >"$CASE/o.hook"
  )
  expect "with only AGENT_GUARD_BIN_DIR set the helper is installed under it, not under the home directory" \
    '[ "$(cat "$CASE/o.status")" = 0 ] && [ -x "$CASE/other-bin/gitleaks-helper/agent-guard-scan" ] \
     && (cd "$CASE/other-bin/gitleaks-helper" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) \
     && [ ! -e "$CASE/home/.agent-guard/bin/gitleaks-helper" ]'
  expect "and scans use the helper installed there, with the same deny" \
    '[ "$(cat "$CASE/o.hook")" = "$missing_status" ] && grep -qF -- "--gitleaks|$CASE/bin/gitleaks|" "$CALLS"'
fi

# A later download that fails the pins leaves the installed helper as it was.
if [ -z "$REAL_GITLEAKS" ]; then
  before=$(cd "$INST" && shasum -a 256 agent-guard-scan agent-guard-gitleaks-helper SHA256SUMS)
  rm -rf "$CASE/tampered" && mkdir "$CASE/tampered"
  tar -xzf "$CASE/good.tar.gz" -C "$CASE/tampered"
  printf 'x' >>"$CASE/tampered/agent-guard-scan"
  tar -C "$CASE/tampered" -czf "$CASE/download/$asset" agent-guard-gitleaks-helper agent-guard-scan SHA256SUMS
  setup --install-gitleaks-helper
  expect "a failed reinstall keeps the working helper" \
    '[ "$(status)" != 0 ] && [ "$before" = "$(cd "$INST" && shasum -a 256 agent-guard-scan agent-guard-gitleaks-helper SHA256SUMS)" ]'
  "$GUARD" setup --help >"$CASE/help" 2>&1
  expect "setup --help documents the flag" 'grep -q -- "--install-gitleaks-helper" "$CASE/help"'
fi

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

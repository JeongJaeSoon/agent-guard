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
  for pid in $(pgrep -f "agent-guard-gitleaks-helper serve --state-dir $CASE/" 2>/dev/null); do kill "$pid" 2>/dev/null; done
  rm -rf "$CASE"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

mkdir -p "$CASE/bin" "$CASE/http-bin" "$CASE/download" "$CASE/home" "$CASE/xs" "$CASE/work" "$CASE/payload"
cp -R "$ROOT/plugins/agent-guard" "$CASE/plugin"
GUARD="$CASE/plugin/bin/agent-guard"
PINS="$CASE/plugin/config/gitleaks-helper.sha256"
OFFICIAL="$CASE/plugin/config/gitleaks-official.sha256"
version=$(sed -n 's/^VERSION=//p' "$GUARD")
glv=$(sed -n 's/^GITLEAKS_DEFAULT_VERSION=//p' "$GUARD")
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
# The stand-in gitleaks is the official release build only through this
# copy's pins; with the real one the repository's pins must name it.
if [ -z "$REAL_GITLEAKS" ] && [ -n "$target" ]; then
  printf '%s  %s/%s/gitleaks\n' "$(shasum -a 256 "$CASE/bin/gitleaks" | awk '{ print $1 }')" "$glv" "$target" >"$OFFICIAL"
fi
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

# The status line says why an installed helper will not answer, and what to
# do, from files, variables and the selected gitleaks's bytes. doctor prints
# the same line and starts, installs and creates nothing.
hl() { grep 'gitleaks helper  ' "$CASE/s.err"; }
doc() { "$GUARD" doctor "$@" >"$CASE/s.out" 2>"$CASE/s.err"; echo "$?" >"$CASE/s.status"; }
expect "the official build on PATH: the line says the helper answers it" \
  'hl | grep -qF "gitleaks helper  installed  (it answers the selected gitleaks $CASE/bin/gitleaks, the official gitleaks $glv release build)"'
# Deep state directories, around the client's 103-byte socket limit:
# <state>/agent-guard/gitleaks-helper/<20 hex digits>.sock.
deep_state() { # $1 = length of XDG_STATE_HOME; prints the directory
  ds=$CASE/d
  while [ "${#ds}" -lt "$1" ]; do ds="${ds}d"; done
  printf '%s' "$ds"
}
at_limit=$(deep_state 49)
over_limit=$(deep_state 50)
(XDG_STATE_HOME=$at_limit; setup)
expect "a state directory whose socket path is exactly 103 bytes keeps the helper" 'hl | grep -q "gitleaks helper  installed  (it answers"'
: >"$URLS"
: >"$CALLS"
(XDG_STATE_HOME=$over_limit; doc)
expect "one byte deeper: doctor says the socket path is too long and what to do, and creates nothing" \
  'hl | grep -qF "gitleaks helper  not used  (its socket path would be 104 bytes, over the 103-byte limit, under the state directory $over_limit/agent-guard; set XDG_STATE_HOME to a shorter directory)" \
   && [ ! -e "$over_limit" ] && [ ! -s "$URLS" ] && [ ! -s "$CALLS" ] && [ -z "$(helper_pids)" ]'
if [ -n "$REAL_GITLEAKS" ]; then
  # Ground truth: the client's own trace at the same two depths.
  : >"$CASE/trace"
  hook "ls -la src" XDG_STATE_HOME="$over_limit" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$CASE/trace"
  expect "ground truth: one byte over, the client runs gitleaks for the socket path" '[ "$(cat "$CASE/trace")" = real:socket-path ]'
  : >"$CASE/trace"
  hook "ls -la src" XDG_STATE_HOME="$at_limit" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$CASE/trace"
  expect "ground truth: at the limit, the client starts a helper" 'grep -qx spawned "$CASE/trace" && ! grep -q socket-path "$CASE/trace"'
fi
mkdir -p "$CASE/back\\slash"
cp "$CASE/bin/gitleaks" "$CASE/back\\slash/gitleaks"
(PATH="$CASE/back\\slash:$PATH"; doc)
expect "the official build in a directory whose name holds a backslash is still recognized" \
  'hl | grep -qF "gitleaks helper  installed  (it answers the selected gitleaks $CASE/back"'
(XDG_STATE_HOME=relative-state; doc)
expect "a state directory that is not a plain absolute path: not used, and what to do" \
  'hl | grep -qF "gitleaks helper  not used  (the state directory relative-state/agent-guard is not a plain absolute path (relative, or through a symbolic link); set XDG_STATE_HOME to one)"'
(AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks"; export AGENT_GUARD_GITLEAKS_BIN; setup)
expect "AGENT_GUARD_GITLEAKS_BIN: not used, and how to use the helper" \
  'hl | grep -qF "gitleaks helper  not used  (AGENT_GUARD_GITLEAKS_BIN selects the scanner, which the helper never serves; unset it to use the helper)"'
(AGENT_GUARD_LOG_MODE=off; export AGENT_GUARD_LOG_MODE; setup)
expect "AGENT_GUARD_LOG_MODE=off: not used, and how to use the helper" \
  'hl | grep -qF "gitleaks helper  not used  (AGENT_GUARD_LOG_MODE=off leaves it no state directory for its socket; unset it to use the helper)"'
cp "$INST/SHA256SUMS" "$CASE/sums.keep"
awk '{ printf "%064d  %s\n", 0, $2 }' "$CASE/sums.keep" >"$INST/SHA256SUMS"
doc
expect "recorded pins that differ: not used, and the command that fixes it" \
  'hl | grep -qF "gitleaks helper  not used  (installed for another Agent Guard version; run: " && hl | grep -q "setup --install-gitleaks-helper)"'
cp "$CASE/sums.keep" "$INST/SHA256SUMS"
cp "$OFFICIAL" "$CASE/official.keep"
if [ -n "$REAL_GITLEAKS" ]; then
  # The repository's pins must name the official build of this platform.
  expect "the repository pins the official gitleaks for this platform" 'grep -q "  $glv/$target/gitleaks\$" "$OFFICIAL"'
fi
# Another build of the same version: a script that runs the official one has
# no Go build information, so the client runs it for real (real:engine).
mkdir -p "$CASE/wrap-bin"
printf '#!/bin/sh\nexec %s "$@"\n' "$CASE/bin/gitleaks" >"$CASE/wrap-bin/gitleaks"
chmod 755 "$CASE/wrap-bin/gitleaks"
(PATH="$CASE/wrap-bin:$PATH"; doc)
expect "a gitleaks on PATH that is not the official build: doctor says not used, why, and what to do" \
  'hl | grep -qF "gitleaks helper  not used  (the selected gitleaks $CASE/wrap-bin/gitleaks is not the official gitleaks $glv release build, such as a Homebrew or go install build; to use the helper, install the official build, which is used before PATH: run " \
   && hl | grep -q "checksum and the setup --install command it prints)"'
if [ -n "$REAL_GITLEAKS" ]; then
  : >"$CASE/trace"
  (PATH="$CASE/wrap-bin:$PATH"; export PATH; hook "ls -la src" AGENT_GUARD_GITLEAKS_HELPER_TRACE="$CASE/trace")
  expect "ground truth: the client runs that gitleaks for real (real:engine)" '[ "$(cat "$CASE/trace")" = real:engine ]'
fi
printf '#!/bin/sh\ncase "$1" in version) echo 8.30.0 ;; esac\nexit 0\n' >"$CASE/wrap-bin/gitleaks"
(PATH="$CASE/wrap-bin:$PATH"; setup)
expect "another gitleaks version: not used, naming the version" \
  'hl | grep -qF "gitleaks helper  not used  (the selected gitleaks $CASE/wrap-bin/gitleaks is version 8.30.0, and the helper answers only gitleaks $glv; to use the helper, install the official build"'
mkdir -p "$PRIV"
cp "$CASE/wrap-bin/gitleaks" "$PRIV/gitleaks"
setup
expect "a private gitleaks that is not the official build: the advice replaces it, since setup --install keeps it" \
  'hl | grep -qF "gitleaks helper  not used  (the selected gitleaks $PRIV/gitleaks is version 8.30.0, and the helper answers only gitleaks $glv; to use the helper, remove $PRIV/gitleaks, then run "'
rm -f "$PRIV/gitleaks"
mv "$INST" "$CASE/inst.keep"
(PATH="$CASE/wrap-bin:$PATH"; doc)
expect "no helper and a gitleaks it would not answer: the line does not suggest installing it" \
  'hl | grep -qF "gitleaks helper  not installed  (it would not answer: the selected gitleaks $CASE/wrap-bin/gitleaks is version 8.30.0" && ! hl | grep -q "optional"'
(AGENT_GUARD_GITLEAKS_BIN="$CASE/wrap-bin/gitleaks"; export AGENT_GUARD_GITLEAKS_BIN; doc)
expect "no helper and AGENT_GUARD_GITLEAKS_BIN: the line names the variable, not an install" \
  'hl | grep -qF "gitleaks helper  not installed  (AGENT_GUARD_GITLEAKS_BIN selects the scanner, which the helper never serves; unset it to use the helper)"'
doc
expect "no helper and the official build: the line suggests the helper" \
  'hl | grep -qF "gitleaks helper  not installed  (optional; keeps gitleaks loaded between scans: "'
mv "$CASE/inst.keep" "$INST"

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
# else ~/.agent-guard/bin. AGENT_GUARD_BIN_DIR is the installer's link
# directory; the CLI reads it as the gitleaks directory only while that is
# deprecated and only when a gitleaks is already in it (see
# tests/gitleaks-bin-dir-deprecation.sh). With it set and no gitleaks there,
# the helper goes to the home directory, with a notice, and is found there.
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
  expect "with only AGENT_GUARD_BIN_DIR set the helper is installed under the home directory, not under it, with a notice" \
    '[ "$(cat "$CASE/o.status")" = 0 ] && [ -x "$CASE/home/.agent-guard/bin/gitleaks-helper/agent-guard-scan" ] \
     && (cd "$CASE/home/.agent-guard/bin/gitleaks-helper" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) \
     && [ ! -e "$CASE/other-bin/gitleaks-helper" ] \
     && grep -qF "AGENT_GUARD_BIN_DIR no longer selects the gitleaks directory" "$CASE/o.err"'
  expect "and scans use the helper installed there, with the same deny" \
    '[ "$(cat "$CASE/o.hook")" = "$missing_status" ] && grep -qF -- "--gitleaks|$CASE/bin/gitleaks|" "$CALLS"'
  rm -rf "$CASE/home/.agent-guard/bin/gitleaks-helper"
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

# `setup --install` installs the helper too, when the gitleaks it manages is
# the one scans run: the private gitleaks at the version the helper links.
# Every branch below; the stand-in curl's URL record shows what was downloaded.
if [ -z "$REAL_GITLEAKS" ]; then
  cp "$CASE/good.tar.gz" "$CASE/download/$asset"
  mkdir -p "$CASE/tools" "$CASE/tmp" "$CASE/gl" "$CASE/path-gl" "$CASE/uname-bin"
  # No gitleaks on this PATH: only the tools the CLI and the stand-in curl use.
  for tool in sh dirname basename pwd jq git awk mktemp rm mkdir rmdir wc tr sleep head tail grep sed cat chmod uname shasum stat \
      tar gzip mv cp ln ls env date id sort uniq cut od tee expr touch find setsid perl; do
    tool_path=$(command -v "$tool" 2>/dev/null) || continue
    case "$tool_path" in /*) ln -s "$tool_path" "$CASE/tools/$tool" ;; esac
  done
  TOOLS_PATH="$CASE/http-bin:$CASE/tools"
  # The gitleaks release archive setup --install downloads, for this platform
  # and for one that has no helper asset.
  cp "$ROOT/tests/fixtures/mock-gitleaks" "$CASE/gl/gitleaks"
  chmod 755 "$CASE/gl/gitleaks"
  gl_version=$(sed -n 's/^GITLEAKS_DEFAULT_VERSION=//p' "$GUARD")
  gl_os=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$(uname -m)" in x86_64|amd64) gl_arch=x64 ;; *) gl_arch=arm64 ;; esac
  gl_archive="gitleaks_${gl_version}_${gl_os}_${gl_arch}.tar.gz"
  tar -C "$CASE/gl" -czf "$CASE/download/$gl_archive" gitleaks
  cp "$CASE/download/$gl_archive" "$CASE/download/gitleaks_${gl_version}_darwin_x64.tar.gz"
  gl_sum=$(shasum -a 256 "$CASE/download/$gl_archive" | awk '{ print $1 }')
  cp "$CASE/gl/gitleaks" "$CASE/path-gl/gitleaks"
  printf '#!/bin/sh\ncase "$1" in version) echo 8.30.0 ;; esac\nexit 0\n' >"$CASE/old-gitleaks"
  printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; *) echo Darwin ;; esac\n' >"$CASE/uname-bin/uname"
  chmod 755 "$CASE/old-gitleaks" "$CASE/uname-bin/uname"
  # $1 private directory, then VAR=value settings, then -- and setup's
  # arguments (default: --install with the gitleaks checksum).
  si() {
    si_priv=$1
    shift
    : >"$URLS"
    si_env=
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do si_env="$si_env $1"; shift; done
    [ "$#" -eq 0 ] || shift
    [ "$#" -gt 0 ] || set -- --install --gitleaks-checksum "$gl_sum"
    # shellcheck disable=SC2086 # settings without spaces, split on purpose
    env PATH="$TOOLS_PATH" TMPDIR="$CASE/tmp" AGENT_GUARD_GITLEAKS_BIN_DIR="$si_priv" $si_env \
      "$GUARD" setup "$@" >"$CASE/s.out" 2>"$CASE/s.err"
    echo "$?" >"$CASE/s.status"
  }
  urls() { grep -c . "$URLS"; }
  helper_url() { grep -c "/$asset\$" "$URLS"; }
  has_helper() { [ -x "$1/gitleaks-helper/agent-guard-scan" ] && (cd "$1/gitleaks-helper" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); }
  no_temp_left() { [ -z "$(ls -A "$CASE/tmp")" ]; }
  # A reason line: why setup --install did not install the helper.
  reason() { grep -c 'gitleaks helper  not installed  (.*\(the helper never serves\|not the official\|answers only\)' "$CASE/s.err"; }
  warned() { grep -c 'warning: the warm gitleaks helper was not installed' "$CASE/s.err"; }

  # Installed: no gitleaks anywhere, so gitleaks and then the helper.
  P="$CASE/p-installed"
  si "$P"
  expect "setup --install installs gitleaks and then the helper that matches the pins" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && has_helper "$P" && [ "$(urls)" = 2 ] \
     && [ "$(sed -n 1p "$URLS" | sed "s|.*/||")" = "$gl_archive" ] && [ "$(sed -n 2p "$URLS" | sed "s|.*/||")" = "$asset" ] \
     && [ "$(reason)" = 0 ] && [ "$(warned)" = 0 ] && no_temp_left'
  : >"$CALLS"
  hook "echo $marker" AGENT_GUARD_GITLEAKS_BIN_DIR="$P"
  expect "and scans then run through that helper with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && grep -qF -- "--gitleaks|" "$CALLS"'

  # Already installed: nothing is downloaded again.
  before=$(cd "$P/gitleaks-helper" && shasum -a 256 agent-guard-scan agent-guard-gitleaks-helper SHA256SUMS)
  si "$P" -- --install
  expect "with this version's helper already installed, setup --install makes no network call" \
    '[ "$(status)" = 0 ] && has_helper "$P" && [ "$(urls)" = 0 ] && [ "$(reason)" = 0 ] && [ "$(warned)" = 0 ] \
     && [ "$before" = "$(cd "$P/gitleaks-helper" && shasum -a 256 agent-guard-scan agent-guard-gitleaks-helper SHA256SUMS)" ]'

  # An existing user: the private gitleaks is there, the helper is not.
  P="$CASE/p-existing"
  mkdir -p "$P" && cp "$CASE/gl/gitleaks" "$P/gitleaks"
  si "$P" -- --install
  expect "rerunning setup --install with the private gitleaks already there downloads only the helper" \
    '[ "$(status)" = 0 ] && has_helper "$P" && [ "$(urls)" = 1 ] && [ "$(helper_url)" = 1 ] \
     && grep -q "gitleaks already available" "$CASE/s.err"'

  # Opted out, with the switch or with the user's own client selected.
  P="$CASE/p-off"
  si "$P" AGENT_GUARD_GITLEAKS_HELPER=off
  expect "AGENT_GUARD_GITLEAKS_HELPER=off at install time installs gitleaks and no helper, without a download" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(urls)" = 1 ] \
     && [ "$(helper_url)" = 0 ] && [ "$(reason)" = 0 ] && [ "$(warned)" = 0 ]'
  P="$CASE/p-own"
  si "$P" AGENT_GUARD_GITLEAKS_HELPER="$CASE/payload/agent-guard-scan"
  expect "a selected client of the user's own is left alone too" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(helper_url)" = 0 ]'

  # Download failure: gitleaks is installed, setup succeeds and says so.
  P="$CASE/p-download"
  mv "$CASE/download/$asset" "$CASE/download/held"
  si "$P"
  expect "a helper download failure leaves gitleaks installed, warns and does not fail setup" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(helper_url)" = 1 ] \
     && [ "$(warned)" = 1 ] && grep -q "setup --install-gitleaks-helper" "$CASE/s.err" && no_temp_left'
  : >"$CALLS"
  hook "echo $marker" AGENT_GUARD_GITLEAKS_BIN_DIR="$P"
  expect "and scans run gitleaks alone, with the same deny" '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && [ ! -s "$CALLS" ]'
  mv "$CASE/download/held" "$CASE/download/$asset"

  # Checksum mismatch: the same, and nothing of the download is kept.
  P="$CASE/p-checksum"
  rm -rf "$CASE/tampered" && mkdir "$CASE/tampered"
  tar -xzf "$CASE/good.tar.gz" -C "$CASE/tampered"
  printf 'x' >>"$CASE/tampered/agent-guard-scan"
  tar -C "$CASE/tampered" -czf "$CASE/download/$asset" agent-guard-gitleaks-helper agent-guard-scan SHA256SUMS
  si "$P"
  expect "a helper that does not match the pins is not installed; gitleaks is, and setup does not fail" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(warned)" = 1 ] \
     && grep -q "checksum verification failed" "$CASE/s.err" && no_temp_left \
     && [ -z "$(find "$P" -name ".gitleaks-helper.*")" ]'
  cp "$CASE/good.tar.gz" "$CASE/download/$asset"

  # A signal during the helper download: the step still removes its own
  # temporary directory, and setup goes on without the helper.
  P="$CASE/p-signal"
  mkdir -p "$CASE/term-bin"
  cat >"$CASE/term-bin/curl" <<'HTTP'
#!/bin/sh
case "$*" in
  *agent-guard-gitleaks-helper-*)
    printf '%s\n' "signal" >>"$AG_INSTALL_URLS"
    kill -TERM "$PPID"
    sleep 1
    exit 22
    ;;
esac
exec "$AG_INSTALL_CURL" "$@"
HTTP
  chmod 755 "$CASE/term-bin/curl"
  TOOLS_PATH="$CASE/term-bin:$CASE/http-bin:$CASE/tools"
  si "$P" AG_INSTALL_CURL="$CASE/http-bin/curl"
  sleep 2
  expect "a helper download ended by a signal leaves no temporary directory, and setup still succeeds" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && grep -qx signal "$URLS" \
     && [ "$(warned)" = 1 ] && no_temp_left'
  TOOLS_PATH="$CASE/http-bin:$CASE/tools"

  # No asset for this platform: quiet.
  P="$CASE/p-platform"
  TOOLS_PATH="$CASE/uname-bin:$CASE/http-bin:$CASE/tools"
  si "$P"
  expect "on a platform without a released helper setup --install installs gitleaks and says nothing more" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(urls)" = 1 ] \
     && [ "$(sed -n 1p "$URLS" | sed "s|.*/||")" = "gitleaks_${gl_version}_darwin_x64.tar.gz" ] && [ "$(reason)" = 0 ] && [ "$(warned)" = 0 ]'
  TOOLS_PATH="$CASE/http-bin:$CASE/tools"

  # The official build on PATH is answered by the helper, so setup --install
  # installs the helper for it, as --install-gitleaks-helper does.
  P="$CASE/p-path"
  TOOLS_PATH="$CASE/path-gl:$CASE/http-bin:$CASE/tools"
  si "$P" -- --install
  expect "the official gitleaks on PATH gets the helper from setup --install" \
    '[ "$(status)" = 0 ] && has_helper "$P" && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 1 ] && [ "$(helper_url)" = 1 ] \
     && [ "$(reason)" = 0 ] && [ "$(warned)" = 0 ]'
  # Any other gitleaks is not answered: one line says why and what to do,
  # nothing is downloaded, and setup does not fail.
  P="$CASE/p-path-other"
  printf '\n# another build\n' >>"$CASE/path-gl/gitleaks"
  si "$P" -- --install
  expect "a gitleaks on PATH that is not the official build gets one line naming the reason, and no download" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(urls)" = 0 ] && [ "$(reason)" = 1 ] && [ "$(warned)" = 0 ] \
     && grep "gitleaks helper  not installed" "$CASE/s.err" | grep -q "not the official gitleaks $glv release build" \
     && grep "gitleaks helper  not installed" "$CASE/s.err" | grep -q "used before PATH"'
  # Asked for with setup --install and a checksum, the official build goes to
  # the private directory, which is selected before PATH, with one line that
  # says so and how to go back; then the helper is installed for it.
  P="$CASE/p-path-replace"
  path_gl_before=$(shasum -a 256 "$CASE/path-gl/gitleaks")
  si "$P"
  expect "setup --install with a checksum puts the official build in the private directory beside the PATH build, says so and how to go back" \
    '[ "$(status)" = 0 ] && cmp -s "$P/gitleaks" "$CASE/gl/gitleaks" && has_helper "$P" \
     && [ "$(sed -n 1p "$URLS" | sed "s|.*/||")" = "$gl_archive" ] && [ "$(helper_url)" = 1 ] \
     && grep -qF "hook scans now use the official gitleaks $glv in $P/gitleaks instead of $CASE/path-gl/gitleaks; to go back, remove $P/gitleaks or set AGENT_GUARD_GITLEAKS_BIN=$CASE/path-gl/gitleaks" "$CASE/s.err" \
     && [ "$path_gl_before" = "$(shasum -a 256 "$CASE/path-gl/gitleaks")" ] && no_temp_left'
  : >"$CALLS"
  hook "echo $marker" AGENT_GUARD_GITLEAKS_BIN_DIR="$P" PATH="$CASE/path-gl:$PATH"
  expect "and hook scans then run the official build through the helper, with the same deny" \
    '[ "$(cat "$CASE/h.status")" = "$missing_status" ] && grep -qF -- "--gitleaks|$P/gitleaks|" "$CALLS"'
  # Never from doctor, which only passes install arguments on while they are
  # deprecated: it installs nothing in place of a working gitleaks.
  P="$CASE/p-path-doctor"
  : >"$URLS"
  env PATH="$TOOLS_PATH" TMPDIR="$CASE/tmp" AGENT_GUARD_GITLEAKS_BIN_DIR="$P" \
    "$GUARD" doctor --install --gitleaks-checksum "$gl_sum" >"$CASE/s.out" 2>"$CASE/s.err"
  expect "doctor with install arguments does not replace the PATH build" \
    '[ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ] && grep -q "gitleaks already available" "$CASE/s.err"'
  # The helper turned off: the PATH build stays.
  P="$CASE/p-path-off"
  si "$P" AGENT_GUARD_GITLEAKS_HELPER=off
  expect "with AGENT_GUARD_GITLEAKS_HELPER=off setup --install keeps the PATH build" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ] && grep -q "gitleaks already available" "$CASE/s.err"'
  # A non-official gitleaks already in the private directory is never
  # overwritten; the advice is to remove it first.
  P="$CASE/p-private-other"
  mkdir -p "$P" && cp "$CASE/path-gl/gitleaks" "$P/gitleaks"
  si "$P"
  expect "a non-official private gitleaks is kept, with advice to remove it and rerun" \
    '[ "$(status)" = 0 ] && cmp -s "$P/gitleaks" "$CASE/path-gl/gitleaks" && [ "$(urls)" = 0 ] && [ ! -e "$P/gitleaks-helper" ] \
     && grep "gitleaks helper  not installed" "$CASE/s.err" | grep -qF "remove $P/gitleaks, then run"'
  # A replacement that does not run is removed again, so the working PATH
  # build stays selected; setup fails and says so.
  P="$CASE/p-path-broken"
  cp "$CASE/download/$gl_archive" "$CASE/gl-archive.keep"
  mkdir -p "$CASE/broken-gl"
  printf '#!/bin/sh\nexit 3\n' >"$CASE/broken-gl/gitleaks"
  chmod 755 "$CASE/broken-gl/gitleaks"
  tar -C "$CASE/broken-gl" -czf "$CASE/download/$gl_archive" gitleaks
  broken_sum=$(shasum -a 256 "$CASE/download/$gl_archive" | awk '{ print $1 }')
  # Pinned as official, so it is the probe that refuses it.
  cp "$OFFICIAL" "$CASE/official.held"
  printf '%s  %s/%s/gitleaks\n' "$(shasum -a 256 "$CASE/broken-gl/gitleaks" | awk '{ print $1 }')" "$glv" "$target" >"$OFFICIAL"
  si "$P" -- --install --gitleaks-checksum "$broken_sum"
  cp "$CASE/official.held" "$OFFICIAL"
  expect "a replacement that does not run is checked aside and never installed; the PATH build stays and setup fails saying so" \
    '[ "$(status)" != 0 ] && [ ! -e "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(helper_url)" = 0 ] \
     && grep -qF "the downloaded gitleaks does not run" "$CASE/s.err" \
     && grep -qF "the official gitleaks was not installed; hook scans keep using $CASE/path-gl/gitleaks" "$CASE/s.err" \
     && [ -z "$(find "$P" -name ".gitleaks.*")" ] && no_temp_left'
  # One that runs and matches the user's checksum but not the official build
  # is not installed either.
  P="$CASE/p-path-unofficial"
  printf '#!/bin/sh\n: >"%s"\nexec "%s" "$@"\n' "$CASE/unofficial-ran" "$CASE/gl/gitleaks" >"$CASE/broken-gl/gitleaks"
  chmod 755 "$CASE/broken-gl/gitleaks"
  tar -C "$CASE/broken-gl" -czf "$CASE/download/$gl_archive" gitleaks
  unofficial_sum=$(shasum -a 256 "$CASE/download/$gl_archive" | awk '{ print $1 }')
  si "$P" -- --install --gitleaks-checksum "$unofficial_sum"
  expect "a downloaded gitleaks that is not the official build is not installed; the PATH build stays" \
    '[ "$(status)" != 0 ] && [ ! -e "$P/gitleaks" ] && grep -qF "the downloaded gitleaks is not the official gitleaks $glv release build" "$CASE/s.err" \
     && [ -z "$(find "$P" -name ".gitleaks.*")" ] && [ ! -e "$CASE/unofficial-ran" ]'
  cp "$CASE/gl-archive.keep" "$CASE/download/$gl_archive"
  # Another install that puts a gitleaks there meanwhile keeps it: the staged
  # one is linked to the name, never moved over it.
  P="$CASE/p-path-race"
  mkdir -p "$CASE/race-bin"
  printf '#!/bin/sh\n"%s" "$@" || exit\nmkdir -p "%s" && printf "#!/bin/sh\\n# theirs\\n" >"%s/gitleaks"\n' \
    "$CASE/http-bin/curl" "$P" "$P" >"$CASE/race-bin/curl"
  chmod 755 "$CASE/race-bin/curl"
  TOOLS_PATH="$CASE/race-bin:$CASE/path-gl:$CASE/http-bin:$CASE/tools"
  si "$P"
  TOOLS_PATH="$CASE/path-gl:$CASE/http-bin:$CASE/tools"
  expect "a gitleaks another install puts in the private directory meanwhile is kept, and setup fails saying so" \
    '[ "$(status)" != 0 ] && grep -qx "# theirs" "$P/gitleaks" && [ ! -e "$P/gitleaks-helper" ] \
     && grep -qF "failed to install gitleaks at $P/gitleaks" "$CASE/s.err" \
     && [ -z "$(find "$P" -name ".gitleaks.*")" ] && no_temp_left'
  # Where the helper could not run anyway, the PATH build stays.
  P="$CASE/p-path-log-off"
  si "$P" AGENT_GUARD_LOG_MODE=off
  expect "with AGENT_GUARD_LOG_MODE=off setup --install keeps the PATH build" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ]'
  P="$CASE/p-path-open-state"
  mkdir -p "$CASE/open-state/agent-guard" && chmod 755 "$CASE/open-state/agent-guard"
  si "$P" XDG_STATE_HOME="$CASE/open-state"
  expect "with a state directory hooks would refuse (mode 0755) setup --install keeps the PATH build and says why" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ] \
     && grep -qF "the state directory $CASE/open-state/agent-guard is not private to you (a 0700 directory you own)" "$CASE/s.err"'
  P="$CASE/p-path-relative-state"
  si "$P" XDG_STATE_HOME=relative-state
  expect "with a state directory that is not a plain absolute path setup --install keeps the PATH build" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ]'
  # A private directory named through a symbolic link is still the private
  # directory: its gitleaks is kept, and the advice is to remove it.
  P="$CASE/p-private-link"
  mkdir -p "$CASE/p-private-real" && cp "$CASE/path-gl/gitleaks" "$CASE/p-private-real/gitleaks"
  ln -s "$CASE/p-private-real" "$P"
  si "$P"
  expect "a private gitleaks reached through a symbolic link gets the remove advice and is kept" \
    '[ "$(status)" = 0 ] && cmp -s "$CASE/p-private-real/gitleaks" "$CASE/path-gl/gitleaks" && [ "$(urls)" = 0 ] \
     && grep "gitleaks helper  not installed" "$CASE/s.err" | grep -q "to use the helper, remove "'
  # No pin for this platform and version: the build cannot be checked, so
  # nothing is replaced.
  P="$CASE/p-path-no-pin"
  cp "$OFFICIAL" "$CASE/official.held"
  printf '%064d  %s/riscv64-unknown-linux-musl/gitleaks\n' 0 "$glv" >"$OFFICIAL"
  si "$P"
  expect "without a pin for this platform setup --install keeps the PATH build" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ] && ! grep -q "not the official" "$CASE/s.err"'
  cp "$CASE/official.held" "$OFFICIAL"
  # No helper for this platform: nothing to gain, so the PATH build stays.
  P="$CASE/p-path-platform"
  mkdir -p "$CASE/path-old"
  cp "$CASE/old-gitleaks" "$CASE/path-old/gitleaks"
  TOOLS_PATH="$CASE/uname-bin:$CASE/path-old:$CASE/http-bin:$CASE/tools"
  si "$P"
  expect "on a platform without a helper release setup --install keeps the PATH build" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ] && grep -q "gitleaks already available" "$CASE/s.err"'
  TOOLS_PATH="$CASE/path-gl:$CASE/http-bin:$CASE/tools"
  # Another version asked for: the helper would not answer it either, so the
  # PATH build stays.
  P="$CASE/p-path-version"
  si "$P" -- --install --gitleaks-checksum "$gl_sum" --gitleaks-version 8.30.0
  expect "setup --install for another gitleaks version keeps the PATH build" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks" ] && [ "$(urls)" = 0 ]'
  cp "$CASE/gl/gitleaks" "$CASE/path-gl/gitleaks"
  TOOLS_PATH="$CASE/http-bin:$CASE/tools"
  P="$CASE/p-explicit"
  mkdir -p "$P" && cp "$CASE/gl/gitleaks" "$P/gitleaks"
  si "$P" AGENT_GUARD_GITLEAKS_BIN="$CASE/path-gl/gitleaks" -- --install
  expect "a scanner selected with AGENT_GUARD_GITLEAKS_BIN gets one line naming that variable, and no download" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(urls)" = 0 ] && [ "$(reason)" = 1 ] \
     && grep "gitleaks helper  not installed" "$CASE/s.err" | grep -q "AGENT_GUARD_GITLEAKS_BIN"'
  P="$CASE/p-version"
  mkdir -p "$P" && cp "$CASE/old-gitleaks" "$P/gitleaks"
  si "$P" -- --install
  expect "a private gitleaks of another version gets one line naming the version, and no download" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(urls)" = 0 ] && [ "$(reason)" = 1 ] \
     && grep "gitleaks helper  not installed" "$CASE/s.err" | grep -q "8.30.0"'

  # A gitleaks this cannot check (here: no pins for the official build) gets
  # no helper from setup --install, with one line naming the command that
  # installs it anyway.
  P="$CASE/p-unknown"
  mv "$OFFICIAL" "$CASE/official.held"
  TOOLS_PATH="$CASE/path-gl:$CASE/http-bin:$CASE/tools"
  si "$P" -- --install
  expect "a gitleaks that cannot be checked gets no helper download, and one line with the command for it" \
    '[ "$(status)" = 0 ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(urls)" = 0 ] \
     && grep "gitleaks helper  not installed  (could not tell whether" "$CASE/s.err" | grep -q "setup --install-gitleaks-helper)"'
  TOOLS_PATH="$CASE/http-bin:$CASE/tools"
  mv "$CASE/official.held" "$OFFICIAL"

  # Both flags: the explicit install stays strict and the helper is fetched once.
  P="$CASE/p-both"
  si "$P" -- --install --gitleaks-checksum "$gl_sum" --install-gitleaks-helper
  expect "with both flags the helper is downloaded once" \
    '[ "$(status)" = 0 ] && [ -x "$P/gitleaks" ] && has_helper "$P" && [ "$(helper_url)" = 1 ] && [ "$(urls)" = 2 ]'
  # Control: a gitleaks that fails its checksum still fails setup, before any helper download.
  P="$CASE/p-gitleaks-bad"
  si "$P" -- --install --gitleaks-checksum 0000000000000000000000000000000000000000000000000000000000000000
  expect "a gitleaks download that fails its checksum still fails setup, and no helper is fetched" \
    '[ "$(status)" != 0 ] && [ ! -e "$P/gitleaks" ] && [ ! -e "$P/gitleaks-helper" ] && [ "$(helper_url)" = 0 ]'
  "$GUARD" setup --help >"$CASE/help" 2>&1
  expect "setup --help says that --install installs the helper and how to opt out" \
    'grep -q "also installs the warm gitleaks helper" "$CASE/help" && grep -q "AGENT_GUARD_GITLEAKS_HELPER=off" "$CASE/help"'
fi

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

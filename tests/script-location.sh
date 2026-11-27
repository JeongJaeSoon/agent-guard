#!/bin/sh
# The CLI must select its own payload through regular and linked entrypoints.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/payload with spaces/bin" "$CASE/payload with spaces/scripts" "$CASE/links" "$CASE/tools"
cp "$ROOT/plugins/agent-guard/bin/agent-guard" "$CASE/payload with spaces/bin/agent-guard"
cat >"$CASE/payload with spaces/scripts/gitleaks-checksum.sh" <<'MARKER'
#!/bin/sh
test "$#" -eq 1 && test "$1" = location-contract || exit 2
# What the CLI runs inherits descriptor 9 only when the caller opened it.
if [ -n "${LOCATION_CONTRACT_FD9:-}" ]; then echo seen >&9; else test ! -e /dev/fd/9 || exit 3; fi
printf 'selected expected payload\n'
MARKER
ln -s "$CASE/payload with spaces/bin/agent-guard" "$CASE/links/absolute"
ln -s '../payload with spaces/bin/agent-guard' "$CASE/links/relative"
ln -s relative "$CASE/links/chain"
ln -s "$CASE/payload with spaces" "$CASE/parent-link"
ln -s missing "$CASE/links/broken"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
count=0
check() {
  "$@" checksum location-contract 9<&- >"$CASE/out"
  test "$(cat "$CASE/out")" = 'selected expected payload'
  count=$((count + 1))
  printf 'ok - script location contract %s\n' "$count"
}
check "$CASE/payload with spaces/bin/agent-guard"
check "$CASE/links/absolute"
check "$CASE/links/relative"
check "$CASE/links/chain"
check "$CASE/parent-link/bin/agent-guard"
cd "$CASE"
check './payload with spaces/bin/agent-guard'
check env PATH="$CASE/payload with spaces/bin:$PATH" agent-guard
if sh "$CASE/links/broken" checksum location-contract >"$CASE/out" 2>"$CASE/err"; then
  echo 'broken executable link unexpectedly succeeded' >&2
  exit 1
fi
count=$((count + 1))
printf 'ok - script location contract %s\n' "$count"
# Without a slash in its own name the CLI is found as the shell found it.
(cd "$CASE/payload with spaces/bin" && check sh agent-guard)
count=$((count + 1))

# bash acting as sh runs this script several times slower than dash. Started
# that way, the CLI hands itself to a system dash; every entry point reaches
# that: the file itself, a link to it (the bootstrap install), a PATH lookup
# and a wrapper script (the Homebrew install). An explicit bash stays bash, a
# shell given options of its own keeps them, and where sh is not bash nothing
# changes.
want=sh
if sh -c 'case ${BASH:-} in */sh) exit 0 ;; esac; exit 1'; then
  for candidate in /bin/dash /usr/bin/dash; do
    if [ -x "$candidate" ]; then want=dash; break; fi
  done
fi
printf '%s\n' '#!/bin/sh' 'exec "$AG_TEST_PAYLOAD" "$@"' >"$CASE/tools/wrapper"
AG_TEST_PAYLOAD="$CASE/payload with spaces/bin/agent-guard"
export AG_TEST_PAYLOAD
chmod 755 "$CASE/tools/wrapper"
mkfifo "$CASE/hold"
# interpreter EXPECTED COMMAND...: the program running the CLI while it waits
# for its input, by PID.
interpreter() {
  expected=$1
  shift
  # A sandbox can deny ps even for the test's own processes.
  if ! ps -o comm= -p "$$" >/dev/null 2>&1; then
    printf 'skip - %s: no process listing here\n' "$*"
    return 0
  fi
  "$@" hook-pre-tool <"$CASE/hold" >/dev/null 2>&1 &
  pid=$!
  exec 9>"$CASE/hold"
  seen=
  tries=0
  while [ "$tries" -lt 50 ]; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null) || name=
    name=${name##*/}
    # The same answer twice: a handover in progress is not the answer.
    if [ -n "$name" ] && [ "$name" = "$seen" ] && [ "$name" != env ]; then
      [ "$name" != "$expected" ] || break
    fi
    seen=$name
    tries=$((tries + 1))
    sleep 0.1
  done
  exec 9>&-
  wait "$pid" || :
  if [ "$name" != "$expected" ]; then
    printf 'not ok - %s runs under %s, expected %s\n' "$*" "$name" "$expected" >&2
    exit 1
  fi
  count=$((count + 1))
  printf 'ok - script location contract %s (%s)\n' "$count" "$name"
}
interpreter "$want" "$CASE/payload with spaces/bin/agent-guard"
interpreter "$want" sh "$CASE/payload with spaces/bin/agent-guard"
interpreter "$want" "$CASE/links/chain"
interpreter "$want" env PATH="$CASE/payload with spaces/bin:$PATH" agent-guard
interpreter "$want" "$CASE/tools/wrapper"
# Options given to the shell stay with the shell they were given to.
interpreter sh sh -x "$CASE/payload with spaces/bin/agent-guard"
interpreter sh sh -e "$CASE/payload with spaces/bin/agent-guard"
if [ "$want" = dash ]; then
  # A bash option that is not in SHELLOPTS: only bash takes -O.
  interpreter sh sh -O nocasematch "$CASE/payload with spaces/bin/agent-guard"
fi
# The caller's descriptor 9 reaches what the CLI runs: it is not taken over.
# Not with the handover's own mark in the environment either: only the dash
# that the handover started closes the descriptor.
for mark in '' AG_SCRIPT_PID=1 AG_SCRIPT_FD=9; do
  : >"$CASE/fd9"
  env LOCATION_CONTRACT_FD9=1 ${mark:+"$mark"} "$CASE/payload with spaces/bin/agent-guard" checksum location-contract 9>"$CASE/fd9" >"$CASE/out"
  test "$(cat "$CASE/out")" = 'selected expected payload'
  test "$(cat "$CASE/fd9")" = seen
  count=$((count + 1))
  printf 'ok - script location contract %s (descriptor 9 is the caller'"'"'s%s)\n' "$count" "${mark:+, $mark set}"
done
# A path that names another file by the time the handover looks: the shell
# that already reads the first file keeps running it.
mkdir -p "$CASE/swap/bin" "$CASE/swap/scripts"
cp "$CASE/payload with spaces/scripts/gitleaks-checksum.sh" "$CASE/swap/scripts/gitleaks-checksum.sh"
awk 'NR == 2 { print; print "mv \"$0.next\" \"$0\""; next } { print }' "$ROOT/plugins/agent-guard/bin/agent-guard" >"$CASE/swap/bin/agent-guard"
printf '%s\n' '#!/bin/sh' 'echo replaced' >"$CASE/swap/bin/agent-guard.next"
chmod 755 "$CASE/swap/bin/agent-guard" "$CASE/swap/bin/agent-guard.next"
check "$CASE/swap/bin/agent-guard"
# A login shell reads profile files whose unexported settings die with a
# handover: it stays the shell it is.
interpreter sh env HOME="$CASE" sh -l "$CASE/payload with spaces/bin/agent-guard"
if [ "$want" = dash ]; then
  # A script named by a descriptor is not reopened from its first byte.
  ln -s /dev/fd/7 "$CASE/links/descriptor"
  for alias in /dev/fd/7 ./dev/fd/7 fd/7 "$CASE/links/descriptor"; do
    case $alias in
      ./dev/fd/7) dir=/ ;;
      fd/7) dir=/dev ;;
      *) dir=$CASE ;;
    esac
    (cd "$dir" && sh "$alias" version 7<"$CASE/payload with spaces/bin/agent-guard") >"$CASE/out"
    grep -q '^agent-guard [0-9]' "$CASE/out"
    count=$((count + 1))
    printf 'ok - script location contract %s (named by a descriptor: %s)\n' "$count" "$alias"
  done
  # A named pipe cannot be opened a second time: the handover would wait for
  # a second writer that never comes.
  mkfifo "$CASE/script-fifo"
  cat "$CASE/payload with spaces/bin/agent-guard" >"$CASE/script-fifo" &
  sh "$CASE/script-fifo" version >"$CASE/out" 2>&1 &
  reader=$!
  tries=0
  while kill -0 "$reader" 2>/dev/null && [ "$tries" -lt 50 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  if kill -0 "$reader" 2>/dev/null; then
    kill "$reader" 2>/dev/null || :
    printf 'not ok - a script read from a named pipe hangs\n' >&2
    exit 1
  fi
  wait "$reader" || :
  grep -q '^agent-guard [0-9]' "$CASE/out"
  count=$((count + 1))
  printf 'ok - script location contract %s (named pipe)\n' "$count"
  # Read from standard input, the script's own name is the shell's.
  sh -s -- version <"$CASE/payload with spaces/bin/agent-guard" >"$CASE/out"
  grep -q '^agent-guard [0-9]' "$CASE/out"
  count=$((count + 1))
  printf 'ok - script location contract %s (read from standard input)\n' "$count"
fi
# A relative path that starts with a hyphen is a path, not shell options.
mkdir -p "$CASE/-payload/bin" "$CASE/-payload/scripts"
cp "$CASE/payload with spaces/bin/agent-guard" "$CASE/-payload/bin/agent-guard"
cp "$CASE/payload with spaces/scripts/gitleaks-checksum.sh" "$CASE/-payload/scripts/gitleaks-checksum.sh"
(cd "$CASE" && check sh -- -payload/bin/agent-guard)
count=$((count + 1))
if bash_path=$(command -v bash 2>/dev/null) && [ "${bash_path##*/}" = bash ]; then
  interpreter bash "$bash_path" "$CASE/payload with spaces/bin/agent-guard"
fi
# exec resolves the command the way the shell that started the CLI does: a
# function bash exports reaches it only in bash.
if [ "$want" = dash ] && command -v bash >/dev/null 2>&1; then
  bash -c 'ag_fn() { echo function-ran; }; export -f ag_fn; sh "$1" exec -- ag_fn' _ \
    "$ROOT/plugins/agent-guard/bin/agent-guard" >"$CASE/out"
  test "$(cat "$CASE/out")" = function-ran
  count=$((count + 1))
  printf 'ok - script location contract %s (exec keeps the shell)\n' "$count"
fi
# The scanner report is bounded in bytes: dash counts the ulimit -f it sets in
# 512-byte blocks, so a report past 64 KiB is cut and the output is masked as
# an unreadable scan. A smaller one is read, and the output stays as it is.
if [ "$want" = dash ] || sh -c 'case ${BASH:-} in */sh) exit 1 ;; esac'; then
  {
    printf '%s\n' '#!/bin/sh' 'case "${1:-}" in version) echo 8.30.1-cap-test; exit 0 ;; stdin) ;; *) exit 2 ;; esac'
    printf '%s\n' 'shift; while [ "$#" -gt 0 ]; do case "$1" in --report-path) shift; report=$1 ;; esac; shift; done'
    printf '%s\n' 'cat >/dev/null; awk -v n="$AGENT_GUARD_TEST_REPORT_BYTES" "BEGIN { printf \"[\"; for (i = 2; i < n; i++) printf \" \"; printf \"]\" }" >"$report"; exit 0'
  } >"$CASE/tools/report-gitleaks"
  chmod 755 "$CASE/tools/report-gitleaks"
  mkdir -p "$CASE/home" "$CASE/state"
  for pad in 40000 80000; do
    printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"opaque.txt"},"tool_response":"opaque material with no heuristic token shape"}' \
      | HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_GITLEAKS_BIN="$CASE/tools/report-gitleaks" \
        AGENT_GUARD_TEST_REPORT_BYTES=$pad sh "$ROOT/plugins/agent-guard/bin/agent-guard" hook-post-tool >"$CASE/out" 2>/dev/null
    if [ "$pad" -lt 65536 ]; then
      if grep -q 'REDACTED' "$CASE/out"; then exit 1; fi
    else
      grep -q '"updatedToolOutput":"\[REDACTED\]"' "$CASE/out"
    fi
    count=$((count + 1))
    printf 'ok - script location contract %s (scanner report of %s bytes)\n' "$count" "$pad"
  done
fi
printf 'passed: %s script location contracts\n' "$count"

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
# The interpreter handover leaves nothing in the environment of what the CLI runs.
test -z "${AGENT_GUARD_SH_HANDOVER+set}" || exit 3
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
  "$@" checksum location-contract >"$CASE/out"
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
# and a wrapper script (the Homebrew install). An explicit bash stays bash,
# and where sh is not bash nothing changes.
want=sh
if sh -c 'case ${BASH:-} in */sh) exit 0 ;; esac; exit 1'; then
  for candidate in /bin/dash /usr/bin/dash; do
    if [ -x "$candidate" ]; then want=dash; break; fi
  done
fi
printf '%s\n' '#!/bin/sh' "exec '$CASE/payload with spaces/bin/agent-guard' \"\$@\"" >"$CASE/tools/wrapper"
chmod 755 "$CASE/tools/wrapper"
mkfifo "$CASE/hold"
# interpreter EXPECTED COMMAND...: the program running the CLI while it waits
# for its input, by PID.
interpreter() {
  expected=$1
  shift
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
# The marker of a finished handover: no second one, so a dash that is bash
# cannot loop.
interpreter sh env AGENT_GUARD_SH_HANDOVER=1 sh "$CASE/payload with spaces/bin/agent-guard"
if bash_path=$(command -v bash 2>/dev/null) && [ "${bash_path##*/}" = bash ]; then
  interpreter bash "$bash_path" "$CASE/payload with spaces/bin/agent-guard"
fi
printf 'passed: %s script location contracts\n' "$count"

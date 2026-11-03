#!/bin/sh
# Observe the real watchdog's waits, including cleanup after timer cancellation.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-watchdog.XXXXXX")
trap 'rm -rf "$CASE"' 0
REAL_SLEEP=$(command -v sleep)
export CASE REAL_SLEEP
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" \
  probe_gitleaks kill_gitleaks_probe_group select_gitleaks_probe_launcher
. "$CASE/probe_gitleaks.sh"
. "$CASE/kill_gitleaks_probe_group.sh"
. "$CASE/select_gitleaks_probe_launcher.sh"
mkdir "$CASE/bin"
cat >"$CASE/bin/sleep" <<'SLEEP'
#!/bin/sh
printf '%s\n' "$$" >"$CASE/timer-pid"
# Cancellation must remain bounded even if a timer inherits ignored SIGTERM.
trap '' TERM
exec "$REAL_SLEEP" "$@"
SLEEP
cat >"$CASE/scanner" <<'SCANNER'
#!/bin/sh
# Hold version completion until the watchdog has definitely started its child.
i=0
while [ ! -s "$CASE/timer-pid" ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || exit 3
  "$REAL_SLEEP" 0.01
done
printf '8.30.1\n'
exit "$SCANNER_STATUS"
SCANNER
chmod +x "$CASE/bin/sleep" "$CASE/scanner"
PATH="$CASE/bin:$PATH"
export PATH
# Keep filesystem/version policy outside this direct process-lifecycle test.
mktemp_gitleaks_probe_file() { GITLEAKS_PROBE_FILE="$CASE/$1"; : >"$GITLEAKS_PROBE_FILE"; }
remove_gitleaks_probe_file() { rm -f "$2"; }
semver_at_least() { return 0; }
wait() {
  printf '%s\n' "$1" >>"$CASE/waits"
  command wait "$@"
}
GITLEAKS_PROBE_TIMEOUT_SECONDS=10
GITLEAKS_PROBE_MAX_BYTES=8192
GITLEAKS_MIN_VERSION=8.30.1
pass=0 fail=0
for SCANNER_STATUS in 0 1; do
  export SCANNER_STATUS
  rm -f "$CASE/timer-pid"
  : >"$CASE/waits"
  status=0
  started=$(date +%s)
  probe_gitleaks "$CASE/scanner" || status=$?
  elapsed=$(($(date +%s) - started))
  timer_pid=$(cat "$CASE/timer-pid")
  waits=$(awk -v pid="$timer_pid" '$0 == pid { n++ } END { print n+0 }' "$CASE/waits")
  # One wait starts the timer; cancellation interrupts it. A second wait must
  # reap that child before the watchdog itself exits, independent of PID 1.
  if [ "$status" -eq "$SCANNER_STATUS" ] && [ "$waits" -eq 2 ] && [ "$elapsed" -lt 5 ]; then
    pass=$((pass + 1)); printf 'ok - watchdog reaps cancelled timer (scanner status %s)\n' "$SCANNER_STATUS"
  else
    fail=$((fail + 1)); printf 'not ok - watchdog timer waits=%s, scanner status=%s\n' "$waits" "$status"
  fi
done
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

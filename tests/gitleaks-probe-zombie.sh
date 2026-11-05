#!/bin/sh
# A stopped parent cannot reap a completed child. Preserve that child's exit
# status without extending the two-second deadline for a live version command.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${PROBE_ZOMBIE_SOURCE:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d)
guard_pid=
cleanup() {
  if [ -n "$guard_pid" ]; then
    kill -CONT "$guard_pid" 2>/dev/null || :
    kill -TERM "$guard_pid" 2>/dev/null || :
    wait "$guard_pid" 2>/dev/null || :
  fi
  rm -rf "$CASE"
}
trap cleanup 0
mkdir "$CASE/bad-bin"
printf '#!/bin/sh\ntouch "$PROBE_ZOMBIE_CASE/shadow-ps"\nsleep 5\nexit 1\n' >"$CASE/bad-bin/ps"
chmod +x "$CASE/bad-bin/ps"
# Simulate an absent system utility in a test-only copy, preserving its config.
mkdir -p "$CASE/unavailable-plugin/bin"
cp -R "$ROOT/plugins/agent-guard/config" "$CASE/unavailable-plugin/"
awk '{ sub("/bin/ps -o stat=", "/nonexistent-agent-guard-test/ps -o stat="); print }' \
  "$GUARD" >"$CASE/unavailable-plugin/bin/agent-guard"
chmod +x "$CASE/unavailable-plugin/bin/agent-guard"
cat >"$CASE/gitleaks" <<'SCANNER'
#!/bin/sh
[ "$1" = version ] || exit 9
printf '%s\n%s\n' "$PPID" "$$" >"$PROBE_ZOMBIE_CASE/parent"
while [ ! -f "$PROBE_ZOMBIE_CASE/release" ]; do sleep .01; done
case "$PROBE_ZOMBIE_MODE" in
  ready|unavailable) printf '8.30.1\n' ;;
  failed) exit 7 ;;
  slow) sleep 8; printf '8.30.1\n' ;;
esac
SCANNER
chmod +x "$CASE/gitleaks"
pass=0 fail=0
for mode in ready failed slow unavailable; do
  folder="$CASE/$mode"; mkdir "$folder"
  probe_path="$CASE/bad-bin:$PATH"
  probe_guard=$GUARD
  [ "$mode" != unavailable ] || probe_guard="$CASE/unavailable-plugin/bin/agent-guard"
  env PATH="$probe_path" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off \
    AGENT_GUARD_GITLEAKS_BIN="$CASE/gitleaks" PROBE_ZOMBIE_MODE="$mode" \
    PROBE_ZOMBIE_CASE="$folder" "$probe_guard" check >"$folder/out" 2>"$folder/err" &
  guard_pid=$!
  attempt=0
  while [ ! -s "$folder/parent" ] && [ "$attempt" -lt 100 ]; do
    sleep .1; attempt=$((attempt + 1))
  done
  { IFS= read -r parent && IFS= read -r probe_pid; } <"$folder/parent"
  printf "# controlled probe: guard=%s parent=%s child=%s mode=%s\n" "$guard_pid" "$parent" "$probe_pid" "$mode"
  [ "$parent" = "$guard_pid" ]
  kill -STOP "$guard_pid"
  touch "$folder/release"
  sleep .3
  observed=$(ps -o stat= -p "$probe_pid" 2>/dev/null) || observed=gone
  printf '# child state before deadline: %s\n' "$observed"
  if [ "$observed" = gone ]; then
    ! kill -0 "$probe_pid" 2>/dev/null
  fi
  case "$mode:$observed" in
    slow:*) ;;
    *:Z*|*:' '*Z*|*:gone) ;;
    *) printf 'not ok - expected completed zombie: %s (%s)\n' "$mode" "$observed"; exit 1 ;;
  esac
  sleep 2.2
  kill -CONT "$guard_pid"
  status=0; wait "$guard_pid" || status=$?
  guard_pid=
  valid=0
  case "$mode" in
    ready) if [ "$status" -eq 0 ]; then valid=1; fi ;;
    failed)
      if [ "$status" -ne 0 ] && grep -q 'command failed' "$folder/err" \
          && ! grep -q 'timed out' "$folder/err"; then valid=1; fi ;;
    unavailable)
      if [ "$observed" = gone ] && [ "$status" -eq 0 ]; then valid=1
      elif [ "$observed" != gone ] && [ "$status" -ne 0 ] \
          && grep -q 'timed out after 2s' "$folder/err"; then valid=1; fi ;;
    slow)
      if [ "$status" -ne 0 ] && grep -q 'timed out after 2s' "$folder/err"; then valid=1; fi ;;
  esac
  if [ "$valid" -eq 1 ] && [ ! -e "$folder/shadow-ps" ]; then
    pass=$((pass + 1)); printf 'ok - unreaped probe verdict: %s\n' "$mode"
  else
    fail=$((fail + 1)); printf 'not ok - unreaped probe verdict: %s\n' "$mode"
    cat "$folder/err"
  fi
done
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

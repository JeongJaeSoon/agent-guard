#!/bin/sh
# Deterministically delay the parent after it reaps a completed version child.
# The original two-second deadline still applies to a child that is running.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-probe-completion.XXXXXX")
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/plugin/bin" "$CASE/scanner"
cp -R "$ROOT/plugins/agent-guard/config" "$CASE/plugin/"
awk '
  /  wait "\$AG_GITLEAKS_PROBE_PID" 2>\/dev\/null$/ { waiting = 1 }
  { print }
  waiting && /^  ag_gl_probe_status=\$\?$/ {
    print "  sleep 3 # test-only parent scheduling delay, after wait/status"
    waiting = 0
    count++
  }
  END { if (count != 1) exit 1 }
' "${PROBE_COMPLETION_SOURCE:-$ROOT/plugins/agent-guard/bin/agent-guard}" >"$CASE/plugin/bin/agent-guard"
chmod +x "$CASE/plugin/bin/agent-guard"
cat >"$CASE/scanner/gitleaks" <<'SCANNER'
#!/bin/sh
case "${1:-}" in
  version)
    case "$PROBE_COMPLETION_MODE" in
      ready) printf '8.30.1\n'; exit 0 ;;
      failed) exit 7 ;;
      slow) sleep 8; printf '8.30.1\n'; exit 0 ;;
    esac ;;
esac
exit 9
SCANNER
chmod +x "$CASE/scanner/gitleaks"
pass=0
fail=0
for mode in ready failed slow; do
  status=0
  env AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off \
    AGENT_GUARD_GITLEAKS_BIN="$CASE/scanner/gitleaks" \
    PROBE_COMPLETION_MODE="$mode" \
    "$CASE/plugin/bin/agent-guard" check >"$CASE/out" 2>"$CASE/err" || status=$?
  valid=0
  case "$mode" in
    ready)
      if [ "$status" -eq 0 ] && ! grep -q 'timed out' "$CASE/err"; then valid=1; fi ;;
    failed)
      if [ "$status" -ne 0 ] && grep -q 'failed' "$CASE/err" \
          && ! grep -q 'timed out' "$CASE/err"; then valid=1; fi ;;
    slow)
      if [ "$status" -ne 0 ] && grep -q 'timed out' "$CASE/err"; then valid=1; fi ;;
  esac
  if [ "$valid" -eq 1 ]; then
    pass=$((pass + 1)); printf 'ok - completed probe status survives parent delay: %s\n' "$mode"
  else
    fail=$((fail + 1)); printf 'not ok - completed probe status survives parent delay: %s (status %s)\n' "$mode" "$status"
    cat "$CASE/err"
  fi
done
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

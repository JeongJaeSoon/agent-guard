#!/bin/sh
# Exercise raw-probe failures through exec with synthetic invalid-byte output.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-raw-probe.XXXXXX")
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/bin" "$CASE/home"
REAL_AWK=$(command -v awk)
export REAL_AWK HOME="$CASE/home"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_OUTPUT_REDACT=mask
export AGENT_GUARD_GITLEAKS_BIN="${RAW_PROBE_TEST_GITLEAKS:-$ROOT/tests/fixtures/mock-gitleaks}"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
unset AI_AGENT
printf '\377\n' >"$CASE/benign"
"$REAL_AWK" 'BEGIN { for (i=0; i<2560; i++) print "ordinary benign output line" }' >>"$CASE/benign"
cp "$CASE/benign" "$CASE/assignment"
printf '%s\n' 'DB_PASSWORD=raw-probe-synthetic-value' >>"$CASE/assignment"
cp "$CASE/benign" "$CASE/sanitized"
printf '%s\n' 'DB_PASSWORD=[REDACTED]' >>"$CASE/sanitized"
printf '%s\n' '[REDACTED]' >"$CASE/masked"
RAW_PROBE_CALLS="$CASE/calls" RAW_PROBE_INJECTIONS="$CASE/injections"
export RAW_PROBE_CALLS RAW_PROBE_INJECTIONS
cat >"$CASE/bin/awk" <<'SHIM'
#!/bin/sh
for arg do
  if [ "$arg" = record_mode=probe_raw ]; then
    printf '%s\n' "$RAW_PROBE_MODE" >>"$RAW_PROBE_CALLS"
    case "$RAW_PROBE_MODE" in
      fail|partial)
        cat >/dev/null
        printf '%s\n' "$RAW_PROBE_MODE" >>"$RAW_PROBE_INJECTIONS"
        [ "$RAW_PROBE_MODE" != partial ] || printf 'x\n'
        exit 23
        ;;
    esac
    break
  fi
done
exec "$REAL_AWK" "$@"
SHIM
chmod +x "$CASE/bin/awk"
PATH="$CASE/bin:$PATH"
export PATH
pass=0 fail=0
for mode in normal fail partial; do
  for kind in benign assignment sanitized; do
    # Normal sanitized output is an independent no-overmasking control.
    [ "$mode" = normal ] || [ "$kind" != sanitized ] || continue
    source_file="$CASE/$kind"
    bytes=$(LC_ALL=C wc -c <"$source_file" | tr -d ' ')
    [ "$bytes" -gt 65536 ] && [ "$bytes" -lt 327680 ]
    : >"$RAW_PROBE_CALLS"
    : >"$RAW_PROBE_INJECTIONS"
    status=0
    RAW_PROBE_MODE=$mode "$ROOT/plugins/agent-guard/bin/agent-guard" exec -- \
      sh -c 'cat "$1"; exit 7' fixture "$source_file" >"$CASE/out" 2>"$CASE/err" || status=$?
    expected="$CASE/masked"
    if [ "$mode" = normal ] && [ "$kind" != assignment ]; then expected=$source_file; fi
    injected=$(cat "$RAW_PROBE_INJECTIONS")
    want_injected=$mode
    [ "$mode" != normal ] || want_injected=
    if [ "$status" -eq 7 ] && cmp -s "$expected" "$CASE/out" \
       && ! LC_ALL=C grep -Fq "raw-probe-synthetic-value" "$CASE/err" \
       && [ "$(cat "$RAW_PROBE_CALLS")" = "$mode" ] \
       && [ "$injected" = "$want_injected" ]; then
      pass=$((pass+1))
      printf 'ok - exec raw probe %s %s preserves exit7 and output contract\n' "$mode" "$kind"
    else
      fail=$((fail+1))
      printf 'not ok - exec raw probe %s %s: status=%s bytes=%s calls=%s injections=%s\n' \
        "$mode" "$kind" "$status" "$(wc -c <"$CASE/out" | tr -d ' ')" \
        "$(cat "$RAW_PROBE_CALLS")" "$injected"
    fi
  done
done
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

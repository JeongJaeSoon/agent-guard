#!/bin/sh
# Bounded invalid-UTF-8 exec contracts; fixtures never reach an installed hook.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-exec-framing.XXXXXX")
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/bin" "$CASE/home"
REAL_AWK=$(command -v awk)
export REAL_AWK HOME="$CASE/home"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_OUTPUT_REDACT=mask
export AGENT_GUARD_GITLEAKS_BIN="${BOUNDARY_TEST_GITLEAKS:-$ROOT/tests/fixtures/mock-gitleaks}"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
unset AI_AGENT
BOUNDARY_CALLS="$CASE/calls" BOUNDARY_INJECTIONS="$CASE/injections"
export BOUNDARY_CALLS BOUNDARY_INJECTIONS
cat >"$CASE/bin/awk" <<'SHIM'
#!/bin/sh
stage=
for arg do
  case "$arg" in
    *'NR > 1 { emit_char("\n") }'*) stage=producer ;;
    record_mode=framed) stage=detector ;;
    record_mode=probe_raw) stage=raw ;;
  esac
done
if [ -n "$stage" ]; then
  printf '%s\n' "$stage" >>"$BOUNDARY_CALLS"
  if [ "$stage" = "${BOUNDARY_MODE%%-*}" ]; then
    cat >/dev/null
    printf '%s\n' "$BOUNDARY_MODE" >>"$BOUNDARY_INJECTIONS"
    case "$BOUNDARY_MODE" in
      producer-partial) printf 'ordinary partial output\036' ;;
      detector-partial) printf 'partial-secret\036' ;;
    esac
    exit 23
  fi
fi
exec "$REAL_AWK" "$@"
SHIM
chmod +x "$CASE/bin/awk"
PATH="$CASE/bin:$PATH"
export PATH
pass=0 fail=0
check() {
  size=$1 kind=$2 mode=$3 final_lfs=$4
  case "$kind" in
    benign) suffix='ordinary benign end' ;;
    assignment) suffix='DB_PASSWORD=boundary-synthetic-value' ;;
    sanitized) suffix='DB_PASSWORD=[REDACTED]' ;;
  esac
  # No terminal LF: source and captured sizes match exactly before extra LFs.
  printf '\377\n' >"$CASE/input"
  "$REAL_AWK" -v n="$((size - 3 - ${#suffix}))" 'BEGIN { for(i=1;i<=n;i++) printf (i%64 == 0 ? "\n" : "a") }' >>"$CASE/input"
  printf '\n%s' "$suffix" >>"$CASE/input"
  cp "$CASE/input" "$CASE/expected"
  if [ "$kind" = assignment ]; then
    if [ "$size" -gt 65536 ]; then
      printf '[REDACTED]' >"$CASE/expected"
    else
      # Independent literal replacement, with identical padding and byte prefix.
      LC_ALL=C sed 's/boundary-synthetic-value/[REDACTED]/' "$CASE/input" >"$CASE/expected"
      # sed appends a terminal LF on some hosts; capture strips it like exec.
      expected=$(cat "$CASE/expected")
      printf '%s' "$expected" >"$CASE/expected"
    fi
  fi
  if [ "$mode" != normal ]; then printf '[REDACTED]' >"$CASE/expected"; fi
  printf '\n' >>"$CASE/expected"
  i=0
  while [ "$i" -lt "$final_lfs" ]; do printf '\n' >>"$CASE/input"; i=$((i+1)); done
  bytes=$(LC_ALL=C wc -c <"$CASE/input" | tr -d ' ')
  [ "$bytes" -eq "$((size + final_lfs))" ]
  : >"$BOUNDARY_CALLS"; : >"$BOUNDARY_INJECTIONS"
  status=0
  BOUNDARY_MODE=$mode "$ROOT/plugins/agent-guard/bin/agent-guard" exec -- \
    sh -c 'cat "$1"; exit 7' fixture "$CASE/input" >"$CASE/out" 2>"$CASE/err" || status=$?
  if [ "$size" -gt 65536 ]; then
    expected_calls=raw
  elif [ "${mode%%-*}" = producer ]; then
    expected_calls=producer
  else
    expected_calls=$(printf 'producer\ndetector')
  fi
  injected=$mode
  [ "$mode" != normal ] || injected=
  if [ "$status" -eq 7 ] && cmp -s "$CASE/expected" "$CASE/out" \
    && ! LC_ALL=C grep -Fq "boundary-synthetic-value" "$CASE/err" \
    && [ "$(cat "$BOUNDARY_CALLS")" = "$expected_calls" ] \
    && [ "$(cat "$BOUNDARY_INJECTIONS")" = "$injected" ]; then
    pass=$((pass+1))
    printf 'ok - exec framing captured=%s final-LFs=%s %s %s preserves bytes and exit7\n' "$size" "$final_lfs" "$kind" "$mode"
  else
    fail=$((fail+1))
    output_matches=no injection_matches=no route_matches=no
    cmp -s "$CASE/expected" "$CASE/out" && output_matches=yes
    [ "$(cat "$BOUNDARY_INJECTIONS")" = "$injected" ] && injection_matches=yes
    [ "$(cat "$BOUNDARY_CALLS")" = "$expected_calls" ] && route_matches=yes
    printf 'not ok - exec framing captured=%s final-LFs=%s %s %s status=%s output=%s injection=%s route=%s\n' \
      "$size" "$final_lfs" "$kind" "$mode" "$status" "$output_matches" "$injection_matches" "$route_matches"
  fi
}
for size in 65535 65536 65537; do
  for kind in benign assignment sanitized; do check "$size" "$kind" normal 0; done
done
for mode in producer-empty producer-partial detector-empty detector-partial; do
  for kind in benign assignment sanitized; do check 65536 "$kind" "$mode" 0; done
done
# Command substitution removes all terminal LFs before choosing the size route.
for size in 65535 65536 65537; do check "$size" benign normal 2; done
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/bin/sh
# #537: the opt-in warm gitleaks helper. Needs the built client and helper
# (scripts/build-gitleaks-helper.sh) and the official gitleaks release:
#
#   AGENT_GUARD_TEST_HELPER_DIR=/abs/build AGENT_GUARD_TEST_REAL_GITLEAKS=/abs/gitleaks \
#     sh tests/gitleaks-helper.sh
#
# Every failure of the helper path must end in the real gitleaks (or, when
# that cannot run either, in the CLI's existing "could not scan" path), never
# in a clean verdict. Process-lifetime checks need an init that reaps
# orphans, so on Linux the script re-runs itself under tini when it can.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
if [ -z "${AG_HELPER_TEST_INIT:-}" ] && [ "$(uname -s)" = Linux ] && command -v tini >/dev/null 2>&1; then
  AG_HELPER_TEST_INIT=tini exec tini -s -- sh "$0" "$@"
fi
HELPER_DIR=${AGENT_GUARD_TEST_HELPER_DIR:?built helper directory required}
REAL=${AGENT_GUARD_TEST_REAL_GITLEAKS:?official gitleaks required}
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CFG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
# A socket path must fit sun_path (104 bytes on macOS), so not $TMPDIR.
CASE=$(mktemp -d /tmp/agh.XXXXXX) || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
STATE="$CASE/xs/agent-guard"
HDIR="$STATE/gitleaks-helper"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
# expect LABEL 'CONDITION': CONDITION is shell text, evaluated whole.
# Settings for one function call go in a subshell with export: macOS's sh
# (bash in POSIX mode) keeps a `VAR=value function` assignment afterwards.
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

helper_pids() { pgrep -f "agent-guard-gitleaks-helper serve --state-dir $STATE" 2>/dev/null; }
stop_helpers() {
  for pid in $(helper_pids); do kill "$pid" 2>/dev/null; done
  n=0
  while [ -n "$(helper_pids)" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  for pid in $(helper_pids); do kill -9 "$pid" 2>/dev/null; done
  [ -z "${FAKE_PID:-}" ] || { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; FAKE_PID=; }
}
cleanup() { stop_helpers; rm -rf "$CASE"; }
trap cleanup 0
trap 'exit 1' HUP INT TERM

mkdir -p "$CASE/bin" "$CASE/lib" "$CASE/empty" "$CASE/home" "$CASE/work" "$CASE/xs"
cp "$REAL" "$CASE/bin/gitleaks"
cp "$HELPER_DIR/agent-guard-scan" "$HELPER_DIR/agent-guard-gitleaks-helper" "$CASE/lib/"
CLIENT="$CASE/lib/agent-guard-scan"
GL="$CASE/bin/gitleaks"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/xs" PATH="$CASE/bin:$PATH"
export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/empty" AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS=60
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_GITLEAKS_CONFIG AGENT_GUARD_LOG_MODE AGENT_GUARD_GITLEAKS_HELPER
TRACE="$CASE/trace"
export AGENT_GUARD_GITLEAKS_HELPER_TRACE="$TRACE"
mkdir -p "$STATE" && chmod 700 "$CASE/xs" "$STATE"

# Synthetic secret-shaped inputs, assembled at run time so no literal sits in
# the repository. Each matches a default gitleaks rule.
fill() { printf '%s' "$2" | awk -v n="$1" '{ s = ""; while (length(s) < n) s = s $0; print substr(s, 1, n) }'; }
IN="$CASE/in"
mkdir -p "$IN"
printf 'export TOKEN=%s\n' "gh""p_$(fill 36 a1B2c3D4e5F6g7H8i9J0)" >"$IN/github-pat"
printf 'aws_access_key_id = %s\n' "AKIA$(fill 16 QWERTYUIOPASDFGH)" >"$IN/aws"
{ printf -- '-----BEGIN %s-----\n' "RSA PRIVATE KEY"; fill 64 MIIEpAIBAAKCAQEA0x9; echo; fill 64 Zq8wLmN3vB7cX2; echo; printf -- '-----END %s-----\n' "RSA PRIVATE KEY"; } >"$IN/private-key"
printf 'curl -H "Authorization: Bearer %s" https://api.example.test\n' "$(fill 40 Zx9Yw8Vu7Ts6Rq5Po4)" >"$IN/bearer"
printf 'ls -la src\n' >"$IN/clean-command"
printf 'The quick brown fox jumps over the lazy dog.\n' >"$IN/clean-prose"
: >"$IN/empty"
awk 'BEGIN { for (i = 0; i < 9000; i++) printf "line %d of a large clean log\n", i }' >"$IN/large-clean"
{ cat "$IN/large-clean"; cat "$IN/github-pat"; } >"$IN/large-secret"
printf '%s\n' "$(fill 60 'cGFzc3dvcmQ9czNjcjN0LXZhbHVlLWZvci10ZXN0')" >"$IN/base64-blob"
printf 'token=%s\n' "$(printf '%s' "gh""p_$(fill 36 Q1w2E3r4T5y6U7i8O9p0)" | base64 | tr -d '\n')" >"$IN/encoded-pat"

ARGS_A="stdin --redact --no-banner --no-color --log-level error --config $CFG --exit-code 1"
# Run one gitleaks invocation shape: $1 runner (real|client), $2 shape (A|B),
# $3 input file, $4 output prefix. Writes .status, .out, .err and, for B, .report.
run_shape() {
  if [ "$2" = A ]; then
    set -- "$1" "$2" "$3" "$4" $ARGS_A
  else
    set -- "$1" "$2" "$3" "$4" stdin --report-format json --report-path "$4.report" --no-banner --config "$CFG"
  fi
  runner=$1 input=$3 prefix=$4
  shift 4
  if [ "$runner" = real ]; then
    "$GL" "$@" <"$input" >"$prefix.out" 2>"$prefix.err"
  else
    "$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- "$@" \
      <"$input" >"$prefix.out" 2>"$prefix.err"
  fi
  echo "$?" >"$prefix.status"
}
# The real gitleaks prints findings in map order and logs a clock time and a
# duration; compare the finding set and the log lines without those.
normal_log() { sed -e 's/^[^ ]* //' -e 's/ in [^ ]*$/ in -/' "$1"; }
normal_report() { jq -S 'sort_by(.RuleID, .StartLine, .StartColumn, .Secret)' "$1" 2>/dev/null || echo invalid; }
same_as_real() { # $1 shape, $2 input -> 0 when the client answered exactly as the real gitleaks
  run_shape real "$1" "$2" "$CASE/r"
  run_shape client "$1" "$2" "$CASE/c"
  cmp -s "$CASE/r.status" "$CASE/c.status" && cmp -s "$CASE/r.out" "$CASE/c.out" || return 1
  if [ "$1" = A ]; then
    cmp -s "$CASE/r.err" "$CASE/c.err"
  else
    [ "$(normal_log "$CASE/r.err")" = "$(normal_log "$CASE/c.err")" ] \
      && [ "$(normal_report "$CASE/r.report")" = "$(normal_report "$CASE/c.report")" ]
  fi
}
last_trace() { tail -n 1 "$TRACE" 2>/dev/null; }
wait_socket() {
  n=0
  while [ "$n" -lt 100 ]; do
    for s in "$HDIR"/*.sock; do [ -S "$s" ] && return 0; done
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}
warm() { run_shape client A "$IN/clean-command" "$CASE/w" && wait_socket && run_shape client A "$IN/clean-command" "$CASE/w"; }

# --- cold start, spawn, warm answers ----------------------------------------
: >"$TRACE"
run_shape client A "$IN/github-pat" "$CASE/c"
expect "a cold client runs the real gitleaks and starts one helper" \
  '[ "$(cat "$CASE/c.status")" = 1 ] && [ "$(sed -n 1p "$TRACE")" = spawned ] && [ "$(sed -n 2p "$TRACE")" = real:cold ]'
check "the helper socket appears in a private directory" wait_socket
sock=$(ls "$HDIR"/*.sock)
key=$(basename "$sock" .sock)
check "the helper directory is 0700 and the socket 0600" \
  sh -c '[ "$(ls -ld "$1" | cut -c1-10)" = drwx------ ] && [ "$(ls -l "$2" | cut -c1-10)" = srw------- ]' _ "$HDIR" "$sock"
run_shape client A "$IN/github-pat" "$CASE/c"
expect "a warm client answers from the helper" '[ "$(last_trace)" = helper ] && [ "$(cat "$CASE/c.status")" = 1 ]'

# --- differential against the official gitleaks ------------------------------
mismatch=
for input in "$IN"/*; do
  for shape in A B; do
    : >"$TRACE"
    if ! same_as_real "$shape" "$input" || [ "$(cat "$TRACE")" != helper ]; then
      mismatch="$mismatch $(basename "$input")/$shape($(tr '\n' ' ' <"$TRACE"))"
    fi
  done
done
check "helper answers equal the official gitleaks for every synthetic input${mismatch:+ (differ:$mismatch)}" [ -z "$mismatch" ]
for f in "$IN/large-clean" "$IN/large-secret"; do
  : >"$TRACE"
  run_shape client A "$f" "$CASE/c"
  run_shape real A "$f" "$CASE/r"
  expect "a $(basename "$f") file over the pipe limit is still answered by the helper as a regular file" \
    '[ "$(last_trace)" = helper ] && cmp -s "$CASE/r.status" "$CASE/c.status"'
  : >"$TRACE"
  cat "$f" | "$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A >/dev/null 2>&1
  st=$?
  expect "a piped $(basename "$f") over 64 KiB goes to the real gitleaks and keeps its verdict" \
    'case "$(last_trace)" in real:large|real:pipe-chunks) ;; *) false ;; esac && [ "$st" = "$(cat "$CASE/r.status")" ]'
done
# A producer that writes in two pieces: the real gitleaks may read two chunks,
# so the client replays the input to it.
: >"$TRACE"
{ printf 'export TOKEN='; sleep 0.3; sed 's/^export TOKEN=//' "$IN/github-pat"; } \
  | "$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A >/dev/null 2>&1
st=$?
expect "piped input that arrives in pieces is replayed to the real gitleaks" '[ "$(last_trace)" = real:pipe-chunks ] && [ "$st" = 1 ]'
awk 'BEGIN { for (i = 0; i < 40000; i++) printf "padding line %d of a very large clean file\n", i }' >"$CASE/huge"
cat "$IN/aws" >>"$CASE/huge"
: >"$TRACE"
run_shape client A "$CASE/huge" "$CASE/c"
expect "a regular file over 1 MiB goes to the real gitleaks and keeps its finding" \
  '[ "$(last_trace)" = real:large ] && [ "$(cat "$CASE/c.status")" = 1 ]'

# --- inputs and options the helper does not take ------------------------------
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- \
  stdin --no-banner --config "$CFG" --max-decode-depth 0 <"$IN/encoded-pat" >/dev/null 2>&1
check "an unknown gitleaks flag goes to the real gitleaks" [ "$(last_trace)" = real:arguments ]
(
  cd "$CASE/work" || exit 1
  : >.gitleaksignore
  : >"$TRACE"
  run_shape client A "$IN/github-pat" "$CASE/c"
  [ "$(last_trace)" = real:gitleaksignore ]
) && ok "a .gitleaksignore in the scan directory goes to the real gitleaks" \
  || bad "a .gitleaksignore in the scan directory goes to the real gitleaks"
rm -f "$CASE/work/.gitleaksignore"
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.29.0 --state-dir "$STATE" -- $ARGS_A <"$IN/github-pat" >/dev/null 2>&1
st=$?
expect "a probed gitleaks version the helper does not link is scanned for real, without asking it" \
  '[ "$(last_trace)" = real:version ] && [ "$st" = 1 ]'
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- \
  stdin --report-format json --report-path "$CASE/no/such/dir/r.json" --no-banner --config "$CFG" \
  <"$IN/github-pat" >/dev/null 2>&1
st=$?
expect "an unwritable report path goes to the real gitleaks, which fails it" \
  '[ "$(last_trace)" = real:report-path ] && [ "$st" != 0 ]'

printf '#!/bin/sh\nexec "%s" "$@"\n' "$GL" >"$CASE/bin/wrapped-gitleaks"
chmod +x "$CASE/bin/wrapped-gitleaks"
: >"$TRACE"
"$CLIENT" --gitleaks "$CASE/bin/wrapped-gitleaks" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$IN/github-pat" >/dev/null 2>&1
st=$?
expect "a gitleaks without Go build information (a wrapper script) is scanned for real" \
  '[ "$(last_trace)" = real:engine ] && [ "$st" = 1 ]'
# A Go program with other build information than the official release (here:
# the client itself, which links other modules) is run for real without
# asking the helper; it is not gitleaks, so that run fails, never clean.
cp "$CLIENT" "$CASE/bin/other-engine"
: >"$TRACE"
"$CLIENT" --gitleaks "$CASE/bin/other-engine" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$IN/clean-command" >/dev/null 2>&1
st=$?
expect "a gitleaks with other Go build information than the helper is run for real, without asking it" \
  '[ "$(last_trace)" = real:engine ] && [ "$st" != 0 ]'
# Neither refused setup may start a helper for itself: with none running and
# no markers, a cold call that is refused leaves the directory empty.
stop_helpers
rm -f "$HDIR"/*
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.29.0 --state-dir "$STATE" -- $ARGS_A <"$IN/clean-command" >/dev/null 2>&1
"$CLIENT" --gitleaks "$CASE/bin/other-engine" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$IN/clean-command" >/dev/null 2>&1
sleep 1
expect "a refused version or engine starts no helper and leaves no socket or marker" \
  '[ -z "$(helper_pids)" ] && [ -z "$(ls "$HDIR")" ]'
warm >/dev/null 2>&1
: >"$TRACE"
(export NO_COLOR=1; same_as_real B "$IN/github-pat"); same=$?
expect "with NO_COLOR set the summary lines are uncoloured, as the real gitleaks prints them" \
  '[ "$same" = 0 ] && grep -qx helper "$TRACE" && ! grep -q "$(printf "\033")" "$CASE/c.err"'

# --- a custom config gets its own helper; an extending one is never served ---
cp "$CFG" "$CASE/custom.toml"
cat >>"$CASE/custom.toml" <<'EOF'

[[rules]]
id = "agent-guard-test-custom"
description = "helper test rule"
regex = '''AGTESTCUSTOM[0-9]{12}'''
keywords = ["agtestcustom"]
EOF
printf 'value AGTESTCUSTOM%s\n' 482915736104 >"$CASE/custom-input"
custom_scan() {
  "$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- \
    stdin --redact --no-banner --no-color --log-level error --config "$1" --exit-code 1 <"$CASE/custom-input" >/dev/null 2>&1
}
: >"$TRACE"
custom_scan "$CASE/custom.toml"; st1=$?
n=0; while [ "$(ls "$HDIR"/*.sock 2>/dev/null | wc -l)" -lt 2 ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
custom_scan "$CASE/custom.toml"; st2=$?
custom_scan "$CFG"; st3=$?
custom_trace=$(printf 'spawned\nreal:cold\nhelper\nhelper')
expect "a changed config starts a second helper and its rule applies (cold, then warm)" \
  '[ "$st1" = 1 ] && [ "$st2" = 1 ] && [ "$st3" = 0 ] && [ "$(cat "$TRACE")" = "$custom_trace" ]'
printf '\n# edited\n' >>"$CASE/custom.toml"
: >"$TRACE"
custom_scan "$CASE/custom.toml"
check "editing the config bytes misses the running helper" [ "$(sed -n 2p "$TRACE")" = real:cold ]
printf '[extend]\npath = "%s"\n' "$CFG" >"$CASE/extend.toml"
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- \
  stdin --redact --no-banner --no-color --log-level error --config "$CASE/extend.toml" --exit-code 1 <"$IN/github-pat" >/dev/null 2>&1
n=0; while ! ls "$HDIR"/*.unsupported >/dev/null 2>&1 && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- \
  stdin --redact --no-banner --no-color --log-level error --config "$CASE/extend.toml" --exit-code 1 <"$IN/github-pat" >/dev/null 2>&1
st=$?
expect "a config that extends another file is marked unsupported and always scanned for real" \
  '[ "$(last_trace)" = real:unsupported-config ] && [ "$st" = 1 ]'

# --- broken helpers ------------------------------------------------------------
stop_helpers
check "a stopped helper removes its socket and lock" \
  sh -c '! ls "$1"/*.sock "$1"/*.lock >/dev/null 2>&1' _ "$HDIR"
fake() { # $1 mode: serve the default-config key with a broken helper
  rm -f "$sock"
  python3 "$ROOT/tests/fixtures/fake-gitleaks-helper.py" "$sock" "$1" >"$CASE/fake.out" 2>&1 &
  FAKE_PID=$!
  n=0; while ! grep -q ready "$CASE/fake.out" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
# A helper that closes early may fail the client's send or its read; either
# way the client must run the real gitleaks.
for spec in close:answer truncate:answer garbage:answer badexit:answer fallback:helper-scan; do
  mode=${spec%%:*} reason=${spec#*:}
  fake "$mode"
  for shape in A B; do
    for input in github-pat clean-command; do
      : >"$TRACE"
      same_as_real "$shape" "$IN/$input"; same=$?
      expect "a helper that answers '$mode' falls back to the real gitleaks ($input, $shape)" \
        '[ "$same" = 0 ] && { [ "$(last_trace)" = "real:$reason" ] || { [ "$reason" = answer ] && [ "$(last_trace)" = real:send ]; }; }'
    done
  done
  stop_helpers
done
fake noreport
: >"$TRACE"
same_as_real B "$IN/github-pat"; same=$?
expect "an answer without the requested report falls back to the real gitleaks" \
  '[ "$same" = 0 ] && [ "$(last_trace)" = real:report-write ]'
stop_helpers
fake hang
: >"$TRACE"
started=$(date +%s)
same_as_real A "$IN/github-pat"; same=$?
took=$(( $(date +%s) - started ))
expect "a helper that never answers times out into the real gitleaks within the client deadline" \
  '[ "$same" = 0 ] && [ "$(last_trace)" = real:answer ] && [ "$took" -le 6 ]'
stop_helpers
if [ "$(id -u)" = 0 ]; then
  fake otheruid
  : >"$TRACE"
  same_as_real A "$IN/github-pat"; same=$?
  expect "a socket served by another user is not trusted, even with a clean answer" \
    '[ "$same" = 0 ] && [ "$(last_trace)" = real:peer ]'
  stop_helpers
elif sudo -n true 2>/dev/null; then
  rm -f "$sock"
  sudo -n python3 "$ROOT/tests/fixtures/fake-gitleaks-helper.py" "$sock" otheruid >"$CASE/fake.out" 2>&1 &
  n=0; while ! grep -q ready "$CASE/fake.out" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  : >"$TRACE"
  same_as_real A "$IN/github-pat"; same=$?
  expect "a socket served by another user is not trusted, even with a clean answer" \
    '[ "$same" = 0 ] && [ "$(last_trace)" = real:peer ]'
  sudo -n pkill -f fake-gitleaks-helper.py 2>/dev/null
  sudo -n rm -f "$sock"
else
  ok "a socket served by another user is not trusted # SKIP needs root or sudo"
fi
rm -f "$sock" "$HDIR"/*.spawn

# A dead helper's socket file: connect is refused, a new helper replaces it.
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$sock"
: >"$TRACE"
run_shape client A "$IN/github-pat" "$CASE/c"
expect "a stale socket file is treated as no helper" '[ "$(sed -n 2p "$TRACE")" = real:cold ] && [ "$(cat "$CASE/c.status")" = 1 ]'
wait_socket
sleep 0.2
run_shape client A "$IN/github-pat" "$CASE/c"
check "the next helper replaces the stale socket and answers" [ "$(last_trace)" = helper ]

# --- unusable directories and binaries ----------------------------------------
stop_helpers
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$CASE/xs/missing" -- $ARGS_A <"$IN/github-pat" >/dev/null 2>&1
check "a missing state directory goes to the real gitleaks" [ "$(last_trace)" = real:state-dir ]
chmod 755 "$HDIR"
: >"$TRACE"
run_shape client A "$IN/github-pat" "$CASE/c"
expect "a helper directory with another mode is not used or repaired" \
  '[ "$(last_trace)" = real:state-dir ] && [ "$(ls -ld "$HDIR" | cut -c1-10)" = drwxr-xr-x ]'
chmod 700 "$HDIR"
mv "$HDIR" "$CASE/moved"; ln -s "$CASE/moved" "$HDIR"
: >"$TRACE"
run_shape client A "$IN/github-pat" "$CASE/c"
check "a symlinked helper directory is not used" [ "$(last_trace)" = real:state-dir ]
rm "$HDIR"; mv "$CASE/moved" "$HDIR"
long="$CASE/xs/$(fill 90 d)"
mkdir -p "$long" && chmod 700 "$long"
: >"$TRACE"
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$long" -- $ARGS_A <"$IN/github-pat" >/dev/null 2>&1
check "a socket path too long for sun_path goes to the real gitleaks" [ "$(last_trace)" = real:socket-path ]
mkdir -p "$CASE/lonely"
cp "$CLIENT" "$CASE/lonely/"
: >"$TRACE"
"$CASE/lonely/agent-guard-scan" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$IN/github-pat" >/dev/null 2>&1
st=$?
expect "a client without its helper binary runs the real gitleaks" '[ "$(last_trace)" = real:helper-missing ] && [ "$st" = 1 ]'
"$CLIENT" --gitleaks "$CASE/no-gitleaks" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$IN/clean-command" >/dev/null 2>&1
st=$?
check "with neither a helper answer nor a runnable gitleaks the client fails (2), never clean" [ "$st" = 2 ]
"$CLIENT" --bogus <"$IN/clean-command" >/dev/null 2>&1
check "a malformed client invocation fails (2), never clean" [ "$?" = 2 ]
# A directory as standard input makes every read() fail. Warm, the client
# has started reading, so it must report the failure itself (2); the real
# gitleaks would otherwise see an end of file. Cold, it execs the real
# gitleaks before reading, which reports the error on stderr; the CLI treats
# exit 0 with output as a scanner error.
warm >/dev/null 2>&1
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$CASE/work" >/dev/null 2>&1
check "warm: a standard input that cannot be read is a failure (2), never clean" [ "$?" = 2 ]
stop_helpers
rm -f "$HDIR"/*
"$CLIENT" --gitleaks "$GL" --gitleaks-version 8.30.1 --state-dir "$STATE" -- $ARGS_A <"$CASE/work" >/dev/null 2>"$CASE/dir.err"
st=$?
expect "cold: an unreadable standard input reaches the real gitleaks, which reports it" \
  '[ "$st" != 0 ] || grep -q "could not read file" "$CASE/dir.err"'
stop_helpers
rm -f "$HDIR"/*

# --- one helper per user and config; lifetime and memory ----------------------
stop_helpers
rm -f "$HDIR"/*
for i in 1 2 3 4 5 6 7 8; do
  run_shape client A "$IN/clean-command" "$CASE/race$i" &
done
wait
wait_socket
sleep 1
race_helpers=$(helper_pids | wc -l | tr -d ' ')
race_status=$(cat "$CASE"/race*.status | sort -u)
expect "eight racing cold clients leave exactly one helper and all pass" '[ "$race_helpers" = 1 ] && [ "$race_status" = 0 ]' 
: >"$TRACE"
for i in 1 2 3 4 5 6; do
  ( cd "$CASE/work" && run_shape client A "$IN/github-pat" "$CASE/sess$i" ) &
done
wait
sessions_answered=$(grep -cx helper "$TRACE")
sessions_helpers=$(helper_pids | wc -l | tr -d ' ')
sessions_status=$(cat "$CASE"/sess*.status | sort -u)
expect "concurrent sessions share the one helper, which answers them all" '[ "$sessions_helpers" = 1 ] && [ "$sessions_status" = 1 ] && [ "$sessions_answered" = 6 ]' 
stop_helpers
rm -f "$HDIR"/*
# The CLI keeps the host's stdout and stderr on descriptors 8 and 9 in Claude
# Code; a helper started from a hook must not inherit them.
: >"$CASE/fdmark"
run_shape client A "$IN/clean-command" "$CASE/fd" 8>>"$CASE/fdmark" 9>>"$CASE/fdmark"
wait_socket
pid=$(helper_pids)
if [ -d "/proc/$pid/fd" ]; then
  leaked=$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -c fdmark)
else
  leaked=$(lsof -p "$pid" 2>/dev/null | grep -c fdmark)
fi
expect "a helper started from a hook holds none of the hook's other descriptors" '[ -n "$pid" ] && [ "$leaked" = 0 ]'
stop_helpers
rm -f "$HDIR"/*
jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la docs"}}' >"$CASE/pre-pipe.json"
started=$(date +%s)
(cd "$CASE/work" && AI_AGENT=claude-code_2.1.300 AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" "$GUARD" hook-pre-tool <"$CASE/pre-pipe.json" 2>&1 | cat >/dev/null)
took=$(( $(date +%s) - started ))
expect "a Claude hook whose output is a pipe ends when the hook ends, though it started a helper" \
  '[ "$took" -lt 15 ] && [ -n "$(helper_pids)" ]'
stop_helpers
rm -f "$HDIR"/*
(export AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS=1; warm)
warm_status=$?
pid=$(helper_pids)
expect "a helper for the idle checks started and answered" '[ "$warm_status" = 0 ] && [ -n "$pid" ] && [ "$(last_trace)" = helper ]'
n=0; while [ -n "$(helper_pids)" ] && [ "$n" -lt 250 ]; do sleep 0.1; n=$((n + 1)); done
check "an idle helper exits by itself" [ -z "$(helper_pids)" ]
check "an idle helper leaves no socket or lock behind" sh -c '! ls "$1"/*.sock "$1"/*.lock >/dev/null 2>&1' _ "$HDIR"
if [ -n "$pid" ] && [ -n "$(ps -o stat= -p "$pid" 2>/dev/null)" ]; then
  bad "the exited helper was reaped (state: $(ps -o stat= -p "$pid"))"
else
  ok "the exited helper was reaped${AG_HELPER_TEST_INIT:+ (under $AG_HELPER_TEST_INIT)}"
fi
rm -f "$HDIR"/*
# A 1 MiB input dense with findings builds a report over the 16 MiB answer
# limit: the helper answers "fallback" (the client scans for real), and the
# memory it needed puts its peak over the lowest cap, so it then exits.
awk -v p="$(sed -n 's/^export TOKEN=//p' "$IN/github-pat" | cut -c1-36)" \
  'BEGIN { for (i = 0; i < 40000; i++) printf "key_%d = %s%04d\n", i, p, i % 9000 }' 2>/dev/null | head -c 1048000 >"$CASE/dense"
(export AGENT_GUARD_GITLEAKS_HELPER_MAX_RSS_MIB=96; warm)
pid=$(helper_pids)
run_shape client B "$CASE/dense" "$CASE/m"
n=0; while [ -n "$(helper_pids)" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
expect "an oversized report is answered by the real gitleaks, and a helper past its memory cap then exits" \
  '[ -n "$pid" ] && [ "$(cat "$CASE/m.status")" = 1 ] && [ "$(last_trace)" = real:helper-report-size ] && [ -z "$(helper_pids)" ]'
rm -f "$HDIR"/*.spawn
: >"$TRACE"
run_shape client A "$IN/github-pat" "$CASE/c"
memory_trace=$(printf 'spawned\nreal:cold')
wait_socket
expect "the next request after a memory exit starts a fresh helper" \
  '[ "$(cat "$TRACE")" = "$memory_trace" ] && [ -n "$(helper_pids)" ]'
stop_helpers

# --- the CLI: every supported host through the same boundary ------------------
rm -f "$HDIR"/*
pat=$(cat "$IN/github-pat")
jq -nc --arg c "echo ${pat#export TOKEN=}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' >"$CASE/pre-secret.json"
jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la src"}}' >"$CASE/pre-clean.json"
jq -nc --arg c "$pat" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:"a.sh",content:$c}}' >"$CASE/write-secret.json"
jq -nc --arg o "$pat" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"cat env.txt"},tool_response:{stdout:$o,stderr:"",interrupted:false}}' >"$CASE/post-secret.json"
jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"ls"},tool_response:{stdout:"a\nb\n",stderr:"",interrupted:false}}' >"$CASE/post-clean.json"
jq -nc --arg p "please use ${pat#export TOKEN=}" '{hook_event_name:"UserPromptSubmit",prompt:$p}' >"$CASE/prompt-secret.json"
jq -nc '{hook_event_name:"UserPromptSubmit",prompt:"summarize the README"}' >"$CASE/prompt-clean.json"
jq -nc '{hook_event_name:"SomethingNew",payload:{x:1}}' >"$CASE/unknown.json"
hook_case() { # $1 host, $2 hook, $3 fixture, $4 helper on|off, $5 prefix
  # Each run must scan, not reuse the other run's clean verdict.
  rm -rf "$STATE/gitleaks-clean"
  if [ "$4" = on ]; then
    (cd "$CASE/work" && AGENT_GUARD_HOOK_HOST="$1" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" "$GUARD" "$2" <"$CASE/$3.json" >"$5.out" 2>"$5.err")
  else
    (cd "$CASE/work" && AGENT_GUARD_HOOK_HOST="$1" "$GUARD" "$2" <"$CASE/$3.json" >"$5.out" 2>"$5.err")
  fi
  echo "$?" >"$5.status"
}
hook_same() { # same arguments as hook_case without the mode
  hook_case "$1" "$2" "$3" off "$CASE/off"
  hook_case "$1" "$2" "$3" on "$CASE/on"
  cmp -s "$CASE/off.status" "$CASE/on.status" && cmp -s "$CASE/off.out" "$CASE/on.out" && cmp -s "$CASE/off.err" "$CASE/on.err"
}
hook_case claude hook-pre-tool pre-clean on "$CASE/x"
wait_socket
hook_helper_pid=$(helper_pids)
for host in claude codex; do
  for spec in hook-pre-tool:pre-secret hook-pre-tool:pre-clean hook-pre-tool:write-secret \
      hook-post-tool:post-secret hook-post-tool:post-clean \
      hook-user-prompt:prompt-secret hook-user-prompt:prompt-clean hook-pre-tool:unknown; do
    : >"$TRACE"
    hook_same "$host" "${spec%%:*}" "${spec#*:}"; same=$?
    used=yes
    case "${spec#*:}" in unknown) used=no ;; esac
    if [ "$used" = yes ] && ! grep -qx helper "$TRACE"; then same=1; fi
    if [ "$used" = no ] && [ -s "$TRACE" ]; then same=1; fi
    check "$host ${spec%%:*} ${spec#*:}: helper on answers byte for byte as off" [ "$same" = 0 ]
    if [ "$same" != 0 ]; then
      # Say why: the client's path for each scan, the helper, and any output difference.
      printf '  trace: %s\n' "$(tr '\n' ' ' <"$TRACE")"
      printf '  helpers: %s; peak/resident KiB: %s\n' "$(helper_pids | tr '\n' ' ')" \
        "$(for pid in $(helper_pids); do ps -o rss= -p "$pid"; done | tr '\n' ' ')"
      for part in status out err; do
        cmp -s "$CASE/off.$part" "$CASE/on.$part" || { printf '  %s differs:\n' "$part"; diff "$CASE/off.$part" "$CASE/on.$part" | head -10 | sed 's/^/    /'; }
      done
    fi
  done
done

printf '# hook loop: helper %s at start, %s at end, resident KiB %s\n' "$hook_helper_pid" \
  "$(helper_pids | tr '\n' ' ')" "$(for pid in $(helper_pids); do ps -o rss= -p "$pid"; done | tr '\n' ' ')"

# AGENT_GUARD_GITLEAKS_CONFIG: the custom config's bytes get their own helper.
jq -nc --arg c "echo $(cat "$CASE/custom-input")" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' >"$CASE/pre-custom.json"
custom_hook() {
  rm -rf "$STATE/gitleaks-clean"
  (cd "$CASE/work" && AGENT_GUARD_GITLEAKS_CONFIG="$CASE/custom.toml" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" \
    "$GUARD" hook-pre-tool <"$CASE/pre-custom.json" >"$CASE/cu.out" 2>&1)
  echo "$?"
}
custom_hook >/dev/null
n=0; while [ "$(ls "$HDIR"/*.sock 2>/dev/null | wc -l)" -lt 2 ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
: >"$TRACE"
st=$(custom_hook)
rm -rf "$STATE/gitleaks-clean"
(cd "$CASE/work" && AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" "$GUARD" hook-pre-tool <"$CASE/pre-custom.json" >/dev/null 2>&1)
st_default=$?
expect "AGENT_GUARD_GITLEAKS_CONFIG: its own helper applies its rule; the default config does not" \
  '[ "$st" = 2 ] && grep -qx helper "$TRACE" && [ "$st_default" = 0 ]'

# Git pre-commit: scan-staged reads staged content through gitleaks stdin.
git init -q "$CASE/repo" && cd "$CASE/repo" || exit 1
git config user.email t@example.test && git config user.name test
cp "$IN/github-pat" leaked.txt && cp "$IN/clean-prose" notes.txt && git add leaked.txt notes.txt
: >"$TRACE"
"$GUARD" scan-staged >"$CASE/off.out" 2>"$CASE/off.err"; echo "$?" >"$CASE/off.status"
AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" "$GUARD" scan-staged >"$CASE/on.out" 2>"$CASE/on.err"; echo "$?" >"$CASE/on.status"
expect "git pre-commit scan-staged: helper on answers as off and blocks" \
  'cmp -s "$CASE/off.status" "$CASE/on.status" && cmp -s "$CASE/off.err" "$CASE/on.err" && [ "$(cat "$CASE/on.status")" != 0 ] && grep -qx helper "$TRACE"'
git rm -q --cached leaked.txt
"$GUARD" scan-staged >"$CASE/off.out" 2>"$CASE/off.err"; echo "$?" >"$CASE/off.status"
AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" "$GUARD" scan-staged >"$CASE/on.out" 2>"$CASE/on.err"; echo "$?" >"$CASE/on.status"
expect "git pre-commit scan-staged: a clean index passes the same way" \
  'cmp -s "$CASE/off.status" "$CASE/on.status" && [ "$(cat "$CASE/on.status")" = 0 ]'
# GitHub Actions: scan-path scans directories with `gitleaks dir`; the helper
# only takes stdin, so the action keeps the real scanner.
: >"$TRACE"
"$GUARD" scan-path -- "$CASE/repo" >"$CASE/off.out" 2>"$CASE/off.err"; echo "$?" >"$CASE/off.status"
AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" "$GUARD" scan-path -- "$CASE/repo" >"$CASE/on.out" 2>"$CASE/on.err"; echo "$?" >"$CASE/on.status"
expect "GitHub Action scan-path: helper on answers as off through the real gitleaks dir scan" \
  'cmp -s "$CASE/off.status" "$CASE/on.status" && [ "$(cat "$CASE/on.status")" != 0 ] && grep -qx real:arguments "$TRACE"'
cd "$CASE" || exit 1

# The switches that keep the CLI on its existing path start no client.
: >"$TRACE"
(cd "$CASE/work" && AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AGENT_GUARD_GITLEAKS_BIN="$GL" "$GUARD" hook-pre-tool <"$CASE/pre-secret.json" >/dev/null 2>&1)
check "an explicit AGENT_GUARD_GITLEAKS_BIN keeps that scanner and starts no client" [ ! -s "$TRACE" ]
(cd "$CASE/work" && AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" AGENT_GUARD_LOG_MODE=off "$GUARD" hook-pre-tool <"$CASE/pre-secret.json" >/dev/null 2>&1)
check "AGENT_GUARD_LOG_MODE=off (no private state directory) starts no client" [ ! -s "$TRACE" ]
(cd "$CASE/work" && AGENT_GUARD_GITLEAKS_HELPER=relative/agent-guard-scan "$GUARD" hook-pre-tool <"$CASE/pre-secret.json" >/dev/null 2>&1)
check "a relative AGENT_GUARD_GITLEAKS_HELPER is ignored" [ ! -s "$TRACE" ]
(cd "$CASE/work" && AGENT_GUARD_GITLEAKS_HELPER="$CASE/missing" "$GUARD" hook-pre-tool <"$CASE/pre-secret.json" >/dev/null 2>&1)
check "a missing AGENT_GUARD_GITLEAKS_HELPER is ignored" [ ! -s "$TRACE" ]
stop_helpers

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

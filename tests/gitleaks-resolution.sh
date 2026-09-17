#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-gitleaks-resolution.XXXXXX")
ORIGINAL_PATH=$PATH
REAL_JQ=$(command -v jq)
REAL_SLEEP=$(command -v sleep)
pass=0
fail=0

cleanup() {
  rm -rf "$CASE_ROOT"
}
trap cleanup EXIT INT TERM

ok() {
  pass=$((pass + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE_ROOT/out" ] || sed 's/^/  stdout: /' "$CASE_ROOT/out"
  [ ! -s "$CASE_ROOT/err" ] || sed 's/^/  stderr: /' "$CASE_ROOT/err"
}

make_scanner() {
  scanner=$1
  version=$2
  version_status=$3
  mkdir -p "${scanner%/*}"
  sed \
    -e "s|@VERSION@|$version|g" \
    -e "s|@VERSION_STATUS@|$version_status|g" \
    >"$scanner" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$0" "${1:-}" >>"${MOCK_GITLEAKS_LOG:-/dev/null}"
case "${1:-}" in
  version)
    printf '%s\n' '@VERSION@'
    exit @VERSION_STATUS@
    ;;
  stdin)
    cat >/dev/null
    exit 0
    ;;
  dir) exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$scanner"
}

run_check() {
  env AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml" \
    AGENT_GUARD_GITLEAKS_BIN_DIR="$1" \
    PATH="$2" \
    ${3:+AGENT_GUARD_GITLEAKS_BIN=$3} \
    "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
}

PATH_BIN="$CASE_ROOT/path-bin"
PRIVATE_BIN="$CASE_ROOT/private-bin"
EXPLICIT_BIN="$CASE_ROOT/explicit-bin"
EMPTY_PRIVATE="$CASE_ROOT/empty-private"
mkdir -p "$EMPTY_PRIVATE"
make_scanner "$PATH_BIN/gitleaks" '8.31.0-path' 0
make_scanner "$PRIVATE_BIN/gitleaks" '8.31.0-private' 0
make_scanner "$EXPLICIT_BIN/gitleaks" '8.31.0-explicit' 0
PATH_BIN_CANON=$(CDPATH= cd -- "$PATH_BIN" && pwd -P)
PRIVATE_BIN_CANON=$(CDPATH= cd -- "$PRIVATE_BIN" && pwd -P)
EXPLICIT_BIN_CANON=$(CDPATH= cd -- "$EXPLICIT_BIN" && pwd -P)

run_check "$PRIVATE_BIN" "$PATH_BIN:$ORIGINAL_PATH" "$EXPLICIT_BIN/gitleaks"
status=$?
if [ "$status" -eq 0 ] \
   && grep -Fq "$EXPLICIT_BIN_CANON/gitleaks" "$CASE_ROOT/err" \
   && ! grep -Fq "$PRIVATE_BIN_CANON/gitleaks" "$CASE_ROOT/err"; then
  ok "explicit gitleaks override has highest priority"
else
  not_ok "explicit gitleaks override has highest priority (status $status)"
fi

run_check "$PRIVATE_BIN" "$PATH_BIN:$ORIGINAL_PATH" ''
status=$?
if [ "$status" -eq 0 ] \
   && grep -Fq "$PRIVATE_BIN_CANON/gitleaks" "$CASE_ROOT/err" \
   && ! grep -Fq "$PATH_BIN_CANON/gitleaks" "$CASE_ROOT/err"; then
  ok "private gitleaks precedes PATH"
else
  not_ok "private gitleaks precedes PATH (status $status)"
fi

run_check "$EMPTY_PRIVATE" "$PATH_BIN:$ORIGINAL_PATH" ''
status=$?
if [ "$status" -eq 0 ] && grep -Fq "$PATH_BIN_CANON/gitleaks" "$CASE_ROOT/err"; then
  ok "PATH is used when no explicit or private candidate exists"
else
  not_ok "PATH is used when no higher-priority candidate exists (status $status)"
fi

chmod -x "$EXPLICIT_BIN/gitleaks"
run_check "$PRIVATE_BIN" "$PATH_BIN:$ORIGINAL_PATH" "$EXPLICIT_BIN/gitleaks"
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq "selected gitleaks is not executable: $EXPLICIT_BIN/gitleaks" "$CASE_ROOT/err" \
   && ! grep -Fq "$PRIVATE_BIN/gitleaks" "$CASE_ROOT/err"; then
  ok "invalid explicit override does not fall back"
else
  not_ok "invalid explicit override does not fall back (status $status)"
fi

chmod -x "$PRIVATE_BIN/gitleaks"
run_check "$PRIVATE_BIN" "$PATH_BIN:$ORIGINAL_PATH" ''
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq "selected gitleaks is not executable: $PRIVATE_BIN/gitleaks" "$CASE_ROOT/err" \
   && ! grep -Fq "$PATH_BIN/gitleaks" "$CASE_ROOT/err"; then
  ok "invalid private candidate does not fall back to PATH"
else
  not_ok "invalid private candidate does not fall back to PATH (status $status)"
fi
chmod +x "$PRIVATE_BIN/gitleaks"

env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$CASE_ROOT/missing-gitleaks" \
  "$GUARD" doctor >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 1 ] \
   && grep -Fq 'gitleaks  missing  (selected path is not executable:' "$CASE_ROOT/err"; then
  ok "doctor distinguishes a missing selected gitleaks"
else
  not_ok "doctor distinguishes a missing selected gitleaks (status $status)"
fi

STATE_BIN="$CASE_ROOT/state-bin"
make_scanner "$STATE_BIN/gitleaks" 'version unavailable' 7
run_check "$EMPTY_PRIVATE" "$ORIGINAL_PATH" "$STATE_BIN/gitleaks"
status=$?
if [ "$status" -eq 2 ] && grep -Fq 'gitleaks version command failed' "$CASE_ROOT/err"; then
  ok "check distinguishes version runtime failure"
else
  not_ok "check distinguishes version runtime failure (status $status)"
fi

make_scanner "$STATE_BIN/gitleaks" 'version unavailable' 0
run_check "$EMPTY_PRIVATE" "$ORIGINAL_PATH" "$STATE_BIN/gitleaks"
status=$?
if [ "$status" -eq 2 ] && grep -Fq 'could not parse gitleaks version' "$CASE_ROOT/err"; then
  ok "check distinguishes unparseable version output"
else
  not_ok "check distinguishes unparseable version output (status $status)"
fi

make_scanner "$STATE_BIN/gitleaks" 'gitleaks version 7.6.1' 0
run_check "$EMPTY_PRIVATE" "$ORIGINAL_PATH" "$STATE_BIN/gitleaks"
status=$?
if [ "$status" -eq 2 ] && grep -Fq 'gitleaks 7.6.1 is incompatible' "$CASE_ROOT/err"; then
  ok "check distinguishes an unsupported version"
else
  not_ok "check distinguishes an unsupported version (status $status)"
fi

make_scanner "$STATE_BIN/gitleaks" 'gitleaks version 8.30.1 then failed' 9
run_check "$EMPTY_PRIVATE" "$ORIGINAL_PATH" "$STATE_BIN/gitleaks"
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq 'gitleaks version command failed' "$CASE_ROOT/err" \
   && ! grep -Fq 'dependencies ok' "$CASE_ROOT/err"; then
  ok "version output followed by nonzero exit remains a runtime failure"
else
  not_ok "version output followed by nonzero exit remains a runtime failure (status $status)"
fi

make_scanner "$STATE_BIN/gitleaks" '8.30.1-before-replacement' 0
run_check "$EMPTY_PRIVATE" "$ORIGINAL_PATH" "$STATE_BIN/gitleaks"
first_status=$?
make_scanner "$STATE_BIN/gitleaks" '7.0.0-after-replacement' 0
run_check "$EMPTY_PRIVATE" "$ORIGINAL_PATH" "$STATE_BIN/gitleaks"
second_status=$?
if [ "$first_status" -eq 0 ] && [ "$second_status" -eq 2 ] \
   && grep -Fq 'gitleaks 7.0.0 is incompatible' "$CASE_ROOT/err"; then
  ok "a replaced binary is re-probed on the next invocation"
else
  not_ok "a replaced binary is re-probed without a stale cache ($first_status/$second_status)"
fi

for doctor_state in runtime unparseable unsupported; do
  case "$doctor_state" in
    runtime) make_scanner "$STATE_BIN/gitleaks" '8.30.1 prefix' 6 ;;
    unparseable) make_scanner "$STATE_BIN/gitleaks" 'unknown' 0 ;;
    unsupported) make_scanner "$STATE_BIN/gitleaks" '7.9.0' 0 ;;
  esac
  env AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
    "$GUARD" doctor >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  expected=$doctor_state
  [ "$doctor_state" = runtime ] && expected='runtime failure'
  if [ "$status" -eq 1 ] && grep -Fq "gitleaks  $expected" "$CASE_ROOT/err"; then
    ok "doctor reports $doctor_state gitleaks state"
  else
    not_ok "doctor reports $doctor_state gitleaks state (status $status)"
  fi
done

make_scanner "$STATE_BIN/gitleaks" '7.9.0' 0
for mode in open closed; do
  : >"$CASE_ROOT/scan-log"
  printf '%s' '{"session_id":"version-gate-'"$mode"'","tool_name":"Bash","tool_input":{"command":"echo clean"}}' \
    | env AGENT_GUARD_LOG_MODE=off \
        AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
        AGENT_GUARD_INFRA_FAILURE_MODE="$mode" \
        AGENT_GUARD_WARNING_DIR="$CASE_ROOT/warnings-$mode" \
        MOCK_GITLEAKS_LOG="$CASE_ROOT/scan-log" \
        "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  expected_status=0
  [ "$mode" = closed ] && expected_status=2
  version_calls=$(grep -c ' version$' "$CASE_ROOT/scan-log" 2>/dev/null || true)
  if [ "$status" -eq "$expected_status" ] \
     && [ "$version_calls" -eq 1 ] \
     && grep -Fq "AGENT_GUARD_INFRA_FAILURE_MODE=$mode" "$CASE_ROOT/err"; then
    ok "unsupported hook scanner follows $mode policy with one bounded version probe"
  else
    not_ok "unsupported hook scanner follows $mode policy (status $status, probes $version_calls)"
  fi
done

make_scanner "$STATE_BIN/gitleaks" '8.30.1' 0
: >"$CASE_ROOT/scan-log"
hook_start=$(date +%s)
printf '%s' '{"session_id":"version-probe-budget","tool_name":"Unknown","tool_input":{}}' \
  | env AGENT_GUARD_LOG_MODE=off \
      AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
      MOCK_GITLEAKS_LOG="$CASE_ROOT/scan-log" \
      "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
hook_elapsed=$(( $(date +%s) - hook_start ))
version_calls=$(grep -c ' version$' "$CASE_ROOT/scan-log" 2>/dev/null || true)
if [ "$status" -eq 0 ] && [ "$version_calls" -eq 1 ] \
   && [ "$hook_elapsed" -le 5 ]; then
  ok "supported hook scanner uses one version probe within the 10-second hook budget (${hook_elapsed}s)"
else
  not_ok "supported hook scanner stays within its probe budget (status $status, probes $version_calls, ${hook_elapsed}s)"
fi

FAIL_MKTEMP_BIN="$CASE_ROOT/fail-mktemp-bin"
FAIL_MKTEMP_TMP="$CASE_ROOT/fail-mktemp-tmp"
mkdir -p "$FAIL_MKTEMP_BIN" "$FAIL_MKTEMP_TMP"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$FAIL_MKTEMP_BIN/mktemp"
chmod +x "$FAIL_MKTEMP_BIN/mktemp"
: >"$CASE_ROOT/fail-mktemp-log"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
  MOCK_GITLEAKS_LOG="$CASE_ROOT/fail-mktemp-log" \
  TMPDIR="$FAIL_MKTEMP_TMP" \
  PATH="$FAIL_MKTEMP_BIN:$ORIGINAL_PATH" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
fail_mktemp_versions=$(grep -c ' version$' "$CASE_ROOT/fail-mktemp-log" 2>/dev/null || true)
fail_mktemp_leftovers=$(find "$FAIL_MKTEMP_TMP" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$status" -eq 0 ] && [ "$fail_mktemp_versions" -eq 1 ] \
   && [ "$fail_mktemp_leftovers" -eq 0 ]; then
  ok "version probing stays bounded and cleans up when mktemp is unavailable"
else
  not_ok "version probing works without a mandatory mktemp dependency (status $status, probes $fail_mktemp_versions, leftovers $fail_mktemp_leftovers)"
fi

OWNERSHIP_BIN="$CASE_ROOT/ownership-bin"
OWNERSHIP_TMP="$CASE_ROOT/ownership-tmp"
mkdir -p "$OWNERSHIP_BIN" "$OWNERSHIP_TMP"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$OWNERSHIP_BIN/mktemp"
sed \
  -e "s|@JQ@|$REAL_JQ|g" \
  -e "s|@SLEEP@|$REAL_SLEEP|g" \
  >"$OWNERSHIP_BIN/jq" <<'STUB'
#!/bin/sh
case "$*" in
  *'(?<![0-9])1'*) '@SLEEP@' 3 ;;
esac
exec '@JQ@' "$@"
STUB
chmod +x "$OWNERSHIP_BIN/mktemp" "$OWNERSHIP_BIN/jq"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
  TMPDIR="$OWNERSHIP_TMP" \
  PATH="$OWNERSHIP_BIN:$ORIGINAL_PATH" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" &
ownership_pid=$!
ownership_dir="$OWNERSHIP_TMP/agent-guard-version-$ownership_pid-0.d"
ownership_output="$ownership_dir/output"
ownership_timeout="$ownership_dir/timeout"
ownership_i=0
while { [ ! -e "$ownership_output" ] || [ ! -e "$ownership_timeout" ]; } \
      && [ "$ownership_i" -lt 50 ]; do
  ownership_i=$((ownership_i + 1))
  sleep 0.05
done
ownership_i=0
while [ -e "$ownership_dir" ] \
      && [ "$ownership_i" -lt 50 ]; do
  ownership_i=$((ownership_i + 1))
  sleep 0.05
done
mkdir -m 700 "$ownership_dir"
printf '%s\n' unrelated-output >"$ownership_output"
printf '%s\n' unrelated-timeout >"$ownership_timeout"
wait "$ownership_pid"
status=$?
if [ "$status" -eq 0 ] \
   && [ "$(cat "$ownership_output" 2>/dev/null)" = unrelated-output ] \
   && [ "$(cat "$ownership_timeout" 2>/dev/null)" = unrelated-timeout ]; then
  ok "completed fallback cleanup relinquishes ownership before EXIT"
else
  not_ok "EXIT cleanup preserves files recreated after fallback unlink (status $status)"
fi
rm -f "$ownership_output" "$ownership_timeout"
rmdir "$ownership_dir"

FIFO_TMP="$CASE_ROOT/fifo-fallback-tmp"
FIFO_RUNNER="$CASE_ROOT/fifo-fallback-runner"
mkdir -p "$FIFO_TMP"
sed \
  -e "s|@GUARD@|$GUARD|g" \
  -e "s|@SCANNER@|$STATE_BIN/gitleaks|g" \
  -e "s|@TMP@|$FIFO_TMP|g" \
  -e "s|@PATH@|$FAIL_MKTEMP_BIN:$ORIGINAL_PATH|g" \
  >"$FIFO_RUNNER" <<'STUB'
#!/bin/sh
fifo='@TMP@/agent-guard-version-'$$'-0.d'
mkfifo "$fifo" || exit 90
exec env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN='@SCANNER@' \
  TMPDIR='@TMP@' PATH='@PATH@' \
  '@GUARD@' check
STUB
chmod +x "$FIFO_RUNNER"
fifo_start=$(date +%s)
"$FIFO_RUNNER" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
fifo_elapsed=$(( $(date +%s) - fifo_start ))
fifo_count=$(find "$FIFO_TMP" -mindepth 1 -maxdepth 1 -type p -print 2>/dev/null \
  | wc -l | tr -d '[:space:]')
fifo_dirs=$(find "$FIFO_TMP" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
  | wc -l | tr -d '[:space:]')
if [ "$status" -eq 0 ] && [ "$fifo_elapsed" -le 3 ] \
   && [ "$fifo_count" -eq 1 ] && [ "$fifo_dirs" -eq 0 ]; then
  ok "pre-existing FIFO cannot block or be removed by fallback allocation"
else
  not_ok "fallback allocation skips a pre-existing FIFO (status $status, ${fifo_elapsed}s, fifos $fifo_count, dirs $fifo_dirs)"
fi
find "$FIFO_TMP" -mindepth 1 -maxdepth 1 -type p -exec rm -f {} \;

NO_RMDIR_BIN="$CASE_ROOT/no-rmdir-bin"
mkdir -p "$NO_RMDIR_BIN"
printf '%s\n' '#!/bin/sh' 'exit 1' >"$NO_RMDIR_BIN/mktemp"
chmod +x "$NO_RMDIR_BIN/mktemp"
for no_rmdir_tool in sh dirname pwd jq git awk rm wc tr sleep mkdir setsid perl; do
  no_rmdir_path=$(command -v "$no_rmdir_tool" 2>/dev/null || true)
  [ -n "$no_rmdir_path" ] && ln -s "$no_rmdir_path" "$NO_RMDIR_BIN/$no_rmdir_tool"
done
: >"$CASE_ROOT/no-rmdir-log"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
  MOCK_GITLEAKS_LOG="$CASE_ROOT/no-rmdir-log" \
  PATH="$NO_RMDIR_BIN" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq 'gitleaks version temp fallback requires mkdir and rmdir' "$CASE_ROOT/err" \
   && [ ! -s "$CASE_ROOT/no-rmdir-log" ]; then
  ok "missing fallback cleanup helper fails before running the scanner"
else
  not_ok "fallback requires an available cleanup primitive (status $status)"
fi

BIND_ROOT="$CASE_ROOT/relative-binding"
BIND_PRIVATE="$BIND_ROOT/private-rel"
BIND_EXPLICIT="$BIND_ROOT/explicit-rel"
BIND_PATH="$BIND_ROOT/path-bin"
BIND_REPO="$BIND_ROOT/repo"
mkdir -p "$BIND_ROOT" "$BIND_REPO/sub"
make_scanner "$BIND_PRIVATE/gitleaks" '8.30.1-private-binding' 0
make_scanner "$BIND_EXPLICIT/gitleaks" '8.30.1-explicit-binding' 0
make_scanner "$BIND_PATH/gitleaks" '8.30.1-path-binding' 0
BIND_PRIVATE_CANON=$(CDPATH= cd -- "$BIND_PRIVATE" && pwd -P)
BIND_EXPLICIT_CANON=$(CDPATH= cd -- "$BIND_EXPLICIT" && pwd -P)
BIND_PATH_CANON=$(CDPATH= cd -- "$BIND_PATH" && pwd -P)
git -C "$BIND_REPO" -c init.templateDir= init -q
git -C "$BIND_REPO" config user.email test@example.com
git -C "$BIND_REPO" config user.name 'Agent Guard Tests'
printf '%s\n' baseline >"$BIND_REPO/README.md"
git -C "$BIND_REPO" add README.md
git -C "$BIND_REPO" commit -qm init
printf '%s\n' ordinary >"$BIND_REPO/clean.txt"
BIND_PAYLOAD=$(jq -nc --arg cwd "$BIND_REPO/sub" \
  '{tool_name:"Write",
    tool_input:{file_path:"../clean.txt",cwd:$cwd},
    tool_response:"ordinary"}')

: >"$CASE_ROOT/binding-log"
printf '%s' "$BIND_PAYLOAD" \
  | (cd "$BIND_ROOT" && env AGENT_GUARD_LOG_MODE=off \
      AGENT_GUARD_GITLEAKS_BIN_DIR=private-rel \
      MOCK_GITLEAKS_LOG="$CASE_ROOT/binding-log" \
      PATH="$BIND_PATH:$ORIGINAL_PATH" \
      "$GUARD" hook-post-tool) >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
private_versions=$(grep -Fc "$BIND_PRIVATE_CANON/gitleaks version" "$CASE_ROOT/binding-log" 2>/dev/null || true)
private_scans=$(grep -Fc "$BIND_PRIVATE_CANON/gitleaks stdin" "$CASE_ROOT/binding-log" 2>/dev/null || true)
if [ "$status" -eq 0 ] && [ "$private_versions" -eq 1 ] \
   && [ "$private_scans" -ge 1 ] \
   && ! grep -Fq "$BIND_PATH_CANON/gitleaks" "$CASE_ROOT/binding-log"; then
  ok "relative private selection stays bound across PostToolUse cwd changes"
else
  not_ok "relative private selection is reused after cwd changes (status $status, versions $private_versions, scans $private_scans)"
fi

: >"$CASE_ROOT/binding-log"
printf '%s' "$BIND_PAYLOAD" \
  | (cd "$BIND_ROOT" && env AGENT_GUARD_LOG_MODE=off \
      AGENT_GUARD_GITLEAKS_BIN=explicit-rel/gitleaks \
      AGENT_GUARD_GITLEAKS_BIN_DIR=private-rel \
      MOCK_GITLEAKS_LOG="$CASE_ROOT/binding-log" \
      PATH="$BIND_PATH:$ORIGINAL_PATH" \
      "$GUARD" hook-post-tool) >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
explicit_versions=$(grep -Fc "$BIND_EXPLICIT_CANON/gitleaks version" "$CASE_ROOT/binding-log" 2>/dev/null || true)
explicit_scans=$(grep -Fc "$BIND_EXPLICIT_CANON/gitleaks stdin" "$CASE_ROOT/binding-log" 2>/dev/null || true)
if [ "$status" -eq 0 ] && [ "$explicit_versions" -eq 1 ] \
   && [ "$explicit_scans" -ge 1 ] \
   && ! grep -Fq "$BIND_PRIVATE_CANON/gitleaks" "$CASE_ROOT/binding-log" \
   && ! grep -Fq "$BIND_PATH_CANON/gitleaks" "$CASE_ROOT/binding-log"; then
  ok "relative explicit selection stays bound across PostToolUse cwd changes"
else
  not_ok "relative explicit selection is reused after cwd changes (status $status, versions $explicit_versions, scans $explicit_scans)"
fi

REMOVED_BIN="$BIND_ROOT/removed-rel"
mkdir -p "$REMOVED_BIN"
sed "s|@LOG@|$CASE_ROOT/removed-log|g" >"$REMOVED_BIN/gitleaks" <<'STUB'
#!/bin/sh
printf '%s %s\n' "$0" "${1:-}" >>'@LOG@'
case "${1:-}" in
  version) chmod -x "$0"; printf '%s\n' '8.30.1'; exit 0 ;;
  stdin|dir) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$REMOVED_BIN/gitleaks"
: >"$CASE_ROOT/removed-log"
printf '%s' '{"session_id":"removed-ready-binary","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
  | (cd "$BIND_ROOT" && env AGENT_GUARD_LOG_MODE=off \
      AGENT_GUARD_INFRA_FAILURE_MODE=closed \
      AGENT_GUARD_WARNING_DIR="$CASE_ROOT/removed-warning" \
      AGENT_GUARD_GITLEAKS_BIN=removed-rel/gitleaks \
      PATH="$BIND_PATH:$ORIGINAL_PATH" \
      "$GUARD" hook-pre-tool) >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq 'selected gitleaks is not executable:' "$CASE_ROOT/err" \
   && ! grep -Fq "$BIND_PATH_CANON/gitleaks" "$CASE_ROOT/removed-log" \
   && ! grep -Fq ' stdin' "$CASE_ROOT/removed-log"; then
  ok "a ready binary that becomes non-executable fails closed without PATH fallback"
else
  not_ok "a changed ready binary fails closed without re-resolution (status $status)"
fi

SLOW_BIN="$CASE_ROOT/slow-bin"
SLOW_SCAN_MARKER="$CASE_ROOT/slow-scan-ran"
mkdir -p "$SLOW_BIN"
sed \
  -e "s|@SCAN_MARKER@|$SLOW_SCAN_MARKER|g" \
  -e "s|@SLEEP@|$REAL_SLEEP|g" \
  >"$SLOW_BIN/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in
  version) exec '@SLEEP@' 6 ;;
  stdin|dir) : >'@SCAN_MARKER@'; cat >/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$SLOW_BIN/gitleaks"
for mode in open closed; do
  rm -f "$SLOW_SCAN_MARKER"
  slow_start=$(date +%s)
  printf '%s' '{"session_id":"slow-version-'"$mode"'","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
    | env AGENT_GUARD_LOG_MODE=off \
        AGENT_GUARD_GITLEAKS_BIN="$SLOW_BIN/gitleaks" \
        AGENT_GUARD_INFRA_FAILURE_MODE="$mode" \
        AGENT_GUARD_WARNING_DIR="$CASE_ROOT/slow-warning-$mode" \
        "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  slow_elapsed=$(( $(date +%s) - slow_start ))
  expected_status=0
  [ "$mode" = closed ] && expected_status=2
  if [ "$status" -eq "$expected_status" ] \
     && [ "$slow_elapsed" -le 5 ] && [ ! -e "$SLOW_SCAN_MARKER" ] \
     && grep -Fq "AGENT_GUARD_INFRA_FAILURE_MODE=$mode" "$CASE_ROOT/err"; then
    ok "slow version probe follows $mode policy before a scanned route (${slow_elapsed}s)"
  else
    not_ok "slow version probe stays below the hook timeout in $mode mode (status $status, ${slow_elapsed}s)"
  fi
done

NO_SLEEP_BIN="$CASE_ROOT/no-sleep-bin"
mkdir -p "$NO_SLEEP_BIN"
for no_sleep_tool in sh dirname pwd jq git awk mktemp rm wc tr perl; do
  no_sleep_path=$(command -v "$no_sleep_tool" 2>/dev/null || true)
  [ -n "$no_sleep_path" ] && ln -s "$no_sleep_path" "$NO_SLEEP_BIN/$no_sleep_tool"
done
: >"$CASE_ROOT/no-sleep-log"
no_sleep_start=$(date +%s)
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$SLOW_BIN/gitleaks" \
  MOCK_GITLEAKS_LOG="$CASE_ROOT/no-sleep-log" \
  PATH="$NO_SLEEP_BIN" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
no_sleep_elapsed=$(( $(date +%s) - no_sleep_start ))
if [ "$status" -eq 2 ] && [ "$no_sleep_elapsed" -le 2 ] \
   && grep -Fq 'gitleaks version timeout helper is unavailable: sleep' "$CASE_ROOT/err" \
   && [ ! -s "$CASE_ROOT/no-sleep-log" ]; then
  ok "missing watchdog sleep fails immediately before running the scanner"
else
  not_ok "missing watchdog sleep cannot bypass the probe deadline (status $status, ${no_sleep_elapsed}s)"
fi

NO_LAUNCHER_BIN="$CASE_ROOT/no-launcher-bin"
mkdir -p "$NO_LAUNCHER_BIN"
for no_launcher_tool in sh dirname pwd jq git awk mktemp rm mkdir rmdir wc tr sleep head grep sed cat chmod; do
  no_launcher_path=$(command -v "$no_launcher_tool" 2>/dev/null || true)
  [ -n "$no_launcher_path" ] \
    && ln -s "$no_launcher_path" "$NO_LAUNCHER_BIN/$no_launcher_tool"
done
: >"$CASE_ROOT/no-launcher-log"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
  MOCK_GITLEAKS_LOG="$CASE_ROOT/no-launcher-log" \
  PATH="$NO_LAUNCHER_BIN" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] \
   && grep -Fq 'gitleaks version isolation requires setsid or perl' "$CASE_ROOT/err" \
   && [ ! -s "$CASE_ROOT/no-launcher-log" ]; then
  ok "check diagnoses a missing version isolation launcher before scanning"
else
  not_ok "check reports the missing version isolation launcher (status $status)"
fi

for launcher_diagnosis in setup doctor; do
  env AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
    MOCK_GITLEAKS_LOG="$CASE_ROOT/no-launcher-log" \
    PATH="$NO_LAUNCHER_BIN" \
    "$GUARD" "$launcher_diagnosis" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq 1 ] \
     && grep -Fq 'gitleaks version isolation requires setsid or perl' "$CASE_ROOT/err" \
     && grep -Fq 'install setsid (util-linux) or Perl' "$CASE_ROOT/err" \
     && ! grep -Fq 'install gitleaks (rerun with --install to opt in)' "$CASE_ROOT/err"; then
    ok "$launcher_diagnosis suggests the isolation dependency instead of reinstalling gitleaks"
  else
    not_ok "$launcher_diagnosis reports the correct launcher repair (status $status)"
  fi
done

printf '%s\n' '#!/bin/sh' 'exit 0' >"$NO_LAUNCHER_BIN/apt-get"
chmod +x "$NO_LAUNCHER_BIN/apt-get"
: >"$CASE_ROOT/no-launcher-log"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
  MOCK_GITLEAKS_LOG="$CASE_ROOT/no-launcher-log" \
  PATH="$NO_LAUNCHER_BIN" \
  "$GUARD" setup --install >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 1 ] \
   && grep -Fq 'sudo apt-get install -y util-linux' "$CASE_ROOT/err" \
   && ! grep -Fq -- '--gitleaks-checksum is required' "$CASE_ROOT/err" \
   && ! grep -Fq 'downloading gitleaks' "$CASE_ROOT/err" \
   && [ ! -s "$CASE_ROOT/no-launcher-log" ]; then
  ok "setup --install leaves a missing launcher nonzero without reinstalling gitleaks"
else
  not_ok "setup --install preserves the launcher repair boundary (status $status)"
fi
rm -f "$NO_LAUNCHER_BIN/apt-get"

BOTH_MISSING_INSTALL="$CASE_ROOT/both-missing-install"
BOTH_MISSING_DOWNLOAD="$CASE_ROOT/both-missing-download"
sed "s|@MARKER@|$BOTH_MISSING_DOWNLOAD|g" >"$NO_LAUNCHER_BIN/curl" <<'STUB'
#!/bin/sh
: >'@MARKER@'
exit 90
STUB
chmod +x "$NO_LAUNCHER_BIN/curl"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN_DIR="$BOTH_MISSING_INSTALL" \
  PATH="$NO_LAUNCHER_BIN" \
  "$GUARD" setup --install \
    --gitleaks-checksum 0000000000000000000000000000000000000000000000000000000000000000 \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 1 ] \
   && grep -Fq 'gitleaks  missing' "$CASE_ROOT/err" \
   && grep -Fq 'install setsid (util-linux) or Perl' "$CASE_ROOT/err" \
   && ! grep -Fq -- '--gitleaks-checksum is required' "$CASE_ROOT/err" \
   && [ ! -e "$BOTH_MISSING_DOWNLOAD" ] \
   && [ ! -e "$BOTH_MISSING_INSTALL/gitleaks" ]; then
  ok "setup --install preflights the launcher before downloading a missing gitleaks"
else
  not_ok "setup --install keeps both missing dependencies nonzero without downloading (status $status)"
fi
rm -f "$NO_LAUNCHER_BIN/curl"

REAL_SETSID=$(command -v setsid 2>/dev/null || true)
REAL_PERL=$(command -v perl 2>/dev/null || true)
LAUNCHER_ROOT="$CASE_ROOT/launcher-selection"
mkdir -p "$LAUNCHER_ROOT"
for launcher_kind in setsid perl; do
  launcher_bin="$LAUNCHER_ROOT/$launcher_kind-bin"
  mkdir -p "$launcher_bin"
  for launcher_tool in sh dirname pwd jq git awk mktemp rm mkdir rmdir wc tr sleep head grep sed cat chmod; do
    launcher_path=$(command -v "$launcher_tool" 2>/dev/null || true)
    [ -n "$launcher_path" ] && ln -s "$launcher_path" "$launcher_bin/$launcher_tool"
  done
  case "$launcher_kind" in
    setsid)
      if [ -n "$REAL_SETSID" ]; then
        ln -s "$REAL_SETSID" "$launcher_bin/setsid"
      else
        sed "s|@PERL@|$REAL_PERL|g" >"$launcher_bin/setsid" <<'STUB'
#!/bin/sh
exec '@PERL@' -MPOSIX \
  -e 'POSIX::setsid() >= 0 or exit 125; exec @ARGV; exit 126' "$@"
STUB
        chmod +x "$launcher_bin/setsid"
      fi
      ;;
    perl)
      if [ -n "$REAL_PERL" ]; then
        ln -s "$REAL_PERL" "$launcher_bin/perl"
      else
        sed "s|@SETSID@|$REAL_SETSID|g" >"$launcher_bin/perl" <<'STUB'
#!/bin/sh
while [ "$#" -gt 2 ]; do shift; done
exec '@SETSID@' "$@"
STUB
        chmod +x "$launcher_bin/perl"
      fi
      ;;
  esac

  : >"$CASE_ROOT/$launcher_kind-only-log"
  printf '%s' '{"session_id":"launcher-'"$launcher_kind"'","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
    | env AGENT_GUARD_LOG_MODE=off \
        AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
        AGENT_GUARD_WARNING_DIR="$CASE_ROOT/$launcher_kind-only-warning" \
        MOCK_GITLEAKS_LOG="$CASE_ROOT/$launcher_kind-only-log" \
        PATH="$launcher_bin" \
        "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  launcher_versions=$(grep -c ' version$' "$CASE_ROOT/$launcher_kind-only-log" 2>/dev/null || true)
  launcher_scans=$(grep -c ' stdin$' "$CASE_ROOT/$launcher_kind-only-log" 2>/dev/null || true)
  if [ "$status" -eq 0 ] && [ "$launcher_versions" -eq 1 ] \
     && [ "$launcher_scans" -ge 1 ]; then
    ok "$launcher_kind-only runtime probes and scans with no alternate launcher"
  else
    not_ok "$launcher_kind-only runtime remains operational (status $status, probes $launcher_versions, scans $launcher_scans)"
  fi
done

INSTALL_FIXTURE="$CASE_ROOT/install-fixture"
INSTALL_PAYLOAD="$INSTALL_FIXTURE/payload"
INSTALL_BIN="$INSTALL_FIXTURE/bin"
INSTALL_TARGET="$INSTALL_FIXTURE/target"
INSTALL_ARCHIVE="$INSTALL_FIXTURE/gitleaks.tar.gz"
INSTALL_PROBE_LOG="$INSTALL_FIXTURE/probe-log"
mkdir -p "$INSTALL_PAYLOAD" "$INSTALL_BIN"
REAL_GZIP=$(command -v gzip) || {
  printf '%s\n' 'gzip is required for the setup --install fixture' >&2
  exit 1
}
sed "s|@LOG@|$INSTALL_PROBE_LOG|g" >"$INSTALL_PAYLOAD/gitleaks" <<'STUB'
#!/bin/sh
printf '%s\n' "${1:-}" >>'@LOG@'
case "${1:-}" in
  version) printf '%s\n' '8.30.1'; exit 0 ;;
  stdin) cat >/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$INSTALL_PAYLOAD/gitleaks"
tar -czf "$INSTALL_ARCHIVE" -C "$INSTALL_PAYLOAD" gitleaks
INSTALL_CHECKSUM=$(shasum -a 256 "$INSTALL_ARCHIVE" | awk '{print $1}')
REAL_CP=$(command -v cp)
sed \
  -e "s|@ARCHIVE@|$INSTALL_ARCHIVE|g" \
  -e "s|@CP@|$REAL_CP|g" \
  >"$INSTALL_BIN/curl" <<'STUB'
#!/bin/sh
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; destination=$1 ;;
  esac
  shift
done
[ -n "$destination" ] || exit 2
exec '@CP@' '@ARCHIVE@' "$destination"
STUB
chmod +x "$INSTALL_BIN/curl"
for install_tool in sh dirname pwd jq git awk mktemp rm mkdir rmdir wc tr sleep head grep sed cat chmod uname shasum tar mv setsid perl; do
  install_path=$(command -v "$install_tool" 2>/dev/null || true)
  [ -n "$install_path" ] && ln -s "$install_path" "$INSTALL_BIN/$install_tool"
done
ln -s "$REAL_GZIP" "$INSTALL_BIN/gzip"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN_DIR="$INSTALL_TARGET" \
  PATH="$INSTALL_BIN" \
  "$GUARD" setup --install \
    --gitleaks-version 8.30.1 \
    --gitleaks-checksum "$INSTALL_CHECKSUM" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
install_probes=$(grep -c '^version$' "$INSTALL_PROBE_LOG" 2>/dev/null || true)
if [ "$status" -eq 0 ] && [ -x "$INSTALL_TARGET/gitleaks" ] \
   && [ "$install_probes" -eq 1 ] \
   && grep -Fq 'gitleaks  ok  (8.30.1;' "$CASE_ROOT/err"; then
  ok "setup --install revalidates full gitleaks readiness after installation"
else
  not_ok "setup --install verifies the installed scanner before success (status $status, probes $install_probes)"
fi

for mode in open closed; do
  : >"$CASE_ROOT/no-launcher-log"
  printf '%s' '{"session_id":"missing-launcher-'"$mode"'","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
    | env AGENT_GUARD_LOG_MODE=off \
        AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
        AGENT_GUARD_INFRA_FAILURE_MODE="$mode" \
        AGENT_GUARD_WARNING_DIR="$CASE_ROOT/no-launcher-warning-$mode" \
        MOCK_GITLEAKS_LOG="$CASE_ROOT/no-launcher-log" \
        PATH="$NO_LAUNCHER_BIN" \
        "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  expected_status=0
  [ "$mode" = closed ] && expected_status=2
  if [ "$status" -eq "$expected_status" ] \
     && grep -Fq "AGENT_GUARD_INFRA_FAILURE_MODE=$mode" "$CASE_ROOT/err" \
     && grep -Fq 'setsid or Perl process-isolation helper' "$CASE_ROOT/err" \
     && [ ! -s "$CASE_ROOT/no-launcher-log" ]; then
    ok "missing isolation launcher follows the $mode infrastructure policy"
  else
    not_ok "missing isolation launcher is not reported as a clean $mode scan (status $status)"
  fi
done

DESCENDANT_BIN="$CASE_ROOT/descendant-bin"
DESCENDANT_MARKER="$CASE_ROOT/orphan-descendant-ran"
mkdir -p "$DESCENDANT_BIN"
sed \
  -e "s|@MARKER@|$DESCENDANT_MARKER|g" \
  -e "s|@SLEEP@|$REAL_SLEEP|g" \
  >"$DESCENDANT_BIN/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in
  version) /bin/sh -c "'@SLEEP@' 4; : >'@MARKER@'" ;;
  stdin|dir) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$DESCENDANT_BIN/gitleaks"
rm -f "$DESCENDANT_MARKER"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$DESCENDANT_BIN/gitleaks" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
sleep 3
if [ "$status" -eq 2 ] && [ ! -e "$DESCENDANT_MARKER" ] \
   && grep -Fq 'gitleaks version command timed out after 2s' "$CASE_ROOT/err"; then
  ok "timed-out version wrappers cannot leave a descendant running"
else
  not_ok "version timeout terminates the complete scanner process group (status $status)"
fi

for launcher_kind in setsid perl; do
  rm -f "$DESCENDANT_MARKER"
  env AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_GITLEAKS_BIN="$DESCENDANT_BIN/gitleaks" \
    PATH="$LAUNCHER_ROOT/$launcher_kind-bin" \
    "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  sleep 3
  if [ "$status" -eq 2 ] && [ ! -e "$DESCENDANT_MARKER" ] \
     && grep -Fq 'gitleaks version command timed out after 2s' "$CASE_ROOT/err"; then
    ok "$launcher_kind-only timeout terminates scanner descendants"
  else
    not_ok "$launcher_kind-only timeout preserves process-tree cleanup (status $status)"
  fi
done

OVER_BIN="$CASE_ROOT/over-output-bin"
OVER_SCAN_MARKER="$CASE_ROOT/over-output-scan-ran"
mkdir -p "$OVER_BIN"
sed "s|@SCAN_MARKER@|$OVER_SCAN_MARKER|g" >"$OVER_BIN/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in
  version) exec awk 'BEGIN { for (i = 0; i < 20000; i++) print "8.30.1 oversized version output" }' ;;
  stdin|dir) : >'@SCAN_MARKER@'; cat >/dev/null; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$OVER_BIN/gitleaks"
rm -f "$OVER_SCAN_MARKER"
env AGENT_GUARD_LOG_MODE=off \
  AGENT_GUARD_GITLEAKS_BIN="$OVER_BIN/gitleaks" \
  "$GUARD" check >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
status=$?
if [ "$status" -eq 2 ] && [ ! -e "$OVER_SCAN_MARKER" ] \
   && grep -Fq 'gitleaks version output exceeded 8192 bytes' "$CASE_ROOT/err"; then
  ok "oversized version output is bounded and classified as a runtime failure"
else
  not_ok "oversized version output is bounded before scanning (status $status)"
fi

SIGNAL_TMP="$CASE_ROOT/probe-signal-tmp"
mkdir -p "$SIGNAL_TMP"
printf '%s' '{"session_id":"version-signal","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
  | env TMPDIR="$SIGNAL_TMP" AGENT_GUARD_LOG_MODE=off \
      AGENT_GUARD_GITLEAKS_BIN="$SLOW_BIN/gitleaks" \
      AGENT_GUARD_WARNING_DIR="$CASE_ROOT/signal-warning" \
      "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" &
signal_pid=$!
signal_unrelated="$SIGNAL_TMP/agent-guard-version-$signal_pid-output-9"
printf '%s\n' unrelated >"$signal_unrelated"
signal_i=0
while ! find "$SIGNAL_TMP" -maxdepth 1 -name 'agent-guard-run.*' 2>/dev/null | grep -q . \
      && [ "$signal_i" -lt 30 ]; do
  signal_i=$((signal_i + 1))
  sleep 0.1
done
kill -TERM "$signal_pid" 2>/dev/null || :
wait "$signal_pid" 2>/dev/null || :
signal_i=0
while find "$SIGNAL_TMP" -maxdepth 1 -name 'agent-guard-run.*' 2>/dev/null | grep -q . \
      && [ "$signal_i" -lt 30 ]; do
  signal_i=$((signal_i + 1))
  sleep 0.1
done
if ! find "$SIGNAL_TMP" -maxdepth 1 -name 'agent-guard-run.*' 2>/dev/null | grep -q . \
   && [ ! -e "$SLOW_SCAN_MARKER" ] \
   && [ "$(cat "$signal_unrelated" 2>/dev/null)" = unrelated ]; then
  ok "interrupting a version probe cleans its private workspace without scanning"
else
  not_ok "interrupted version probe cleans watchdog and private workspace"
fi
rm -f "$signal_unrelated"

FALLBACK_SIGNAL_TMP="$CASE_ROOT/fallback-probe-signal-tmp"
mkdir -p "$FALLBACK_SIGNAL_TMP"
printf '%s' '{"session_id":"fallback-version-signal","tool_name":"Write","tool_input":{"content":"ordinary"}}' \
  | env TMPDIR="$FALLBACK_SIGNAL_TMP" AGENT_GUARD_LOG_MODE=off \
      AGENT_GUARD_GITLEAKS_BIN="$SLOW_BIN/gitleaks" \
      AGENT_GUARD_WARNING_DIR="$CASE_ROOT/fallback-signal-warning" \
      PATH="$FAIL_MKTEMP_BIN:$ORIGINAL_PATH" \
      "$GUARD" hook-pre-tool >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" &
fallback_signal_pid=$!
signal_i=0
while ! find "$FALLBACK_SIGNAL_TMP" -maxdepth 1 -name 'agent-guard-version-*' 2>/dev/null | grep -q . \
      && [ "$signal_i" -lt 30 ]; do
  signal_i=$((signal_i + 1))
  sleep 0.1
done
kill -TERM "$fallback_signal_pid" 2>/dev/null || :
wait "$fallback_signal_pid" 2>/dev/null || :
if ! find "$FALLBACK_SIGNAL_TMP" -maxdepth 1 -name 'agent-guard-version-*' 2>/dev/null | grep -q . \
   && [ ! -e "$SLOW_SCAN_MARKER" ]; then
  ok "interrupting a fallback version probe removes its bounded output files"
else
  not_ok "interrupted fallback version probe cleans watchdog and output files"
fi

FAKE_JQ_BIN="$CASE_ROOT/fake-jq-bin"
mkdir -p "$FAKE_JQ_BIN"
sed "s|@REAL_JQ@|$REAL_JQ|g" >"$FAKE_JQ_BIN/jq" <<'STUB'
#!/bin/sh
case "$*" in
  *'(?<![0-9])1'*) exit 3 ;;
esac
exec '@REAL_JQ@' "$@"
STUB
chmod +x "$FAKE_JQ_BIN/jq"
make_scanner "$STATE_BIN/gitleaks" '8.30.1' 0
for capability_cmd in check doctor; do
  env AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_GITLEAKS_BIN="$STATE_BIN/gitleaks" \
    PATH="$FAKE_JQ_BIN:$ORIGINAL_PATH" \
    "$GUARD" "$capability_cmd" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq 0 ] \
     && grep -F 'jq regex lookbehind' "$CASE_ROOT/err" | grep -Fq 'unavailable' \
     && grep -Fq 'conservative shape-preserving fallback' "$CASE_ROOT/err"; then
    ok "$capability_cmd reports missing jq lookbehind without disabling the fallback"
  else
    not_ok "$capability_cmd reports jq lookbehind capability (status $status)"
  fi
done

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

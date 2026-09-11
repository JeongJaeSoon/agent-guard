#!/usr/bin/env sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-audit.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
export XDG_STATE_HOME="$CASE/state"
export AGENT_GUARD_LOG_MODE=on
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_INFRA_FAILURE_MODE=open
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
export_logs() { "$GUARD" logs export >"$CASE/export" 2>"$CASE/export.err"; }
has_outcome() { jq -es --arg o "$1" 'any(.[]; .phase == "finished" and .outcome == $o)' "$CASE/export" >/dev/null; }
new_case() { rm -rf "$XDG_STATE_HOME"; }
no_export_temps() { ! find "$1" -maxdepth 1 -name '.agent-guard-support.*' -print | grep -q .; }

printf '%s' '{"tool_name":"FutureTool","tool_input":{}}' | "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
check 'clean passthrough status and stdout unchanged' test ! -s "$CASE/out"
check 'export succeeds' export_logs
check 'successful invocation has start and finish linked by run ID' jq -es 'length == 2 and .[0].phase == "started" and .[1].phase == "finished" and .[0].run_id == .[1].run_id' "$CASE/export"
check 'pass does not imply a clean scan' has_outcome pass
if "$GUARD" logs >"$CASE/default-status.out" 2>"$CASE/default-status.err" \
   && grep -q 'Local diagnostic logging:' "$CASE/default-status.out"; then
  ok 'logs without a subcommand keeps the status default'
else
  bad 'logs without a subcommand keeps the status default'
fi

output_file="$CASE/agent-guard-support.jsonl"
"$GUARD" logs export --output "$output_file" >"$CASE/output-file.out" 2>"$CASE/output-file.err"
check 'output-file export succeeds' test -f "$output_file"
check 'output-file export preserves stdout export records' cmp "$CASE/export" "$output_file"
check 'output-file export leaves stdout empty' test ! -s "$CASE/output-file.out"
check 'output-file export reports its location on stderr' grep -Fq "$output_file" "$CASE/output-file.err"
case "$(stat -f '%Lp' "$output_file" 2>/dev/null || stat -c '%a' "$output_file" 2>/dev/null)" in
  600) ok 'output-file export is mode 0600' ;;
  *) bad 'output-file export is mode 0600' ;;
esac
check 'output-file export removes its temporary file' no_export_temps "$CASE"

printf 'keep\n' >"$CASE/existing-output"
if "$GUARD" logs export --output "$CASE/existing-output" >"$CASE/existing.out" 2>"$CASE/existing.err"; then
  bad 'output-file export refuses an existing target'
else
  ok 'output-file export refuses an existing target'
fi
check 'existing output target remains unchanged' sh -c 'test "$(cat "$1")" = keep' _ "$CASE/existing-output"
check 'existing output refusal leaves no temporary file' no_export_temps "$CASE"

mkdir "$CASE/directory-output"
if "$GUARD" logs export --output "$CASE/directory-output" >"$CASE/directory.out" 2>"$CASE/directory.err"; then
  bad 'output-file export refuses a directory target'
else
  ok 'output-file export refuses a directory target'
fi
check 'directory target remains a directory' test -d "$CASE/directory-output"
check 'directory target refusal leaves no temporary file' no_export_temps "$CASE"

if command -v mkfifo >/dev/null 2>&1 && mkfifo "$CASE/fifo-output" 2>/dev/null; then
  if "$GUARD" logs export --output "$CASE/fifo-output" >"$CASE/fifo.out" 2>"$CASE/fifo.err"; then
    bad 'output-file export refuses a FIFO target'
  else
    ok 'output-file export refuses a FIFO target'
  fi
  check 'FIFO target remains a FIFO' test -p "$CASE/fifo-output"
  check 'FIFO target refusal leaves no temporary file' no_export_temps "$CASE"
else
  printf '%s\n' 'skipping FIFO output test: mkfifo is unavailable'
fi

if ln -s "$CASE/existing-output" "$CASE/symlink-output" 2>/dev/null; then
  if "$GUARD" logs export --output "$CASE/symlink-output" >"$CASE/symlink.out" 2>"$CASE/symlink.err"; then
    bad 'output-file export refuses a symlink target'
  else
    ok 'output-file export refuses a symlink target'
  fi
else
  printf '%s\n' 'skipping output symlink test: filesystem does not support symlinks'
fi
check 'symlink target refusal leaves no temporary file' no_export_temps "$CASE"

if ln -s "$CASE/not-created" "$CASE/dangling-output" 2>/dev/null; then
  if "$GUARD" logs export --output "$CASE/dangling-output" >"$CASE/dangling.out" 2>"$CASE/dangling.err"; then
    bad 'output-file export refuses a dangling symlink target'
  else
    ok 'output-file export refuses a dangling symlink target'
  fi
  check 'dangling symlink target remains a symlink' test -L "$CASE/dangling-output"
  check 'dangling symlink refusal leaves no temporary file' no_export_temps "$CASE"
else
  printf '%s\n' 'skipping dangling output symlink test: filesystem does not support symlinks'
fi

mkdir "$CASE/real-parent"
if ln -s "$CASE/real-parent" "$CASE/symlink-parent" 2>/dev/null; then
  if "$GUARD" logs export --output "$CASE/symlink-parent/support.jsonl" >"$CASE/parent-symlink.out" 2>"$CASE/parent-symlink.err"; then
    bad 'output-file export refuses an immediate symlink parent'
  else
    ok 'output-file export refuses an immediate symlink parent'
  fi
  check 'symlink parent receives no completed export' test ! -e "$CASE/real-parent/support.jsonl"
  check 'symlink parent refusal leaves no temporary file' no_export_temps "$CASE/real-parent"
else
  printf '%s\n' 'skipping symlink parent test: filesystem does not support symlinks'
fi

if "$GUARD" logs export --output "$CASE/missing-parent/support.jsonl" >"$CASE/missing.out" 2>"$CASE/missing.err"; then
  bad 'output-file export requires an existing parent'
else
  ok 'output-file export requires an existing parent'
fi
check 'missing parent receives no completed export' test ! -e "$CASE/missing-parent/support.jsonl"

mkdir "$CASE/no-jq-bin"
for tool in dirname readlink mktemp id stat rm uname; do
  tool_path=$(command -v "$tool") || exit 1
  ln -s "$tool_path" "$CASE/no-jq-bin/$tool"
done
if PATH="$CASE/no-jq-bin" /bin/sh "$GUARD" logs export --output "$CASE/jq-missing.jsonl" >"$CASE/jq-missing.out" 2>"$CASE/jq-missing.err"; then
  bad 'output-file export fails when jq is unavailable'
else
  ok 'output-file export fails when jq is unavailable'
fi
check 'jq failure leaves no completed export' test ! -e "$CASE/jq-missing.jsonl"
check 'jq failure leaves no temporary file' no_export_temps "$CASE"

mkdir "$CASE/storage-real"
if ln -s "$CASE/storage-real" "$CASE/storage-symlink" 2>/dev/null; then
  if XDG_STATE_HOME="$CASE/storage-symlink" "$GUARD" logs export --output "$CASE/storage-unavailable.jsonl" >"$CASE/storage-unavailable.out" 2>"$CASE/storage-unavailable.err"; then
    bad 'output-file export fails when audit storage is unavailable'
  else
    ok 'output-file export fails when audit storage is unavailable'
  fi
  check 'storage failure leaves no completed export' test ! -e "$CASE/storage-unavailable.jsonl"
  check 'storage failure leaves no temporary file' no_export_temps "$CASE"
else
  printf '%s\n' 'skipping unavailable storage test: filesystem does not support symlinks'
fi

new_case
sentinel="private-path-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
jq -nc --arg p "/$sentinel/.env" '{tool_name:"Read",tool_input:{file_path:$p},session_id:$p}' \
  | "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
status=$?
check 'protected read stays blocked' test "$status" -eq 2
export_logs
check 'blocked outcome recorded' has_outcome blocked
if grep -Fq "$sentinel" "$CASE/export"; then bad 'log excludes raw paths and session identifiers'; else ok 'log excludes raw paths and session identifiers'; fi

for host in claude codex; do
  new_case
  printf '%s' '{"tool_name":"Read","tool_response":{"content":"email: reader@example.test"}}' \
    | AGENT_GUARD_HOOK_HOST="$host" AGENT_GUARD_PII_HOOK_MODE=mask "$GUARD" hook-post-tool >"$CASE/out" 2>"$CASE/err"
  status=$?
  check "$host mask retains status" test "$status" -eq 0
  export_logs
  check "$host mask is recorded without response contents" has_outcome masked
  if grep -q 'reader@example' "$CASE/export"; then bad "$host content-free logs"; else ok "$host content-free logs"; fi
done

for mode in open closed; do
  new_case
  printf '%s' '{"tool_name":"FutureTool","tool_input":{}}' \
    | AGENT_GUARD_GITLEAKS_BIN="$CASE/missing" AGENT_GUARD_INFRA_FAILURE_MODE="$mode" "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$mode" = open ]; then expected=0; else expected=2; fi
  check "$mode infrastructure policy retains status" test "$status" -eq "$expected"
  export_logs
  check "$mode infrastructure failure never reported as pass" has_outcome degraded
done

new_case
printf '%s' '{"tool_name":"FutureTool"}' | AGENT_GUARD_LOG_MODE=off "$GUARD" hook-pre-tool >/dev/null 2>&1
check 'opt-out creates no persistent log directory' test ! -e "$XDG_STATE_HOME"

mkdir -p "$CASE/external"
ln -s "$CASE/external" "$XDG_STATE_HOME"
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":".env"}}' | "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
status=$?
check 'unsafe log storage does not change denial' test "$status" -eq 2
check 'unsafe storage emits generic diagnostic' grep -q 'local diagnostic logging unavailable' "$CASE/err"
check 'symlink log path not followed' test ! -e "$CASE/external/agent-guard"
rm "$XDG_STATE_HOME"

new_case
i=0
while [ "$i" -lt 12 ]; do
  printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1 &
  i=$((i + 1))
done
wait
export_logs
check 'concurrent invocations preserve separate complete records' jq -es 'length == 24 and ([.[].run_id] | unique | length) == 12' "$CASE/export"

# Export reconstructs a whitelist even if a local user edited an event.
event=$(find "$XDG_STATE_HOME/agent-guard" -type f -name 'event-*' | head -1)
jq --arg x "$sentinel" '. + {raw_payload:$x}' "$event" >"$CASE/edited"
cat "$CASE/edited" >"$event"
export_logs
if grep -Fq "$sentinel" "$CASE/export"; then bad 'export strips arbitrary added fields'; else ok 'export strips arbitrary added fields'; fi
jq --arg x "$sentinel" '.version=$x' "$event" >"$CASE/edited"
cat "$CASE/edited" >"$event"
export_logs
if grep -Fq "$sentinel" "$CASE/export"; then bad 'export rejects poisoned allowed fields'; else ok 'export rejects poisoned allowed fields'; fi

new_case
AGENT_GUARD_OUTPUT_REDACT=off "$GUARD" exec sh -c 'sleep 2' >"$CASE/out" 2>"$CASE/err" &
pid=$!
i=0
while [ ! -d "$XDG_STATE_HOME/agent-guard" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.1
exit_marker="$XDG_STATE_HOME/agent-guard/event-1000000000-exit00"
printf 'preserve through exit\n' >"$exit_marker"
kill -TERM "$pid"
wait "$pid" 2>/dev/null
status=$?
check 'SIGTERM preserves conventional status' test "$status" -eq 143
check 'SIGTERM exit does not run retention cleanup' test -f "$exit_marker"
export_logs
check 'SIGTERM records interruption' has_outcome interrupted

new_case
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
event=$(find "$XDG_STATE_HOME/agent-guard" -type f -name 'event-*' | head -1)
i=0
now=$(date +%s)
while [ "$i" -lt 1005 ]; do
  suffix=$(printf '%06d' "$i")
  cp "$event" "$XDG_STATE_HOME/agent-guard/event-$now-$suffix"
  i=$((i + 1))
done
old_event="$XDG_STATE_HOME/agent-guard/event-1000000000-old123"
cp "$event" "$old_event"
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
count=$(find "$XDG_STATE_HOME/agent-guard" -type f -name 'event-*' | wc -l | tr -d ' ')
check 'retention bounds completed invocation files' test "$count" -le 1000
check 'old records removed on next invocation' test ! -f "$old_event"

# Retention never recurses, accepts only generated names, and performs at most
# one bounded listing per invocation (none on EXIT, including signal exit).
mkdir "$XDG_STATE_HOME/agent-guard/nested"
printf 'keep\n' >"$XDG_STATE_HOME/agent-guard/nested/event-1000000000-old123"
foreign="$XDG_STATE_HOME/agent-guard/event-1000000000-foreign"
printf 'keep\n' >"$foreign"
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
check 'retention ignores foreign names' test -f "$foreign"
check 'retention never recurses into foreign directories' test -f "$XDG_STATE_HOME/agent-guard/nested/event-1000000000-old123"

printf '%s audit log checks passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

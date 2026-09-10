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

printf '%s' '{"tool_name":"FutureTool","tool_input":{}}' | "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
check 'clean passthrough status and stdout unchanged' test ! -s "$CASE/out"
check 'export succeeds' export_logs
check 'successful invocation has start and finish linked by run ID' jq -es 'length == 2 and .[0].phase == "started" and .[1].phase == "finished" and .[0].run_id == .[1].run_id' "$CASE/export"
check 'pass does not imply a clean scan' has_outcome pass

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
kill -TERM "$pid"
wait "$pid" 2>/dev/null
status=$?
check 'SIGTERM preserves conventional status' test "$status" -eq 143
export_logs
check 'SIGTERM records interruption' has_outcome interrupted

new_case
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
event=$(find "$XDG_STATE_HOME/agent-guard" -type f -name 'event-*' | head -1)
i=0
while [ "$i" -lt 1005 ]; do cp "$event" "$XDG_STATE_HOME/agent-guard/event-1000000000-$i"; i=$((i + 1)); done
touch -t 200001010000 "$event"
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
count=$(find "$XDG_STATE_HOME/agent-guard" -type f -name 'event-*' | wc -l | tr -d ' ')
check 'retention bounds completed invocation files' test "$count" -le 1000
check 'old records removed on next invocation' test ! -f "$event"

printf '%s audit log checks passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

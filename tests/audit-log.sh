#!/usr/bin/env sh
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
# Capture these before fault-injection wrappers alter PATH. dash may apply
# preceding environment assignments before expanding later assignments.
REAL_MKDIR=$(command -v mkdir)
REAL_JQ=$(command -v jq)
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
probe_output_value() {
  probe_host=$1
  probe_file=$2
  case "$probe_host" in
    claude) jq -r '.hookSpecificOutput.updatedToolOutput.stdout' "$probe_file" 2>/dev/null ;;
    codex) jq -r '
        .hookSpecificOutput.additionalContext
        | sub("^Agent Guard sanitized tool output:\\n"; "")
        | fromjson
        | .stdout
      ' "$probe_file" 2>/dev/null ;;
  esac
}
no_export_temps() { ! find "$1" -maxdepth 1 -name '.agent-guard-support.*' -print | grep -q .; }
file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

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
if "$GUARD" logs --help >"$CASE/logs-help.out" 2>"$CASE/logs-help.err" \
   && grep -Fq 'Usage: agent-guard logs' "$CASE/logs-help.err"; then
  ok 'logs help exits successfully'
else
  bad 'logs help exits successfully'
fi

output_file="$CASE/agent-guard-support.jsonl"
"$GUARD" logs export --output "$output_file" >"$CASE/output-file.out" 2>"$CASE/output-file.err"
check 'output-file export succeeds' test -f "$output_file"
check 'output-file export preserves stdout export records' cmp "$CASE/export" "$output_file"
check 'output-file export leaves stdout empty' test ! -s "$CASE/output-file.out"
check 'output-file export reports its location on stderr' grep -Fq "$output_file" "$CASE/output-file.err"
case "$(file_mode "$output_file" 2>/dev/null)" in
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
old_probe_marker="$XDG_STATE_HOME/agent-guard/live-probe-1000000000-old123"
(umask 077; mkdir "$old_probe_marker")
tampered_event="$XDG_STATE_HOME/agent-guard/event-1000000000-bad123"
cp "$event" "$tampered_event"
tampered_probe_marker="$XDG_STATE_HOME/agent-guard/live-probe-1000000000-bad123"
(umask 077; mkdir "$tampered_probe_marker")
printf 'keep\n' >"$tampered_probe_marker/unexpected"
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
count=$(find "$XDG_STATE_HOME/agent-guard" -type f -name 'event-*' | wc -l | tr -d ' ')
check 'retention bounds completed invocation files' test "$count" -le 1000
check 'old records removed on next invocation' test ! -f "$old_event"
check 'retention removes the empty live-probe sidecar for a pruned event' \
  test ! -e "$old_probe_marker"
check 'retention still removes an event with a nonempty sidecar' \
  test ! -e "$tampered_event"
check 'retention does not recurse into a nonempty live-probe sidecar' \
  test -f "$tampered_probe_marker/unexpected"
rm -f "$tampered_probe_marker/unexpected"
rmdir "$tampered_probe_marker"

# Retention never recurses, accepts only generated names, and performs at most
# one bounded listing per invocation (none on EXIT, including signal exit).
mkdir "$XDG_STATE_HOME/agent-guard/nested"
printf 'keep\n' >"$XDG_STATE_HOME/agent-guard/nested/event-1000000000-old123"
foreign="$XDG_STATE_HOME/agent-guard/event-1000000000-foreign"
printf 'keep\n' >"$foreign"
foreign_probe_marker="$XDG_STATE_HOME/agent-guard/live-probe-1000000000-foreign"
(umask 077; mkdir "$foreign_probe_marker")
printf '%s' '{"tool_name":"FutureTool"}' | "$GUARD" hook-pre-tool >/dev/null 2>&1
check 'retention ignores foreign names' test -f "$foreign"
check 'retention ignores a sidecar without a strictly valid event id' \
  test -d "$foreign_probe_marker"
check 'retention never recurses into foreign directories' test -f "$XDG_STATE_HOME/agent-guard/nested/event-1000000000-old123"


# The live post-tool probe is the only masked value whose replacement names the
# invocation that produced it. Without that binding the expected output is a
# constant, so "the probe came back masked" cannot be told apart from a report
# that was written without running anything. Read the sentinel out of the binary
# so this file never carries a second copy of it.
probe_marker=$(sed -n 's/^LIVE_POST_TOOL_PROBE=//p' "$GUARD" | head -1)
check 'the live post-tool sentinel is readable from the binary' test -n "$probe_marker"
probe_secret=supersecretvalue123
for host in claude codex; do
  new_case
  jq -nc --arg marker "$probe_marker" --arg secret "$probe_secret" \
    '{session_id:"probe",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:("API_KEY=" + $secret + "\n" + $marker)}}' \
    | AGENT_GUARD_HOOK_HOST="$host" AGENT_GUARD_PII_HOOK_MODE=mask \
        "$GUARD" hook-post-tool >"$CASE/probe-$host.out" 2>"$CASE/probe-$host.err"
  probe_status=$?
  check "$host live probe keeps the host status" test "$probe_status" -eq 0
  check "$host live probe emits top-level JSON" \
    jq -e 'type == "object" and .hookSpecificOutput.hookEventName == "PostToolUse"' \
      "$CASE/probe-$host.out"
  probe_masked=$(probe_output_value "$host" "$CASE/probe-$host.out")
  export_logs
  probe_audit_id=$(jq -r '
      select(.phase == "finished"
             and .command == "hook-post-tool"
             and .host == $host
             and .outcome == "masked")
      | .run_id
    ' --arg host "$host" "$CASE/export" | tail -1)
  probe_id=$(printf '%s' "$probe_masked" | sed -n 's/.*run_id=\([0-9A-Za-z-]*\).*/\1/p')
  case "$probe_masked" in
    *"$probe_marker"*|*"$probe_secret"*) bad "$host live probe drops the raw sentinel and secret" ;;
    *) ok "$host live probe drops the raw sentinel and secret" ;;
  esac
  case "$probe_masked" in
    *'API_KEY=[REDACTED]'*) ok "$host normal secret keeps the bare placeholder" ;;
    *) bad "$host normal secret keeps the bare placeholder" ;;
  esac
  case "$probe_masked" in
    *"[REDACTED] agent-guard live probe run_id=$probe_audit_id"*)
      ok "$host live probe names the exact audit run id" ;;
    *) bad "$host live probe names the exact audit run id" ;;
  esac
  case "$probe_masked" in
    *'[PII:PHONE]'*) bad "$host live probe run id is not masked as a phone number" ;;
    *) ok "$host live probe run id is not masked as a phone number" ;;
  esac
  probe_id_shape=$(expr "$probe_id" : '[0-9][0-9]*-[0-9A-Za-z][0-9A-Za-z]*$') || probe_id_shape=0
  check "$host live probe replacement names a well-formed run id" test "$probe_id_shape" -gt 0
  if jq -es --arg id "$probe_id" --arg host "$host" \
       'any(.[]; .run_id == $id and .host == $host and .phase == "finished" and .command == "hook-post-tool" and .outcome == "masked")' \
       "$CASE/export" >/dev/null; then
    ok "$host live probe run id resolves to its masked post-tool record"
  else
    bad "$host live probe run id resolves to its masked post-tool record"
  fi
  if grep -Fq "$probe_secret" "$CASE/export"; then
    bad "$host live probe audit remains metadata-only"
  else
    ok "$host live probe audit remains metadata-only"
  fi
done
probe_replacement=$(printf '%s\n' "$probe_masked" | tail -1)
probe_sidecar="$XDG_STATE_HOME/agent-guard/live-probe-$probe_audit_id"
check 'live probe records a private directory sidecar' \
  sh -c 'test -d "$1" && test ! -L "$1" && test "$(find "$1" -mindepth 1 -maxdepth 1 -print)" = ""' \
    _ "$probe_sidecar"
check 'live probe sidecar is mode 0700' test "$(file_mode "$probe_sidecar")" = 700

# With logging off there is no record to point at, so the replacement must fall
# back to the bare placeholder rather than name an id nobody can look up.
for host in claude codex; do
  jq -nc --arg marker "$probe_marker" \
    '{session_id:"probe",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$marker}}' \
    | AGENT_GUARD_LOG_MODE=off AGENT_GUARD_PII_HOOK_MODE=mask \
        AGENT_GUARD_HOOK_HOST="$host" "$GUARD" hook-post-tool \
        >"$CASE/probe-off-$host.out" 2>"$CASE/probe-off-$host.err"
  probe_off=$(probe_output_value "$host" "$CASE/probe-off-$host.out")
  check "$host live probe falls back to the bare placeholder without logging" \
    test "$probe_off" = '[REDACTED]'

  jq -nc --arg marker "$probe_marker" \
    '{session_id:"probe",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$marker}}' \
    | XDG_STATE_HOME=relative AGENT_GUARD_LOG_MODE=on AGENT_GUARD_PII_HOOK_MODE=mask \
        AGENT_GUARD_HOOK_HOST="$host" "$GUARD" hook-post-tool \
        >"$CASE/probe-failed-$host.out" 2>"$CASE/probe-failed-$host.err"
  probe_failed=$(probe_output_value "$host" "$CASE/probe-failed-$host.out")
  check "$host live probe falls back to the bare placeholder when logging fails" \
    test "$probe_failed" = '[REDACTED]'
done

# A failed atomic sidecar creation must downgrade the first replacement to the
# bare placeholder rather than expose an id that cannot be trusted on re-entry.
fail_marker_dir="$CASE/fail-live-marker"
mkdir "$fail_marker_dir"
cat >"$fail_marker_dir/mkdir" <<'EOSH'
#!/bin/sh
case "$*" in
  *'/live-probe-'*) exit 1 ;;
esac
exec "${AGENT_GUARD_TEST_REAL_MKDIR:?}" "$@"
EOSH
chmod +x "$fail_marker_dir/mkdir"
jq -nc --arg marker "$probe_marker" \
  '{session_id:"probe-marker-failure",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$marker}}' \
  | PATH="$fail_marker_dir:$PATH" AGENT_GUARD_TEST_REAL_MKDIR="$REAL_MKDIR" \
      AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=claude \
      "$GUARD" hook-post-tool >"$CASE/probe-marker-failure.out" \
        2>"$CASE/probe-marker-failure.err"
probe_marker_failure=$(probe_output_value claude "$CASE/probe-marker-failure.out")
check 'live probe falls back to the bare placeholder when sidecar creation fails' \
  test "$probe_marker_failure" = '[REDACTED]'

# If the sentinel redactor fails after unrelated PII masking succeeds, the
# invocation may still finish masked but must not leave live-probe provenance.
fail_live_jq_dir="$CASE/fail-live-jq"
mkdir "$fail_live_jq_dir"
cat >"$fail_live_jq_dir/jq" <<'EOSH'
#!/bin/sh
case "$*" in
  *'def specs($s)'*) exit 1 ;;
esac
exec "${AGENT_GUARD_TEST_REAL_JQ:?}" "$@"
EOSH
chmod +x "$fail_live_jq_dir/jq"
jq -nc --arg marker "$probe_marker" \
  '{session_id:"probe-redactor-failure",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$marker,email:"reader@example.test"}}' \
  | PATH="$fail_live_jq_dir:$PATH" AGENT_GUARD_TEST_REAL_JQ="$REAL_JQ" \
      AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=claude \
      "$GUARD" hook-post-tool >"$CASE/probe-redactor-failure.out" \
        2>"$CASE/probe-redactor-failure.err"
check 'live-probe redactor failure conservatively replaces the complete response' \
  jq -e --arg marker "$probe_marker" '
      .hookSpecificOutput.updatedToolOutput.stdout == "[REDACTED]"
      and .hookSpecificOutput.updatedToolOutput.email == "[REDACTED]"
      and (.hookSpecificOutput.updatedToolOutput | tostring | contains($marker) | not)
    ' "$CASE/probe-redactor-failure.out"
export_logs
failed_redactor_id=$(jq -r --arg probe_id "$probe_audit_id" '
    select(.phase == "finished"
           and .command == "hook-post-tool"
           and .host == "claude"
           and .outcome == "masked"
           and .run_id != $probe_id)
    | .run_id
  ' "$CASE/export" | tail -1)
check 'failed live-probe redaction leaves no provenance sidecar' \
  test ! -e "$XDG_STATE_HOME/agent-guard/live-probe-$failed_redactor_id"

# Claude serializes its validated replacement without jq. Codex keeps a fixed,
# secret-free block response when its richer additionalContext envelope cannot
# be serialized, and removes provenance that response did not carry.
fail_envelope_jq_dir="$CASE/fail-envelope-jq"
mkdir "$fail_envelope_jq_dir"
cat >"$fail_envelope_jq_dir/jq" <<'EOSH'
#!/bin/sh
case "$*" in
  *'additionalContext:'*|*'updatedToolOutput:'*) exit 1 ;;
esac
exec "${AGENT_GUARD_TEST_REAL_JQ:?}" "$@"
EOSH
chmod +x "$fail_envelope_jq_dir/jq"
for host in claude codex; do
  envelope_state="$CASE/envelope-state-$host"
  jq -nc --arg marker "$probe_marker" \
    '{session_id:"probe-envelope-failure",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$marker}}' \
    | XDG_STATE_HOME="$envelope_state" PATH="$fail_envelope_jq_dir:$PATH" \
        AGENT_GUARD_TEST_REAL_JQ="$REAL_JQ" \
        AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST="$host" \
        "$GUARD" hook-post-tool >"$CASE/probe-envelope-$host.out" \
          2>"$CASE/probe-envelope-$host.err"
  XDG_STATE_HOME="$envelope_state" "$GUARD" logs export \
    >"$CASE/probe-envelope-$host.export" 2>"$CASE/probe-envelope-$host.export.err"
  envelope_id=$(jq -r --arg host "$host" '
      select(.phase == "finished"
             and .command == "hook-post-tool"
             and .host == $host
             and .outcome == "masked")
      | .run_id
    ' "$CASE/probe-envelope-$host.export" | tail -1)
  case "$host" in
    claude)
      check 'claude direct envelope emits one valid replacement without jq' \
        jq -e --arg id "$envelope_id" '
          .hookSpecificOutput.updatedToolOutput.stdout
          | contains("[REDACTED] agent-guard live probe run_id=" + $id)
        ' "$CASE/probe-envelope-$host.out"
      check 'claude direct envelope retains delivered live-probe provenance' \
        test -d "$envelope_state/agent-guard/live-probe-$envelope_id"
      ;;
    codex)
      check 'codex envelope serialization failure emits one fixed block response' \
        jq -e '
          .decision == "block"
          and .hookSpecificOutput.hookEventName == "PostToolUse"
          and (.hookSpecificOutput.additionalContext | type == "string")
          and (.hookSpecificOutput.additionalContext | contains("sanitized replacement could not be serialized safely"))
        ' "$CASE/probe-envelope-$host.out"
      check 'codex fixed envelope removes undelivered live-probe provenance' \
        test ! -e "$envelope_state/agent-guard/live-probe-$envelope_id"
      envelope_forgery="[REDACTED] agent-guard live probe run_id=$envelope_id"
      jq -nc --arg replacement "$envelope_forgery" \
        '{session_id:"probe-envelope-forgery",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
        | XDG_STATE_HOME="$envelope_state" AGENT_GUARD_PII_HOOK_MODE=mask \
            AGENT_GUARD_HOOK_HOST="$host" "$GUARD" hook-post-tool \
            >"$CASE/probe-envelope-forgery-$host.out" \
            2>"$CASE/probe-envelope-forgery-$host.err"
      envelope_forgery_masked=$(probe_output_value "$host" "$CASE/probe-envelope-forgery-$host.out")
      case "$envelope_forgery_masked" in
        *'[PII:PHONE]-'*) ok 'codex fixed envelope id does not forge provenance' ;;
        *) bad 'codex fixed envelope id does not forge provenance' ;;
      esac
      ;;
  esac
done

# A generated replacement travels back through PostToolUse as ordinary text.
# PII masking may preserve it only after the exact prior run id resolves to a
# finished/masked audit record; a prefix and plausible-looking id are not enough.
for host in claude codex; do
  jq -nc --arg replacement "$probe_replacement" \
    '{session_id:"probe-reentry",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
    | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST="$host" \
        "$GUARD" hook-post-tool >"$CASE/probe-reentry-$host.out" 2>"$CASE/probe-reentry-$host.err"
  if [ ! -s "$CASE/probe-reentry-$host.out" ]; then
    probe_reentry=$probe_replacement
  else
    probe_reentry=$(probe_output_value "$host" "$CASE/probe-reentry-$host.out")
  fi
  check "$host preserves a provenance-verified live probe replacement under PII masking" \
    test "$probe_reentry" = "$probe_replacement"
  case "$probe_reentry" in
    *'[PII:PHONE]'*) bad "$host verified live probe id is not masked as a phone number on re-entry" ;;
    *) ok "$host verified live probe id is not masked as a phone number on re-entry" ;;
  esac
done

failed_redactor_forgery="[REDACTED] agent-guard live probe run_id=$failed_redactor_id"
jq -nc --arg replacement "$failed_redactor_forgery" \
  '{session_id:"probe-failed-forgery",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=claude \
      "$GUARD" hook-post-tool >"$CASE/probe-failed-forgery.out" \
        2>"$CASE/probe-failed-forgery.err"
failed_redactor_forgery_masked=$(probe_output_value claude "$CASE/probe-failed-forgery.out")
case "$failed_redactor_forgery_masked" in
  *'[PII:PHONE]-'*) ok 'masked outcome after redactor failure does not forge provenance' ;;
  *) bad 'masked outcome after redactor failure does not forge provenance' ;;
esac

# A real masked audit record is still not live-probe provenance. Produce one
# with ordinary phone PII, then forge the live-probe prefix around that exact id.
jq -nc '{session_id:"ordinary-mask",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:"1234567890"}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=claude \
      "$GUARD" hook-post-tool >"$CASE/ordinary-mask.out" 2>"$CASE/ordinary-mask.err"
export_logs
ordinary_mask_id=$(jq -r --arg probe_id "$probe_audit_id" '
    select(.phase == "finished"
           and .command == "hook-post-tool"
           and .host == "claude"
           and .outcome == "masked"
           and .run_id != $probe_id)
    | .run_id
  ' "$CASE/export" | tail -1)
ordinary_id_shape=$(expr "$ordinary_mask_id" : '[0-9][0-9]*-[0-9A-Za-z][0-9A-Za-z]*$') || ordinary_id_shape=0
check 'ordinary PII masking produces a plausible audit run id' test "$ordinary_id_shape" -gt 0
check 'ordinary PII masking does not create live-probe provenance' \
  test ! -e "$XDG_STATE_HOME/agent-guard/live-probe-$ordinary_mask_id"
forged_probe="[REDACTED] agent-guard live probe run_id=$ordinary_mask_id"
for host in claude codex; do
  jq -nc --arg replacement "$forged_probe" \
    '{session_id:"probe-forged",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
    | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST="$host" \
        "$GUARD" hook-post-tool >"$CASE/probe-forged-$host.out" 2>"$CASE/probe-forged-$host.err"
  check "$host rewrites a forged live probe replacement" test -s "$CASE/probe-forged-$host.out"
  probe_forged_masked=$(probe_output_value "$host" "$CASE/probe-forged-$host.out")
  case "$probe_forged_masked" in
    *"$ordinary_mask_id"*) bad "$host ordinary masked event id does not forge live-probe provenance" ;;
    *'[PII:PHONE]-'*) ok "$host ordinary masked event id does not forge live-probe provenance" ;;
    *) bad "$host forged live probe id does not bypass PII masking" ;;
  esac
done

# Marker provenance fails closed on mode, type, and symlink tampering.
chmod 755 "$probe_sidecar"
jq -nc --arg replacement "$probe_replacement" \
  '{session_id:"probe-mode",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=claude \
      "$GUARD" hook-post-tool >"$CASE/probe-mode.out" 2>"$CASE/probe-mode.err"
probe_mode_masked=$(probe_output_value claude "$CASE/probe-mode.out")
case "$probe_mode_masked" in
  *'[PII:PHONE]-'*) ok 'live probe rejects a sidecar with unsafe mode' ;;
  *) bad 'live probe rejects a sidecar with unsafe mode' ;;
esac
chmod 700 "$probe_sidecar"

rmdir "$probe_sidecar"
printf 'not a marker\n' >"$probe_sidecar"
chmod 600 "$probe_sidecar"
jq -nc --arg replacement "$probe_replacement" \
  '{session_id:"probe-type",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
  | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=codex \
      "$GUARD" hook-post-tool >"$CASE/probe-type.out" 2>"$CASE/probe-type.err"
probe_type_masked=$(probe_output_value codex "$CASE/probe-type.out")
case "$probe_type_masked" in
  *'[PII:PHONE]-'*) ok 'live probe rejects a non-directory sidecar' ;;
  *) bad 'live probe rejects a non-directory sidecar' ;;
esac
rm -f "$probe_sidecar"
(umask 077; mkdir "$probe_sidecar")

probe_sidecar_target="$CASE/probe-sidecar-target"
(umask 077; mkdir "$probe_sidecar_target")
rmdir "$probe_sidecar"
if ln -s "$probe_sidecar_target" "$probe_sidecar" 2>/dev/null; then
  jq -nc --arg replacement "$probe_replacement" \
    '{session_id:"probe-symlink",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{},tool_response:{stdout:$replacement}}' \
    | AGENT_GUARD_PII_HOOK_MODE=mask AGENT_GUARD_HOOK_HOST=claude \
        "$GUARD" hook-post-tool >"$CASE/probe-symlink.out" 2>"$CASE/probe-symlink.err"
  probe_symlink_masked=$(probe_output_value claude "$CASE/probe-symlink.out")
  case "$probe_symlink_masked" in
    *'[PII:PHONE]-'*) ok 'live probe rejects a symlink sidecar' ;;
    *) bad 'live probe rejects a symlink sidecar' ;;
  esac
  rm -f "$probe_sidecar"
else
  printf '%s\n' 'skipping live-probe sidecar symlink test: filesystem does not support symlinks'
fi
(umask 077; mkdir "$probe_sidecar")
rmdir "$probe_sidecar_target"

# The same verified replacement may be pasted into a prompt without poisoning
# the session; the prompt guard's ordinary placeholder exemption still applies.
printf '{"session_id":"probe","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$probe_replacement" \
  >"$CASE/probe-prompt.json"
if "$GUARD" hook-user-prompt <"$CASE/probe-prompt.json" >"$CASE/probe-prompt.out" 2>/dev/null; then
  check 'the replacement is not blocked at the prompt guard' test ! -s "$CASE/probe-prompt.out"
else
  bad 'the replacement is not blocked at the prompt guard'
fi

printf '%s audit log checks passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

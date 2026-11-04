#!/bin/sh
# Controlled hypothesis probe; this does not reproduce the missing original CI evidence.
set -eu
out=/workspace/agent-guard-evidence/readiness-hypothesis
mkdir "$out"
cat > "$out/delayed-scanner" <<'SH'
#!/bin/sh
if [ "${1:-}" = version ]; then sleep 3; fi
exec /workspace/agent-guard-tools/gitleaks "$@"
SH
cat > "$out/failing-core" <<'SH'
#!/bin/sh
printf '{"partial":"unmasked"}'
exit 2
SH
chmod 755 "$out/delayed-scanner" "$out/failing-core"
printf '%s\n' '{"tool_name":"Read","tool_input":{},"tool_response":{"stdout":"API_KEY=perf-literal-tail","clean":"visible","type":"text"}}' > "$out/input.json"
for mode in healthy delayed; do
  scanner=/workspace/agent-guard-tools/gitleaks
  [ "$mode" != delayed ] || scanner="$out/delayed-scanner"
  status=0
  env AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off \
    AGENT_GUARD_GITLEAKS_BIN="$scanner" AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust \
    AGENT_GUARD_RUST_CORE_BIN="$out/failing-core" \
    /workspace/agent-guard-evidence/v3.7.0/bin/agent-guard hook-post-tool \
    < "$out/input.json" > "$out/$mode.stdout" 2> "$out/$mode.stderr" || status=$?
  printf '%s\n' "$status" > "$out/$mode.status"
done

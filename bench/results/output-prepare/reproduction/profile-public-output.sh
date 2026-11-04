#!/bin/sh
# Diagnostic instrumentation only. Never mix these samples with CLI benchmarks.
set -eu
cli=${1:?absolute public CLI required}
scanner=${2:?absolute scanner required}
driver=${3:?absolute built devtools required}
out=${4:?new absolute output directory required}
[ ! -e "$out" ] || exit 2
mkdir -p "$out/bin" "$out/samples"
out=$(CDPATH= cd -- "$out" && pwd -P)
export PROFILE_DRIVER="$driver" PROFILE_SAMPLES="$out/samples" PROFILE_SCANNER="$scanner"
for name in jq awk grep mktemp cat rm wc tr sha256sum; do
  real=$(command -v "$name")
  # The resolved system paths contain no user-controlled payload.
  printf '#!/bin/sh\nexec "$PROFILE_DRIVER" resource-sample "$PROFILE_SAMPLES/%s.$$" "%s" "$@"\n' "$name" "$real" > "$out/bin/$name"
  chmod 755 "$out/bin/$name"
done
cat > "$out/bin/gitleaks" <<'SH'
#!/bin/sh
case "${1:-}" in version) stage=scanner-readiness ;; *) stage=scanner-execution ;; esac
exec "$PROFILE_DRIVER" resource-sample "$PROFILE_SAMPLES/$stage.$$" "$PROFILE_SCANNER" "$@"
SH
chmod 755 "$out/bin/gitleaks"
jq -nc '{tool_name:"mcp__latency__read",tool_response:([range(100)|"API_KEY=perf-literal-\(.)"]+[range(4000)|"status"])}' > "$out/input.json"
(cd "$out"
env PATH="$out/bin:$PATH" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off \
  AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust \
  AGENT_GUARD_GITLEAKS_BIN="$out/bin/gitleaks" \
  "$driver" resource-sample "$out/cli.json" "$cli" hook-post-tool \
  < "$out/input.json" > "$out/output.json" 2> "$out/stderr.txt")
jq -e '.hookSpecificOutput.updatedToolOutput == ([range(100)|"API_KEY=[REDACTED]"]+[range(4000)|"status"])' "$out/output.json" > "$out/verified.txt"
for path in "$out"/samples/*; do
  label=${path##*/}
  jq -c --arg stage "${label%.*}" '. + {stage:$stage}' "$path"
done > "$out/rows.jsonl"
jq -s 'group_by(.stage) | map({stage:.[0].stage, invocations:length,
  wall_seconds:(map(.wall_seconds)|add),
  cpu_seconds:(map(.user_cpu_seconds + .system_cpu_seconds)|add),
  maximum_individual_child_rss_kib:(map(.max_child_peak_rss_kib)|max)})' "$out/rows.jsonl" > "$out/summary.json"

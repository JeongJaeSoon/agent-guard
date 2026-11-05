#!/bin/sh
# Exercise the opt-in pipeline using the same installed core for both commands.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
core=${1:?absolute qualified native core required}
scanner=${2:?absolute real scanner required}
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) target=x86_64-unknown-linux-musl ;;
  Linux:aarch64) target=aarch64-unknown-linux-musl ;;
  Darwin:x86_64) target=x86_64-apple-darwin ;;
  Darwin:arm64) target=aarch64-apple-darwin ;;
  *) exit 2 ;;
esac
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
cp -R "${AGENT_GUARD_TEST_PAYLOAD:-$ROOT/plugins/agent-guard}" "$case_dir/payload"
test -f "$case_dir/payload/scripts/output-pipeline-experiment.sh"
mkdir -p "$case_dir/payload/libexec"
name="agent-guard-redact-$target"
helper="$case_dir/payload/libexec/$name"
cli="$case_dir/payload/bin/agent-guard"
cp "$core" "$case_dir/real-core"
chmod 755 "$case_dir/real-core"
export FUSED_REAL_CORE="$case_dir/real-core" FUSED_PACKAGED_MARKER="$case_dir/used"
cat >"$helper" <<'CORE'
#!/bin/sh
printf '%s\n' "$1" >>"$FUSED_PACKAGED_MARKER"
exec "$FUSED_REAL_CORE" "$@"
CORE
chmod 755 "$helper"
(cd "$case_dir/payload/libexec" && shasum -a 256 "$name" >"$name.sha256")
cat >"$case_dir/partial" <<'PARTIAL'
#!/bin/sh
printf 'untrusted prefix' >"$2"
printf 'untrusted framing' >"$3"
printf 'prepared-v1\n'
exit 2
PARTIAL
chmod 755 "$case_dir/partial"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$scanner" AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_OUTPUT_REDACT=mask
unset AGENT_GUARD_RUST_CORE_BIN AGENT_GUARD_EXPERIMENTAL_REDACTOR
unset AI_AGENT
payload='{"tool_name":"Read","tool_input":{},"tool_response":{"stdout":"API_KEY=perf-literal-tail","clean":"visible","type":"text"}}'
count=0
for host in claude codex; do
  export AGENT_GUARD_HOOK_HOST="$host"
  for mode in healthy partial missing shell no-module source-healthy source-partial source-shell; do
    helper="$case_dir/payload/libexec/$name"
    unset AGENT_GUARD_RUST_CORE_BIN
    case "$mode" in
      source-*)
        # A Git marketplace cache has no bundled core. Use the same verified
        # standalone helper for preparation and the existing redactor override.
        mv "$case_dir/payload/libexec" "$case_dir/standalone-libexec"
        helper="$case_dir/standalone-libexec/$name"
        (cd "$case_dir/standalone-libexec" && shasum -a 256 -c "$name.sha256") >/dev/null
        export AGENT_GUARD_RUST_CORE_BIN="$helper"
        ;;
    esac
    export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused
    export AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$helper"
    : >"$FUSED_PACKAGED_MARKER"
    case "$mode" in
      partial|source-partial) AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$case_dir/partial" ;;
      missing) AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN="$case_dir/missing" ;;
      shell) unset AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN ;;
      source-shell) unset AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN AGENT_GUARD_RUST_CORE_BIN ;;
      no-module) mv "$case_dir/payload/scripts/output-pipeline-experiment.sh" "$case_dir/module" ;;
    esac
    printf '%s\n' "$payload" | "$cli" hook-post-tool >"$case_dir/actual"
    if [ "$host" = claude ]; then
      jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and
        .hookSpecificOutput.updatedToolOutput == {stdout:"API_KEY=[REDACTED]",clean:"visible",type:"text"}' "$case_dir/actual" >/dev/null
    else
      jq -e '.decision == "block" and .hookSpecificOutput.hookEventName == "PostToolUse" and
        (.hookSpecificOutput.additionalContext | ltrimstr("Agent Guard sanitized tool output:\n") | fromjson) ==
        {stdout:"API_KEY=[REDACTED]",clean:"visible",type:"text"}' "$case_dir/actual" >/dev/null
    fi
    case "$mode" in
      healthy|source-healthy)
        grep -qx prepare-v1 "$FUSED_PACKAGED_MARKER"
        grep -qx redact-v1 "$FUSED_PACKAGED_MARKER"
        ;;
      source-shell) test ! -s "$FUSED_PACKAGED_MARKER" ;;
      *) ! grep -qx prepare-v1 "$FUSED_PACKAGED_MARKER" ;;
    esac
    if [ "$mode" = source-partial ]; then
      grep -qx redact-v1 "$FUSED_PACKAGED_MARKER"
    fi
    if [ "$mode" = no-module ]; then
      mv "$case_dir/module" "$case_dir/payload/scripts/output-pipeline-experiment.sh"
    fi
    case "$mode" in
      source-*) mv "$case_dir/standalone-libexec" "$case_dir/payload/libexec" ;;
    esac
    count=$((count + 1))
    printf 'ok - %s installed fused %s preserves independent output\n' "$host" "$mode"
  done
done
printf 'passed: %s; shared packaged core, independent output, fallback and opt-out\n' "$count"

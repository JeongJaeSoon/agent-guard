#!/bin/sh
# Run the installed CLI boundary against real and deliberately broken helpers.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
core=${1:?absolute native core required}
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
mkdir -p "$case_dir/payload/libexec"
name="agent-guard-redact-$target"
helper="$case_dir/payload/libexec/$name"
cli="$case_dir/payload/bin/agent-guard"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$scanner" AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_OUTPUT_REDACT=mask
export NATIVE_UNVERIFIED_MARKER="$case_dir/unverified-executed"
unset AGENT_GUARD_RUST_CORE_BIN
payload='{"tool_name":"Read","tool_input":{},"tool_response":{"stdout":"API_KEY=perf-literal-tail","clean":"visible","type":"text"}}'
checksum() { (cd "$case_dir/payload/libexec" && shasum -a 256 "$name" > "$name.sha256"); }
count=0
for host in claude codex; do
  export AGENT_GUARD_HOOK_HOST="$host"
  printf '%s\n' "$payload" | AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell "$cli" hook-post-tool > "$case_dir/expected"
  grep -q REDACTED "$case_dir/expected"
  if grep -q perf-literal-tail "$case_dir/expected"; then
    echo 'shell expectation leaked the fixture secret' >&2; exit 1
  fi
  for fault in healthy missing corrupt checksum no-checksum no-execute error partial-zero empty-zero multiple-zero partial-error; do
    cp "$core" "$helper"
    chmod 755 "$helper"
    checksum
    case "$fault" in
      missing) rm "$helper" ;;
      corrupt)
        printf '#!/bin/sh\ntouch "$NATIVE_UNVERIFIED_MARKER"\nprintf '\''{}'\''\n' > "$helper" ;;
      checksum) printf 'incorrect\n' > "$helper.sha256" ;;
      no-checksum) rm "$helper.sha256" ;;
      no-execute) chmod 644 "$helper" ;;
      error) printf '#!/bin/sh\nexit 2\n' > "$helper"; checksum ;;
      partial-zero) printf '#!/bin/sh\nprintf '\''{"stdout":"perf-literal-tail"'\''\n' > "$helper"; checksum ;;
      empty-zero) printf '#!/bin/sh\nexit 0\n' > "$helper"; checksum ;;
      multiple-zero) printf '#!/bin/sh\nprintf '\''{}{}'\''\n' > "$helper"; checksum ;;
      partial-error) printf '#!/bin/sh\nprintf '\''{"stdout":"perf-literal-tail"}'\''\nexit 2\n' > "$helper"; checksum ;;
    esac
    printf '%s\n' "$payload" | AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust "$cli" hook-post-tool > "$case_dir/actual"
    cmp "$case_dir/expected" "$case_dir/actual"
    test ! -e "$NATIVE_UNVERIFIED_MARKER"
    (unset AGENT_GUARD_EXPERIMENTAL_REDACTOR
     printf '%s\n' "$payload" | "$cli" hook-post-tool) > "$case_dir/actual"
    cmp "$case_dir/expected" "$case_dir/actual"
    test ! -e "$NATIVE_UNVERIFIED_MARKER"
    count=$((count + 2))
    printf 'ok - %s packaged %s preserves full shell output\n' "$host" "$fault"
  done
done
# Prove selection reached the verified packaged helper; matching shell output
# alone could pass if native selection were accidentally disabled.
export NATIVE_TEST_CORE="$core" NATIVE_TEST_MARKER="$case_dir/used"
cat > "$helper" <<'WRAPPER'
#!/bin/sh
printf x >> "$NATIVE_TEST_MARKER"
exec "$NATIVE_TEST_CORE" "$@"
WRAPPER
chmod 755 "$helper"
checksum
printf '%s\n' "$payload" | AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust "$cli" hook-post-tool > "$case_dir/actual"
cmp "$case_dir/expected" "$case_dir/actual"
test -s "$NATIVE_TEST_MARKER"
rm "$NATIVE_TEST_MARKER"
(unset AGENT_GUARD_EXPERIMENTAL_REDACTOR
 printf '%s\n' "$payload" | "$cli" hook-post-tool) > "$case_dir/actual"
cmp "$case_dir/expected" "$case_dir/actual"
test -s "$NATIVE_TEST_MARKER"
rm "$NATIVE_TEST_MARKER"
printf '%s\n' "$payload" | AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell "$cli" hook-post-tool > "$case_dir/actual"
cmp "$case_dir/expected" "$case_dir/actual"
test ! -e "$NATIVE_TEST_MARKER"
printf '%s\n' "$payload" | AGENT_GUARD_EXPERIMENTAL_REDACTOR= "$cli" hook-post-tool > "$case_dir/actual"
cmp "$case_dir/expected" "$case_dir/actual"
test ! -e "$NATIVE_TEST_MARKER"
printf 'passed: %s; verified default/explicit native invocation and explicit shell/empty selection\n' "$count"

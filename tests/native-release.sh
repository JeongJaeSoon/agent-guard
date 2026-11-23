#!/bin/sh
# Release selection must reject stale, failed or corrupted workflow evidence.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
mkdir -p "$case_dir/bin" "$case_dir/artifacts"
export NATIVE_RELEASE_TEST_DIR="$case_dir"
sha=0123456789012345678901234567890123456789
cat > "$case_dir/bin/gh" <<'GH'
#!/bin/sh
case "$1" in
  api) cat "$NATIVE_RELEASE_TEST_DIR/runs.json" ;;
  run)
    name= destination=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) shift; name=$1 ;;
        --dir) shift; destination=$1 ;;
      esac
      shift
    done
    mkdir -p "$destination"
    cp -R "$NATIVE_RELEASE_TEST_DIR/artifacts/$name/." "$destination/"
    ;;
  *) exit 2 ;;
esac
GH
chmod 755 "$case_dir/bin/gh"
export PATH="$case_dir/bin:$PATH"
write_run() {
  jq -n --arg sha "$1" --arg conclusion "$2" \
    '{workflow_runs:[{id:1,head_sha:$sha,head_branch:"main",event:"push",status:"completed",conclusion:$conclusion}]}' > "$case_dir/runs.json"
}
write_run "$sha" success
# The script reads the helper pins of its own tree; run a copy beside pins
# that name the stand-in helper binaries below.
mkdir -p "$case_dir/tree/scripts" "$case_dir/tree/plugins/agent-guard/config" "$case_dir/tree/native/gitleaks-helper" "$case_dir/helper"
cp "$ROOT/scripts/prepare-native-release.sh" "$case_dir/tree/scripts/"
# It also reads the license table of its own tree: a helper archive must carry
# a notice for every module that table names.
licenses="$case_dir/tree/native/gitleaks-helper/module-licenses.txt"
cp "$ROOT/native/gitleaks-helper/module-licenses.txt" "$licenses"
notices="$case_dir/helper/THIRD_PARTY_LICENSES.txt"
write_notices() { awk '!/^#/ && NF { print "## " $1 " " $2 }' "$licenses" > "$notices"; }
write_notices
[ "$(grep -c . "$notices")" -gt 60 ]
printf 'stand-in license\n' > "$case_dir/helper/LICENSE"
prepare="$case_dir/tree/scripts/prepare-native-release.sh"
pins="$case_dir/tree/plugins/agent-guard/config/gitleaks-helper.sha256"
printf '#!/bin/sh\nexit 0\n' > "$case_dir/helper/agent-guard-gitleaks-helper"
printf '#!/bin/sh\nexit 1\n' > "$case_dir/helper/agent-guard-scan"
# $1 target: its stand-in helper archive, checksum, source record and test logs.
write_helper() {
  helper="agent-guard-gitleaks-helper-$1"
  tar -C "$case_dir/helper" -czf "$case_dir/artifacts/native-$1/$helper.tar.gz" agent-guard-gitleaks-helper agent-guard-scan THIRD_PARTY_LICENSES.txt LICENSE
  (cd "$case_dir/artifacts/native-$1" && shasum -a 256 "$helper.tar.gz" > "$helper.tar.gz.sha256")
  printf '%s\n' "$sha" > "$case_dir/artifacts/native-$1/$helper.build.txt"
  printf 'passed: 9\nfailed: 0\n' > "$case_dir/artifacts/native-$1/gitleaks-helper.log"
  printf 'passed: 9\nfailed: 0\n' > "$case_dir/artifacts/native-$1/gitleaks-helper-corpus.log"
}
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin; do
  (cd "$case_dir/helper" && shasum -a 256 agent-guard-gitleaks-helper agent-guard-scan) \
    | awk -v target="$target" '{ print $1 "  " target "/" $2 }' >> "$pins"
  dir="$case_dir/artifacts/native-$target"
  name="agent-guard-redact-$target"
  mkdir "$dir"
  write_helper "$target"
  printf '#!/bin/sh\nexit 0\n' > "$dir/$name"
  printf '%s\n' "$sha" > "$dir/$name.build.txt"
  (cd "$dir" && shasum -a 256 "$name" > "$name.sha256")
  printf '{"passed":1024,"failed":0}\n' > "$dir/differential.json"
  printf '{"passed":90,"failed":0,"native_invocation_verified":true}\n' > "$dir/integration.json"
done
sh "$prepare" "$sha" "$case_dir/good"
test "$(find "$case_dir/good" -type f | wc -l | tr -d ' ')" = 13
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin; do
  (cd "$case_dir/good" && shasum -a 256 -c "agent-guard-gitleaks-helper-$target.tar.gz.sha256" >/dev/null)
done
jq -e '.targets == ["x86_64-unknown-linux-musl","aarch64-unknown-linux-musl","aarch64-apple-darwin"]' \
  "$case_dir/good/native-validation.json" >/dev/null
printf 'ok - exact successful main artifacts are selected\n'
reject() {
  if sh "$prepare" "$sha" "$case_dir/reject-$1" > "$case_dir/out" 2> "$case_dir/err"; then
    echo "release gate accepted $1" >&2; exit 1
  fi
  printf 'ok - release rejects %s\n' "$1"
}
write_run "$sha" failure
reject failed-workflow
write_run 1123456789012345678901234567890123456789 success
reject wrong-workflow-commit
write_run "$sha" success
target=x86_64-unknown-linux-musl
dir="$case_dir/artifacts/native-$target"
name="agent-guard-redact-$target"
printf 'wrong\n' > "$dir/$name.build.txt"
reject wrong-build-commit
printf '%s\n' "$sha" > "$dir/$name.build.txt"
printf '{"passed":1023,"failed":1}\n' > "$dir/differential.json"
reject differential-failure
printf '{"passed":1024,"failed":0}\n' > "$dir/differential.json"
printf '{"passed":90,"failed":0,"native_invocation_verified":false}\n' > "$dir/integration.json"
reject missing-execution-proof
printf '{"passed":90,"failed":0,"native_invocation_verified":true}\n' > "$dir/integration.json"
helper="agent-guard-gitleaks-helper-$target"
printf 'wrong\n' > "$dir/$helper.build.txt"
reject helper-wrong-build-commit
write_helper "$target"
printf 'passed: 8\nfailed: 1\n' > "$dir/gitleaks-helper.log"
reject helper-test-failure
write_helper "$target"
printf 'passed: 0\nfailed: 0\n' > "$dir/gitleaks-helper-corpus.log"
reject helper-tests-that-did-not-run
write_helper "$target"
printf 'x' >> "$dir/$helper.tar.gz"
reject helper-archive-checksum-mismatch
# A sound archive whose client is not the one the release's CLI pins.
printf '#!/bin/sh\nexit 3\n' > "$case_dir/helper/agent-guard-scan"
write_helper "$target"
reject helper-binaries-the-cli-does-not-pin
printf '#!/bin/sh\nexit 1\n' > "$case_dir/helper/agent-guard-scan"
# A sound archive whose notices lack one module the helper links.
grep -Fxv '## golang.org/x/sys v0.30.0' "$notices" > "$notices.short"
[ "$(grep -c . "$notices.short")" = "$(($(grep -c . "$notices") - 1))" ]
mv "$notices.short" "$notices"
write_helper "$target"
reject helper-notices-without-a-linked-module
grep -Fq 'lack golang.org/x/sys v0.30.0' "$case_dir/err"
# One that lacks the Go standard library the binaries are built from.
write_notices
grep -v '^## std ' "$notices" > "$notices.short"
[ "$(grep -c . "$notices.short")" = "$(($(grep -c . "$notices") - 1))" ]
mv "$notices.short" "$notices"
write_helper "$target"
reject helper-notices-without-the-go-standard-library
grep -Fq 'lack std go' "$case_dir/err"
write_notices
# A sound archive with no notices file at all.
write_helper "$target"
tar -C "$case_dir/helper" -czf "$dir/$helper.tar.gz" agent-guard-gitleaks-helper agent-guard-scan LICENSE
(cd "$dir" && shasum -a 256 "$helper.tar.gz" > "$helper.tar.gz.sha256")
reject helper-archive-without-license-notices
grep -Fq 'carries no license notices' "$case_dir/err"
write_helper "$target"
# Control: with every stand-in restored the same artifacts are accepted again,
# so each rejection above came from its one change.
sh "$prepare" "$sha" "$case_dir/good-again"
printf 'ok - restored artifacts are selected again\n'
printf 'corruption\n' >> "$dir/$name"
reject checksum-mismatch

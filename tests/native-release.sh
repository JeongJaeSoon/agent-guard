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
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin; do
  dir="$case_dir/artifacts/native-$target"
  name="agent-guard-redact-$target"
  mkdir "$dir"
  printf '#!/bin/sh\nexit 0\n' > "$dir/$name"
  printf '%s\n' "$sha" > "$dir/$name.build.txt"
  (cd "$dir" && shasum -a 256 "$name" > "$name.sha256")
  printf '{"passed":1024,"failed":0}\n' > "$dir/differential.json"
  printf '{"passed":90,"failed":0,"native_invocation_verified":true}\n' > "$dir/integration.json"
done
sh "$ROOT/scripts/prepare-native-release.sh" "$sha" "$case_dir/good"
test "$(find "$case_dir/good" -type f | wc -l | tr -d ' ')" = 9
printf 'ok - exact successful main artifacts are selected\n'
reject() {
  if sh "$ROOT/scripts/prepare-native-release.sh" "$sha" "$case_dir/reject-$1" > "$case_dir/out" 2> "$case_dir/err"; then
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
printf 'corruption\n' >> "$dir/$name"
reject checksum-mismatch

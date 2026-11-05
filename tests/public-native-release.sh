#!/bin/sh
# Validate public release bytes, without substituting download responses.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
version=${1:?published version required}
out=${2:?new evidence directory required}
previous=${3:-3.7.1}
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
# Pin the actual published bootstrap for each qualified source release.
case "$previous" in
  3.6.14|3.6.15) previous_bootstrap_sha=2f6a796c1249d1a4ecdfa9b41507dcd61f34cc42dbb43013769c7cbac3112e12 ;;
  3.7.0|3.7.1) previous_bootstrap_sha=a28827587c60a02c44567a480e1e0e08bf517c407f64e8b28fa4450aee75b64e ;;
  *) echo 'unqualified previous release' >&2; exit 2 ;;
esac
[ ! -e "$out" ] || { echo 'refusing to overwrite release evidence' >&2; exit 2; }
mkdir -p "$out"
out=$(CDPATH='' cd -- "$out" && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
if command -v cargo || command -v rustc; then
  echo 'Rust compiler visible on runtime test PATH' >&2; exit 1
fi
uname -a > "$out/platform.txt"
base="https://github.com/JeongJaeSoon/agent-guard/releases/download/v$version"
mkdir -p "$case_dir/download" "$case_dir/home"
for asset in bootstrap.sh "agent-guard-$version.tar.gz" "agent-guard-$version.tar.gz.sha256" agent-guard.rb native-validation.json THIRD_PARTY_NOTICES.md; do
  curl -fsSL "$base/$asset" -o "$case_dir/download/$asset"
done
(cd "$case_dir/download" && shasum -a 256 -c "agent-guard-$version.tar.gz.sha256") > "$out/archive-checksum.txt"
cp "$case_dir/download/native-validation.json" "$out/"
published_sha=$(git ls-remote https://github.com/JeongJaeSoon/agent-guard.git "refs/tags/v$version" | awk 'NR == 1 {print $1}')
[ "${#published_sha}" -eq 40 ]
jq -e --arg sha "$published_sha" '.release_sha == $sha and (.targets|length) == 4' "$out/native-validation.json" >/dev/null
printf '%s\n' "$published_sha" > "$out/published-tag-sha.txt"
mkdir "$case_dir/payload"
tar -xzf "$case_dir/download/agent-guard-$version.tar.gz" -C "$case_dir/payload"
cmp "$case_dir/download/THIRD_PARTY_NOTICES.md" "$case_dir/payload/THIRD_PARTY_NOTICES.md"
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-apple-darwin aarch64-apple-darwin; do
  name="agent-guard-redact-$target"
  curl -fsSL "$base/$name" -o "$case_dir/download/$name"
  curl -fsSL "$base/$name.sha256" -o "$case_dir/download/$name.sha256"
  (cd "$case_dir/download" && shasum -a 256 -c "$name.sha256") >> "$out/native-checksums.txt"
  cmp "$case_dir/download/$name" "$case_dir/payload/libexec/$name"
done
archive_sha=$(awk '{print $1}' "$case_dir/download/agent-guard-$version.tar.gz.sha256")
grep -F "sha256 \"$archive_sha\"" "$case_dir/download/agent-guard.rb" > "$out/formula-checksum.txt"
export HOME="$case_dir/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_HOME="$case_dir/fresh" AGENT_GUARD_BIN_DIR="$case_dir/fresh-bin"
AGENT_GUARD_VERSION="$version" sh "$case_dir/download/bootstrap.sh" > "$out/fresh.log" 2>&1
"$AGENT_GUARD_BIN_DIR/agent-guard" version | grep -F "agent-guard $version"
"$AGENT_GUARD_BIN_DIR/agent-guard" smoke-test >> "$out/fresh.log" 2>&1
curl -fsSL "https://github.com/JeongJaeSoon/agent-guard/releases/download/v$previous/bootstrap.sh" -o "$case_dir/old-bootstrap.sh"
printf '%s  %s\n' "$previous_bootstrap_sha" "$case_dir/old-bootstrap.sh" | shasum -a 256 -c -
export AGENT_GUARD_HOME="$case_dir/upgrade" AGENT_GUARD_BIN_DIR="$case_dir/upgrade-bin"
AGENT_GUARD_VERSION="$previous" sh "$case_dir/old-bootstrap.sh" > "$out/old.log" 2>&1
"$AGENT_GUARD_BIN_DIR/agent-guard" version | grep -F "agent-guard $previous"
printf '%s\n' "$previous" > "$out/upgrade-from.txt"
printf 'preserve local note\n' > "$AGENT_GUARD_HOME/local-note"
AGENT_GUARD_VERSION="$version" "$AGENT_GUARD_BIN_DIR/agent-guard" update > "$out/update.log" 2>&1
"$AGENT_GUARD_BIN_DIR/agent-guard" version | grep -F "agent-guard $version"
grep -F 'preserve local note' "$AGENT_GUARD_HOME/local-note"
"$AGENT_GUARD_BIN_DIR/agent-guard" smoke-test >> "$out/update.log" 2>&1
(cd "$AGENT_GUARD_HOME/libexec" && shasum -a 256 -c ./*.sha256) >> "$out/native-checksums.txt"
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) target=x86_64-unknown-linux-musl ;;
  Linux:aarch64) target=aarch64-unknown-linux-musl ;;
  Darwin:x86_64) target=x86_64-apple-darwin ;;
  Darwin:arm64) target=aarch64-apple-darwin ;;
  *) exit 2 ;;
esac
# Test the downloaded CLI and helper together, not the checkout's CLI.
AGENT_GUARD_TEST_PAYLOAD="$AGENT_GUARD_HOME" sh "$ROOT/tests/native-packaged.sh" \
  "$AGENT_GUARD_HOME/libexec/agent-guard-redact-$target" "$(command -v gitleaks)" > "$out/fallback.log"
if [ -f "$AGENT_GUARD_HOME/scripts/output-pipeline-experiment.sh" ]; then
  AGENT_GUARD_TEST_PAYLOAD="$AGENT_GUARD_HOME" sh "$ROOT/tests/fused-packaged.sh" \
    "$AGENT_GUARD_HOME/libexec/agent-guard-redact-$target" "$(command -v gitleaks)" > "$out/fused-packaged.log"
fi
printf 'passed: public assets, fresh install, %s update, scanner and host fallback\n' "$previous"

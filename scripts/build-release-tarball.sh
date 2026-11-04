#!/usr/bin/env sh
set -eu

version=${1:?version required}
output=${2:-agent-guard-${version}.tar.gz}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
stage=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

cp -R "$ROOT/plugins/agent-guard/." "$stage/"
# Qualification and release callers provide already executed, native artifacts.
# Source-only archives retain the shell implementation and do not build/download.
if [ -n "${AGENT_GUARD_NATIVE_ARTIFACT_DIR:-}" ]; then
  mkdir -p "$stage/libexec"
  for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
    x86_64-apple-darwin aarch64-apple-darwin; do
    name="agent-guard-redact-$target"
    source="$AGENT_GUARD_NATIVE_ARTIFACT_DIR/$name"
    [ -f "$source" ] && [ ! -L "$source" ] && [ -f "$source.sha256" ] && [ ! -L "$source.sha256" ] \
      || { echo "missing regular native artifact: $name" >&2; exit 2; }
    expected=$(cat "$source.sha256")
    actual=$(CDPATH= cd -- "$AGENT_GUARD_NATIVE_ARTIFACT_DIR" && shasum -a 256 "$name")
    [ "$actual" = "$expected" ] || { echo "native artifact checksum mismatch: $name" >&2; exit 2; }
    cp "$source" "$source.sha256" "$stage/libexec/"
    chmod 755 "$stage/libexec/$name"
  done
fi
cp "$ROOT"/README*.md "$stage/"
cp "$ROOT/CHANGELOG.md" "$stage/CHANGELOG.md"
mkdir -p "$stage/docs"
cp "$ROOT/docs/demo.gif" "$stage/docs/demo.gif"
mkdir -p "$stage/docs/assets"
cp "$ROOT/docs/assets/icon.png" "$stage/docs/assets/icon.png"
# The standalone archive replaces the plugin README with the repository README.
# Ship user guides and their translations for offline README navigation.
# Developer notes, experiment goals and reports belong to the source checkout.
for guide in installation installation.ko installation.ja \
  verification verification.ko verification.ja configuration integrations operations; do
  cp "$ROOT/docs/$guide.md" "$stage/docs/"
done
cp "$ROOT/install.sh" "$stage/install.sh"
cp -R "$ROOT/deployment" "$stage/deployment"
tar -C "$stage" -czf "$output" .

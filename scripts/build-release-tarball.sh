#!/usr/bin/env sh
set -eu

version=${1:?version required}
output=${2:-agent-guard-${version}.tar.gz}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
stage=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

cp -R "$ROOT/plugins/agent-guard/." "$stage/"
cp "$ROOT/README.md" "$stage/README.md"
cp "$ROOT/CHANGELOG.md" "$stage/CHANGELOG.md"
mkdir -p "$stage/docs"
cp "$ROOT/docs/demo.gif" "$stage/docs/demo.gif"
# The standalone archive replaces the plugin README with the repository README.
# Ship every repository Markdown guide it links to so that README navigation is
# useful without cloning the repository.
for doc in "$ROOT"/docs/*.md; do
  [ -f "$doc" ] || continue
  cp "$doc" "$stage/docs/"
done
cp "$ROOT/install.sh" "$stage/install.sh"
cp -R "$ROOT/deployment" "$stage/deployment"
tar -C "$stage" -czf "$output" .

#!/usr/bin/env sh
set -eu

version=${1:?version required}
output=${2:-agent-guard-${version}.tar.gz}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
stage=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

cp -R "$ROOT/plugins/agent-guard/." "$stage/"
cp "$ROOT/install.sh" "$stage/install.sh"
cp "$ROOT/managed-install.sh" "$stage/managed-install.sh"
cp -R "$ROOT/deployment" "$stage/deployment"
mkdir -p "$stage/docs"
cp "$ROOT/docs/managed-deployment.md" "$stage/docs/managed-deployment.md"
tar -C "$stage" -czf "$output" .

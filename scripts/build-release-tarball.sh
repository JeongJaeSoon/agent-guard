#!/usr/bin/env sh
set -eu

version=${1:?version required}
output=${2:-agent-guard-${version}.tar.gz}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
stage=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM

cp -R "$ROOT/plugins/agent-guard/." "$stage/"
cp "$ROOT/install.sh" "$stage/install.sh"
tar -C "$stage" -czf "$output" .

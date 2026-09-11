#!/usr/bin/env sh
# Verify that the standalone release carries the Markdown documents referenced
# by its root README. This stays offline and exercises the actual tar builder.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-release-docs.XXXXXX")
trap 'rm -rf "$CASE"' EXIT INT TERM

archive="$CASE/agent-guard.tar.gz"
stage="$CASE/stage"
"$ROOT/scripts/build-release-tarball.sh" test "$archive"
mkdir "$stage"
tar -xzf "$archive" -C "$stage"

[ -f "$stage/docs/installation.md" ] \
  || { printf '%s\n' 'release archive is missing docs/installation.md' >&2; exit 1; }
[ -f "$stage/CHANGELOG.md" ] \
  || { printf '%s\n' 'release archive is missing CHANGELOG.md' >&2; exit 1; }

# Only relative Markdown links are archive members. Fragment-only links are
# internal to README, and remote/absolute links intentionally resolve elsewhere.
links=$(grep -oE '\]\(([^)#]+\.md)(#[^)]*)?\)' "$stage/README.md" 2>/dev/null \
  | sed -E 's/^\]\(//; s/#.*\)$//; s/\)$//' || true)
printf '%s\n' "$links" | while IFS= read -r link; do
  [ -n "$link" ] || continue
  case "$link" in http://*|https://*|/*) continue ;; esac
  [ -f "$stage/$link" ] \
    || { printf '%s\n' "release archive README link is missing: $link" >&2; exit 1; }
done

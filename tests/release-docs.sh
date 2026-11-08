#!/usr/bin/env sh
# Verify offline navigation from every shipped README and translated entry guide
# against an archive produced by the actual release builder.
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

for internal in README.md native-redactor.md development; do
  [ ! -e "$stage/docs/$internal" ] \
    || { printf '%s\n' "release archive includes repository-only documentation: $internal" >&2; exit 1; }
done

for source in "$ROOT"/README*.md "$ROOT"/docs/installation*.md "$ROOT"/docs/verification*.md \
  "$ROOT/docs/configuration.md" "$ROOT/docs/integrations.md" "$ROOT/docs/operations.md"; do
  relative=${source#"$ROOT"/}
  document="$stage/$relative"
  cmp -s "$source" "$document" \
    || { printf '%s\n' "release archive document is missing or differs: $relative" >&2; exit 1; }
  directory=$(dirname -- "$document")

  # Fragment-only links stay in the document; remote and absolute links are not
  # archive members. Resolve relative Markdown links from each document's folder.
  links=$(grep -oE '\]\(([^)#]+\.md)(#[^)]*)?\)' "$document" 2>/dev/null \
    | sed -E 's/^\]\(//; s/#.*\)$//; s/\)$//' || true)
  printf '%s\n' "$links" | while IFS= read -r link; do
    [ -n "$link" ] || continue
    case "$link" in http://*|https://*|/*) continue ;; esac
    [ -f "$directory/$link" ] \
      || { printf '%s\n' "release archive document link is missing: $relative -> $link" >&2; exit 1; }
  done
done

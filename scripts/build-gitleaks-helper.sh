#!/bin/sh
# Build the opt-in warm gitleaks helper and its scan client (#537) on the
# machine that will run them. The helper links the gitleaks library with the
# build tag, flags and module versions of the public gitleaks release, and the
# build fails if any linked module differs from release-modules.txt.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC="$ROOT/native/gitleaks-helper"
out=${1:?output directory required}
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd -P)
GITLEAKS_VERSION=8.30.1
export CGO_ENABLED=0 GOFLAGS=-mod=readonly
(
  cd "$SRC"
  go build -trimpath -buildvcs=false -tags gore2regex \
    -ldflags "-s -w -X=github.com/zricethezav/gitleaks/v8/version.Version=$GITLEAKS_VERSION" \
    -o "$out/" ./cmd/agent-guard-scan ./cmd/agent-guard-gitleaks-helper
)
helper="$out/agent-guard-gitleaks-helper"
client="$out/agent-guard-scan"
go version -m "$helper" | awk '$1 == "dep" { print $2, $3, $4 }' | LC_ALL=C sort >"$out/helper-modules.txt"
if ! cmp -s "$out/helper-modules.txt" "$SRC/release-modules.txt"; then
  echo 'helper modules differ from the gitleaks release:' >&2
  diff "$SRC/release-modules.txt" "$out/helper-modules.txt" >&2 || :
  exit 1
fi
# The client must stay small: the standard library and golang.org/x/sys only.
client_modules=$(go version -m "$client" | awk '$1 == "dep" { print $2 }')
[ "$client_modules" = golang.org/x/sys ] || {
  echo "unexpected client modules: $client_modules" >&2
  exit 1
}
[ "$("$helper" version)" = "gitleaks $GITLEAKS_VERSION; regex engine github.com/wasilibs/go-re2; protocol 1" ] || {
  echo 'helper does not report the pinned gitleaks and engine' >&2
  exit 1
}
{
  uname -srm
  go version
  go version -m "$helper"
  go version -m "$client"
} >"$out/build.txt"
(cd "$out" && shasum -a 256 agent-guard-gitleaks-helper agent-guard-scan >SHA256SUMS)

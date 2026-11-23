#!/bin/sh
# Build the warm gitleaks helper and its scan client (#537) on the machine
# that will run them. The helper links the gitleaks library with the build
# tag, flags and module versions of the public gitleaks release, and the
# build fails if any linked module differs from release-modules.txt.
#
#   sh scripts/build-gitleaks-helper.sh OUT_DIR
#   sh scripts/build-gitleaks-helper.sh OUT_DIR TARGET ARTIFACT_DIR
#   sh scripts/build-gitleaks-helper.sh --print-pins
#
# With TARGET (the running platform, named as the native artifacts are) the
# two binaries must also equal the checksums the CLI pins for that target in
# plugins/agent-guard/config/gitleaks-helper.sha256, and ARTIFACT_DIR gets the
# release asset agent-guard-gitleaks-helper-TARGET.tar.gz with its .sha256 and
# .build.txt (#569). --print-pins cross-builds every target without running
# it and prints the lines of that pin file; the build is reproducible, so the
# release build on each platform must produce the same bytes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC="$ROOT/native/gitleaks-helper"
PINS="$ROOT/plugins/agent-guard/config/gitleaks-helper.sha256"
TARGETS='x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin'
GITLEAKS_VERSION=8.30.1
# The helper must match the official release toolchain too (the engine check
# compares it), so a newer installed Go fetches this one.
export CGO_ENABLED=0 GOFLAGS=-mod=readonly GOTOOLCHAIN=go1.24.11

# $1 output directory; GOOS and GOARCH, when set, select another platform.
build() {
  (
    cd "$SRC"
    go build -trimpath -buildvcs=false -tags gore2regex \
      -ldflags "-s -w -X=github.com/zricethezav/gitleaks/v8/version.Version=$GITLEAKS_VERSION" \
      -o "$1/" ./cmd/agent-guard-scan ./cmd/agent-guard-gitleaks-helper
  )
}
sums() { (cd "$1" && shasum -a 256 agent-guard-gitleaks-helper agent-guard-scan); }
# The pin file's lines for target $2, from the sums of directory $1.
pin_lines() { sums "$1" | awk -v target="$2" '{ print $1 "  " target "/" $2 }'; }

if [ "${1:-}" = --print-pins ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' 0
  for target in $TARGETS; do
    case "$target" in
      x86_64-unknown-linux-musl) os=linux arch=amd64 ;;
      aarch64-unknown-linux-musl) os=linux arch=arm64 ;;
      aarch64-apple-darwin) os=darwin arch=arm64 ;;
    esac
    mkdir "$tmp/$target"
    GOOS=$os GOARCH=$arch build "$tmp/$target"
    pin_lines "$tmp/$target" "$target"
  done
  exit 0
fi

out=${1:?output directory required}
target=${2:-}
artifacts=${3:-}
if [ -n "$target" ]; then
  [ -n "$artifacts" ] || { echo 'artifact directory required with a target' >&2; exit 2; }
  case "$(uname -s):$(uname -m):$target" in
    Linux:x86_64:x86_64-unknown-linux-musl|Linux:aarch64:aarch64-unknown-linux-musl|Darwin:arm64:aarch64-apple-darwin) ;;
    *) echo 'build target must match the native runner' >&2; exit 2 ;;
  esac
fi
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd -P)
build "$out"
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
sums "$out" >"$out/SHA256SUMS"

[ -n "$target" ] || exit 0
# The CLI installs a released helper only when it matches these pins, so a
# build that differs must fail here, before anything is published.
pin_lines "$out" "$target" >"$out/built-pins.txt"
grep -F "  $target/" "$PINS" >"$out/expected-pins.txt" || :
if ! cmp -s "$out/expected-pins.txt" "$out/built-pins.txt"; then
  echo "built helper differs from the pinned checksums for $target in ${PINS#"$ROOT"/}." >&2
  echo 'If the helper sources or toolchain changed on purpose, replace its lines with:' >&2
  cat "$out/built-pins.txt" >&2
  exit 1
fi
mkdir -p "$artifacts"
artifacts=$(CDPATH= cd -- "$artifacts" && pwd -P)
name="agent-guard-gitleaks-helper-$target"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' 0
cp "$helper" "$client" "$out/SHA256SUMS" "$ROOT/THIRD_PARTY_NOTICES.md" "$stage/"
chmod 755 "$stage/agent-guard-gitleaks-helper" "$stage/agent-guard-scan"
tar -C "$stage" -czf "$artifacts/$name.tar.gz" agent-guard-gitleaks-helper agent-guard-scan SHA256SUMS THIRD_PARTY_NOTICES.md
(cd "$artifacts" && shasum -a 256 "$name.tar.gz" >"$name.tar.gz.sha256")
{
  git -C "$ROOT" rev-parse HEAD
  cat "$out/build.txt"
} >"$artifacts/$name.build.txt"

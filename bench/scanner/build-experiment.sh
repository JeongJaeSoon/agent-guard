#!/bin/sh
# Isolated dependency experiment. These binaries are not release assets.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
out=${1:?new absolute output directory required}
case "$out" in /*) ;; *) exit 2 ;; esac
[ ! -e "$out" ] || { echo 'refusing to overwrite evidence' >&2; exit 2; }
[ "$(go env GOVERSION)" = go1.26.0 ] || { echo 'Go 1.26.0 required for both arms' >&2; exit 2; }
mkdir -p "$out/control" "$out/candidate"
git init -q "$out/source"
git -C "$out/source" remote add origin https://github.com/gitleaks/gitleaks.git
git -C "$out/source" fetch -q --depth=1 origin 83d9cd684c87d95d656c1458ef04895a7f1cbd8e
git -C "$out/source" checkout -q --detach FETCH_HEAD
git -C "$out/source" rev-parse HEAD > "$out/source-sha.txt"
go version > "$out/toolchain.txt"
uname -a >> "$out/toolchain.txt"
export CGO_ENABLED=0 GOTOOLCHAIN=local
for arm in control candidate; do
  if [ "$arm" = candidate ]; then
    git -C "$out/source" apply "$ROOT/bench/scanner/re2-upgrade.patch"
  fi
  (
    cd "$out/source"
    go mod download
    go build -buildvcs=false -trimpath -tags gore2regex \
      -ldflags '-s -w -X=github.com/zricethezav/gitleaks/v8/version.Version=8.30.1' \
      -o "$out/$arm/gitleaks" .
    go list -m all > "$out/$arm/modules.txt"
    go version -m "$out/$arm/gitleaks" > "$out/$arm/buildinfo.txt"
    go list -m -f '{{.Path}} {{.Dir}}' all > "$out/$arm/module-directories.txt"
    while read -r module directory; do
      [ -n "$directory" ] || continue
      mkdir -p "$out/$arm/licenses/$module"
      for notice in "$directory"/LICENSE* "$directory"/NOTICE* "$directory"/COPYING*; do
        [ ! -f "$notice" ] || cp "$notice" "$out/$arm/licenses/$module/"
      done
    done < "$out/$arm/module-directories.txt"
    re2_directory=$(go list -m -f '{{.Dir}}' github.com/wasilibs/go-re2)
    cp "$re2_directory/internal/cre2/NOTICE.txt" "$out/$arm/licenses/cre2-NOTICE.txt"
    cp "$(go env GOROOT)/LICENSE" "$out/$arm/licenses/Go-LICENSE"
  ) > "$out/$arm/build.log" 2>&1
  cp "$out/source/go.mod" "$out/source/go.sum" "$out/$arm/"
  shasum -a 256 "$out/$arm/gitleaks" > "$out/$arm/binary.sha256"
  # v8.30.1's generator imports stdlib regexp in two rules, which prevents
  # its tests from compiling with the very build tag used by public releases.
  # Fix those imports identically in both arms; no expected finding changes.
  git -C "$out/source" apply "$ROOT/bench/scanner/upstream-test-imports.patch"
  (cd "$out/source" && go test -buildvcs=false -tags gore2regex ./...) \
    > "$out/$arm/upstream-tests.log" 2>&1
  (cd "$out/source" && go test -buildvcs=false github.com/wasilibs/go-re2/...) \
    > "$out/$arm/regex-library-tests.log" 2>&1
  git -C "$out/source" apply -R "$ROOT/bench/scanner/upstream-test-imports.patch"
  env GODEBUG=inittrace=1 "$out/$arm/gitleaks" version \
    > "$out/$arm/version.stdout" 2> "$out/$arm/inittrace.stderr"
done
git -C "$out/source" diff > "$out/dependency-change.patch"

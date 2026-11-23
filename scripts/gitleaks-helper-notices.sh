#!/bin/sh
# Write the license notices that ship in a warm gitleaks helper archive (#569):
# name, version, license and license text of everything linked into the two
# binaries.
#
#   sh scripts/gitleaks-helper-notices.sh HELPER_MODULES CLIENT_MODULES GO_VERSION >THIRD_PARTY_LICENSES.txt
#
# HELPER_MODULES and CLIENT_MODULES hold the "path version" lines of
# `go version -m` for each built binary, and GO_VERSION is the toolchain they
# record. The texts are the license files of those module versions in the
# module cache, so this needs go and a finished build. The license names are
# reviewed by hand in native/gitleaks-helper/module-licenses.txt.
#
# It fails, and so does the build, when a linked module has no row for its
# version in that table, has no license file, or when the notices for the code
# compiled into go-re2's WebAssembly module (embedded-licenses.txt; that code
# is in no Go module) were recorded for another go-re2 version.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SRC="$ROOT/native/gitleaks-helper"
TABLE="$SRC/module-licenses.txt"
EMBEDDED="$SRC/embedded-licenses.txt"
helper_modules=${1:?helper module list required}
client_modules=${2:?client module list required}
go_version=${3:?Go version required}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0
fail() {
  printf 'gitleaks helper notices: %s\n' "$*" >&2
  exit 1
}

(cd "$SRC" && go list -m -f '{{.Path}} {{.Version}} {{.Dir}}' all) >"$tmp/dirs" \
  || fail 'cannot list the module directories'
goroot=$(go env GOROOT) || fail 'cannot find GOROOT'

# Everything linked: the modules each binary records, and the Go standard
# library and runtime, which both are built from and no module list names.
{
  awk 'NF { print $1, $2 }' "$helper_modules" "$client_modules"
  printf 'std %s\n' "$go_version"
} | LC_ALL=C sort -u >"$tmp/linked"

re2=$(awk '$1 == "github.com/wasilibs/go-re2" { print $2 }' "$tmp/linked")
grep -Fxq "# For github.com/wasilibs/go-re2 $re2" "$EMBEDDED" \
  || fail "${EMBEDDED#"$ROOT"/} is not recorded for the linked go-re2 ${re2:-(none)}; review what its WebAssembly module is built from"

: >"$tmp/summary"
: >"$tmp/texts"
while read -r path version; do
  license=$(awk -v path="$path" -v version="$version" '
    $1 == path && $2 == version { sub(/^[^ ]+ +[^ ]+ +/, ""); print; found = 1; exit }
    END { exit !found }' "$TABLE") && [ -n "$license" ] \
    || fail "no license is recorded for $path $version in ${TABLE#"$ROOT"/}"
  into=agent-guard-gitleaks-helper
  if [ "$path" = std ]; then
    into="$into, agent-guard-scan"
    dir=$goroot
    source="https://github.com/golang/go/tree/$version"
    # Only the toolchain's own notices: the rest of GOROOT is not all linked.
    find_notices() { for name in LICENSE PATENTS; do [ ! -f "$dir/$name" ] || printf './%s\n' "$name"; done; }
  else
    ! awk -v path="$path" -v version="$version" '$1 == path && $2 == version { found = 1 } END { exit !found }' "$client_modules" \
      || into="$into, agent-guard-scan"
    dir=$(awk -v path="$path" -v version="$version" '
      $1 == path && $2 == version { sub(/^[^ ]+ +[^ ]+ */, ""); print; exit }' "$tmp/dirs")
    source="https://pkg.go.dev/$path@$version"
    find_notices() {
      (cd "$dir" && find . -type f \( -iname 'licen[sc]e*' -o -iname 'copying*' -o -iname 'unlicense*' \
        -o -iname 'notice*' -o -iname 'copyright*' -o -iname 'patents*' -o -iname 'authors*' -o -iname 'contributors*' \) \
        ! -name '*.go' ! -path '*/testdata/*' | LC_ALL=C sort)
    }
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || fail "the source of $path $version is not in the module cache"
  find_notices >"$tmp/files"
  # A notice file elsewhere in the tree does not license the module itself.
  grep -Eiq '^\./(licen[sc]e|copying|unlicense)[^/]*$' "$tmp/files" \
    || fail "$path $version has no license file of its own in $dir"
  printf '%s %s  %s\n' "$path" "$version" "$license" >>"$tmp/summary"
  {
    printf '\n## %s %s\nLicense: %s\nLinked into: %s\nSource: %s\n' "$path" "$version" "$license" "$into" "$source"
    while IFS= read -r file; do
      printf '\n---- %s ----\n\n' "${file#./}"
      # awk ends the last line, so the next heading starts its own.
      LC_ALL=C awk 1 "$dir/$file"
    done <"$tmp/files"
  } >>"$tmp/texts"
done <"$tmp/linked"

cat <<'EOF'
Third-party licenses of the Agent Guard warm gitleaks helper

This file belongs to the two programs beside it, agent-guard-gitleaks-helper
and agent-guard-scan. Agent Guard's own code in them is under the MIT License
in the LICENSE file beside this one.

The build wrote this file from the modules recorded in the two binaries
(`go version -m`) and from the license files of exactly those module versions.
"std" is the Go standard library and runtime. Each section names the binaries
that link the module. The license names are Agent Guard's reading of the files
that follow them; the texts govern. The last part covers code that is
compiled into one of the modules and is in no Go module of its own.

Modules
=======

EOF
cat "$tmp/summary"
printf '\nLicense texts\n=============\n'
cat "$tmp/texts"
printf '\nCode compiled into github.com/wasilibs/go-re2\n=============================================\n\n'
grep -v '^# For github.com/wasilibs/go-re2 ' "$EMBEDDED"

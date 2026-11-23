#!/bin/sh
# #569: the released warm gitleaks helper archives carry a license notice for
# everything linked into their two binaries.
#
# scripts/gitleaks-helper-notices.sh writes that file during the build, from
# the modules the built binaries record and the license files in the module
# cache, and fails when a linked module has no reviewed license in
# native/gitleaks-helper/module-licenses.txt or no license file. This runs it
# against stand-in modules and a stand-in go, so it needs neither Go nor a
# network, and checks that the committed table names exactly the modules the
# build pins.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-notices.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
SRC="$ROOT/native/gitleaks-helper"
TABLE="$SRC/module-licenses.txt"
EMBEDDED="$SRC/embedded-licenses.txt"
GENERATOR="$ROOT/scripts/gitleaks-helper-notices.sh"

# The committed table: one reviewed license for each module the build pins
# (release-modules.txt, which the build compares with the built helper) and
# for the Go standard library of the pinned toolchain, and nothing else.
toolchain=$(sed -n 's/.*GOTOOLCHAIN=\(go[0-9][0-9.]*\).*/\1/p' "$ROOT/scripts/build-gitleaks-helper.sh" | head -n 1)
{ awk '{ print $1, $2 }' "$SRC/release-modules.txt"; printf 'std %s\n' "$toolchain"; } | LC_ALL=C sort >"$CASE/linked"
grep -v '^#' "$TABLE" 2>/dev/null | awk 'NF { print $1, $2 }' | LC_ALL=C sort >"$CASE/table"
expect "the pinned toolchain is known" '[ -n "$toolchain" ]'
expect "the license table names every pinned module and the Go standard library, and nothing else" \
  '[ -s "$CASE/table" ] && cmp -s "$CASE/linked" "$CASE/table"'
expect "every row of the license table names a license" \
  '[ -f "$TABLE" ] && ! grep -v "^#" "$TABLE" | awk "NF && NF < 3 { short = 1 } END { exit !short }"'
re2=$(awk '$1 == "github.com/wasilibs/go-re2" { print $2 }' "$SRC/release-modules.txt")
expect "the notices of the code compiled into go-re2 are recorded for the linked go-re2 version" \
  '[ -n "$re2" ] && grep -Fxq "# For github.com/wasilibs/go-re2 $re2" "$EMBEDDED"'
for copy in THIRD_PARTY_NOTICES.md plugins/agent-guard/THIRD_PARTY_NOTICES.md; do
  expect "$copy points to the license file in the helper archive and to the table" \
    'grep -q "THIRD_PARTY_LICENSES.txt" "$ROOT/$copy" && grep -q "native/gitleaks-helper/module-licenses.txt" "$ROOT/$copy"'
done

# The generator, in a copy of its tree with stand-in inputs.
mkdir -p "$CASE/tree/scripts" "$CASE/tree/native/gitleaks-helper" "$CASE/bin" "$CASE/goroot" "$CASE/mod"
cp "$GENERATOR" "$CASE/tree/scripts/" 2>/dev/null
generator="$CASE/tree/scripts/gitleaks-helper-notices.sh"
table="$CASE/tree/native/gitleaks-helper/module-licenses.txt"
embedded="$CASE/tree/native/gitleaks-helper/embedded-licenses.txt"
mkdir -p "$CASE/mod/a/sub" "$CASE/mod/a/testdata" "$CASE/mod/b" "$CASE/mod/re2"
printf 'text of a LICENSE\n' >"$CASE/mod/a/LICENSE"
printf 'text of a nested NOTICE\n' >"$CASE/mod/a/sub/NOTICE"
printf 'text of a testdata license\n' >"$CASE/mod/a/testdata/LICENSE"
printf 'package a // text of a go source\n' >"$CASE/mod/a/licenses.go"
# No newline at the end: the next heading must still start its own line.
printf 'text of b LICENSE.md' >"$CASE/mod/b/LICENSE.md"
printf 'text of re2 LICENSE\n' >"$CASE/mod/re2/LICENSE"
printf 'text of the Go LICENSE\n' >"$CASE/goroot/LICENSE"
printf 'text of the Go PATENTS\n' >"$CASE/goroot/PATENTS"
write_inputs() {
  cat >"$table" <<'EOF'
# comment
example.test/a v1.0.0 MIT
example.test/b v2.0.0 Apache-2.0 AND MIT
github.com/wasilibs/go-re2 v9.9.9 MIT
std go9.9.9 BSD-3-Clause
EOF
  printf '# For github.com/wasilibs/go-re2 v9.9.9\ntext of the embedded notices\n' >"$embedded"
  cat >"$CASE/list" <<EOF
example.test/main  $CASE/tree/native/gitleaks-helper
example.test/a v1.0.0 $CASE/mod/a
example.test/b v2.0.0 $CASE/mod/b
example.test/unlinked v3.0.0
github.com/wasilibs/go-re2 v9.9.9 $CASE/mod/re2
EOF
  printf 'example.test/a v1.0.0 h1:x=\nexample.test/b v2.0.0 h1:y=\ngithub.com/wasilibs/go-re2 v9.9.9 h1:z=\n' >"$CASE/helper-modules"
  printf 'example.test/b v2.0.0 h1:y=\n' >"$CASE/client-modules"
}
cat >"$CASE/bin/go" <<'EOF'
#!/bin/sh
case "$1" in
  list) cat "$NOTICES_TEST_DIR/list" ;;
  env) printf '%s\n' "$NOTICES_TEST_DIR/goroot" ;;
  *) exit 9 ;;
esac
EOF
chmod 755 "$CASE/bin/go"
generate() {
  NOTICES_TEST_DIR="$CASE" PATH="$CASE/bin:$PATH" sh "$generator" "$CASE/helper-modules" "$CASE/client-modules" go9.9.9 \
    >"$CASE/out" 2>"$CASE/err"
  status=$?
}
# $1 a line that must stand alone in the output.
has() { grep -Fxq -- "$1" "$CASE/out"; }
# The lines from heading $1 to the next heading.
section() { awk -v want="## $1" '$0 == want { on = 1; print; next } /^## / { on = 0 } on' "$CASE/out"; }

write_inputs
generate
expect "must-pass: the generator succeeds when every linked module has a license and a license file" '[ "$status" = 0 ] && [ ! -s "$CASE/err" ]'
expect "every linked module and the Go standard library has a heading" \
  'has "## example.test/a v1.0.0" && has "## example.test/b v2.0.0" && has "## github.com/wasilibs/go-re2 v9.9.9" && has "## std go9.9.9"'
expect "a module that is not linked has none" '! grep -q "example.test/unlinked" "$CASE/out" && ! grep -q "example.test/main" "$CASE/out"'
expect "a section names the reviewed license and the binaries that link the module" \
  'section "example.test/a v1.0.0" | grep -Fxq "License: MIT" \
    && section "example.test/a v1.0.0" | grep -Fxq "Linked into: agent-guard-gitleaks-helper" \
    && section "example.test/b v2.0.0" | grep -Fxq "License: Apache-2.0 AND MIT" \
    && section "example.test/b v2.0.0" | grep -Fxq "Linked into: agent-guard-gitleaks-helper, agent-guard-scan" \
    && section "std go9.9.9" | grep -Fxq "Linked into: agent-guard-gitleaks-helper, agent-guard-scan"'
expect "a section holds the text of the license file and of a nested notice" \
  'section "example.test/a v1.0.0" | grep -Fxq "text of a LICENSE" && section "example.test/a v1.0.0" | grep -Fxq "text of a nested NOTICE"'
expect "test data and source files are not notices" '! grep -q "testdata license" "$CASE/out" && ! grep -q "go source" "$CASE/out"'
expect "a license file without a final newline does not swallow the next heading" \
  'section "example.test/b v2.0.0" | grep -Fxq "text of b LICENSE.md" && has "## github.com/wasilibs/go-re2 v9.9.9"'
expect "the Go standard library section holds the toolchain's LICENSE and PATENTS" \
  'section "std go9.9.9" | grep -Fxq "text of the Go LICENSE" && section "std go9.9.9" | grep -Fxq "text of the Go PATENTS"'
expect "the notices of the code compiled into go-re2 are included" 'has "text of the embedded notices"'
expect "the summary lists each module once with its version and license" \
  '[ "$(grep -c "^example.test/a v1.0.0  MIT$" "$CASE/out")" = 1 ] && [ "$(grep -c "^std go9.9.9  BSD-3-Clause$" "$CASE/out")" = 1 ]'

# Must-fail: each change alone makes the generator fail, naming what is wrong.
write_inputs
grep -v '^example.test/b ' "$table" >"$table.new" && mv "$table.new" "$table"
generate
expect "must-fail: a linked module missing from the license table" '[ "$status" != 0 ] && grep -q "example.test/b v2.0.0" "$CASE/err"'
write_inputs
sed 's|^example.test/b v2.0.0 |example.test/b v2.0.1 |' "$table" >"$table.new" && mv "$table.new" "$table"
generate
expect "must-fail: the table records another version of a linked module" '[ "$status" != 0 ] && grep -q "example.test/b v2.0.0" "$CASE/err"'
write_inputs
printf 'example.test/c v1.0.0 h1:w=\n' >>"$CASE/client-modules"
generate
expect "must-fail: a module only the client links is checked too" '[ "$status" != 0 ] && grep -q "example.test/c v1.0.0" "$CASE/err"'
write_inputs
mv "$CASE/mod/a/LICENSE" "$CASE/held"
generate
expect "must-fail: a linked module without a license file of its own" '[ "$status" != 0 ] && grep -q "example.test/a v1.0.0" "$CASE/err"'
mv "$CASE/held" "$CASE/mod/a/LICENSE"
write_inputs
grep -v '^example.test/a ' "$CASE/list" >"$CASE/list.new" && { cat "$CASE/list.new"; echo 'example.test/a v1.0.0'; } >"$CASE/list"
generate
expect "must-fail: a linked module whose source is not in the module cache" '[ "$status" != 0 ] && grep -q "example.test/a v1.0.0" "$CASE/err"'
write_inputs
mv "$CASE/goroot/LICENSE" "$CASE/held"
generate
expect "must-fail: a toolchain without its LICENSE" '[ "$status" != 0 ] && grep -q "std go9.9.9" "$CASE/err"'
mv "$CASE/held" "$CASE/goroot/LICENSE"
write_inputs
printf '# For github.com/wasilibs/go-re2 v9.9.8\ntext\n' >"$embedded"
generate
expect "must-fail: embedded notices recorded for another go-re2 version" '[ "$status" != 0 ] && grep -q "go-re2 v9.9.9" "$CASE/err"'
# Control: with the inputs restored the generator succeeds again, so each
# failure above came from its one change.
write_inputs
generate
expect "control: the restored inputs generate again" '[ "$status" = 0 ] && has "## example.test/b v2.0.0"'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" = 0 ]

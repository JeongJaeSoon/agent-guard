#!/bin/sh
# Synthetic rows for bench/instruction-count/run.sh --render, never benchmark
# evidence, plus the argument and missing-tool contracts of the measurement.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
bench="$ROOT/bench/instruction-count/run.sh"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

{
  row version version 66630711 66650711 0 0 same
  row dense-controls hook-post-tool 484083428 422936287 0 0 same
  row pre-edit hook-pre-tool 69273762 69290013 0 0 same
  row pre-bash-repeated hook-pre-tool 249181358 249500000 0 2 different
  row prompt hook-user-prompt 71840678 71830000 0 0 same
  row post-bash hook-post-tool 92636119 92636219 0 0 same
} > "$case_dir/rows.tsv"
sh "$bench" --render "$case_dir/rows.tsv" > "$case_dir/table" 2> "$case_dir/stderr" \
  || fail 'render accepts a measured TSV'
[ ! -s "$case_dir/stderr" ] || fail 'render writes nothing to stderr'
has() { grep -Fxq -- "$1" "$case_dir/table" || fail "$2"; }
has '| 이벤트 | 명령 | base | head | 차이 | 스크립트 크기 몫(추정) | 나머지 | 분류 | 종료 코드 | 출력 |' 'header'
has '| version | version | 66,630,711 | 66,650,711 | +20,000 (+0.03%) | +20,000 | 0 | 스크립트 크기 기준 | 0 | 같음 |' \
  'the version row is the script-size reference'
has '| dense-controls | hook-post-tool | 484,083,428 | 422,936,287 | -61,147,141 (-12.63%) | +20,000 | -61,167,141 | 실행 코드 감소 | 0 | 같음 |' \
  'a decrease beyond the script-size share is named'
has '| pre-edit | hook-pre-tool | 69,273,762 | 69,290,013 | +16,251 (+0.02%) | +20,000 | -3,749 | 스크립트 크기만 | 0 | 같음 |' \
  'a change within the script-size share is only script size'
has '| pre-bash-repeated | hook-pre-tool | 249,181,358 | 249,500,000 | +318,642 (+0.13%) | +20,000 | +298,642 | **실행 코드 증가** | 0 → 2 | **다름** |' \
  'an increase beyond the share, a status change and an output change are all shown'
has '| prompt | hook-user-prompt | 71,840,678 | 71,830,000 | -10,678 (-0.01%) | +20,000 | -30,678 | 스크립트 크기만 | 0 | 같음 |' \
  'the tolerance scales with the base count'
has '| post-bash | hook-post-tool | 92,636,119 | 92,636,219 | +100 (+0.00%) | +20,000 | -19,900 | 변화 없음 | 0 | 같음 |' \
  'run-to-run noise is no change'
[ "$(grep -c '^| ' "$case_dir/table")" -eq 7 ] || fail 'a header and one row per event'

# Without the reference first there is no script-size share to subtract.
row dense-controls hook-post-tool 1 2 0 0 same > "$case_dir/noref.tsv"
if sh "$bench" --render "$case_dir/noref.tsv" > "$case_dir/table" 2> "$case_dir/stderr"; then
  fail 'render refuses rows without the version reference'
else
  [ "$?" -eq 3 ] || fail 'a missing reference exits 3'
fi
[ ! -s "$case_dir/table" ] || fail 'no partial table without the reference'

status=0
sh "$bench" > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail 'missing trees are a usage error'
status=0
sh "$bench" --render "$case_dir/absent.tsv" > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail 'a missing TSV is a usage error'

# A missing tool is "could not measure" (3), never an empty "no change".
mkdir "$case_dir/bin"
for tool in jq git awk mktemp dirname; do
  path=$(command -v "$tool") && ln -s "$path" "$case_dir/bin/$tool"
done
status=0
PATH="$case_dir/bin" "$(command -v sh)" "$bench" "$ROOT" "$ROOT" "$case_dir/out.tsv" \
  > /dev/null 2> "$case_dir/stderr" || status=$?
[ "$status" -eq 3 ] || fail 'missing valgrind exits 3'
grep -Fxq 'bench: valgrind is required' "$case_dir/stderr" || fail 'missing valgrind is named'
[ ! -e "$case_dir/out.tsv" ] || fail 'no TSV is written without valgrind'

printf 'hook instruction count fixtures passed\n'

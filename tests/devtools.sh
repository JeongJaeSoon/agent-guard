#!/bin/sh
# Retained Python expectations and failure gates; no interpreter is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
TOOLS=${1:?absolute devtools binary required}
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
mkdir "$CASE/results"
cp bench/results/rust-experiment/*.json "$CASE/results/"
cp bench/results/rust-experiment/environment.txt bench/results/rust-experiment/image-id.txt "$CASE/results/"
"$TOOLS" report --results "$CASE/results" --html "$CASE/report.html" >"$CASE/assessment.json"
jq -S . bench/results/rust-experiment/assessment.json >"$CASE/expected"
jq -S . "$CASE/assessment.json" >"$CASE/actual"
cmp "$CASE/expected" "$CASE/actual"
"$TOOLS" --help >"$CASE/help"
"$TOOLS" report --help >"$CASE/report-help"
if "$TOOLS" report --results "$CASE/results" --html "$CASE/unknown.html" --unknown-option >"$CASE/unknown-output" 2>"$CASE/unknown-error"; then
  echo 'unknown report option was silently accepted' >&2; exit 1
fi
test ! -e "$CASE/unknown.html"
grep -q 'unknown option' "$CASE/unknown-error"
"$TOOLS" report --results /nonexistent --results "$CASE/results" "--html=$CASE/last-option.html" >"$CASE/last-option.json"
jq -S . "$CASE/last-option.json" >"$CASE/actual"
cmp "$CASE/expected" "$CASE/actual"
test "$(find "$CASE/assets" -name 'rust-*.svg' | wc -l | tr -d ' ')" = 5
for chart in "$CASE"/assets/rust-*.svg; do
  test "$(grep -o '<svg ' "$chart" | wc -l | tr -d ' ')" = 1
done
for heading in '판정과 적용 범위' '실제 CLI' '동시 부하' '정확성' '측정 한계'; do
  grep -q "$heading" "$CASE/report.html"
done
# A failed correctness result must never generate an assessment or HTML.
jq '.failed = 1' "$CASE/results/differential.json" >"$CASE/bad"
mv "$CASE/bad" "$CASE/results/differential.json"
rm "$CASE/results/assessment.json"
if "$TOOLS" report --results "$CASE/results" --html "$CASE/invalid.html" >"$CASE/bad-output" 2>/dev/null; then
  echo 'report accepted failed verification' >&2; exit 1
fi
test ! -e "$CASE/invalid.html"
test ! -e "$CASE/results/assessment.json"
status=0
"$TOOLS" resource-sample "$CASE/resources.json" sh -c 'exit 7' || status=$?
test "$status" = 7
jq -e '.wall_seconds >= 0 and .user_cpu_seconds >= 0 and .system_cpu_seconds >= 0 and .max_child_peak_rss_kib > 0' "$CASE/resources.json" >/dev/null
"$TOOLS" measure-selected-bash >"$CASE/locations.json"
jq -e '.denominator > 0 and .observed > 0 and .definition_only_observed == 0' "$CASE/locations.json" >/dev/null
# A failing partition must keep both logs and a failed machine-readable report.
mkdir -p "$CASE/failure/plugins/agent-guard/bin" "$CASE/failure/tests"
printf 'frozen source\n' >"$CASE/failure/plugins/agent-guard/bin/agent-guard"
printf 'printf "passed: 0\\nfailed: 1\\n"; exit 7\n' >"$CASE/failure/tests/run.sh"
printf 'printf "passed: 1\\nfailed: 0\\n"\n' >"$CASE/failure/tests/native-suite.sh"
if (cd "$CASE/failure" && "$TOOLS" verify --out "$CASE/failed-partitions" --native-core /bin/sh --shards 1) >"$CASE/failed-report" 2>/dev/null; then
  echo 'verification accepted a failing partition' >&2; exit 1
fi
jq -e '.stable and .results[0].status == 7 and .results[1].status == 0' "$CASE/failed-partitions/verification.json" >/dev/null
grep -q 'failed: 1' "$CASE/failed-partitions/shell-1.log"
grep -q 'passed: 1' "$CASE/failed-partitions/native-4.log"
printf 'Developer tools: historical assessment, report rejection, resource status, source-location contracts passed\n'

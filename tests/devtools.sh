#!/bin/sh
# Developer tool option, resource and failure-gate contracts; no interpreter is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
TOOLS=${1:?absolute devtools binary required}
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
"$TOOLS" --help >"$CASE/help"
"$TOOLS" measure-selected-bash --help >"$CASE/command-help"
if "$TOOLS" measure-selected-bash --unknown-option >"$CASE/unknown-output" 2>"$CASE/unknown-error"; then
  echo 'unknown option was silently accepted' >&2; exit 1
fi
grep -q 'unknown option' "$CASE/unknown-error"
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
if (cd "$CASE/failure" && "$TOOLS" verify --out "$CASE/ignored-out" "--out=$CASE/failed-partitions" --native-core /bin/sh --shards 1) >"$CASE/failed-report" 2>/dev/null; then
  echo 'verification accepted a failing partition' >&2; exit 1
fi
jq -e '.stable and .results[0].status == 7 and .results[1].status == 0' "$CASE/failed-partitions/verification.json" >/dev/null
grep -q 'failed: 1' "$CASE/failed-partitions/shell-1.log"
grep -q 'passed: 1' "$CASE/failed-partitions/native-4.log"
# A repeated option keeps its last value.
test ! -e "$CASE/ignored-out"
printf 'Developer tools: option parsing, resource status, source-location and failed-partition contracts passed\n'

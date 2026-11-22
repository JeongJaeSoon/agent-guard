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
# Refresh only a disposable repository, never the checked-in pin during tests.
mkdir -p "$CASE/pins/plugins/agent-guard/bin" "$CASE/pins/tests/helpers"
cp tests/helpers/extract-functions.sh "$CASE/pins/tests/helpers/"
printf 'sample() {\n  :\n}\n' >"$CASE/pins/plugins/agent-guard/bin/agent-guard"
printf '{"sample":{"relative_lines":[2],"body_sha256":"stale","note":"keep"}}\n' >"$CASE/pins/tests/selected-bash-locations.json"
cp "$CASE/pins/tests/selected-bash-locations.json" "$CASE/before.json"
if (cd "$CASE/pins" && "$TOOLS" measure-selected-bash) >"$CASE/stale-output" 2>"$CASE/stale-error"; then
  echo 'measurement accepted a stale pin' >&2; exit 1
fi
grep -F 'sh scripts/devtools.sh refresh-selected-bash' "$CASE/stale-error"
cmp "$CASE/before.json" "$CASE/pins/tests/selected-bash-locations.json"
if (cd "$CASE/pins" && CI=true "$TOOLS" refresh-selected-bash) >"$CASE/ci-output" 2>"$CASE/ci-error"; then
  echo 'refresh was allowed in CI' >&2; exit 1
fi
cmp "$CASE/before.json" "$CASE/pins/tests/selected-bash-locations.json"
(unset CI; cd "$CASE/pins" && "$TOOLS" refresh-selected-bash)
sh tests/helpers/extract-functions.sh "$CASE/pins/plugins/agent-guard/bin/agent-guard" "$CASE" sample
expected=$(shasum -a 256 "$CASE/sample.sh" | awk '{ print $1 }')
jq -e --arg expected "$expected" '.sample.body_sha256 == $expected and .sample.relative_lines == [2] and .sample.note == "keep"' "$CASE/pins/tests/selected-bash-locations.json" >/dev/null
cp "$CASE/pins/tests/selected-bash-locations.json" "$CASE/refreshed.json"
(unset CI; cd "$CASE/pins" && "$TOOLS" refresh-selected-bash)
cmp "$CASE/refreshed.json" "$CASE/pins/tests/selected-bash-locations.json"
# Extraction failure leaves every original pin intact.
printf 'missing() {\n  :\n}\n' >"$CASE/pins/plugins/agent-guard/bin/agent-guard"
if (unset CI; cd "$CASE/pins" && "$TOOLS" refresh-selected-bash) >"$CASE/missing-output" 2>"$CASE/missing-error"; then
  echo 'refresh accepted a missing selected function' >&2; exit 1
fi
cmp "$CASE/refreshed.json" "$CASE/pins/tests/selected-bash-locations.json"
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

#!/bin/sh
# Separate collection success from the predeclared adoption thresholds.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)
dir=${1:?measurement directory required}
[ "$(cat "$dir/enforced-limits.txt")" = "200000 100000
1073741824
0" ] || { echo 'missing enforced resource limits' >&2; exit 2; }
[ ! -e "$dir/assessment.json" ] || { echo 'refusing to overwrite assessment' >&2; exit 2; }
jq -s -f "$ROOT/bench/native/assess-packaged.jq" \
  "$dir/cli-claude.json" "$dir/cli-codex.json" "$dir/cli-clean-followup.json" \
  "$dir/cli-shell-control.json" "$dir/kernel.json" "$dir/differential.json" \
  "$dir/integration.json" "$dir"/load-*.json > "$dir/assessment.json"
jq -e '.performance_gate_passed' "$dir/assessment.json"

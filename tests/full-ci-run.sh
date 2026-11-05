#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
fixture="$ROOT/tests/fixtures/full-ci-runs.json"
count=$(jq 'length' "$fixture")
index=0
pass=0
fail=0
while [ "$index" -lt "$count" ]; do
  entry=$(jq -c ".[$index]" "$fixture")
  name=$(printf '%s\n' "$entry" | jq -r '.name')
  expected=$(printf '%s\n' "$entry" | jq -r '.expected')
  expected_event=$(printf '%s\n' "$entry" | jq -r '.event // "pull_request"')
  expected_branch=$(printf '%s\n' "$entry" | jq -r '.branch // "release/v9"')
  pages=$(printf '%s\n' "$entry" | jq -c '.pages')
  actual=false
  if printf '%s\n' "$pages" | jq -se \
      --arg sha fixture-sha --arg event "$expected_event" --arg branch "$expected_branch" \
      -f "$ROOT/scripts/require-full-ci.jq" >/dev/null 2>&1; then
    actual=true
  fi
  if [ "$actual" = "$expected" ]; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
  index=$((index + 1))
done
if jq -se --arg sha fixture-sha --arg event pull_request --arg branch release/v9 \
    -f "$ROOT/scripts/require-full-ci.jq" </dev/null >/dev/null 2>&1; then
  printf 'not ok - empty API output fails closed\n'
  fail=$((fail + 1))
else
  printf 'ok - empty API output fails closed\n'
  pass=$((pass + 1))
fi
printf '%s full-CI provenance checks passed, %s failed\n' "$pass" "$fail"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]

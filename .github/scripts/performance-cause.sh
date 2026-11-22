#!/bin/sh
# Keep different failures out of an older nightly issue. CPU models are irrelevant.
set -eu
evidence=${1:?evidence directory required}
failed=${2:?failed jobs required}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
{
  sh "$root/.github/scripts/performance-verdict.sh" "$evidence"
  printf '%s\n' "$failed" | sort
  for artifact in packaged-performance instruction-count; do
    dir="$evidence/$artifact"
    [ ! -f "$dir/errors.txt" ] || cat "$dir/errors.txt"
    [ ! -f "$dir/over-limit.txt" ] || sed 's/[0-9][0-9.]*/#/g' "$dir/over-limit.txt"
    for file in "$dir"/*confirmation.json; do
      [ ! -f "$file" ] || jq -c '[.confirmed[] | {host,name}] | sort_by(.host,.name)' "$file"
    done
  done
} | shasum -a 256 | cut -d ' ' -f1

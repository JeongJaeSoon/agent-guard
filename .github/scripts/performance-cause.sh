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
    # Keep host/case/fixture context so different timeouts remain distinct.
    # Only timing jitter is removed; the issue body keeps the original text.
    if [ -f "$dir/errors.txt" ]; then
      sed -E '
        s/((baseline_|candidate_)?seconds=)[-+0-9.eE]+/\1#/g
        s/^((baseline|candidate) [^ ]+) [-+0-9.eE]+s$/\1 #s/
        s/^(#[0-9]+) [0-9.]+ /\1 /
        /^(#[0-9]+ (DONE |sha256:|extracting |transferring )|sha256:)/ {
          s/[0-9]+([.][0-9]+)?([kMGT]?B)/#\2/g
          s/ [0-9.]+s( done)?$/ #s\1/
        }
      ' "$dir/errors.txt" | awk '
        /^(#[0-9]+ (DONE |sha256:|extracting |transferring )|sha256:)/ { if (seen[$0]++) next }
        { print }
      '
    fi
    [ ! -f "$dir/over-limit.txt" ] || sed 's/[0-9][0-9.]*/#/g' "$dir/over-limit.txt"
    for file in "$dir"/*confirmation.json; do
      [ ! -f "$file" ] || jq -c '[.confirmed[] | {host,name}] | sort_by(.host,.name)' "$file"
    done
  done
} | shasum -a 256 | cut -d ' ' -f1

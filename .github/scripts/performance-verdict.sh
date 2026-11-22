#!/bin/sh
# Shared release/nightly classification; absent or invalid evidence fails closed.
set -eu
evidence=${1:?evidence directory required}
verdict=passed
for artifact in packaged-performance instruction-count; do
  file="$evidence/$artifact/verdict.txt"
  status=measurement_error
  [ ! -f "$file" ] || status=$(cat "$file")
  case "$status" in
    passed) ;;
    threshold_exceeded) [ "$verdict" != passed ] || verdict=threshold_exceeded ;;
    *) verdict=measurement_error ;;
  esac
done
printf '%s\n' "$verdict"

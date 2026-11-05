#!/usr/bin/env sh
set -eu

scope=full
if [ "$1" = pull_request ]; then
  case "$2" in
    release/*) ;;
    *) scope=subset ;;
  esac
fi

# Matrix coverage and aggregate identity must come from the same decision.
case "$scope" in
  full)
    printf '%s\n' 'oses=["ubuntu-latest","macos-latest"]' 'check_prefix=Test'
    ;;
  subset)
    printf '%s\n' 'oses=["ubuntu-latest"]' 'check_prefix=PR subset test'
    ;;
esac

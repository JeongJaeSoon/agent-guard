#!/usr/bin/env sh
# CI coverage for one event.
#
#   sh .github/scripts/ci-scope.sh EVENT HEAD_REF < changed-paths
#
# Pull requests (except release/*) run Linux only, and a pull request that
# changes only documentation skips the suites. Pushes, release pull requests
# and manual runs run everything. Changed paths are read only for the pull
# requests that can use them; an unreadable list never skips a suite.
set -eu
export LC_ALL=C

scope=full
if [ "$1" = pull_request ]; then
  case "$2" in
    release/*) ;;
    *) scope=subset ;;
  esac
fi

tests=true
if [ "$scope" = subset ]; then
  changed=$(cat)
  # A path git still quotes starts with a quote and never matches.
  if [ -n "$changed" ] && ! printf '%s\n' "$changed" \
      | grep -Ev '^(docs/[^"]+|README([.][a-z]+)?[.]md|CONTRIBUTING[.]md|AGENTS[.]md)$' > /dev/null; then
    tests=false
  fi
fi

# Matrix coverage and aggregate identity must come from the same decision.
case "$scope" in
  full)
    printf '%s\n' 'oses=["ubuntu-latest","macos-latest"]' 'check_prefix=Test' 'macos=true'
    ;;
  subset)
    printf '%s\n' 'oses=["ubuntu-latest"]' 'check_prefix=PR subset test' 'macos=false'
    ;;
esac
printf 'tests=%s\n' "$tests"

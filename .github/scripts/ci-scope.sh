#!/usr/bin/env sh
# CI coverage for one event.
#
#   sh .github/scripts/ci-scope.sh EVENT HEAD_REF [ORDINARY] < changed-paths
#
# Pull requests (except release/*) run Linux only, and a pull request that
# changes only documentation skips the suites. A push of an ordinary PR merge
# (ORDINARY=true from reuse-tested-tree.sh) runs every suite on Linux only.
# Other pushes, release pull requests, schedule and manual runs run
# everything. Changed paths are read only for the pull
# requests that can use them; an unreadable list never skips a suite.
set -eu
export LC_ALL=C

scope=full
if [ "$1" = pull_request ]; then
  case "$2" in
    release/*) ;;
    *) scope=subset ;;
  esac
elif [ "$1" = push ] && [ "${3-}" = true ]; then
  scope=main
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

suites='{"bundle":"core","suite":"Core, host adapters and Git","shards":"1 3 6"},{"bundle":"commands","suite":"Command policies","shards":"2 7 8"},{"bundle":"navigation-claude","suite":"Shell navigation (Claude)","shards":"5","navigation_host":"claude"},{"bundle":"navigation-codex","suite":"Shell navigation (Codex)","shards":"5","navigation_host":"codex"},{"bundle":"scanner","suite":"CLI, scanner and output","shards":"4"}'
# macOS runs each partition on a runner of its own: side by side on one
# three-core runner two came to the job limit (#579), and the single core
# partition 1 and command partition 2 jobs then ran 21 to 25 minutes. The
# entries that match an existing os and bundle merge into that job and keep its
# check name; the others create a job. A created job gets nothing from the
# entries above, so each supplies every field itself.
macos='{"os":"macos-latest","bundle":"core","timeout_minutes":25,"suite":"Core, host adapters and Git","shards":"1"},{"os":"macos-latest","bundle":"core-partition-3","timeout_minutes":25,"suite":"Core, host adapters and Git (partition 3)","shards":"3"},{"os":"macos-latest","bundle":"core-partition-6","timeout_minutes":25,"suite":"Core, host adapters and Git (partition 6)","shards":"6"},{"os":"macos-latest","bundle":"commands","timeout_minutes":25,"suite":"Command policies","shards":"2"},{"os":"macos-latest","bundle":"commands-partition-7","timeout_minutes":25,"suite":"Command policies (partition 7)","shards":"7"},{"os":"macos-latest","bundle":"commands-partition-8","timeout_minutes":25,"suite":"Command policies (partition 8)","shards":"8"}'

# Matrix coverage and aggregate identity must come from the same decision.
case "$scope" in
  full)
    printf '%s\n' 'oses=["ubuntu-latest","macos-latest"]' 'check_prefix=Test' "include=[$suites,$macos]"
    ;;
  subset)
    printf '%s\n' 'oses=["ubuntu-latest"]' 'check_prefix=PR subset test' "include=[$suites]"
    ;;
  main)
    printf '%s\n' 'oses=["ubuntu-latest"]' 'check_prefix=Main subset test' "include=[$suites]"
    ;;
esac
printf 'tests=%s\n' "$tests"

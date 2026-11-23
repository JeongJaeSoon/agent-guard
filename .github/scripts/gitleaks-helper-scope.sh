#!/usr/bin/env sh
# Platforms for the warm gitleaks helper workflow (#537), as a job matrix.
#
#   sh .github/scripts/gitleaks-helper-scope.sh EVENT < changed-paths
#
# macOS runners are the scarce resource, so a pull request runs the macOS job
# only when the helper itself changes: its sources, build scripts, own tests,
# fake helper fixture, this script or the workflow. A pull request that only
# touches the CLI or other fixtures runs the Linux job, whose routing through
# the CLI is also covered by tests/gitleaks-helper-routing.sh. Every other
# event (push to main, manual runs) runs both platforms and reads no input.
set -eu
# Match bytes, not characters: git prints a name that is not valid UTF-8 as
# raw bytes, which a UTF-8 locale's '.' would not match.
export LC_ALL=C

linux='{"os":"ubuntu-24.04","archive":"linux_x64","checksum":"551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"}'
macos='{"os":"macos-15","archive":"darwin_arm64","checksum":"b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"}'

platforms=both
if [ "${1:?event name required}" = pull_request ]; then
  platforms=linux
  # Git still C-quotes a path holding a quote, backslash, tab or newline even
  # with core.quotePath=false; such a line cannot be matched safely, so it
  # selects both platforms rather than risk dropping a helper change.
  if grep -Eq '^("|(native/gitleaks-helper/.+|scripts/build-gitleaks-helper\.sh|scripts/gitleaks-helper-notices\.sh|tests/gitleaks-helper\.sh|tests/gitleaks-helper-corpus\.sh|tests/fixtures/fake-gitleaks-helper\.py|\.github/workflows/gitleaks-helper\.yml|\.github/scripts/gitleaks-helper-scope\.sh)$)'; then
    platforms=both
  fi
fi

case "$platforms" in
  both) printf 'matrix={"include":[%s,%s]}\n' "$linux" "$macos" ;;
  linux) printf 'matrix={"include":[%s]}\n' "$linux" ;;
esac

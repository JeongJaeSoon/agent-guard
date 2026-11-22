#!/usr/bin/env sh
# Which Performance evidence jobs measure this event.
#
#   sh .github/scripts/performance-scope.sh EVENT < changed-paths
#
# Prints packaged=true|false and instruction_count=true|false. A pull request
# measures only what its changes can affect; every other event (schedule,
# manual runs) measures everything and reads no input.
#
# packaged: the paths that triggered the whole workflow before #590 item 8;
# release pull requests always bump plugin.json.
# instruction_count: what bench/instruction-count/run.sh executes. It copies
# the whole plugin tree and runs its CLI, builds the gitleaks stand-in (or
# copies the shell mock), and the job runs this workflow, this script and the
# evidence-source writer.
set -eu
# Match bytes, not characters: git prints a name that is not valid UTF-8 as
# raw bytes, which a UTF-8 locale's '.' would not match.
export LC_ALL=C

packaged=true
instruction_count=true
if [ "${1:?event name required}" = pull_request ]; then
  changed=$(cat)
  # Git still C-quotes a path holding a quote, backslash, tab or newline even
  # with core.quotePath=false; such a line cannot be matched safely, so it
  # counts as relevant to both.
  common='\.github/workflows/performance\.yml|\.github/scripts/performance-scope\.sh|bench/instruction-count/.+'
  printf '%s\n' "$changed" | grep -Eq "^(\"|($common|bench/native/.+|native/devtools/.+|scripts/build-native-artifact\.sh|scripts/install-native-test-tools\.sh|plugins/agent-guard/\.claude-plugin/plugin\.json)$)" \
    || packaged=false
  printf '%s\n' "$changed" | grep -Eq "^(\"|($common|plugins/agent-guard/.+|bench/process-count/fake-gitleaks\.c|tests/fixtures/mock-gitleaks|\.github/scripts/write-performance-source\.sh)$)" \
    || instruction_count=false
fi
printf 'packaged=%s\ninstruction_count=%s\n' "$packaged" "$instruction_count"

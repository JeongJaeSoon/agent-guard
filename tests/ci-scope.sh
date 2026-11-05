#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
pass=0
check() {
  event=$1 branch=$2 scope=$3
  actual=$(sh "$ROOT/.github/scripts/ci-scope.sh" "$event" "$branch")
  case "$scope" in
    full) expected=$(printf '%s\n' 'oses=["ubuntu-latest","macos-latest"]' 'check_prefix=Test') ;;
    subset) expected=$(printf '%s\n' 'oses=["ubuntu-latest"]' 'check_prefix=PR subset test') ;;
  esac
  if [ "$actual" != "$expected" ]; then
    printf 'not ok - CI scope for %s/%s\n' "$event" "$branch"
    exit 1
  fi
  pass=$((pass + 1))
}

check pull_request feature/ci subset
check pull_request main subset
check pull_request '' subset
check pull_request release subset
check pull_request prerelease/v1 subset
check pull_request feature/release/v1 subset
check pull_request Release/v1 subset
check pull_request 'release-x/v1' subset
check pull_request release/ full
check pull_request release/v1.2.3 full
check pull_request release/nested/version full
check push main full
check push release/v1.2.3 full
check push refs/tags/v1.2.3 full
check workflow_dispatch feature/ci full
check workflow_dispatch main full
check release v1.2.3 full

# Pin the wiring as well as the producer: no event-specific name fallback.
grep -Fq 'os: ${{ fromJSON(needs.secret-guard.outputs.oses) }}' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'name: ${{ needs.secret-guard.outputs.check_prefix }} (${{ matrix.os }})' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'needs: [secret-guard, test-shard]' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'oses: ${{ steps.scope.outputs.oses }}' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'check_prefix: ${{ steps.scope.outputs.check_prefix }}' "$ROOT/.github/workflows/ci.yml"
printf 'CI scope fixtures passed: %s; matrix and aggregate wiring verified\n' "$pass"

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

# Performance measurement runs nightly, manually and on release PRs, outside
# the native qualification run that release reads. Only the schedule-only
# notify job may write issues, and release only warns about performance.
fail() {
  printf 'not ok - %s\n' "$1"
  exit 1
}
perf="$ROOT/.github/workflows/performance.yml"
native="$ROOT/.github/workflows/native-platforms.yml"
[ -f "$perf" ] || fail 'performance workflow exists'
if grep -Eq '^  push:' "$perf"; then fail 'performance does not run on push'; fi
grep -Fq "    - cron: '" "$perf" || fail 'performance runs on a schedule'
grep -Fq '  workflow_dispatch:' "$perf" || fail 'performance runs on dispatch'
grep -Fq "      - 'plugins/agent-guard/.claude-plugin/plugin.json'" "$perf" || fail 'release PRs run performance'
for path in bench/native/ bench/fused-output/ bench/scanner/ native/devtools/; do
  grep -Fq "      - '$path**'" "$perf" || fail "PRs changing $path run performance"
done
[ "$(awk '/^permissions:/ { on = 1; next } /^[^ ]/ { on = 0 } on' "$perf")" = '  contents: read' ] \
  || fail 'performance workflow token is read-only'
[ "$(grep -c 'issues: write' "$perf")" -eq 1 ] || fail 'one job writes issues'
notify=$(awk '/^  notify:/ { on = 1 } on' "$perf")
printf '%s\n' "$notify" | grep -Fq 'issues: write' || fail 'notify job holds the issue permission'
printf '%s\n' "$notify" | grep -Fq "always() && github.event_name == 'schedule'" || fail 'notify runs only on schedule'
# continue-on-error would turn a failed measurement into success for needs.*.result.
if awk '/^jobs:/ { on = 1 } /^  notify:/ { on = 0 } on' "$perf" | grep -Fq 'continue-on-error'; then
  fail 'measurement failures reach notify'
fi
printf '%s\n' "$notify" | grep -Fxq '    needs: [build, performance, fused-performance]' || fail 'notify waits for every measurement'
for result in failure cancelled skipped; do
  printf '%s\n' "$notify" | grep -Fq "contains(needs.*.result, '$result')" || fail "notify reports a $result measurement"
done
# No concurrency group: a pending notify job would be cancelled and its report lost.
if printf '%s\n' "$notify" | grep -Fq 'concurrency:'; then fail 'notify is never cancelled as pending'; fi
printf '%s\n' "$notify" | grep -Fq 'gh issue close "$created"' || fail 'overlapping notify runs fold into one issue'
printf '%s\n' "$notify" | grep -Fq '[ "$number" -lt "$created" ]' || fail 'notify folds only into a smaller issue number'
grep -Fq 'name: Packaged performance evidence' "$perf" || fail 'packaged measurement moved'
grep -Fq 'name: Fused packaged performance (' "$perf" || fail 'fused measurement moved'
for text in 'Packaged performance evidence' 'Fused packaged performance' 'continue-on-error: true'; do
  if grep -Fq "$text" "$native"; then fail "native qualification has no $text"; fi
done
grep -Fq 'needs: [platform, installation]' "$native" || fail 'native aggregate waits only for qualification'
release_perf=$(awk '/- name: Report release performance evidence/ { on = 1; print; next } on && /^      - / { exit } on' \
  "$ROOT/.github/workflows/release.yml")
printf '%s\n' "$release_perf" | grep -Fq 'for sha in "$RELEASE_HEAD_SHA" "$RELEASE_SHA"; do' \
  && printf '%s\n' "$release_perf" | grep -Fq 'actions/workflows/performance.yml/runs?head_sha=${sha}' \
  || fail 'release reads the performance runs of the released tree'
printf '%s\n' "$release_perf" | grep -Fq '::warning title=Release performance evidence::' \
  || fail 'release warns about performance'
if printf '%s\n' "$release_perf" | grep -Eq 'exit [1-9]'; then fail 'release performance report never fails'; fi
printf 'CI scope fixtures passed: %s; matrix, aggregate and performance schedule wiring verified\n' "$pass"

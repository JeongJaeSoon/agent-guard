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
for path in bench/native/ bench/fused-output/ native/devtools/; do
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
printf '%s\n' "$notify" | grep -Fxq '    needs: [build, instruction-count, performance, fused-performance]' || fail 'notify waits for every measurement'
for result in failure cancelled skipped; do
  printf '%s\n' "$notify" | grep -Fq "contains(needs.*.result, '$result')" || fail "notify reports a $result measurement"
done
# No concurrency group: a pending notify job would be cancelled and its report lost.
if printf '%s\n' "$notify" | grep -Fq 'concurrency:'; then fail 'notify is never cancelled as pending'; fi
printf '%s\n' "$notify" | grep -Fq 'gh issue close "$created"' || fail 'overlapping notify runs fold into one issue'
printf '%s\n' "$notify" | grep -Fq '[ "$number" -lt "$created" ]' || fail 'notify folds only into a smaller issue number'
printf '%s\n' "$notify" | grep -Fq 'sh .github/scripts/performance-issue-body.sh "$RUNNER_TEMP/evidence" "$failed"' \
  || fail 'notify builds the body with the tested script'
# Run notify's own body lines where the script is missing, as after a failed checkout.
fallback=$(mktemp -d)
printf '%s\n' "$notify" | awk '/^          body="\$RUNNER_TEMP\/issue.md"$/ { on = 1 } on { print substr($0, 11) } on && /^          fi$/ { exit }' \
  > "$fallback/body-lines.sh"
(cd "$fallback" && RUNNER_TEMP="$fallback" RUN_URL=https://example.invalid/run HEAD_SHA=synthetic-sha \
  failed='- Packaged performance evidence: failure' sh -eu body-lines.sh 2>/dev/null) \
  && grep -Fxq 'nightly run: https://example.invalid/run' "$fallback/issue.md" \
  && grep -Fxq '커밋: synthetic-sha' "$fallback/issue.md" \
  && grep -Fxq '이슈 본문을 만들지 못했습니다. run 로그와 artifact를 확인하세요.' "$fallback/issue.md" \
  && grep -Fxq -- '- Packaged performance evidence: failure' "$fallback/issue.md" \
  || { rm -rf "$fallback"; fail 'a body script failure still opens the issue with the run, commit and jobs'; }
rm -rf "$fallback"
sh "$ROOT/tests/performance-issue-body.sh" > /dev/null || fail 'nightly issue body fixtures'
# Performance evidence gates shell instructions against the latest release:
# a 5% rise beyond the script-size share, or no measurement, fails the job.
shell_gate=$(awk '/^  instruction-count:$/ { on = 1 } on && /^  [a-z-]+:$/ && !/^  instruction-count:$/ { exit } on' "$perf")
[ -n "$shell_gate" ] || fail 'performance evidence has the shell instruction count job'
printf '%s\n' "$shell_gate" | grep -Fq 'name: Shell instruction count against the latest release' \
  && printf '%s\n' "$shell_gate" | grep -Fq "git -C head tag --merged HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname" \
  && printf '%s\n' "$shell_gate" | grep -Fq 'git -C head worktree add --detach ../base "$tag"' \
  || fail 'the shell gate measures against the latest release tag other than the measured commit'
printf '%s\n' "$shell_gate" | grep -Fq 'sh head/bench/instruction-count/run.sh base head "$tsv" || status=$?' \
  && printf '%s\n' "$shell_gate" | grep -Fq 'sh head/bench/instruction-count/run.sh --check "$tsv" 5 > "$out/over-limit.txt" || gate=$?' \
  && printf '%s\n' "$shell_gate" | grep -Fxq '          [ "$gate" -eq 0 ]' \
  || fail 'the shell gate fails above 5% with the tested script'
printf '%s\n' "$shell_gate" | grep -Fq "if: failure() && steps.count.outcome == 'skipped'" \
  && printf '%s\n' "$shell_gate" | grep -Fq 'uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' \
  && printf '%s\n' "$shell_gate" | grep -Fq 'sudo timeout --kill-after=5 55 apt-get' \
  && printf '%s\n' "$shell_gate" | grep -Fq 'timeout-minutes: 10' \
  || fail 'the shell gate reports a run that never measured and reuses the valgrind cache'
if printf '%s\n' "$shell_gate" | grep -Eq '^    if:|continue-on-error'; then fail 'the shell gate runs and gates on every event'; fi
grep -Fq '    needs: [build, instruction-count, performance' "$perf" \
  && grep -Fq '          name: instruction-count' "$perf" \
  || fail 'the nightly issue waits for and reads the shell gate'
grep -Fq 'name: Packaged performance evidence' "$perf" || fail 'packaged measurement moved'
grep -Fq 'name: Fused packaged performance (' "$perf" || fail 'fused measurement moved'
for text in 'Packaged performance evidence' 'Fused packaged performance' 'continue-on-error: true'; do
  if grep -Fq "$text" "$native"; then fail "native qualification has no $text"; fi
done
grep -Fq 'needs: [platform, installation]' "$native" || fail 'native aggregate waits only for qualification'
# PRs trigger native qualification only for the test files it runs; a script
# the workflow executes must stay inside that filter.
native_tests=$(sed -n 's/.*sh tests\/\([A-Za-z0-9_-]*\.sh\).*/\1/p' "$native" | sort -u)
[ -n "$native_tests" ] || fail 'native qualification executes test scripts'
for script in $native_tests; do
  case $script in
    native-*.sh) grep -Fq "      - 'tests/native-*.sh'" "$native" ;;
    *) grep -Fq "      - 'tests/$script'" "$native" ;;
  esac || fail "PRs changing tests/$script run native qualification"
done
if grep -Fq "      - 'tests/**'" "$native"; then fail 'native qualification skips unrelated test changes'; fi
release_perf=$(awk '/- name: Report release performance evidence/ { on = 1; print; next } on && /^      - / { exit } on' \
  "$ROOT/.github/workflows/release.yml")
printf '%s\n' "$release_perf" | grep -Fq 'for sha in "$RELEASE_HEAD_SHA" "$RELEASE_SHA"; do' \
  && printf '%s\n' "$release_perf" | grep -Fq 'actions/workflows/performance.yml/runs?head_sha=${sha}' \
  || fail 'release reads the performance runs of the released tree'
printf '%s\n' "$release_perf" | grep -Fq '::warning title=Release performance evidence::' \
  || fail 'release warns about performance'
if printf '%s\n' "$release_perf" | grep -Eq 'exit [1-9]'; then fail 'release performance report never fails'; fi
# Hook PRs get a base-versus-head instruction count that reports and never
# gates on a rise; it fails only when it could not measure.
count="$ROOT/.github/workflows/hook-instruction-count.yml"
sh "$ROOT/tests/hook-instruction-count.sh" > /dev/null || fail 'hook instruction count fixtures'
awk '/^  pull_request:$/ { on = 1; next } on && /^    paths:$/ { paths = 1; next } paths && !/^      - / { exit } paths' "$count" \
  | grep -Fxq "      - 'plugins/agent-guard/bin/agent-guard'" || fail 'hook PRs run the instruction count'
grep -Fq 'sh head/bench/instruction-count/run.sh base head "$tsv" || status=$?' "$count" \
  && grep -Fq 'sh head/bench/instruction-count/run.sh --render "$tsv"' "$count" \
  || fail 'the instruction count runs the tested script'
grep -Fq '::warning title=Hook instruction count::' "$count" || fail 'an instruction rise is a warning'
[ "$(grep -Eo 'exit[[:space:]]+[^[:space:];]+' "$count" | tr '\n' ' ')" = 'exit 1 exit 1 ' ] \
  || fail 'the instruction count fails only when it could not measure'
grep -Fq 'git -C head worktree add --detach ../base HEAD^1' "$count" || fail 'the instruction count base is the merge parent'
grep -Fq 'sudo timeout --kill-after=5 55 apt-get' "$count" && grep -Fq 'for attempt in 1 2 3; do' "$count" \
  && grep -Fq 'install -y --no-install-recommends --no-download valgrind' "$count" \
  || fail 'the valgrind download is retried with a per-attempt limit and installed without a download'
grep -Fq "if: failure() && steps.count.outcome == 'skipped'" "$count" || fail 'a run that never measured says so'
grep -Fq 'uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' "$count" \
  && grep -Fq 'uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' "$count" \
  && grep -Fq "if: steps.restore.outputs.cache-hit != 'true'" "$count" \
  && grep -Fq 'install -qq --print-uris --no-install-recommends valgrind' "$count" \
  || fail 'the valgrind packages are cached under a key from the planned package list'
awk '/^  push:$/ { on = 1; next } on && /^    branches: \[main\]$/ { ok = 1 } on && /^[a-z]/ { exit } END { exit !ok }' "$count" \
  || fail 'main runs store the valgrind cache every PR can restore'
printf 'CI scope fixtures passed: %s; matrix, aggregate and performance schedule wiring verified\n' "$pass"

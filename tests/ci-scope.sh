#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
pass=0
check() {
  event=$1 branch=$2 scope=$3 changed=${4-} tests=${5:-true}
  actual=$(printf '%s' "$changed" | sh "$ROOT/.github/scripts/ci-scope.sh" "$event" "$branch")
  case "$scope" in
    full) expected=$(printf '%s\n' 'oses=["ubuntu-latest","macos-latest"]' 'check_prefix=Test') ;;
    subset) expected=$(printf '%s\n' 'oses=["ubuntu-latest"]' 'check_prefix=PR subset test') ;;
  esac
  # The include list is checked below; here it only has to be valid JSON
  # with macOS legs exactly on full runs.
  include=$(printf '%s\n' "$actual" | sed -n 's/^include=//p')
  printf '%s\n' "$include" | jq -e '.' > /dev/null || { printf 'not ok - include is JSON for %s\n' "$event"; exit 1; }
  macos_legs=$(printf '%s\n' "$include" | jq '[.[] | select(.os == "macos-latest")] | length')
  case "$scope:$macos_legs" in full:2|subset:0) ;; *) printf 'not ok - macOS legs for %s/%s: %s\n' "$event" "$branch" "$macos_legs"; exit 1 ;; esac
  actual=$(printf '%s\n' "$actual" | grep -v '^include=')
  expected=$(printf '%s\ntests=%s' "$expected" "$tests")
  if [ "$actual" != "$expected" ]; then
    printf 'not ok - CI scope for %s/%s [%s]\n' "$event" "$branch" "$changed"
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
# Documentation-only pull requests skip the suites; any other path, an
# unreadable list or a quoted path runs them. Release PRs and main never skip.
check pull_request feature/docs subset 'docs/installation.md' false
check pull_request feature/docs subset 'README.md
README.ko.md
docs/verification.ja.md
CONTRIBUTING.md' false
check pull_request feature/docs subset 'docs/installation.md
plugins/agent-guard/bin/agent-guard' true
check pull_request feature/docs subset 'CHANGELOG.md' true
check pull_request feature/docs subset 'docs.sh' true
check pull_request feature/docs subset '"docs/a\tb.md"' true
check pull_request feature/docs subset '' true
check pull_request release/v1.2.3 full 'docs/installation.md' true
check push main full 'docs/installation.md' true

# Pin the wiring as well as the producer: no event-specific name fallback.
grep -Fq 'os: ${{ fromJSON(needs.secret-guard.outputs.oses) }}' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'name: ${{ needs.secret-guard.outputs.check_prefix }} (${{ matrix.os }})' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'needs: [secret-guard, test-shard, release-evidence, long-input]' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'oses: ${{ steps.scope.outputs.oses }}' "$ROOT/.github/workflows/ci.yml"
grep -Fq 'check_prefix: ${{ steps.scope.outputs.check_prefix }}' "$ROOT/.github/workflows/ci.yml"
# macOS legs and the suites are gated on the same scope decision; every
# Linux leg still starts, so each required name reports.
grep -Fq 'include: ${{ fromJSON(needs.secret-guard.outputs.include) }}' "$ROOT/.github/workflows/ci.yml"
# The matrix context does not exist in a job-level condition.
if awk '/^    if:/ { on = 1 } on && /matrix[.]/ { found = 1 } /^    [a-z-]+:/ && !/^    if:/ { on = 0 } END { exit !found }' "$ROOT/.github/workflows/ci.yml"; then
  fail 'no job-level condition reads the matrix'
fi
[ "$(grep -c "needs.secret-guard.outputs.tests == 'true'" "$ROOT/.github/workflows/ci.yml")" -ge 7 ]
for gated in native-platforms native-redaction; do
  grep -Fq "github.event_name != 'pull_request' || startsWith(github.head_ref, 'release/')" "$ROOT/.github/workflows/$gated.yml"
done

# Performance measurement runs nightly, manually and on release PRs, outside
# the native qualification run that release reads. Only the schedule-only
# notify job may write issues, and release only warns about performance.
fail() {
  printf 'not ok - %s\n' "$1"
  exit 1
}
# Execute the aggregate's real shell block: a missing, skipped or failed
# timing matrix must not be hidden by successful ordinary shards.
aggregate=$(awk '/^  test:$/ { on = 1; next } on && /^  [a-z-]+:/ { exit } on' "$ROOT/.github/workflows/ci.yml")
printf '%s\n' "$aggregate" | grep -Fq 'LONG_INPUT_RESULT: ${{ needs.long-input.result }}' \
  || fail 'the aggregate receives the timing matrix result'
aggregate_tmp=$(mktemp -d)
trap 'rm -rf "$aggregate_tmp"' 0
printf '%s\n' "$aggregate" | awk '/^        run: \|$/ { on = 1; next } on && /^          / { print substr($0, 11) }' \
  >"$aggregate_tmp/check.sh"
[ -s "$aggregate_tmp/check.sh" ] || fail 'the aggregate has an executable result check'
REUSED=false EVIDENCE_RESULT=skipped SHARDS_RESULT=success LONG_INPUT_RESULT=success sh "$aggregate_tmp/check.sh" || fail 'both successful inputs pass'
for result in failure cancelled skipped ''; do
  if REUSED=false EVIDENCE_RESULT=skipped SHARDS_RESULT=success LONG_INPUT_RESULT="$result" sh "$aggregate_tmp/check.sh" >/dev/null 2>&1; then
    fail 'a non-successful timing matrix fails the aggregate'
  fi
  if REUSED=false EVIDENCE_RESULT=skipped SHARDS_RESULT="$result" LONG_INPUT_RESULT=success sh "$aggregate_tmp/check.sh" >/dev/null 2>&1; then
    fail 'a non-successful shard fails the aggregate'
  fi
  if REUSED=true EVIDENCE_RESULT=success SHARDS_RESULT=skipped LONG_INPUT_RESULT="$result" sh "$aggregate_tmp/check.sh" >/dev/null 2>&1; then
    fail 'reused release evidence cannot hide a non-successful timing matrix'
  fi
done
REUSED=true EVIDENCE_RESULT=success SHARDS_RESULT=skipped LONG_INPUT_RESULT=success sh "$aggregate_tmp/check.sh" \
  || fail 'verified release evidence can replace ordinary shards when timings pass'
rm -rf "$aggregate_tmp"
trap - 0
pass=$((pass + 14))
# Publication and release-tree reuse share the required-check manifest.
for variant in mawk gawk busybox; do
  check=$(printf 'ci.yml\tLarge hook inputs (%s)' "$variant")
  grep -Fxq "$check" "$ROOT/.github/release-checks.tsv" || fail 'release requires all three awk timings'
done
check=$(printf 'ci.yml\tCore, host adapters and Git (partition 3) (macos-latest)')
grep -Fxq "$check" "$ROOT/.github/release-checks.tsv" || fail 'release requires the macOS partition 3 check'
pass=$((pass + 1))
grep -Fq 'env AGENT_GUARD_TEST_REQUIRE_AWKS= AGENT_GUARD_TEST_LONG_INPUT_AWKS=default sh' "$ROOT/tests/run.sh" \
  || fail 'the default-awk subset clears inherited implementation requirements'
# Overridable so a must-fail control can point the checks at a mutated copy.
perf=${CI_SCOPE_PERFORMANCE_WORKFLOW:-$ROOT/.github/workflows/performance.yml}
perf_scope=${CI_SCOPE_PERFORMANCE_SCOPE:-$ROOT/.github/scripts/performance-scope.sh}
native="$ROOT/.github/workflows/native-platforms.yml"
[ -f "$perf" ] || fail 'performance workflow exists'
if grep -Eq '^  push:' "$perf"; then fail 'performance does not run on push'; fi
grep -Fq "    - cron: '" "$perf" || fail 'performance runs on a schedule'
grep -Fq '  workflow_dispatch:' "$perf" || fail 'performance runs on dispatch'
# Every pull request runs the workflow, so the shell instruction count exists
# on each one and can be required; the scope script picks what it measures.
awk '/^on:$/ { on = 1; next } on && /^[a-z]/ { exit } on' "$perf" | grep -Fxq '  pull_request:' \
  || fail 'performance runs on pull requests'
if awk '/^on:$/ { on = 1; next } on && /^[a-z]/ { exit } on' "$perf" | grep -Eq '^    (paths|paths-ignore|branches):'; then
  fail 'no pull request filter can keep the shell instruction count off a pull request'
fi
perf_case() { # $1 event, $2 packaged, $3 instruction_count, $4 changed paths (newline separated)
  got=$(printf '%s' "$4" | sh "$perf_scope" "$1" | tr '\n' ' ') \
    || fail "performance scope runs for $1"
  [ "$got" = "packaged=$2 instruction_count=$3 " ] || fail "performance scope for $1 [$4]: got '$got'"
  pass=$((pass + 1))
}
perf_case schedule true true ''
perf_case workflow_dispatch true true ''
perf_case pull_request true true 'plugins/agent-guard/.claude-plugin/plugin.json'
perf_case pull_request true true '.github/workflows/performance.yml'
perf_case pull_request true true '.github/scripts/performance-scope.sh'
perf_case pull_request true true 'bench/instruction-count/run.sh'
perf_case pull_request true false 'bench/native/run-packaged.sh'
perf_case pull_request true false 'native/devtools/src/main.rs'
perf_case pull_request true false 'scripts/build-native-artifact.sh'
perf_case pull_request true false 'scripts/install-native-test-tools.sh'
perf_case pull_request false true 'plugins/agent-guard/bin/agent-guard'
perf_case pull_request false true 'plugins/agent-guard/config/gitleaks.toml'
perf_case pull_request false true 'plugins/agent-guard/hooks/hooks.json'
perf_case pull_request false true 'bench/process-count/fake-gitleaks.c'
perf_case pull_request false true 'tests/fixtures/mock-gitleaks'
perf_case pull_request false true '.github/scripts/write-performance-source.sh'
perf_case pull_request false true "README.md
plugins/agent-guard/bin/agent-guard"
# A path git still quotes cannot be matched; it counts as relevant to both.
perf_case pull_request true true '"plugins/agent-guard/a\tb"'
perf_case pull_request false false 'README.md'
perf_case pull_request false false 'docs/installation.ko.md'
perf_case pull_request false false 'tests/run.sh'
perf_case pull_request false false 'tests/fixtures/mock-gitleaks-extra'
perf_case pull_request false false 'xplugins/agent-guard/bin/agent-guard'
perf_case pull_request false false 'bench/process-count/run.sh'
perf_case pull_request false false ''
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
printf '%s\n' "$notify" | grep -Fxq '    needs: [build, instruction-count, performance]' || fail 'notify waits for every measurement'
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
printf '%s\n' "$shell_gate" | grep -Fq 'sh head/bench/instruction-count/run.sh base head "$tsv" 2> "$out/errors.txt" || status=$?' \
  && printf '%s\n' "$shell_gate" | grep -Fq 'sh head/bench/instruction-count/run.sh --check "$tsv" 5 > "$out/over-limit.txt" 2>> "$out/errors.txt" || gate=$?' \
  && printf '%s\n' "$shell_gate" | grep -Fxq '          [ "$gate" -eq 0 ]' \
  || fail 'the shell gate fails above 5% with the tested script'
printf '%s\n' "$shell_gate" | grep -Fq "if: failure() && steps.count.outcome == 'skipped'" \
  && printf '%s\n' "$shell_gate" | grep -Fq 'uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' \
  && printf '%s\n' "$shell_gate" | grep -Fq 'sudo timeout --kill-after=5 55 apt-get' \
  && printf '%s\n' "$shell_gate" | grep -Fq 'timeout-minutes: 10' \
  || fail 'the shell gate reports a run that never measured and reuses the valgrind cache'
if printf '%s\n' "$shell_gate" | grep -Eq '^    (if|needs):|continue-on-error'; then fail 'the shell gate runs and gates on every event'; fi
awk '/^  build:$/ { on = 1; next } on && /^  [a-z-]+:$/ { exit } on' "$perf" | grep -Fxq "    if: needs.scope.outputs.packaged == 'true'" \
  || fail 'the packaged jobs run only when the scope selects them'
# Each step after the scope decision measures only when the change reaches the
# measured path; the setup-failure report and the evidence upload still run
# when the decision itself failed.
gate_steps=$(printf '%s\n' "$shell_gate" | awk '
  /^      - / { if (s != "") print s "|" g; s = $0; g = "none"; next }
  /^        if: / { g = substr($0, 13) }
  END { if (s != "") print s "|" g }')
[ "$(printf '%s\n' "$gate_steps" | sed -n 2p)" = '      - name: Decide whether the change reaches the measured path|none' ] \
  || fail 'the shell gate decides its scope right after the checkout'
printf '%s\n' "$gate_steps" | sed -n '3,$p' | while IFS= read -r step; do
  case $step in
    *"|steps.scope.outputs.instruction_count == 'true'"|*"|steps.scope.outputs.instruction_count == 'true' && "*) ;;
    *'Report a run that never reached the measurement|'"failure() && steps.count.outcome == 'skipped'") ;;
    *"upload-artifact@"*"|always() && steps.scope.outputs.instruction_count != 'false'") ;;
    *) fail "the shell gate step is not scoped: $step" ;;
  esac
done || exit 1
[ "$(printf '%s\n' "$gate_steps" | wc -l | tr -d ' ')" -ge 11 ] || fail 'the shell gate keeps its measuring steps'
# Run the job's own scope step on a real history: a docs-only change passes
# at once with a summary that says so, and a CLI change runs the measurement.
scope_step=$(printf '%s\n' "$shell_gate" | awk '
  /^      - name: Decide whether the change reaches the measured path$/ { on = 1; next }
  on && /^      - / { exit }
  on && /^        run: \|$/ { run = 1; next }
  run && /^          / { print substr($0, 11) }')
[ -n "$scope_step" ] || fail 'the shell gate scope step has a run block'
gate_tmp=$(mktemp -d)
trap 'rm -rf "$gate_tmp"' 0
(
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$gate_tmp"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
printf '%s\n' "$scope_step" > "$gate_tmp/scope.sh" || exit 1
for change in docs cli; do
  run="$gate_tmp/$change"
  mkdir -p "$run/head/.github/scripts" "$run/head/plugins/agent-guard/bin" "$run/temp" || exit 1
  cp "$perf_scope" "$run/head/.github/scripts/" || exit 1
  printf '#!/bin/sh\n' > "$run/head/plugins/agent-guard/bin/agent-guard" && printf '# demo\n' > "$run/head/README.md" || exit 1
  git init -q "$run/head" && git -C "$run/head" add . \
    && git -C "$run/head" -c user.email=t@example.test -c user.name=t commit -qm base || exit 1
  case $change in
    docs) printf 'more\n' >> "$run/head/README.md" ;;
    cli) printf ':\n' >> "$run/head/plugins/agent-guard/bin/agent-guard" ;;
  esac || exit 1
  git -C "$run/head" -c user.email=t@example.test -c user.name=t commit -qam "$change" || exit 1
  : > "$run/output" && : > "$run/summary" && cp "$gate_tmp/scope.sh" "$run/" || exit 1
  (cd "$run" && EVENT_NAME=pull_request RUNNER_TEMP="$run/temp" GITHUB_OUTPUT="$run/output" \
    GITHUB_STEP_SUMMARY="$run/summary" sh -e scope.sh) < /dev/null \
    || fail "the shell gate scope step runs on a $change change"
  case $change in
    docs)
      grep -Fxq instruction_count=false "$run/output" || fail 'a docs-only change skips the measurement'
      grep -Fq '측정하지 않고 통과합니다' "$run/summary" || fail 'a skipped measurement says so in the summary' ;;
    cli)
      grep -Fxq instruction_count=true "$run/output" || fail 'a CLI change runs the measurement'
      [ ! -s "$run/summary" ] || fail 'a measured change writes no skip summary' ;;
  esac
done
# A diff that cannot run fails the step rather than skip the measurement.
run="$gate_tmp/nohistory"
mkdir -p "$run/head" "$run/temp" && git init -q "$run/head" || exit 1
cp "$gate_tmp/scope.sh" "$run/" || exit 1
if (cd "$run" && EVENT_NAME=pull_request RUNNER_TEMP="$run/temp" GITHUB_OUTPUT="$run/output" \
    GITHUB_STEP_SUMMARY="$run/summary" sh -e scope.sh) > /dev/null 2>&1 < /dev/null; then
  fail 'a scope diff that cannot run fails the shell gate'
fi
) || exit 1
rm -rf "$gate_tmp"
trap - 0
pass=$((pass + 3))
grep -Fq '    needs: [build, instruction-count, performance' "$perf" \
  && grep -Fq '          name: instruction-count' "$perf" \
  || fail 'the nightly issue waits for and reads the shell gate'
grep -Fq 'name: Packaged performance evidence' "$perf" || fail 'packaged measurement moved'
for text in 'Packaged performance evidence' 'continue-on-error: true'; do
  if grep -Fq "$text" "$native"; then fail "native qualification has no $text"; fi
done
grep -Fq 'needs: [platform, installation, release-evidence]' "$native" || fail 'native aggregate waits for qualification or verified reuse'
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
grep -Fq 'sh .github/scripts/release-performance.sh "$SOURCE_SHA"' "$ROOT/.github/workflows/release.yml" \
  || fail 'release requires the shared performance classification'
grep -Fq 'performance-verdict.sh' "$ROOT/.github/scripts/release-performance.sh" \
  && grep -Fq 'threshold_exceeded)' "$ROOT/.github/scripts/release-performance.sh" \
  && grep -Fq 'exit 1' "$ROOT/.github/scripts/release-performance.sh" \
  || fail 'only completed threshold excess warns; failed measurement blocks'
grep -Fq 'performance-cause.sh' "$perf" \
  && grep -Fq 'contains($marker)' "$perf" \
  || fail 'different nightly causes receive separate issues'
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
# The warm gitleaks helper (#537) runs its macOS job on a pull request only
# when the helper itself changes; pushes and manual runs use both platforms.
helper_scope() { # $1 event, stdin changed paths -> the platform list
  sh "$ROOT/.github/scripts/gitleaks-helper-scope.sh" "$1" | sed -n 's/^matrix=//p' | jq -r '[.include[].os] | join(" ")'
}
helper_case() { # $1 event, $2 expected platforms, $3 changed paths (newline separated)
  got=$(printf '%s' "$3" | helper_scope "$1") || fail "helper scope runs for $1"
  [ "$got" = "$2" ] || fail "helper scope for $1 [$3]: got '$got', want '$2'"
  pass=$((pass + 1))
}
both='ubuntu-24.04 macos-15'
helper_case push "$both" ''
helper_case workflow_dispatch "$both" ''
helper_case pull_request "$both" 'native/gitleaks-helper/cmd/agent-guard-scan/main.go'
helper_case pull_request "$both" 'scripts/build-gitleaks-helper.sh'
helper_case pull_request "$both" 'scripts/gitleaks-helper-notices.sh'
helper_case pull_request ubuntu-24.04 'tests/gitleaks-helper-notices.sh'
helper_case pull_request "$both" 'tests/gitleaks-helper.sh'
helper_case pull_request "$both" 'tests/gitleaks-helper-corpus.sh'
helper_case pull_request "$both" 'tests/fixtures/fake-gitleaks-helper.py'
helper_case pull_request "$both" '.github/workflows/gitleaks-helper.yml'
helper_case pull_request "$both" '.github/scripts/gitleaks-helper-scope.sh'
helper_case pull_request "$both" "plugins/agent-guard/bin/agent-guard
native/gitleaks-helper/go.sum"
helper_case pull_request ubuntu-24.04 'plugins/agent-guard/bin/agent-guard'
# A path git still quotes cannot be matched; it fails safe to both platforms.
# A name that is not valid UTF-8 comes out raw; it must match in any locale.
# (Passed as bytes: macOS cannot create such a file.)
for locale in C.UTF-8 en_US.UTF-8; do
  got=$(printf 'native/gitleaks-helper/ff\377\n' | LC_ALL=$locale helper_scope pull_request) \
    && [ "$got" = "$both" ] || fail "a helper path that is not UTF-8 selects macOS under $locale: got '$got'"
  pass=$((pass + 1))
done
helper_case pull_request "$both" '"native/gitleaks-helper/a\tb.txt"'
helper_case pull_request ubuntu-24.04 'tests/fixtures/mock-gitleaks'
helper_case pull_request ubuntu-24.04 'plugins/agent-guard/config/gitleaks.toml'
helper_case pull_request ubuntu-24.04 'tests/gitleaks-helper-routing.sh'
helper_case pull_request ubuntu-24.04 'bench/gitleaks-helper/compare-off.sh'
helper_case pull_request ubuntu-24.04 'docs/native/gitleaks-helper/notes.md'
helper_case pull_request ubuntu-24.04 ''
helper_wf="$ROOT/.github/workflows/gitleaks-helper.yml"
# Run the workflow's own diff command on a real history: a helper file moved
# out of the helper tree, a non-ASCII helper path and a path git quotes (a
# tab) still select macOS.
helper_diff=$(sed -n 's/^ *\(git -c core.quotePath=false diff [^>]*\) > "\$RUNNER_TEMP\/changed"$/\1/p' "$helper_wf")
[ -n "$helper_diff" ] || fail 'the helper workflow lists changed paths with one git diff command'
helper_moves='rename unicode tab'
moves=$(mktemp -d)
trap 'rm -rf "$moves"' 0
# The throwaway repositories must not read the user's or system git config.
(
# The subshell runs under '|| exit 1', which turns errexit off inside it, so
# every git step fails it explicitly; it never climbs into an outer repo.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$moves"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
for change in $helper_moves; do
  rm -rf "$moves/repo"
  git init -q "$moves/repo" || exit 1
  mkdir -p "$moves/repo/native/gitleaks-helper" || exit 1
  printf 'package x\n' >"$moves/repo/native/gitleaks-helper/a.go" || exit 1
  git -C "$moves/repo" add . && git -C "$moves/repo" -c user.email=t@example.test -c user.name=t commit -qm base || exit 1
  case $change in
    rename) git -C "$moves/repo" mv native/gitleaks-helper/a.go moved.go ;;
    unicode) printf 'package x\n' >"$moves/repo/native/gitleaks-helper/é.go" && git -C "$moves/repo" add . ;;
    tab) printf 'x\n' >"$moves/repo/native/gitleaks-helper/a	b.txt" && git -C "$moves/repo" add . ;;
  esac || exit 1
  git -C "$moves/repo" -c user.email=t@example.test -c user.name=t commit -qm change || exit 1
  got=$(cd "$moves/repo" && eval "$helper_diff" | helper_scope pull_request) || fail "helper scope after a $change"
  [ "$got" = "$both" ] || fail "a helper $change selects macOS: got '$got'"
done
) || exit 1
pass=$((pass + $(set -- $helper_moves; echo $#)))
rm -rf "$moves"
trap - 0
grep -Fq 'matrix: ${{ fromJSON(needs.scope.outputs.matrix) }}' "$helper_wf" \
  && grep -Fq 'git -c core.quotePath=false diff --no-renames --name-only HEAD^1 HEAD > "$RUNNER_TEMP/changed"' "$helper_wf" \
  && grep -Fq 'sh .github/scripts/gitleaks-helper-scope.sh "$EVENT_NAME" < "$RUNNER_TEMP/changed" >> "$GITHUB_OUTPUT"' "$helper_wf" \
  && grep -Fq "      - '.github/scripts/gitleaks-helper-scope.sh'" "$helper_wf" \
  || fail 'the helper workflow takes its platforms from the tested scope script'
# The off-state comparison puts an unusable helper beside the unset state in
# one tree, and adds the base only when the diff touches the helper call sites.
off_job=$(awk '/^  off-state:/ { on = 1 } on' "$helper_wf")
printf '%s\n' "$off_job" | grep -Fq 'runs-on: ubuntu-24.04' \
  || fail 'the helper-off comparison runs on Linux'
printf '%s\n' "$off_job" | grep -Fxq '    name: Unusable helper equals unset in the same tree' \
  && printf '%s\n' "$off_job" | grep -Fxq '    timeout-minutes: 20' \
  || fail 'the helper-off job is named for what it compares, with the original time limit'
printf '%s\n' "$off_job" | grep -Fxq '          fetch-depth: 2' \
  && printf '%s\n' "$off_job" | grep -Fxq '        run: sh .github/scripts/helper-call-sites.sh HEAD^1 HEAD >> "$GITHUB_OUTPUT"' \
  || fail 'the helper-off job asks the call-site script about the merge parent'
printf '%s\n' "$off_job" | grep -Fq 'git worktree add --detach base-checkout HEAD^1' \
  && printf '%s\n' "$off_job" | grep -Fq 'compare-off.sh "$RUNNER_TEMP/official/gitleaks" "$GITHUB_WORKSPACE/base-checkout" "$SITES_SCOPE"' \
  && ! printf '%s\n' "$off_job" | grep -Fq 'pull_request.base.sha' \
  || fail 'the helper-off comparison base is the merge parent'
printf '%s\n' "$off_job" | grep -Fxq '              sh bench/gitleaks-helper/compare-off.sh "$RUNNER_TEMP/official/gitleaks"' \
  && printf '%s\n' "$off_job" | grep -Fq 'exit 1' \
  || fail 'the helper-off comparison runs without a base when untouched and fails without an answer'
for path in plugins/agent-guard/bin/agent-guard bench/gitleaks-helper/compare-off.sh .github/scripts/helper-call-sites.sh; do
  grep -Fxq "      - '$path'" "$helper_wf" || fail "helper PR filter includes $path"
done
if grep -Fq "      - 'bench/gitleaks-helper/**'" "$helper_wf"; then
  fail 'the helper workflow skips benchmarks it does not run'
fi
# The call-site script on real diffs of the CLI: the variants a same-tree
# comparison misses (work added where both states run, a plain branch folded
# into the wrapper, a wrapper call dropped) are found, a change unrelated to
# the helper is not, and a diff that cannot run is an error, not "none".
sites_script="$ROOT/.github/scripts/helper-call-sites.sh"
sites_cli=plugins/agent-guard/bin/agent-guard
sites_tmp=$(mktemp -d)
trap 'rm -rf "$sites_tmp"' 0
(
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$sites_tmp"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
repo="$sites_tmp/repo"
git init -q "$repo" && mkdir -p "$repo/plugins/agent-guard/bin" && cp "$ROOT/$sites_cli" "$repo/$sites_cli" \
  && git -C "$repo" add . && git -C "$repo" -c user.email=t@example.test -c user.name=t commit -qm base || exit 1
base_rev=$(git -C "$repo" rev-parse HEAD) || exit 1
sites_case() { # $1 description, $2 expected output, $3 awk program applied to the CLI, $4 .gitattributes
  rm -f "$repo/.gitattributes"
  git -C "$repo" checkout -q "$base_rev" -- . || exit 1
  awk "$3" "$ROOT/$sites_cli" >"$repo/$sites_cli.new" && mv "$repo/$sites_cli.new" "$repo/$sites_cli" || exit 1
  [ -z "${4:-}" ] || { printf '%s\n' "$4" >"$repo/.gitattributes" && git -C "$repo" add .gitattributes || exit 1; }
  git -C "$repo" diff --quiet "$base_rev" -- . && fail "the $1 variant changes the CLI"
  git -C "$repo" -c user.email=t@example.test -c user.name=t commit -qam "$1" || exit 1
  got=$(cd "$repo" && sh "$sites_script" "$base_rev" HEAD 2>/dev/null) || fail "call-site script on the $1 variant"
  [ "$got" = "$2" ] || fail "the $1 variant gives '$got', not '$2'"
}
sites_case 'work before the helper case' scope=full '{ print } /^gitleaks_helper_selected\(\) \{/ { print "  jq -n null >/dev/null" }'
sites_case 'plain branch through the wrapper' scope=cost '/^          "\$gl" stdin --report-format json/ && !done { sub(/"\$gl"/, "gitleaks_exec \"$gl\""); done = 1 } { print }'
sites_case 'wrapper call dropped' scope=cost '/gitleaks_exec "\$GITLEAKS_BIN" "\$@"/ && !done { sub(/gitleaks_exec /, ""); done = 1 } { print }'
sites_case 'work in a function that calls the wrapper' scope=cost '{ print } /^gitleaks_scan\(\) \{/ { print "  jq -n null >/dev/null" }'
sites_case 'output change in a function that calls the wrapper' scope=cost '{ sub(/secret-like value detected in/, "secret-like value found in") } { print }'
sites_case 'file sourced from an unrelated function' scope=full '{ print } /^block_on_scan_status\(\) \{/ { print "  . ./extra.sh" }'
sites_case 'helper function definition line' scope=full '{ sub(/^gitleaks_helper_selected\(\) \{/, "gitleaks_helper_selected() { :;") } { print }'
sites_case 'work on the definition line of a caller function' scope=cost '/^detect_output_secret_records\(\) \(/ { sub(/\(\) \(/, "() ( jq -n null >/dev/null;") } { print }'
sites_case 'helper function defined with a space before the parentheses' scope=full '/^block_on_scan_status\(\) \{/ { print "gitleaks_helper_extra () {\n  :\n}\n" } { print }'
sites_case 'indented helper function inside a caller' scope=full '{ print } /^gitleaks_scan\(\) \{/ { print "  gitleaks_helper_extra() { :; }" }'
sites_case 'work before the helper case, file marked -diff' scope=full '{ print } /^gitleaks_helper_selected\(\) \{/ { print "  jq -n null >/dev/null" }' 'plugins/agent-guard/bin/agent-guard -diff'
sites_case 'work in a caller, file given another diff driver' scope=cost '{ print } /^gitleaks_scan\(\) \{/ { print "  jq -n null >/dev/null" }' 'plugins/agent-guard/bin/agent-guard diff=cpp'
sites_case 'conditional sourcing in an unrelated function' scope=full '{ print } /^block_on_scan_status\(\) \{/ { print "  if [ -r ./extra.sh ]; then . ./extra.sh; fi" }'
sites_case 'change unrelated to the helper' scope=none '{ print } /^block_on_scan_status\(\) \{/ { print "  jq -n null >/dev/null" }'
git -C "$repo" checkout -q "$base_rev" -- . || exit 1
got=$(cd "$repo" && sh "$sites_script" "$base_rev" HEAD) && [ "$got" = scope=none ] || fail 'no change leaves the call sites untouched'
# No function names the helper in either revision: the callers list is empty.
mini="$sites_tmp/mini"
git init -q "$mini" && mkdir -p "$mini/plugins/agent-guard/bin" && printf 'f() {\n  echo a\n}\n' >"$mini/$sites_cli" \
  && git -C "$mini" add . && git -C "$mini" -c user.email=t@example.test -c user.name=t commit -qm base || exit 1
mini_base=$(git -C "$mini" rev-parse HEAD) || exit 1
printf 'f() {\n  . ./extra.sh\n  echo a\n}\n' >"$mini/$sites_cli" \
  && git -C "$mini" -c user.email=t@example.test -c user.name=t commit -qam sourcing || exit 1
got=$(cd "$mini" && sh "$sites_script" "$mini_base" HEAD 2>/dev/null) && [ "$got" = scope=full ] || fail 'sourcing is found when no function names the helper'
if (cd "$repo" && sh "$sites_script" no-such-revision HEAD >/dev/null 2>&1); then fail 'a diff that cannot run is an error'; fi
) || exit 1
pass=$((pass + 17))
rm -rf "$sites_tmp"
trap - 0
printf 'CI scope fixtures passed: %s; matrix, aggregate and performance schedule wiring verified\n' "$pass"

#!/bin/sh
# Synthetic API fixtures and real Git trees, never release evidence.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
export RELEASE_FIXTURE_DIR="$case_dir" GITHUB_REPOSITORY=test/repo
REAL_GIT=$(command -v git)
export REAL_GIT
mkdir -p "$case_dir/bin" "$case_dir/repo/plugins/agent-guard/.claude-plugin"
cat > "$case_dir/bin/git" <<'MOCK'
#!/bin/sh
if [ "$1" = fetch ]; then exit 0; fi
exec "$REAL_GIT" "$@"
MOCK
cat > "$case_dir/bin/gh" <<'MOCK'
#!/bin/sh
case " $* " in
  *check-runs*)
    [ ! -f "$RELEASE_FIXTURE_DIR/api-error" ] || exit 1
    cat "$RELEASE_FIXTURE_DIR/checks.json"
    if [ -f "$RELEASE_FIXTURE_DIR/after-checks.json" ]; then
      mv "$RELEASE_FIXTURE_DIR/after-checks.json" "$RELEASE_FIXTURE_DIR/checks.json"
    fi ;;
  *actions/workflows/performance.yml/runs*) cat "$RELEASE_FIXTURE_DIR/performance.json" ;;
  *actions/runs/*/jobs*) cat "$RELEASE_FIXTURE_DIR/jobs.json" ;;
  *actions/runs/*/artifacts*)
    for arg in "$@"; do
      case "$arg" in
        repos/*/actions/runs/*/artifacts*)
          id=${arg##*/actions/runs/}
          id=${id%%/*}
          if [ -f "$RELEASE_FIXTURE_DIR/artifacts-$id.json" ]; then cat "$RELEASE_FIXTURE_DIR/artifacts-$id.json"; exit; fi ;;
      esac
    done
    cat "$RELEASE_FIXTURE_DIR/artifacts.json" ;;
  *actions/workflows/*.yml/runs*)
    [ ! -f "$RELEASE_FIXTURE_DIR/workflow-api-error" ] || exit 1
    for arg in "$@"; do
      case "$arg" in
        repos/*/actions/workflows/*)
          workflow=${arg##*/workflows/}
          workflow=${workflow%%/*}
          cat "$RELEASE_FIXTURE_DIR/$workflow.json"
          exit ;;
      esac
    done
    exit 2 ;;
  *' workflow run '*) printf '%s\n' "$*" >> "$RELEASE_FIXTURE_DIR/dispatch.log" ;;
  *commits/*/pulls*) cat "$RELEASE_FIXTURE_DIR/prs.json" ;;
  *pulls/1*) cat "$RELEASE_FIXTURE_DIR/pr.json" ;;
  *commits/*) cat "$RELEASE_FIXTURE_DIR/merge.json" ;;
  *' run download '*)
    artifact= destination=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --name) shift; artifact=$1 ;;
        --dir) shift; destination=$1 ;;
      esac
      shift
    done
    mkdir -p "$destination"
    cp "$RELEASE_FIXTURE_DIR/evidence/$artifact/"* "$destination/" ;;
  *) exit 2 ;;
esac
MOCK
printf '#!/bin/sh\nprintf "waited\\n" >> "$RELEASE_FIXTURE_DIR/sleep.log"\n' > "$case_dir/bin/sleep"
chmod 755 "$case_dir/bin/git" "$case_dir/bin/gh" "$case_dir/bin/sleep"
export PATH="$case_dir/bin:$PATH"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
reject() {
  if "$@" > "$case_dir/rejected.out" 2> "$case_dir/rejected.err"; then fail "unexpected success: $*"; fi
}
cd "$case_dir/repo"
git init -q
git config user.name Fixture
git config user.email fixture@example.invalid
printf '{"version":"1.0.0"}\n' > plugins/agent-guard/.claude-plugin/plugin.json
git add .
git commit -qm base
base=$(git rev-parse HEAD)
printf '{"version":"1.0.1"}\n' > plugins/agent-guard/.claude-plugin/plugin.json
git add .
git commit -qm candidate
head=$(git rev-parse HEAD)
tree=$(git rev-parse 'HEAD^{tree}')
merge=$(printf 'release squash\n' | git commit-tree "$tree" -p "$base")
git update-ref refs/remotes/origin/main "$merge"
export GITHUB_SHA="$merge" GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=push
pr() {
  jq -n --arg head "$head" --arg merge "$merge" --arg base "$base" \
    '{number:1,merged:true,merged_at:"synthetic",state:"closed",merge_commit_sha:$merge,
      base:{ref:"main",sha:$base},head:{sha:$head,ref:"release/v1.0.1",repo:{full_name:"test/repo"}},
      user:{login:"github-actions[bot]"},labels:[{name:"release"}],body:"<!-- agent-guard-release:publish -->"}' > "$case_dir/pr.json"
  jq -s . "$case_dir/pr.json" > "$case_dir/prs.json"
  jq -n --arg base "$base" '{parents:[{sha:$base}]}' > "$case_dir/merge.json"
}
checks() {
  : > "$case_dir/check-rows"
  while IFS="$(printf '\t')" read -r workflow name; do
    suite=$(printf '%s' "$workflow" | cksum | cut -d ' ' -f1)
    jq -nc --arg name "$name" --arg sha "$head" --argjson suite "$suite" \
      '{id:1,name:$name,head_sha:$sha,check_suite:{id:$suite},app:{slug:"github-actions"},status:"completed",conclusion:"success",details_url:"https://example.invalid/check"}' >> "$case_dir/check-rows"
    jq -nc --arg workflow "$workflow" --arg sha "$head" --argjson suite "$suite" \
      '[{workflow_runs:[{id:1,event:"workflow_dispatch",head_sha:$sha,path:(".github/workflows/"+$workflow),check_suite_id:$suite}]}]' > "$case_dir/$workflow.json"
  done < "$ROOT/.github/release-checks.tsv"
  jq -s '[{check_runs:.}]' "$case_dir/check-rows" > "$case_dir/checks.json"
}
target() { sh "$ROOT/.github/scripts/release-target.sh" 1 1.0.1 "${1:-false}"; }
reuse() { sh "$ROOT/.github/scripts/reuse-release-tree.sh"; }
pr
checks
mkdir -p "$case_dir/empty-policy/.github/scripts"
cp "$ROOT/.github/scripts/release-checks.sh" "$case_dir/empty-policy/.github/scripts/"
: > "$case_dir/empty-policy/.github/release-checks.tsv"
reject sh "$case_dir/empty-policy/.github/scripts/release-checks.sh" "$head" 0
grep -Fq 'Invalid required check manifest' "$case_dir/rejected.err" || fail 'empty policy fails closed'
printf 'not a workflow or tab-separated check\n' > "$case_dir/empty-policy/.github/release-checks.tsv"
reject sh "$case_dir/empty-policy/.github/scripts/release-checks.sh" "$head" 0
printf 'ci.yml\tAgent Guard\nci.yml\tLint' > "$case_dir/empty-policy/.github/release-checks.tsv"
jq '(.[0].check_runs[] | select(.name == "Lint")).conclusion="failure"' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$case_dir/empty-policy/.github/scripts/release-checks.sh" "$head" 0
grep -Fq "'Lint'" "$case_dir/rejected.err" || fail 'unterminated final check is still mandatory'
checks
sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
target > "$case_dir/target"
grep -Fxq "source_sha=$head" "$case_dir/target" || fail 'identical reviewed tree is reused'
reuse > "$case_dir/reuse"
grep -Fxq reuse=true "$case_dir/reuse" || fail 'squash release push reuses exact successful head'
printf 'ok - identical squash release tree reuses required checks\n'

jq --arg head "$head" '.parents += [{sha:$head}]' "$case_dir/merge.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/merge.json"
target > "$case_dir/target"
grep -Fxq "source_sha=$merge" "$case_dir/target" || fail 'two-parent merge requires exact merge checks'
reuse | grep -Fxq reuse=false || fail 'two-parent merge runs full main CI'
pr
jq --arg head "$head" '.parents[0].sha=$head' "$case_dir/merge.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/merge.json"
target > "$case_dir/target"
grep -Fxq "source_sha=$merge" "$case_dir/target" || fail 'different parent requires exact merge checks'
reuse | grep -Fxq reuse=false || fail 'different parent runs full main CI'
pr
printf 'ok - two parents or a parent differing from reviewed base require main CI\n'

jq '.[0].check_runs[0].check_suite.id=42' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
reuse | grep -Fxq reuse=false || fail 'same-named check from another workflow is not evidence'
checks
jq '.[0].workflow_runs[0].path=".github/workflows/unrelated.yml"' "$case_dir/ci.yml.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/ci.yml.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
checks
jq '.[0].workflow_runs[0].head_sha="0000000000000000000000000000000000000000"' "$case_dir/ci.yml.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/ci.yml.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
checks
printf 'ok - check suite, workflow path and run SHA must match the required workflow\n'

cp "$case_dir/checks.json" "$case_dir/after-checks.json"
jq '.[0].check_runs[0].status="queued"' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
sh "$ROOT/.github/scripts/release-checks.sh" "$head" 60 > "$case_dir/waited"
grep -Fxq waited "$case_dir/sleep.log" || fail 'unfinished checks are awaited'
printf 'ok - queued checks are awaited until they succeed\n'

jq '.[0].check_runs |= .[1:]' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
reuse | grep -Fxq reuse=false || fail 'missing check runs full main CI'
target > "$case_dir/target"
grep -Fxq "source_sha=$merge" "$case_dir/target" || fail 'publication falls back to exact merge checks when head evidence is missing'
grep -Fq missing "$case_dir/rejected.out" || fail 'missing is named separately'
checks
jq '.[0].check_runs[0].conclusion="failure"' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
grep -Fq 'failed: failure' "$case_dir/rejected.err" || fail 'failed conclusion is explicit'
checks
jq '.[0].check_runs[0].status="in_progress"' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
grep -Fq in_progress "$case_dir/rejected.out" || fail 'pending is named separately'
checks
touch "$case_dir/api-error"
reuse | grep -Fxq reuse=false || fail 'API error runs full main CI'
rm "$case_dir/api-error"
touch "$case_dir/workflow-api-error"
reuse | grep -Fxq reuse=false || fail 'workflow lookup error runs full main CI'
rm "$case_dir/workflow-api-error"
printf 'ok - missing, failed, unfinished and unreadable checks fail closed\n'

ci_suite=$(printf '%s' ci.yml | cksum | cut -d ' ' -f1)
ci_run() { # id event suite status conclusion
  jq -nc --argjson id "$1" --arg event "$2" --argjson suite "$3" --arg status "$4" --arg conclusion "$5" --arg sha "$head" \
    '{id:$id,event:$event,head_sha:$sha,path:".github/workflows/ci.yml",check_suite_id:$suite,status:$status,conclusion:(if $conclusion == "" then null else $conclusion end)}'
}
ci_runs() { jq -s '[{workflow_runs:.}]' > "$case_dir/ci.yml.json"; }
good_checks() { sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0; }
only_ci() { sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0 ci.yml; }

checks
{ ci_run 1 workflow_dispatch "$ci_suite" completed success; ci_run 9 pull_request 777 completed success; } | ci_runs
good_checks || fail 'a newer pull_request run does not hide the dispatched run'
{ ci_run 1 push "$ci_suite" completed success; ci_run 9 pull_request 777 in_progress ''; } | ci_runs
good_checks || fail 'a newer unfinished pull_request run does not hide the push run'
printf 'ok - the newest push or workflow_dispatch run is chosen, never a pull_request run\n'

{ ci_run 1 workflow_dispatch "$ci_suite" completed success; ci_run 9 workflow_dispatch 888 queued ''; } | ci_runs
good_checks || fail 'an earlier successful dispatched run satisfies a queued newer run'
only_ci || fail 'dispatch step skips a workflow with a successful run'
printf 'ok - a completed successful run at the exact SHA is reused while a newer run is still queued\n'

{ ci_run 1 workflow_dispatch "$ci_suite" completed success; ci_run 9 workflow_dispatch 888 completed failure; } | ci_runs
jq -c '.[0].check_runs += [{id:2,name:"Lint",head_sha:"'"$head"'",check_suite:{id:888},app:{slug:"github-actions"},status:"completed",conclusion:"failure"}]' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
grep -Fq 'failed: failure' "$case_dir/rejected.err" || fail 'a failed newest run still fails'
reject only_ci
checks

{ ci_run 1 workflow_dispatch "$ci_suite" completed failure; ci_run 9 workflow_dispatch 888 queued ''; } | ci_runs
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
{ ci_run 1 pull_request "$ci_suite" completed success; ci_run 9 workflow_dispatch 888 queued ''; } | ci_runs
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
reject only_ci
{ ci_run 1 workflow_dispatch "$ci_suite" completed success; ci_run 9 workflow_dispatch 888 queued ''; } | ci_runs
jq '.[0].check_runs |= map(select(.name != "Lint"))' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
grep -Fq "Required check 'Lint'" "$case_dir/rejected.out" || fail 'an earlier run lacking a required name is not evidence'
reject only_ci
checks
{ ci_run 1 workflow_dispatch "$ci_suite" completed success; ci_run 9 workflow_dispatch 888 queued ''; } | ci_runs
jq '(.[0].check_runs[] | select(.name == "Lint")).app.slug="other-app"' "$case_dir/checks.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/checks.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
checks
jq '.[0].workflow_runs[0].head_sha="0000000000000000000000000000000000000000"' "$case_dir/ci.yml.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/ci.yml.json"
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0
reject sh "$ROOT/.github/scripts/release-checks.sh" "$head" 0 not-in-manifest.yml
checks
printf 'ok - reuse never accepts failed, partial, foreign-app, pull_request or other-SHA evidence\n'

release_yml="$ROOT/.github/workflows/release.yml"
awk '/^  verify:/ { on = 1 } /^  publish:/ { on = 0 } on' "$release_yml" > "$case_dir/verify-job"
grep -Fxq '    timeout-minutes: 180' "$case_dir/verify-job" || fail 'verify job has a long hard upper bound'
grep -Fq 'release-checks.sh "$SOURCE_SHA" 0 "$workflow"' "$case_dir/verify-job" || fail 'dispatch step skips already successful workflows'
grep -Fq 'release-checks.sh "$RELEASE_HEAD_SHA" 7200' "$case_dir/verify-job" || fail 'verify waits for a long runner queue'
grep -Fq 'release-performance.sh "$RELEASE_HEAD_SHA" 3000' "$case_dir/verify-job" || fail 'verify waits for the measurement within the job bound'
printf 'ok - verify survives a long queue within a hard job bound\n'

jq '.labels=[]' "$case_dir/pr.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/pr.json"
jq -s . "$case_dir/pr.json" > "$case_dir/prs.json"
reject target
reuse | grep -Fxq reuse=false || fail 'ordinary main push runs full CI'
pr
jq '.head.ref="release/v1.0.2"' "$case_dir/pr.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/pr.json"
reject target
pr
printf 'ok - release label and candidate version are mandatory\n'

printf 'new main content\n' > moved
git add moved
git commit -qm moved
different_tree=$(git rev-parse 'HEAD^{tree}')
merge=$(printf 'different squash\n' | git commit-tree "$different_tree" -p "$base")
git update-ref refs/remotes/origin/main "$merge"
export GITHUB_SHA="$merge"
pr
target > "$case_dir/target"
grep -Fxq "source_sha=$merge" "$case_dir/target" || fail 'different tree requires exact merge checks'
reuse | grep -Fxq reuse=false || fail 'tree mismatch runs full main CI'
git update-ref refs/remotes/origin/main "$head"
reject target
printf 'ok - changed trees require main checks and advanced main cannot publish\n'

pr
jq '.merged=false | .state="open" | .head.ref="release/dry-run-1/v1.0.1" | .body="<!-- agent-guard-release:dry-run -->"' "$case_dir/pr.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/pr.json"
target true > "$case_dir/target"
grep -Fxq "release_sha=$head" "$case_dir/target" || fail 'dry run qualifies candidate head'
reject target false
printf 'ok - dry run candidate cannot authorize real publication\n'

mkdir -p "$case_dir/evidence/packaged-performance" "$case_dir/evidence/instruction-count"
jq -n --arg head "$head" '{workflow_runs:[{head_sha:$head,id:1,status:"completed"}]}' > "$case_dir/performance.json"
for artifact in packaged-performance instruction-count; do
  printf 'passed\n' > "$case_dir/evidence/$artifact/verdict.txt"
done
for pair in packaged-performance:101 instruction-count:102; do
  EVIDENCE_JOB_CONTEXT="{\"check_run_id\":${pair#*:}}" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA="$head" \
    sh "$ROOT/.github/scripts/write-performance-source.sh" "$case_dir/evidence/${pair%:*}"
done
jq -n --arg head "$head" '[{jobs:[
  {id:1,name:"Packaged performance evidence",head_sha:$head,run_id:1,run_attempt:1,
   status:"completed",conclusion:"success",check_run_url:"https://example.invalid/check-runs/101"},
  {id:2,name:"Shell instruction count against the latest release",head_sha:$head,run_id:1,run_attempt:1,
   status:"completed",conclusion:"success",check_run_url:"https://example.invalid/check-runs/102"}
]}]' > "$case_dir/jobs.json"
perf() { sh "$ROOT/.github/scripts/release-performance.sh" "$head" 0; }
perf
printf 'threshold_exceeded\n' > "$case_dir/evidence/packaged-performance/verdict.txt"
jq '.[0].jobs[0].conclusion="failure"' "$case_dir/jobs.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/jobs.json"
perf > "$case_dir/warning"
grep -Fq '::warning' "$case_dir/warning" || fail 'completed threshold excess warns'
cp "$case_dir/jobs.json" "$case_dir/fresh-jobs.json"
jq '.[0].jobs[0].check_run_url="https://example.invalid/check-runs/201"' "$case_dir/fresh-jobs.json" > "$case_dir/jobs.json"
reject perf
grep -Fq 'evidence link check_mismatch' "$case_dir/rejected.err" || fail 'check link failure is visible'
jq '.[0].jobs[0].run_attempt=2' "$case_dir/fresh-jobs.json" > "$case_dir/jobs.json"
reject perf
grep -Fq 'evidence link attempt_mismatch' "$case_dir/rejected.err" || fail 'attempt link failure is visible'
jq '.[0].jobs[0] |= (.check_run_url="https://example.invalid/check-runs/201" | .run_attempt=2 | .conclusion="cancelled")' \
  "$case_dir/fresh-jobs.json" > "$case_dir/jobs.json"
reject perf
grep -Fq 'evidence link job_cancelled' "$case_dir/rejected.err" || fail 'cancelled latest job is visible'
grep -Fq 'did not finish or failed validation' "$case_dir/rejected.err" || fail 'stale artifact cannot hide a cancelled latest job'
cp "$case_dir/fresh-jobs.json" "$case_dir/jobs.json"
printf 'ok - fresh job evidence passes or warns; stale check, attempt and cancelled evidence block\n'
printf 'measurement_error\n' > "$case_dir/evidence/packaged-performance/verdict.txt"
printf 'measurement timed out\n' > "$case_dir/evidence/packaged-performance/errors.txt"
reject perf
grep -Fq 'measurement timed out' "$case_dir/rejected.err" || fail 'tool stderr is visible'
jq '.workflow_runs[0].status="in_progress"' "$case_dir/performance.json" > "$case_dir/changed"
mv "$case_dir/changed" "$case_dir/performance.json"
reject perf
printf 'ok - measurement failure blocks and complete threshold excess warns\n'

cause() { sh "$ROOT/.github/scripts/performance-cause.sh" "$case_dir/evidence" '- Packaged performance evidence: failure'; }
first=$(cause)
[ "$first" = "$(cause)" ] || fail 'same cause has stable issue identity'
printf 'output validation failed\n' > "$case_dir/evidence/packaged-performance/errors.txt"
[ "$first" != "$(cause)" ] || fail 'different tool error opens a different issue'
printf 'ok - changed nightly failure cause gets a separate issue identity\n'

# Publication falls back to the exact merge commit when the reviewed tree
# differs. Workflows that never run on a push must then be dispatched there,
# or their required checks never report on that SHA.
pub="$case_dir/publish-fallback"
mkdir -p "$pub/.github"
cp -R "$ROOT/.github/workflows" "$pub/.github/workflows"
cp -R "$ROOT/.github/scripts" "$pub/.github/scripts"
cp "$ROOT/.github/release-checks.tsv" "$pub/.github/release-checks.tsv"
awk '/^      - name: Dispatch candidate verification/ { on = 1; next } on && /^      - name:/ { exit }
  on && /^        run: \|$/ { body = 1; next } body { print substr($0, 11) }' "$ROOT/.github/workflows/release.yml" > "$case_dir/dispatch-step.sh"
[ -s "$case_dir/dispatch-step.sh" ] || fail 'the dispatch step has a run block'
(
  cd "$pub"
  git init -q
  git config user.name Fixture
  git config user.email fixture@example.invalid
  git add . && git commit -qm pub
  git update-ref refs/remotes/origin/main HEAD
  current=$(git rev-parse HEAD)
  : > "$case_dir/dispatch.log"
  MODE=publish SOURCE_SHA="$current" RELEASE_SHA="$current" RELEASE_BRANCH=main bash "$case_dir/dispatch-step.sh"
) || fail 'the publish fallback dispatch step runs'
grep -Fxq 'workflow run performance.yml --ref main' "$case_dir/dispatch.log" || fail 'fallback measures the merge commit'
cut -f1 "$ROOT/.github/release-checks.tsv" | sort -u | while IFS= read -r workflow; do
  if awk '/^on:$/ { on = 1; next } on && /^[a-z]/ { exit } on' "$ROOT/.github/workflows/$workflow" | grep -Eq '^  push:'; then
    if grep -Fq "workflow run $workflow " "$case_dir/dispatch.log"; then fail "push-triggered $workflow is not dispatched again"; fi
  else
    grep -Fxq "workflow run $workflow --ref main" "$case_dir/dispatch.log" || fail "fallback dispatches $workflow, which has no push trigger"
  fi
done
grep -Fxq 'workflow run mutation-check.yml --ref main' "$case_dir/dispatch.log" || fail 'fallback dispatches the mutation check'
# A retried publication does not dispatch a workflow that already passed there.
current=$(git -C "$pub" rev-parse HEAD)
: > "$case_dir/check-rows"
awk -F '\t' '$1 == "mutation-check.yml" { print $2 }' "$ROOT/.github/release-checks.tsv" | while IFS= read -r name; do
  jq -nc --arg name "$name" --arg sha "$current" \
    '{id:1,name:$name,head_sha:$sha,check_suite:{id:77},app:{slug:"github-actions"},status:"completed",conclusion:"success"}' >> "$case_dir/check-rows"
done
jq -s '[{check_runs:.}]' "$case_dir/check-rows" > "$case_dir/checks.json"
jq -n --arg sha "$current" '[{workflow_runs:[{id:3,event:"workflow_dispatch",head_sha:$sha,path:".github/workflows/mutation-check.yml",check_suite_id:77,status:"completed",conclusion:"success"}]}]' \
  > "$case_dir/mutation-check.yml.json"
(
  cd "$pub"
  : > "$case_dir/dispatch.log"
  MODE=publish SOURCE_SHA="$current" RELEASE_SHA="$current" RELEASE_BRANCH=main bash "$case_dir/dispatch-step.sh" > /dev/null
) || fail 'the retried publish dispatch step runs'
if grep -Fq 'workflow run mutation-check.yml' "$case_dir/dispatch.log"; then fail 'a passed workflow is not dispatched again'; fi
grep -Fxq 'workflow run performance.yml --ref main' "$case_dir/dispatch.log" || fail 'a retry still measures the merge commit'
rm "$case_dir/mutation-check.yml.json"
# Main moved after the first check: refuse rather than dispatch a newer commit.
(
  cd "$pub"
  : > "$case_dir/dispatch.log"
  moved=$(git commit-tree "$(git rev-parse 'HEAD^{tree}')" -p HEAD -m moved)
  # The first fetch (the step's opening check) still sees the release; main
  # moves before the dispatch.
  : > "$case_dir/fetches"
  printf '#!/bin/sh\nif [ "$1" = fetch ]; then echo x >> "$RELEASE_FIXTURE_DIR/fetches"; [ "$(wc -l < "$RELEASE_FIXTURE_DIR/fetches")" -lt 2 ] || "$REAL_GIT" update-ref refs/remotes/origin/main %s; exit 0; fi\nexec "$REAL_GIT" "$@"\n' "$moved" > "$case_dir/bin/git"
  if MODE=publish SOURCE_SHA="$current" RELEASE_SHA="$current" RELEASE_BRANCH=main bash "$case_dir/dispatch-step.sh" > /dev/null 2>&1; then
    exit 1
  fi
) || fail 'a moved main is refused before dispatch'
printf '#!/bin/sh\nif [ "$1" = fetch ]; then exit 0; fi\nexec "$REAL_GIT" "$@"\n' > "$case_dir/bin/git"
if grep -Fq 'workflow run mutation-check.yml' "$case_dir/dispatch.log"; then fail 'nothing is dispatched once main moved'; fi
[ "$(wc -l < "$case_dir/fetches")" -ge 2 ] || fail 'main is checked again right before the dispatch'
printf 'ok - the merge-commit fallback dispatches required workflows that a push does not start\n'

# A main push reuses an ordinary PR's newest run of the same workflow only
# when it succeeded and recorded the very tree being pushed. Anything else
# runs again; a lookup that fails runs everything.
tested() { sh "$ROOT/.github/scripts/reuse-tested-tree.sh" ci.yml 2> "$case_dir/tested.err"; }
expect_tested() { # $1 expected reuse/ordinary lines, $2 description
  tested > "$case_dir/tested" || fail "reuse-tested-tree runs: $2"
  [ "$(grep -E '^(reuse|ordinary)=' "$case_dir/tested" | tr '\n' ' ')" = "$1" ] \
    || fail "$2: $(tr '\n' ' ' < "$case_dir/tested")"
}
edit_fixture() { # $1 file, $2 jq program; a run list is edited as one page
  if [ "$1" = ci.yml.json ]; then
    jq ".[0] | $2" "$case_dir/$1" > "$case_dir/changed" && mv "$case_dir/changed" "$case_dir/$1" && pages
  else
    jq "$2" "$case_dir/$1" > "$case_dir/changed" && mv "$case_dir/changed" "$case_dir/$1"
  fi
}
pages() { # gh --paginate --slurp: the run list is an array of pages
  jq -s '.' "$case_dir/ci.yml.json" > "$case_dir/changed" && mv "$case_dir/changed" "$case_dir/ci.yml.json"
}
git checkout -q --detach "$base"
printf 'feature\n' > feature
git add feature
git commit -qm feature
feature=$(git rev-parse HEAD)
merge=$(printf 'feature squash\n' | git commit-tree "$(git rev-parse 'HEAD^{tree}')" -p "$base")
export GITHUB_SHA="$merge" GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main GITHUB_RUN_ID=9 GITHUB_RUN_ATTEMPT=1
ordinary_pr() { # $1 the tree the PR run recorded
  jq -n --arg head "$feature" --arg merge "$merge" \
    '[{number:7,merged_at:"synthetic",merge_commit_sha:$merge,base:{ref:"main"},
       head:{sha:$head,ref:"feature/x",repo:{full_name:"test/repo"}},labels:[]}]' > "$case_dir/prs.json"
  jq -n --arg head "$feature" \
    '{workflow_runs:[{id:5,head_sha:$head,event:"pull_request",path:".github/workflows/ci.yml",
       head_branch:"feature/x",head_repository:{full_name:"test/repo"},run_started_at:"2026-11-20T00:00:00Z",status:"completed",conclusion:"success"}]}' \
    > "$case_dir/ci.yml.json"
  pages
  printf '{"artifacts":[{"name":"tested-tree","expired":false}]}\n' > "$case_dir/artifacts.json"
  mkdir -p "$case_dir/evidence/tested-tree"
  printf '%s\n' "${1:-$(git rev-parse "$merge^{tree}")}" > "$case_dir/evidence/tested-tree/tree"
}
ordinary_pr
expect_tested 'reuse=true ordinary=true ' 'a passed PR run of the same tree is reused'
grep -Fxq "source_sha=$feature" "$case_dir/tested" || fail 'reused evidence names the PR head'
grep -Fxq 'source_run=5' "$case_dir/tested" || fail 'reused evidence names the PR run'
# The run tested a merge onto another base: the recorded tree differs.
ordinary_pr "$(git rev-parse "$base^{tree}")"
expect_tested 'reuse=false ordinary=true ' 'a run that tested another tree runs again'
ordinary_pr
edit_fixture ci.yml.json '.workflow_runs += [.workflow_runs[0] | .id = 6 | .run_started_at = "2026-11-21T00:00:00Z" | .conclusion = "failure"]'
expect_tested 'reuse=false ordinary=true ' 'a newer failed run on the head is not evidence'
# A matching run without its branch or repository cannot be ruled out.
ordinary_pr
edit_fixture ci.yml.json '.workflow_runs += [.workflow_runs[0] | .id = 6 | .run_started_at = "2026-11-21T00:00:00Z" | del(.head_repository) | .conclusion = "failure"]'
expect_tested 'reuse=false ordinary=false ' 'a run without identity keeps the full matrix'
for field in head_sha event path; do
  ordinary_pr
  edit_fixture ci.yml.json ".workflow_runs += [.workflow_runs[0] | .id = 6 | .run_started_at = \"2026-11-21T00:00:00Z\" | del(.$field) | .conclusion = \"failure\"]"
  expect_tested 'reuse=false ordinary=false ' "a newer run without $field keeps the full matrix"
done
# A run without a start time cannot be ordered: that is unreadable evidence.
ordinary_pr
edit_fixture ci.yml.json '.workflow_runs += [.workflow_runs[0] | .id = 6 | .run_started_at = null | .conclusion = "failure"]'
expect_tested 'reuse=false ordinary=false ' 'a run without a start time keeps the full matrix'
# A re-run on a later page still decides.
ordinary_pr
jq '. + [{workflow_runs:[.[0].workflow_runs[0] | .id = 3 | .run_started_at = "2026-11-22T00:00:00Z" | .conclusion = "failure"]}]' \
  "$case_dir/ci.yml.json" > "$case_dir/changed" && mv "$case_dir/changed" "$case_dir/ci.yml.json"
expect_tested 'reuse=false ordinary=true ' 'a failed re-run on another page is not hidden'
# An older run re-run later and failed keeps its id but starts again.
ordinary_pr
edit_fixture ci.yml.json '.workflow_runs += [.workflow_runs[0] | .id = 4 | .run_started_at = "2026-11-21T00:00:00Z" | .conclusion = "failure"]'
expect_tested 'reuse=false ordinary=true ' 'a re-run that failed later is not hidden by a newer id'
for change in '.status = "in_progress"' '.path = ".github/workflows/other.yml"' '.head_branch = "fork/x"' \
  '.head_repository.full_name = "fork/repo"' '.event = "push"' '.head_sha = "0000000000000000000000000000000000000000"'; do
  ordinary_pr
  edit_fixture ci.yml.json ".workflow_runs[0] |= ($change)"
  expect_tested 'reuse=false ordinary=true ' "run with $change is not evidence"
done
# No tested-tree artifact: a run whose suites skipped, or an expired record.
ordinary_pr
printf '{"artifacts":[]}\n' > "$case_dir/artifacts.json"
expect_tested 'reuse=false ordinary=true ' 'a run without a tree record runs again'
edit_fixture artifacts.json '.artifacts = [{name:"tested-tree",expired:true}]'
expect_tested 'reuse=false ordinary=true ' 'an expired tree record runs again'
ordinary_pr
edit_fixture prs.json '.[0].labels = [{name:"release"}]'
expect_tested 'reuse=false ordinary=false ' 'a release PR merge keeps the full matrix'
ordinary_pr
edit_fixture prs.json '.[0].head.ref = "release/v1.0.2"'
expect_tested 'reuse=false ordinary=false ' 'a release branch merge keeps the full matrix'
ordinary_pr
edit_fixture prs.json '. + .'
expect_tested 'reuse=false ordinary=false ' 'an ambiguous PR lookup keeps the full matrix'
# Lookups that fail after the merge is known to be ordinary run everything.
ordinary_pr
rm "$case_dir/prs.json"
expect_tested 'reuse=false ordinary=false ' 'a failed PR lookup keeps the full matrix'
ordinary_pr
: > "$case_dir/workflow-api-error"
expect_tested 'reuse=false ordinary=false ' 'a failed run lookup keeps the full matrix'
rm "$case_dir/workflow-api-error"
rm "$case_dir/artifacts.json"
expect_tested 'reuse=false ordinary=false ' 'a failed artifact lookup keeps the full matrix'
ordinary_pr
rm "$case_dir/evidence/tested-tree/tree"
expect_tested 'reuse=false ordinary=false ' 'a failed artifact download keeps the full matrix'
grep -Fq 'Tested-tree evidence unavailable' "$case_dir/tested.err" || fail 'a failed lookup is visible'
# Unreadable evidence is a failed lookup, not a valid mismatch.
ordinary_pr
edit_fixture prs.json '.[0].labels = null'
expect_tested 'reuse=false ordinary=false ' 'PR metadata without labels keeps the full matrix'
ordinary_pr
printf '{"workflow_runs":[42]}\n' > "$case_dir/ci.yml.json"
expect_tested 'reuse=false ordinary=false ' 'a malformed run entry keeps the full matrix'
ordinary_pr
printf '{"artifacts":[42]}\n' > "$case_dir/artifacts.json"
expect_tested 'reuse=false ordinary=false ' 'a malformed artifact entry keeps the full matrix'
ordinary_pr
printf '{"artifacts":[{"name":"tested-tree"}]}\n' > "$case_dir/artifacts.json"
expect_tested 'reuse=false ordinary=false ' 'an artifact without its expiry keeps the full matrix'
ordinary_pr
edit_fixture ci.yml.json '.workflow_runs[0] |= del(.conclusion)'
expect_tested 'reuse=false ordinary=false ' 'a run without its conclusion keeps the full matrix'
ordinary_pr
printf 'not json\n' > "$case_dir/ci.yml.json"
expect_tested 'reuse=false ordinary=false ' 'malformed run JSON keeps the full matrix'
ordinary_pr
printf '{"message":"rate limited"}\n' > "$case_dir/artifacts.json"
expect_tested 'reuse=false ordinary=false ' 'artifact JSON without a list keeps the full matrix'
ordinary_pr
printf 'not a tree\n' > "$case_dir/evidence/tested-tree/tree"
expect_tested 'reuse=false ordinary=false ' 'an unreadable tree record keeps the full matrix'
ordinary_pr
printf '%s\nextra\n' "$(git rev-parse "$merge^{tree}")" > "$case_dir/evidence/tested-tree/tree"
expect_tested 'reuse=false ordinary=false ' 'a tree record with extra lines keeps the full matrix'
ordinary_pr
(GITHUB_EVENT_NAME=pull_request; expect_tested 'reuse=false ordinary=false ' 'a pull request never reuses') || exit 1
(GITHUB_REF=refs/heads/other; expect_tested 'reuse=false ordinary=false ' 'a push to another branch never reuses') || exit 1
printf 'ok - main push reuses only a passed PR run that recorded the same tree\n'

export GITHUB_EVENT_NAME=schedule
# A nightly reuses the newest earlier nightly that ran the matrix itself (it
# holds a tested-tree record) when that one passed and nothing started later
# failed; a nightly that reused evidence records nothing.
nightly_run() { # $1 id, $2 start day, $3 conclusion, $4 recorded (true|false)
  jq -nc --arg sha "$merge" --argjson id "$1" --arg day "$2" --arg c "$3" \
    '{id:$id,head_sha:$sha,event:"schedule",path:".github/workflows/ci.yml",run_started_at:("2026-11-" + $day + "T00:00:00Z"),status:"completed",conclusion:$c}'
  if [ "$4" = true ]; then
    printf '{"artifacts":[{"name":"tested-tree","expired":false}]}\n' > "$case_dir/artifacts-$1.json"
  else
    printf '{"artifacts":[]}\n' > "$case_dir/artifacts-$1.json"
  fi
}
nightlies() { # rows from nightly_run, one page
  jq -s '[{workflow_runs:.}]' > "$case_dir/ci.yml.json"
}
{ nightly_run 8 20 success true; } | nightlies
expect_tested 'reuse=true ordinary=false ' 'an unchanged main skips the nightly run'
grep -Fxq 'source_run=8' "$case_dir/tested" || fail 'the nightly names the run that ran the matrix'
(GITHUB_RUN_ATTEMPT=2; export GITHUB_RUN_ATTEMPT; expect_tested 'reuse=false ordinary=false ' 'a re-run nightly runs everything') || exit 1
{ nightly_run 8 20 success true; nightly_run 7 21 success false; } | nightlies
expect_tested 'reuse=true ordinary=false ' 'a later reusing nightly passes on the same evidence'
# A passed, B reused it, then A was re-run and failed: A started last.
{ nightly_run 7 21 failure true; nightly_run 8 20 success false; } | nightlies
expect_tested 'reuse=false ordinary=false ' 'a re-run full nightly that failed runs again'
# B re-ran only a cheap job and passed; A, the newest full run, failed before.
{ nightly_run 7 21 failure true; nightly_run 8 22 success false; } | nightlies
expect_tested 'reuse=false ordinary=false ' 'a reusing nightly never stands in for a failed full run'
{ nightly_run 8 20 success true; nightly_run 10 21 failure false; } | nightlies
expect_tested 'reuse=false ordinary=false ' 'a later failed nightly at the same commit runs again'
{ nightly_run 4 19 failure true; nightly_run 8 20 success true; } | nightlies
expect_tested 'reuse=true ordinary=false ' 'an older failure before the green full nightly does not count'
{ nightly_run 8 20 success false; } | nightlies
expect_tested 'reuse=false ordinary=false ' 'a nightly without any full-matrix record runs'
{ nightly_run 9 20 success true; } | nightlies
expect_tested 'reuse=false ordinary=false ' 'its own run is never evidence'
for change in '.status = "in_progress"' '.event = "push"' \
  '.head_sha = "0000000000000000000000000000000000000000"' '.path = ".github/workflows/other.yml"'; do
  nightly_run 8 20 success true | jq -c "$change" | nightlies
  expect_tested 'reuse=false ordinary=false ' "nightly with $change runs"
done
{ nightly_run 8 20 success true; nightly_run 10 21 success true | jq -c 'del(.run_started_at) | .status = "queued"'; } | nightlies
expect_tested 'reuse=false ordinary=false ' 'a nightly without a start time runs'
for field in head_sha event path; do
  { nightly_run 8 20 success true; nightly_run 10 21 failure false | jq -c "del(.$field)"; } | nightlies
  expect_tested 'reuse=false ordinary=false ' "a newer nightly without $field runs"
done
{ nightly_run 8 20 success true; } | nightlies
printf '{"artifacts":{"x":{"name":"tested-tree","expired":false}}}\n' > "$case_dir/artifacts-8.json"
expect_tested 'reuse=false ordinary=false ' 'a nightly artifact list that is not an array runs'
{ nightly_run 8 20 success true; } | nightlies
printf '{"message":"error"}\n' > "$case_dir/artifacts-8.json"
expect_tested 'reuse=false ordinary=false ' 'an unreadable nightly record runs'
printf '{"workflow_runs":[42]}\n' > "$case_dir/ci.yml.json"
expect_tested 'reuse=false ordinary=false ' 'a malformed nightly entry runs'
: > "$case_dir/workflow-api-error"
expect_tested 'reuse=false ordinary=false ' 'a failed nightly lookup runs'
rm "$case_dir/workflow-api-error"
printf 'ok - a nightly run is skipped only after a green nightly at the same commit\n'

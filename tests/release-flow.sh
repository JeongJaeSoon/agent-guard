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

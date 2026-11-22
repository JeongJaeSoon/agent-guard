#!/bin/sh
# Synthetic fixtures for the nightly performance issue body, never benchmark evidence.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
script="$ROOT/.github/scripts/performance-issue-body.sh"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
render() {
  RUN_URL=https://example.invalid/run HEAD_SHA=synthetic-sha sh "$script" "$1" '- Packaged performance evidence: failure' \
    > "$case_dir/body" 2> "$case_dir/stderr"
}
has() { grep -Fxq -- "$1" "$case_dir/body" || fail "$2"; }
lacks() { if grep -Fq -- "$1" "$case_dir/body"; then fail "$2"; fi; }
row() { jq -nc --arg name "$1" --argjson lat "$2" --argjson cpu "$3" '{host:"claude",name:$name,latency_change_percent:$lat,cpu_change_percent:$cpu}'; }

# Evidence could not be downloaded at all: the issue still names what is missing.
render "$case_dir/absent"
has '러너 CPU(packaged job, cpuinfo.txt): artifact 없음' 'missing packaged artifact is named'
has '- artifact 없음' 'a missing instruction count artifact is named'
[ "$(grep -c -Fx -- '- artifact 없음' "$case_dir/body")" -eq 1 ] || fail 'the missing instruction count artifact is named once'
has 'nightly run: https://example.invalid/run' 'run link is kept'
has '확인된 회귀 행이 없습니다. 위 판정과 측정 도구 오류를 확인하세요. 행이 없다는 사실은 측정 성공의 근거가 아닙니다.' 'no rows never implies a completed measurement'
has '판정: 측정 미완료 또는 출력 검증 실패. 성능 기준 초과와 구별하며 릴리스를 막습니다.' 'missing evidence is a measurement failure'
[ "$(head -n 1 "$case_dir/body")" = '러너 CPU(packaged job, cpuinfo.txt): artifact 없음' ] || fail 'runner CPU is the first line'

evidence="$case_dir/evidence"
packaged="$evidence/packaged-performance"
other="$evidence/other-packaged"
mkdir -p "$packaged" "$other"
printf 'threshold_exceeded\n' > "$packaged/verdict.txt"
printf 'measurement timed out\n' > "$packaged/errors.txt"
printf 'processor\t: 0\nmodel name\t: Synthetic CPU A\nprocessor\t: 1\nmodel name\t: Synthetic CPU A\n' > "$packaged/cpuinfo.txt"
{
  row stall 10.34 -0.8; row boundary 7 2; row cpu-rose 9 2.01; row cpu-confirmed 3 8; row stall-cpu-fell 12 -24
} | jq -s '{complete:true,confirmed:.}' > "$packaged/legacy-confirmation.json"
jq -n '{complete:false,confirmed:[]}' > "$packaged/public-default-confirmation.json"
row cpu-missing 9 null | jq -s '{complete:true,confirmed:.}' > "$other/confirmation.json"
printf '{not json' > "$other/broken-confirmation.json"
mkdir -p "$evidence/instruction-count"
printf '%s\n' '### Shell instruction count against the latest release' '' '- base: 릴리스 태그 `v0.0.0`' \
  '판정: **실패**. synthetic' > "$evidence/instruction-count/summary.md"
render "$evidence"
has 'measurement timed out' 'measurement tool stderr is preserved verbatim'
has '셸 명령어 수(최근 릴리스 태그 대비, Shell instruction count job):' 'the instruction count has its own section'
has '- base: 릴리스 태그 `v0.0.0`' 'the instruction count summary is included'
has '판정: **실패**. synthetic' 'the instruction count verdict is included'
lacks '### Shell instruction count against the latest release' 'the summary heading is not repeated'

has '러너 CPU(packaged job, cpuinfo.txt): Synthetic CPU A' 'packaged CPU comes from cpuinfo.txt, once per model'
note='노이즈 의심(latency만 오름)'
cpu='Synthetic CPU A'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/stall | +10.3% | -0.8% | $note |" 'latency-only row is marked'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/boundary | +7% | +2% | $note |" 'CPU at +2% is still latency-only'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/stall-cpu-fell | +12% | -24% | $note |" 'falling CPU is latency-only'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/cpu-rose | +9% | +2% |  |" 'CPU above +2% is not marked'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/cpu-confirmed | +3% | +8% |  |" 'a CPU-confirmed row is not marked'
has "| packaged-performance | $cpu | public-default-confirmation.json | 확인 측정 불완전 | | | |" 'incomplete confirmation is reported'
has '| other-packaged | 읽지 못함 | confirmation.json | 읽을 수 없음 | | | |' 'a row without CPU time is unreadable'
has '| other-packaged | 읽지 못함 | broken-confirmation.json | 읽을 수 없음 | | | |' 'malformed confirmation is reported'
lacks 'claude/cpu-missing' 'a row without CPU time is never marked'
[ "$(grep -c "$note" "$case_dir/body")" -eq 3 ] || fail 'exactly the latency-only rows are marked'
has '| Artifact | 러너 CPU | 파일 | Host/case | Latency | CPU 시간 | 판단 |' 'table names the CPU time column'
[ "$(head -n 1 "$case_dir/body")" = '러너 CPU(packaged job, cpuinfo.txt): Synthetic CPU A' ] || fail 'runner CPU is the first line'
printf 'passed\n' > "$evidence/instruction-count/verdict.txt"
for pair in packaged-performance:101 instruction-count:102; do
  EVIDENCE_JOB_CONTEXT="{\"check_run_id\":${pair#*:}}" GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=synthetic-sha \
    sh "$ROOT/.github/scripts/write-performance-source.sh" "$evidence/${pair%:*}"
done
jq -n '[{jobs:[
  {id:1,name:"Packaged performance evidence",head_sha:"synthetic-sha",run_id:1,run_attempt:1,
   status:"completed",conclusion:"failure",check_run_url:"https://example.invalid/check-runs/101"},
  {id:2,name:"Shell instruction count against the latest release",head_sha:"synthetic-sha",run_id:1,run_attempt:1,
   status:"completed",conclusion:"success",check_run_url:"https://example.invalid/check-runs/102"}
]}]' > "$evidence/jobs.json"
render "$evidence"
has '판정: 측정 완료, 성능 기준 초과.' 'completed thresholds are distinct from failed measurement'
jq '.[0].jobs[0] |= (.run_attempt=2 | .conclusion="cancelled")' "$evidence/jobs.json" > "$case_dir/changed"
mv "$case_dir/changed" "$evidence/jobs.json"
render "$evidence"
has '판정: 측정 미완료 또는 출력 검증 실패. 성능 기준 초과와 구별하며 릴리스를 막습니다.' 'an older threshold artifact cannot hide a cancelled latest job'
has 'packaged-performance: evidence link job_cancelled' 'the issue names the failed evidence link'
printf 'ok - nightly performance issue body fixtures passed\n'

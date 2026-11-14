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
has '- artifact 없음' 'missing fused artifacts are named'
has 'nightly run: https://example.invalid/run' 'run link is kept'
has '확인된 회귀 행이 없습니다. 목표 미달, 출력 검증 실패, 측정 미완료나 미실행으로도 job이 실패합니다. run artifact를 확인하세요.' 'no rows means no table'
[ "$(head -n 1 "$case_dir/body")" = '러너 CPU(packaged job, cpuinfo.txt): artifact 없음' ] || fail 'runner CPU is the first line'

evidence="$case_dir/evidence"
packaged="$evidence/packaged-performance"
mkdir -p "$packaged" "$evidence/fused-packaged-official-off/evidence" \
  "$evidence/fused-packaged-homebrew-cold/evidence" "$evidence/fused-packaged-homebrew-warm/evidence" \
  "$evidence/fused-packaged-official-cold/evidence"
printf 'processor\t: 0\nmodel name\t: Synthetic CPU A\nprocessor\t: 1\nmodel name\t: Synthetic CPU A\n' > "$packaged/cpuinfo.txt"
printf 'Linux synthetic\njq-1.7\nmodel name\t: Synthetic CPU B\n' > "$evidence/fused-packaged-official-off/evidence/environment.txt"
printf 'model name\t: Synthetic CPU B\n' > "$evidence/fused-packaged-homebrew-cold/evidence/environment.txt"
printf 'model name\t: Synthetic CPU C\n' > "$evidence/fused-packaged-homebrew-warm/evidence/environment.txt"
printf 'Linux synthetic\n' > "$evidence/fused-packaged-official-cold/evidence/environment.txt"
{
  row stall 10.34 -0.8; row boundary 7 2; row cpu-rose 9 2.01; row cpu-confirmed 3 8; row stall-cpu-fell 12 -24
} | jq -s '{complete:true,confirmed:.}' > "$packaged/legacy-confirmation.json"
jq -n '{complete:false,confirmed:[]}' > "$packaged/public-default-confirmation.json"
row cpu-missing 9 null | jq -s '{complete:true,confirmed:.}' > "$evidence/fused-packaged-official-off/evidence/confirmation.json"
printf '{not json' > "$evidence/fused-packaged-homebrew-cold/evidence/confirmation.json"
{
  row fused-stall 6 1; row fused-cost 6 6
} | jq -s '{complete:true,confirmed:.}' > "$evidence/fused-packaged-homebrew-warm/evidence/confirmation.json"
render "$evidence"

has '러너 CPU(packaged job, cpuinfo.txt): Synthetic CPU A' 'packaged CPU comes from cpuinfo.txt, once per model'
has '- Synthetic CPU B: fused-packaged-homebrew-cold, fused-packaged-official-off' 'fused jobs on one CPU share a line'
has '- Synthetic CPU C: fused-packaged-homebrew-warm' 'each fused CPU is listed'
has '- 읽지 못함: fused-packaged-official-cold' 'an environment without a model name says so'
note='노이즈 의심(latency만 오름)'
cpu='Synthetic CPU A'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/stall | +10.3% | -0.8% | $note |" 'latency-only row is marked'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/boundary | +7% | +2% | $note |" 'CPU at +2% is still latency-only'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/stall-cpu-fell | +12% | -24% | $note |" 'falling CPU is latency-only'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/cpu-rose | +9% | +2% |  |" 'CPU above +2% is not marked'
has "| packaged-performance | $cpu | legacy-confirmation.json | claude/cpu-confirmed | +3% | +8% |  |" 'a CPU-confirmed row is not marked'
has "| packaged-performance | $cpu | public-default-confirmation.json | 확인 측정 불완전 | | | |" 'incomplete confirmation is reported'
has '| fused-packaged-official-off | Synthetic CPU B | confirmation.json | 읽을 수 없음 | | | |' 'a row without CPU time is unreadable'
has '| fused-packaged-homebrew-cold | Synthetic CPU B | confirmation.json | 읽을 수 없음 | | | |' 'malformed confirmation is reported'
has "| fused-packaged-homebrew-warm | Synthetic CPU C | confirmation.json | claude/fused-stall | +6% | +1% | $note |" 'a fused row carries its own CPU'
has '| fused-packaged-homebrew-warm | Synthetic CPU C | confirmation.json | claude/fused-cost | +6% | +6% |  |' 'a fused row with CPU cost is not marked'
lacks 'claude/cpu-missing' 'a row without CPU time is never marked'
[ "$(grep -c "$note" "$case_dir/body")" -eq 4 ] || fail 'exactly the latency-only rows are marked'
has '| Artifact | 러너 CPU | 파일 | Host/case | Latency | CPU 시간 | 판단 |' 'table names the CPU time column'
[ "$(head -n 1 "$case_dir/body")" = '러너 CPU(packaged job, cpuinfo.txt): Synthetic CPU A' ] || fail 'runner CPU is the first line'
printf 'ok - nightly performance issue body fixtures passed\n'

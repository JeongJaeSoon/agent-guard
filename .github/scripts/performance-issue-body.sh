#!/usr/bin/env sh
# Body of the nightly performance issue (performance.yml notify job).
# Usage: performance-issue-body.sh EVIDENCE_DIR FAILED_JOBS; reads RUN_URL and
# HEAD_SHA. EVIDENCE_DIR holds one directory per downloaded artifact and may be
# missing: a missing artifact must not suppress the issue.
set -u
evidence=$1
failed=$2
: "${RUN_URL:?}" "${HEAD_SHA:?}"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' 0
: > "$work/rows"

# Display only: a confirmed latency row whose CPU time rose at most this much
# matches the off-CPU stall shape #446 classified. Observed stalls moved CPU
# time by -5% to +0.6%; the real +4-6% cost moved it by +4% or more.
noise_cpu_limit=2

# packaged-performance keeps /proc/cpuinfo in cpuinfo.txt.
cpu_model() {
  if [ -f "$1/cpuinfo.txt" ]; then
    model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$1/cpuinfo.txt" | sort -u | paste -sd ';' -)
    printf '%s\n' "${model:-읽지 못함}"
    return
  fi
  printf '%s\n' '읽지 못함'
}

packaged_cpu='artifact 없음'
if [ -d "$evidence" ]; then
  for dir in "$evidence"/*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}
    artifact=${dir##*/}
    cpu=$(cpu_model "$dir")
    case "$artifact" in
      packaged-performance) packaged_cpu=$cpu ;;
    esac
    # Every measurement path writes bench/native/confirm.jq output to a
    # *confirmation.json file; its confirmed rows are the regressions.
    find "$dir" -name '*confirmation.json' | sort | while IFS= read -r file; do
      jq -r --arg artifact "$artifact" --arg cpu "$cpu" --arg file "${file##*/}" \
        --argjson limit "$noise_cpu_limit" '
        def pct: . * 10 | round / 10 + 0 | if . > 0 then "+\(.)" else "\(.)" end;
        # confirm.jq confirms latency or CPU above 5%, so a row under the CPU
        # limit rose in latency only. A row without CPU time fails in pct.
        (.confirmed[]
         | (if .cpu_change_percent <= $limit then "노이즈 의심(latency만 오름)" else "" end) as $note
         | "| \($artifact) | \($cpu) | \($file) | \(.host)/\(.name) | \(.latency_change_percent | pct)% | \(.cpu_change_percent | pct)% | \($note) |"),
        (select(.complete == false) | "| \($artifact) | \($cpu) | \($file) | 확인 측정 불완전 | | | |")
      ' "$file" || echo "| $artifact | $cpu | ${file##*/} | 읽을 수 없음 | | | |"
    done >> "$work/rows"
  done
fi

echo "러너 CPU(packaged job, cpuinfo.txt): $packaged_cpu"
echo
echo "nightly run: $RUN_URL"
echo "커밋: $HEAD_SHA"
echo
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
verdict=$(sh "$script_dir/performance-verdict.sh" "$evidence" "$HEAD_SHA" 2> "$work/verdict-errors")
cat "$work/verdict-errors" >&2
case "$verdict" in
  passed) echo '판정: 측정 완료, 기준 통과.' ;;
  threshold_exceeded) echo '판정: 측정 완료, 성능 기준 초과.' ;;
  *) echo '판정: 측정 미완료 또는 출력 검증 실패. 성능 기준 초과와 구별하며 릴리스를 막습니다.' ;;
esac
echo
echo '최신 job의 check·run·attempt·커밋 연결을 확인하지 못한 artifact는 현재 측정 증거로 인정하지 않습니다.'
echo
echo '측정 도구 오류(stderr 원문):'
echo
echo '```text'
cat "$work/verdict-errors"
for artifact in packaged-performance instruction-count; do
  if [ -s "$evidence/$artifact/errors.txt" ]; then
    cat "$evidence/$artifact/errors.txt"
  else
    printf '%s: 오류 artifact 없음 또는 stderr 없음\n' "$artifact"
  fi
done
echo '```'
echo
echo '통과하지 못한 job(최신 attempt):'
echo
printf '%s\n' "$failed"
echo
# The instruction-count job writes its own summary: base tag, table, verdict.
echo '셸 명령어 수(최근 릴리스 태그 대비, Shell instruction count job):'
echo
if [ -s "$evidence/instruction-count/summary.md" ]; then
  sed '1{/^### /d;}' "$evidence/instruction-count/summary.md"
else
  echo '- artifact 없음'
fi
echo
if [ -s "$work/rows" ]; then
  echo '새 21쌍 확인에서도 5%를 넘은 행(candidate 대 baseline 중앙값):'
  echo
  echo '| Artifact | 러너 CPU | 파일 | Host/case | Latency | CPU 시간 | 판단 |'
  echo '| --- | --- | --- | --- | --- | --- | --- |'
  cat "$work/rows"
  echo
  echo "노이즈 의심은 latency가 5%를 넘었지만 CPU 시간이 +${noise_cpu_limit}% 이하로 오른 행입니다. 공유 러너의 off-CPU 정지(#446)와 같은 모양입니다. sleep이나 I/O 대기처럼 CPU를 쓰지 않는 실제 회귀도 같은 모양이라 표시일 뿐이고, job 결론은 바뀌지 않습니다. artifact의 원시 표본을 함께 확인하세요."
else
  echo '확인된 회귀 행이 없습니다. 위 판정과 측정 도구 오류를 확인하세요. 행이 없다는 사실은 측정 성공의 근거가 아닙니다.'
fi

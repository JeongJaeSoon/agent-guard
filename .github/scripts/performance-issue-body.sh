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
: > "$work/cpus"
: > "$work/rows"

# Display only: a confirmed latency row whose CPU time rose at most this much
# matches the off-CPU stall shape #446 classified. Observed stalls moved CPU
# time by -5% to +0.6%; the real +4-6% cost moved it by +4% or more.
noise_cpu_limit=2

# packaged-performance keeps /proc/cpuinfo in cpuinfo.txt; fused artifacts
# append it to evidence/environment.txt.
cpu_model() {
  for file in "$1/cpuinfo.txt" "$1/evidence/environment.txt"; do
    [ -f "$file" ] || continue
    model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' "$file" | sort -u | paste -sd ';' -)
    printf '%s\n' "${model:-읽지 못함}"
    return
  done
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
      fused-packaged-*) printf '%s\t%s\n' "$cpu" "$artifact" >> "$work/cpus" ;;
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
echo 'fused job CPU(environment.txt):'
echo
if [ -s "$work/cpus" ]; then
  sort "$work/cpus" | awk -F '\t' '
    $1 != cpu { if (NR > 1) print line; cpu = $1; line = "- " $1 ": " $2; next }
    { line = line ", " $2 }
    END { print line }'
else
  echo '- artifact 없음'
fi
echo
echo "nightly run: $RUN_URL"
echo "커밋: $HEAD_SHA"
echo
echo '통과하지 못한 job(최신 attempt):'
echo
printf '%s\n' "$failed"
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
  echo '확인된 회귀 행이 없습니다. 목표 미달, 출력 검증 실패, 측정 미완료나 미실행으로도 job이 실패합니다. run artifact를 확인하세요.'
fi

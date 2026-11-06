# 공개7버전 boundary 경로 독립 실측

12개 job은 host2×audit2×input3이며, 서로 다른 VM/job의 표본을 합치지 않는다. 각 job 안에서 공개7기본+3.8.0/3.8.1 fused 9조건을 동일 scanner·정책·입력으로 Latin 순서9회, warmup1회 측정한다. 별도 endpoint는 .13default/.381default/.381fused 12회이며 독립 measurement로 보존한다. 각 실험은 단일/4동시를 포함한다.

실제 cgroup 2CPU·1GiB·swap0을 확인하지 못하면 측정하지 않는다. 공개 archive·checksum·bootstrap은 기존 release-lock으로 검증하고 비semver `payload` 경로에 공식 bootstrap 설치한다. 빌드·대체버전·재시도는 없다. 모든30초 timeout과 실패를 보존한다. 설치 준비 비용은 usage 결과에서 제외한다.

unknown은 FutureEvent/no-response payload를 `hook-post-tool`에 직접 전달한다. 실제 Claude/Codex dispatcher는 검증하지 않는다. missing-open/closed는 존재하지 않는 명시 scanner 경로로 각각 실제 정책 복귀를 검사한다. 공개 official scanner도 각 job 동일하게 다운로드·해시검증하지만 실패 입력에서는 의도적으로 실행 불가 경로를 사용한다.

경고 계약은 측정 전 plan에 고정한다. 배치마다 새 session_id, 같은 배치의4worker는 session 공유: open은 경고 JSON1개+빈stdout3개, 단일은경고1개, 각exit0이다. warmup/정규 동일하며 audit HOME·cache는 유지한다. closed는 worker모두exit2/빈stdout/closed사유, outer batchexit1을 정상 기대결과로 다룬다. unknown은 각exit0/빈stdout이다. stderr 원문·모든worker status·stdout/stderr/payload SHA객체를 보존한다.

이 경로의 latency/CPU/RSS/throughput은 boundary 처리 비용이며 성공한 마스킹의 성능 이득으로 세지 않는다. `performance_comparable`, `masking_work_comparison_eligible`, `elapsed_cpu_comparison_eligible`은 false다. 독립 boundary 비교는 정확도 통과 시만 허용한다. RSS 합은 이 실험에서 측정하지 않으므로 N/A다.

`base_runtime.py`의 `measure`는 원본 Linux도구와 AST/바이트 동일하다(`validation.json`). 단일과4동시는 같은 outer batch shell·status 수집 경로를 쓰며 그 고정 overhead를 포함한다. 이 프로토콜을 direct-single-path 다른 실험과 합치지 않는다. 원시 expected fail-closed returncode1은 숨기지 않으며 summary성공은 고정계약 충족 여부로 결정한다.

재현: 이 디렉터리를 `bench/results/public-release-comparison/ci-boundary`로 올리고 workflow를 `.github/workflows/public-seven-boundary.yml`에 배치한다. branch는 `bench/public-seven-boundary-comparison-20261106`이다. Docker에서 `BENCH_HOST`, `BENCH_AUDIT`, `BENCH_INPUT`을 지정하고 `/results`를 새 디렉터리에 마운트한다. 기존 samples가 있으면 거부한다. `samples.jsonl/CSV`, `summary.json/CSV`, `warmups.jsonl`, `errors.json`, `outputs/<sha>.txt`, 설치·환경·plan·manifest가 원시 근거다.

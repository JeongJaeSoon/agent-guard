# 공개 7버전 정책 고정 실측: 실행 도구 분할

이 프로토콜은 입력 5종 × agent host 2종 × audit 2종을 20개의 독립 job으로 분할합니다. 버전·입력·독립 기대값·scanner·세 정책 바이트·측정 함수·timeout 30초·워밍업 1회·series 9회·endpoint 12회·RSS profile 9회는 기존 7버전 도구와 동일합니다. 한 condition을 성공할 때까지 다시 실행하지 않습니다.

분할 사유는 실행 예산입니다. 초기 부분 표본 749개의 합계 wall 1369초를 바탕으로 단일 runner에서 전체 5976개 배치를 실행하면 기존 90분 job 예산을 크게 초과한다고 판단했습니다. 제품의 개선·회귀 결과로 표본이나 조건을 선택하지 않았으며 분할 계획을 실행 전에 고정했습니다. 기존 6버전 및 7버전 단일 job의 부분 자료·실패·중단 사유는 별도 보존하며 새 표본에 합치지 않습니다.

각 job 내부에서 같은 실제 host의 동일한 2 CPU·1 GiB·swap 0 조건으로 7개 기본 경로와 두 선택형 경로를 비교합니다. 1/4동시 요청, 주 series, 직접 endpoint 비교, 해당 입력의 RSS profile은 모두 같은 job에서 끝냅니다. 입력·host·audit를 바꾸면 다른 VM의 결과입니다. 이들 조건을 평균하여 전체 성능 수치를 만들거나 서로 다른 입력의 차이를 cache 인과관계로 설명하지 않습니다.

주 series의 각 버전·모드 조건은 9회 Latin 순환으로 각 실행 위치에 한 번씩 옵니다. endpoint-direct는 v3.6.13 기본/v3.8.1 기본/v3.8.1 fused를 12회 순환·역순으로 별도 실행합니다. RSS profile은 small-clean/many-replacements만 9회이며 시간·CPU·처리량은 성능 비교에서 제외합니다. 서로 다른 measurement 표본을 합치지 않습니다.

분할은 측정 함수 밖의 Cartesian iterator façade로만 입력·host·audit를 거릅니다. `timing_matrix`, `probe`, `batch_command`, `prepare`, `env_for` 등 기존 9개 함수의 AST가 동일한지 검증했습니다. `base_runtime.py`는 원본과 바이트가 같고 wait4 측정·독립 기대값 검사 함수도 그대로입니다. execution_host/partition_id는 원래 측정 구간이 끝나고 반환된 row에 덧붙입니다. 기존 단일 runner 도구는 `run.monolithic-measured-v1.py`로 함께 보존합니다.

bootstrap으로 실제 비semver `payload`에 설치하는 준비와 대표 native/fused strace probe도 그대로 유지합니다. 이는 독립 CLI 경로를 만들기 위한 준비이며 설치 비교를 다시 측정하는 job이 아닙니다. 설치 비용은 이미 완료된 7버전 설치 artifact의 294개 표본을 사용합니다. 그 설치 host와 이번 사용 성능 host를 연결하여 손익분기 횟수를 계산하지 않습니다.

repo 도구 경로는 `bench/results/public-release-comparison/ci-seven-partitioned/`, workflow는 `.github/workflows/public-seven-partitioned-comparison.yml`, 전용 branch는 `bench/public-seven-partitioned-comparison-20261106`입니다. 결과는 `bench/results/public-release-comparison/linux-seven-partitioned/<input--host--audit>/`에 저장합니다. 20개 job이 각 artifact를 업로드하고 collect job만 마지막에 한 번 commit/push합니다. 측정 종료 후 합성 증거에만 읽기 권한을 추가하며 runtime UID는 기존 root 조건을 유지합니다.

각 원시 row와 summary에는 protocol, execution_host, partition_id를 넣습니다. JSON/JSONL/CSV, exact stdout/stderr, 원시 trace, cgroup 환경 및 모든 실패를 보존합니다. trace의 `unfinished/resumed execve` 때문에 초기 단순 호출 카운터가 낮게 나올 수 있으므로, 원시 카운터를 바꾸지 않고 PID를 결합하는 별도 분석 결과로 경로를 보충 검증합니다. 재실행으로 해결하지 않습니다.

```sh
docker build -t guard-public-seven-partitioned bench/results/public-release-comparison/ci-seven-partitioned
mkdir -p results/small-clean--claude--off
docker run --rm --cpus=2 --memory=1g --memory-swap=1g --pids-limit=512 \
  -e AG_EXPERIMENT_EXECUTION_HOST="local-host:$(hostname)" \
  -v "$PWD/bench/results/public-release-comparison/ci-seven-partitioned:/experiment:ro" \
  -v "$PWD/results/small-clean--claude--off:/results" \
  guard-public-seven-partitioned --stage performance \
  --only-input small-clean --only-host claude --only-audit off
sudo chmod -R a+rX results/small-clean--claude--off
```

입력·host·audit는 `partition-plan.json`의 20조건에서 선택하고 매번 새 출력 폴더를 사용합니다. 기존 원시 자료를 덮어쓰지 않습니다.

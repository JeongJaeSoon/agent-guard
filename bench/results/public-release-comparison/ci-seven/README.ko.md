# 공개 7버전 정책 고정 비교 실험

이 프로토콜은 공개 v3.8.1의 실제 태그·릴리스·자산이 확인된 후 사전 고정한 별도 실험입니다. 초기 6개 공개 버전 cutoff로 실행한 실험을 재작성하거나 표본을 합치지 않습니다. `release-lock.json`의 7개 공개 archive·bootstrap·checksum과 공식 gitleaks 8.30.1을 검증하며 직접 빌드하지 않습니다.

저장소 도구 경로는 `bench/results/public-release-comparison/ci-seven/`, workflow는 `.github/workflows/public-seven-release-comparison.yml`, 전용 브랜치는 `bench/public-seven-release-comparison-20261106`입니다. 결과는 `bench/results/public-release-comparison/linux-seven/performance`와 `installation`에 분리됩니다.

성능 job과 설치 job은 서로 다른 실제 host입니다. 각 job 내부에서 CPU 2개·RAM 1 GiB·swap 0의 cgroup 실제 값을 확인합니다. 두 job의 설치 비용과 사용 지연을 합쳐 손익분기 횟수를 계산하지 않습니다. 컨테이너 측정 UID는 첫 6버전 실험과 동일한 root이며, 측정이 끝난 후 합성 증거 폴더에만 읽기 권한을 추가하여 artifact/git 수집을 보장합니다. 두 job은 독립 artifact를 저장하고 마지막 collect job이 한 번만 commit/push합니다.

주 실행 경로는 **정책 고정 기본 실행 경로**입니다. scanner와 v3.6.13의 gitleaks/deny-read/deny-bash 세 정책 바이트를 모든 버전에 같은 환경 변수로 지정합니다. 공개 package의 native helper 자동 선택 방식은 그대로 유지합니다. 실제 버전별 bundled 정책의 보안·오탐 차이는 별도 정확도 실험이며 이 성능 결과와 혼동하지 않습니다.

성능 준비 단계에서 각 공개 버전의 checksum 검증 bootstrap으로 별도 HOME의 `payload` 루트에 실제 설치합니다. archive와 설치된 CLI 해시를 비교합니다. 이 준비 비용은 주 CLI 지연에서 제외하며 원문과 해시를 보존합니다. `payload`는 semver 이름이 아니므로 독립 CLI 설치의 경로 분류를 따릅니다. 첫 6버전 도구가 사용한 `X.Y.Z` 디렉터리는 CLI의 `is_semver_dir`/`PLUGIN_CACHE_BASE` 분기 조건에 해당할 수 있습니다. 코드 조건과 별도 layout trace를 보존하고, 초기 실험에서 실제로 발생한 비용을 새 layout 보조 관측으로 대신 주장하지 않습니다.

주 series는 기본 7경로와 v3.8.0/v3.8.1 fused의 9개 조건입니다. 사전에 9회 Latin 순환 순서를 고정하여 모든 조건이 각 실행 위치에 한 번씩 옵니다. 각 입력·host·audit·동시성 조합에서 한 번 워밍업 후 9표본을 측정합니다. `cli` 표본에 서로 다른 입력을 임의 평균한 전체 개선율을 만들지 않습니다.

`endpoint-direct`는 v3.6.13 기본/v3.8.1 기본/v3.8.1 fused를 12회 순환·역순 직접 비교한 별도 데이터입니다. 주 series 표본과 합치지 않습니다. Claude/Codex, audit off/on-warm, 다섯 입력, 1/4동시를 동일하게 적용합니다. 4동시 지연은 배치 완료 시간이며 처리량은 4/배치 시간입니다.

`rss-profile`은 small-clean/many-replacements의 RSS 합을 별도 9회 측정합니다. 5ms 간격의 동일 프로세스 그룹 RSS 합이며 공유 페이지가 중복 계산될 수 있습니다. profile의 지연·CPU·처리량은 성능 비교에서 제외합니다. 주 CLI의 wait4 최대 자식 RSS와 RSS 합도 서로 다른 지표입니다.

각 measurement/version/mode/host/audit/input/concurrency 조건은 새 HOME을 생성합니다. 한 번 워밍업한 뒤 같은 HOME과 audit/cache 파일을 유지합니다. 입력·동시성·주 series·endpoint·profile 간 상태는 공유하지 않습니다. cache TTL 만료 가능성을 숨기지 않으며 최종 상태 파일과 해시를 저장합니다.

모든 경로는 주 측정 전에 32개 secret 문자열과 clean 문자열 하나의 대표 입력에서 별도 strace를 실행합니다. 출력 기대값과 실제 native prepare/redact 호출 여부를 확인합니다. native를 기대했는데 호출하지 않으면 fallback/미검증으로 그대로 기록합니다. 제품을 수정하거나 성공할 때까지 다시 실행하지 않습니다. fused는 검증한 공개 core를 명시적으로 선택하므로 자동 checksum 선택의 비용까지 달라질 수 있고, 순수 pipeline만의 인과 효과로 단정하지 않습니다.

설치 job은 7버전×14회 균형 순서로 archive 추출만, pinned bootstrap 새 설치, 같은 bootstrap 재적용을 나눕니다. 새 설치·재적용은 archive/checksum 네트워크와 검증·설정 비용을 포함하며 bootstrap script 사전 다운로드 및 의존성 최초 설치는 제외합니다. bootstrap script 다운로드는 별도 asset 원시 자료에 남습니다. 동적 latest bootstrap을 사용하는 CLI update 경로는 검증하지 않은 범위입니다.

전체 JSON/JSONL/CSV와 exact stdout/stderr, trace, cgroup 환경, 공개 자산 hash를 보존합니다. connector 제한을 위한 220KB 분할 파일과 chunk-index도 함께 생성합니다. 실패·timeout·기대값 불일치는 별도 errors와 원문으로 남기고 동일 작업의 성능 개선에 포함하지 않습니다. timeout은 30초로 고정하고 재시도하지 않습니다.

```sh
docker build -t guard-public-seven bench/results/public-release-comparison/ci-seven
mkdir -p results/performance
docker run --rm --cpus=2 --memory=1g --memory-swap=1g --pids-limit=512 \
  -v "$PWD/bench/results/public-release-comparison/ci-seven:/experiment:ro" \
  -v "$PWD/results/performance:/results" guard-public-seven --stage performance
sudo chmod -R a+rX results/performance
```

설치는 새 폴더를 사용하여 마지막 인자를 `--stage installation`으로 바꿔 별도 실행합니다. 원시 자료를 덮어쓰지 않습니다.

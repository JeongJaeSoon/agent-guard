# 공개 배포본 Linux 실측 도구

제품 코드를 수정하지 않는 일회성 비교 실험입니다. `release-lock.json`에 기록한 공개 배포본만 다운로드하며, 다운로드한 바이트의 SHA-256을 API digest 및 공개 checksum 파일과 비교합니다. v3.8.1은 잠금 시점에 공개 릴리스·태그가 없어서 N/A입니다. main을 대신 실행하지 않습니다.

저장소에서의 권장 배치:

- 이 폴더의 `Dockerfile`, `run.py`, `release-lock.json`: `bench/results/public-release-comparison/ci/`
- `workflow.yml`: `.github/workflows/public-release-comparison.yml`
- 워크플로가 동작하는 보고서 브랜치: `bench/public-release-comparison-20261106`

재현 명령:

```sh
docker build -t guard-public-comparison bench/results/public-release-comparison/ci
mkdir -p bench/results/public-release-comparison/linux
docker image inspect guard-public-comparison > bench/results/public-release-comparison/linux/image.json
docker run --rm --cpus=2 --memory=1g --memory-swap=1g --pids-limit=512 \
  -v "$PWD/bench/results/public-release-comparison/ci:/experiment:ro" \
  -v "$PWD/bench/results/public-release-comparison/linux:/results" \
  guard-public-comparison
```

`--memory-swap=1g`는 memory와 합산한 제한이므로 RAM 1 GiB와 같게 지정하면 추가 swap을 허용하지 않습니다. 도구가 컨테이너 내부 `cpu.max`, `memory.max`, `memory.swap.max`의 실제 값을 검사하며 다르면 측정을 시작하지 않습니다.

설치 측정은 의존성이 이미 설치된 이미지에서 수행합니다. 네트워크 단일 다운로드, 압축 해제만 수행한 비용, 공개된 버전의 bootstrap 새 설치/동일 installer 재적용 비용을 구분합니다. bootstrap script 자체는 검증 후 미리 다운로드하며 그 비용은 따로 기록합니다. fresh/refresh는 각 버전 12회 균형 반복입니다. 사용자의 실제 설치 또는 설정을 변경하지 않으며 매번 `/tmp`의 별도 HOME을 사용합니다. CLI의 `update`는 latest bootstrap을 동적으로 내려받으므로 이 도구에서는 고정 installer 재적용 경로와 혼동하지 않고 미검증으로 남깁니다.

audit `on-warm`은 각 버전/모드/host/audit/입력/동시성 조건별로 새 HOME을 생성하고, 한 번 워밍업한 뒤 같은 HOME과 audit/cache 상태를 14회 유지합니다. 입력·동시성 간 상태는 공유하지 않습니다. 별도 RSS profile은 별도 HOME에서 다시 워밍업합니다. TTL 만료 가능성 때문에 모든 cache lookup이 hit라는 주장은 하지 않으며 최종 audit/cache 파일과 해시를 보존합니다.

기본 CLI 경로는 공개 archive의 디렉터리 구조를 유지하여 배포본이 native helper를 자동 선택하도록 둡니다. v3.8.0 fused 경로는 공개 archive에 실제 모듈과 x86_64 Linux helper가 모두 있을 때만 실행합니다. native helper를 로컬에서 빌드하지 않습니다. 모든 버전은 동일한 공식 gitleaks 8.30.1 바이너리와 v3.6.13 scanner 설정 바이트를 사용합니다. 실제 Homebrew scanner 비교군 및 source-only Git 플러그인 경로와 결과를 합치지 않습니다.

주 CLI 계측은 14회 반복과 1회 워밍업, 조건 순환과 역순 실행을 사용합니다. 4동시 요청 지연은 배치 전체가 끝나는 시간이고 처리량은 4/배치 시간입니다. CPU는 배치 전체 user+system 시간, wait4 최대 RSS는 개별 자식 중 최대값입니다. RSS 합은 `small-clean`, `many-replacements` 입력을 별도 14회 profile로 측정합니다. 5ms 간격으로 동일 프로세스 그룹의 RSS를 더한 최대 표본값이며 공유 페이지가 중복 계산될 수 있습니다. 이 profile의 지연·CPU·처리량은 성능 비교에서 제외합니다. 다른 입력의 RSS 합은 N/A입니다. `strace`는 주 측정 이후 별도 실행하여 scanner/native/fused 실제 호출을 확인합니다.

`summary.json`은 원시 실패를 버리지 않고 전체 분포를 기록합니다. `failures>0`인 행은 동일 작업의 성능 개선으로 계산하면 안 됩니다. 성공·불일치 stdout/stderr 원문은 `outputs/<sha256>.txt`에 중복 제거하여 보존합니다. stderr도 보존하므로 timeout, scanner 실패, 기대값 불일치를 숨기지 않습니다.

이 도구를 작성한 macOS에서 Python 문법, Claude/Codex 출력 기대값 검사, 정상 출력 캡처, 고정 timeout 시 프로세스 그룹 종료를 검증했습니다. Linux/Docker 실측 성공 여부는 실제 CI 결과로 확인해야 합니다. 도구의 존재나 문법 검증만으로 실측 성공을 주장하지 않습니다.

원본 JSON/CSV 외에 `chunks/`의 220KB 이하 분할 파일과 `chunk-index.json`도 생성합니다. JSONL/CSV 조각은 숫자 순서로 연결하면 원본이 되고, JSON 조각은 배열 레코드를 이어 붙이면 원본 배열입니다. 원본도 함께 보존합니다.

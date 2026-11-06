# 공개 배포본 설치 비용 재현

이 문서는 설치 계측 절차의 원문이다. 제품 코드를 수정하지 않는다. 공개 버전의 `bootstrap.sh`, tarball 및 SHA256 파일은 `../evidence/releases/`의 공개 릴리스 증거에 따라 미리 확보한다. 공개 자산을 받지 못한 버전은 다른 버전으로 대체하지 않는다.

## 네트워크를 제외한 설치·업데이트·scanner 최초 설치

```sh
docker run --rm --network=none \
  -v /workspace:/workspace \
  agent-guard-public-bench:20261106 \
  python3 /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/measure_install.py \
  --lab /workspace/agent-guard-lab \
  --out /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation \
  --phase cached --rounds 9
```

`--out`과 작업 경로에 이전 실행 증거가 있으면 덮어쓰지 않는다. 재현은 새로운 `--out`, `--work` 경로를 사용한다. 로컬 Docker의 CPU/메모리 제한 옵션은 적용되지 않아 실제 4 CPU·16 GiB 환경으로 분류한다. CI는 별도의 작업에서 실제 cgroup 2 CPU·1 GiB·swap 금지를 검사한다. `--environment`에는 적용 여부가 검증된 환경 이름을 준다.

측정 전 고정한 순서는 `protocol-cached.json`에 있다. 각 조건은 버전당 warmup 1회 후 9회이며, 7버전의 회전 순서를 매 라운드 정방향/역방향으로 바꾼다. 성공 여부를 보고 재실행하지 않는다. 모든 시도는 raw JSON과 stdout/stderr를 남긴다. 각 설치/다운로드 프로세스 제한시간은 120초이며, 초과하면 프로세스 그룹을 종료하고 실패 표본으로 남긴다.

- `standalone-fresh-cached`: 빈 HOME에 공개 bootstrap으로 새로 설치한다. 공식 scanner, jq, git 등 의존성은 준비된 상태다. checksum 검증, 압축 해제/검증, 단계별 교체, dependency 진단, 기본 command wrapping용 shell 설정까지 포함한다.
- `standalone-update-cached`: 직전 비교 버전으로 사전 설치한 뒤 공개 CLI의 실제 `agent-guard update`를 계측한다. `AGENT_GUARD_VERSION`으로 target을 고정한다. v3.6.13은 이전 비교 대상이 없어 동일 버전 재설치이며, 직전 버전 업데이트와 같은 뜻으로 해석하지 않는다.
- `dependency-scanner-cached`: scanner가 없는 빈 HOME에서 공개 CLI의 실제 `setup --install --gitleaks-version 8.30.1 --gitleaks-checksum ...`을 계측한다. jq/git은 미리 설치되어 있다. 이 경로가 jq/git까지 자동 설치한다는 뜻은 아니다.

운송만 `curl` shim으로 고정 공개 파일의 로컬 복사로 치환한다. 공개 installer 내용은 그대로다. 따라서 이것은 다운로드를 포함한 전체 신규 설치 시간과 다르며, shim의 Python 실행 비용도 포함한다. 초기 bootstrap 자체를 받는 비용은 제외한다. bytes는 운송된 공개 자산의 크기이며 네트워크 실제 전송량과 혼동하지 않는다.

설치 전후 `.bashrc`의 기존 문자열, 외부 사용자 설정, 업데이트 시 payload 내 관련없는 파일의 보존을 검사한다. 이는 격리 HOME의 시험 결과이며 사용자의 모든 가능한 커스텀 설정을 보장하지 않는다.

## 실제 네트워크 다운로드

동일 하네스 `--phase network --rounds 9`는 실제 `curl -fsSL`로 고정 버전 tarball을 다운로드한다. 각 표본의 계측이 끝난 뒤 pinned 공개 자산과 SHA256을 대조한다. bootstrap, checksum 파일, OS 의존성의 다운로드는 이 조건에 포함하지 않는다. 세션 프록시/CDN 캐시 상태는 관측되지 않으며, 이를 전 세계 사용자의 콜드 다운로드 시간으로 일반화하지 않는다. TLS 검증은 유지한다.

CI 네트워크 측정과 로컬 설치 측정을 합산하지 않는다. 설치·사용 성능이 서로 다른 환경일 때 손익분기 횟수는 계산하지 않는다.

## 단위와 통계

`wall_s`는 CLI 프로세스 생성부터 종료까지의 `perf_counter` 시간이다. `cpu_s`는 `wait4`의 user+system CPU 시간으로, 설치 프로세스와 종료한 자식들의 CPU를 포함한다. `max_child_rss_kib`는 Linux `ru_maxrss`에 전파된 개별 프로세스 최대 RSS다. 동시 RSS 합과 같지 않다. 설치 크기는 설치 payload의 일반 파일 논리적 크기 합이며, 심볼릭 링크 중복과 파일시스템 할당량을 포함하지 않는다. `home_delta_bytes`는 이전 설치가 존재하는 상태에서 HOME 일반 파일 크기의 증가분이다.

집계는 warmup을 제외하고 성공·실패 수를 함께 보고한다. 중앙값, IQR(Q3−Q1), n을 사용한다. 지연/CPU/메모리/설치 bytes는 낮을수록 유리하며 개선 10% 이상과 회귀 5% 초과 기준은 사전에 고정한다.

## 실제 네트워크를 포함한 전체 신규 설치

```sh
docker run --rm \
  -v /workspace:/workspace \
  -v /etc/ssl/certs/ca-certificates.crt:/run/combined-ca.crt:ro \
  -e CURL_CA_BUNDLE=/run/combined-ca.crt \
  agent-guard-public-bench:20261106 \
  python3 /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/measure_install.py \
  --lab /workspace/agent-guard-lab \
  --out /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/full-network \
  --phase network --scenarios standalone-fresh-network --rounds 9
```

이 조건은 실제 `curl`로 공개 archive와 checksum을 받는다. `full-network/results-network.json`에 63표본을 보존했다. 매 표본에서 설치된 CLI의 hash를 해당 공개 payload와 독립 대조하고, bootstrap의 dependency 진단 로그도 별도로 검사했다. 7버전 각각 9표본이며 warmup은 0회로 고정했다. 초기 bootstrap 스크립트 자체는 사전에 검토한 로컬 공개 파일로 실행하므로 그 다운로드 비용은 포함하지 않는다. 기존 의존성도 이미 준비되어 있다. 이 결과를 신규 OS에 Homebrew·jq·git·scanner까지 처음 설치하는 전체 비용으로 표현하지 않는다.

`environment-local.json`은 실제 4 CPU·16 GiB 제한과 host swap 부재, jq 1.7.1, Git 2.39.5를 기록한다. 같은 이미지에는 rustc/cargo/gcc/clang/cc가 없고 이 상태에서 공개 package 설치가 성공했다. image digest는 `image-id-local.txt`에 있다.

회전+역순 순서는 시간 경과 편향을 줄이기 위해 사전에 고정했지만 완전히 위치 균형을 이루는 Latin-square는 아니다. `order-position-counts.json`에 각 버전·실행 위치의 횟수를 보존한다. 캐시/시간 영향이 완전히 제거되었다고 주장하지 않는다.

## 업데이트 및 사용자 설정 해석

cached updater의 `/latest/download/bootstrap.sh` 요청은 target 버전의 실제 공개 bootstrap 바이트에 고정된다. 각 릴리스 시점의 updater를 고정 재현하는 조건이며 오늘의 최신 bootstrap으로 임의의 과거 target을 설치하는 조건과 같지 않다. v3.6.13→v3.8.1 기능 검증은 현재 latest와 같은 target bootstrap을 사용한다.

`config-preservation.json`은 지원되는 standalone update에서 외부 `AGENT_GUARD_GITLEAKS_CONFIG` 파일과 기존 rc 내용을 보존했음을 검증한다. 반면 payload 안에서 직접 수정한 `config/gitleaks.toml`은 새 배포본의 기본 정책으로 바뀐다. 이를 모든 설정이 자동 보존된다는 뜻으로 확대 해석하지 않는다.

## Homebrew 기능 검증

실제 `brew install --force-bottle gitleaks`로 받은 scanner와 실제 `brew install`/`brew upgrade` 제품 경로를 검증했다. `/workspace/agent-guard-lab/homebrew`의 scanner는 원본 bottle을 Homebrew가 relocation한 그대로 보존하며, 수동 ELF 패치나 loader wrapper를 쓰지 않는다. 실제 ELF interpreter가 이 prefix를 참조하므로 사용 성능 측정 컨테이너에서는 같은 절대 경로에 prefix를 read-only로 mount해야 한다.

길이35자인 prefix에서 git/perl 의존성 bottle relocation이 실패했다. 이전 실패와 차단된 mirror 로그는 그대로 보존했다. 길이14자인 별도 격리 `/workspace/agb`에서는 정상 공개 bottle로 의존성 설치가 성공했고, 공개 formula 바이트를 그대로 pin한 endpoint 신규 설치 두 건과 v3.6.13→v3.8.1 `brew upgrade`가 성공했다. 구체적인 동작은 `measure_homebrew.py`, 원시는 `homebrew-functional/`에 있다. 각 조건1회 기능 검증이므로 설치 비용 비교는 N/A이며 n=9 이상 조건과 같은 그래프에서 개선율을 계산하지 않는다.

최초 Homebrew 자체 설치부터 모든 의존성을 포함한 cold installation 전체를 한 조건으로 9회 측정하지 않았다. 여러 준비 로그의 숫자를 합산해서 그 전체 비용을 만들지 않는다. 제품의 `agent-guard update`가 Homebrew 설치를 변경하지 않고 `brew upgrade JeongJaeSoon/tap/agent-guard`로 안내하는 것도 별도로 검증했다.

## Homebrew 비용 추가 실측(n=9)

초기 기능검증 자료는 그대로 보존한 뒤, 부모 작업 요청에 따라 별도 조건을 사전 고정해 최소표본을 보완했다. 각 endpoint fresh 조건은 warmup2회 후 9쌍 교대 반복, v3.6.13→v3.8.1 upgrade는 warmup2회 후 9회다. 원시는 `homebrew-measured/results-homebrew.json`, 사전 순서는 `homebrew-measured/protocol-homebrew.json`, 집계는 `aggregate-homebrew-measured.json`이다. 이 별도 비용 조건에 대해 앞 절의 n1/N/A 제한은 해소되며 원래 기능검증 시도의 수치는 그대로 둔다.

```sh
python3 /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/measure_homebrew.py \
  --lab /workspace/agent-guard-lab --prefix /workspace/agb \
  --out /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/homebrew-measured \
  --warmups 2 --rounds 9 --prepare-only
python3 /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/measure_homebrew.py \
  --lab /workspace/agent-guard-lab --prefix /workspace/agb \
  --out /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/homebrew-measured \
  --warmups 2 --rounds 9
```

이는 기존 Homebrew 사용자에게 의존성과 두 공개 archive가 이미 준비된 cached package-only 비용이다. `HOMEBREW_NO_AUTO_UPDATE=1`, analytics off, API 없는 고정 core tap, 공개 formula 원문 pin, 동일 prefix와 normal cleanup을 사용한다. 최초 Homebrew/의존성 설치, network 다운로드, 별도 shell integration은 포함하지 않는다. upgrade의 baseline seed 설치와 reset uninstall은 계측 밖이며 로그는 보존한다. `download_bytes`는 이 조건에서 캐시에 있는 공개 archive 크기이며 실제 네트워크 전송량이 아니다. 2 CPU·1 GiB CI와 다른 Linux host 4 CPU·16 GiB 환경이므로 표·그래프를 분리한다.

## 제한이 적용된 CI 설치 결과의 독립 집계

`ci-summary.json`과 `aggregate-ci.csv`는 실제 `cpu.max=200000 100000`, `memory.max=1073741824`, `memory.swap.max=0`을 확인한 CI의 273시도를 독립 집계한다. 원본 artifact 생성은 `42224583403`, 별도 compact export는 `42227732499`이며 export는 측정을 재실행하지 않았다. CI host의 `/proc/swaps`에는 swapfile이 보이지만 이 cgroup에는 swap이 금지되어 있다. 원본 artifact 만료는 `source-artifact.json`의 2026-12-06이며 공개 payload 반복 복사본의 전체 목록·hash·크기는 `work-file-manifest.csv`에 보존한다.

```sh
python3 /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation/summarize_ci_installation.py \
  --source /workspace/agent-guard-bench/bench/results/public-versions-20261106/evidence/ci/42227732499/extracted/public-version-installation-compact-linux \
  --out /workspace/agent-guard-bench/bench/results/public-versions-20261106/installation
```

CI network 원시 행의 `scope`에는 이전 하네스의 cached 설명 문자열이 잘못 남아 있다. 원문은 수정하지 않았으며 실제 `asset-network-download` 명령·SHA256·프로토콜을 기준으로 archive-only 실제 다운로드라는 파생 설명을 사용한다.

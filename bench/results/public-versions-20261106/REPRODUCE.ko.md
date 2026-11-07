# 재현 방법

이 파일의 상대 경로는 `JeongJaeSoon/agent-guard` 저장소 루트 기준이다. 공개 배포 파일과 source commit은 [manifest](evidence/releases/manifest.json)로 고정한다. 없거나 SHA가 다르면 실패하며 다른 버전으로 대체하지 않는다.

## 1. 실행 환경과 공개 파일

Docker가 실제 cgroup 자원을 제한할 수 있는 Linux x86_64 환경이 필요하다. 로컬 rootless daemon의 `CgroupDriver=none`에서는 옵션이 적용되지 않았으므로 주 결과를 그 환경으로 재현했다고 주장하면 안 된다. CI는 `ubuntu-24.04`, 컨테이너는 고정된 Python 3.12 Bookworm image를 사용한다. 실제 도구 버전·이미지 ID·CPU 모델·도구 SHA는 각 artifact의 `provision/`에 있다. apt와 Homebrew의 최초 준비 비용은 benchmark 인프라 준비이며 제품 설치 비용에 섞지 않는다.

```sh
sh bench/results/public-versions-20261106/runtime/ci.sh \
  /tmp/ag-public-lab /tmp/ag-public-evidence \
  agent-guard-public-bench:20261106 official claude controlled
```

`/tmp/ag-public-lab`과 `/tmp/ag-public-evidence`는 없던 새 경로여야 한다. 다른 구성은 scanner=`official`/`homebrew`, host=`claude`/`codex`다. 실제 Homebrew scanner가 없거나 bottle/version/hash가 맞지 않으면 N/A로 기록하고 공식 scanner로 몰래 대체하지 않는다. Homebrew는 정상 pour/relocation한 binary와 그 runtime prefix를 함께 사용한다.

측정 진입 시 다음 값이 모두 같아야 한다.

```text
cpu.max: 200000 100000
memory.max: 1073741824
memory.swap.max: 0
```

실행 전에 `policy-proof.json`의 14개 version/distribution 항목에 대해 gitleaks.toml, deny-read-paths.txt, deny-bash-patterns.txt 해시가 각각 한 종류인지 확인한다. deny-read는 기본 파일의 바이트가 같아 custom-policy 모드를 켜는 override를 추가하지 않는다. 나머지 두 정책은 v3.6.13 파일로 고정한다.

## 2. 성능·정확도·설치

[protocol.json](runtime/protocol.json)과 [공통 정책 보완 사유](runtime/common-policy-amendment.ko.md)를 읽는다. 7버전 14회 순환/역순, 3-arm 직접 비교 14회 교대, 4요청 wave와 RSS 16회 균형 배치, 구성당 warmup 2회, CLI timeout 30초를 사용한다. 모든 입력은 `correctness/make_workloads.py`에서 실행 전에 생성한다.

- `versions`: 공개 기본 redactor/pipeline 7버전.
- `direct`: v3.6.13 기본, v3.8.1 기본, v3.8.1 fused를 같은 입력에서 직접 교대.
- `optional`: 지원하는 v3.8.0/1 각각의 기본↔fused. 버전 간 값은 별도 블록의 중앙값 비율이다.
- `source`: 바이너리 없는 실제 tag source plugin의 endpoint 비교.
- `audit`: off 외에 warm/cold 상태를 endpoint·지정 입력에서 별도 검증.
- `load`: 요청 4개를 한 wave로 실행. throughput은 각 wave의 4/wall, CPU는 4요청 합계다.
- `rss`: 같은 VM 안 별도 표본 RSS 계측. sampler의 wall/CPU는 주 CLI 지표에서 제외한다.
- `trace`: 별도 프로세스 추적. 실제 생성과 실패한 clone/exec 시도는 `trace_attribution.py`로 구분한다.

정확도 재현은 [correctness/REPRODUCE.ko.md](correctness/REPRODUCE.ko.md), 설치 재현은 [installation/REPRODUCE.ko.md](installation/REPRODUCE.ko.md)를 따른다. 설치 timeout은 120초다. 새 HOME/XDG/prefix 안에서만 실행하여 기존 설치·설정을 보존한다. 공개 payload의 직접 수정 config는 업데이트에서 교체될 수 있으며 지원 외부 override와 구분한다.

## 3. 보존 자료 복원과 재집계

ZIP 없이도 HTML의 표·그래프·필터·데이터 다운로드는 작동한다. 원본 stdout/stderr·trace·입력까지 검토할 때는 `raw/`를 함께 내려받는다. raw 인덱스는 원본 artifact ID·SHA·만료일과 보존 ZIP의 모든 member SHA를 연결한다.

```sh
python3 bench/results/public-versions-20261106/analysis/restore_evidence.py \
  --raw bench/results/public-versions-20261106/raw \
  --base bench/results/public-versions-20261106
python3 bench/results/public-versions-20261106/analysis/restore_evidence.py \
  --raw bench/results/public-versions-20261106/raw \
  --base bench/results/public-versions-20261106 --execute
python3 bench/results/public-versions-20261106/analysis/assemble.py \
  --ci-roots \
    bench/results/public-versions-20261106/evidence/ci/42232755942/extracted \
    bench/results/public-versions-20261106/evidence/ci/42227732499/extracted \
  --out bench/results/public-versions-20261106/analysis \
  --runtime-policy common --require-complete \
  --ci-correctness bench/results/public-versions-20261106/correctness/ci-analysis.json \
  --local-install bench/results/public-versions-20261106/installation/results.json \
  --local-correctness bench/results/public-versions-20261106/correctness/local-correctness-analysis.json
python3 bench/results/public-versions-20261106/analysis/build_context.py
python3 bench/results/public-versions-20261106/report/generate.py \
  --runtime bench/results/public-versions-20261106/analysis/runtime.json \
  --metadata bench/results/public-versions-20261106/report/context.json \
  --installation bench/results/public-versions-20261106/analysis/installation.json \
  --installation-summary bench/results/public-versions-20261106/installation/summary.json \
  --correctness bench/results/public-versions-20261106/analysis/correctness.json \
  --correctness-summary bench/results/public-versions-20261106/analysis/supplementary-correctness.json \
  --out bench/results/public-versions-20261106/report
python3 bench/results/public-versions-20261106/analysis/gates.py
python3 bench/results/public-versions-20261106/analysis/plot_figures.py \
  --data bench/results/public-versions-20261106/report/data.json \
  --out bench/results/public-versions-20261106/report/figures
```

복원은 내용이 다른 기존 파일을 덮어쓰지 않는다. SHA 불일치, ZipSlip, symlink를 경유한 쓰기를 거부한다. Python·locale·font·plotting 버전도 그림 검증 JSON에 남긴다. 원시 측정값은 바꾸지 않고 표시와 집계만 재생성한다.

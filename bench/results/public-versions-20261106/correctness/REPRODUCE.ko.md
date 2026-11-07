# 정확도 재현

공개 자산 준비와 Docker image 빌드는 상위 `runtime/ci.sh` 및 고정 release
manifest를 따른다. 사용한 실제 public payload를 `/lab/releases/v*/payload`,
동일 scanner를 `/lab/scanners/official/gitleaks`에 둔다. 이 파일의 상대 경로는
컨테이너 기준이다. 출력 디렉터리는 매번 **새 이름**이어야 하며 기존 원시
자료를 덮어쓰지 않는다.

기본 32개 및 선택형 공유 core 정확도:

```sh
python /repo/bench/results/public-versions-20261106/correctness/run.py \
  --releases /lab/releases --scanner /lab/scanners/official/gitleaks \
  --scanner-name official --out /results/correctness/official-fixed-new \
  --variants default,fused --config-mode fixed --label YOUR_VERIFIED_ENVIRONMENT
```

각 배포 config 효과는 `--config-mode packaged`와 별도 출력 디렉터리로
비교한다. Homebrew는 실제 brew가 pour한 scanner와 ELF runtime prefix를
함께 mount하며, scanner 이름과 SHA를 별도 유지한다.

기존 1,013건 core corpus, 13개 scanner config 사례, 20개 실패 복귀:

```sh
python /repo/bench/results/public-versions-20261106/correctness/existing_corpus.py \
  --repo /repo --releases /lab/releases --out /results/correctness/core-new
python /repo/bench/results/public-versions-20261106/correctness/scanner_config.py \
  --releases /lab/releases --scanner /lab/scanners/official/gitleaks \
  --scanner-name official --out /results/correctness/config-new
python /repo/bench/results/public-versions-20261106/correctness/fallback.py \
  --releases /lab/releases --scanner /lab/scanners/official/gitleaks \
  --scanner-name official --out /results/correctness/fallback-new
python /repo/bench/results/public-versions-20261106/correctness/large_output.py \
  --releases /lab/releases --scanner /lab/scanners/official/gitleaks \
  --out /results/correctness/large-output-new
```

별도 printenv 및 masked-token 정확도는 `run.py`의 `--suite compatibility`,
`--suite masked-token`을 각각 쓴다. 원래 기본 32개 입력과 분리되며, 보조
실행의 elapsed 진단값을 주 성능 표본으로 세지 않는다. masked-token은
`masked-token-protocol.json`의 입력·기대값을 먼저 확인한다.

로컬 printenv 보조는 이미지 `/usr/bin/jq`(1.6)를 가리키는 새 PATH shim을
만들어 실행했고, masked-token은 `/usr/local/bin/jq`(1.7.1) 기본 PATH를
썼다. Docker에 요청한 `--cpus=2 --memory=1g --memory-swap=1g`는 이 rootless
환경에서 적용되지 않았다. 실제 outer 4 CPU/16 GiB·host swap 없음의 보조
환경으로 표시했다. CI 2 CPU/1 GiB 결과는 cgroup의 실제 세 값이
`200000 100000`, `1073741824`, `0`인지 확인한 별도 결과다.

모든 case는 hard runner timeout 30초다. 내부 scanner 준비 2초 실패를
그 제한을 바꾸거나 성공할 때까지 반복해 처리하지 않는다. 완료 표본의
stdin·stdout·stderr·hash·판정과 실패 원본을 보존한다.

`local-correctness-analysis.json` 및 CSV는 원시 `results.json`에 추가한
분석 열이다. V1 snapshot-control의 두 잘못된 기대값에는
`oracle_invalid=true`를 달아 제품 정확도 집계에서 제외했으며, 원본 판정과
입력·출력을 수정하지 않았다. 사례별 변경 이유는 `measurement-notes.ko.md`에
있다. `unknown-event-inspection.json` 및 `unknown-event.ko.md`는 실제 host
lifecycle event 미검증과 unknown tool pass-through의 차이를 설명한다.

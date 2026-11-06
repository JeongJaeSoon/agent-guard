# 인접 공개 버전 업데이트 비용 보조 실험

`run_updates.py`는 실제 공개 3.6.13→3.6.14→3.6.15→3.7.0→3.7.1→3.8.0→3.8.1의
여섯 인접 업데이트를 쌍별 12회 측정하고, 별도 12회 연속 chain과 12회 단번 endpoint 업데이트도 측정한다. 최초 조회 후 3.8.1이 실제 공개되어
새 7버전 lock으로 독립 실험한다. 이전 5쌍 결과를 지우거나 새 표본과 합치지 않는다.
`release-lock.json`은 정확한 커밋 및 공개 자산 digest/크기를 고정한다.

제품 코드는 수정하지 않는다. 공개 `bootstrap.sh` 자체를 매 표본 실제 다운로드하고
고정 digest를 검증한 뒤, 문서의 pin 가능한 bootstrap 경로에 동일한 기존 설치
목적지를 전달한다. latest 기반 `agent-guard update`를 다른 버전으로 몰래 바꾸거나
제품 코드를 패치한 실험이 아니다. bootstrap은 공개 archive와 checksum을 내려받아
자체 검증한다. bootstrap digest는 실험 도구가 매 표본 독립 확인한다. 반복 설치의
archive bytes는 bootstrap이 그때 내려받은 공개 sidecar와 검증하며, 다운로드의
패킷/TLS bytes 또는 서버 전송량을 추적한 것은 아니다.

매 표본 이전 버전 설치는 준비 단계로 실행하며 stdout/stderr·진단 계측을 별도로
보존한다. 이 준비 시간·scanner 최초 준비·시스템 의존성 최초 설치는 업데이트
결과에서 제외한다. 측정 구간은 bootstrap 다운로드·해시 검증·프로세스 시작·archive와
checksum 다운로드·압축 해제·staging·버전 검사·의존성 검사·shell setup을 포함한다.
bootstrap lock 독립 해시 검증의 비용도 포함되므로 일반 사용자 bootstrap 실행과
완전히 같은 계측 없는 절대 설치 시간이라고 표현하지 않는다. 네트워크 조건은
통제하지 않았으며 설치 결과와 다른 host 사용 성능으로 손익분기를 계산하지 않는다.

조건은 실제 cgroup 2 CPU·1 GiB·swap0이며 값이 다르면 실패한다. cc/gcc/clang/
rustc/cargo가 없음을 확인하며 하나라도 있으면 실패한다. scanner는 고정 공식
8.30.1 bytes다. 12개 실행 블록은 사전 고정한 회전/역순 회전을 사용하며, 6개 쌍이
각 실행 위치를 정확히 2회씩 차지한다. 네트워크 warmup은 하지 않는다. timeout120초,
재시도0을 고정하고 모든 실패를 보존한다. 지연·CPU·RSS는 낮을수록 유리하다.
wait4 RSS는 Linux 최대 개별 자식 RSS KiB이며 RSS 합·PSS·고유 물리 메모리가 아니다.

보존 검사는 기존 rc prefix, payload 내 제품과 무관한 파일과 사용자 추가 config,
외부 custom config, 기존 public symlink를 확인한다. 공개 문서의 unrelated local
files 보존 정책에 대응하는 관찰이다. **배포본이 소유한 canonical config를 변경해
넣지 않으며**, 그것이 새 배포본 bytes로 교체되는 것을 사용자 설정 유실 회귀로
판정하지 않는다. 사용자 추가 파일 보존 여부는 별도 필드로 제시한다. 지원 보존
계약이 확인되지 않은 다른 임의 위치까지 일반화하지 않는다. `rc_byte_unchanged`는
진단 항목이며, 제품이 관리하는 block이 정당하게 갱신되더라도 기존 prefix가
보존되면 rc 보존 검사는 성공할 수 있다.

원시 `updates.jsonl`/`updates.json`/`updates.csv`, `summary.json`, `plan.json`,
`environment.json`, `scanner.json`, `preparation.jsonl`, `errors.json`, 각 실행의
stdout/stderr와 보존 검사 전후 내용이 `/results-update`에 저장된다. 실패하면 추가로
실패 payload의 path/size/hash/symlink manifest 및 관련 text 파일을 남긴다.
통계는 성공·정확도 검사를 통과한 표본 수와 전체 시도·실패 수를 구분한다.

실행 workflow는 독립 branch `bench/public-seven-release-update-cost-20261106`의
`bench/results/public-release-comparison/seven-update-ci/**` 변경에만 반응한다. 원래 실행을
재실행하지 않는다. 기존 `ci/Dockerfile`을 재사용하며 runner UID/GID로 Docker를
실행해 artifact 권한을 보존하고 실패 때에도 artifact를 업로드한다.

## 이전 실행과의 분리 및 설치 크기 해석

초기 5쌍 CI는 immutable commit `1216e32`의 원시 자료로 보존한다. 새 6쌍
실험의 실제 Linux host/kernel 및 Docker image ID는 다시 저장한다. 같은 Dockerfile과
cgroup 제한을 썼다는 이유로 서로 다른 runner의 표본을 하나의 동일 host 측정으로
합치지 않는다. 모든 7개 버전을 새 실행 안에서 비교한 결과를 우선한다.

`fresh-old-adjacent` cohort의 각 쌍은 **fresh 구버전 설치를 준비한 뒤 한 번 업그레이드**한 비용이다. 초기 5쌍
결과에서 .14→.15의 업데이트 후 설치 크기와 fresh .15 설치의 크기가 달랐다.
bootstrap이 unrelated files를 보존하면서 구형 payload의 잔여 파일이 남을 수
있기 때문이다. 쌍별 `installed_bytes_increment`를 합산하여 .13부터 .381까지
연속 업데이트한 누적 설치 크기인 것처럼 표현하지 않는다. 따라서 새 도구는 `sequential-chain` cohort를 별도로 실행한다. 같은 .13 payload에서
.14→.15→.7.0→.7.1→.8.0→.8.1의 여섯 step을 실제 적용하고 각 step의 직접 설치크기와
최초 payload 대비 실제 증가분을 기록한다. `direct-endpoint` cohort는 fresh .13에서
바로 .381로 업데이트한 별도 12회다. 세 cohort 표본/통계를 섞지 않는다.

전체 12개 블록 안에서 세 cohort의 순서를 회전/역순 회전으로 교차 배치한다.
chain 내부 버전 순서는 의존 관계상 고정된다. 각 step 전후 파일 manifest를 계측 구간
밖에서 해시하고, 추가·삭제·변경된 파일의 path/size/hash를 보존한다. 성공한 chain의
최종 설치 크기는 직접 관측하며 개선율이나 fresh-old 쌍의 증가분을 합산하지 않는다.
`chain-summary.json`의 지연/CPU 합은 실제 연속 step의 절대 비용을 더한 것으로,
step 사이 manifest·보존검사 도구 비용은 제외한다. 이는 일반적인 하나의 updater
프로세스 실행 시간과 같다고 표현하지 않는다. 원시 각 step 결과도 유지한다.

전체 예정 표본은 fresh-old 72회 + chain step 72회 + 직접 endpoint 12회 =
156회 업그레이드이며, 구버전 준비 96회는 별도로 기록한다. 실패한 chain은 그 지점에서
중단하고 이후 step은 누락/N/A로 유지한다. 실패를 성공할 때까지 다시 실행하지 않는다.
루프 종료 시 JSONL/CSV를 180KB 미만 line-boundary 청크로 나누어 원본 SHA-256 및
재조립 안내와 함께 `chunk-index.json`에 기록한다. 모든 원래 파일도 그대로 보존한다.

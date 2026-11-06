# 인접 공개 버전 업데이트 비용 보조 실험

`run_updates.py`는 실제 공개 3.6.13→3.6.14→3.6.15→3.7.0→3.7.1→3.8.0의
다섯 인접 업데이트를 쌍별 12회 측정한다. 공개되지 않은 3.8.1은 대체하지 않는다.
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
8.30.1 bytes다. 12개 실행 블록은 사전 고정한 회전/역순 회전을 사용하며, 각 쌍의
각 실행 위치 횟수 차이는 최대 1회다. 네트워크 warmup은 하지 않는다. timeout120초,
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

실행 workflow는 독립 branch `bench/public-release-update-cost-20261106`의
`bench/results/public-release-comparison/update-ci/**` 변경에만 반응한다. 원래 실행을
재실행하지 않는다. 기존 `ci/Dockerfile`을 재사용하며 runner UID/GID로 Docker를
실행해 artifact 권한을 보존하고 실패 때에도 artifact를 업로드한다.

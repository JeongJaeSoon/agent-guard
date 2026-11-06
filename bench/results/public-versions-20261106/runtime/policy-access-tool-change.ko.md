# 정책 파일 접근 보조 검증의 실행 환경 수정

목적은 주 성능 조건에서 배포 기본 deny 정책 파일을 실제로 읽는지 확인하는 것이다. 이 실행은 syscall 추적이 붙은 n=1 보조 검증이며 지연·CPU·처리량 성능 표본으로 사용하지 않는다. 제품 코드, 공개 payload, 기대값과 30초 timeout은 변경하지 않았다.

첫 실행 `policy-access-local/`은 기본 실행 샌드박스가 ptrace를 금지하여 24개 호출 모두 실제 CLI 시작 전에 실패했다. 원문 stderr는 `PTRACE_TRACEME: Operation not permitted`, `PTRACE_SETOPTIONS: Operation not permitted`이며 trace는 0 byte다. 해당 디렉터리의 stdout/stderr/status/trace와 completion을 그대로 보존한다. 이 24회는 도구 인프라 실패로 분류하며 제품 정확도 실패·성능 실패·정책 미참조 증거에 포함하지 않는다.

다음 실행 `policy-access-local-ptrace-enabled/`은 이미 승인된 합성 자식 프로세스의 추적에 필요한 샌드박스 예외를 적용했다. strace가 생성하는 자식 CLI만 추적하며 기존 사용자 설치·설정은 바꾸지 않는다. 실행 도구 권한만 바로잡은 별도 검증이고, 실패한 조건을 성공할 때까지 반복한 성능 표본 수집이 아니다. 원래 실패 자료는 원래 경로에 남겼다. 이 경로는 로컬 실제 4 CPU·16GiB이며 요청한2 CPU·1GiB·swap0 조건으로 표현하지 않는다.

권한 허용 후 실제 trace에서 `hook_dependencies_ready`의 `policy_file_has_active_rule` 때문에 post-tool 정상 입력에서도 deny-read/deny-bash 정책을 열고 첫 active rule까지 읽는 것을 관측했다. 기본 주 성능 실험은 scanner 설정만 v3.6.13으로 고정했고 deny 정책은 공개 버전의 기본값을 유지했으므로, 모든 정책 파일 바이트가 동일하다는 주장은 성립하지 않는다. 활성 rule 유무 준비 검사와 실제 deny-bash 정규식 매칭은 구분한다. 관측하지 않은 경로와 시간 인과 기여율로 일반화하지 않는다.

권한 허용 실행의 초기 small-clean 두 조건은 full read syscall 추적을 단 상태에서30초 timeout으로 끝났다. stdout/stderr/status/trace를 그대로 보존하고 동일 조건을 다시 실행하지 않았다. 이 결과도 추적 없는 주 CLI 결과를 대체하거나 제품 성능 회귀로 해석하지 않는다. 추적된 호출에서 수행된 파일 접근까지만 증거로 사용한다.

부모가 정책 미참조 가정이 기각된 이후 추가24조건 완주의 실익이 낮다고 판단하여 권한 허용 추적을 중단하도록 지시했다. 완료12조건의 stdout/stderr/status/trace를 보존했고, 다음 escaped-control baseline 조건은 시작 후 중단되어 stdin·invocation·부분 trace만 남아 있다. 미완료 조건의 stdout/stderr 결과는 추정하지 않는다. `policy-access-local-ptrace-enabled/partial-completion.json`에 완료/미완료 조건과 중단 이유를 기록했다. 이 과정은 주 실측의 조건별 n을 대체하지 않는다.

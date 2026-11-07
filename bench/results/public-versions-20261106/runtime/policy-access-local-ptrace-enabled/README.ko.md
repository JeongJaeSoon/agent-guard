# 기본 정책 파일 접근 확인: 부분 보조 검증

이 결과는 local actual4CPU/16GiB에서 n=1 syscall trace이며 성능 비교가 아니다. 초기 sandbox ptrace 실패24회는 도구 실패이고 CLI가 실행되지 않았다. 권한 허용 추적은12조건을 마친 뒤 부모 지시로 중단했다. 다음 조건의 부분 trace도 보존했다. 완료12조건 모두 deny-bash와 deny-read 파일을 성공적으로 열고 읽었다.

|입력|버전|경로|종료 상태|deny-bash open|관측 read byte|deny-read open|관측 read byte|
|---|---|---|---:|---:|---:|---:|---:|
|long-line|v3.6.13|default|-9|1|209|1|80|
|long-line|v3.8.1|default|-9|1|235|1|80|
|long-line|v3.8.1|fused|-9|1|235|1|80|
|long-multiline|v3.6.13|default|-9|1|209|1|80|
|long-multiline|v3.8.1|default|0|1|235|1|80|
|long-multiline|v3.8.1|fused|0|1|235|1|80|
|many-replacement-leaves|v3.6.13|default|0|1|209|1|80|
|many-replacement-leaves|v3.8.1|default|0|1|235|1|80|
|many-replacement-leaves|v3.8.1|fused|0|1|235|1|80|
|small-clean|v3.6.13|default|-9|1|209|1|80|
|small-clean|v3.8.1|default|-9|1|235|1|80|
|small-clean|v3.8.1|fused|0|1|235|1|80|

`hook_dependencies_ready`는 정상 post-tool 입력에서도 `policy_file_has_active_rule`을 호출한다. trace에서는 deny-bash 첫 active rule까지 v3.6.13의209byte, v3.8.1의235byte가 읽혔다. 따라서 파일을 전혀 참조하지 않는다는 가정은 기각된다. 이 준비 검사는 실제 Bash 명령에 대한 전체 deny 정규식 매칭과 구분한다. first-active rule이 존재하는지 확인한 것만으로 새 정규식의 보안/오탐 효과나 전체 지연 기여를 입증하지 않는다.

공개 config 파일을 전수 해시한 결과 v3.6.13~v3.8.0은 동일하고 v3.8.1에서 `gitleaks.toml`과 `deny-bash-patterns.txt`가 달랐다. deny-read는 동일했다. 기존 주 성능 cohort는 scanner config만 v3.6.13으로 고정하고 deny-bash는 각 공개 배포 기본 파일을 유지했으므로 모든 정책 파일 바이트가 동일하다고 표현하지 않는다.

full read syscall trace가 붙은 상태에서6조건이30초 timeout(-9)으로 종료됐다. timeout을 늘리거나 해당 조건을 다시 실행하지 않았다. 이6건은 추적 없는 주 성능 결과를 덮어쓰거나 제품 회귀로 계산하지 않는다. 민감 stdout 원문이 아니라 file-access 여부를 검증하는 이 보조 실험에서는 종료 이전에 관측한 open/read까지만 사실로 사용한다.

[정책 파일 전체 해시](public-policy-files.json) · [완료/중단·원시 결과 목록](partial-completion.json) · [보조 프로토콜](protocol.json) · [실제 환경](environment.json) · [도구 변경/실패 보존 이유](../policy-access-tool-change.ko.md)


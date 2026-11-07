# 프로세스 trace 보조 계측

이 자료는 strace가 붙은 별도 phase=trace이며, 주 CLI wall/CPU 표와 섞지 않는다. `successful_execs`는 성공한 exec만, `failed_exec_attempts`는 PATH 탐색 실패 등을 별도로 센다. 프로세스 생성도 clone3 미지원·실패를 실제 생성으로 세지 않는다. 같은 프로세스의 재exec는 새 프로세스 생성이 아니다.

`scanner-readiness-version`은 실제 gitleaks version 실행, `scanner-stdin-execution`은 실제 stdin 스캔, `native-json-framing-prepare`와 `native-literal-replacement`는 실제 helper의 명령 인자로 구분한다. jq와 awk는 필터/코드가 strace 기본 문자열 상한으로 잘릴 수 있으므로 JSON 파싱·치환·framing의 정확한 세부 시간으로 분해하지 않는다. 이 분류로 shell 정책 비용 전체를 Rust 효과라고 부를 수 없다.

`exec_to_exit_wall_sum_s`는 성공한 exec 시점부터 프로세스 종료까지의 관측 경과시간을 역할별로 합한 참고값이다. CPU 시간이 아니며 자식 대기·스케줄링·strace overhead가 포함된다. 여러 프로세스가 겹치므로 합이 전체 지연보다 커질 수 있다. 역할별 인과 기여율이나 전체 시간의 분할로 해석하지 않는다. 마지막 exec만 수명을 귀속하므로 재exec 전 구간은 별도 귀속되지 않는다. strace -qq가 종료 메시지를 생략하므로 exit/exit_group syscall도 읽으며, CLONE_THREAD의 종료는 thread leader에 연결한다. 실패나 출력 불일치가 있는 sample도 success=false와 함께 보존한다.

재현: `python runtime/trace_attribution.py --runtime <run.py output dir> --out <new output dir>`

# 첫 CI 실행의 자료 내보내기 실패와 수정

2026-11-06의 첫 주 실험(`42223034457`, head `53480b49cc0253e41f7d37e0f1e171315e2162f6`)에서 `correctness (homebrew, fixed)` 실험 단계는 완료했으나 artifact 업로드가 실패했다. 컨테이너 UID 1000이 만든 보안 상태 디렉터리의 모드는 0700이고, GitHub runner 계정의 UID가 달라 업로더가 `warnings` 하위 디렉터리를 읽지 못했다. 오류는 `EACCES: permission denied, scandir`다.

원래 측정 결과를 성공할 때까지 재시도한 것이 아니다. 결과 내보내기의 인프라 오류를 수정한 후 **별도 head의 전체 프로토콜**을 다시 실행한다. 타이밍, CPU/RSS 계측, 입력, scanner, 기대값, timeout, 표본 수를 이 수정 때문에 바꾸지 않는다. 변경은 계측 밖의 다음 동작이다.

- `ci.sh`의 종료 trap이 합성 증거 디렉터리의 소유권을 runner 계정으로 반환한다.
- 두 워크플로에 `if: always()` 소유권 반환 단계를 업로드 바로 앞에 추가한다.
- 합성 HOME의 `.bashrc`, `.config` 등 보존 검증 자료도 빠지지 않도록 artifact에 숨김 파일을 포함한다.
- cgroup의 실제 세 값은 파일과 stdout에 동시에 보존한다.
- 자동 `synchronize`와 라벨 이벤트가 중복 대형 실행을 만들지 않도록 PR 실행은 명시적 `labeled` 이벤트만 받는다. 수동 dispatch도 유지한다.

첫 주 실험과 첫 RSS 보충 실험(`42223821896`, head `e211611d983b0f1b9e7f26260181f8c7d9fedfab`), 같은 이전 head의 중복 대기 실행들은 상태·실패 로그·취소 사유를 보존한 뒤 취소한다. 이전 실행의 선택 가능한 속도 숫자를 최종 성능 표본에 섞지 않는다. 업로드되지 않은 stdout/stderr·JSON의 일부는 runner 종료로 유실되었으므로 완전 복구했다고 주장하지 않는다. 회수 가능한 GitHub 로그와 annotation은 `evidence/ci/`에 남긴다.

소유권 수정은 공개 배포본이나 제품의 보안 디렉터리 생성 정책을 바꾸지 않는다. 격리된 실험 산출물의 계측 이후 내보내기에만 적용한다.

# 출력 준비 Rust 실험 원본

- `81ef728/local`: 실제 공개 v3.7.0과 초기 후보의 7쌍 CLI 비교, 9쌍 준비 단계 비교 및 별도 진단. 로컬 상위 제한은 4 CPU/16 GiB이며 개별 컨테이너 제한이 아니다.
- `81ef728/intel-failure`: CI 41857455960의 실제 macOS Intel 불일치. 비어 있는 JSON은 실패 시 미완료 출력이며 삭제하지 않았다.
- `81ef728/linux-x64`: 같은 초기 CI의 Linux x64 계약 결과·빌드 출처·바이너리 checksum. 바이너리는 GitHub artifact에 있다.
- `investigation`: 최초 Intel 실패 로그, 이번 Intel 실패 로그와 readiness 지연/scan 실패의 통제 실험. 통제 실험을 최초 원인 증명으로 쓰지 않는다.
- `validation-history`: 오류 주입 적응 전·후, 진단 경고 중복 회귀와 수정 검사, 환경 제약이 있는 전체 실행 기록. 초기 전체 실행은 개발 중 소스 수정과 겹쳐 단일 SHA 검증으로 쓸 수 없다.

원시 stdout/stderr·ANSI·개행·실패 결과를 보존한다. `.trace.gz`는 원본 trace의 무손실 압축이다. 프로파일의 wrapping과 strace는 오버헤드를 추가하며 일부 로컬 검사와 겹친다. 구간의 wall 시간을 합해 CPU나 전체 CLI 지연으로 부르지 않는다. 첫 `instrumented`는 git backstop 때문에 scanner를 두 번 호출했고, `instrumented-isolated`는 저장소 밖에서 한 번 호출했다.

`startup/cli-1..3`은 잘못 사용한 `--version`의 usage 경로다. 유효한 공개 CLI 시작 검사는 `startup/cli-version-*`다. 이런 시행 과정도 덮어쓰지 않았다. 채택 판정에는 실제 제한이 확인된 별도 CI의 교대 측정만 사용한다.

- `923944d/performance`: 최종 후보의 실제 2 CPU/1 GiB/swap 0 비교. `assessment.json`은 채택 실패다. `summary.json`은 원시 표본에서 계산한 요약이며 나머지 artifact 파일을 바꾸지 않았다.
- `923944d/linux-*`, `923944d/macos-*`: 최종 후보의 네 플랫폼 실제 실행 계약과 artifact 출처.
- `923944d/install-linux-*`: Linux 두 플랫폼의 컴파일러 없는 설치·업데이트·복구 검사.
- `923944d/public-profile-stages`: 실제 공개 CLI의 JSON 준비·scanner report 파싱을 구분한 후속 단일 진단. 채택 표본에 합치지 않는다.
- `923944d/public-recheck`: 공개 v3.7.0 자산 15개 SHA-256 재확인 및 tap formula.
- `reproduction`: 실험 커밋에서 실행하는 수집·오류 주입 스크립트 사본. 현재 main의 기본 기능으로 제공하는 코드가 아니다.

최종 비교 소스는 PR #395의 `923944dc65e3530d9d0c89a1a72f9e5bc5a22363`이다. 원격 실험 브랜치와 커밋을 보존한다. 실패한 후보를 기본 경로에 병합하지 않는다.

대형 전체 검사 로그 두 개는 `.log.gz`로 보존한다. `validation-history/compressed-logs.json`에 압축 해제 후 SHA-256과 크기를 명시했으며 원본과 일치함을 확인했다. HOL의 테스트 이름 오인 전후 JSON과 CI 실패 로그도 같은 디렉터리에 남겼다. scanner 규칙·임계값·기대값을 바꾸지 않았다.

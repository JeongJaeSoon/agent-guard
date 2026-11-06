# Native 프로토콜 probe 수정 기록

최초 `--help` 호출은 helper가 제공하지 않는 명령이다. 최초 `prepare-v1` 호출도 출력 파일 2개 인자를 생략하고 redact-v1 형식 envelope를 보내어 rc=1이었다. 이 결과는 기능 미지원이나 제품 실패가 아니라 계측자 호출 오류다. 기존 stdout/stderr를 각 버전 `native-help.*`, `native-prepare-probe.*`에 보존했다.

두 번째 호출은 인자 두 개와 원래 response JSON을 올바르게 전달했으나 caller가 private staging 파일을 미리 생성해야 하는 조건을 누락해 rc=1이었다. 해당 입력·stdout·stderr는 `native-prepare-files-not-created.*`에 보존했다. 실제 모듈과 Rust OpenOptions 계약을 다시 확인해 파일 2개를 먼저 만들도록 도구만 수정했다.

최종 `prepare-v1 <strings-file> <framed-file>` 호출의 원시 입력·출력은 `native-prepare-valid.*`이다. v3.8.0과 v3.8.1 모두 rc=0, `prepared-v1`을 확인했다. 이는 성능 표본이 아니라 지원 API의 단일 smoke probe이다. 실패 자료를 삭제하지 않았으며 제품 코드나 기대값·timeout은 변경하지 않았다.

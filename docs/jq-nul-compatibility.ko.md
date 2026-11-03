# jq 1.6의 정상 문자열 과도 마스킹 수정

내부 검증 기록이며 번역 문서가 아니다.

jq 1.6에서 `"clean" | contains("\u0000")`는 `true`를 반환한다.
기존 NUL 선처리가 이 함수에 의존해 정상 문자열과 빈 문자열까지 전체 마스킹했다.
`index("\u0000") != null`로 바꾸어 실제 NUL 위치가 있는 경우만 기존과 같이
전체 leaf를 가린다. jq 1.7.1에서의 기존 동작과 일치시키는 호환성 수정이다.

탐지 규칙이나 NUL-bearing leaf의 보수적 마스킹은 유지한다. 키·숫자·boolean·null,
정상 Unicode, 빈 문자열과 문자열로 표시된 `\\u0000`은 유지한다.

`tests/unit-nul-redaction.sh`의 독립 기대값 3개를 jq 1.6 및 1.7.1에서 검사한다.
기존 소스+jq 1.6에서는 실패하고 수정 후에는 양쪽 모두 통과해야 한다.
전체 suite의 NUL 실패 주입도 새 predicate를 대상으로 유지한다.

```sh
AGENT_GUARD_TEST_JQ=/absolute/path/to/jq-1.6 sh tests/unit-nul-redaction.sh
AGENT_GUARD_TEST_JQ=/absolute/path/to/jq-1.7.1 sh tests/unit-nul-redaction.sh
```

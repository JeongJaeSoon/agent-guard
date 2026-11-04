# scanner 시작 비용 실험

출력 준비 Rust 후보(#395)를 기각한 뒤 전체 CLI 성능의 다음 병목을 조사한다.
기본 런타임·설치·업데이트·탐지 설정은 변경하지 않는다. 여기서 빌드하는
scanner는 공개 배포본이 아니며 production 설치에 자동 선택되지 않는다.

## 근거와 변수

공개 gitleaks 8.30.1의 `GODEBUG=inittrace=1`에서 go-re2/wazero 초기화가
약 317 ms였다. 공개 릴리스는 `gore2regex` 태그와 go-re2 1.9.0을 사용한다.
버전 조회도 패키지 초기화를 수행한다. 입력이나 검사 생략으로 얻은 값이 아니다.

- Agent Guard 기준: 실제 공개 v3.7.0 아카이브. 양쪽 모두 같은 CLI와 공개 Rust
  redactor bytes를 사용한다.
- scanner 공개 기준: 공식 gitleaks 8.30.1 바이너리.
- 재빌드 대조군: gitleaks 소스 `83d9cd684c87d95d656c1458ef04895a7f1cbd8e`,
  Go 1.26.0, 원래 go-re2 1.9.0.
- 후보: 동일 gitleaks 소스·컴파일러·빌드 태그, go-re2 1.13.0 및 필요한
  x/sys 0.48.0 의존성 업데이트. 상위 [PR #2289](https://github.com/gitleaks/gitleaks/pull/2289)도
  조사 시점에 같은 의존성 업데이트를 제안하고 있었으나 아직 병합되지 않았다.

scanner 바이너리를 바꾸는 실험이다. 이전 Rust 준비 실험의 ‘동일 scanner’
비교와 혼동하지 않는다. 버전 문자열만으로 동일 구현이라 보지 않고 SHA-256,
Go build info와 module graph를 함께 기록한다.

## 실행

Go 1.26.0과 기존 Rust devtools 빌드 환경에서:

```sh
sh bench/scanner/build-experiment.sh /absolute/new-scanner-directory
```

공개 빌드 태그로 upstream 테스트를 컴파일하면 v8.30.1의 generator 두 파일이
stdlib regexp를 import해 타입 오류가 발생한다. 공개 소스 대조군과 후보에서
동일하게 재현했고, 검증용 import 수정만 양쪽에 적용한다. 기대값은 바꾸지 않는다.
scanner 실행 파일은 이 검증용 수정 전에 빌드한다.

CI는 네 플랫폼에서 공식 scanner·재빌드 대조군·후보의 전체 finding을 비교한다.
finding 순서만 정렬하며 Secret, RuleID, 좌표, entropy 등 필드를 제거하지 않는다.
upstream testdata 및 독립 기대값·Unicode·NUL·잘못된 UTF-8 경계를 포함한다.
호스트 계약은 컴파일러가 없는 PATH에서 실행한다.

별도 Linux job은 실제 2 CPU/1 GiB/swap 0을 확인하고 두 호스트의 21개 경로를
9쌍 교대로 측정한다. 로그 off, 로그 on의 매번 새 상태, 로그 on의 준비 캐시
적중을 구분한다. warmup은 독립 clean 기대값과 cache 생성까지 확인하고 측정에서
제외하며 각 측정은 새 CLI 프로세스를 실행한다. 별도 strace에서 실제 version
실행 횟수도 보존한다. 동시 처리량과 10 ms RSS 합은 별도로 측정한다.

## 예비 관측과 채택 제한

로컬 9회 버전 실행 중앙값은 공개 314.06 ms, 재빌드 대조군 317.03 ms,
후보 6.23 ms였다. 7쌍 CLI 예비 비교에서 Claude 다수 문자열 지연은 로그 off
−62.89%, cold −61.04%, warm −47.93%였다. 개별 2 CPU/1 GiB가 보장된 수치가
아니므로 CI의 제한 자원 비교를 대신하지 않는다.

성능 판정은 목표 지연 또는 CPU 10% 이상 개선, 일반 경로 지연·CPU 5% 초과
회귀 없음이다. 성능 판정과 scanner 의미·기존 corpus·독립 기대값 판정은 별개다.
원시 결과와 실패를 보존하고, 일치하지 않는 필드를 지우거나 timeout을 늘려서
통과시키지 않는다. 성공하더라도 사용자 배포 적합성 검증의 완료를 뜻하지 않는다.
새 scanner 공급·식별·업데이트·복구 계약 및 upstream 유지보수 상태도 검토해야 한다.

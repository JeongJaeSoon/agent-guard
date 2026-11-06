# 보고서 도구의 집계·검증 범위

이 디렉터리는 제품 코드를 실행하는 계측 하네스와 분리된 후처리·브라우저 검증 도구다. 실측 입력, 제품 기대값, timeout, 실행 순서와 표본 수를 이 도구가 바꾸지 않는다.

- `generate.py`는 `runtime`과 별도 `rss` phase만 집계한다. `warmup`·`trace`는 원시 JSON/CSV에 유지하며 CLI 지연·CPU에 섞지 않는다. RSS 합은 별도 계측 자료만 사용한다.
- 실패·작업량 불일치는 원시 행을 유지하고 동일 작업 성능 집계에서 제외한다. 유효 n이 9미만이면 중앙값·IQR·n을 남기되 변화율과 개선/회귀 판정은 N/A다. 실제 교대 실험은 같은 round의 양쪽 유효 표본 교집합도 9쌍 이상이어야 한다. optional 버전간 직전 비율은 같은 VM의 별도 버전 블록 비교로 명시하며, 같은 버전의 기본↔fused 비교와 구분한다.
- 정확도 사례의 일치 수는 종료 상태와 출력을 함께 검증한 `success`를 우선한다. 출력만 일치하는 `expected_match`가 참이어도 `success=false`이면 실패다. oracle 오류에 대한 파생 제외 메타데이터는 별도 집계하며 원시 분류를 덮어쓰지 않는다.
- 설치 버전의 `v` 접두어는 집계 표시에서만 표준화한다. 같은 버전 재설치를 update에서 분리한다. scanner 최초 설치 크기는 `home_delta_bytes`를 사용해 기존 sentinel 48 B를 빼며, 원시 `installed_bytes`는 변경하지 않는다. cached 다운로드 크기는 실제 네트워크 시간과 구분한다.
- 일부 설치 원시 `scope`에는 공용 formatter의 bootstrap 설명이 들어 있다. `asset-network-download`는 archive 전송만, `dependency-scanner-cached`는 scanner 최초 설치로 실제 scenario·명령이 다르다. 원문은 그대로 두고 집계에 `scope_raw`·`scope_display`·`scope_display_corrected`·`scope_display_note`를 추가해 표시 범위와 정정 이유를 구분한다. 수치나 계측 구간을 사후 변경하지 않는다.
- 4동시의 지연은 4요청 묶음 완료 시간, CPU는 4요청 합계다. 단위를 `ms/4요청 묶음`으로 표시하고 단일 요청 CPU와 같은 양으로 비교하지 않는다.
- HTML 임베드 전체 JSON, 모든 집계 CSV의 숫자, Markdown의 반올림된 숫자를 생성 시 대조한다. `<tag>`, `&`, `</script>`와 문자 그대로의 `\\u003c`를 포함한 독립 roundtrip 검증도 수행한다. 이 escape 검증에서 데이터 변형은 확인되지 않았다.

`check_generator.py`의 합성 검증은 제품 실측과 분리된다. n=8, 각각 n=9이지만 공통 유효 round가 4개인 경우, optional의 별도 버전 블록, 출력만 일치하고 종료 상태가 틀린 경우를 검사한다. 합성 수치는 제품 보고서에 포함하지 않는다.

브라우저 도구 초기 smoke의 실패 원본은 [browser-tooling-failures.json](browser-tooling-failures.json)에 있다. 처음에는 기본 실행 sandbox가 Chromium의 socket 동작을 막았다. 추가 실행 권한에서는 Chromium이 시작되었으나 관리 정책이 `file://` 탐색을 차단했다. 정책을 변경하지 않고 허용된 `http://localhost:31460`에서 우리가 생성한 HTML 한 파일만 제공하는 경로로 UI를 검사한다. 외부 HTTP(S) 요청은 차단하고 새 임시 프로필을 사용한다. 이는 file URL 직접 열기 검증을 대신했다고 주장하지 않는다.

최종 `validate_browser.py`는 실제 최종 HTML의 hash를 기록하고 표·그래프·필터·다운로드 JSON/CSV의 숫자를 대조한다. 결과와 screenshot은 별도 출력 디렉터리에 보존한다. 생성기를 다시 실행하면 브라우저 확인 상태가 초기화되므로 최종 HTML이 바뀌면 다시 확인해야 한다.

최종 데이터의 첫 브라우저 자동 검증은 통과했으나 screenshot을 직접 확인해 작은 변화율 축의 정수 반올림(`0`/`-0` 중복)과 모바일 긴 환경변수 줄넘침을 발견했다. 실측값·기준·기대값을 바꾸지 않고 축 표시 정밀도와 본문 word wrapping을 보정했다. 첫 성공 증거는 `browser-validation/`에 유지하고, 보정된 최종 HTML은 별도 `browser-validation-final/`에서 다시 검증한다.

독립 최종 검토에서 RSS가 같은 VM의 별도 phase라는 점, 완전 마스킹 토큰 오탐의 실제 경로가 사용자 프롬프트라는 점, CI 32개 사례와 별도 로컬 jq1.6 printenv 검사 범위를 명확히 하는 문구를 수정했다. 실제 사용한 correctness-summary 입력에 재현 명령도 맞췄다. `final-regeneration-validation.json`은 수정 전후 실측·집계·정확도·설치·지표/판정 규칙 10개 데이터 항목의 깊은 동등성, 원본 source-index 6개 SHA와 23개 증거 ZIP SHA를 검증한다. 이 문구 보정 뒤의 최종 UI 검증은 `browser-validation-final2/`에 남긴다.

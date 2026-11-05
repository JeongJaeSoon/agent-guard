# 전체 재작성 없이 출력 처리 비용 줄이기

v3.7.1 main `d00b488`에서 분리한 실험이다. 기본 경로와 scanner 선택은 유지한다.
명시적 `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused` 또는 이 디렉터리의
`candidate`/`candidate-prepare` 실행기로만 새 경로를 선택한다. 변수를 지우면
원래 셸 경로로 복귀한다. 사용자 설치나 릴리스에는 아직 채택하지 않았다.

## 구현 범위

1. detector의 각 파일마다 호출하던 mktemp를 하나의 private directory로 합친다.
2. 성공 여부를 확인한 중간 결과는 private records 파일에 직접 누적한다.
   실패 뒤의 부분 결과를 stdout으로 내보내지 않는다.
3. JWT와 bearer의 원래 grep 패턴·순서·실패 판정은 유지하고 JSON 인코딩을 합친다.
4. secret bundle 생성 시 이미 파일인 입력을 다시 복사하는 단계를 제거한다.
5. 앞서 단독으로는 기각한 Rust `prepare-v1`을 결합한 후보도 별도로 측정한다.
   탐지·정책·호스트 계약은 기존 셸이 담당하고, Rust는 JSON 문자열 추출·framing만 한다.

`prototype.py`는 첫 셸 후보를 main에서 만든 기록이다. 현재 구현을 재생성하는
스크립트가 아니며, 이후 수정을 덮어쓰도록 실행하지 않는다. 원래 redactor와
prepare helper는 별개 실행 파일로 측정해 기존 공개 core를 양쪽에서 유지한다.

## 사전 판정 기준과 비교 조건

목표는 scanner 초기화가 작아진 환경에서도 남는 출력 처리 비용이다.
**stdlib scanner를 양쪽에 동일하게 둔 다중 문자열 출력**을 목표로 삼고,
off/cold/warm 및 두 호스트에서 지연 또는 CPU 10% 이상 개선을 요구한다.
공식 scanner 경로도 같은 입력으로 검사하며, 두 scanner의 모든 일반 경로에서
지연·CPU 5% 초과 회귀를 허용하지 않는다. 공식 scanner에서의 추가 개선은 별도
보고하며 stdlib 결과를 전체 설치에 일반화하지 않는다.

CI는 실제 공개 v3.7.0 archive와 그 core를 기준으로, candidate만 현재 코드와
prepare helper를 사용한다. 각 쌍의 scanner bytes·정책 파일은 동일하다.
2CPU/1GiB/swap0의 실제 cgroup 값을 확인하고, 21개 경로 × 두 호스트 ×
9쌍을 audit off/cold/warm 각각 측정한다. 별도 부하에서는 처리량·CPU·최대 자식
RSS·10ms 표본 RSS 합을 구분한다. stdlib 빌드는 동일 upstream 소스/Go 버전으로
만든 비교 scanner이며 실제 Homebrew bottle 설치를 대신하지 않는다.

로컬 예비 비교는 공개 v3.7.1을 기준으로 외부 4CPU/16GiB 조건에서 실행했다.
셸 후보는 다중 문자열 지연 약 8% 개선, 준비 통합 후보는 약 19% 개선을 관측했다.
이는 CI 판정이나 모든 플랫폼의 성능 증거가 아니며 원시 표본을 별도로 보존한다.

네 플랫폼에서 prepare differential/독립 기대값, 기존 redactor corpus,
두 호스트와 helper 실패 복귀, 기존 출력 suite 및 scanner report 실패를 검사한다.
온전한 전체 suite도 별도로 실행한다. 과도 마스킹, 탐지 생략, timeout 확대는
채택 수단이 아니다. 효과가 부족하면 원시 기록을 남기고 더 넓은 구현을 비교한다.

## 최초 CI와 측정 진입점 수정

`b673546`의 최초 stdlib/cold 실행에서 목표 지연 약 15%, CPU 약 13~14% 개선을
관측했으나 Codex pre-read-clean 지연이 5.0259% 증가해 판정은 실패했다.
이 실행은 편의 wrapper를 후보에만 추가해 dirname·shell exec 비용도 포함했다.
기준을 완화하거나 같은 실행을 재시도하지 않고, devtools가 실제 CLI를 양쪽 모두
직접 실행하면서 후보에만 명시적 환경 선택을 전달하도록 수정한다. baseline의
실험 변수는 매번 비우며 helper 해시도 결과에 기록한다. 최초 wrapper 결과는
별도로 남기고 수정된 진입점과 혼합하지 않는다.

기존 jq 부분 출력 주입은 native 준비 경로에서는 실행되지 않는다. 이에 native
테스트 wrapper도 해당 두 단계에서 먼저 실패하게 하고, 원래 jq fallback에도
그대로 주입하여 기존 whole-leaf 기대값을 유지한다. 정상 native 준비와 prepare
실패 후 정상 jq 복구는 각각 corpus와 `tests/fused-output.sh`로 따로 검증한다.

최초 Linux 출력 suite에서는 1004건 성공·35건 실패를 보존했다. 컴파일러 없는
host 계약용 PATH를 전체 suite에도 적용해 fixture 생성에 필요한 gzip, mkfifo,
base64, printenv, yes가 빠진 로그를 확인했다. compiler-free 준비·host·fallback
검사는 유지하고, 전체 출력 suite는 시스템 fixture 도구가 있는 별도 step에서
실행하도록 분리한다. 기대값과 scanner 제한 시간은 변경하지 않는다.

후속 CI는 실제 Linux Homebrew 설치 바이너리도 같은 방식으로 양쪽에 사용한다.
버전·formula 정보·build info·해시를 보존하고, bottle의 loader와 라이브러리 prefix를
읽기 전용으로 함께 마운트하여 실행 파일을 패치하지 않는다. 따라서 이전 stdlib
소스 재빌드 관측과 실제 Homebrew 비교를 구분할 수 있다.

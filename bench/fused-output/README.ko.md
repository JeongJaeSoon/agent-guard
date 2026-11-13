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

실제 Homebrew 추가의 최초 3개 job은 설치 뒤 `go version -m` 단계에서 중단됐다.
로컬에 보존한 SHA-256 `78b43af...fe5d1`의 **설치 전 공개 bottle ELF**에도 같은
오류가 재현되어, 설치나 후보의 실행 실패로 해석하지 않는다. Go build-info를
읽을 수 있다고 가정한 검증기 문제다. 후속 검증은 해당 공식 bottle 해시를 고정하고
설치된 8.30.1 버전·복사 바이트 일치·Homebrew SBOM·formula·ELF 정보와 실제 실행을
검사한다. build-info의 원래 실패 상태와 stderr는 지우지 않는다. 공식 및 stdlib
소스 빌드의 build-info 추출 실패는 여전히 검증 실패로 처리한다.

`733cf38` 직접 실행에서는 stdlib의 126개 비교가 목표 10%/일반 경로 5% 기준을
통과했다. 공식 scanner warm의 Claude pre-read-placeholder는 지연 +6.06%,
CPU +5.42%여서 전체 기준은 아직 실패다. 출력과 무관한 PreToolUse에서도 추가한
출력 함수 정의를 매번 파싱하고 있었으므로, 다음 후보는 그 정의를 별도 파일로
옮겨 출력 detector를 실제 호출할 때만 읽는다. 동일 실패 표본을 보존하며, 이 변경이
회귀를 해소하는지는 후속 측정으로 판단한다. 단순 재실행이나 기준 변경은 하지 않는다.

같은 head의 macOS Intel 출력 suite는 1042건 성공·1건 실패였다. 기존 960000개
숫자/불리언 fallback fixture가 36초 걸려 원래의 20초 조건을 넘었다. stdout 일부와
stderr는 남았지만 실패한 조건의 단락 평가로 전체 출력 검증은 완료되지 않았다.
새 진단은 공개 3.7.0/3.7.1/후보 각각의 원본 CLI와 함수별 시간 계측 CLI를 한 번씩
실행하고 입력·전체 stdout·stderr·CPU·RSS·독립 기대값·단계 시간을 보존한다.
계측 오버헤드는 성능 판정에 섞지 않으며 시간 제한·기대값은 그대로 유지한다.

고정된 `355bf54` 소스를 읽기 전용으로 둔 컴파일러 없는 Linux 컨테이너에서 전체
suite 2727건 성공·0건 실패(exit 0)를 확인했다. 해당 CLI 구현은 `733cf38`과 같고,
이후 지연 로딩 변경은 별도 fallback 6건 및 후속 플랫폼 CI로 검증한다.

`afab414`의 별도 Intel 진단에서 공개 3.7.0은 47.8초, 공개 3.7.1은 41.3초,
후보는 37.0초였고 세 출력 모두 960000개 독립 기대값과 일치했다. 단 한 번씩의
진단이므로 버전별 속도 순위를 주장하지 않는다. 계측 함수 wrapper 자체가 큰 JSON
인자를 추가 복사하여 58~63초가 되었으므로 그 절대 시간도 채택 지표로 쓰지 않는다.
다만 문자열만 바꾸는 primary transform을 통과하는 큰 인자와 awk 스칼라 레코드
반복 처리가 관측되어, quote-free JSON에서는 항등인 문자열 변환을 건너뛰고 이미
열린 container 안의 완전한 scalar record는 구조 재검사·여러 gsub를 생략하는
작은 셸 수정을 분리했다. 괄호 포함 레코드는 원래 구조 검사를 그대로 통과한다.
독립 숫자·중첩 shape·두 호스트 12건을 추가하고 원래 20초 검사도 유지한다.
이 실패는 최초 v3.7.0 Intel host mismatch와 원인이 같다고 확정하지 않는다.

첫 숫자 최적화 `f19a9a0`(실행 head `9c5d937`)는 Linux x64/ARM과 macOS ARM에서
같은 20초 조건을 통과했지만 Intel 원본 실행이 21.8초라서 실패로 보존했다.
전체 출력은 네 플랫폼 모두 독립 기대값과 일치했다. 후속안은 conservative 호출자가
이미 보유한 JSON 변수를 command substitution 안에서 그대로 읽도록 하여, 두 내부
함수의 큰 인자 확장·중복 대입을 제거한다. 외부에서 호출하는 awk wrapper는 유지하고
private 임시 출력·전체 성공 확인·복구 계약을 그대로 검사한다. 실패한 21.8초를
반올림하거나 timeout을 늘려 성공으로 처리하지 않는다.

인자 재확장 제거 `e87a903`도 Intel 24.5초로 실패했다. 따라서 이를 시간 문제의
해결로 채택하지 않는다. 다음 후보는 문자열이 없는 유효 JSON이 ASCII라는 조건에서
동일한 327680-byte cap을 먼저 검사한다. 이미 conservative 복귀가 필수인 값은
큰 `out` 복사와 변화를 줄 수 없는 NUL 문자열 walk 전에 기존 복귀 함수를 호출한다.
상한을 올리거나 검증을 생략하지 않으며, 문자열/바이너리 응답과 작은 값의 경로는
원래대로 둔다. 이전 두 실패 head와 원시 출력은 별도 디렉터리에 보존한다.

조기 cap 후보도 Intel 25.2초로 실패했다. 동일 `a7b7c55` CLI의 자식 CPU/locale
진단에서 기본 en_US.UTF-8은 47.9초(user+sys 36.0초), C locale은 9.6초
(user+sys 8.7초)였고 독립 출력은 같았다. awk 자체의 user CPU는 각각 약
4.5~4.8초 / 4.2~4.3초로 차이 대부분을 설명하지 못했다. 이는 작은 표본의 원인
진단이며 채택 성능 비율이 아니다. 후속안은 문자열 없는 상한 초과 ASCII JSON에만
함수 호출 범위의 C locale을 사용한다. 일반 문자열·바이너리·탐지 경로와 호출자의
locale은 유지하며 전체 C locale을 사용자에게 요구하지 않는다.

함수 호출 앞의 임시 `LC_ALL=C` 후보는 Intel 58.6초로 통과하지 못했다. locale
변수 값과 shell 내부 처리 효과를 같다고 가정하지 않고 이 실패도 보존한다.
후속안은 ASCII 초과 응답 구간에서 shell의 LC_ALL을 명시적으로 대입한 후,
함수가 끝나면 이전 값과 set/unset 상태를 복원한다. 계측 실행에서 호출 전후
locale 상태가 정확히 같은지도 독립적으로 확인한다.

명시적 대입/복원 `88cc1ab`은 네 플랫폼의 원래 20초 조건을 통과했다.
원본 CLI 실행은 Linux x64 1.43초, Linux ARM 1.18초, macOS ARM 5.24초,
Intel 11.12초였고 전체 독립 출력과 호출 전후 locale 상태도 일치했다.
이 플랫폼별 단일 실행을 평균 성능 비율로 사용하지 않는다. 최종 PR head에서는
전체 계약 및 동일 scanner 성능 측정을 다시 적용한다.

통합 `bd19cb5`의 378개 동일 조건 비교는 독립 기대값 불일치 0, 일반 경로
지연·CPU 5% 초과 회귀 0으로 사전 성능 기준을 통과했다. 실제 Homebrew의
목표 지연은 15.30~21.51%, CPU는 13.72~15.17% 감소했다. Claude 동시
4요청 표본 RSS 합은 213.43→238.37MiB로 증가했으므로 메모리 개선으로
표현하지 않는다. 격리 Linux 전체 suite도 2739 성공/0실패, exit 0이었다.

그러나 같은 head의 native-platforms Intel job `127226599967`은 Claude
fixture 3 / relative-path에서 실패했다. 이번에는 원시 stdout/stderr가 남아
scanner readiness의 기존 2초 timeout이 DEGRADED 출력 차이의 직접 원인임을
확인했다. 후속 macOS Intel/ARM의 각 24회 합성 hook 진단에서는 재현되지
않았고, Intel 직접 version은 0.34~0.83초였다. 이 성공으로 기존 실패를
지우지 않으며 최초 자료 없는 v3.7.0 mismatch에 같은 원인을 소급하지 않는다.

별도로 부모가 완료한 version 자식을 reap한 직후 지연되는 경합을 결정적으로
재현했다. 기존 watchdog은 이미 정상 종료/exit 7인 자식도 늦게 timeout으로
바꿨다. timeout 기록 직전에 자식의 생존 여부를 확인하는 최소 수정과 전후
회귀 검사를 추가한다. 실제 느린 자식의 2초 제한과 실패 정책은 그대로다.
이 재현 가능한 경합이 위의 실제 CI timeout 원인이었다고 확정하지 않는다.
실패를 성공까지 재실행하지 않고, 수정된 head의 필수 CI·네 플랫폼 설치·성능을
별도로 검증한다. 원시 자료는 `codex/fused-output-evidence` 브랜치에 head별로
보존하며 공개 배포는 아직 v3.7.1이다.

완료 경합의 네 플랫폼 전후 회귀 실행 `42026053383`은 모두 통과했다.
각 플랫폼에서 기존 코드 1성공/2실패, 수정 코드 3성공/0실패, 기존 readiness
47성공/0실패였다. 이는 결정적으로 만든 부모 지연 경합의 수정 증거이며 실제
간헐 CI timeout의 동일 원인 증명은 아니다. 기존 `bd19cb5` CI 원시는 보존하고
이 수정이 포함된 최종 head를 별도로 검증한다.

## 배포 패키지 조합의 추가 검증

원인별 성능 실험은 공개 redactor bytes를 양쪽에서 유지하고 준비 helper를
분리했다. 최종 설치에서는 같은 검증된 core가 `prepare-v1`과 `redact-v1`을
모두 처리하므로, 설치물의 이 조합도 별도로 측정한다. `performance.yml`의
공식/Homebrew × off/cold/warm job은 해당 실행에서 실제 빌드·실행한 Linux
musl artifact와 sidecar를 받아 후보 설치 위치에 넣고, 같은 파일을 준비 경로에도
지정한다. 공개 v3.7.0 기준본과 scanner bytes·입력·정책·실제 2CPU/1GiB/swap0·
9쌍 교대 조건은 같다. 기존 attribution 원시와 별도 artifact 이름으로 보존한다.

실제 Homebrew 목표 지연 또는 CPU 10% 이상, 두 scanner 일반 경로 지연·CPU
5% 초과 회귀 없음, 모든 독립 출력 일치를 요구한다. 9쌍 측정에서 5%를 넘은
일반 경로 케이스는 그 케이스만 새 21쌍으로 다시 재고, 다시 5%를 넘을 때만 회귀로
판정한다(`bench/native/confirm.jq`). `screening.json`과 `assessment.json`의
`screened_regressions`에 첫 판정을 남긴다. 이 job은 main push마다 돌지 않고
nightly, 수동 실행, 릴리스 PR에서만 돈다. 실패해도 native 배포 집계와 릴리스를
막지 않는다. nightly가 통과하지 못하면 GitHub issue 하나를 열고, 이후 실패는 그
issue에 댓글로 남긴다. 릴리스 workflow는 릴리스 PR head의 결과를 경고로만
남긴다. 공식 scanner 목표의 10% 개선을 요구했다고 표현하지 않는다.
두 호스트의 설치 core 공유·부분 실패·helper/모듈 누락·옵션 해제 10개 검사도
네 플랫폼 설치 검증과 발행 후 공개 설치·Homebrew 검증에 추가한다. 로컬에서는
컴파일러·네트워크 없는 컨테이너에서 같은 10개 독립 기대값 검사를 통과했다.
이 추가 검증을 마치기 전에는 최종 제품 채택·발행이 완료됐다고 표현하지 않는다.

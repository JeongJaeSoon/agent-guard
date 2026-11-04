# v3.7 공개 배포본 이후 출력 준비 Rust 실험

내부 실험 기록. 계획만 작성한 문서가 아니라 실제 구현·실행·실패 원본을
구분해 보존한다. 2026-11-05(JST) 시작 시 원격 main을 다시 조회해
`2a35cd4f3900d28cac057d70fa1559ac87c26890`과 네 워크플로 성공을 확인했다.
PR #393·#394는 병합됐고 열린 이슈·PR은 없었다. 최신 공개 릴리스는
`e709445fb6fce9ade8cbbd2d6bcf2940e48da178`의 v3.7.0이었다.
기존 `/workspace/agent-guard` 작업 트리는 미커밋 변경이 없었고 그대로 보존했다.

## 구현한 후보

[실험 PR #395](https://github.com/JeongJaeSoon/agent-guard/pull/395)의
`81ef7288e0bef2bad6967cee2c0c4c2a57b422aa`에서 다음 후보를 실제 구현했다.

- `prepare-v1`: JSON을 한 번 파싱하고 scanner용 문자열과 RS/US로 framing한
  leaf 스트림을 함께 작성한다. 객체 키·숫자·불리언은 탐지 입력에 추가하지 않는다.
  jq의 순서, 빈 leaf, 개행, 구분자 escaping을 그대로 보존한다.
- 명시적 `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN`으로만 선택한다.
  이 절대 경로는 기존 redactor override와 같은 신뢰된 개발 실행 파일 계약이다.
  기본 사용자 경로·패키지 선택은 바꾸지 않았다.
- 두 private staging 파일 작성이 끝나야 완료 표식을 출력한다. 실행·쓰기 실패,
  빈/부분 완료 표식에서는 두 단계를 기존 jq로 다시 수행한다. 부분 파일을
  detector가 소비하지 않는다. 예약 키·과도한 nesting 등 미지원 입력도 복귀한다.
- 탐지 규칙, gitleaks, 정책, NUL 마스킹, PII, 호스트 envelope, 예산과 timeout은
  그대로 둔다. 같은 공개 v3.7 redactor 바이너리를 양쪽에 사용해 준비 단계의
  효과만 비교한다. 이 실험만으로 전체 Rust 재작성 필요성을 주장하지 않는다.

기존 측정 도구는 기준을 강제로 `shell`로 설정했다. 공개 v3.7의 기본 경로와
비교하려고 `--baseline-packaged-native`를 구현했고 매 표본에서 기준·후보의
override를 명시적으로 초기화했다. 실험 helper의 SHA-256도 결과에 기록한다.

## 측정 경계와 첫 결과

공개 아카이브 SHA-256은
`d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d`다.
실제 다운로드를 이 값으로 검증했다. 로컬 gitleaks 8.30.1 아카이브도 저장소의
고정 checksum과 일치한다. 입력·규칙은 양쪽이 같고 매 실행의 출력을 독립
기대값으로 확인한다.

로컬 상위 cgroup은 `cpu.max=400000 100000`, `memory.max=17179869184`,
`memory.swap.max=max`였다. rootless Docker의 cgroup driver는 `none`이므로
컨테이너별 2 CPU·1 GiB 제한이 적용됐다고 표현하지 않는다. CI 수집기는 실제
`200000 100000`·`1073741824`·`0`을 읽고 일치해야 측정한다.

로컬 7쌍 교대 예비 비교:

| Claude 경로 | CLI 지연 변화 | CPU 변화 |
| --- | ---: | ---: |
| 다수 문자열 치환 | −4.32% | −3.66% |
| 정상 짧은 출력 | −0.25% | −0.25% |
| 긴 한 줄 | +0.58% | +0.71% |

목표 10%에 미달한다. 예비 결과를 채택이나 다른 플랫폼의 성능 근거로 쓰지
않는다. 지연에는 CLI 시작과 공개 redactor checksum 검증을 포함한다. CPU는
각 표본의 user+system 합의 중앙값이며, `ru_maxrss`는 단일 자식 최대 RSS다.
동시 실행의 10 ms RSS 합은 공유 페이지 중복과 짧은 peak 누락 가능성이 있어
총 peak 메모리나 메모리 절감으로 표현하지 않는다.

별도 계측에서 scanner 준비와 실행이 큰 비용이었다. 격리된 작업 디렉터리의
계측 실행은 준비 CPU 약 384 ms, scanner CPU 약 615 ms, jq 15회 CPU 합 약
109 ms를 보였다. wrapping·동시 로컬 검사 부하가 있는 진단 실행이므로 이
구간 시간을 채택 성능이나 합산 가능한 CLI 지연으로 쓰지 않는다. 최초 Bash
trace에는 PS4 unset 변수 진단이 있었고 초기 기준 표본 수집과 겹쳤다. 원본을
보존하되 예비 설명 자료로만 취급한다. 저장소 안에서 수행한 첫 wrapping
실행은 git backstop까지 scanner를 두 번 호출했으므로 별도 보존한다.

후속 진단에서는 공개 CLI의 jq 호출을 목적별로 구분했다. 문자열 추출 CPU
13.22 ms, leaf framing 25.14 ms, scanner report 파싱 3.31 ms, 나머지 JSON
12회 57.51 ms였다. 같은 진단의 scanner 준비/실행은 357.88/478.49 ms였다.
이 값도 wrapper를 포함한 단일 진단이므로 교대 비교의 표본에 합치지 않는다.
원본은 `923944d/public-profile-stages`에 별도로 보존했다.

별도의 준비 단계 9쌍 교대 실행에서는 jq 두 호출 47.03 ms/CPU 44.96 ms,
Rust 한 호출 4.42 ms/CPU 4.07 ms였다. 완성된 두 파일은 매번 byte-for-byte
검증했다. 이 약 91%의 국소 개선을 전체 CLI 개선으로 표현하지 않는다.
공개 CLI의 유효한 `version` 명령 시작 비용은 별도 3회 진단에서 중앙값
19.60 ms였다. 잘못 호출한 `--version`의 usage 결과도 원본에 남기며 유효
명령 측정과 구분한다. gitleaks `version`을 `--version`으로 바꾸는 단순 대안도
각 3회 실행했지만 약 0.38초의 초기화 비용을 제거하지 못했다.

## macOS Intel 불일치 조사

PR #393의 최초 실패 job `126591007436` 로그를 다시 읽었다. Claude의
`failing` helper에서 불일치가 있었다는 사실만 남아 있고 fixture 번호·출력·
stderr가 없다. 기존 보강 후 90건 × 3회 성공은 원인 해결 증거가 아니다.

이번 [CI 실행](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41857455960)의
[Intel job](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41857455960/job/126669802861)에서
불일치가 다시 발생했다. 기존 90건과 준비 차등 1,024건은 성공했고, 추가 호스트
검사의 Claude fixture 1, `missing` helper 변형에서 실패했다.

- 기준: 2.842786787초, `stdout:"API_KEY=[REDACTED]"`, `clean:"visible"`,
  `type:"text"`를 포함한 정상 replacement.
- 후보: 4.556029904초, replacement 대신 기존 `protection is DEGRADED` 응답.
- stderr도 같은 degraded 메시지였다. helper가 없으므로 출력 준비 Rust 코드에
  진입하기 전 의존성 준비 경로에서 실패한 관측과 일치한다.
- artifact `13339481443`의 ZIP SHA-256은
  `298ca8c2af5ab1399cd38fae03bb34bf4fc652730f1088c4b7ffed2b3b720b8e`다.

통제 실험에서는 동일한 공개 v3.7.0·동일 fixture·동일 failing helper에 대해
scanner `version`만 3초 지연시키면 기존 2초 watchdog에 의해 degraded 응답이
나왔다. 별도로 scanner `stdin`만 종료 코드 2로 실패시키면 정상 leaf까지
`[REDACTED]`가 되는 보수적 응답이 나왔다. 서로 다른 두 실패 조건이 모두
출력 불일치를 만든다. 이 통제 결과는 원본 CI와 동일 원인이라는 증명이 아니다.

`e51ee11`에서는 준비 실패의 같은 실행에서 `state`·`detail` 내부 enum만
stderr에 남기도록 보강했다. 경로·scanner 원문·hook payload는 출력하지 않는다.
기존 2초 제한, host의 open/closed 정책과 기대값을 유지하며 두 호스트 timeout
진단을 검사한다. 진단 로컬 계약은 47건/실패 0이다. 다음 실행에서 정확한
실패 이유를 관측하기 위한 변경이며 최초 장애의 원인 수정 완료가 아니다.

초기 보강은 매 호출마다 stderr를 내보내 세션별 한 번만 경고하는 기존
계약을 깨뜨렸다. `923944dc65e3530d9d0c89a1a72f9e5bc5a22363`에서 기존
경고 출력 조건 안으로 옮겼다. 두 호스트에서 같은 세션의 두 번째 경고가
stdout·stderr 모두 비어 있는 기대값을 추가했고 최종 진단 49건/실패 0이다.

## 정확도와 실패 자료

초기 로컬 준비 차등·독립 바이트·잘못된 입력·쓰기 실패 계약은 1,024건/실패 0,
호스트·실패 복귀는 126건/실패 0이다. Linux 두 아키텍처의 네이티브 실행도
기존 차등 1,024건, 기존 호스트 90건, 새 준비 1,024건, 새 호스트 126건을 통과했다.
Intel 실패를 이 성공들과 합쳐 지우지 않는다.

초기 로컬 전체 검사에는 두 가지 시험 환경 문제가 있었다. 측정용으로 한
플랫폼의 공개 바이너리만 `libexec`에 놓아 archive 설치 검사가 불완전 payload를
정상적으로 거부했다. 또한 기존 jq 오류 주입은 성공하는 Rust 단계까지 실패시키지
못했다. 최초 로그를 보존하고 source-only checkout 및 동등한 단계에 오류를 넣는
어댑터로 구분해 검사한다. `test-output-prepare-experiment.sh`는 Rust 준비 파일에
부분 출력을 쓰고 실패한 뒤 기존 jq 오류 주입도 유지한다. 기대값을 완화하거나
실패 검사를 삭제하지 않는다.

초기 전체 실행은 개발 중인 파일을 읽었으며 진단 수정과 겹친 한 호출에 일시적
셸 구문 오류도 남았다. 집계는 2,719 통과/11 실패지만 단일 SHA의 회귀 결과로
사용할 수 없다. 이후 source-only 검사는 별도 detached checkout에 고정했고,
최종 판정에는 변경되지 않는 CI checkout의 결과를 사용한다. 이 실행 문제도
제품 원인으로 돌리거나 로그에서 제거하지 않았다.

고정된 `81ef728` source-only 전체 검사는 2,629건 통과/1개 집계 항목 실패였다.
private allow-list 양성 사례가 로컬 환경에서 실패했다.
이 실행 환경은 `/tmp/.git`와 `/workspace/.git`를 읽기 전용으로 놓아 두므로,
그 아래 임시 HOME은 제품의 저장소 내부 경로 차단 규칙에 걸린다. 이 안전
검사를 우회하거나 기대값을 바꾸지 않는다. 해당 로컬 로그는 환경 제한이 있는
실패 자료이며, 이 marker가 없는 CI의 전체 결과와 구분한다.

## 실제 제한 비교와 판정

최종 후보 `923944dc65e3530d9d0c89a1a72f9e5bc5a22363`의
[실제 비교 job](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41860989750/job/126682826561)은
공개 v3.7.0 아카이브, 동일 gitleaks 8.30.1·설정·공개 redactor bytes를 사용했다.
실제 checkout은 PR merge ref `6608c5fb7ecdc2f3d08789888b0ccdaad4efb403`이며,
head와 Git tree `8e1568800b718bbedbca4a4972a9a1487997a383`가 동일함을 확인했다.
컨테이너 내부에서 2 CPU, 1 GiB, swap 0의 적용을 확인했다. 21개 입력 × 두
호스트에 각각 9쌍을 교대로 실행했고, 별도 tracing은 지연 표본에서 제외했다.
양쪽 모두 audit logging을 꺼서 준비 캐시는 비활성화했다. 이 설정의 반복
CLI 비용이며 캐시가 활성화된 모든 사용자 세션의 개선율로 일반화하지 않는다.
[판정 원본](../bench/results/output-prepare/923944d/performance/assessment.json)과
[자원 요약](../bench/results/output-prepare/923944d/performance/summary.json)을 보존한다.

| 목표 경로 | 공개 v3.7 지연 → 후보 (ms) | 지연 변화 | CPU 합 중앙값 → 후보 (ms) | CPU 변화 |
| --- | ---: | ---: | ---: | ---: |
| Claude 다수 문자열 | 943.69 → 914.14 | −3.13% | 989.95 → 961.65 | −2.86% |
| Codex 다수 문자열 | 945.19 → 917.06 | −2.98% | 990.37 → 965.78 | −2.48% |

일반 경로의 지연 또는 CPU 5% 초과 회귀는 0개지만, 목표의 10% 개선을
충족하지 못하므로 **출력 준비 통합 후보를 기각한다**. 성공한 수집 job은
성능 채택 성공을 뜻하지 않는다. assessment의 `accepted`는 `false`다.

단일 호출 최대 자식 RSS 중앙값은 Claude 63,852 → 64,116 KiB,
Codex 64,372 → 63,860 KiB였다. tracing에서 execve/프로세스 생성 수는
Claude 79/132 → 79/132, Codex 80/135 → 80/135로 줄지 않았다.
두 jq 호출을 합쳐도 완료 확인과 파일 전달을 포함한 전체 경계 비용이 남는다.

각 8요청·3회 교대 부하 실행의 처리량 중앙값은 workers=1에서
1.0591 → 1.0905 요청/초(+2.96%), workers=4에서
1.2912 → 1.3356 요청/초(+3.44%)였다. 4-worker 최대 자식 RSS는
65,836 → 65,444 KiB, 10 ms 표본 RSS 합의 peak 중앙값은
310,412 → 308,444 KiB, 컨테이너 memory.peak 중앙값은
206,823,424 → 200,654,848 bytes였다. 세 수치는 범위가 다른 메모리
계측이며 서로 대체할 수 없다. 이 결과로 일반적인 메모리 절감을 주장하지 않는다.

최종 제한 컨테이너의 기존 출력 corpus는 939건/실패 0, 756개 지연 표본과
별도 trace 호출, 96개 부하 요청은 모두 독립 기대값과 일치했다. 정상 leaf를
그대로 보존하는 기대값도 포함하므로 과도 마스킹을 성공으로 계산하지 않았다.
최종 네 플랫폼의 실행 artifact에서 기존 차등 1,024건, 기존 호스트 90건,
준비 차등 1,024건, 준비 호스트 126건과 audit 116건이 모두 통과했다. Intel의
기존 워크플로에 이미 있던 추가 90건 × 2회도 통과했다. 이 workflow의 고정
반복을 실패 후 성공할 때까지 재실행한 것으로 세지 않으며, 성공 결과를 최초
및 이번 Intel 장애의 원인 해결 증거로도 쓰지 않는다.

Linux 두 플랫폼의 설치 artifact에는 컴파일러 없는 신규 설치·공개 3.6.14에서
업데이트, 실패 복귀 44건, 업데이트 실패 시 기존 설치·링크 복구 성공도 남았다.
이들은 실험 코드가 들어 있는 후보 패키지의 검증이며 새 공개 릴리스는 아니다.

## 호환성과 배포

채택한 런타임 변경과 실제 호환성 변경은 없다. 실험 override를 제거하면 기존
셸 준비 경로로 돌아가며, override가 실패해도 같은 경로로 복귀한다. 실패한
후보 때문에 버전 번호를 올리거나 v4 마이그레이션을 만들지 않는다. 진단 보강도
실험 브랜치에 보존하며 이번 기록 PR은 기본 런타임을 바꾸지 않는다.

공개 v3.7.0 자산 15개를 다시 내려받아 모두 SHA-256을 대조했다. Homebrew
main formula도 공개 `agent-guard.rb`와 byte-for-byte 일치한다. 이 재확인은
새 후보의 네 플랫폼 설치·업데이트 적합성을 대신하지 않는다. 기존 v3.7의
네 플랫폼 실행·컴파일러 없는 설치/업데이트·실패 복귀·정상 설치 보존 및
Homebrew 실제 설치 검증은 기존 릴리스 기록에 그대로 귀속된다.
**신규 릴리스·자산 교체·Homebrew 변경은 하지 않았다.**

남은 문제는 최초 Intel 실패의 정확한 원인이다. 이번 재현은 준비 단계의 degraded
출력까지 좁혔으나 어떤 의존성이 왜 실패했는지는 확정하지 못했다. version
준비를 생략하거나 timeout을 늘리면 정상/인프라 실패 구분을 바꿀 수 있으므로
성능 개선으로 채택하지 않았다. scanner 상주화, 탐지·정책·호스트 전체 재작성은
이 실험으로 효과나 안전성이 입증되지 않았으며 구현 완료로 주장하지 않는다.


## 기록 PR의 검증 과정

기록 PR의 HOL 검사는 전체 테스트 로그 두 개의 테스트 이름을 generic secret
규칙으로 오인했다. 고정된 scanner 3.57.0 wheel(checksum 검증)로 두 파일의
동일 행을 재현했다. 내용은 쉘 탐색 시험 이름의 command substitution 표기이며
자격증명이 아니다. Gitleaks의 원문 검사도 통과했다. 두 대형 로그를 무손실
`.log.gz`로 보존하고 압축 해제 SHA-256·크기를 `compressed-logs.json`에 기록했다.
실패 행을 편집하거나 삭제하지 않았으며 이전 커밋의 평문도 보존한다. 같은
score/severity 조건의 로컬 HOL은 high 2개에서 0개, 97점으로 통과했다. 로컬
의존성 버전은 CI lock과 다르므로 최종 head의 필수 CI 성공을 대신하지 않는다.

실험 PR의 전체 CI 집계에는 `SHARDS_RESULT: abandoned`가 남았다. 실행하지
못한 shard와 집계 실패를 원시 로그로 보존하며, 이를 코드 회귀 실패나 전체
성공으로 단정하지 않는다. 기록 PR 병합도 필수 CI 성공 전에는 수행하지 않는다.

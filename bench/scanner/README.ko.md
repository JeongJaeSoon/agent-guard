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
9쌍 교대로 측정한다. off/cold/warm은 각각 독립 runner에서 수집하고 6개 목표
비교와 126개 경로 결과가 모두 있는지 집계한다. 쌍 내부의 환경을 동일하게
유지하며, 다른 runner의 절대 지연을 직접 비교하지 않는다. 로그 off, 로그 on의 매번 새 상태, 로그 on의 준비 캐시
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

## 후속 로컬 분해와 조합 실험

230개 입력(상위 testdata 215개, 독립 기대값 7개, 잘못된 UTF-8 경계 8개)의
공식·재빌드·후보 비교에서 불일치 0이었다. 독립 기대값은 clean, placeholder,
일반 토큰, Unicode, NUL, CRLF, 인용 문자열이다. 상위 전체 테스트도 두 빌드에서
통과했다. 이 corpus가 모든 정규식 의미의 동등성을 증명하는 것은 아니다.

후보 scanner를 적용한 계측 실행에서 준비 CPU는 7.34 ms, 검사 CPU는
145.14 ms, JSON 추출·framing은 18.30/26.01 ms, 기타 JSON 12회는 60.13 ms였다.
wrapper가 추가되는 진단 실행이며 각 값의 합을 비계측 CLI 시간으로 취급하지 않는다.

빠른 scanner를 양쪽에 동일하게 둔 뒤 기각한 #395의 `prepare-v1`만 추가하는
9쌍 교대 조합 실험도 실행했다. 공개 CLI·공개 redactor를 기준으로 후보 CLI는
`923944d`를 사용하고 공개 redactor bytes를 그대로 복사했다. Claude 다중 leaf
지연은 추가 −7.65%, Codex는 −8.82%였다. CPU는 각각 −7.55%, −8.02%였다.
세 입력씩 양쪽 호스트의 독립 출력 기대값은 모두 통과했다. 이 제한된 로컬 결과는
목표 10% 개선의 채택 근거가 아니며 기존 기각 결론을 뒤집지 않는다.

현재 우선순위는 scanner 초기화 제거, 다음은 여러 JSON 단계를 합쳐 실제 호출
횟수를 줄이는 것이다. 작은 Rust helper를 더 붙이거나 탐지·정책·호스트 전체를
재작성해야 한다는 근거는 없다. 호환성을 유지하는 scanner 업데이트는 원칙상
v3.x 범위이며, v4.0.0을 필요하게 하는 계약 변경은 아직 확인하지 못했다.

## 설치 경로 차이: 전체 사용자 일괄 교체는 기각

Homebrew의 gitleaks formula와 실제 8.30.1 Linux x64 bottle은 `gore2regex`를
쓰지 않는다. Go 표준 정규식으로 빌드되어 공식 GitHub 바이너리의 wazero 시작
비용이 없다. 따라서 앞의 개선율을 Homebrew 사용자에게 일반화할 수 없다.

공개 bottle archive SHA-256은
`78b43afdf14a05c5df07b73aeaf63ae56b784c905f057411a43ee8fde40fe5d1`이다.
검증 후 원본 실행 파일은 수정하지 않고 시스템 ELF loader로 실행했다. bottle의
`@@HOMEBREW_PREFIX@@/lib/ld.so`는 미설치 상태에서 직접 실행할 수 없으므로
실험용 shell wrapper만 사용했다. 이 비교는 로그 off이며 wrapper는 준비 캐시
대상이 아니므로 warm 설치 검증으로 표현하지 않는다. 실제 Homebrew 설치·갱신
검증도 아니다. 원본·wrapper·loader 해시를 함께 보존한다.

같은 공개 Agent Guard CLI/core에서 9쌍 교대 비교한 RE2 1.13 후보는 다음과 같이
더 느렸다. 자원 제한 CI 수치가 아니라 로컬 탐색 결과다.

| 호스트·입력 | 공개 Homebrew 기준 지연 (ms) | RE2 후보 (ms) | 지연 변화 | CPU 변화 |
| --- | ---: | ---: | ---: | ---: |
| Claude small-clean | 243.77 | 309.23 | +26.85% | +20.49% |
| Claude long-line | 476.18 | 563.74 | +18.39% | +14.42% |
| Claude many-replacement-leaves | 345.47 | 401.60 | +16.25% | +11.96% |
| Codex small-clean | 209.64 | 286.30 | +36.57% | +30.29% |
| Codex long-line | 487.83 | 564.15 | +15.65% | +12.35% |
| Codex many-replacement-leaves | 346.61 | 395.47 | +14.10% | +9.90% |

따라서 모든 설치의 scanner를 이 후보로 일괄 교체하는 방안은 기각한다. 공식
GitHub scanner를 사용하는 경로의 의존성 개선 후보로만 남긴다. 기존 Homebrew
선택을 유지해야 하며, 공통 성능 개선은 JSON·출력 처리 통합에서 찾아야 한다.
실제 bottle·동일 컴파일러 stdlib 재빌드·RE2 후보의 별도 230입력 비교도 불일치
0이었지만 이것으로 두 정규식 엔진의 모든 의미가 같다고 결론 내리지 않는다.

후보 scanner로 실행한 로컬 출력 partition은 1,041개 통과, 2개 실패였다. 실패는
기존 환경에서도 관측한 `/tmp/.git` sandbox marker 아래 allow-list 신뢰 경계
검사 두 건이다. 원시 stderr를 보존하며 기대값이나 신뢰 검사를 완화하지 않았다.
따라서 이 로컬 실행을 전체 suite 성공으로 기록하지 않는다. 기존 macOS Intel
일회성 출력 불일치의 원인 미확정 상태도 유지한다.

## Intel 재관측과 진단 보강

기존 공개 scanner를 쓰는 `c4e5c48`의 native-platforms Intel job
`126744811093`에서 불일치를 다시 관측했다. Claude fixture 4는
`ordinary build status`이고 baseline 2.222 s에는 빈 출력, failing-helper
variant 2.404 s에는 DEGRADED envelope가 나왔다. 이번에는 fixture 번호,
stdout·stderr와 두 시간이 모두 남았다. 정상 입력의 준비 실패를 가리키지만,
기존 메시지에 probe detail이 없어 timeout으로 단정하지 않는다.

`degraded_hook_message`에 고정된 scanner 준비 원인 코드를 추가한다. 경로,
scanner 원문, hook 입력은 포함하지 않는다. 기존 한 번의 경고 안에 표시해
세션별 경고 제한·호스트 envelope·실패 정책·2초 시간 제한을 유지한다. 지원하지
않는 버전, 실제 지연 probe의 open/closed, 두 호스트의 clean PostToolUse를
검증하는 회귀 검사로 진단 전달을 확인한다. 원래 간헐적 지연의 원인 수정으로
간주하지 않는다.

별도 실험 CI의 macOS 두 플랫폼은 230 입력과 90 host/fallback 검사를 통과했다.
Linux 두 플랫폼은 시스템 PATH의 `go` 때문에 컴파일러 부재 검사에서 중단됐다.
명시한 런타임 도구만 연결하는 PATH로 수정한다. 로컬에서는 누락된 테스트 도구
`cmp`를 추가한 뒤 컴파일러 없는 host/fallback 90 검사를 통과했다. 초기 실패
로그와 수정 후 결과를 모두 남긴다.

진단 변경 후 readiness 검사 47개와 정규 suite 환경(`AGENT_GUARD_LOG_MODE=off`)
의 host outcome 검사 144개가 통과했다. 처음 host outcome 스크립트만 독립 실행한
경우 기본 audit 저장소를 쓸 수 없어 40개가 실패했다. 해당 로그를 별도로
보존하고 원래 suite가 지정하는 환경으로 검증했다. 출력 partition 재검사에서도
1,041 통과와 기존 sandbox allow-list 2실패만 관측했다.

## 실제 제한 자원 결과 (`c4e5c48`)

[실행 41878575601](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41878575601)의
성능 job `126745460249`는 35분 27초에 완료됐다. 실제 cgroup 값은 CPU
`200000 100000`, memory `1073741824`, swap `0`이었다. 같은 runner에서
두 호스트 × 3 audit 상태 × 21 입력 × 9쌍을 교대로 실행했다.

| 목표 | audit | 공개 지연 → 후보 (ms) | 지연 변화 | CPU 변화 |
| --- | --- | ---: | ---: | ---: |
| Claude | off | 932.51 → 331.07 | −64.50% | −64.38% |
| Claude | cold | 951.79 → 356.72 | −62.52% | −62.11% |
| Claude | warm | 655.09 → 334.71 | −48.91% | −48.32% |
| Codex | off | 941.21 → 339.11 | −63.97% | −63.96% |
| Codex | cold | 975.02 → 366.05 | −62.46% | −61.96% |
| Codex | warm | 659.51 → 342.34 | −48.09% | −47.92% |

126개 경로 비교의 독립 출력 검증은 모두 통과했고, 일반 경로의 지연 또는 CPU
5% 초과 회귀는 0개다. 별도 출력 partition은 1,039 통과·0 실패였다. 같은
컴파일러로 원래 RE2를 재빌드한 대조군 지연은 세 입력에서 +0.61%, +0.26%,
−0.90%로, 후보의 큰 개선을 컴파일러 변경만으로 설명하지 못했다.

8요청씩 3라운드의 처리량 중앙값은 1 worker에서 1.071 → 2.958 req/s,
4 workers에서 1.241 → 3.745 req/s였다. 4 workers의 최대 단일 자식 RSS는
65,828 → 37,468 KiB, 10 ms 표본 RSS 합의 peak는 306,804 → 195,832 KiB였다.
이는 공유 페이지를 중복 계산하는 표본 합이며 고유 물리 메모리로 해석하지 않는다.

이 범위의 성능 채택 기준은 충족했다. Homebrew 일괄 교체의 회귀 판정은 그대로이며,
네 플랫폼 검증·공급 출처·설치·업데이트·복구까지 완료한 제품 채택은 아니다.
릴리스나 v4.0.0 전환을 수행하지 않았다.

원래 trace counter는 `setsid` argv에 포함된 `gitleaks version`도 세어 off/cold를
2로 기록했다. 지연·CPU 표본과 분리된 trace 계수 오류다. 실제 실행 파일명이
`gitleaks`인 execve만 세도록 수정하고 원시 trace도 JSON에 보존한다. `c4e5c48`의
기존 계수는 덮어쓰지 않으며 버전 실행이 실제 두 번이었다고 해석하지 않는다.

원시 trace를 남기는 후속 로컬 검사에서 off/cold의 scanner 버전 실행은 각각
1회, warm은 0회였다. 최초 sandbox의 ptrace 차단 실패를 보존한 뒤, 고정된
합성 입력으로 생성한 자식만 추적하는 실행에서 확인했다. 이 1쌍 진단 결과를
9쌍의 성능 판정에 섞지 않는다.

추가로 같은 Go 1.26.0에서 양쪽 `go-re2/...` 전체 테스트를 `-race -count=1`로
실행해 모두 통과했다. race 계측은 CGO_ENABLED=1이며 `re2_cgo` 태그를 쓰지
않아 두 WASM 계열 backend를 검사한다. 실제 성능 바이너리는 CGO_ENABLED=0이다.
생성된 16/32/64-bit 메모리 접근의 범위 검사도 확인했다. 이것은 전체 의존성에
대한 보안 감사 완료나 모든 탐지 의미의 동등성 증명이 아니다.

## 후속 실제 실행과 별도 JSON 호환성 결함 (`301d091`)

[scanner 실행 41888821620](https://github.com/JeongJaeSoon/agent-guard/actions/runs/41888821620)은
네 플랫폼에서 각각 corpus 230개 불일치 0, 호스트 계약 90개 실패 0을 기록했다.
Go·Rust·C 컴파일러가 없는 runtime PATH에서 실제 바이너리를 실행했다.
같은 head의 기존 native-platforms 네 플랫폼 실행과 설치 검사도 통과했다.
이 결과는 실험 scanner를 정식 설치·업데이트 경로에 배포한 검증이 아니다.

성능 collector는 off/cold/warm을 서로 다른 runner로 나눴으며, 각 baseline과
candidate 쌍은 같은 runner와 실제 2 CPU/1 GiB 제한에서 교대로 실행했다.
상태 간 절대 지연을 비교하지 않는다. 전체 126개 비교·목표 6개가 완전하고
일반 경로의 지연·CPU 5% 초과 회귀는 0이었다.

| 목표 | audit | 공개 지연 → 후보 (ms) | 지연 변화 | CPU 변화 |
| --- | --- | ---: | ---: | ---: |
| Claude | off | 948.84 → 336.45 | −64.54% | −64.51% |
| Claude | cold | 942.81 → 325.41 | −65.48% | −64.98% |
| Claude | warm | 426.91 → 226.56 | −46.93% | −46.80% |
| Codex | off | 932.90 → 339.00 | −63.66% | −63.38% |
| Codex | cold | 938.46 → 333.44 | −64.47% | −64.12% |
| Codex | warm | 407.69 → 221.48 | −45.67% | −45.64% |

단, 같은 head의 일반 CI Linux core job `126780408081`은 기존 깊이 2,000
PostToolUse 검사에서 실패했다. 비밀값은 노출되지 않았지만 배열이 단일
`"[REDACTED]"` 문자열로 바뀌어 구조 보존 계약을 지키지 못했다. 해당 최초
stdout·stderr를 보존했고, 이를 scanner 성능 성공과 구분한다.

로컬에서 체크섬을 검증한 공식 jq 1.8.1로 같은 실패를 재현했다. 이 버전은
깊은 배열을 직렬화하며 종료 상태 0으로 `[[…<skipped: too deep>…]]`라는
JSON이 아닌 출력을 만든다. 기존 코드는 손상된 중간 응답으로 복구를 시도해
원래 배열을 잃었다. jq 1.7은 입력 검사 단계에서 거부해 원본 복구를 탔고,
1.8.2는 완전한 응답을 출력했다. 1.8.1/1.8.2 각각 stack 1/2/4/8 MiB에서도
같은 버전별 차이를 관측했다. 최초 CI는 jq 버전을 기록하지 않았으므로 CI의
정확한 바이너리 식별까지 입증한 것은 아니다. 후속 CI에 버전 출력을 추가했다.

중간 응답의 보수적 치환까지 실패할 때 보존된 원본 hook envelope를 독립
parser로 복구하도록 최소 수정했다. 성공하면 정확히 한 호스트 응답을 내고
종료한다. 원본도 복구할 수 없을 때의 비밀값 없는 최종 실패 응답은 유지한다.
truncation marker를 정상 문자열에 포함한 입력은 마스킹하지 않는다.

새 회귀 검사는 성공 종료·잘린 JSON을 강제로 만드는 jq wrapper, 두 호스트의
독립 기대값, 정상 marker 문자열, 실제 깊이 2,000을 검사한다. 공개 v3.7.0에는
실패하고 수정 후 jq 1.7/1.8.1/1.8.2에서 각각 4개가 통과했다. 실제 jq 1.8.1의
전체 core partition도 825 통과·0 실패였다. jq 1.6 및 고정 1.8.1 검사를 CI에
추가했다. timeout이나 기대값은 완화하지 않았다.

이 JSON 호환성 수정은 앞서 Intel의 scanner 준비 실패와 별개의 문제다.
Intel 준비 지연의 근본 원인이 밝혀졌다고 주장하지 않는다. 실험 scanner의
전체 설치 경로 교체는 계속 기각하며, 제품 채택에는 공급 출처·업데이트·복구
검증이 더 필요하다. 위 진단과 JSON 복구는 기존 계약을 유지하는 수정이므로
호환성을 깨는 v4.0.0 전환의 근거가 아니다.

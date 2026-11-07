# 회수된 CI 정확도 결과의 해석

이 문서는 실제 완료된 원시 자료만 해석한다. 전체 회수 범위와 수치는
`ci-summary.json`의 환경·scanner·config·version·variant별 group, 원시를
바꾸지 않고 붙인 사례별 설명은 `ci-analysis.json`/CSV에 있다. 아직 회수하지
않은 환경을 같은 결과라고 추정하지 않는다.

## 최초 회수: Homebrew scanner / 고정 v3.6.13 config / jq 1.7.1

`public-version-correctness-linux-homebrew-fixed`는 실제 cgroup 세 값
`200000 100000`, `1073741824`, `0`을 기록한 2 CPU/1 GiB/swap 없음 CI다.
원본 ZIP SHA-256은
`b128416d0e02c6f79354cfb38c5197f05e96495f706bd3bc2de2aa1a178b85c9`다.

기본 CLI 32개 입력 × 두 호스트의 정확도는 다음과 같았다. 아래는 케이스
통과 개수이며, 실제 사용에서의 false-positive rate 또는 민감도 추정이 아니다.

| 공개 버전 | 기본 경로 정확 기대값 일치 | 선택형 공유 core 경로 |
|---|---:|---:|
| v3.6.13 | 52/64 | N/A: 공개 선택형 fused 미지원 |
| v3.6.14 | 52/64 | N/A: 공개 선택형 fused 미지원 |
| v3.6.15 | 54/64 | N/A: 공개 선택형 fused 미지원 |
| v3.7.0 | 54/64 | N/A: 공개 선택형 fused 미지원 |
| v3.7.1 | 54/64 | N/A: 공개 선택형 fused 미지원 |
| v3.8.0 | 54/64 | 54/64 |
| v3.8.1 | 64/64 | 64/64 |

- v3.6.13/14의 추가 불일치 두 개는 두 호스트의 유효 draft snapshot 토큰
  과도 마스킹이다. v3.6.15부터 독립 기대값과 일치했다. 이는 `9a0ee9e`에
  문서화된 호환성 수정과 일치하며 이후 버전의 제품 회귀로 세지 않는다.
- v3.8.1 전 각 경로에서는 따옴표로 감싼 메시지 데이터 3종 × 두 호스트가
  차단됐다. v3.8.1 기본·선택형 경로에서는 허용됐다. `7a643f4`의 메시지
  본문 검사 수정과 일치하는 케이스별 오탐 감소다.
- 동시에 `$(env)`와 `$(set)` 합성 명령을 두 호스트가 pre-hook에서 허용하던
  네 경우는 v3.8.1에서 기대한 exit 2 차단이 됐다. 실제 shell 명령을
  실행하거나 host가 tool dispatch를 했다는 증거로 해석하지 않는다.
- 이 불일치 사례는 작업량 또는 정책 결과가 다르므로 같은 작업의 속도
  향상 계산에서 제외한다. 기본 성능 corpus의 8개 입력과도 구분한다.

## scanner 설정 오탐과 보안 대조군

위 artifact의 별도 scanner-only 13개 사례 × 7개 배포 config에서는,
unquoted `model-key.md --repo id:<lowercase UUID>` 한 사례가 v3.6.13부터
v3.8.0까지 finding으로 나왔고 v3.8.1에서 clean이 됐다. 인접 credential
문맥의 9개 양성 대조군은 모든 config에서 탐지를 유지했다. quoted repo id와
placeholder 두 종류를 포함한 나머지 clean 대조군도 유지됐다. CLI 마스킹
지연과 같은 측정으로 합치지 않는다.

나중에 회수한 Homebrew packaged-config job의 동일 32개 CLI 입력은
fixed-config job과 576조건 모두 status·stdout SHA-256·독립 기대값 판정이
일치했다. 두 job의 실제 scanner SHA-256도 동일했다. 그 조건별 증거는
`homebrew-fixed-packaged-behavior.json`에 있다. 이 32개에 Orca repo-id 입력이
포함되지 않았으므로 config 개선이 없다는 뜻으로 일반화하지 않는다.
서로 다른 CI job 사이의 동작 비교이며 지연 값을 합치지 않는다.

## 네 정확도 CI 환경의 회수 완료

공식 scanner의 fixed·packaged config도 모두 원시 자료를 회수했다. 네 환경의
주 CLI corpus는 **각각 576건**이다: 32개 입력 × 2호스트 × (7개 기본 경로 +
지원하는 2개 fused 경로). 주 corpus는 총 2,304건이며 네 환경 각각 502개
기대값 일치와 74개 기존 정책·호환성 차이를 동일하게 보였다. 위 버전별 표는
각 환경에서 독립적으로 재확인됐으며 환경 사이의 지연을 합산하지 않는다.

공식·Homebrew scanner 각각의 fixed/packaged 사이와 fixed-config 공식/실제
Homebrew 사이에서도 조건별 576개 status·stdout SHA·기대값 판정이 모두
일치했다(`ci-behavior-comparison.json`). 이는 이 입력 집합의 동작 비교다.
scanner 전체 탐지 범위가 같거나 모든 실제 입력의 false-positive rate가
같다는 뜻이 아니다.

각 scanner의 config-only 91건은 각각 85개 기대값 일치, 6개 이전 Orca repo id
오탐이었다. 각 scanner의 fault injection 20건은 각각 16개 정밀 복귀와
거짓 성공 override 4개 불일치였다. 공식 jq1.6 focused 보조 108건은 98개
기대값 일치, v3.6.13의 알려진 NUL 과도 마스킹 10개 불일치였다. 원시 stdout
framing 후검증은 네 주 환경 총 144건에서 단일 JSON 또는 빈 출력을 확인했다.

## 공식 fixed CI 작업의 도구 연결 실패

`correctness (official, fixed)` 작업 자체는 실패 상태다. workflow commit
`cb30fdb6acbb4731b2719387d3eb51f5a5871f17`에서 위 32개 주 corpus·scanner config·
fallback·jq1.6 focused를 모두 끝낸 뒤, 호출자가 새 `--suite compatibility`
인자를 주었으나 고정된 `run.py` parser에는 그 인자가 없어 exit 2였다.
제품 실패와 구분되는 벤치마크 하네스 호출자/parser 스냅샷 불일치다. 정확한
오류와 완료·미실행 범위를 `ci-tool-failure.json` 및 원본 job 로그에 보존했다.

이 실패 때문에 뒤의 기존 1,013건 native-core corpus는 그 CI에서 실행되지
않았다. 이미 완료된 주 corpus를 성공할 때까지 다시 실행하지 않는다.
printenv 보조는 별도로 완료한 로컬 자료를 유지하고, 누락된 core-only corpus만
실제 outer4CPU/16GiB의 다른 로컬 보조 환경으로 실행·표시한다. 현재 도구는
`--suite`를 지원하지만 옛 workflow 실패 자료와 pin을 바꾸지 않는다.

## 실패 복귀의 경계: 거짓 성공 helper는 다르다

Homebrew scanner를 사용한 v3.8.0/1의 격리 payload fault injection 20건 중
16건은 기대한 정밀 마스킹으로 복귀했다. prepare missing, partial+exit 2,
packaged checksum corrupt, packaged core missing의 각 두 호스트 경우다.

**`prepare-partial-success` 네 경우는 실패했다.** 사용자가 명시적으로 지정한
임의 helper에 partial plain/frame을 쓰고 `prepared-v1` 및 exit 0을 반환하도록
했을 때, 두 공개 버전·두 호스트 모두 stdout을 내지 않아 원래 합성 민감 값
`API_KEY=perf-literal-tail`을 대체하거나 차단하지 않는 CLI 결과였다. 독립
정규화는 원래 `tool_response`가 그대로 유지되는 것으로 판정한다. 실제 앱의
모델에게 값이 전달되는 세션을 실행한 것은 아니다. 정확한 원문과 기대값 불일치를
`homebrew-fallback/results.json` 및 host별 stdout/stderr에 보존했다.

이는 정상 checksum을 가진 공개 native core가 실제로 이런 출력을 냈다는
증거가 아니다. explicit override helper를 거짓 성공하도록 바꾼 fault의
범위이며, 이를 기본 경로 보안 회귀라고 일반화하지 않는다. 반대로
exit nonzero·missing 복귀 성공만으로 모든 malformed-success에 대한
안전성을 주장할 수도 없다. 성공 ack와 exit status를 신뢰하는 경계의
견고성 한계로 보고한다. 제품 변경은 이번 비교 실험 범위에 포함하지 않았다.

## 출력 framing과 미검증 범위

같은 원시 stdout에 수행한 후검증에서, 위 36개 scanner-failure(open/closed)
응답은 모두 단일 JSON 객체 또는 허용된 빈 stdout이었다. 재실행한 표본이
아니며 새 성능 표본으로 세지 않는다. 다른 scanner 환경의 같은 결과는
원시 회수 후 별도로 확인한다.

새 lifecycle event 실제 host dispatch는 N/A다. 고정 이름 `unknown-event`는
unknown tool 입력을 CLI로 보낸 경우이며, `unknown-event.ko.md`에 명확히
구분했다. main 후속 #416에서 수정한 이미 마스킹된 token의 오탐은 별도 로컬
공개 버전 시험에서 v3.8.1에도 남아 있음을 확인했으며 이 32개와 합치지 않는다.

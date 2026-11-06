# 정확도 실험의 고정 조건과 보존 기록

독립 기대값 CLI corpus는 `make_workloads.py`가 생성한다. 기존 저장소의
`native/devtools/src/contracts.rs`와 같은 대표 입력(정상 소출력, 260,000자
문자열, 여러 줄, 제어 문자, 100개 치환과 4,000개 정상 leaf)을 포함하며,
호스트 출력은 `common.py`가 Claude의 `updatedToolOutput`, Codex의 차단 및
`additionalContext`를 각각 검증한다. Codex 차단을 Claude와 같은 성공
envelope로 취급하지 않는다. pre-hook 시험은 명령을 실제 실행하지 않는다.

`run.py`는 모든 완료 표본과 표준출력·표준오류를 보존한다. 지연의 기재는
정확도 실행 진단용이며 전체 CLI 성능 측정 표본으로 재사용하지 않는다.
30초 제한을 실행 전에 고정했으며 실패를 이유로 늘리지 않는다.

## jq 1.6 보조 실행과 주 환경 선택

최초 `sanity-jq16/`의 endpoint 16건에서 v3.6.13은 정상 문자열과 placeholder도
`[REDACTED]`로 바꿨다. v3.8.1은 독립 기대값대로 정밀 마스킹했다. 이는
v3.6.14의 jq 1.6 NUL 판정 수정(커밋 `1607576`)과 일치하는 실제 차이다.
서로 다른 작업량을 속도 개선으로 합산하지 않기 위해 **주 성능 측정 전에**
jq 1.7.1을 공통 주 환경으로 선택했다. jq 1.6 결과는 별도 보조 환경이다.

`official-jq16-fixed/`는 이 선택 이후 보조 실행 범위를 줄이면서 중단했다.
완료 74건(v3.6.13의 32개 입력 × 2호스트 64건, v3.6.14 일부 10건), 진행 중
자료, 로그와 `interruption.json`을 보존했다. Docker 종료 코드 137은 실험
범위 조정에 따른 종료이며 제품 timeout이나 성공으로 재실행한 결과가 아니다.
이 부분 집합을 7개 버전 전체 결과로 제시하지 않는다.

## 측정 도구 수정 이력

1. 초기 snapshot-control의 `snapshot_token=draft-token`에 clean을 기대한 것은
   실제 예외 계약인 `snapshotToken`/`snapshot_token` 아래의 `d<n>:base64`
   형태와 달랐다. jq 1.6 보조 실행 후, 주 성능 측정 전에 문서화된 유효
   snapshot JSON으로 입력을 고쳤다. `make_workloads.v1.py`,
   `workloads.v1.json`과 보조 실행의 기존 실패 원본은 보존했다. 이 변경은
   일반 비밀 토큰을 허용하도록 제품이나 기대값을 완화한 것이 아니라,
   snapshot 호환성 검사의 대상 입력을 해당 계약에 맞춘 것이다.
2. 선택형 경로는 `OUTPUT_PIPELINE=fused`만 지정하지 않고 각 배포본의 실제
   공개 core를 `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN`에 지정한다.
   이에 앞선 sanity는 기본 경로만 실행했다. 이 선택은 공유 native core
   실험이며 소스 플러그인만 설치한 사용자의 기본 경로와 구분한다.
3. 주 정확도 실행 전에 state를 비어 있는 Git 저장소로 초기화하도록 했다.
   `git commit -m` 메시지 오탐 사례가 저장소 부재에 따른 infrastructure
   degradation을 함께 시험하지 않도록 조건을 분리했다. 이전 jq 1.6 보조
   원본은 그대로 보존했다.
4. 최초 32개 입력을 바꾸지 않고 `--suite compatibility`를 별도로 추가했다.
   고정 합성 환경변수를 인자로 조회하는 실제 `/usr/bin/printenv` 3개 사례로
   빈 값, trailing newline, 존재하지 않는 인자의 종료 상태를 검증한다.
   이는 기본 독립 corpus 및 성능 입력과 별개이다.

## 서로 다른 검증 범위

- `run.py`: 실제 공개 CLI, 공통 scanner 및 고정 v3.6.13 config. 탐지부터
  framing·마스킹·호스트 envelope까지 독립 기대값과 비교한다.
- `scanner_config.py`: 각 배포본 config와 동일 scanner. Orca UUID 오탐 감소와
  주변 credential 통제 사례를 검사한다. scanner-only 결과이므로 CLI 지연과
  합치지 않는다.
- `existing_corpus.py`: 저장소의 동결 1,013건 corpus를 최초 버전의 jq redaction
  계약과 공개 core 사이에서 비교한다. scanner나 호스트 실행 증명이 아니다.
  공개 core가 없는 버전은 N/A이다. 위 독립 기대값 검사와 별개로 제시한다.
- `fallback.py`: 공개 payload의 격리 복사본에만 prepare 실패·부분출력과
  packaged core 손상을 주입한다. 원본 배포본은 바꾸지 않는다. 실패 자료를
  보존하고 독립적인 구조·마스킹 기대값에 맞는지 확인한다.

## printenv jq 1.6 보조 결과

`official-jq16-printenv-local/`의 실제 CLI `exec /usr/bin/printenv` 3개 사례 ×
2호스트 × 7버전 = 42건에서 v3.7.0 이후의 네 공개 버전은 각각 6/6 정확한
출력과 종료 상태를 보였다. v3.6.14와 v3.6.15는 각각 0/6이며, 비밀 인자의
trailing newline 다음에 출력한 정상 public 인자가 함께 마스킹됐다.
v3.7.0에 포함된 인자 경계 수정 `ff956aa`와 일치하는 호환성 개선이다.
빈 secret 출력 및 missing argument 종료상태도 별도 사례로 유지했다.

v3.6.13의 첫 Claude trailing-newline 표본은 scanner의 내부 version 준비
2초 제한에 걸려 exit 2였다. stderr를 그대로 보존하며 다른 과도 마스킹
사례와 구분한다. runner의 30초 timeout이 아니고, 같은 표본을 다시 실행하거나
scanner의 제한시간을 늘리지 않았다. 이 실행은 실제 outer 4 CPU/16 GiB의
로컬 보조 환경이며, CI의 2 CPU/1 GiB 결과와 합치지 않는다.

`--suite masked-token`은 주 corpus 뒤에 별도로 고정한 추가 정확도 검사다.
사전 입력·기대값은 `masked-token-protocol.json`에 있다. main의 후속 수정
`b6a1c19`(#416)은 v3.8.1에 포함되지 않았으므로, 그 main을 공개 v3.8.1
대신 실행하지 않는다. 모든 공개 버전에 같은 4개 입력을 준다.

이 보조 실행은 `official-jq171-masked-token-local/`에 56건 모두 보존했다.
각 공개 버전은 4/8 기대값 일치, 4/8 오탐이었다. 두 호스트 모두 이미 완전히
마스킹된 `Token: ghu_****************************`와 `password: <redacted>`를
차단했다. 실제 모양 tail이 섞인 부분 마스킹과 real-shaped token은 각각
기대한 대로 차단했다. 따라서 v3.8.1까지 이 종류의 오탐이 줄었다고 주장하지
않는다. 이는 실제 사용자 false-positive rate가 아니라 고정 합성 4종의
케이스별 결과다.

완료된 로컬 scanner-failure 원시 출력도 재실행 없이 후검증했다.
`local-failure-framing.json`의 네 경우(2호스트 × open/closed)는 각각 단일
JSON 객체 또는 허용된 빈 stdout이었다. 이는 같은 기존 원본을 읽은 검사이며
새 성능 표본으로 세지 않는다.

실제 Claude/Codex 앱의 tool dispatch 및 사용자 모델의 행동은 이 synthetic
CLI 입력 실험만으로 검증하지 못한다. 서로 다른 결과가 생기면 같은 작업의
성능 개선에서 제외하며, 버그 수정·오탐·누락·oracle 불확실성을 나눠 설명한다.
고정 이름 `unknown-event`는 실제로 `tool_name: future_tool`을 PreToolUse CLI에
전달하는 unknown **tool** 입력이다. 새 lifecycle event를 실제 host가 어떻게
dispatch하는지까지 실행한 시험이 아니며, 그 범위는 미검증으로 남긴다.

## 별도 1/8 MiB output cap 보안 검사

`large_output.py`는 실행 전에 `official-jq171-large-output-local/protocol.json`을
고정하고, 문자 `a` 1,048,576바이트와 8,388,608바이트를 실제 `exec -- cat`으로
출력했다. 7개 기본 경로 및 v3.8.0/1의 fused 설정, 각 두 크기 총 18건은
모두 status 0과 정확히 `[REDACTED]` 한 줄을 반환했다. exec 경로는 host별
dispatch가 없어 host `none`으로 한 번씩 실행했다.

모든 요청의 `strace execve` 원본에서 native `prepare-v1`·`redact-v1` 성공
호출은 0회였다. 이 입력은 output cap에서 전체 마스킹하는 분기를 검증하며,
선택형 helper를 실제 수행한 일반 출력 마스킹 효과나 처리량으로 세지 않는다.
fused라는 환경변수 설정만으로 native 실행을 추정하지 않았다. 260k 정상
마스킹 주 사례와 이 안전 cap 사례는 서로 다른 작업이다.

출력·오류·exec trace 및 두 입력은 gzip을 다시 풀어 원래 byte와 동일함을
검증한 뒤 압축 보존했다. uncompressed/gzip SHA-256 및 크기는 각 artifact
metadata에 있다. 30초 hard timeout을 유지했고, strace가 포함된 진단 elapsed는
전체 CLI 성능 측정에 넣지 않는다. 실제 환경은 로컬 outer4CPU/16GiB jq1.7.1이다.

초기 `sanity-jq16` 원시 label `linux-jq1.6-constrained`는 cgroup 미적용이 확인되기
전 도구의 기본 문구였다. 원문은 보존하고 파생 environment를 실제
`linux-local-actual4CPU16GiB-jq1.6-sanity`로 교정했으며 이유와 원문 label은
`environment-label-correction.json` 및 파생 열에 남겼다. 이 표본이 2CPU/1GiB
제한을 충족했다고 보고하지 않는다.

## 기존 동결 core corpus 보완 완료

공식 fixed CI의 하네스 인자 불일치 때문에 실행되지 않았던 단계만
`existing-core-corpus-local/`에서 수행했다. reference 1,013건 준비에 실패가
없었고, 실제 공개 v3.7.0·v3.7.1·v3.8.0·v3.8.1 native core는 각각
1,013/1,013의 parsed JSON 일치를 보였다. v3.6.13/14/15는 공개 native binary가
없어 N/A이며 이번 시험을 위해 임의로 빌드하지 않았다.

실행 전에 원시 보존을 보강했다. corpus·기대값·원래의 core subprocess 15초
제한은 바꾸지 않았다. reference 실패도 입력·출력·오류를 보존하도록 하고,
전체 reference 1,013건과 native 4,052건의 stdout·stderr를 base64 JSONL.gz로
남겼다. gzip roundtrip 및 각 native stdout hash 4,052개를 재검증했다.
실패를 이유로 기대값을 바꾸거나 성공할 때까지 반복한 것이 아니다.

`local-core-summary.json`은 범위를 별도로 표시한다. 이것은 v3.6.13에서
추출한 기존 jq redaction 계약과 frozen corpus의 차등 검사이며, 독립
기대값을 둔 실제 CLI 32개 검사와는 다르다. scanner 준비·탐지 및 host
dispatch를 증명하지 않는다. 후속 환경 진단에서도 jq1.7.1, outer cpu.max
`400000 100000`, memory.max 16GiB, memory.swap.max `max`, 실제 host swap 없음이
확인됐으므로 CI의 2CPU/1GiB/no-swap 결과에 합치지 않는다.

이번 정확도 실행은 jq1.7.1 주 환경과 jq1.6 보조 환경이다. v3.7.1의
jq1.8.1 depth-2000 직렬화 손상 복구 자체를 재현한 시험은 아니며, 관련
코드 변경을 적는 경우 그 수정의 실제 동작까지 이번에 검증했다고 하지 않는다.
PII provider 및 실제 자격증명의 네트워크 유효성 검증도 범위 밖이다.

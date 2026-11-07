# 구성요소 별도 실측: 로컬 실제 4 CPU·16 GiB

이 결과는 주 CLI 실측과 환경·작업 범위가 다르다. 전체 CLI 개선율의 인과 기여율로 합산하거나 CI 수치에서 빼지 않는다. `cpu.max=400000 100000`, `memory.max=17179869184`, `memory.swap.max=max`였고 `/proc/swaps`에는 실제 swap 장치가 없다. 요청한 2 CPU·1 GiB·swap0 제한 실측으로 표현하지 않는다.

공개 jq1.7.1과 공개 native만 사용했다. 각 arm 2회 warmup 후9쌍 AB/BA 교대,30초 timeout을 시작 전에 고정했다. 308회 실행(워밍업56회+실측252회), 실패·기대값 불일치0회다. shell source의 jq 치환 프로그램은 v3.6.13 공개 CLI에서 그대로 추출했으며 원본·추출파일 SHA256을 보존했다. native core는 공개3.7.0/3.8.1이며 빌드하지 않았다.

|구성요소|입력|arm|지연 중앙값 ms ↓|지연 MAD ms|최소–최대 ms|자식 CPU 중앙값 ms ↓|최대 개별 자식 RSS 중앙값 MiB ↓|n/성공|
|---|---|---|---:|---:|---:|---:|---:|---:|
|prepare|long-multiline|jq|20.002|0.823|18.851–29.015|16.383|13.88|9/9|
|prepare|long-multiline|native|8.783|0.526|8.257–17.536|4.366|13.88|9/9|
|prepare|many-replacement-leaves|jq|64.187|1.169|48.058–65.356|45.330|13.62|9/9|
|prepare|many-replacement-leaves|native|3.979|0.205|3.714–8.346|2.976|13.62|9/9|
|prepare|small-clean|jq|7.493|0.285|7.204–13.623|6.422|13.38|9/9|
|prepare|small-clean|native|1.663|0.112|1.530–2.425|0.630|13.62|9/9|
|redact-v3.7.0|long-multiline|jq|23.781|0.950|21.223–25.323|19.163|13.88|9/9|
|redact-v3.7.0|long-multiline|v3.7.0|8.374|3.952|4.069–17.152|4.102|13.88|9/9|
|redact-v3.7.0|many-replacement-leaves|jq|1477.045|51.855|1422.635–1624.832|1454.210|13.62|9/9|
|redact-v3.7.0|many-replacement-leaves|v3.7.0|4.143|0.504|3.638–8.587|3.741|13.62|9/9|
|redact-v3.7.0|small-clean|jq|7.905|0.106|7.798–32.019|5.591|13.62|9/9|
|redact-v3.7.0|small-clean|v3.7.0|1.559|0.062|1.486–1.725|0.432|13.62|9/9|
|redact-v3.8.1|long-multiline|jq|22.718|1.193|20.911–24.765|18.932|13.88|9/9|
|redact-v3.8.1|long-multiline|v3.8.1|8.158|3.545|4.062–16.983|4.132|13.88|9/9|
|redact-v3.8.1|many-replacement-leaves|jq|1520.956|99.596|1367.957–1719.548|1488.334|13.62|9/9|
|redact-v3.8.1|many-replacement-leaves|v3.8.1|8.736|4.220|3.794–17.672|4.617|13.62|9/9|
|redact-v3.8.1|small-clean|jq|8.102|0.299|7.698–32.195|6.159|13.62|9/9|
|redact-v3.8.1|small-clean|v3.8.1|1.668|0.060|1.608–2.216|0.510|13.62|9/9|
|scanner-stdin|long-multiline|homebrew|196.486|6.221|179.215–256.855|188.260|38.13|9/9|
|scanner-stdin|long-multiline|official|799.791|51.884|705.727–1689.277|822.431|60.98|9/9|
|scanner-stdin|many-replacement-leaves|homebrew|218.845|53.257|114.441–526.359|185.725|38.43|9/9|
|scanner-stdin|many-replacement-leaves|official|817.521|100.939|666.276–1459.484|799.638|60.66|9/9|
|scanner-stdin|small-clean|homebrew|64.983|0.893|64.090–122.835|84.484|38.19|9/9|
|scanner-stdin|small-clean|official|665.907|45.309|617.546–740.373|663.017|60.66|9/9|
|scanner-version|none|homebrew|15.804|0.721|7.696–16.525|9.526|14.32|9/9|
|scanner-version|none|official|464.888|46.434|364.918–515.443|440.863|44.04|9/9|
|spawn|none|sh|3.687|0.131|1.552–3.957|1.628|13.62|9/9|
|spawn|none|true|3.702|0.147|1.472–3.983|1.757|13.62|9/9|

`scanner-version`은 scanner 자체 version 명령의 시작·실행이며 실제 CLI readiness의 cache 검사·watchdog 전체 시간은 아니다. `scanner-stdin`은 같은 plain 입력·v3.6.13 config를 actual official/Homebrew scanner에 각각 전달했다. 모든9쌍에서 정규화한 탐지 결과가 같았다. 여기서 Homebrew 수치는 prefix 재배치가 반영된 로컬 실행파일 hash에 한정되며 CI scanner와 absolute 성능을 합치지 않는다. official/Homebrew의 version 초기화 차이는 관측했지만 ABI·Go 빌드·정규식 backend 중 어느 요인이 차이를 만들었는지는 이 실험으로 분리 검증하지 않았다.

`prepare`는 같은 response JSON으로 jq plain 추출+framing 두 프로세스와 native prepare-v1 한 프로세스를 비교한다. 각 출력 파일의 plain/framed 바이트를 Python의 독립 기대값과 정확히 비교했다. `redact`는 같은 논리 response와 secret 배열로 jq 치환과 공개 native를 비교하며, decoded JSON이 고정 독립 기대값과 같은지 전 표본에서 검사했다. JSON 파싱·framing과 literal 치환 단계는 분리했지만 각 단계 내부 파싱 시간을 따로 분리한 것은 아니다. small-clean의 secret 배열은 비어 있으며, microbench는 그 상태의 primitive API를 의도적으로 호출한 비용이다. 실제 기본 CLI는 탐지 비밀값이 없으면 literal 치환 helper를 호출할 필요가 없으므로 이 행의 helper 속도 차이를 정상 소출력의 실제 CLI 이득으로 해석하지 않는다. 선택형 prepare와 기본 literal 치환기의 호출 조건도 다르다.

spawn의 true와 sh-colon은 서로 다른 최소 no-op 실행파일의 시작 비용 대조군이며 다른 작업에서 이를 빼지 않는다. 각 표본은 fresh Python wrapper에서 Popen 전 시계를 시작하여 입력 파이프·실제 출력 파일 쓰기·자식 종료를 포함한다. 입력파일 읽기, Python wrapper interpreter 시작, 기대값 검증·JSON/CSV 저장은 시간 밖이다. wrapper CPU는 별도 raw 필드다. maxchildRSS는 동시 RSS 합이나 고유 물리 메모리가 아니다. 이 Popen 구성은 exec 이전에 복제된 Python wrapper의 RSS도 자식 수명 최대치에 포함할 수 있다. true/sh 대조군부터 약13.6MiB이며 짧은 jq/native도 이 바닥값에 모였다. 따라서 helper 정상 실행 중 메모리나 jq/native의 메모리 동등성을 입증하지 않는다. 매우 짧은 helper에는 계측자의 프로세스 대기/스케줄링 비용 비중이 높고 wall 산포가 크므로 CPU와 함께 읽어야 한다.

[원시 JSONL](samples.jsonl) · [원시 CSV](samples.csv) · [중앙값/MAD 요약 JSON](summary.json) · [직접 구성요소 비교 JSON](comparisons.json) · [고정 프로토콜·도구해시](protocol.json) · [실제 환경](environment.json)

재현: `python runtime/components.py --lab /workspace/agent-guard-lab --jq /workspace/agent-guard-lab/component-tools/jq --out <new output directory>`


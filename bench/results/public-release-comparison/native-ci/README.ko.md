# 공개 package 정확도·실패 복귀 전용 실험

기존 성능 실험을 재실행하지 않는 별도 범위입니다. 공개 archive 7개와 공식 gitleaks 8.30.1을 동일 lock/digest/checksum으로 검증하고, 원본 정확도 실험의 15개 사례와 corpus 형태 추가 4개 사례의 입력·기대값을 바꾸지 않고 사용합니다. 각 조건은 한 번만 실행하며 timeout은 20초, 재시도는 없습니다. 지연·CPU·성능 개선율을 계산하지 않습니다.

배치 경로:

- 도구 파일: `bench/results/public-release-comparison/native-ci/`
- 워크플로: `.github/workflows/public-release-native-correctness.yml`
- 분리 브랜치: `bench/public-release-correctness-20261106`
- 결과: `bench/results/public-release-comparison/native-correctness-linux/`

Dockerfile은 성능 실험과 동일합니다. 컨테이너는 runner UID/GID로 실행하여 합성 증거 파일의 소유권이 artifact/git 수집을 막지 않도록 합니다. 실제 cgroup의 CPU 2개·RAM 1 GiB·swap 0을 확인합니다. 이 UID 조건과 공식 scanner/Linux package 경로는 macOS의 Homebrew/source plugin 정확도 조건과 분리합니다.

일반 의미 검사는 `kind=independent_semantic_accuracy`입니다. 기본 7개 버전과 지원되는 v3.8.0/v3.8.1 fused에 각각 Claude/Codex 응답 형식을 검사합니다. 공통 scanner 설정은 v3.8.0 archive의 바이트를 사용하므로 macOS 원본 정확도 실험과 같은 설정이며, 성능 실험의 v3.6.13 설정과 구분합니다. 기존 과잉 마스킹·실패도 기대값을 바꾸지 않고 보존합니다.

추가 검사는 `kind=fault_or_compatibility`로 구분합니다. 알 수 없는 tool의 PreToolUse 빈 입력은 통과, 잘못된 JSON 객체는 exit 2 거부, scanner 준비 실패는 명시한 인프라 open/closed 계약으로 검사합니다. 실제 Claude/Codex 앱이 설치되지 않았기 때문에 알 수 없는 native hook event의 host dispatch는 N/A로 남깁니다. manifest의 등록 여부만으로 host 실행 성공을 주장하지 않습니다.

`kind=separate_instrumentation`은 별도 strace 실행입니다. 기본 native 선택과 fused의 prepare/redact 실제 호출을 대표 입력에서 확인합니다. prepare 경로 누락, 잘못된 prepare 응답, redactor 경로 누락, module 누락의 복귀를 확인합니다. module 누락은 검증한 공개 설치의 별도 임시 복사본에서만 fault injection하며 제품 저장소와 원본 설치는 수정하지 않습니다. 실험 종료 시 원본 CLI/native 파일 해시가 그대로인지 확인합니다. strace 출력과 결과 원문은 보존하며 이 실행의 시간은 성능 주장에 사용하지 않습니다.

`correctness-raw.json/jsonl`은 stdout/stderr와 입력·독립 기대값·실제 응답·종료 코드·분류를 포함합니다. 정확한 출력 바이트도 SHA-256별 파일로 보존합니다. `correctness-summary.csv`, `correctness-combined-summary.json`, 원본 및 220KB 분할 JSON/JSONL이 함께 생성됩니다. 합산 요약에는 서로 다른 종류의 검사가 포함되므로 정확도 비율을 계산할 때는 `kind=independent_semantic_accuracy` 행만 사용해야 합니다. 기대값 불일치는 성능 개선으로 계산하지 않습니다.

공개 v3.8.1 확인 후 원래 6개 버전 초안은 work/native-correctness-ci-draft-six에 보존하고, 실제 공개 commit/asset을 포함한 7개 lock으로 실행 전 갱신했습니다. 공통 v3.8.0 세 정책으로 고정한 비교와 v3.8.1의 실제 bundled 정책 비교는 mode/policy_mode/config_sha256으로 구분합니다. v3.8.1 bundled-default/bundled-fused를 별도로 각각 19개 사례×2 host에 실행합니다. 공개 archive 원본 루트는 public-package-X.Y.Z로 두어 semver 디렉터리를 plugin cache로 인식하는 별도 동작을 피합니다. 대표 native/fused 호출 검증은 32개 secret 문자열과 clean 필드 1개의 고정 추가 입력을 사용하며 기존 19개 의미 검사의 기대값은 바꾸지 않습니다.

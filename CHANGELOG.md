## Unreleased

- fix(scan): `clientId`·`tokenRef`·`credential_ref`·`token_id`처럼 이름 끝이 `Id`·`Ref`·`_id`·`_ref`인 칸에 소문자 UUID 하나만 있으면 `generic-api-key` finding으로 보지 않습니다. Edit/Write 검사, 커밋 검사, `scan-path`, 출력 마스킹에 똑같이 적용됩니다. 접미사 앞 이름이 대소문자와 관계없이 `secret`이나 `secrets`로 끝나면(`secretId`, `secretRef`, `secret_ref`, `clientSecretRef`, `secret_id`) 이전과 같이 잡습니다. Vault AppRole과 Consul/Nomad의 secret id가 UUID이기 때문입니다. `SecretID`·`SECRET_ID`·`secret-id`, 대문자 UUID, 같은 줄의 다른 secret, 공급자 전용 UUID 규칙(Heroku, Snyk, HubSpot)도 그대로 잡습니다. 따옴표 UUID 뒤에 글자가 이어져 셸에서 더 긴 값이 되면 새 규칙 `agent-guard-reference-id-concatenation`이 잡습니다. 다만 secret이 아닌 참조 id의 셸 대입에서 따옴표 UUID 바로 뒤에 `,` `]` `}` 한 글자만 붙고 값이 끝나면, Python 여러 줄 키워드 인자와 구별할 수 없어 잡지 않습니다.

## v3.8.2 - 2026-11-06

- fix(hooks): heredoc 본문과 산문 placeholder를 오탐으로 막지 않는다 (#423)
- ci: PR의 Fused contracts에서 macOS Intel 잡을 뺀다 (#417)
- fix(hooks): 마스킹된 토큰 값을 secret-like 할당으로 오인하지 않는다 (#416)
- ci: bump actions/upload-artifact from 4.6.2 to 7.0.2 (#401)
- ci: bump actions/setup-go from 6.5.0 to 7.0.0 (#400)
- ci: bump actions/download-artifact from 4.3.0 to 8.0.2 (#399)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#402)
- ci: 성능 비교를 차단 조건에서 빼고 중복 잡을 줄인다 (#415)

## v3.8.1 - 2026-11-06

- fix(hooks): 메시지 본문 오탐을 줄이고 set·$(env) 환경 출력 구멍을 막는다 (#405)
- ci: PR macOS matrix를 줄이고 전체 검증 체크를 구분한다 (#408)

## v3.8.0 - 2026-11-05

### 선택형 출력 처리 통합

- 기존 core에 JSON 문자열 추출·framing을 위한 `prepare-v1`을 추가하고, private 중간 파일과 출력 처리를 통합하는 선택형 경로를 제공합니다. 전체 재작성은 아니며 탐지·scanner·정책·PII·호스트 계약은 기존 셸에 남습니다. 기본 출력 파이프라인은 바꾸지 않습니다.
- `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PIPELINE=fused`와 검증된 절대 `AGENT_GUARD_EXPERIMENTAL_OUTPUT_PREPARE_BIN`을 함께 선택합니다. 소스만 있는 Git marketplace 플러그인은 기존 `AGENT_GUARD_RUST_CORE_BIN`도 같은 바이너리로 지정해 준비·치환에 공유합니다. 두 번째 helper나 Rust 컴파일러 설치는 필요하지 않습니다. helper 실패·누락은 원래 jq 단계로, 모듈 누락은 원래 파이프라인으로 복귀합니다. 선택 설정을 지우고 호스트를 재시작하면 기본 경로로 돌아갑니다.
- Claude/Codex의 기존 설치·업데이트 명령을 유지합니다. Git marketplace 설치는 같은 릴리스의 독립 사전 빌드 core를 연결할 수 있으며 호스트 캐시를 수정할 필요가 없습니다. 신뢰하는 실행 파일 재정의 계약과 체크섬 검증 방법은 [설치 안내](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/installation.ko.md)를 참고하세요.

### 기본 경로의 수정

- 일반 문자열 출력의 framing에서 이스케이프가 없는 구간을 한 번에 처리해 긴 값의 반복 복사 비용을 줄입니다. 이스케이프가 있는 구간은 기존 상태 처리를 유지하며 제어 문자·비 UTF-8 바이트·문맥 경계·최장 일치의 독립 기대값을 검사합니다. 마스킹 범위와 scanner는 바꾸지 않습니다.
- 호스트가 절대 경로의 일반 실행 파일을 호출할 때 셸 내장 경로 처리를 사용해 시작 시 자식 프로세스 두 개를 줄입니다. 상대 경로·심볼릭 링크 체인의 기존 해석과 실제 설치 루트 선택은 유지합니다.
- 문자열 없는 상한 초과 숫자/불리언 JSON의 보수적 복귀에서 항등 변환과 큰 인자 복사를 줄입니다. 해당 ASCII 구간에만 C locale을 적용한 뒤 이전 값과 set/unset 상태를 복원합니다. 기존 327680-byte 상한, 구조·숫자 치환 기대값, 20초 조건을 유지합니다.
- 버전 확인 자식이 이미 종료됐는데 부모 처리가 지연되면 watchdog이 늦게 timeout으로 바꾸던 경합을 수정합니다. 이미 회수된 자식과 아직 회수되지 않은 zombie 상태를 구분하며, 상태 조회 실패 때는 보수적인 timeout 처리를 유지합니다. 정상 종료·실패 종료·실제 지연 자식의 전후 검사를 포함합니다. 실제로 실행 중인 scanner의 2초 제한과 open/closed 정책은 바꾸지 않습니다.
- 최초 v3.7.0 Intel 출력 불일치의 자료가 없으므로 동일 원인으로 소급 확정하지 않습니다. 후속 실제 CI에서 scanner 준비 timeout을 관측했지만, 위 경합이 모든 간헐 지연의 원인이라고 주장하지 않습니다. 공개 기준본의 진단 실패도 원시 자료에 남깁니다.

### 성능 근거와 한계

사전 실험 head `9fb3c1d`는 실제 공개 v3.7.0을 기준으로 같은 scanner·입력·설정, 실제 2CPU/1GiB/swap0에서 시작 비용 포함 9쌍 교대 측정을 수행했습니다. 두 호스트·audit 세 상태·scanner 세 종류의 378개 비교에서 독립 출력 불일치와 일반 경로 지연·CPU 5% 초과 회귀는 0이었습니다.

- stdlib 비교 빌드의 다중 문자열 목표: 지연 15.34~16.78%, CPU 13.92~15.08% 감소.
- 실제 Homebrew scanner의 같은 목표: 지연 14.07~17.05%, CPU 12.48~15.38% 감소.
- 공식 scanner의 같은 목표: 지연 2.93~5.82%, CPU 3.88~6.19% 감소. 모든 설치나 작업에 10% 개선을 주장하지 않습니다.
- Claude/Homebrew 부하 검사에서 동시 4요청 처리량은 6.02→7.34 req/s, CPU는 2.652→2.261초/8요청이었지만, 표본 RSS 합은 214.35→236.98MiB로 증가했습니다. 최대 자식 RSS와 공유 페이지를 중복 집계할 수 있는 표본 RSS 합은 구분합니다. 메모리 절감은 입증하지 않았습니다.

위 원인별 실험은 공개 redactor를 양쪽에 유지하고 prepare helper를 분리한 구성입니다. 실제 설치의 공유 core 구성도 공식/Homebrew와 audit 세 상태에서 별도로 측정하며, 독립 출력·일반 경로 회귀·Homebrew 목표 개선을 배포 관문으로 검사합니다. 숫자 fallback의 단일 진단 시간을 평균 성능으로 사용하지 않습니다. 설치 비용과 반복 사용의 손익, 실패한 후보 및 최종 설치 구성의 원시는 [상세 보고서](https://github.com/JeongJaeSoon/agent-guard/blob/codex/fused-output-evidence/bench/results/fused-output/README.ko.md)에서 구분합니다.

호환성을 깨야 할 필요성은 확인하지 못했습니다. v4.0.0을 위한 불필요한 계약 변경을 만들지 않고 선택형 기능을 v3.x에 추가합니다. 공식 scanner의 의존성 실험을 전체 설치에 적용하면 Homebrew에서 회귀하므로 scanner 일괄 교체는 계속 기각합니다.

## v3.7.1 - 2026-11-04

### 출력 복구와 진단

- jq 1.8.1처럼 깊은 JSON을 정상 종료 상태로 불완전하게 출력하는 경우, 손상된 중간 응답 대신 보존된 원본 PostToolUse 이벤트에서 복구합니다. 독립 parser가 성공하면 중첩 배열 구조를 유지하며 호스트 응답을 한 번만 출력합니다. 원본도 복구할 수 없을 때의 비밀값 없는 실패 응답은 유지합니다.
- scanner 준비 실패 경고에 `Scanner readiness: timeout.` 같은 고정 원인 코드를 추가합니다. 입력·파일 경로·scanner 원문은 포함하지 않으며 기존 시간 제한, open/closed 정책, 세션별 경고 제한을 유지합니다. timeout 코드는 실패 단계를 나타내며 간헐적 준비 지연의 근본 원인이 해결됐다는 의미는 아닙니다.
- CLI·설정·탐지·마스킹·호스트 계약과 기존 Claude/Codex 설치 방식을 유지합니다. 일반 사용자에게 Rust 또는 Go 컴파일러 설치를 요구하지 않습니다. 공개 자산의 체크섬 검증, 네 플랫폼 바이너리 선택, 셸 경로 복귀와 기존 정상 설치 보존은 v3.7.0의 계약을 유지합니다.

### 성능 실험의 범위

공식 gitleaks의 초기화 비용을 줄이는 의존성 후보를 별도 빌드하여 실제 공개 v3.7.0과 비교했습니다. 제한 자원에서 큰 개선을 확인했지만 Homebrew의 기존 backend에는 회귀가 있어 전체 설치 교체를 기각했습니다. 이 후보는 이 릴리스의 기본 scanner에 포함하지 않습니다. 실험 개선율을 v3.7.1의 사용자 성능 개선으로 해석하지 마세요. 기존 Rust 준비 후보도 목표 10% 개선에 못 미쳐 채택하지 않았습니다.

- [실험·기각 근거와 미해결 항목](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.1/bench/scanner/README.ko.md)
- [실패를 포함한 원시 측정과 체크섬](https://github.com/JeongJaeSoon/agent-guard/tree/v3.7.1/bench/results/scanner-startup)
- [검증 안내](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.1/docs/verification.ko.md)

호환성을 깨야 할 필요성은 입증되지 않았으므로 v4.0.0 전환을 추가하지 않았습니다.

## v3.7.0 - 2026-11-04

기존 CLI·설정·출력·종료 코드·마스킹 정책과 호스트 계약을 유지하면서, 검증된 문자열 치환 코어를 사전 빌드 Rust 바이너리로 제공합니다. 일반 사용자는 Rust를 설치할 필요가 없습니다. 탐지·PII·정책·호스트 어댑터는 셸에 남으며 전체 Rust 재작성이 아닙니다.

### 배포와 복구

- Linux/macOS × x64/arm64 바이너리와 SHA-256을 공개 자산 및 기존 universal archive에 포함합니다. Linux는 정적 musl이며 glibc 의존성이 없습니다. macOS 배포 대상은 14 이상이고 실제 검증 환경은 두 아키텍처 모두 macOS 15입니다. 그 밖의 OS·커널 실행까지 입증한 것으로 일반화하지 않습니다.
- 배포 아카이브와 Homebrew에서는 해당 플랫폼 바이너리의 체크섬을 확인하고 기본으로 사용합니다. 부재·손상·체크섬 불일치·실행 오류·빈/부분/복수 JSON 출력은 원래 셸/jq 경로로 복귀합니다. `AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell`은 명시적 셸 선택으로 유지합니다.
- Git marketplace 플러그인과 소스 아카이브는 바이너리가 없으므로 셸을 사용합니다. 기존 `AGENT_GUARD_RUST_CORE_BIN`으로 검증된 독립 설치의 바이너리를 지정할 수 있으며 Rust 컴파일이나 호스트 캐시 수정은 필요하지 않습니다.
- 업데이트를 기존 설치 옆에서 준비하고 검증한 뒤 같은 파일시스템에서 교체합니다. 추출·커밋·공개 링크 실패 및 INT/TERM에 대해 기존 정상 설치를 복구합니다. SIGKILL·전원 손실 때의 남은 `previous` 디렉터리 복구는 설치 안내를 따릅니다.
- 릴리스는 최종 PR head와 병합 커밋의 필수 검사 및 네 플랫폼 실제 실행·설치·성능 검증을 요구합니다. 다른 SHA의 바이너리를 발행하거나 기존 공개 자산을 덮어쓰지 않습니다.
- jq 1.6의 입력 끝 NUL 제거 때문에 `exec -- printenv`가 빈 값과 정상 값을 과도 마스킹하던 문제를 고쳤습니다. 인자 경계와 실패 시 전체 마스킹은 유지합니다.

### 측정과 범위

기본 전환 전 Linux x64의 실제 2 CPU·1 GiB·swap 없음 제한에서, 같은 입력·gitleaks 8.30.1·설정으로 시작 비용과 배포 체크섬 검증까지 포함해 측정했습니다. Claude 목표 경로 지연 22.20%·CPU 20.68%, Codex 지연 21.96%·CPU 21.06%가 개선됐고 일반 경로 지연 5% 초과 회귀는 없었습니다. 동시 작업 4개 처리량은 1.562→2.059 요청/초입니다. 이는 해당 입력·환경의 결과이며 다른 플랫폼의 성능이나 메모리 절감 입증이 아닙니다.

- [지원 조건·선택·실패 복귀](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.0/docs/native-redactor.md)
- [실측 검증 기록과 재현 방법](https://github.com/JeongJaeSoon/agent-guard/blob/v3.7.0/docs/rust-packaged-validation.ko.md)
- [새 측정 원본](https://github.com/JeongJaeSoon/agent-guard/tree/v3.7.0/bench/results/rust-packaged/qualification-30d7df8)

현재 병목만으로 호환성을 깨야 할 필요성은 입증되지 않았습니다. 영역별 후속 후보와 판단 근거를 문서화했고, 버전 번호를 위한 v4 변경은 추가하지 않았습니다.

## v3.6.15 - 2026-11-04

### 변경 사항

- **draft snapshot token 과잉 마스킹 수정**: 문서 도구의 draft 조회 결과에 들어 있는 `d<n>:` 형식의 snapshot token 을 더 이상 가리지 않고, 이 토큰을 인용한 프롬프트도 차단하지 않습니다. 다음 update 요청에 이 토큰을 그대로 보낼 수 있습니다. 면제 조건은 정확한 `snapshotToken`/`snapshot_token` 키와 해당 값 형식이 함께 맞는 경우뿐입니다. 다른 secret 키 아래의 같은 값, env 형식, 그 밖의 값 형식은 계속 가립니다. (#387)
- **Rust 배포 후보 CI**: 네 플랫폼에서 Rust 바이너리를 빌드하고 실제로 실행해 확인하는 CI 를 추가했습니다. 일반 설치 경로는 바뀌지 않습니다. (#388)
- **문서 정리**: 중복 검토 문서를 통합하고, 사용자·개발·측정 자료를 다시 구성했습니다. v3.6.14 발행과 설치 검증 근거를 반영했습니다. (#382)

## v3.6.14 - 2026-11-04

기본 셸 실행의 병목과 도구 호환성을 개선하고, 측정으로 효과를 확인한 Rust 문자열 치환기를 선택형 실험으로 추가했습니다. 일반 설치에 Rust 의존성이 추가되지 않으며 기본 마스킹 정책은 유지합니다.

### 변경 사항

- **셸 성능·프로세스 정리**: 중복 jq 처리와 불필요한 문자열 분할을 줄이고 watchdog 종료 시 남는 프로세스를 정리했습니다. (#377)
- **jq 1.6 과도 마스킹 수정**: NUL이 없는 정상 문자열까지 마스킹되던 판정을 수정했습니다. 실제 NUL이 포함된 값은 계속 보호합니다. (#379)
- **구형 awk 로그 보존 수정**: 반복 정규식을 지원하지 않는 awk에서도 기존 감사 로그 보존 정책이 적용됩니다. (#378)
- **shell 스크립트 인자 판정**: 단일 문자열 변수로 넘긴 스크립트 경로를 리터럴 경로와 동일하게 처리해 안전한 반복 실행의 오탐을 줄였습니다. `-c` 값은 코드로 검사하고 불명확한 값은 기존 closed 정책으로 차단합니다. (#385)
- **선택형 Rust 치환기**: 문자열 치환 단계만 Rust로 실행할 수 있습니다. 바이너리가 없거나 실행이 실패하면 기존 jq 경로로 복귀하고 부분 출력은 폐기합니다. 탐지기·정책·호스트 어댑터는 유지합니다. (#380)
- **개발 도구 Rust 이관**: Python 검증·측정·보고서 스크립트 10개를 Rust 명령으로 옮기고 Python 실행 의존성을 제거했습니다. 기존 입력·기대값·통계 동등성을 유지하며 Python 없는 Docker와 Linux/macOS 계약 검사를 추가했습니다. (#386)
- **측정·시각화**: 반복 측정 원시 데이터, 재현 명령, 한국어 그래프 HTML 보고서를 추가했습니다. (#381)
- **CI**: 같은 PR의 이전 실행만 취소하고 main·수동·릴리스 검증은 보존합니다. jq/awk·Rust 계약 검사를 관련 main 변경에도 실행합니다. HOL scanner를 v1.2.806으로 갱신했습니다. (#383, #364)

### 측정 결과와 적용 범위

최적화된 셸과 Rust를 같은 Docker 환경에서 비교한 결과입니다. 전체 CLI 실행 시간을 측정했으며 Rust 코어만의 속도와 구분했습니다.

| 측정 항목 | 최적화된 셸 | 선택형 Rust | 변화 |
| --- | ---: | ---: | ---: |
| Claude 다수 문자열 치환 지연 | 1,194.1 ms | 868.2 ms | 27.3% 감소 |
| 같은 경로 CPU 시간 | 1,236.4 ms | 910.8 ms | 26.3% 감소 |
| 동시 작업 4개 처리량 | 2.20 요청/초 | 3.08 요청/초 | 40.3% 증가 |
| 동시 작업 4개 표본 RSS 합 | 271.9 MiB | 281.9 MiB | 3.7% 증가 |

메모리 절감은 입증되지 않았습니다. Docker의 컨테이너별 CPU·메모리 제한은 해당 환경에서 적용되지 않았으며 양쪽은 동일한 상위 자원 한도를 공유했습니다. RSS 합은 표본 측정으로 공유 페이지 중복과 순간 최대치 누락 가능성이 있습니다. 이 수치를 모든 입력·운영체제나 전체 Rust 재작성의 효과로 일반화하지 않습니다.

### 호환성·검증

- 차등 검사 1,024건, jq 1.7.1/1.6 각각 호스트·복귀 검사 90건, 기존/Rust 출력 회귀 각각 1,018건, 단위 검사 201건을 통과했습니다.
- 기본 실행은 셸/jq입니다. 일반 사용자는 Rust를 설치할 필요가 없습니다. Rust 실험을 직접 빌드하는 개발자에게만 빌드 도구가 필요하며, 이 릴리스는 플랫폼별 Rust 바이너리를 배포하지 않습니다.
- 실험 활성화·복귀 동작: [native-redactor.md](https://github.com/JeongJaeSoon/agent-guard/blob/v3.6.14/docs/native-redactor.md)
- 그래프 HTML: [rust-performance.ko.html](https://github.com/JeongJaeSoon/agent-guard/blob/v3.6.14/docs/rust-performance.ko.html) (다운로드 후 브라우저에서 열기)
- [원시 측정값·검증 근거](https://github.com/JeongJaeSoon/agent-guard/tree/v3.6.14/bench/results/rust-experiment)

## v3.6.13 - 2026-11-03

- fix(scan): bare key 필드의 레코드 UUID를 generic-api-key 오탐에서 제외 (#375)

## v3.6.12 - 2026-11-02

- fix(hooks): grep/rg 검색 패턴과 새 openssl 출력 경로를 보호 경로 검사에서 제외 (#373)
- fix(hooks): jq filter field names no longer trip the protected-path check (#372)
- docs: 영어 정본을 유지하고 한국어·일본어 안내 추가 (#369)
- docs: 직접 계약 테스트 목록과 Makefile 도움말 정합성 정리 (#362)

## v3.6.11 - 2026-10-30

- fix(hooks): resolve commit and push in compound Bash commands (#367)

## v3.6.10 - 2026-10-30

- fix(prompt-guard): make blocked injected messages recoverable (#365)

## v3.6.9 - 2026-10-28

- perf(masking): streamline framing and reuse redaction plans (#360)
- perf(ci): parallelize navigation by host contract (#361)
- perf(hooks): reuse the gitleaks readiness verdict across hook processes (#359)

## v3.6.8 - 2026-10-27

- fix(hooks): stop reading inert here-documents and plain-word git arguments as unknown code (#357)
- Merge pull request #340 from JeongJaeSoon/codex/status-label-test-layers
- Merge remote-tracking branch 'origin/main' into codex/local-chain-integration-20261024
- Merge pull request #339 from JeongJaeSoon/codex/test-coverage-boundary
- Merge branch 'codex/local-339-integration-20261024' into codex/local-chain-integration-20261024
- test: revalidate selected locations after detector updates
- test: revalidate selected locations after detector updates
- Merge commit '0fb9d6cc2a017d57751aebe728ecf7ba72e832dd' into codex/local-chain-integration-20261024
- Merge remote-tracking branch 'origin/main' into codex/local-chain-integration-20261024
- Merge branch 'codex/test-coverage-boundary' into codex/status-label-test-layers
- docs: date the recorded coverage observation
- test: reject decision fields in fail-open prompt notices
- Merge branch 'codex/exec-raw-probe-failure' into codex/test-coverage-boundary
- Merge branch 'codex/test-coverage-boundary' into codex/status-label-test-layers
- test: assert failure diagnostics do not expose fixture secrets
- test: move status-label variants to direct classification contracts
- test: document layers and guard exec framing failures

## v3.6.7 - 2026-10-23

- fix(hooks): stop over-masking booleans, page cursors and short multibyte words (#353)
- ci: suite job の timeout を 25 分に上げる (#355)
- fix(hooks): resolve command variables in any locale, after closed parens and before builtin-named arguments (#354)

## v3.6.6 - 2026-10-23

- fix(hooks): resolve a literal command variable in the git gate (#351)
- fix(hooks): treat a bracket as a non-boundary before a spanning star (#350)
- fix: Claude の PreToolUse hook が timeout・crash したら tool 呼び出しをブロックする (#349)
- fix: inspect quoted substitutions and honor GIT_DIR in the git gate (#346)
- Merge pull request #337 from JeongJaeSoon/codex/exec-raw-probe-failure
- Merge pull request #336 from JeongJaeSoon/codex/prompt-assignment-failure-policy
- Merge branch 'codex/prompt-assignment-failure-policy' into codex/exec-raw-probe-failure
- Merge remote-tracking branch 'origin/main' into codex/prompt-assignment-failure-policy
- fix: fail closed on exec raw probe errors
- test: name synthetic assignment fixture explicitly
- fix: preserve prompt assignment probe failures

## v3.6.5 - 2026-10-22

- fix: only treat unquoted names as assignments in the git gate (#345)
- fix: follow an unquoted tilde cd target to HOME in the git gate (#344)
- fix: require a pinned letter for one-character star stand-ins in Bash path text (#343)
- test: add direct probe eligibility contracts (#335)
- perf: avoid per-character subshells in deny-path regex construction (#334)
- test: consolidate duplicated function extraction setup (#333)
- test: cover framing producer byte and failure contracts (#332)
- docs: document test layers and scoped source coverage (#329)
- test: add fast version and shell quoting contracts (#331)
- Merge pull request #327 from JeongJaeSoon/codex/ci-runtime-balance
- ci: preserve OS temporary root for permission regression fixtures
- docs: clarify preserved regression assertions and matrix check
- ci: run isolated test partitions on bounded worker bundles
- Merge remote-tracking branch 'origin/main' into codex/ci-runtime-balance
- ci: balance output coverage against latest baseline
- ci: balance test work and name suites by coverage

## v3.6.4 - 2026-10-17

- ci: bump hashgraph-online/ai-plugin-scanner-action (#312)
- fix(hooks): explain every closed block from the manifest resolver (#325)

## v3.6.3 - 2026-10-16

- ci: remove unused scanner setup and simplify validation output (#320)
- fix(pii): keep UTF-8 text out of byte-window regex matching (#322)
- fix(detection): allow source-module mentions in static prose (#321)
- fix(hooks): closed モードの遮断で毎回理由を返し、case の subject をコマンド扱いしない (#318)
- perf(redaction): avoid quadratic assembly of complete framed leaves (#323)

## v3.6.2 - 2026-10-15

- fix(detection): stop the cwd re-parse from recursing on blankless words (#316)
- fix(detection): keep env source modules readable after one static cwd change (#313)

## v3.6.1 - 2026-10-12

- MCP token 키의 `v:<n>` 버전 핸들을 불필요하게 마스킹하지 않도록 수정했습니다 (#309).
- 릴리스 발행 후 Homebrew tap 갱신 PR을 자동 생성하며, 같은 formula와 열린 PR은 재사용합니다 (#310).
- HOL 플러그인 스캐너 Action을 업데이트했습니다 (#302).

## v3.6.0 - 2026-10-11

- feat(hooks): show values the mask allow list names in the masked view (#307)
- feat(hooks): mask deny-value rule matches in the masked view (#306)
- feat(hooks): return a masked view in the block reason of a protected read (#305)
- feat(cli): add mask-file, a masked view of json, yaml, ini and dotenv files (#304)
- docs: add a sponsor line to the README (#301)

## Unreleased

- feat(hooks): in `AGENT_GUARD_DENY_READ_MODE=mask`, values whose key path matches a rule in `~/.config/agent-guard/mask-allow-keys.txt` are shown; the file must sit outside the work tree and the working directory and be private to the user, no variable can supply rules, deny-value rules and the secret scanner still win, and any refused rule or failed check keeps every value masked with a warning
- feat(hooks): in `AGENT_GUARD_DENY_READ_MODE=mask`, deny-value rules from `~/.config/agent-guard/mask-deny-values.txt` and the file `AGENT_GUARD_MASK_DENY_VALUES` names, together, replace every match with `[MASKED]`, comments included; a refused or unreadable rule, a match in a key, or a rule that runs out of time blocks with no view
- feat(hooks): `AGENT_GUARD_DENY_READ_MODE=mask` keeps blocking reads of protected files and puts a masked view of the file in the block reason for a `Read` or a plain `cat PATH`; the view is rescanned, capped at 6,144 bytes, and any failure blocks with no view
- fix(hooks): a `~/` path no longer normalizes to `$HOME/~/...`
- feat(cli): add `mask-file`, which prints a json, yaml, ini or dotenv file with its values replaced by `[MASKED]` and fails closed on anything else; `.envrc` and `*.envrc` are not supported because a shell, not a dotenv reader, reads them

## v3.5.6 - 2026-10-04

- fix(hooks): give Claude Code the block reason as JSON and stop echoing blocked prompts (#299)

## v3.5.5 - 2026-10-04

- chore: match the Action branding color to the new icon (#296)
- docs: record the demo GIF inside Claude Code (#295)
- chore(plugin): match the Codex brand color to the new icon (#293)
- docs: add the Agent Guard icon and a centered README header (#292)
- docs: re-record the demo GIF against the current CLI (#291)
- chore: add GitHub Sponsors funding link (#290)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#289)
- refactor: clean up stale comments, dead branches and drifted docs (#288)

## v3.5.4 - 2026-09-27

- fix(hooks): scan the git commit or push a git alias expands to (#286)
- test: move the shell cd tests from shard 3 to shard 4 (#285)

## v3.5.3 - 2026-09-25

- fix(hooks): check shell -c, eval and split words that hide a git commit (#283)

## v3.5.2 - 2026-09-25

- fix(hooks): scan the repository a shell cd moves git commit and push into (#276)

## v3.5.1 - 2026-09-25

- fix(hooks): decode ANSI-C quoted words before the Bash path check (#279)
- fix(hooks): let one star span several characters of a deny-read entry (#278)
- ci(test): shard tests/run.sh across a five-way CI matrix (#277)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#274)
- fix(hooks): scan changes git commit -a and pathspecs stage themselves (#275)
- docs(readme): highlight commit and push secret blocking (#273)

## v3.5.0 - 2026-09-21

- docs: remove maintainer-only documents and keep user-facing docs in English (#271)
- docs(boundaries): record function hooks (Claude Mods) compatibility probe (#270)
- fix(scan): bound git diff stderr capture at the source (#269)
- feat(scan): add AGENT_GUARD_SCAN_INPUT_MAX_BYTES and bound git diff stderr (#268)
- fix(plugin): make plugin update legible and report release staleness (#267)

## v3.4.5 - 2026-09-20

- fix: classify git diff scan-limit truncation as a size limit, not a git failure (#263)

## v3.4.4 - 2026-09-17

- fix(release): require reviewed two-phase publishing (#257)

## v3.4.3 - 2026-09-17

- ci: HOL plugin scanner action을 v1.2.678로 업데이트 (#250)
- fix: untracked 입력 상한의 SIGPIPE 오분류 수정 (#255)
- docs: 출력 마스킹 범위와 host 가정 명시 (#254)
- fix: expand Claude post-tool matchers (#253)
- fix: make gitleaks resolution deterministic (#252)
- fix: close post-tool masking fail-open paths (#251)
- fix(verification): Tie the live post-tool probe to an audit run ID and make the verification procedure self-contained (#244)

## v3.4.2 - 2026-09-14

- fix(redaction): keep content-block discriminators and pass image/PDF blocks through the output guard (#239)
- docs: support Homebrew 6 release checks (#237)

## v3.4.1 - 2026-09-11

- fix: preserve exact documentation placeholders (#235)
- Separate public and internal rollout documentation (#234)
- Add safe support log file export (#233)
- Add CLI-managed Claude and Codex plugin lifecycle (#232)

## v3.4.0 - 2026-09-11

- Prepare safe internal rollout, support logs, and portable installs (#230)

## v3.3.0 - 2026-09-10

- `PostToolUse` now scans the file a write tool just targeted, so a secret written to a gitignored path, outside the repository, into a *different* repository, or into a `skip-worktree` / `assume-unchanged` file is caught. Those were blind spots before: the working-tree backstop skips all of them (#221, #228).
- `scan-working-tree`, and therefore `/agent-guard:verify`, now covers the index as well as the worktree, both diffed against `HEAD`. Staging a secret and then restoring the file on disk no longer hides it. Content that only differs from the index — a committed secret whose staged removal is undone on disk — is still not reported, because only lines added relative to `HEAD` count (#225).
- Tier-2 PII detection (credit card, US SSN, Korean resident registration number) now requires digit boundaries and a valid Luhn checksum. Epoch-nanosecond timestamps, snowflake-style ids and other long digit runs are no longer read as card numbers, and IPv4 masking rejects out-of-range octets. `AGENT_GUARD_PII_HOOK_MODE=mask` hard-blocks Tier-2 on tool input, so this is what makes that mode usable (#217).
- New `AGENT_GUARD_PII_SKIP` turns individual **Tier-1** types (`EMAIL`, `PHONE`, `IP_ADDRESS`) off — useful when IPv4 masking hides what you are debugging. A skipped type stops being PII entirely, so `block` mode also stops blocking it; the switch is not output-only. Tier-2 names and unknown names are refused with exit 2, and it requires the built-in `regex` provider (#219).
- A Bash path block now names the `deny-read-paths` entry that matched and suggests a non-path-shaped rewrite, instead of only reporting `reason=bash_protected_path_text_match`. The gate still fails closed and no verdict changed; the matched command excerpt is deliberately not echoed, so an authenticated URL in the command cannot reach the transcript through the diagnostic (#220).
- Documentation now matches the code: `/agent-guard:verify`'s scan scope, why gitignored paths are excluded from it, how to distribute policy environment variables through managed settings and verify the value actually took effect, and what Codex managed configuration does and does not offer (#218, #222).

Existing installations need no new setup step: update the plugin and restart the session. In Codex, re-trust the hooks in **Settings > Hooks** after the update, as with any plugin change. `AGENT_GUARD_PII_HOOK_MODE` remains `off` by default; see the README before enabling it, since Tier-2 hard-blocks tool input and a small residual false-positive class remains.

## v3.2.0 - 2026-09-06

- Add an experimental, explicitly enabled pleno-anonymize PII provider with strict response validation. Remote processing remains off by default.
- Preserve standalone executable links during updates, including legacy payload directory aliases.
- Prefer the selected healthy shell cache and reject incomplete or redirected cache payloads. Existing shell integrations should rerun setup-shell after updating.
- Report unavailable direct scans with exit code 3 while preserving fail-closed execution behavior.
- Explain ambiguous Bash protected-path matches without weakening protection. Inline source expressions can still match the conservative path gate.
- Limit the setup skill to explicit invocation and clarify what host dispatch, policy denial, dependency failures, and unobserved execution can establish.
- Clean up GitHub Action scanner downloads after success, failure, and interruption.
- Reject malformed or multiple remote PII response objects and avoid echoing endpoint details in provider failures.

Use the README for installation, optional PII configuration, shell integration, and troubleshooting.

## v3.1.1 - 2026-09-04

- feat: harden multi-host installation and release flow
- fix(detection): exempt the Grep content pattern from the deny-path gate (#188)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#189)
- docs: document strict Bash path matching (#185)
- fix(redaction): mask quoted line-start assignments (#184)

## v3.1.0 - 2026-08-31

- fix: address post-merge hook regressions (#182)
- fix(redaction): accept a carriage return as an assignment delimiter (#181)
- fix(redaction): mask a KEY=value assignment inside a quoted string leaf (#179)
- fix(redaction): close the status-label display leak (#177)
- ci: remove the codex-review workflow (#176)
- feat(hooks): UserPromptSubmit prompt guard — block pasted secrets on both hosts (#173)
- feat(detection): block package-manager credential leak vectors (#172)
- fix(redaction): gate display masking on the value shape (#171)
- fix(detection): allow env source modules with an intermediate segment (#170)
- fix(setup-shell): support a fish login shell in setup and detection (#155)
- ci: bump openai/codex-action from 1.11 to 1.12 (#174)
- ci: bump hashgraph-online/ai-plugin-scanner-action from 1.2.514 to 1.2.533 (#175)
- fix(redaction): enforce short-value probe eligibility (#163)
- fix(pii): validate regex and experimental http adapters (#154)
- fix(hooks): prefix the Claude setup-skill invocation with a slash (#151)
- feat(shell)!: remove 1.x bang-guard compat flags; fail loud on unknown args (#167)
- refactor(hooks): render hook manifests from one template; dedup inline helpers (#166)
- chore(ci): cap job runtime on merge-gating workflows (#165)
- refactor(hosts): keep host-specific surfaces in sync with generic logic (#164)
- Merge pull request #161 from JeongJaeSoon/codex/env-template-filename-policy
- fix(detection): detect path-qualified cwd wrappers
- fix(detection): guard reevaluated template paths
- Merge remote-tracking branch 'origin/main' into codex/env-template-filename-policy
- Merge pull request #162 from JeongJaeSoon/codex/submission-artifact-lifecycle
- docs(submission): repin shell re-evaluation guard
- fix(detection): keep re-evaluated tokens guarded
- docs(submission): repin env template fix
- fix(detection): reject dynamic env template tokens
- fix(submission): require reviewed remote inputs
- chore(submission): repin merged env template payload
- Merge remote-tracking branch 'origin/main' into codex/env-template-filename-policy
- chore(submission): repin hardened env template payload
- fix(detection): preserve env template deny boundaries
- refactor(submission): render catalog pin after merge
- Merge pull request #153 from JeongJaeSoon/fix/display-redaction-chained-colon-labels
- chore(submission): repin env template payload
- fix(detection): handle env template filenames safely
- chore(submission): re-pin reviewed plugin payload
- Merge remote-tracking branch 'origin/main' into fix/display-redaction-chained-colon-labels
- Merge pull request #160 from JeongJaeSoon/codex/p1-invalid-toml-escape
- chore(submission): re-pin reviewed plugin payload
- fix(lockfiles): handle TOML escape boundaries
- chore(submission): re-pin reviewed plugin payload
- fix(lockfiles): reject invalid TOML escapes
- Merge pull request #157 from JeongJaeSoon/codex/p2-escaped-quote-redaction
- chore(submission): re-pin reviewed plugin payload
- test(exec): cover trailing printenv values
- fix(redaction): bound trailing printenv values
- test(exec): clarify large fixture indirection
- chore(submission): re-pin reviewed plugin payload
- test(exec): cover repeated large printenv values
- fix(redaction): bound printenv output modeling
- test(exec): keep high-cardinality probe single-shot
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): fail closed on printenv metadata
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): preserve bounded exec masking
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): guarantee whole-output fallback
- chore(submission): re-pin reviewed plugin payload
- perf(redaction): preflight oversized output
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): bound gitleaks output scanning
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): fail closed on raw temp errors
- chore(submission): re-pin reviewed plugin payload
- perf(redaction): fast-path framed assignment probes
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): fail closed across bounded output paths
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): bound all detector records
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): stream large hook output into jq
- chore(submission): re-pin reviewed plugin payload
- fix(redaction): bound high-cardinality output work
- Merge origin/main into codex/p2-escaped-quote-redaction
- Merge pull request #159 from JeongJaeSoon/codex/p1-lockfile-same-line-secrets
- chore(submission): re-pin reviewed plugin payload
- fix(detection): reject incomplete TOML state
- chore(submission): re-pin reviewed plugin payload
- fix(detection): reject malformed checksum tails
- chore(submission): re-pin reviewed plugin payload
- fix(detection): reject incomplete TOML filtering
- chore(submission): re-pin reviewed plugin payload
- fix(detection): preserve binary lockfile bytes
- Merge remote-tracking branch 'origin/main' into codex/p1-lockfile-same-line-secrets
- ci: bump hashgraph-online/ai-plugin-scanner-action (#147)
- ci: bump actions/checkout from 7.0.0 to 7.0.1 (#146)
- chore(ci): re-pin marketplace .source.sha and verify linter download checksums (#152)
- fix(detection): validate package-lock snapshots
- fix(detection): scope structural lockfile hashes
- test: assemble shared redaction fixture safely
- fix(detection): scan context-free lockfile fragments
- fix: redact short punctuated secrets safely
- fix: preserve byte-exact output redaction
- test: clarify printenv fixture indirection
- fix: preserve exact exec redaction output
- fix: redact multiline secrets per output leaf
- fix(detection): parse structural lockfile fields
- test(redact): construct secret fixtures at runtime
- fix(detection): scan beside lockfile checksums
- fix(redact): mask through escaped quotes
- fix(redact): mask secrets behind non-status colon labels
- fix(detection): narrow lockfile checksums and output redaction (#145)
- fix(runtime): keep Agent Guard stable across plugin upgrades (#143)
- fix(security): scan-accuracy + shell-parsing hardening batch (#125-#134)
- Add a host-neutral setup-shell workflow for Codex (#144)

## v3.0.1 - 2026-07-22

- fix: handle sandboxed Agent Guard setup (#141)
- docs: surface the setup skill as a Claude Code entry point (#135)
- fix(hooks): report a scan that could not run distinctly from a detection (#137)
- fix(security): close verified scan bypasses + finish v3.0.0 release (#124)

## Unreleased

- fix(hooks): treat malformed `UserPromptSubmit` JSON as an infrastructure
  failure instead of collapsing a failed `jq` extraction into an empty prompt.
  The opt-in closed policy now blocks; the default open policy emits one
  host-shaped degradation notice.
- fix(shell): when SessionStart still receives a fish `$SHELL`, require both
  `.bashrc` and `.zshrc` managed blocks to remain loadable. The host snapshot may
  choose either shell, so one surviving rc can no longer silence the warning
  while the other snapshot path is unprotected.
- fix(redaction): limit the `:` equals-assignment delimiter to the quoted string
  leaf it was added for. Serialized output such as
  `{"log":"API_KEY=<value>"}` still masks, while valid compact source such as
  the JavaScript labelled statement `label:API_KEY=config.apiKey;` is preserved
  on display and accepted by the prompt guard.
- fix(redaction): accept a carriage return as an assignment delimiter. A `\r`
  before the key hid the assignment completely, on display and at the prompt
  guard, so a secret printed after a progress meter, a spinner, or on
  classic-Mac line endings reached the model in full and was not blocked when
  pasted back:

  ```
    0 12.3M    0 16384    0     0  50000      0\rAPI_KEY=<secret>   ->  no rewrite
  ```

  `\r` is a delimiter for the same reason it is edge whitespace on the value
  side: it separates fields on screen and belongs to neither. It joins the
  leading class of both assignment forms and of the status-label test, so the
  prose chain the status allowlist protects (`error: password: authentication
  is disabled`) is now recognised after a carriage return too — previously the
  label went unseen there and the prose was masked. Measured against the
  previous release commit over 2,518 carriage-return shapes: 357 real leaks
  closed, 6 false-positive prose masks removed, and every other newly masked
  case byte-identical to what that commit already produced with a space in the
  same position. The status guard in `scan_line` tests the delimiter character
  directly and had to agree: with the carriage return between the label and the
  key (`error:\rpassword: <prose>`) the colon assignment matches at the CR, and
  while that check accepted only space and tab the label went unrecognised and
  the prose was masked.
- fix(redaction): mask a `KEY=value` assignment inside a quoted string leaf
  (#178). The ordinary shape of a tool that returns a serialized log —
  `{"log":"starting with API_KEY=<value>"}` — reached the model in full on the
  heuristic path. Two causes, both needed. The enclosing string's own closing
  quote rode along on the value token, and `looks_like_reference()` tests for an
  embedded quote without position, so a terminator at the very end marked the
  token a nested reference and skipped it; a single trailing quote is now
  stripped the way trailing `}`/`]`/`)` already were, and only when the
  assignment does not itself begin with a quote, so the line-start re-scan of a
  value an outer quoted assignment already claimed cannot emit a narrower
  mapping that beats it. And `:` was not accepted as the delimiter before a
  quoted key, so the JSON form never matched at all — it joins the class away
  from `[`, since `[:` opens a POSIX character class and invalidates the whole
  regex. Credential-handling source code is unchanged: `os.environ["DB_PASSWORD"]`
  and `ENV.fetch("SESSION_KEY")` keep interior quotes and stay references.
  Display redaction and the prompt guard; the block/detect path is unchanged.
  The strip stops at the redaction sentinel: `password=[REDACTED]"` would
  otherwise lose the `]` that belongs to the marker, so `[REDACTED` was
  re-emitted as a secret and a stray `]` appended — compounding on every pass
  and making the prompt guard block text Agent Guard had itself redacted.
  A trailing carriage return is skipped as edge whitespace, so CRLF output —
  Windows tools, PowerShell, Docker and CI logs — masks the same shape it
  does on LF; the carriage return itself is preserved.
- fix(redaction): close the status-label display-redaction leak (#156). The
  seven-word status allowlist (`error`, `warning`, `info`, `note`, `debug`,
  `fatal`, `hint`) let a secret that gitleaks does not recognise reach the model
  unmasked whenever it sat behind one of those labels — `error: password:
  <value>` and `warning: db_password: <value>` were displayed in full. The label
  cannot settle it, because it is identical in the prose chain the allowlist
  exists to protect (`error: password: authentication is disabled`), so the
  VALUE now decides: a token whose shape reads as a credential (a digit beside a
  letter, an uppercase run starting past the first character, or a single-case
  alphabetic run longer than any ordinary word) masks, while a word, path,
  number, clock time or date stays visible. The chained shape
  (`response: error: api_key: <value>`) is covered by the same gate. Display
  redaction only; the block/detect path is unchanged. An unterminated quoted
  value (truncated output) is captured and classified when the leaf ends rather
  than skipped, so a credential-shaped one still masks. A captured value is recorded in
  both its literal and its edge-trimmed form, so a bare recurrence of a
  credential that was padded or split across a newline behind its label
  masks as well. Residual: an
  all-lowercase alphabetic secret shorter than 24 characters is indistinguishable
  from a prose word on this path and stays visible.
- docs: record why the deny-read Bash gate is NOT narrowed (#99). `echo
  foo.key`, `echo see also foo.pem` and `jq -r .key data.json` are reported as
  `blocked shell command referencing a deny-listed path` although nothing is
  read and no such file exists. A command-position narrowing that dropped word
  operands of commands which take no file operands was written, measured and
  removed again: every revision of it let a real read through. A newline or `&`
  starts another command, `|` hands the dropped word to `xargs cat`, a path- or
  quote-qualified name resolves to a different program than the one compared, an
  external binary resolves through PATH at execution time so a wrapper inherits
  the exception, and an exported Bash function named `echo` or `printf` beats
  the builtin — so even a builtin name does not identify what will run. A text
  gate that cannot name the program cannot safely drop its operands. #99 stays
  open as an accepted false positive; the counter-examples are pinned as tests
  so any re-attempt has to answer them.
- fix(hooks): drop the undefined `\"` escape from the shell-parser awk bracket
  expression (#99). gawk warned `regexp escape sequence \" is not a known
  regexp operator` on every `hook-pre-tool` run, including runs that passed. The
  class already contains a literal backslash via `\\`, so it is unchanged.
- ci: remove the `codex-review` workflow. It has never produced a review in
  this repository: with no `OPENAI_API_KEY` Actions secret every step is
  skipped, the job reports success in a few seconds, and the feedback job is
  skipped for an empty message — so it read as a passing check while doing
  nothing. Codex review on pull requests comes from the ChatGPT Codex GitHub
  app and is unaffected. Dropping the workflow also stops Dependabot raising
  version bumps for an action that never runs; the README section documenting
  it is removed with it.
- feat(detection): extend the env template marker vocabulary with `tpl`/`tmpl`
  and accept `-`/`_` marker separators (`.env-example`, `.env_sample`,
  `.env.tpl`), matching the naming conventions measured on GitHub. The marker
  must still be final and the stem must stay an env family; `.env.default(s)`
  stays blocked because dotenv-defaults loads it at runtime.
- fix(detection): allow env source modules that carry exactly one intermediate
  segment between the `env`/`envrc` stem and a code extension, so ordinary
  committed files such as `env.d.ts`, `env.server.ts`, `env.config.ts`, and `env.spec.ts`
  are readable on both the Read and Bash gates. The final extension must still
  be code: data/config suffixes (`env.json`, `env.local.json`), extension-less
  names (`env.d`), the leading-dot runtime form (`.env.d.ts`), deny-listed
  ancestors, and custom deny policies all stay authoritative.
- feat(detection): block package-manager credential leak vectors. Deny-read now
  covers Bundler (`.bundle/config`), RubyGems (`.gem/credentials` and the XDG
  `gem/credentials` location), Cargo (`.cargo/credentials*`), Composer home
  `auth.json`, Maven `.m2/settings.xml`, Gradle `.gradle/gradle.properties`,
  `pip.conf`, Poetry `pypoetry/auth.toml`, and Terraform CLI credentials
  (`.terraformrc`/`terraform.rc`). Deny-bash now blocks credential dump
  commands that print stored auth with no path or token in the command text:
  `bundle config` reads (bare/`list`/`get`/legacy dotted-key read; `set` stays
  allowed and is gitleaks-scanned), `npm config get` of protected keys,
  `yarn config get` of npmAuthToken/npmAuthIdent (and the registry/scope maps
  that nest them), `git credential fill`/any-helper `get`, `pip config
  list|get`, `composer config` on credential keys or `--list`,
  `mvn help:effective-settings -DshowPasswords`, and
  `security find-(generic|internet)-password`; `gcloud auth
  print-refresh-token` joins the existing gcloud token alternation. The
  command patterns are hardened against realistic variants an agent may emit:
  tool aliases (`bundler`, `npm c`/`npm get`), version-suffixed binaries
  (`pip3.12`), leading global options between a binary and its subcommand
  (`npm --location=user config get`, `bundle config --parseable`,
  `bundle --verbose config`, `security -q`, `gcloud --quiet`), Composer's
  documented `global <command>` wrapper, which runs the same config read
  against COMPOSER_HOME where the stored OAuth token lives
  (`composer global config`), wrapper/PHAR invocation forms (`./mvnw`,
  `php composer.phar`), the direct `git-credential-<helper> get` executable,
  `pip config debug`, and `$(...)` subshell prefixes; pnpm `config list`
  (which, unlike npm, does not mask) is blocked, and coverage extends to
  pnpm/bun. The `mvn` and `composer` patterns are anchored so prose/filenames,
  value tokens like `repositories.bearer`, and the `showPasswords=false` safe
  default do not over-block. Adds deny-read for Bun's `.bunfig.toml`; uv and
  pnpm need no new path (env/.netrc and `.npmrc` respectively already cover
  them).
- feat(hooks): add a `UserPromptSubmit` prompt guard on both hosts. Secrets
  pasted into the user prompt (gitleaks rules or `KEY=value` assignment
  heuristic) are blocked before submission by default.
  `AGENT_GUARD_PROMPT_GUARD_MODE` selects `block` (default), `mask` (reserved;
  degrades to block because neither host lets a hook rewrite the submitted
  prompt), `warn` (pass through with a host-shaped visible notice), or `off`.
  The PII input gate (`AGENT_GUARD_PII_HOOK_MODE`) applies to prompts
  independently of the secret mode, and an invalid PII mode now fails loud on
  the prompt path too. `read_stdin` uses `cat` when available and prompts over
  the shared scan cap skip the super-linear assignment probe (gitleaks still
  applies; the skip follows `AGENT_GUARD_INFRA_FAILURE_MODE`), so a large
  pasted prompt cannot burn the host hook timeout into a silent fail-open.
  A prompt-path infrastructure notice is folded into the same response object
  as the mode-specific message: a hook may write only one top-level JSON
  document, and emitting the notice separately left two concatenated objects
  that a host parsing stdout as one document rejects, dropping the warning.
  The privacy policy now discloses that with the experimental
  `AGENT_GUARD_PII_PROVIDER=http` adapter in `AGENT_GUARD_PII_HOOK_MODE=block`,
  the complete text of every submitted prompt — not just tool-input text —
  is sent to `AGENT_GUARD_PII_REDACT_URL`.

- fix(detection): allow explicitly named env templates such as `sample.env`,
  `example.envrc`, `.flaskenv.example`, and `.dev.vars.example`, while blocking
  reverse/runtime forms including `local.env`, `env.local`, `env.preview`, and
  template-looking names whose final suffix is a runtime or backup marker;
  preserve custom/non-environment deny precedence and deny-listed ancestors,
  accept safely quoted Bash template paths, and keep source modules such as
  `config.env.ts` readable without opening `schema.env.json` data files.
- fix(runtime): keep plugin hooks and Claude shell integration on the
  version-independent `current/bin/agent-guard` path. Each plugin execution
  refreshes `current`, while hook and shell entrypoints fall back to the newest
  installed semantic version when symlinks are unavailable.
- test(hooks): lock in commit/push staged scans from the tool payload's target
  work directory, including linked worktrees and hook processes launched from
  a different sandbox cwd, so stale-runtime regressions cannot reintroduce the
  Codex block.
- fix(runtime): unify scanner-infrastructure failures behind
  `AGENT_GUARD_INFRA_FAILURE_MODE=open|closed` (default `open`). Hooks, `agx`,
  and transparent Claude command wrapping now warn once per session and follow
  the same selected policy; actual secret detections still always block.
- fix(detection): allow recognized checksum fields in `go.sum`,
  `package-lock.json`, `yarn.lock`, `Cargo.lock`, and `uv.lock` only when both
  the lockfile path and checksum-line shape match. Other lockfile content,
  including embedded credentials, remains scannable.
- fix(redaction): mask only the value token of a complete secret-bearing
  assignment. Metadata keys such as `password_policy`, prose such as
  `error: password: ...`, and text adjacent to a real value are preserved.
  Suffix-qualified credential keys (`AWS_SECRET_ACCESS_KEY_ID`,
  `API_KEY_VALUE`, `DB_PASSWORD_HASH`) and whitespace-prefixed colon
  assignments in log lines still mask.
- fix(pii): make the accepted PII provider values explicit (#52).

  `regex` remains the supported, local default. `http` is an experimental
  bring-your-own-endpoint adapter with no service-specific compatibility
  guarantee. Any other value fails closed instead of falling through to
  pass-through output. Existing endpoint-backed configurations that fail
  provider validation should set `AGENT_GUARD_PII_PROVIDER=http` and keep their
  existing `AGENT_GUARD_PII_REDACT_URL`. Rejected values are now reported
  exactly once.

- fix(hooks): prefix the Claude Code setup-skill invocation with a slash
  (#151). The degraded-session warning told Claude Code users to run
  `agent-guard:setup-agent-guard`; pasted verbatim that is ordinary prompt
  text, not a skill invocation. Claude Code exposes a plugin skill on the
  slash-command surface as `/plugin:skill`, which is how this plugin already
  writes its sibling skill `/agent-guard:setup-shell`. The degraded message
  and every Claude-facing doc reference now use `/agent-guard:setup-agent-guard`.
  The Codex form `$setup-agent-guard` is unchanged.

- fix(setup-shell): support a fish login shell and stop the permanent
  "command wrapping is not loaded" false positive (#139). The marker
  `AGENT_GUARD_SHELL_INIT_VERSION` only reaches `SessionStart` through the
  environment of the shell that *launched* the agent, so a fish (or other
  non-POSIX) login shell — and any GUI/IDE launcher — could never satisfy it,
  even though the agent's own bash/zsh shell snapshot did load the wrapping from
  the same rc. `SessionStart` now reads the managed rc block on disk before
  reporting missing setup, and checks that it can still *load* — the delimiters
  alone prove nothing, because the block's `eval` emits neither the wrapping nor
  the marker once the binary it resolves is gone. It replays the block's own
  resolution order (baked stable path, newest versioned plugin-cache binary,
  `agent-guard` on `$PATH`) with `stat`-level checks only: silent when setup
  demonstrably ran and still resolves (only the version-drift comparison is
  lost), the usual setup guidance when the block is absent, and a distinct
  `can no longer load` warning when the block is present but resolves nothing
  (cache updated, uninstalled, hand-edited) — that state leaves command output
  unmasked, so it must never be silent. `setup-shell` additionally writes the
  managed block to **both** `~/.bashrc` and `~/.zshrc` when either the process
  `$SHELL` or the account login shell is fish. Account lookup uses `getent
  passwd` on Linux and `dscl UserShell` on macOS, with a non-fatal process-shell
  fallback; this covers the standard skill path where Claude's Bash tool reports
  zsh even though passwd reports fish. The CLI also says plainly that no
  automatic `agx` or nudge exists at a fish prompt and prints an executable path
  for plugin-only installs where bare `agent-guard` is not on `PATH`. No
  fish-syntax marker is written or faked: claiming protection fish cannot
  provide would be worse than the warning it replaces.
- fix(hooks): report a scan that could not run distinctly from a detection
  (#137). A scanner precondition failure and a real detection previously looked
  identical — both printed and exited 2 — so an operator could not tell whether
  agent-guard had found something in their staged changes or had never managed
  to look. The message names the directory and the action instead of an internal
  subcommand; hook handling now follows the infrastructure policy above.

  CLI behaviour change: `agent-guard scan-staged` and `agent-guard
  scan-working-tree` invoked outside a git work tree now exit **3** rather than
  2. Everything in this repo treats non-zero as failure (the native pre-commit
  hook, the `make` targets, the verify command), so no consumer changes — but
  scripts that test for exactly 2 should be updated. Direct scan commands and
  native Git hooks still treat every non-zero result as uncleared.

## v3.0.0 - 2026-07-19

- feat!: simplify managed deployment to settings merge plus developer setup (#122)

Breaking changes (see the [upgrade guidance](README.md#upgrading-older-installations)):

- Removed the `managed-install.sh` entrypoint and the self-contained
  `managed-bootstrap.sh`, including the `managed-bootstrap.sh` /
  `managed-bootstrap.sh.sha256` release assets.
- Removed the Codex managed hook path (`deployment/codex-hook`,
  `deployment/codex-requirements.toml.template`); Codex users install the
  plugin through the standard install.
- Removed `setup-shell --prepend-path`.

## v2.2.0 - 2026-07-18

- feat: add self-contained managed bootstrap (#119)

## v2.1.0 - 2026-07-18

- feat: add managed deployment for Claude Code and Codex (#117)
- docs: pin community submission source (#116)
- docs: prepare Claude marketplace submission review (#115)
- docs: lead quick start with Claude Code and Codex (#54)
- ci: bump hashgraph-online/ai-plugin-scanner-action from 1.2.286 to 1.2.484 (#111)
- ci: bump openai/codex-action from 1.9 to 1.11 (#107)

## v2.0.1 - 2026-07-17

- fix(hooks): scan `NotebookEdit` cell content so secrets written to notebook cells are blocked (and PII when `AGENT_GUARD_PII_HOOK_MODE=block`) (#112)

## v2.0.0 - 2026-07-14

- feat(shell)!: make Claude command wrapping stable and default-on, with `--no-command-wrapping` and `AGENT_GUARD_COMMAND_WRAPPING=off` opt-outs
- feat(install): enable command wrapping from direct bootstrap and add `/agent-guard:setup-shell` for plugin installs
- docs: add the 1.x to 2.x migration guide and move GitHub Action examples to the preserved `v2` release line
- ci(release): verify publishing `v2` does not move the existing `v1` compatibility tag

## v1.10.1 - 2026-07-14

- fix(codex): verify the plugin-local binary, hook trust, and live host dispatch during guided setup
- fix(codex): use harmless dedicated sentinels for live PreToolUse and PostToolUse probes
- docs(codex): document wrapping-tool boundaries and require pre/post live probes
- fix(shell): mask bare `printenv NAME` values with their variable-name context

## v1.10.0 - 2026-07-13

- feat(codex): add guided dependency setup and host-native hook responses
- feat(shell): graduate the Claude bang-command guard to a supported opt-in

## v1.9.0 - 2026-07-07

- feat(plugin): warn on version drift between plugin hooks and the shell-integration CLI (#104)
- feat(bench): per-channel leak-prevention benchmark (#90)

## v1.8.0 - 2026-07-06

- feat(detection): catch low-entropy vendor-prefixed tokens by shape alone (#101)
- feat(detection): allow dotenv-style template files via suffix rule (#100)

## v1.7.1 - 2026-07-03

- fix(shell): make setup-shell rc line self-healing when the CLI leaves $PATH (#96)

## v1.7.0 - 2026-07-02

- feat(shell): resolve agent-guard without a PATH install for the bang guard (#94)

## v1.6.0 - 2026-07-02

- feat(shell): experimental opt-in bang-command guard (#92)

## v1.5.0 - 2026-07-01

- feat(shell): mask ! shell-escape output via agent-guard exec + shell-init (#86)
- feat(detection): broaden output secret recall (JWT, bearer, more env keys) (#85)

## v1.4.0 - 2026-07-01

- test: harden tests/run.sh temp files with mktemp (CWE-377) (#82)
- chore(changelog): drop stale Unreleased block ahead of v1.4.0 (#81)
- ci: bump actions/github-script from 7.1.0 to 9.0.0 (#71)
- ci: bump actions/checkout from 5.0.1 to 7.0.0 (#74)
- ci: bump openai/codex-action from 1.8 to 1.9 (#76)
- ci: bump hashgraph-online/ai-plugin-scanner-action (#75)
- docs: document shell-escape hook-bypass blind spot (#80)
- feat(agent-guard): mask PII in tool output via mask mode (#78)
- feat(agent-guard): mask secret-like values in tool output (#77)
- docs(readme): lead with a Claude Code quick start to lift install conversion (#73)
- feat(plugin): add Codex composer icon for Agent Guard (#72)
- ci: add HOL plugin scanner self-scan and harden CI workflows (#68)

## v1.3.8 - 2026-06-16

- docs: separate demo steps with blank lines for readability (#66)
- docs: render README badges in a single row (#65)

## v1.3.7 - 2026-06-16

- feat(agent-guard): rename Action to a unique GitHub Marketplace name (#63)

## v1.3.6 - 2026-06-16

- feat(agent-guard): unify positioning + Action branding for Marketplace publish (#61)
- fix(agent-guard): close fail-open gaps in hook input handling and deny-read Bash scan (#60)
- fix(agent-guard): calibrate secret-detection patterns (#59)

## v1.3.5 - 2026-05-24

- Merge pull request #57 from JeongJaeSoon/codex/plugin-layout-validation-ci
- Normalize plugin validation workflow names
- Tighten plugin root variable validation
- Split plugin layout validation steps
- Add plugin layout validation CI
- Merge pull request #56 from JeongJaeSoon/codex/codex-claude-plugin-hooks
- Align Codex hooks with plugin layout
- Use host-specific plugin hooks
- Improve Codex and Claude plugin hook compatibility
- feat: add PII filtering provider adapters (#51)
- [codex] Harden agent tool input scanning (#49)
- [codex] Add Codex code review workflow (#55)
- fix install hook quoting and docs

## v1.3.4 - 2026-05-09

- docs: clarify codex plugin hook setup (#46)
- ci: use checkout v5 (#45)

## v1.3.3 - 2026-05-09

- fix: include install script in release tarball (#43)

## v1.3.2 - 2026-05-09

- Fix real user install and verification flows
- simplify: narrow PostToolUse matcher, dedupe deny-read path, guard gitleaks version drift (#40)
- docs: fix v1 raw URL for gitleaks-checksum.sh after plugin restructure (#39)

## v1.2.1 - 2026-05-08

- fix(cli): follow symlinks when resolving SCRIPT_DIR (#34)

## v1.2.0 - 2026-05-08

- docs: restructure README around user task flow (#32)
- feat: add gitleaks-checksum helper (script + subcommand + slash command) (#31)
- refactor: simplify bin/agent-guard helper functions (#30)

## v1.1.2 - 2026-05-07

- feat(plugin): add /agent-guard:verify slash command (#26)
- chore(release): make release.yml idempotent on re-dispatch (#25)
- fix(release): bump VERSION constant in bin/agent-guard on release (#24)

## v1.1.1 - 2026-05-07

- Revert "chore(release): v1.1.1 (#20)" (#22)
- fix(release): build tarball outside the directory being archived (#21)

## v1.1.0 - 2026-05-07

- Revert "chore(release): v1.1.0 (#15)" (#17)
- fix(release): exclude tarball self-reference from tar input (#16)

## v1.0.2 - 2026-05-07

- fix(release): pick latest semver tag, ignore moving major tag (#10)
- chore(release): also bump marketplace.json plugin version (#9)
- docs: add Quickstart section with plugin install paths (#8)

## v1.0.1 - 2026-05-07

- chore(release): add automated release workflow (#5)
- simplify: remove scan_text_hook, fix sub-shell exit, drop make doctor, optimize deny-pattern checks (#4)
- chore: usability and robustness pass (#3)
- [codex] Add CI and clean public-readiness scan noise (#2)
- Harden against Bash/path bypass, Codex patch parsing, symlink, and action injection (#1)


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

### 실제 출하 커밋의 성능과 설치 비용

실제 릴리스 커밋 `f295e1a6727b674713a52134dd576f7cd2272131`을 공개 v3.7.0과 비교했습니다. 동일 scanner 바이트·입력·설정, 실제 2CPU/1GiB/swap0에서 CLI 시작 비용을 포함해 각 9쌍 교대 측정했습니다. 선택형 공유 core의 252개 비교(4,536회 CLI)에서 독립 출력 불일치 0, 일반 경로 지연·CPU 5% 초과 회귀 0입니다. 기본 출력 경로는 별도로 검증했고 그대로 유지합니다.

| 선택형 출력 통합 / 같은 scanner 내 비교 | 목표 지연 감소 | 목표 CPU 감소 |
|---|---:|---:|
| 실제 Homebrew scanner | 15.56~16.86% | 14.09~15.26% |
| 공식 scanner | 4.23~7.71% | 3.90~6.90% |

공식 scanner는 10% 목표에 미달합니다. 모든 사용자 작업이나 네 플랫폼 모두에 같은 성능 개선을 주장하지 않습니다. Claude/Homebrew의 4동시 요청 처리량은 4.493→5.338 req/s, CPU는 3.601→2.978초/8요청이었습니다. 최대 자식 RSS는 39.828→39.965MiB, 표본 RSS 합은 214.551→238.055MiB로 증가했습니다. 공유 페이지 중복 집계와 짧은 피크 누락 가능성이 있는 표본 합이며, 메모리 절감은 입증하지 않았습니다.

실제 공개 v3.7.0/v3.8.0 bootstrap의 컴파일러 없는 새 설치 9쌍에서는 지연 중앙값 0.637→0.640초, CPU 0.681→0.688초, 최대 자식 RSS 44.672→44.477MiB였습니다. 설치 파일은 3,494,569→3,539,549 bytes(+1.29%), archive는 1,927,563→1,948,006 bytes(+1.06%)입니다. 로컬 4CPU/16GiB에서 네트워크·Docker 시작·의존성 최초 설치를 제외한 비용이며 작은 시간/RSS 차이를 개선으로 주장하지 않습니다. 소스 Git 플러그인만 쓰던 사람이 문서대로 독립 설치를 새로 연결하면 약 3.54MB 전체 설치를 추가하는 것이므로 기존 packaged 사용자의 증가분과 구분해야 합니다.

### 배포 검증과 한계

최종 PR head `c3cfb40`와 실제 merge `f295e1a`의 필수 CI 8개가 각각 성공한 후 발행했습니다. 네 플랫폼의 native 실행·설치·업데이트·실패 복귀·정상 설치 보존을 검증했고, 공개 15개 자산·SHA-256·정확한 main 빌드 출처와 archive/core 일치를 확인했습니다. 기존 v1 태그는 유지합니다.

[Homebrew PR #26](https://github.com/JeongJaeSoon/homebrew-tap/pull/26)은 exact head의 audit·실제 install·brew test 성공 후 병합했습니다. 공개 태그의 [실제 배포 검증](https://github.com/JeongJaeSoon/agent-guard/actions/runs/42104857774)도 첫 실행에서 Linux/macOS x64/ARM 직접 설치 4개와 Homebrew 3환경 모두 성공했습니다. 각 환경에서 공유 core·소스 플러그인·부분 실패 복귀·설정 해제 16개 계약을 확인했습니다. 사용자 Rust 컴파일러는 필요하지 않습니다.

최초 v3.7.0 Intel 불일치는 원본 fixture/stdout/stderr가 없어 여전히 원인 미확정입니다. 후속 경합 수정이나 반복 검증 성공을 최초 사건의 원인 해결로 간주하지 않습니다. 호환성을 깨야 할 필요성은 입증되지 않아 기존 Claude/Codex 설치·업데이트 방식과 셸 복귀를 유지하는 v3.8.0으로 제공합니다.

[채택·기각 후보, 최종 비교와 실패를 포함한 원시 기록](https://github.com/JeongJaeSoon/agent-guard/blob/9569b81167c96d12a8a9ca8e3c2c8b05866f6a55/bench/results/fused-output/README.ko.md) · [선택형 기능 적용·복구 안내](https://github.com/JeongJaeSoon/agent-guard/blob/v3.8.0/docs/installation.ko.md)

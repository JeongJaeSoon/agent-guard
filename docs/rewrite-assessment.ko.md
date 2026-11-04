# agent-guard 재작성 타당성 검토

2026-11-04 내부 검토. 검토 기준은 `c81699ed2a368e0a4fefadca6446c7bc5c9734cd`의
구조이며, 같은 작업에서 수행하는 셸 성능 개선과 별도로 판단했다.
이 문서는 신규 한국어 검토 문서이며 기존 영어 문서의 번역본이 아니다.

> 후속 구현·실측 결과는 [Rust 성능 그래프 보고서](rust-performance.ko.html)에 정리했다.
> 아래 내용은 구현 전 타당성 검토 기록이다.

## 판단

현재 구조는 **단기 셸 최적화와 중기 native 코어 실험을 병행할 가치가 있다.**
Rust로 전면 재작성하면 빨라진다는 결론을 내릴 측정 근거는 아직 없다.
배포본을 즉시 교체하기보다 출력 탐지·치환 경로 하나를 동일 동작으로 옮겨
측정한 뒤 확대 여부를 결정하는 것이 적절하다. 이 검토에서는 native 구현을
작성하거나 실행하지 않았으므로 언어별 지연·메모리 수치를 추정해 제시하지 않는다.

우선 후보는 Rust의 단발 실행 코어다. 입력 바이트와 JSON 값을 구분해 다루고,
작업량·메모리·하위 프로세스 수명을 명시적으로 제어하기에 적합하다.
유지보수 인력이 Go에 더 익숙하다면 Go도 충분히 합리적인 후보다.
실제 이득은 언어 이름보다 JSON 재파싱, 프로세스 생성, 중간 파일을 한 실행 안으로
합칠 수 있는지에 달려 있다. scanner와 저장소 scan 비용은 그대로 남는다.
같은 작업의 [실측·수정 결과](runtime-review.ko.md)에서는 출력의 특정 hotspot은
셸 개선으로 줄었지만, 정상 Bash 명령의 다수 syscall 시도와 exec capture의
메모리 제약은 남았다. 이는 단계적 코어 실험의 근거이며 Rust 자체의 성능 증거는 아니다.

## 코드에서 확인한 구조와 제약

| 영역 | 현재 구현과 근거 | 재작성에 주는 의미 |
| --- | --- | --- |
| 진입점 | `plugins/agent-guard/bin/agent-guard`: 약 13,500줄의 POSIX 셸, 설치·관리·정책·호스트 응답·마스킹을 함께 포함 | 관리 명령과 매 hook의 실행 경로를 구분할 필요가 있음. 파일 크기만으로 성능 병목을 단정할 수 없음 |
| 출력 탐지 | `detect_output_secret_records`, `detect_output_secret_bundle`, `classify_secret_bundle`: jq/awk/grep, 여러 임시 파일, scanner JSON report를 거쳐 shell 변수에 재적재 | 단일 native 실행으로 합치기 좋은 첫 경계. scanner 규칙은 외부 gitleaks로 유지 |
| 문자열 처리 | `frame_json_string_leaves`, `secretish_env_values`, `redact_tool_response_json` | RS/US 프레이밍, leaf별 상태, contextual 우선·긴 literal 우선 순서까지 동작 계약 |
| 명령 분석 | `git_gate_records`, `is_git_commit_or_push`, deny-path helper군 | 셸 quote·변수·alias·cwd·Git 환경 해석이 정책과 결합돼 있음. 일반 shell parser를 넣는 것만으로 기존 정책과 같아지지 않음 |
| 장애 경계 | `run_gitleaks_stdin`, `hook_dependencies_ready`, `handle_hook_infrastructure_failure` | 정상·탐지·실행 불가를 별도 상태로 유지. plugin 기본 open/설정 closed와 native Git hook의 정책을 혼합하면 안 됨 |
| 호스트 출력 | `emit_post_tool_replacement` | Claude는 `updatedToolOutput`, Codex는 block와 sanitized `additionalContext`. 공통 JSON envelope 하나로 합치면 계약 위반 |
| 설치/업데이트 | `plugin_cache_root_usable`, `shell_init_resolver`, 생성 hook의 `root_ok` | 실행 파일을 텍스트로 읽어 `VERSION=`를 찾음. ELF/Mach-O로 파일을 단순 교체하면 정상 plugin 선택이 실패할 수 있음 |
| 테스트 | `tests/helpers/extract-functions.sh`, `tests/selected-bash-locations.json`, `native/devtools/src/verification.rs` | 함수 본문 추출·해시 기반 단위 검증은 native 구현을 검증하지 못함. 실행 파일 경계의 fixture도 필요 |

관련 파일은 [CLI](../plugins/agent-guard/bin/agent-guard),
[hook 생성기](../scripts/render-hook-manifests.sh),
[배포 tarball 생성기](../scripts/build-release-tarball.sh),
[회귀 테스트](../tests/run.sh), [마스킹 측정기](../native/devtools/src/measure.rs)다.
함수 이름을 근거로 사용했으며 이후 편집으로 달라질 수 있는 줄 번호는 고정하지 않았다.

## 언어별 비교

| 선택 | 기대 효과 | 추가 비용과 위험 | 적합한 사용 |
| --- | --- | --- | --- |
| 기존 셸 개선 | 신규 실행 의존성 없이 프로세스·파싱 중복 감소. 배포와 현 fixture 재사용이 쉬움 | 데이터 구조·오류 전파·바이트 처리의 복잡성이 계속 증가. 전체 capture 뒤 적용하는 cap은 capture 메모리를 제한하지 않음 | 즉시 개선과 회귀 기준 확보 |
| Rust 코어 | 단발 프로세스 안에서 JSON·바이트·치환 계획 재사용. 소유권과 명시적 예산을 활용 가능 | macOS/Linux × x64/arm64 빌드·서명/체크섬·release 지원 필요. jq/awk/grep 의미를 직접 재현해야 함 | 동일 동작의 출력 처리 코어 실험 우선 후보 |
| Go 코어 | JSON·프로세스·파일 처리 표준 라이브러리, 배포 바이너리와 개발 생산성. gitleaks와 같은 언어 | GC/런타임 비용은 실측 필요. gitleaks 라이브러리 결합은 외부 CLI 유지보다 버전·설정·report 동등성 검증 범위가 큼 | Go 운영 경험이 강한 팀의 대안 |
| Python/Node | 구현·테스트 생산성, 풍부한 parser | 현재 runtime 요구사항에 인터프리터와 배포·버전 관리를 추가. 시작 비용·메모리 개선 보장 없음 | 개발용 측정·fixture 생성·차등 검증 도구 |

Rust의 일반 `regex`는 jq의 Oniguruma와 같은 기능 집합이 아니다. gitleaks의
Go 정규식과 jq/grep의 정규식을 하나의 Rust 정규식으로 단순 통합하면 탐지 결과가
달라질 수 있다. parser를 교체할 때는 duplicate JSON key 처리, 숫자 표현,
Unicode escape·surrogate, 최대 깊이, invalid UTF-8, 문자열 순회 순서도 확인해야 한다.
보호 대상이 동일해도 정밀 치환 순서가 바뀌면 과잉 마스킹이 생길 수 있다.

gitleaks를 새 언어의 탐지기로 함께 교체하거나 rule을 재해석하는 작업은 첫 실험에서
제외한다. 기존 scanner의 버전·설정·결과를 고정해야 출력 처리 자체의 개선을 구분할 수 있다.
Go에서 gitleaks를 라이브러리로 넣는 방안도 별도 단계의 실험으로 취급한다.

## 먼저 유지해야 할 계약

- 탐지 여부뿐 아니라 **어떤 값이 어느 위치에서 얼마나 치환되는지** 일치해야 한다.
  정상 제어군의 통과, contextual/ordinary 우선순위, 긴 literal 우선, 동률 순서를 유지한다.
- object key와 protocol discriminator 보존, leaf 사이의 할당 상태 격리,
  RS/US·NUL·줄 끝·invalid UTF-8의 기존 처리와 conservative fallback을 유지한다.
- 기존 작업량 cap을 더 빨리 돌리기 위해 낮추거나 높이지 않는다. 현재 raw 출력 cap
  327,680바이트, bundle 256레코드/65,536바이트, 정밀 치환 작업량 8,000,000 등의
  경계 전후를 검증한다. 이 cap들은 하위 프로세스의 wall-clock timeout이 아니다.
- 부분 scanner report, 파서/임시 파일/디스크 오류를 정상 빈 결과로 바꾸지 않는다.
  감춰야 하는 오류 출력에 원문 secret을 기록하지 않는다.
- 알 수 없는 이벤트는 기존의 안전한 pass-through를 유지한다. 알려진 이벤트의
  인프라 장애 정책과 혼동하지 않는다.
- `exec`는 기존 command 종료 코드, stdout/stderr 결합, trailing newline 처리까지
  비교한다. 현재 shell 변수 capture 특성을 바꾸는 것은 별도의 호환성 변경이다.
- scanner readiness cache의 identity·TTL·권한·네이티브 실행 파일 검증을 유지한다.
  언어 변경을 이유로 캐시 검증이나 프로세스 그룹 종료를 생략하지 않는다.

## 권장 전환 순서

1. **실행 파일 경계의 기준 corpus 고정.** 작은 정상 출력, 각 secret 종류,
   많은 leaf/규칙, 제어 문자, 빈 값, malformed JSON, 제한 경계, scanner 실패,
   두 호스트 envelope, Git backstop을 포함한다. 기존 정확한 기대값 fixture를
   재사용하고 실제 scanner 기반 coverage도 함께 고정한다.
2. **기존 구현에서 프로세스 수와 파싱 중복을 줄인다.** 이 결과를 새 baseline으로
   삼는다. 기존 불필요한 비용을 남긴 채 native 언어와 비교하지 않는다.
3. **별도 opt-in native 출력 코어를 만든다.** 셸 launcher는 `VERSION=`와 현재
   경로 선택을 유지하고, 고정된 plugin payload의 native 코어를 호출한다.
   `PATH` 검색이나 명령 문자열 `eval`로 코어를 찾지 않는다. 설치·관리와 Git/Bash
   정책은 유지한다. core/launcher 버전과 protocol version을 함께 확인한다.
4. **동일 입력으로 오프라인 차등 검증한다.** stdout의 masking 위치·envelope와
   exit code를 비교한다. JSON key 순서처럼 정책과 무관한 직렬화 차이는 명시적으로만
   정규화한다. 감사 timestamp/run id의 허용 차이를 개별 지정한다. 기존 전용 failpoint와
   별개로 native allocation/I/O/child failure도 주입한다.
5. **배포·롤백을 준비한 뒤 제한적으로 활성화한다.** 지원 네 플랫폼의 release artifact,
   checksum, 권한, plugin payload 완전성, native core 누락/불일치, 오래된 launcher,
   업데이트 중단, rollback을 검증한다. helper 실패 후 부분 출력을 내보내지 말고
   기존 정책의 실패 처리로 이동한다. 초기에는 기존 구현이 기본이다.
6. **측정 기준을 충족할 때 확대한다.** 출력 코어가 안정화된 뒤 명령 분석·Git policy
   이전 여부를 따로 결정한다. scanner 내장화·daemon 도입·언어 변경을 한 번에 하지 않는다.

상주 daemon은 첫 전환안에 권장하지 않는다. hook 간 secret 보관 기간, IPC 인증,
권한·세션 격리, 장애 복구, upgrade 시 rule 혼용이라는 새로운 운영 책임이 생긴다.
단발 실행만으로 목표를 충족하는지 먼저 확인한다.

## 실험의 통과 기준과 측정 방법

보안·호환성 통과 기준은 corpus의 허용되지 않은 차이 **0개**다. 보호율 평균이
같다는 것만으로 통과시키지 않는다. 정상 입력의 추가 마스킹과 기존 secret의
노출을 모두 실패로 취급한다. `tests/run.sh`, 직접 단위 계약, 실제 gitleaks의
`smoke-test`, 실제 coverage benchmark를 통과해야 한다. 기존 소스 추출 테스트는
셸에 유지하고 native 코어에는 동일 fixture를 실행 파일 경계에서 적용한다.

성능 실험은 동일 scanner·config·OS·CPU에서 후보 실행 순서를 번갈아 수행한다.
프로세스 시작을 포함한 wall time, user/system CPU, peak RSS의 측정 정의,
하위 프로세스 수, 임시 파일 수/bytes를 함께 기록한다. readiness cache와 audit의
cold/warm 조건, PII off/regex/endpoint 조건을 구분한다. 실제 운영 목표가
동시 hook 부하라면 단일 호출 측정 후 별도 동시성 실험을 추가한다.

자식 프로세스의 CPU를 누락한 값이나 `RUSAGE_CHILDREN` 누적 high-water RSS를
동시 프로세스 트리 peak로 표시하지 않는다. 단일 프로세스 peak RSS 최대값과
트리 전체 메모리는 다른 지표다. 충분한 표본 없이 최댓값을 p95로 부르지 않는다.
현재 마스킹 측정기의 소수 반복은 중앙값·최댓값 비교에 사용하고, tail latency는
별도 반복 실험으로 확인한다. 성능 측정 중 전체 회귀 테스트를 같이 돌리지 않는다.

채택할 성능 목표는 실험 전에 합의해 고정한다. 예를 들어 작은 정상 출력과 주요
큰 입력에서 모두 유의미하게 빨라지고, CPU·메모리 또는 배포 비용의 악화가 없을
때 채택하는 방식이다. 구체적 배율은 native 구현과 환경별 실측이 나온 뒤에만
보고한다. scanner/저장소 scan이 지배하면 전체 지연 개선은 제한될 수 있다.

## 현재 메모리 제한에서 별도로 다룰 부분

`do_exec`는 `out=$("$@" 2>&1)`로 전체 출력을 먼저 보관한 뒤 scan cap을 적용한다.
따라서 cap은 scanner·치환 작업량은 제한하지만 명령 출력 capture 메모리를 제한하지
않는다. 여러 JSON/shell 변수와 임시 파일 사본도 동시에 존재할 수 있다.
이는 코드에서 확인되는 구조적 제약이며 이번 검토에서 메모리 상한을 실측했다는 뜻은 아니다.

native 코어 실험에서는 자식 출력을 private spool에 받아 기존 cap 초과 여부를
확인하면서 메모리 복제를 줄일 수 있다. 그러나 단순히 pipe를 닫거나 명령을 죽이면
원래 명령의 종료 코드·부수 효과가 달라진다. 출력 수집은 계속하되 cap 이후 원문을
폐기하고 기존 보수적 마스킹으로 귀결시키는 설계를 따로 검증해야 한다.
PII와 redaction off 설정, stderr 결합, binary/NUL과 trailing newline 호환성도
포함한다. 이런 구조 개선은 Rust/Go 모두 가능하며 전면 재작성의 전제는 아니다.

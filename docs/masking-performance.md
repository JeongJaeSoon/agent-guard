# 마스킹 성능과 처리 단계

마스킹 지연은 입력 바이트 수뿐 아니라 줄바꿈, 제어 문자, 문자열 leaf 수,
치환 규칙 수에 따라 달라진다. `bench/masking-latency.py`는 이 입력 형태를
분리해서 측정하고, **각 측정에서 마스킹 결과까지 검증**한다.
탐지를 생략하거나 제한값을 낮춰서 얻은 단축은 아니다.

## 처리 단계와 책임

| 단계 | 구현 | 비용을 줄인 방법 | 유지하는 계약 |
| --- | --- | --- | --- |
| 문자열 leaf 프레이밍 | `frame_json_string_leaves` | RS/US 이스케이프를 정규식 `gsub` 대신 literal `split`/`join`으로 처리 | US를 먼저 이스케이프하고 RS를 처리하며, leaf마다 RS와 개행을 붙임 |
| 프레임 해석과 할당 탐지 | `secretish_env_values` | 물리 줄을 한 번 분할하고 일반 바이트 구간을 통째로 결합 | RS/US, pending escape, 여러 줄 인용 값, leaf 간 격리를 기존 byte decoder가 처리 |
| 탐지 결과 수집 | `detect_output_secret_records`, `bundle_secret_records` | 기존 경로 유지 | gitleaks, 할당 heuristic, JWT/Bearer 탐지를 합치고 실패를 빈 정상 결과로 취급하지 않음 |
| 치환 계획 준비 | `redact_tool_response_json`의 `prepare_specs` | 응답당 한 번 분류·정렬하고 모든 leaf에서 재사용 | contextual 규칙 우선, 각 그룹의 긴 literal 우선 및 동률 순서 유지 |
| 치환과 호스트 응답 | `redact_tool_response_json`, `redact_tool_output`, `do_exec` | 기존 호스트 계약 유지 | JSON key와 protocol discriminator 보존, 실패·작업량 초과 시 기존 보수적 마스킹 유지 |

기존 제한은 그대로다. 출력 scan cap은 327,680바이트이며, 큰 JSON 응답의
할당 probe는 262,144바이트를 넘으면 적용된다. secret bundle은 최대 256개
레코드와 65,536바이트로 제한하고, 정밀 치환은 규칙 수와 문자열 작업량의
곱 8,000,000을 넘으면 보수적 치환으로 전환한다. JSON 크기와 원문 크기는
이스케이프 때문에 다를 수 있다. 이 값들은 시간 초과를 보장하는 wall-clock
timeout이 아니다.

## 재현 방법

필요한 도구는 Python 3, `jq`, 실제 `gitleaks`다. Python은 개발용 측정 도구에만
사용하며 배포 CLI에는 새 의존성을 추가하지 않는다.

```sh
make bench-masking
python3 bench/masking-latency.py --baseline /absolute/path/to/baseline/bin/agent-guard --runs 5
```

기준 실행 파일은 같은 버전의 전체 plugin payload와 함께 두어야 한다. 측정은
현재 checkout의 동일한 gitleaks 설정과 지정한 scanner를 양쪽에 적용한다.
`--scanner /absolute/path/to/gitleaks`로 scanner를 고정할 수 있다.

합성 입력만 사용하고 Git 저장소 밖의 임시 디렉터리에서 실행한다. audit logging과
그에 연결된 readiness cache, PII 마스킹은 꺼서 secret masking 경로를 비교한다.
PostToolUse 출력은 Claude 응답 계약으로 고정하고 `exec`도 별도로 측정한다.
Codex 호스트 계약의 정확성은 전체 fixture 검증에서 확인한다.
기준과 후보의 실행 순서를 번갈아 사용하며, 매번 exit status와 정확한 마스킹
결과를 확인한다. 시간 초과나 결과 불일치는 성공 표본에 포함하지 않고 실패한다.
출력 JSON에는 실행 파일 SHA-256, scanner 버전, OS, 모든 표본과 중앙값·최댓값이
포함된다. 진행 메시지에는 입력 내용이나 탐지된 값이 포함되지 않는다.

이 측정은 CLI 프로세스 시작과 scanner readiness 확인을 포함한 로컬 실행 시간이다.
다른 테스트·벤치마크와 동시에 실행하지 않는다. 소수 표본의 최댓값을 p95라고
부르지 않으며, 결과를 hosted CI 시간이나 실제 Claude/Codex 세션의 지연으로
대체하지 않는다. scanner 자체의 장시간 실행이나 원격 PII 서비스의 지연까지
해결했다는 의미도 아니다.

## 로컬 전후 측정

2026-10-28, macOS 26.5.2 arm64, 실제 gitleaks 8.30.1에서 기준 `907e6db`와
수정 실행 파일을 비교했다. 다른 테스트 실행을 멈춘 뒤 각 입력·버전당 5회,
총 80회 실행했고 모두 정확한 기대 출력과 일치했다.

| 입력 형태 | 기준 중앙값 | 수정 중앙값 | 수정 최댓값 | 중앙값 기준 배율 |
| --- | ---: | ---: | ---: | ---: |
| 작은 정상 출력 | 0.219s | 0.221s | 0.239s | 0.99× |
| 긴 단일 줄 | 0.551s | 0.560s | 0.566s | 0.98× |
| 긴 여러 줄 | 4.847s | 0.568s | 0.572s | 8.53× |
| 긴 줄 안의 RS | 4.871s | 0.565s | 0.589s | 8.62× |
| 8,000줄 출력 | 2.392s | 0.741s | 0.754s | 3.23× |
| 100개 규칙, 4,100개 leaf | 1.491s | 1.013s | 1.019s | 1.47× |
| US가 많은 약 280KB JSON | 12.078s | 1.303s | 1.379s | 9.27× |
| exec의 긴 여러 줄 | 4.588s | 0.370s | 0.383s | 12.41× |

작은 정상 출력과 긴 단일 줄은 사실상 같은 수준이며, 큰 개선은 기존의 느린
프레이밍 경로에서 나타났다. 제어 문자가 많은 입력의 보수적 전체 leaf 치환을
포함해 기준·수정 버전의 결과가 동일하다. 이 표는 로컬 합성 재현 사례의
측정이며 hosted runner나 실제 사용자 세션의 SLO 보장은 아니다.

측정한 수정 실행 파일의 SHA-256:

```text
61c689022b685064dda8f9c4257a00f8c609425cdbfc89c31ca013c620b2ad8b
```

## 회귀 검증

- `tests/unit-framing.sh`: 독립적으로 지정한 기대 바이트로 producer를 검증한다.
- `tests/framed-leaves.sh`: bulk append만 끈 기존 byte decoder와 JSON/framed/probe
  모드를 비교한다. 긴 여러 줄, RS/US, 빈 leaf, pending escape, 잘린 인용 값,
  비 UTF-8 바이트, producer 실패를 포함한다.
- `tests/redaction-plan.sh`: contextual/ordinary 순서, 긴 literal 우선, 동률,
  여러 leaf, 빈 literal, protocol shape, 기존 레코드 예산을 검증한다.
- `tests/run.sh`: 기존 전체 호스트·CLI·실제 scanner 회귀 검증을 유지한다.

`tests/selected-bash-locations.json`은 변경된 함수의 해시만 갱신하며 관측 대상
라인의 분모를 늘리거나 줄이지 않는다. 해당 관측은 AWK 내부 branch coverage가
아니며, 프레이밍·치환 fixture와 전체 통합 테스트를 대신하지 않는다.

### 이번 로컬 검증의 결과와 환경 차이

최초 전체 `tests/run.sh` 실행 결과는 **2,507 통과, 8 실패**였다. 원인과 재검증은 다음과 같다.

| 실패 | 원인 | 재검증 |
| --- | --- | --- |
| 상대 `HOME` 뒤 `cd ~` 사례 6개 | fixture는 Bash 3.2의 동작을 가정하지만 로컬 PATH는 Bash 5.3.9를 선택함 | 기존 실제 hook·Bash·Git helper로 해당 6개를 기본 Bash 3.2에서 재실행하여 기준 `907e6db`와 수정 버전 모두 6/6 통과 |
| native scanner 캐시 사례 1개 | Homebrew scanner의 mode 555가 fixture 복사본에 보존되어 재덮어쓰기 `cp`가 실패함 | 같은 native 실행 파일의 쓰기 가능한 임시 복사본으로 기존 cache suite 22/22 통과 |
| 부분 프레이밍 실패 주입 1개 | jq mock이 이전 `gsub` 표현만 찾아 새 프레이밍 단계에 실패를 주입하지 못함 | selector를 프레임 경계 literal에 맞춰 수정하고 원본 실패 주입 구간 9/9 통과 |

이후 기본 Bash 3.2와 쓰기 가능한 임시 gitleaks 8.30.1 복사본을 우선하는
PATH로 모든 기존 partition을 다시 실행했다. 각 실행은 별도 TMPDIR를 사용했고,
최대 세 partition을 동시에 실행했다. **전체 2,515개 통과, 실패 0개**였으며
다섯 프로세스의 종료 코드는 모두 0이었다. 실행 전후 주요 실행·테스트 파일
해시가 같고, source의 partition 집합과 실행된 집합이 정확히 1–5로 일치했다.

| Partition | 통과 | 실패 |
| --- | ---: | ---: |
| Core | 677 | 0 |
| Command policies | 182 | 0 |
| Host adapters and Git | 278 | 0 |
| Scanner and output | 1,000 | 0 |
| Shell navigation | 378 | 0 |

`make test-unit`, 실제 gitleaks 8.30.1의 `make smoke-test`, 저장소 전체 secret
scan, ShellCheck(error), actionlint도 통과했다. 이 로컬 전체 검증은 CI wall time
단축률의 증거가 아니다. 로컬의 알려진 환경 차이를 테스트 생략이나 기대값 완화로
처리하지 않았다.

최초 hosted 후보 `1ff1122`의 [CI run 40623642319](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40623642319)에서는
Linux 2,511개와 macOS 2,436개가 통과했고 모든 실패 집계는 0이었다. 실제
gitleaks의 RSA private key 탐지 assertion과 `smoke-test ok`, 두 aggregate의
`SHARDS_RESULT: success`도 로그에서 확인했다. OS별 수 차이는 기존 실제 scanner
검증과 플랫폼별 사례 차이다. 이 결과는 CI 배치 변경을 함께 포함한 당시 후보의
검증 기록이다. 마스킹 전용 변경은 main의 기존 CI 배치를 유지하고, 실행 파일은
위 SHA-256 그대로다. 분리된 마스킹 후보의 단독 CI 결과는
[JeongJaeSoon/agent-guard#360](https://github.com/JeongJaeSoon/agent-guard/pull/360)에서 추적한다.
CI 호스트별 병렬 실행은 독립적인
[JeongJaeSoon/agent-guard#361](https://github.com/JeongJaeSoon/agent-guard/pull/361)에서 다룬다.

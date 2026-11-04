# agent-guard 성능·구조 점검

2026-11-04 내부 검토. 기준 소스는 `c81699ed2a368e0a4fefadca6446c7bc5c9734cd`다.
새 한국어 작업 기록이며 기존 영어 문서의 번역본이 아니다.

## 적용한 개선

| 변경 | 이유 | 보존하는 동작 |
| --- | --- | --- |
| watchdog timer 종료 후 강제 종료·`wait` | 종전 TERM handler는 timer를 죽인 뒤 회수하지 않아, 자식을 회수하지 않는 PID 1 아래서 좀비가 누적됨 | version probe의 2초 제한, scanner process group 정리, 정상/인프라 실패 구분. timer가 TERM을 무시해도 cleanup이 기다리며 멈추지 않음 |
| scanner report 검증·추출을 한 jq 호출로 통합 | 동일 JSON report 재파싱과 프로세스 생성 한 번 제거 | slurp 뒤 빈 문서/비-array 검증, 비어 있지 않은 문자열 Secret만 수집, 부분 출력은 임시 파일에 격리하고 실패 시 폐기 |
| ordinary 치환에 `contains` 선행 검사 | 해당 literal이 없는 leaf에서도 split/join 배열을 반복 생성하던 비용 감소 | contextual 우선, 긴 literal 우선, 동률 순서, literal 치환, 키·protocol discriminator 보존 |
| plaintext framing의 record 단위 치환 | 입력 바이트마다 awk 함수·printf를 호출하던 비용 감소 | US 먼저, RS 다음 escape; LF 처리, invalid UTF-8, 종료 RS와 실패 status 유지 |

탐지 정규식, allow/deny 정책, PII 기본값, secret bundle 제한, scan cap,
치환 작업량 제한, 호스트별 실패 정책은 변경하지 않았다. 파일을 나누는 작업만으로
성능이 좋아진다고 보지 않았고, 배포 CLI에 실행 의존성도 추가하지 않았다.

## 구조 점검과 후속 우선순위

| 경계 | 확인 결과와 판단 |
| --- | --- |
| 정책과 호스트 | CLI가 정책을 소유하고 어댑터가 호스트 envelope를 만드는 기존 경계를 유지. Claude와 Codex의 출력 계약을 하나로 통합하지 않음 |
| 탐지와 치환 | gitleaks, 할당 heuristic, JWT/Bearer 결과를 bundle로 합치는 경계는 유효. 반복 JSON 파싱·shell 변수 복제·중간 파일을 줄이는 출력 코어가 다음 구조 개선 후보 |
| 필터링 정확성 | 정상 prose, placeholder, metadata와 실제 credential을 구분하는 기존 gate를 유지. 무조건적인 keyword 확대나 allowlist 완화는 하지 않음 |
| 실패 처리 | scanner/parser/temp-file 오류와 정상 빈 결과를 구분하는 atomic staging을 유지. 고카디널리티·제어 문자·부분 변환 실패의 conservative fallback을 유지 |
| 프로세스 수명 | 이번에 timer 회수 누락 수정. 별도의 scanner session/group과 timeout 처리의 통합 테스트는 계속 필요 |
| 메모리 예산 | `exec`의 `out=$(...)`는 전체 출력을 먼저 담는다. 327,680바이트 cap은 scanner/치환 작업 예산이며 capture 메모리 상한이 아님. 입력 JSON과 여러 변수·임시 파일 사본도 남음 |
| Bash/Git 분석 | quote, cwd, alias, 환경 변수, Git index 의미가 결합됨. 일반 parser 교체만으로 호환성을 보장할 수 없어 첫 native 이전 대상에서 제외 |
| 설치·업데이트 | `VERSION=`를 텍스트로 읽는 resolver가 있으므로 기존 CLI를 ELF/Mach-O로 단순 교체할 수 없음. 셸 launcher와 버전이 고정된 코어를 분리해야 함 |

capture 개선은 후속 작업으로 분리한다. private spool 또는 cap 이후 discard를
도입하더라도 자식 명령을 조기에 죽이거나 pipe를 닫아 종료 코드·부수 효과를
바꾸면 안 된다. redaction off, PII-only, binary와 trailing newline 계약도
포함해야 하므로 이번 최적화에 함께 섞지 않았다.

이 점검은 실제 호스트 세션 전체나 모든 셸 문법의 안전성을 증명하는 검증이 아니다.
object key, binary payload, 호스트의 hook 미발생 채널 등 기존 보호 범위의 한계도
없어진 것이 아니다. 기존 fixture와 실제 scanner의 측정 결과를 구분해 읽어야 한다.

## 재현과 측정 정의

기준 실행 파일은 같은 버전의 전체 plugin payload를 보존한 복사본으로 사용한다.
실제 gitleaks 8.30.1 Linux x64 배포 archive의 SHA-256은 저장소 CI의
`551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb`와
일치하는 것을 확인했다. 양쪽에 같은 scanner와 설정 파일을 적용한다.

```sh
sh scripts/devtools.sh masking-latency \
  --baseline /absolute/path/to/baseline/plugins/agent-guard/bin/agent-guard \
  --scanner /absolute/path/to/gitleaks --runs 5 \
  --resources --include-boundaries --trace-processes
```

합성 입력만 사용하며 audit/readiness cache와 PII는 끈다. 기준/후보 순서를
번갈아 실행하고 매 호출의 종료 코드와 정확한 출력 기대값을 확인한다.
정상 입력은 빈 hook 출력 또는 변경 없는 exec 출력이어야 한다. 변환한 leaf의
원래 secret이 사라졌는지만 확인하는 방식이 아니라 전체 기대값과 비교한다.

보존된 아래 측정은 Python 도구로 실행했다. 현재 Rust 도구의
`--resources`도 표본마다 새 worker를 사용해 이전 표본의
`RUSAGE_CHILDREN` high-water mark가 섞이지 않게 한다. 보고하는 wall time은
worker 초기화 이후 CLI 실행 구간이며, worker 시작 시간은 제외한다.
새 Rust 도구의 smoke 수치를 과거 성능 수치와 섞지 않는다.
CPU는 회수된 CLI와 하위 프로세스의 user/system 시간이다.
`max_child_peak_rss_kib`는 자식의 개별 peak RSS 최대값이며 **동시 process tree의
메모리 합계가 아니다.** Linux와 macOS의 RSS 단위를 KiB로 정규화한다.

`--trace-processes`는 Linux strace 별도 호출에서 exec/프로세스/스레드 생성
syscall 시도 횟수를 기록한다. 실패한 syscall도 포함하며 프로세스 수의 실측값과
혼동하지 않는다. trace 호출은 성능 표본에서 제외하고 출력은 동일하게 검증한다.
raw trace에는 합성 입력만 들어가며 임시 디렉터리와 함께 삭제한다.
ptrace가 제한된 환경에서는 별도 실행 권한이 필요하거나 이 옵션을 빼야 한다.

전체 회귀 테스트와 성능 측정은 동시에 돌리지 않는다. 다섯 번의 중앙값·최댓값은
로컬 비교 자료이며 p95, CI 단축률, 실제 Claude/Codex 세션 지연이 아니다.
PII endpoint, cache warm, 대규모 저장소 scan, 동시 hook 부하의 수치로 일반화하지 않는다.

## 검증 범위

watchdog 직접 회귀는 변경 전 scanner 성공/실패 양쪽에서 timer wait 한 번만
관측해 **0/2**로 실패했고, 수정 후 두 번의 wait와 bounded cleanup을 확인해
**2/2** 통과했다. TERM을 무시하는 timer도 포함한다.
framing 직접 검증은 18개에서 20개로 확장해 모든 non-NUL 바이트와 제어 문자가
밀집한 Unicode/invalid-UTF-8 stream을 별도 기대 바이트로 검증한다.
report parser 통합 후보의 공백-only 입력이 정상 빈 결과가 될 수 있음을 추가 검토에서
발견해, bounded report를 slurp하고 문서 유무까지 확인하도록 수정했다.
독립 CLI 회귀 8개는 수정 전 후보에서 공백-only 사례만 실패했고 최종 수정 후 모두
통과했다. 기존 기준의 보수적 처리를 유지하는 수정이며 새 탐지 규칙을 추가한 것은 아니다.
이후 최종 CLI로 측정과 회귀 검증을 다시 수행했다.

전체 테스트와 실측 결과는 아래에 기록한다. 선택된 Bash source location의
선택적 계측에서는 `secretish_env_values`의 기존 manifest hash가 기준 소스와
이미 달라 실행이 거부됐다. 기준/후보의 해당 함수 본문 SHA-256은 둘 다
`45b639e14834a761756b97c32cbe495bd7b474aab14ce49b23064f2154f2b45f`다.
선택된 상대 위치 2·3이 각각 `record_mode` 할당과 awk 호출임을 다시 확인하고,
관측 대상·분모를 유지한 채 stale hash를 갱신했다. 변경한 framing 함수의 선택
위치와 hash도 재검토했다. [재측정 원본](../bench/results/source-locations-2026-11-04.json)은
**39/40**, 정의만 읽는 음성 대조군은 **0/40**이다. embedded awk/jq, 전체 파일,
분기 coverage를 측정한 수치가 아니다.

## 재작성 판단

[재작성 검토](rewrite-assessment.ko.md)에 언어별 비교와 전환 조건을 정리했다.
Rust 단발 출력 코어 실험을 우선 권장하며, Go 운영 경험이 많으면 Go도 유효하다.
gitleaks와 셸 launcher를 유지하고, 마스킹 위치·강도와 실패 처리의 허용되지 않은
차이가 0개임을 확인한 뒤 단계적으로 이전한다. 이번에는 native 코어를 구현하거나
언어별 성능 우위를 측정한 것이 아니다.

## 로컬 실측 결과

Linux x86_64, jq 1.7, gitleaks 8.30.1에서 수행했다. 기준 CLI와 후보 CLI의 SHA-256,
scanner/config hash, 표본은 [기본 측정 원본](../bench/results/runtime-2026-11-04.json)에
있다. 후보 CLI SHA-256은
`8eafb814b1e64f7fca533aed37064e63d866eeb6636bc70fc426484e8709f409`다.
아래 시간은 각각 표본의 중앙값이다.

| 입력/경로 | 반복 수/각 버전 | 기준 wall s | 후보 wall s | 기준/후보 CPU s | 기준/후보 개별 peak RSS MiB |
| --- | ---: | ---: | ---: | --- | --- |
| 많은 치환 규칙과 leaf | 5 | 2.002 | 1.277 | 2.059 / 1.343 | 60.85 / 61.59 |
| 많은 줄 | 5 | 1.247 | 1.286 | 1.304 / 1.354 | 60.66 / 60.36 |
| 짧은 정상 hook 출력, 추가 반복 | 15 | 0.796 | 0.799 | 0.843 / 0.845 | 60.16 / 60.54 |
| 짧은 정상 exec 출력, 추가 반복 | 15 | 0.786 | 0.792 | 0.831 / 0.829 | 60.04 / 60.35 |
| 1 MiB exec capture | 3 | 0.322 | 0.312 | 0.339 / 0.342 | 44.42 / 44.86 |
| 8 MiB exec capture | 3 | 0.458 | 0.439 | 0.488 / 0.467 | 49.48 / 49.48 |

많은 치환 규칙·leaf 입력의 wall time은 **36.2%**, CPU는 **34.8%** 감소했다.
일반 입력의 일괄 성능 향상이나 메모리 감소를 주장하지 않는다. 초기 통합 후보의
첫 5회에서 정상 exec는 0.851→0.993초로 느리게 나와 두 정상 제어군을 별도
15회 측정했고, 최종 코드에서도 전체 측정과 15회 제어군을 다시 실행했다.
[최종 추가 원본](../bench/results/controls-2026-11-04.json)의 중앙값 차이는 각각
약 +0.4%, +0.8%였다. [초기 원본](../bench/results/runtime-initial-2026-11-04.json)과
`*-initial-2026-11-04.json`도 보존했다. 초기 후보의 수치를 최종 CLI의 수치로
표시하거나 유리한 표본만 버리지 않았다.

[capture 원본](../bench/results/capture-2026-11-04.json)은 1/8 MiB 원문 모두
기존과 같이 `[REDACTED]`로 처리됨을 확인한다. peak RSS가 scan cap의 크기에
고정되지 않음을 보여 주지만, 이 값으로 capture만의 메모리나 트리 전체 peak를
역산할 수는 없다. 메모리를 제한하는 spool/capture 설계는 여전히 후속 과제다.

독립 strace 표본에서는 일반 출력 탐지 경로의 execve 시도가 78→77 또는
80→79로 한 번 줄었다. 작은 정상 Bash 명령의 PreToolUse는 양쪽 모두
execve 288회, thread를 제외한 생성 syscall 시도 1,073회였다. 실패한 시도도
포함한 계수이며 생성된 프로세스의 개수로 해석하면 안 된다. 이번 수정이
Bash policy 분석 경로의 구조적 비용을 줄이지 않았다는 증거이기도 하다.

21종의 서로 다른 입력에 대해 기본 252회, 정상 제어군 추가 60회,
대형 capture 12회로 **총 324회의 종료 코드·마스킹 결과 검증을 통과**했다.
그중 정상 제어군은 추가 마스킹 없이 통과하고, 기존 정밀/보수적 마스킹 결과는
각 fixture의 기대값과 일치했다. 이 수는 전체 제품의 탐지율이나 source coverage가 아니다.

[watchdog 원본](../bench/results/watchdog-2026-11-04.json)은 Linux subreaper로
각 CLI `check` 종료 뒤 입양한 고아 자식을 세고 회수한 결과다. 기준은 10회 모두
1개, 후보는 10회 모두 0개였다. 시스템 전체의 고아 프로세스를 센 것이 아니다.
다음 명령으로 별도 재현할 수 있다.

```sh
sh scripts/devtools.sh watchdog-orphans \
  --baseline /absolute/path/to/baseline/plugins/agent-guard/bin/agent-guard \
  --scanner /absolute/path/to/gitleaks --runs 10
```

## 최종 회귀 검증

[검증 원본](../bench/results/verification-2026-11-04.json)은 최종 CLI hash를 고정한
상태에서 전체 5개 shard를 최대 두 개씩 실행한 결과다. 실행 전후 CLI가 같았고,
모든 shard와 후속 통합 검증의 종료 코드는 0이다.

| Shard | 통과 outer assertion | 실패 |
| --- | ---: | ---: |
| 1 | 821 | 0 |
| 2 | 195 | 0 |
| 3 | 278 | 0 |
| 4 | 1,022 | 0 |
| 5 | 380 | 0 |
| 합계 | **2,696** | **0** |

`make test-unit`의 7개 suite는 **188개**의 내부 assertion을 통과했다.
이는 위 outer assertion 합계에 더하는 별도 coverage 분모가 아니다.
새 scanner report 회귀 8개는 원래 기준 CLI에서도 통과해 원래의 fail-closed
계약을 보존함을 확인했다. 실제 gitleaks를 사용한 `smoke-test`와 invalid-UTF-8
exec framing 경계 회귀 **24개**도 통과했다.

[기준 채널 결과](../bench/results/coverage-baseline-2026-11-04.tsv)와
[최종 채널 결과](../bench/results/coverage-candidate-2026-11-04.tsv)의 15개 행은
동일했다. 실제 scanner의 passive hook secret 사례는 **9/9 보호**,
benign 제어군 오탐은 **0/4**, engine error는 0개다. hook이 발생하지 않는
`!` 채널은 기존처럼 미보호로 기록하며, opt-in exec 보호와 혼합하지 않았다.

검증 중 발견한 환경·test harness 차이는 다음과 같이 처리했다.

- 프레이밍 구현의 예전 `emit_char` 문장을 찾던 오류 주입 selector 두 곳을
  프레이밍의 RS 종료 계약으로 변경했다. 오류·부분 출력의 기존 기대값은 유지했고,
  prompt 34개와 mock/실제 scanner의 exec 경계 회귀 24개를 다시 확인했다.
- 기본 sandbox는 `/tmp/.git` 표식과 UID 65534인 가상 루트 소유권을 보여 주어
  private allow-list 신뢰 검사가 거부됐다. 실제 파일 소유권이 보이는 실행 환경에서
  재검증했으며, 제품의 ownership/ACL/working-directory 검사는 완화하지 않았다.
- CPU quota 4개인 환경에서 초기 5-way 실행 중 readiness의 기존 2초 timeout과
  DEGRADED 경로가 관측됐다. [부하 진단 원본](../bench/results/probe-load-2026-11-04.json)의
  원래 기준 CLI `check`에서도 150회 중 1회 같은 timeout이 있었다. 이를 특정 수정의
  성능 향상 증거로 해석하지 않는다. 최종 전체 검증은 최대 두 shard씩 실행했고
  deadline이나 infrastructure failure 기본값은 바꾸지 않았다. 과도한 동시 부하에서
  기본 open 정책이 적용될 가능성은 별도의 운영·동시성 검증 대상이다.

이번 검증은 Linux에서 수행했다. macOS CI와 인증된 실제 Claude/Codex의 host
dispatch는 실행하지 않았으며, CLI 호스트 fixture 통과를 그 증거로 대신하지 않는다.

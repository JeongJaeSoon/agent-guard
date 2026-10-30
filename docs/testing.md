# Test layers, coverage and regression workflow

Agent Guard currently relies primarily on CLI contract and integration tests.
A count of passing assertions is an inventory check, **not a code-coverage
percentage**. The execution partitions described in [CI](ci.md) are scheduling
units, not security tiers or test-pyramid layers.

<a id="current-layers"></a>

## 현재 테스트 계층

| 계층 | 실행 진입점 | 검증 범위 |
| --- | --- | --- |
| 정적 검사와 패키징 | ShellCheck, actionlint, plugin/layout 및 submission validator | shell/workflow 오류와 패키징 계약 |
| 직접 함수 계약 | `make test-unit`; 아래 [전체 목록](#direct-contract-inventory) 참고 | CLI 시작 없이 추출한 프로덕션 함수 본문 검증 |
| 집중 실패 회귀 | `tests/prompt-assignment-failure.sh`, `tests/exec-raw-probe-failure.sh`, `tests/exec-framing-boundary.sh` | prompt 직접/host 정책 34개, raw exec 7개, exec framing 경계 24개; 직접 함수 계약 합계와 별도 |
| 좁은 컴포넌트 비교 | `tests/framed-leaves.sh` | framing fast path와 byte decoder 비교, escaping, byte 경계와 명시적 detector 기대값 |
| CLI 계약 | `tests/deny-read-mask*.sh`, `tests/source-module-prose.sh`, `tests/hook-outcome-contract.sh`, `tests/gitleaks-resolution.sh`, `tests/audit-log.sh` | CLI를 통한 종료 상태, host payload, 진단, 마스킹과 인프라 정책 |
| OS/tool 통합 | `tests/run.sh`의 Git fixture, permission/ACL/symlink/signal 사례, `tests/pii-utf8.sh`, Linux real-gitleaks 블록 | 실제 파일시스템·Git·프로세스 동작, Apple awk와 scanner 차이 |
| 배포와 서비스 통합 | `make smoke-test`, archive/Homebrew 검증, 선택 실행하는 `make test-pleno-integration` | 실제 scanner/tool 의존성, 설치와 설정한 서비스 경계 |
| 인증된 host E2E | 별도 Claude/Codex host-dispatch 검증 | host가 설치된 adapter를 로드하고 호출하는지 확인; 직접 CLI 호출이나 host 환경변수 지정만으로는 입증되지 않음 |

<a id="direct-contract-inventory"></a>

## 직접 계약 테스트 목록

`make test-unit`의 전체 목록과 현재 수치는 이 표에서만 관리한다.
Makefile의 실행 recipe와 각 스크립트의 `passed:` 출력을 기준으로 확인하며,
suite를 추가하거나 assertion 수를 바꾸면 이 표도 함께 갱신한다.
개별 문서는 각 suite의 계약과 검증 근거를 설명하고 이 목록을 참조한다.

| 실행 경로 (`sh`로 개별 실행 가능) | 내부 assertion | `tests/run.sh` partition | 계약 설명 |
| --- | ---: | ---: | --- |
| `tests/unit-core.sh` | 35 | 1 | [버전 비교와 shell quoting](unit-tests.md) |
| `tests/unit-framing.sh` | 18 | 1 | [framing producer](unit-framing.md) |
| `tests/unit-deny-path.sh` | 83 | 1 | [deny-path 문자 producer](deny-path-regex.md) |
| `tests/unit-probe.sh` | 4 | 1 | probe 대상 판정 |
| `tests/unit-status-label.sh` | 22 | 1 | [status-label 분류](status-label-tests.md) |
| `tests/redaction-plan.sh` | 8 | 4 | [치환 순서·문맥·출력 예산](masking-performance.md) |
| **합계: 6개 suite** | **170** | | |

`make test`는 위 suite를 각 partition에서 한 번씩 실행하고 전체 통합 테스트도
실행한다. 각 suite는 내부 assertion 수와 무관하게 외부 assertion 하나로 집계한다.
개별 partition 조사에는 `AGENT_GUARD_TEST_SHARD=2 tests/run.sh`를 사용하되,
이 로컬 진단 선택으로 전체 CI 검증을 대체하지 않는다. 좁은 범위는
`sh tests/source-module-prose.sh` 또는 `sh tests/framed-leaves.sh`로 실행할 수 있다.
PATH에 실제 scanner가 있으면 추가 통합 assertion이 활성화될 수 있다.
CI의 Linux scanner job은 이 assertion과 smoke test 실행을 요구하며 다른
partition은 합성 scanner fixture를 사용한다. Linux와 macOS 검증을 모두 유지한다.

The full test suite includes subprocess, file-mode and process-cleanup cases.
Keep HOME, warning/session state, Git repositories and output files isolated.
Do not cache a passing result, share mutable repositories across cases, or
replace a real OS boundary with a mock merely to shorten the suite.

## Prior four-suite cost inventory (2026-10-20)

These sequential, uninstrumented macOS arm64 observations use the repository
CLI and synthetic test fixtures; they are not budgets, guarantees or CI speedup
evidence. The installed real scanner was gitleaks 8.30.1. The four direct suites
total 140 assertions and about 0.479 seconds in this sample.

| Entry point (`sh tests/…` unless shown) | Inner assertions | Seconds | Main boundary/cost |
| --- | ---: | ---: | --- |
| `unit-core.sh` | 35 | 0.184 | Shell quoting and awk version comparison |
| `unit-framing.sh` | 18 | 0.186 | jq/awk producer byte contracts and partial failure |
| `unit-deny-path.sh` | 83 | 0.062 | Shell character/regex producer contracts |
| `unit-probe.sh` | 4 | 0.047 | awk eligibility marker contracts |
| `prompt-assignment-failure.sh` | 34 | 3.280 | Direct probe plus Claude/Codex CLI payload/policy combinations |
| `exec-raw-probe-failure.sh` | 7 | 1.210 | >64 KiB invalid-byte exec route; mock scanner |
| `exec-framing-boundary.sh` | 24 | 5.355 | Exact 64 KiB framing errors and adjacent routes; mock scanner |
| Same boundary suite with `BOUNDARY_TEST_GITLEAKS=/path/to/gitleaks` | 24 | 10.192 | Same contracts with real scanner |
| `make smoke-test` with real scanner | separate E2E checks | 1.519 | Real git/jq/gitleaks, temporary repository |

위 과거 측정의 직접 suite 네 개는 각각 partition 1의 외부 assertion 하나에 해당한다.
prompt 회귀도 partition 1에서, 두 exec 회귀는 partition 4에서 실행한다.
Do not add their inner counts to `tests/run.sh`'s outer count as if they were a
single coverage denominator. Existing OS/integration suites remain in place.
For scale, PR337's local full suite passed 1958 outer assertions in 840.18 seconds;
that historical result is not the new head's validation. Full CI depends on
runner capacity and OS differences and requires its own exact-head evidence.

## Coverage we do and do not measure

There is no automatic line/branch coverage collector or percentage gate in
these workflows. A local [scoped source-line measurement](coverage-core.md)
retains the historical 4/4 result and records an eight-function observation from 2026-10-20:
**39/40 predetermined physical Bash source locations**, with a definition-only
control at **0/40**. This excludes embedded programs and is not whole-file,
repository or branch coverage. `bench/run.sh` reports behavior on synthetic leak-prevention
channels; its detection and false-positive metrics are not source coverage.
Assertion inventory comparisons detect omitted or duplicated cases, but do not
prove every branch was executed or every security behavior was asserted.

Every shell coverage experiment must state its exact interpreter, source
files, denominator and exclusions. [kcov](https://github.com/SimonKagstrom/kcov)
supports Bash coverage and exports reports, but has not been integrated here.
A Bash-instrumented run cannot replace the normal POSIX-sh or Apple awk runs.
Embedded awk/jq programs, child interpreters, external Git/scanner behavior and
actual host dispatch need separate accounting; do not fold unmeasured regions
into a single reassuring percentage. Instrumentation also changes timing, so
keep coverage collection separate from performance comparisons. Use synthetic
fixtures and avoid tracing credentials or publishing sensitive payloads.

## Small steps toward a test pyramid

The first step is implemented in PR #331: fast, table-driven checks with
independent expected values for version comparison and shell quoting. All
existing CLI tests remain. Exact-head and merged-main CI passed on both OSes;
assertion inventory comparison found no removals. The framing comparison is an existing narrow
example; source extraction has boundaries that must be checked when code moves.
The CLI initializes and dispatches at load time, so sourcing it wholesale is
not an isolated unit-test interface.

A later module-extraction PR should own its production function boundary and
unit fixtures, retain CLI parity cases, and show byte/exit-status equivalence
on both OSes. Filesystem path resolution, shell-command interpretation, ACLs,
Git index semantics and process cleanup are poor first extraction candidates:
their environment and security boundaries are part of what must be tested.
Only consider replacing a subprocess-heavy duplicate after documenting exactly
which behavior the faster test preserves and which integration case remains.

## Red, green, then refactor

For a bug or behavior change:

1. Add an independently specified regression and record it failing on the
   parent commit for the intended reason, including the command and exit code.
   Include the relevant clean and blocked/error controls.
2. Make the smallest production correction and record the same regression
   passing, without weakening its expectations.
3. Refactor only after green; run the narrow checks, affected CLI/OS contracts,
   then all existing required gates on the exact head.
4. Record the red/green commits or logs and remaining untested boundaries in
   the PR. If no pre-fix failure was observed, call it added regression coverage,
   not completed TDD.

Direct framing producer contracts now supplement the decoder comparison: see
[the measured blind spot and limits](unit-framing.md). Next evaluate a standard
Bash collector in an isolated Linux environment only when broader source-level
measurement will guide a concrete change. Keep AWK
branch profiling separate and label its interpreter; GNU awk results would not
prove Apple awk behavior. Authenticated host E2E and currently unrepresented
OS/CPU targets remain distinct gaps. Do not convert OS-dependent integration
tests to unit tests just to improve the pyramid shape.

This document introduces no framework, coverage service, credentials, new
required check or reduction in the existing suite. CI performance changes own
their test helpers; future unit/module changes should use separate small PRs.

The [status-label family mapping](status-label-tests.md) records the subsequent
move of pure classification variants to 22 direct assertions, five retained CLI
representatives, equivalence and selected mutation controls. It does not change
the historical four-suite timing or scoped Bash observation above.

마스킹 처리 단계, 입력 형태별 성능 측정, 프레이밍 및 치환 순서의 회귀 검증은
[마스킹 성능 문서](masking-performance.md)를 참고한다. 성능 측정은 모든 표본의
마스킹 결과를 확인하며 기본 CI의 기능 검증을 대체하지 않는다.

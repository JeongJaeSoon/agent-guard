# CI checks and test partitions

CI runs on pull requests and pushes to `main`: the first validates a proposed
change, the second validates the merged tree. Plugin Validation and HOL scan
have the same triggers but own different checks; they are not duplicate suite
runs. The release workflow also relies on the existing check names.

| Check | Coverage |
| --- | --- |
| Agent Guard | Real scanner against the checked-out tree |
| Named suites (ubuntu-latest) | All suite partitions on Linux; real scanner integration and smoke test in shard 4 |
| Named suites (macos-latest) | All suite partitions on macOS with the mock scanner; platform-specific permission and process behavior |
| Test (ubuntu-latest), Test (macos-latest) | Fail-closed aggregate of every shard, including cancelled/failed jobs |
| Lint | ShellCheck on tracked shell scripts and actionlint on workflows |
| Plugin Layout | Codex, Claude, marketplaces, release archive, and submission metadata |
| HOL Plugin Scanner | Independent plugin scanner |

The numbers are execution partitions, not security tiers or sequential stages.
`tests/run.sh` without `AGENT_GUARD_TEST_SHARD` runs them all in order. CI runs
them on both operating systems, and shard 1 checks that every
partition is present in the matrix. Fixtures remain local to each partition.
The internal IDs select execution partitions; Actions displays descriptive names:

| Internal ID | Actions suite | Change from the previous layout |
| --- | --- | --- |
| 1 | Core, host adapters and Git (with 3) | Unchanged |
| 2 | Command policies | Adds git aliases and three mask suites previously in 3 |
| 3 | Core, host adapters and Git (with 1) | Retains auto-staging regression cases |
| 4 | CLI, scanner and output | Retains scanner integration; adds original 5 output, PII and shell-setup cases |
| 5 | Shell navigation | Runs shell-navigation cases previously in 4 |

Regression assertion bodies and their unpartitioned execution order stay
identical; the matrix-coverage assertion is updated for the bundle format. Moved groups initialize their own repositories, configuration and
sessions. The aggregate check names and their fail-closed dependencies remain
unchanged; the release workflow consumes those aggregates, not the child names.

## Reading test results

Each partition prints execution seconds and passed/failed counts in the Actions job summary. The Run tests
step groups the full assertion stream, with failures and final counts repeated
outside the group. Expand the **full test assertions** group for all diagnostics. The
original output also remains in the runner's `test-output.txt` for the Linux
real-scanner presence gate. Every child exit status is collected, including after another child fails;
printing a summary cannot make a failing suite pass.

## Small setup and layout simplification

Only Linux shard 4 consumes the installed real scanner; the other four Linux
partitions use the suite's mock. Restricting the pinned, checksum-verified
installation to shard 4 removes four unused downloads per CI run. The real
scanner assertions, explicit no-skip gate, smoke test, and separate Agent Guard
scan are unchanged. No cache is introduced: downloading a small pinned archive
once avoids cache restore/save machinery and keeps checksum verification at the
point of use.

Plugin Layout uses the validator's existing `--all` mode instead of four
separate invocations. It calls the same four validation functions, in the same
order, with one temporary directory. Submission validation stays separate.
No assertion, platform, required aggregate name, trigger, permission, pin,
timeout, or release gate is removed or changed.

## Earlier setup-only change

Baseline: main commit `4718939f2f8923d2e483928620f6878fa32192a6`,
[CI run 38683421367](https://github.com/JeongJaeSoon/agent-guard/actions/runs/38683421367).
Workflow creation to update: 515 seconds. The longest test step was macOS shard
4 at 491 seconds. The four unused Linux installation steps totalled only one
second at Actions' whole-second timestamp resolution. Eliminating those
installations reduces requests and setup duplication, but does not establish a
material wall-time or billed-cost saving. Runner variability dominates this
small change; compare runner and test-step time separately, and do not treat a
single faster run as causal evidence.

Baseline top-level passed counts by shard (nested suites have their own counts):

| OS | 1 | 2 | 3 | 4 | 5 | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Linux | 602 | 142 | 163 | 532 | 500 | 1939 |
| macOS | 602 | 142 | 163 | 458 | 504 | 1869 |

Every failed count was zero. The difference includes real-scanner coverage on
Linux and platform-specific assertions on macOS. The earlier setup-only change did not change test source or partition boundaries.
These historical counts are not the baseline for the subsequent rebalance.

## Runtime rebalance and measurement

Two recent baseline runs show the uneven work:

| Main CI run | macOS test seconds, internal partitions 1–5 |
| --- | --- |
| [38986270841](https://github.com/JeongJaeSoon/agent-guard/actions/runs/38986270841), `95d795a` | 392, 356, 650, 745, 223 |
| [38991770310](https://github.com/JeongJaeSoon/agent-guard/actions/runs/38991770310), exact base `3207298` | 394, 320, 486, 615, 253 |

In the exact base, assertion timestamps put shell-navigation cases at about
391 seconds (including initial setup) and aliases plus three mask suites at
about 151 seconds. Move those groups to 5 and 2, and combine the original 5
with the remaining 4. Applying these group times gives estimated macOS loads
of 394, 471, 335, 477 and 391 seconds. This is **a redistribution estimate, not
an observed speedup**. All ten OS/partition combinations stay; redistribution
aims to shorten the critical path, not reduce total test work. See the PR's
validation evidence for actual candidate measurements and assertion comparison.

Compare the exact base and candidate runs using creation-to-last-job completion
(wall time), creation-to-job-start (queue/start delay), test-step duration, and
summed job durations (runner time). Hosted-runner variability can overwhelm a
single comparison; a lower wall time alone does not establish lower billed cost.
The per-suite summary reports only test execution, excluding queue and setup.

## 호스트 계약별 병렬 실행

core runner는 partition 1과 3을 동시에 실행한다. command policies는
partition 2, scanner는 partition 4를 각각 실행한다. 가장 오래 걸리는 shell
navigation은 Claude와 Codex의 호스트 계약별 runner로 나눈다. 두 호스트는
입력의 cwd/workdir 위치와 응답 계약이 다르며, 각 worker는 자신이 맡은 호스트의
실제 hook·Bash·Git 검증 전체를 실행한다. 테스트 목록을 번호나 개수로 자르지 않는다.

각 OS에서 navigation 두 worker의 합집합은 기존 378개 assertion과 같다.
호스트 공통 assertion 5개는 Claude worker가 한 번 실행한다. fixture의 저장소,
TMPDIR, 출력 파일은 worker마다 격리한다. 기본 `tests/run.sh`는 여전히 모든
호스트를 실행하고, 호스트 선택은 navigation partition에만 허용한다.
잘못된 호스트나 다른 partition과의 조합은 오류로 종료한다. core의 matrix 검증은
일반 partition의 단일 실행과 Claude/Codex navigation의 누락·중복을 확인한다.

따라서 test job은 이전 6개에서 10개가 된다. OS/partition/host의 전체 검증 범위,
aggregate job 2개의 이름과 fail-closed 의존성은 유지한다. scanner의 실제 설치,
no-skip gate와 smoke test도 그대로다. core의 parent는 모든 child를 기다리고,
하나라도 실패하거나 출력 수집이 실패하면 job을 실패시킨다. 전체 log는 완료 후
출력하며 job 취소 시 hosted runner teardown이 정리를 담당한다.

### 측정과 설계 선택

2026-10-25~27의 성공 CI 8회에서 결합된 macOS `Command policies and shell
navigation` job은 [11분 32초](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40181470019)~[16분 29초](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40483354986)가 걸렸다.
정확한 기준 커밋 `907e6db`의 [run 40537624147](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40537624147)과
최초 후보 `1ff1122`의 [run 40623642319](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40623642319)를
생성 시각부터 마지막 job 종료까지 비교한 결과는 다음과 같다.

| 지표 | 기준 | 명령 정책과 navigation만 분리한 최초 후보 |
| --- | ---: | ---: |
| 전체 CI wall time | 960초 | 1,015초 |
| 가장 긴 macOS job | 949초 | 1,003초 |
| runner 실행 시간 합계 | 3,133초 | 3,296초 |

두 실행은 모두 성공했지만 **최초 분리안의 속도 개선은 입증되지 않았다**.
macOS navigation이 그대로 병목이었다. 따라서 그 결과를 개선 수치로 사용하지 않고,
호스트별 실제 검증을 독립 runner에 배치하는 구조로 변경했다. 최초 후보의
navigation 로그에는 Claude 사례 193개, Codex 사례 180개와 공통 assertion 5개가
있다. 마스킹 개선도 포함했던 결합 후보 `6867ceb`의
[run 40626075994](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40626075994)는
전체 519초, runner 합계 3,335초였으며 모든 검증이 통과했다. 다만 두 변경을
함께 적용한 측정이므로 CI 변경만의 단독 단축률로 해석하지 않는다.
CI 전용 변경은 마스킹 개선에 의존하지 않고 main에 독립적으로 적용된다.
분리한 CI 전용 PR의 현재 head 실행 로그와 검증 기록으로 단독 결과를 확인한다.

Hosted runner 이미지와 부하가 실행마다 달라질 수 있다. 전체 wall time,
queue/start 지연, test-step 시간, runner 시간 합계를 구분하며, 단일 실행으로
비용 절감이나 안정적인 단축률을 단정하지 않는다. 로컬 비교 중 source가 변경된
표본은 제외했다. 같은 명령의 중복 파싱을 줄이는 별도 아이디어도 측정했지만,
로컬 추정 절감량이 전체 navigation에서 약 4초에 불과해 이번 변경에 포함하지 않았다.

suite job timeout은 25분을 유지한다. [main run 39933464643](https://github.com/JeongJaeSoon/agent-guard/actions/runs/39933464643)의
macOS partition 5 child elapsed 약 14분은 partition 2와 같은 runner에서 동시에
실행된 값이므로 독립 runner 시간으로 해석할 수 없다. 가장 느린 case를 다른
번호의 partition으로 옮겨 병목만 이동시키는 방식도 사용하지 않는다.

See [Test layers and coverage](testing.md) for the distinction between execution
partitions, test-pyramid layers, assertion inventories and code coverage.

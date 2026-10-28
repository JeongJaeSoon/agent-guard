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

## OS별 제한된 동시 실행

core runner는 partition 1과 3을 동시에 실행한다. 오래 걸리는 command
policies partition 2와 shell navigation partition 5는 서로 다른 runner에서
실행하여 같은 macOS runner의 자원 경합이 critical path를 늘리지 않게 한다.
scanner runner는 partition 4만 실행하며 real-scanner 설치, no-skip gate,
smoke test를 그대로 유지한다. 따라서 test job은 6개에서 8개로 늘지만
OS/partition 10개 조합은 그대로 모두 실행되며 aggregate job 2개의 이름과
의존성도 바뀌지 않는다. core의 각 child는 별도 TMPDIR와 출력 파일을 사용하고 parent는
모든 child를 기다린 뒤 하나라도 실패하거나 출력 수집이 실패하면 job을
실패시킨다. 전체 log는 완료 후 출력하므로 서로 섞이지 않는다. job 취소 시
hosted runner teardown이 정리를 담당하며 내부 timeout은 완화하지 않는다.

2026-10-25~27의 최근 성공 CI 8회에서 결합된 macOS `Command policies and
shell navigation` job은 [11분 32초](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40181470019)~[16분 29초](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40483354986)가 걸렸고,
[최신 run](https://github.com/JeongJaeSoon/agent-guard/actions/runs/40537624147)은
15분 49초였다. 이 변경은 같은 runner에서 두 heavy shell suite가 경쟁하는
구조를 제거한다. 로컬 비교는 실행 중 source가 변경되어 인과 증거에서 제외했다.
실제 candidate hosted CI가 실행되지 않았으므로 단축 효과는 **UNVERIFIED**다.
job 수만으로 billed cost 절감을 주장하지 않는다.

suite job timeout은 25분이다. [main run 39933464643](https://github.com/JeongJaeSoon/agent-guard/actions/runs/39933464643)에서
macOS partition 5의 child elapsed는 약 14분이었지만, 이는 partition 2와 같은
`Command policies and shell navigation` runner에서 동시에 실행된 값이다. 따라서
partition 5의 독립 runner 시간으로 해석할 수 없다. 가장 느린 shell cd case를
partition 3으로 옮긴 이전 시도는 병목을 core runner로 이동시켰을 뿐이었다.
case 비용이 고르지 않고 runner 시간도 run 사이에 약 25% 변하므로 candidate
hosted CI 전에는 이번 분리의 단축 효과를 확정하지 않는다.

See [Test layers and coverage](testing.md) for the distinction between execution
partitions, test-pyramid layers, assertion inventories and code coverage.

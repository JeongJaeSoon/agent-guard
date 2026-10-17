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
them independently on both operating systems, and shard 1 checks that every
partition is present in the matrix. Fixtures remain local to each partition.
The internal IDs select execution partitions; Actions displays descriptive names:

| Internal ID | Actions suite | Change from the previous layout |
| --- | --- | --- |
| 1 | Core and host adapters | Unchanged |
| 2 | Command policies and aliases | Adds git aliases and three mask suites previously in 3 |
| 3 | Git auto-staging | Retains auto-staging regression cases |
| 4 | CLI and scanner integration | Moves shell-navigation cases to 5; retains real scanner integration |
| 5 | Shell navigation and output | Adds shell-navigation cases previously in 4 |

Only gates move: assertion bodies and their unpartitioned execution order stay
identical. Moved groups initialize their own repositories, configuration and
sessions. The aggregate check names and their fail-closed dependencies remain
unchanged; the release workflow consumes those aggregates, not the child names.

## Reading test results

Each suite prints execution seconds and passed/failed counts in the Actions job summary. The Run tests
step groups the full assertion stream, with failures and final counts repeated
outside the group. Expand the **full test assertions** group for all diagnostics. The
original output also remains in the runner's `test-output.txt` for the Linux
real-scanner presence gate. The test/tee pipeline's nonzero exit is preserved;
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

The rebalance uses [run 38986270841](https://github.com/JeongJaeSoon/agent-guard/actions/runs/38986270841)
at `95d795a` to identify uneven work: macOS test steps took 392, 356, 650,
745 and 223 seconds in partitions 1–5. Assertion timestamps put shell-navigation
cases at approximately 404 seconds and aliases plus the three mask suites at
approximately 150 seconds. Moving these self-contained groups to 5 and 2 reduces
the estimated longest partition to about 627 seconds **on those same timings**.
This estimate is not an observed speedup. All ten OS/partition combinations stay;
redistribution aims to shorten the critical path, not reduce total test work.

Compare the exact base and candidate runs using creation-to-last-job completion
(wall time), creation-to-job-start (queue/start delay), test-step duration, and
summed job durations (runner time). Hosted-runner variability can overwhelm a
single comparison; a lower wall time alone does not establish lower billed cost.
The per-suite summary reports only test execution, excluding queue and setup.

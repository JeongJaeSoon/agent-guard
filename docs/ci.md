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
| 2 | Command policies and shell navigation (with 5) | Adds git aliases and three mask suites previously in 3 |
| 3 | Core, host adapters and Git (with 1) | Retains auto-staging regression cases |
| 4 | CLI, scanner and output | Retains scanner integration; adds original 5 output, PII and shell-setup cases |
| 5 | Command policies and shell navigation (with 2) | Runs shell-navigation cases previously in 4 |

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

## Bounded concurrency within each OS

The core runner executes partitions 1 and 3 concurrently; the policies runner
executes 2 and 5 concurrently. The scanner runner executes 4 alone, retaining
its real-scanner installation, no-skip gate and smoke test. This keeps all ten
OS/partition combinations on six runners instead of ten. Each child gets a
separate TMPDIR and output file; the parent waits for every child and fails if
any child or output collection fails. Full logs are printed after completion,
so they do not interleave. Hosted-runner teardown handles job cancellation.
No internal timeout is relaxed. This uses the existing runner CPUs; contention
can offset the reduction in runner lifetimes. Actual timing comparisons are
required before claiming a saving; job count alone is not a cost measurement.

See [Test layers and coverage](testing.md) for the distinction between execution
partitions, test-pyramid layers, assertion inventories and code coverage.

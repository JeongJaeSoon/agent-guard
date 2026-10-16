# CI checks and test partitions

CI runs on pull requests and pushes to `main`: the first validates a proposed
change, the second validates the merged tree. Plugin Validation and HOL scan
have the same triggers but own different checks; they are not duplicate suite
runs. The release workflow also relies on the existing check names.

| Check | Coverage |
| --- | --- |
| Agent Guard | Real scanner against the checked-out tree |
| Test (ubuntu-latest, shard 1–5) | All suite partitions on Linux; real scanner integration and smoke test in shard 4 |
| Test (macos-latest, shard 1–5) | All suite partitions on macOS with the mock scanner; platform-specific permission and process behavior |
| Test (ubuntu-latest), Test (macos-latest) | Fail-closed aggregate of every shard, including cancelled/failed jobs |
| Lint | ShellCheck on tracked shell scripts and actionlint on workflows |
| Plugin Layout | Codex, Claude, marketplaces, release archive, and submission metadata |
| HOL Plugin Scanner | Independent plugin scanner |

The numbers are execution partitions, not security tiers or sequential stages.
`tests/run.sh` without `AGENT_GUARD_TEST_SHARD` runs them all in order. CI runs
them independently on both operating systems, and shard 1 checks that every
partition is present in the matrix. Fixtures remain local to each partition.
The partitions contain mixed regression groups; the numbers are deliberately
kept stable rather than implying a security taxonomy.

## Reading test results

Each shard prints passed/failed counts in the Actions job summary. The Run tests
step groups the full assertion stream, with failures and final counts repeated
outside the group. Expand **Full test assertions** for all diagnostics. The
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
No assertion, platform, check name, trigger, permission, pin, timeout, or release
gate is removed or changed.

## Baseline and limits

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
Linux and platform-specific assertions on macOS. Test source and partition
boundaries are unchanged by this CI simplification. Rebalancing the long macOS
partitions is separate work requiring fixture-dependency analysis and repeated
measurements; flattening them would restore the historically slower serial job.

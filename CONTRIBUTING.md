# Contributing to Agent Guard

Read [AGENTS.md](AGENTS.md) first: it defines the layer boundaries, the
minimum-complexity ladder and the documentation language rules. This guide
covers how the tests are organized, how CI runs them and how to read the
results.

Run `tests/run.sh` (or `make test`) before declaring a change complete. A
count of passing assertions is an inventory check, **not a code-coverage
percentage**. The execution partitions below are scheduling units, not
security tiers or test-pyramid layers.

## Test layers

| Layer | Existing entry points | What they establish |
| --- | --- | --- |
| Static and packaging | ShellCheck, actionlint, plugin/layout and submission validators | Shell/workflow errors and packaging contracts |
| Direct function contracts | `make test-unit`; see the [inventory](#direct-contract-inventory) below | Extracted production bodies without CLI startup |
| Focused failure regressions | `prompt-assignment-failure.sh`, `exec-raw-probe-failure.sh`, `exec-framing-boundary.sh` | Prompt direct/host-policy regressions 34; raw exec regressions 7; bounded exec framing regressions 24. These are separate from the direct function contract total |
| Scanner report validation | `tests/scanner-report.sh` | Eight CLI checks: empty/whitespace/malformed/non-array reports and scanner failure stay fail-closed; clean arrays and precise findings retain their output |
| Narrow component comparisons | `tests/framed-leaves.sh` | Framing fast path versus byte-decoder reference, escaping, byte boundaries and explicit detector expectations |
| awk implementation comparison | `tests/assignment-leftmost.sh` (partition 1; `legacy-tools.yml` requires mawk, gawk and busybox awk) | 16 fixture lines with more than one assignment: detector values and Claude/Codex PostToolUse output are the same bytes on the awk on `PATH` and on each of mawk, gawk and busybox awk that is installed. `AGENT_GUARD_TEST_REQUIRE_AWKS` turns a missing implementation into a failure. `tests/key-name-masking.sh` (partition 3) compares its detector records the same way; `legacy-tools.yml` runs its two halves in separate jobs with `AGENT_GUARD_TEST_KEY_NAME_PART=records` (all three awks required) and `=hooks` (the hook cases under mawk) |
| CLI contracts | `tests/deny-read-mask*.sh`, `source-module-prose.sh`, `hook-outcome-contract.sh`, `gitleaks-resolution.sh`, `audit-log.sh`, `redaction-wrapped-values.sh` | Exit status, host payloads, diagnostics, masking and infrastructure policy through the CLI. `redaction-wrapped-values.sh` runs every row of `tests/fixtures/redaction-wrapped-values.json` through Claude and Codex PostToolUse and UserPromptSubmit |
| Plugin hook launcher | `tests/hook-launcher.sh` (partition 1) | `plugins/agent-guard/hooks/launch.sh` driven directly for Claude and Codex under `sh`, `dash` and `bash` over a fake plugin cache: authoritative complete root, deleted-root recovery through `current` or the highest complete semver sibling, no substitution for an incomplete root, closed blocks with a reason every time, once-per-session open warning, stdin pass-through and invalid-argument refusal. Not host dispatch |
| OS/tool integration | Git fixtures in `tests/run.sh`, permission/ACL/symlink/signal cases, `pii-utf8.sh`, Linux real-gitleaks block | Actual filesystem, Git and process behavior; Apple awk and scanner differences |
| Deployment and service integration | `make smoke-test`, archive/Homebrew validation, opt-in `make test-pleno-integration` | Real scanner/tool dependencies, installation and configured service boundaries |
| Authenticated host E2E | Separate Claude/Codex host-dispatch verification | Host loads and invokes the installed adapter; direct CLI calls or selecting a host environment variable do not establish this |

## Direct contract inventory

This table is the single reference for the complete `make test-unit` suite
list and current counts. Verify it against the Makefile recipe and each
script's `passed:` output; update it whenever a suite or assertion count
changes.

| Entry point (also runnable with `sh`) | Inner assertions | `tests/run.sh` partition | Contract |
| --- | ---: | ---: | --- |
| `tests/unit-core.sh` | 36 | 1 | Numeric version comparison (`version_newer`) and shell single-quote encoding and round trip (`sh_squote`) |
| `tests/unit-framing.sh` | 20 | 1 | JSON and plaintext framing producers: exact RS/US/LF bytes, Unicode and invalid bytes, jq/awk failure after partial output keeps exit 23 |
| `tests/unit-deny-path.sh` | 139 | 1 | Deny-path character producers (`sx_hex`, `sx_char`, `sx_pin`): the ASCII hex table, unsupported-input reset, pin patterns, no output and caller variables preserved |
| `tests/unit-probe.sh` | 4 | 1 | Probe eligibility |
| `tests/unit-watchdog.sh` | 2 | 1 | Timer cancellation waits for the child on scanner success and failure |
| `tests/unit-status-label.sh` | 22 | 1 | Status-label classification |
| `tests/redaction-plan.sh` | 8 | 4 | Replacement ordering, context and output budgets |
| `tests/unit-audit-retention.sh` | 10 | 1 | Portable audit filename and retention rules |
| `tests/unit-nul-redaction.sh` | 3 | 1 | NUL-only masking on supported jq versions |
| `tests/unit-quoted-words.sh` | 16 | 1 | The shell gate skips the quote-removal pass only for texts the pass returns unchanged |
| **Total: 10 suites** | **260** | | |

The suites extract the named functions from the CLI's source layout, reject
missing or duplicate definitions and invalid shell syntax, and source only
those bodies. A change to a function's layout may require updating the
extractor. Expected bytes are explicit fixtures, independent of the producer
under test. To repeat a negative control, copy the CLI to a temporary file,
break one behavior and run, for example,
`AGENT_GUARD_UNIT_SOURCE=/absolute/path/to/copy sh tests/unit-core.sh`. This
override affects the test harness only; do not point it at untrusted code.

Direct contracts do not replace the integration suites: private producer
contracts do not prove path policy, OS behavior or that an enclosing pipeline
keeps the producer's failure status (`tests/exec-framing-boundary.sh` covers
that at exactly 65536 captured bytes).

`make test` runs each suite once in its assigned partition and keeps the full
integration suite. Each suite contributes one outer assertion, regardless of
its inner count. To investigate one partition, use
`AGENT_GUARD_TEST_SHARD=2 tests/run.sh`; this is a local diagnostic, not a
substitute for the complete CI gates. A real scanner on PATH enables
additional integration assertions; CI requires them and the smoke test on its
Linux scanner job, and other partitions use synthetic scanner fixtures.

The full suite includes subprocess, file-mode and process-cleanup cases. Keep
HOME, warning/session state, Git repositories and output files isolated. Do
not cache a passing result, share mutable repositories across cases, or
replace a real OS boundary with a mock merely to shorten the suite.

## Coverage limits

There is no automatic line or branch coverage collector or percentage gate.
`bench/run.sh` reports behavior on synthetic leak-prevention channels; its
detection and false-positive metrics are not source coverage. Assertion
inventory comparisons detect omitted or duplicated cases, but do not prove
every branch ran or every security behavior was asserted.

A coverage experiment must state its exact interpreter, source files,
denominator and exclusions. A Bash-instrumented run cannot replace the normal
POSIX-sh or Apple awk runs, and GNU awk profiling would not establish Apple awk
behavior. Embedded awk/jq programs, child interpreters, external Git/scanner
behavior and actual host dispatch need separate accounting. Instrumentation
changes timing, so keep coverage separate from performance comparisons. Use
synthetic fixtures and never trace credentials.

Filesystem path resolution, shell-command interpretation, ACLs, Git index
semantics and process cleanup are poor candidates for extraction into unit
tests: their environment and security boundaries are part of what must be
tested. The CLI initializes and dispatches at load time, so sourcing it
wholesale is not an isolated unit-test interface.

## Selected Bash location pins

When `measure-selected-bash` reports a changed selected function, review its
`relative_lines` in `tests/selected-bash-locations.json`, then explicitly run:

```sh
sh scripts/devtools.sh refresh-selected-bash
```

This recomputes only `body_sha256` with the measurement's function extractor.
It preserves the selected lines and other metadata, and refuses to run when
`CI` is set. Measurement remains read-only and fails on a stale pin; CI never
refreshes the repository's pins. The command requires the existing Rust
developer toolchain.

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
   the PR. If no pre-fix failure was observed, call it added regression
   coverage, not completed TDD.

## CI checks

CI runs on pull requests and pushes to `main`: the first validates a proposed
change, the second validates the merged tree. Plugin Validation and HOL scan
have the same triggers but own different checks; they are not duplicate suite
runs. The release workflow relies on the existing check names and does not
rerun the suite itself. The required check/workflow mapping lives in
`.github/release-checks.tsv`; dispatch and publication both read it.
The release candidate runs the full matrix once. Publication reuses those
results only for an identical, reviewed release tree with one merge parent
equal to the PR base. Otherwise it requires checks on the merge commit. Manual dispatch
runs the full Linux/macOS matrix on the selected ref, so the main/release
matrix can be verified before merging a CI change.

| Check | Coverage |
| --- | --- |
| Agent Guard | Real scanner against the checked-out tree |
| Named suites (ubuntu-latest) | All suite partitions on Linux; real scanner integration and smoke test in partition 4 |
| Named suites (macos-latest) | Core, host adapters and Git on every PR, as two jobs (partition 1 under that name, partition 3 as `Core, host adapters and Git (partition 3)`); all partitions on main and `release/` PRs, with the mock scanner |
| Test (ubuntu-latest), Test (macos-latest) | Full-matrix aggregate on main, release PRs and manual dispatch; names consumed by release |
| PR subset test (ubuntu-latest), PR subset test (macos-latest) | Ordinary PR aggregate of every selected shard, including cancelled/failed jobs |
| Lint | ShellCheck on tracked shell scripts and actionlint on workflows |
| Plugin Layout | Codex, Claude, marketplaces, release archive, and submission metadata |
| HOL Plugin Scanner | Independent plugin scanner |

Only Linux partition 4 installs the pinned, checksum-verified real scanner; the
other partitions use the suite's mock. No cache is used: downloading the small
pinned archive keeps checksum verification at the point of use. Plugin Layout
runs the validator's `--all` mode; submission validation stays separate.

## One dispatch and one approval

Dispatch `release.yml` on current `main` with the bump or explicit version.
Preparation opens a release PR. Verification dispatches the required workflows
with the built-in token and waits up to an hour for missing or unfinished
checks. Failed checks fail immediately. It also waits for performance evidence.
Only verification holds the Actions dispatch permission; workflow defaults
remain read-only. No additional credential or repository setting is needed.

Human PR merge approves publication. A merged, release-labelled bot PR starts
publication automatically. The branch and manifest version must match, and
the merge must still be current `main`. CI and native qualification reuse the
head's successful checks only when the merge has the same tree and one parent
equal to the reviewed PR base. Squash and single-commit rebase merges satisfying
that proof are eligible. API errors, missing checks, different trees and
ordinary main pushes keep full main coverage. Job summaries record the source
head and check links. Native artifacts must have executed successfully on all
three platforms at that source SHA; packaging verifies checksums and source
metadata. Publication rechecks current main before touching tags.

Use `dry_run` on a branch to exercise candidate creation, CI dispatch, waiting,
tree comparison and the same asset qualification job. Candidates use isolated
branches and an explicit marker; their merge cannot authorize publication.
Tags, releases and the tap are skipped. Close the test candidate and remove its
branch afterward. `tests/release-flow.sh` covers merge-trigger conditions and
different-tree fallbacks; dry runs do not prove real merge or publication.

An explicit version retries a merged, unpublished release without another PR.
Published releases are immutable. `replace_stale_branch` explicitly replaces
a stale candidate only when no open PR exists and a lease matches the observed
branch SHA.

Performance artifacts preserve `verdict.txt`, tool stderr and `source.json`.
The source records the job's check run ID, workflow run ID, attempt and head
SHA. The [GitHub job context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)
provides the check identity without extra API permissions on measurement jobs.
The shared verdict accepts evidence only when these identities match the latest
completed job and its conclusion. Missing, stale, cancelled or ambiguous
evidence counts as not measured, even when earlier complete evidence exists for
the same SHA. Partial reruns with ambiguous cached metadata may need a fresh
full performance run.

`performance-verdict.sh` classifies release and nightly evidence alike.
Completed threshold excess warns; absent, unfinished or invalid measurements
block publication. Required adoption improvement and correctness validation
still fail closed. Nightly issue bodies preserve tool errors verbatim and use
a cause fingerprint so different failures open separate issues. Runner CPU
alone does not change the issue identity.

## Test partitions

`tests/run.sh` without `AGENT_GUARD_TEST_SHARD` runs every partition in
order. CI runs them all on Linux for every PR and on both operating systems
for main pushes and PRs whose source branch starts with `release/`. Other PRs
also run partitions 1 and 3 on macOS, each on its own runner. Fixtures stay
local to each partition, and moved groups initialize their own repositories,
configuration and sessions.

| Internal ID | Actions suite | Contents |
| --- | --- | --- |
| 1 | Core, host adapters and Git (with 3 on Linux; alone on macOS) | Core, host adapter and Git contracts, direct unit suites, protected-path fixture suites |
| 2 | Command policies | Command policies, git aliases and mask suites |
| 3 | Core, host adapters and Git (with 1 on Linux; `Core, host adapters and Git (partition 3)` on macOS) | Auto-staging cases and the heaviest hook fixture suites |
| 4 | CLI, scanner and output | Real scanner integration, output masking, PII and shell setup |
| 5 | Shell navigation (Claude), Shell navigation (Codex) | Shell navigation, split by host |

Partitions are balanced by measured macOS job time, not assertion count. On
Linux one core runner runs partitions 1 and 3 side by side, so the slower of
the two sets the job time; on macOS each runs on its own runner, because both
on one three-core runner reached the 25-minute job limit. Heavy fixture suites
that run the hook hundreds of times go where there is room:
`tests/key-name-masking.sh`, `tests/deny-path-regex-cache.sh` and
`tests/message-value-prose.sh` run in partition 3, while
`tests/tracked-file-exception.sh` and `tests/path-operands-only.sh` stay in
partition 1 beside the other protected-path suites. When you move a suite,
compare the macOS job times of both partitions. Do not raise the timeout, and
do not move the slowest case to another partition only to move the bottleneck.

Shell navigation runs on one runner per host contract. Claude and Codex differ
in where the input carries the cwd/workdir and in the response contract, and
each worker runs the full real hook, Bash and Git checks for its host. The test
list is never cut by number or count. The assertions common to both hosts run
once, in the Claude worker. Each worker isolates its fixture repositories,
TMPDIR and output files. `AGENT_GUARD_TEST_NAVIGATION_HOST` selects a host,
and only for the navigation partition: an unknown host or a combination with
another partition exits with an error. The default `tests/run.sh` runs both
hosts.

Partition 1 checks that every partition is present in the matrix: partitions
1 and 3 twice each (the Linux bundle and the two macOS entries), every other
partition once, and the Claude and Codex navigation entries without a gap or a
duplicate. The full matrix therefore has 11 test jobs; an ordinary PR runs 5 on
Linux and the 2 macOS core jobs. Each core parent waits for every child and
fails the job if any child fails or its output cannot be collected.

## Run lifecycle

A newer commit cancels obsolete runs of the same workflow on the same PR.
Main pushes and manual checks use unique run groups, so they keep their own
validation. The serialized release workflow is separate and is never cancelled
by a PR update. Reduced PR runs use distinct aggregate names, so a later subset
success on the same SHA cannot replace full macOS evidence, and the full
`Test` names are never emitted by a reduced run. Coverage and check identity
share one scope decision in the Agent Guard job; test shards start after that
job succeeds. `sh tests/ci-scope.sh` tests that decision and its workflow
wiring. Ordinary PRs defer macOS command, navigation and scanner/output
coverage until main, so macOS-specific failures outside the core bundle are
found later.

Legacy jq/awk and Rust contracts also run after relevant changes merge to
main, under their own check names. Rust contracts compile with the pinned
toolchain and exercise differential, real-scanner, fallback and output/audit
regressions on Linux; the regular macOS suite does not imply native-helper
validation on macOS.

A queued job without an assigned runner has not started its test budget, and a
longer test timeout cannot fix runner allocation delays. Concurrency settings
apply to new runs only. Cancel only superseded PR runs, keeping the current PR
head and any release or main evidence still needed for publication.

## Reading test results

Each partition prints its execution seconds and passed/failed counts in the
Actions job summary, followed by every suite's seconds and exit status (slowest
first) and the job's elapsed time against its limit, with a warning above 80%. The Run tests step groups the full assertion stream, with
failures and final counts repeated outside the group; expand the **full test
assertions** group for all diagnostics. The original output also stays in the
runner's `test-output.txt` for the Linux real-scanner presence gate. Every
child exit status is collected, including after another child fails; printing
a summary cannot make a failing suite pass.

When comparing CI timing, separate wall time (creation to last job
completion), queue/start delay, test-step duration and summed runner time.
Hosted-runner variability can overwhelm a single comparison, and a lower wall
time alone does not establish lower billed cost.

## Measurements

Benchmark tools live under `bench/`. Do not commit generated reports, raw
measurement output, or goal and plan notes: write them to the ignored
`bench/local/` directory, a release asset or a CI artifact. Update the
relevant guide instead of adding one document per PR; Git history keeps
earlier discussion.

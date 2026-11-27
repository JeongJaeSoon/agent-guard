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
| OS/tool integration | Git fixtures in `tests/run.sh`, permission/ACL/symlink/signal cases, `pii-utf8.sh`, Linux real-gitleaks block, the rule suites of `tests/real-gitleaks-rules.sh` | Actual filesystem, Git and process behavior; Apple awk and scanner differences |
| Deployment and service integration | `make smoke-test`, archive/Homebrew validation, opt-in `make test-pleno-integration` | Real scanner/tool dependencies, installation and configured service boundaries |
| Authenticated host E2E | Separate Claude/Codex host-dispatch verification | Host loads and invokes the installed adapter; direct CLI calls or selecting a host environment variable do not establish this |

## Test-only environment variables

The hook launcher and the CLI read these so that tests can isolate warning
markers. They are not user settings. The CLI also keys the recovery notice it
queues for a blocked injected prompt on both, so a test of that recovery keeps
both the same across its hook calls. The notice is queued only in a directory
that is private: let the CLI create it, or create it as a non-symlink owned by
the current user with mode `0700`.

| Variable | Use |
| --- | --- |
| `AGENT_GUARD_SESSION_ID` | A non-empty value replaces the payload's `session_id` as the key that deduplicates notices; an empty one counts as unset. The CLI accepts only ASCII letters, digits, `.`, `_` and `-`; with any other character it keys on the host and parent process ID instead (the launcher hashes any value) |
| `AGENT_GUARD_WARNING_DIR` | Directory of the notice markers and queued recovery notices (default `${TMPDIR:-/tmp}/agent-guard-warnings-<uid>`) |

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
Linux scanner job, and other partitions use synthetic scanner fixtures. The
suites that check the rules of `gitleaks.toml` run through
`tests/real-gitleaks-rules.sh`, which partition 4 starts unless the workflow
runs it as a step (see "Test partitions").

The full suite includes subprocess, file-mode and process-cleanup cases. Keep
HOME, warning/session state, Git repositories and output files isolated. Do
not cache a passing result, share mutable repositories across cases, or
replace a real OS boundary with a mock merely to shorten the suite.

## Coverage limits

There is no automatic line or branch coverage collector or percentage gate.
Assertion inventory comparisons detect omitted or duplicated cases, but do not prove
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

## Hook latency measurement

`hook-latency` times the hook events an agent session fires most (PreToolUse
for Bash, Write and Read, PostToolUse for Bash, UserPromptSubmit) on synthetic
inputs. It builds a temporary repository, home and state directory and passes
the hooks only that environment, so it reads no user settings and no caller
variables:

```sh
sh scripts/devtools.sh hook-latency --scanner /abs/gitleaks \
  --helper /abs/dir-with-agent-guard-scan --runs 30 --out bench/local/hook-latency.json
```

One run interleaves these arms: `helper-off` (no warm helper installed),
`first-call` (a helper is installed and none is running), `warm-helper`,
`repeat-input` (the same input again, where the clean-scan cache can hit)
and `fallback` (a helper is installed and the client hands every scan to
gitleaks). Without `--helper` only `helper-off` and `repeat-input` run.
`--entry manifest` runs the Claude plugin manifest's command, so the launcher
is timed too; `--binary` measures another checkout's CLI.

The file named by `--out` holds every sample with what was observed, not
assumed: `scanner` (the scan client's trace, or the peak memory of the hook's
children where no client is selected), `cache` (whether the clean-scan cache
gained an entry or answered) and `probe` (whether the readiness probe ran).
Standard output is the per-arm summary. The command fails when a sample did
not run the path its arm names, so a helper that silently fell back, or a
hook that passed without scanning, is never reported as measured. A sample
that also ran the readiness probe is kept in the file and left out of the
summary. `--scanner` must be the official gitleaks release build for the
helper arms; `--unverified` accepts a test double whose runs cannot be
told from a hook without a scan, and the report then says `verified: false`.

## CLI differential

`cli-differential` runs two builds of the CLI over a corpus of hook inputs
and fails on any difference. It is the parity check for a change that must
not alter a decision: another interpreter, a launcher change, a refactor.

```sh
sh scripts/devtools.sh cli-differential --baseline /abs/base/plugins/agent-guard/bin/agent-guard \
  --candidate "$PWD/plugins/agent-guard/bin/agent-guard" --scanner /abs/gitleaks \
  --out bench/local/cli-differential.json
```

Each case of `tests/fixtures/cli-differential.json` (or `--corpus`) is a
list of steps run in order in one fresh sandbox: the repository, home, state
and temporary directories are rebuilt at the same path before each side
runs, so both start from the same state and neither sees the caller's
variables. Compared for every step: exit status, the decision the host is
told, standard output and standard error byte for byte, the audit events
written, and the files left behind. `--baseline-shell` and
`--candidate-shell` run a side under a named interpreter;
`--entry manifest` runs the host's plugin manifest command. The hooks get
no locale variable, not the caller's either, so both sides run in the C
locale, where a shell handles text byte by byte; `--locale NAME` (a name
`locale -a` lists, such as `en_US.UTF-8`) sets `LC_ALL` for every hook
and is recorded in the report. Run a change of interpreter
both ways: a shell with multibyte support differs from one without only in
such a locale.

What two runs of one build may differ in is not compared and is listed in the
report as `not_compared`: the time, run identifier and duration of an audit
event, the content of the CLI's cache files and the times and hashes in their
names, the times Git keeps in its logs and beside its index entries (the
index is compared as `git ls-files --stage -v` lists it), and the time a
warning marker holds. Every other entry of the sandbox is compared by name,
permission bits and content. A new entry there needs a reason; a difference is otherwise a bug in
the change.

The report holds case names, sizes, equality, the first differing offset and
a count of what each step left by kind (audit event, cache, state file,
temporary file, home file, repository file, other sandbox file), never the
text of an input or
an output and never a file name, which can hold a session identifier. So the
same command is safe on a corpus that is not synthetic. `--names` prints the
names of the entries that differ to standard error, for a synthetic corpus.
A comparison that cannot finish (a timeout, state it cannot read, a build
that wrote to the scanner directory both sides share) replaces any earlier
report with one that says `complete: false`; `--out` may not name a file
the comparison reads. A corpus is trusted input: a
step can be `exec`, which runs a command. Its `env` may set only
`AGENT_GUARD_` variables, and no value may be a path other than one under
`/nonexistent/`. Corpus strings may use `{{REPO}}`, `{{TOKEN}}`,
`{{HEX}}` and `{{KEY_BLOCK}}`; the last three are values built at run time
that a scanner must report, so the corpus itself holds none.

Before trusting a result, qualify the comparison on the machine at hand: a
build against itself must report no difference (run it twice), and
`tests/devtools.sh` shows that a changed message and a changed deny list are
both found.

## Rule mutation check

`tests/mutations.json` lists hand-written mutants of the core detection rules:
each entry is one literal edit (`old` occurs exactly once in
`plugins/agent-guard/bin/agent-guard` and becomes `new`) that loosens one
rule, and the test files that must catch it. Run:

```sh
sh tests/mutation-check.sh            # every mutation
sh tests/mutation-check.sh ID...      # only these
```

The script copies the tree to a temporary directory and never edits the
checkout. It first requires the listed tests to pass on the unmutated copy,
then requires at least one of them to fail on each mutant. It exits 1 and
prints the id and rule of a surviving mutant, and exits 2 when it cannot
judge (an edit that no longer applies, a failing baseline).
`AGENT_GUARD_MUTATION_JOBS` sets how many copies run side by side.

When you change a listed rule, update its mutation so that it still applies.
When a review finds a loosened copy of a rule that passes the suite, add the
missing test row and the mutant. Never weaken a mutant to make it pass. The
`Rule mutation check` workflow runs on pull requests that touch the bin, the
list or a listed test; `tests/run.sh` checks that the workflow lists every
test file the list names.

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

## Revert and compatibility switches

A setting that reverts a behavior change, or keeps earlier behavior available,
states its removal condition in the pull request that adds it. List it under
[Compatibility and hardening switches](docs/configuration.md#compatibility-and-hardening-switches),
not among the policy settings, and add its row to
[Unrecognized values](docs/configuration.md#unrecognized-values).

## CI checks

CI runs on pull requests, pushes to `main` and nightly on `main`: the first
validates a proposed change, the second validates the merged tree. A main
push of an ordinary PR merge reuses the newest CI run at that PR's head when
it succeeded and its `tested-tree` artifact (the tree of the merge commit the
run checked out, recorded only when its suites ran) equals the pushed tree;
otherwise it runs every suite on Linux only, under `Main subset test` names. The nightly run covers the macOS legs
and is skipped when `main` has not changed since the last green nightly run.
Any failed lookup runs everything. Plugin Validation and HOL scan
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
| Named suites (ubuntu-latest) | All suite partitions on Linux; real scanner integration and smoke test in partition 4; the real-scanner rule suites as a step of Shell navigation (Codex) |
| Named suites (macos-latest) | Core, host adapters and Git as three jobs (partition 1 under that name, partitions 3 and 6 as `Core, host adapters and Git (partition 3)` and `(partition 6)`) and Command policies as two (partition 2 under that name, partition 7 as `Command policies (partition 7)`), plus every other partition, on release merges, the nightly run, manual dispatch and `release/` PRs, with the mock scanner |
| Test (ubuntu-latest), Test (macos-latest) | Full-matrix aggregate on release merges, the nightly run, release PRs and manual dispatch; names consumed by release |
| Main subset test (ubuntu-latest), Main subset test (macos-latest) | Linux aggregate on a main push of an ordinary PR merge |
| PR subset test (ubuntu-latest), PR subset test (macos-latest) | Ordinary PR aggregate of every selected shard, including cancelled/failed jobs |
| Lint | ShellCheck on tracked shell scripts and actionlint on workflows |
| Plugin Layout | Codex, Claude, marketplaces, release archive, and submission metadata |
| HOL Plugin Scanner | Independent plugin scanner |
| Rule mutations fail a test (group) | Each hand-written rule mutant fails a listed test; runs on pull requests that change the CLI, the mutation list, the checker or test code, and release verification dispatches every group at the release SHA |

Only the Linux scanner job (partition 4) and the Linux Codex navigation job
install the pinned, checksum-verified real scanner, the second for the rule
suites that run after its partition; every partition other than 4 uses the
suite's mock. No cache is used: downloading the small
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
also run the macOS partitions on their own runners. Fixtures stay
local to each partition, and moved groups initialize their own repositories,
configuration and sessions.

| Internal ID | Actions suite | Contents |
| --- | --- | --- |
| 1 | Core, host adapters and Git (with 3 and 6 on Linux; alone on macOS) | Core, host adapter and Git contracts, direct unit suites, protected-path fixture suites |
| 2 | Command policies (with 7 on Linux; alone on macOS) | Command policies, git aliases and mask suites, plus the Bash text-as-data and operand fixture suites moved from partition 1 |
| 3 | Core, host adapters and Git (with 1 and 6 on Linux; `Core, host adapters and Git (partition 3)` on macOS) | Auto-staging cases and the heaviest hook fixture suites |
| 4 | CLI, scanner and output | Real scanner integration, output masking, PII and shell setup |
| 5 | Shell navigation (Claude), Shell navigation (Codex) | Shell navigation, split by host |
| 6 | Core, host adapters and Git (with 1 and 3 on Linux; `Core, host adapters and Git (partition 6)` on macOS) | The suites moved from partition 1 that each run the hook hundreds of times: the search, gh/jq program, here-document, environment-lookup, tool-coverage, plugin-management and long-input suites |
| 7 | Command policies (with 2 on Linux; `Command policies (partition 7)` on macOS) | `tests/bash-path-text-data.sh` and `tests/handback-values.sh`, moved from partition 2 |

Partitions are balanced by measured macOS job time, not assertion count. On
Linux one core runner runs partitions 1, 3 and 6 side by side, and one command
runner runs 2 and 7, so the slowest of each set sets the job time; on macOS each
runs on its own runner to stay under the 25-minute job limit (partitions 1 and 2
alone measured 21 to 25 minutes before 6 and 7 were split off). Heavy fixture suites
that run the hook hundreds of times go where there is room:
`tests/key-name-masking.sh`, `tests/deny-path-regex-cache.sh` and
`tests/message-value-prose.sh` run in partition 3, while
`tests/handback-values.sh`, `tests/bash-path-text-data.sh`,
`tests/path-operands-only.sh`, `tests/redaction-wrapped-values.sh` and
`tests/tracked-file-exception.sh` run in partition 2, which had room while
partition 1 alone reached the 25-minute limit on macOS;
`tests/partition-membership.sh` keeps them there. The CI log of each core job
prints per-suite seconds and, per partition, the total beside the timed-suite
sum, so the next move can be chosen from measured numbers. When you move a suite,
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

On Linux CI the Codex navigation job then runs `tests/real-gitleaks-rules.sh`:
the eight suites that check the rules and allowlists of `gitleaks.toml`, there
against the real scanner. They are a step of that job, not a job of their own,
because branch protection requires the job by name and the scanner job is the
longest of a pull request. The step fails the job when a suite fails or skips,
or when the scanner is missing. The workflow sets
`AGENT_GUARD_TEST_RULE_SUITES_STEP` for its Linux test jobs; without it, on
macOS and in a local run, `tests/gitleaks-probe-cache.sh` (partition 4) starts
the same file as one assertion, and without a real scanner five of the suites
skip and three run on the mock. `tests/ci-scope.sh` checks
that wiring and that a change to the config, a suite or the driver runs the
job.

Partition 1 checks that every partition is present in the matrix: partitions
1, 2, 3, 6 and 7 twice each (the Linux bundle and a macOS entry), every other
partition once, and the Claude and Codex navigation entries without a gap or a
duplicate. `tests/partition-membership.sh` checks the other side: every suite
that `tests/run.sh` starts sits in exactly one partition block, and every other
test file is started by a workflow, a suite or the Makefile. The full matrix
therefore has 13 test jobs (5 on Linux, 8 on macOS); an ordinary PR runs the 5
Linux jobs. Each core parent waits for every child and fails the job if any
child fails or its output cannot be collected.

## Run lifecycle

A newer commit cancels obsolete runs of the same workflow on the same PR.
Main pushes and manual checks use unique run groups, so they keep their own
validation. The serialized release workflow is separate and is never cancelled
by a PR update. Reduced PR runs use distinct aggregate names, so a later subset
success on the same SHA cannot replace full macOS evidence, and the full
`Test` names are never emitted by a reduced run. Coverage and check identity
share one scope decision in the Agent Guard job; test shards start after that
job succeeds. `sh tests/ci-scope.sh` tests that decision and its workflow
wiring. Ordinary PRs and their merges defer macOS coverage to the nightly
run and the release PR, so macOS-specific failures are found up to a day
later.

Legacy jq/awk and Rust contracts also run after relevant changes merge to
main, under their own check names, unless the PR run of the same workflow
already passed on the same tree (the macOS developer tools job always runs). Rust contracts compile with the pinned
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
relevant guide instead of adding one document per PR.

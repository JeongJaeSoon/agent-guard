# Test layers, coverage and regression workflow

Agent Guard currently relies primarily on CLI contract and integration tests.
A count of passing assertions is an inventory check, **not a code-coverage
percentage**. The execution partitions described in [CI](ci.md) are scheduling
units, not security tiers or test-pyramid layers.

## Current layers

| Layer | Existing entry points | What they establish |
| --- | --- | --- |
| Static and packaging | ShellCheck, actionlint, plugin/layout and submission validators | Shell/workflow errors and packaging contracts |
| Fast core contracts | `make test-unit` / `tests/unit-core.sh`, `tests/unit-framing.sh` | Version comparison and shell quoting: 35 assertions; framing producers: 18 assertions; see [scope and negative controls](unit-tests.md) |
| Narrow component comparisons | `tests/framed-leaves.sh` | Framing fast path versus byte-decoder reference, escaping, byte boundaries and explicit detector expectations |
| CLI contracts | `tests/deny-read-mask*.sh`, `source-module-prose.sh`, `hook-outcome-contract.sh`, `gitleaks-resolution.sh`, `audit-log.sh` | Exit status, host payloads, diagnostics, masking and infrastructure policy through the CLI |
| OS/tool integration | Git fixtures in `tests/run.sh`, permission/ACL/symlink/signal cases, `pii-utf8.sh`, Linux real-gitleaks block | Actual filesystem, Git and process behavior; Apple awk and scanner differences |
| Deployment and service integration | `make smoke-test`, archive/Homebrew validation, opt-in `make test-pleno-integration` | Real scanner/tool dependencies, installation and configured service boundaries |
| Authenticated host E2E | Separate Claude/Codex host-dispatch verification | Host loads and invokes the installed adapter; direct CLI calls or selecting a host environment variable do not establish this |

`make test-unit` runs the fast core contracts; `make test` includes them once
in partition 1 and retains the full integration suite. To investigate one partition, use
`AGENT_GUARD_TEST_SHARD=2 tests/run.sh`; this is a local diagnostic selection,
not a substitute for the complete CI gates. Narrow scripts can also run with
`sh tests/source-module-prose.sh` or `sh tests/framed-leaves.sh`. A real scanner
on PATH can enable additional integration assertions. CI requires those
assertions and the smoke test on its Linux scanner job; other partitions use
synthetic scanner fixtures. Preserve both Linux and macOS checks.

The full test suite includes subprocess, file-mode and process-cleanup cases.
Keep HOME, warning/session state, Git repositories and output files isolated.
Do not cache a passing result, share mutable repositories across cases, or
replace a real OS boundary with a mock merely to shorten the suite.

## Coverage we do and do not measure

There is no automatic line/branch coverage collector or percentage gate in
these workflows. A local [scoped source-line measurement](coverage-core.md)
observed 4/4 selected Bash command-start lines, with a definition-only control at 0/4.
This excludes AWK and is not whole-file or repository coverage. `bench/run.sh` reports behavior on synthetic leak-prevention
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

# Fast core contracts

Run `sh tests/unit-core.sh` for 35 assertions against the production `version_newer`
and `sh_squote` function bodies. This component test needs only POSIX shell,
awk, sed, cmp and ordinary system utilities; it does not initialize the CLI,
create a Git repository, install a scanner or invoke a host adapter.

`make test-unit` also runs the 18 [framing producer contracts](unit-framing.md).

The suite isolates the two named functions using their existing source layout,
rejects missing/duplicate definitions and invalid shell syntax, and sources
only those bodies. A change to their layout may require updating the extractor.
The CLI's public API and startup behavior are unchanged.

| Contract | Assertions | What is measured |
| --- | ---: | --- |
| Numeric version comparison | 15 | Equal/greater/less, component precedence, multi-digit values, existing leading-zero behavior; exit status and no output |
| Shell single-quote encoding | 10 | Exact expected bytes for empty input, spaces, quotes, backslash, metacharacters, options, Unicode, tab and trailing newlines |
| Shell argument round trip | 10 | Exactly one literal argument, preserved bytes, no stderr or command-substitution side effect |

`tests/run.sh` runs this component suite once in partition 1, on both existing
CI operating systems. The 35 internal assertions are represented by one new
outer assertion. No existing assertion, integration suite, scanner check or
platform matrix entry is removed. `make test` still runs the full suite.

## Evidence and limits

Before wiring the tests into CI, six deliberately faulty source copies failed:
accepting equal versions as newer, reversing the version comparison, returning
raw unquoted text, failing to escape apostrophes, removing a function and
duplicating a function. The unchanged production source then passed all 35
assertions in about 0.16–0.18 seconds locally on macOS. To repeat a negative control,
copy the CLI to a temporary file, change one of those behaviors and run
`AGENT_GUARD_UNIT_SOURCE=/absolute/path/to/copy sh tests/unit-core.sh`.
This override affects the test harness only. Do not point it at untrusted code.

These are characterization tests with mutation-based red controls, not a claim
that an existing production bug was fixed. Six selected controls detected out
of six tried is not a general mutation score. The elapsed time is one local
observation, not evidence of faster full CI: the new checks add work and give a
fast developer feedback path.

The table describes contracts, not a source-coverage percentage. The separate
[scoped Bash measurement](coverage-core.md) records four command-start lines;
AWK branches and scanner/host behavior remain unmeasured. See the shared
[test-layer guide](testing.md) for integration boundaries and remaining gaps.
Framing producer contracts are implemented in [the framing suite](unit-framing.md).

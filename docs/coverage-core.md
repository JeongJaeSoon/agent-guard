# Scoped source-line coverage measurement

Measured on 2026-10-17 against main `3b614880580a674748fe4e0a438e6b15d67a1fc1`,
on macOS arm64 with installed `/bin/bash` 3.2.57. This is execution tracing of
**four selected shell command-start source lines**, not assertion counting,
whole-function multilingual coverage, whole-file coverage or branch coverage.

| Production CLI line | Shell operation | Observed DEBUG events | Covered |
| ---: | --- | ---: | --- |
| 134 | Opening quote printf | 10 | yes |
| 135 | Value printf piped through sed | 20 | yes |
| 136 | Closing quote printf | 10 | yes |
| 234 | Invoke awk version comparator | 15 | yes |

The explicit denominator is the three executable physical shell lines in
`sh_squote` and the one shell command-start line in `version_newer`.
Declarations, braces and the multiline AWK program are not eligible shell
command-start lines. **4/4 eligible lines were observed**. The pipeline produces
two events on one line, counted as one covered line. Event totals are not
execution-frequency or branch coverage metrics. The instrumented test exited 0
with 35 passing assertions. A definition-only control sourced both functions without invoking them and
produced **0/4**, confirming the
report does not mark the selected lines covered merely because they exist.

## Reproduce without installing a tool

Run from the repository root. Only synthetic test data is used; the trace logs
source locations rather than expanded command arguments. The normal POSIX-sh
CI remains separate. The temporary function files are generated and removed
by the existing component suite; their line numbers map to the source above.

```sh
trace=$(mktemp)
status=0
AG_TRACE_OUTPUT="$trace" /bin/bash -c '
  set -T
  exec 9>"$AG_TRACE_OUTPUT"
  trap '\''printf "%s:%s\n" "${BASH_SOURCE[0]:-driver}" "$LINENO" >&9'\'' DEBUG
  . "$0"
' "$PWD/tests/unit-core.sh" || status=$?
# Function line 2/3/4 maps to CLI 134/135/136; version line 2 maps to 234.
# Ignore function-declaration events at line 1.
grep -E '/(sh_squote|version_newer)\.sh:[234]$' "$trace" | sort | uniq -c
rm "$trace"
(exit "$status")
```

For the definition-only control, replace `. "$0"` in the Bash snippet with
the following code. This loads the test's extraction/setup section and sources
both functions, stopping before its first assertion. No eligible function
locations should appear. Recheck both extraction and line mapping if code moves.

```sh
partial=$(mktemp)
awk '/^pass=0$/{exit}{print}' "$0" >"$partial"
. "$partial"
rm "$partial"
```

When inserting this into the single-quoted command above, escape the awk
program's single quotes in the same way as the trap's quotes.
Source SHA256: `669566dab17415bd0993b83655cbb0c3b8ea3dca2ad8cca3bc341558d86a5a6c`.
Test SHA256: `74ad29ccbd8827e45af6ad38fc3a8724478509ea892de3c7cd3ef7b58b76ca38`.

## Exclusions and tool suitability

- The AWK program at CLI lines 235–240, including both comparisons and loop
  branches, is **unmeasured**. Reaching its invocation does not cover its body.
- Embedded jq filters, sed internals, child shells, Git/scanner/host processes, startup/dispatch and
  all other CLI functions are **unmeasured**. No overall percentage is reported.
- Bash tracing changes the interpreter and execution behavior. It establishes
  neither POSIX-sh source coverage nor Apple awk branch coverage. Instrumented
  timing is not a performance baseline. Branch coverage is **not measured**.
- Installed tools included Bash 3.2.57, Apple awk 20200816, jq and Python;
  kcov and GNU awk were absent. No Python production code was found in the
  tracked application, so Python coverage tooling would not cover this CLI.
- [kcov](https://github.com/SimonKagstrom/kcov) supports Bash and reports source
  coverage. Its [macOS build instructions](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md)
  require additional build dependencies and may require debug-entitled signing.
  It was not installed or run. A future standard-collector trial needs a
  supported isolated environment and its normal dependencies; it still cannot
  claim coverage of embedded AWK from a Bash invocation line.
- POSIX shell application/scripts and Bash CI helpers require interpreter-aware
  tracing; the run above includes only the selected application functions.
  JSON/YAML/TOML configuration uses schema/behavior validation, not executable
  line coverage. No installed jq branch-coverage collector was identified.
- GNU awk profiling would require installing GNU awk and running the extracted
  program under it. Apple awk has no equivalent profiler exposed by this
  installed version; GNU results must not be relabeled as Apple awk coverage.

This deliberately small measurement adds no CI gate, dependency, permission,
service, token or runtime change. It is a reproducible observation, not a
replacement for the existing cross-platform integration suite.

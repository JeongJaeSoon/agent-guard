# Scoped source-location observations

## Historical four-location measurement (2026-10-17)

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


## Recorded eight-function observation (2026-10-20)

The historical 4/4 above is unchanged. This separate observation runs the four
measured direct suites (35 + 18 + 83 + 4 = **140 assertions**) using installed
`/bin/bash` 3.2.57 on macOS arm64. The exact production source SHA256 is
`09d4b111f99998567cab969837037310fc70259220c0927d4fbe611f1cfb4380`.

Before running any fixtures, `tests/selected-bash-locations.json` fixes **40
physical Bash source locations in eight functions**. Each selected function's
body hash is checked before collecting events; source movement is mapped from
the unique definition, and a body change requires an explicit denominator
review. Locations include simple-command starts, `case` controls and `if`
condition commands. They exclude definition headers, braces, closing syntax,
comments and the contents/closing lines of multiline awk/jq programs.
Multiple commands or case arms on one physical line count as one location;
repeated DEBUG events do not increase the denominator.

| Function | Eligible production source lines | Observed | Missing |
| --- | --- | ---: | --- |
| `sh_squote` | 134, 135, 136 | 3/3 | none |
| `version_newer` | 234 | 1/1 | none |
| `frame_json_string_leaves` | 6712 | 1/1 | none |
| `frame_plaintext_leaf` | 6723 | 1/1 | none |
| `secretish_env_values` | 6751, 6752 | 2/2 | none |
| `deny_path_char_hex_pattern` | 4203–4218 | 16/16 | none |
| `deny_path_shell_expansion_char_pattern` | 4226, 4227, 4229, 4231, 4233, 4234, 4235, 4237, 4238, 4240, 4244, 4245, 4247 | 12/13 | 4240 |
| `deny_path_pin_char_pattern` | 4162, 4163, 4165 | 3/3 | none |

**39/40 selected locations were observed.** All eligible locations except 4240
appear in the observation. Line 4240 is the dot-character branch's fallback
assignment when the hex helper returns no pattern; the current real helper
always supplies a hex pattern for dot. It remains in the predetermined
denominator rather than being removed to produce a perfect result. This is an
explanation of the missing observation, not a general unreachable-code proof.
A separate process sources all eight definitions without calling them and
observes **0/40** eligible locations.

Run from the repository root with existing Python 3 and Bash (no installation):

```sh
python3 tests/measure-selected-bash.py
```

The script prints only aggregate counts, source line lists, interpreter/source
identity and test hashes. Temporary DEBUG traces contain **source paths and
line numbers only**, never `BASH_COMMAND`, expanded arguments or input/output
contents, and are deleted when collection ends. Function-only extraction uses
the same checked helper as the direct suites; the complete CLI is never sourced.
The collector pins `AGENT_GUARD_UNIT_SOURCE` to the hashed production file,
even when the caller sets a mutation override. A control with a nonexistent
caller override produced the same report. The collector is opt-in and adds no
CI dependency or percentage gate.

Bash may emit DEBUG events for pipeline commands, case controls and commands
inside inherited function/subshell execution. That records reaching the shell
source location, not every operation on that line or any embedded program.
The measurement **excludes AWK/jq/sed internals, external subprocess execution,
scanner logic, CLI startup/dispatch, actual authenticated host behavior and
branch/condition coverage**. Normal POSIX-sh tests and Linux/macOS integration
remain separate. This is neither whole-function semantic coverage nor a claim
of 100% whole-file or repository coverage; instrumented runtime is not a cost
baseline.

The later status-label direct suite is outside this recorded observation. Its
22 assertions do not change the fixed 40-location denominator or this result.

## Revalidated observation after main integration (2026-10-24)

After integrating main `2a076dc`, the `secretish_env_values` body hash
changed because #353 added detector rules. The manifest correctly rejected
the changed body before observation. Its two selected relative locations
remain the `record_mode` assignment and the `LC_ALL=C awk` invocation
(lines 2 and 3); no embedded AWK lines enter the denominator. After reviewing
these locations, only that function hash was refreshed. The other seven
function hashes and all 40 selected relative locations are unchanged.

The new production source SHA256 is
`225966dc9f2bcddd6056c2e923b9868c65071a8cceacee4bfd963c15e92315a8`.
The same four suites passed 140/0 under Bash 3.2.57 on macOS arm64:
**39/40** selected locations were observed and the definition-only control
observed **0/40**. The missing location is now line **4260**, the same dot
fallback assignment previously recorded at 4240. The detector invocation
locations are now 7330 and 7331. This is a separate observation; it does not
rewrite the 2026-10-20 result or measure the new embedded AWK branches.

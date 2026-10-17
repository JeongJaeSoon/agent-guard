# Direct framing producer contracts

`make test-unit` runs 35 core assertions and 18 framing assertions.
`sh tests/unit-framing.sh` runs only the framing producer contracts, directly
against extracted production function bodies without CLI startup.

## Why these checks add value

`tests/framed-leaves.sh` compares the detector's fast path with its byte decoder.
Its fixtures construct input framing using a jq expression in the test, rather
than invoking `frame_json_string_leaves` or `frame_plaintext_leaf`. A concrete
negative control removed the JSON producer's RS terminator: that existing
suite still passed, while the new direct producer suite failed. Keep both:
producer contracts and detector/decoder parity establish different behavior.

| Direct contract | Assertions |
| --- | ---: |
| JSON: no strings, empty/scalar/nested strings, non-string/key exclusion, newline, RS/US, Unicode, quote/backslash/tab/CR | 8 |
| Plaintext: empty input, absent/single/extra final LF, interior LF, RS/US, invalid UTF-8 plus Unicode, CRLF | 8 |
| jq/awk failure after partial output retains exit 23 and output | 2 |

Expected output bytes are explicit fixtures, independent of the producer and
decoder. JSON emits an RS and LF after each string leaf. Plaintext emits one
RS-terminated leaf and retains existing awk record semantics: one final LF is
consumed as the record terminator; preceding LFs remain. These tests characterize
that behavior, not a new byte-preservation promise for terminal newlines.
The harness rejects missing/duplicate function definitions and syntax errors.

## Validation and coverage limits

Seven deliberately faulty source copies failed: missing JSON boundary,
unescaped JSON US, unescaped plaintext RS, lost interior LF, missing plaintext
boundary, and swallowed jq/awk errors. Unchanged production then passed all 18
assertions in about 0.16 seconds on local macOS. These are characterization
tests with mutation red controls, not a pre-existing product bug fix or an
exhaustive mutation score. The test-only `AGENT_GUARD_UNIT_SOURCE` override can
repeat controls against a trusted temporary source copy.

The suite runs once in partition 1 on both existing CI operating systems. The
18 inner assertions contribute one new outer assertion. The old decoder suite,
all security/OS integration assertions and real-scanner gates remain. No runtime,
public API, workflow permission or required-check change is made. Adding tests
is not evidence of a full-CI speedup.

No source-line or branch percentage was measured for these producers. The
[previous four-line Bash measurement](coverage-core.md) applies only to the
version/quoting functions; it must not be extended to this suite. Assertions and
selected mutations are behavior evidence, not a source-coverage percentage.

The current local Apple awk is 20200816; GNU awk and kcov are absent, and the
installed Apple awk manual exposes no profiler. GNU awk's official
[profiling documentation](https://www.gnu.org/software/gawk/manual/html_node/Profiling.html)
describes statement, condition/true and else counts. With actual profile output
and an explicit denominator, those could measure selected branch outcomes;
they do not automatically establish complete branch/condition coverage, and
profile-to-source mapping is required. GNU awk observations would not establish
Apple awk behavior. No installation, privilege, cost or persistent access was
added. These byte contracts execute the installed awk; its internal branches
remain unmeasured.

## Recommended boundary for this batch

Keep the new fast producer contracts alongside existing integration tests.
A standard Bash/GNU awk profiling experiment has value when it answers a
specific remaining branch question; isolate and label its interpreter first.
Prioritize actual authenticated host dispatch and missing supported OS/CPU
validation when those environments are available. Do not move filesystem,
Git index, permissions, signals or scanner boundaries into mocks for speed.
Do not add a coverage percentage gate, paid runner or broad function extraction
on the strength of this small measurement. The separate PR #330 optimization
has no proven runtime benefit and remains a draft.

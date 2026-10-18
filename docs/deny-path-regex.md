# Deny-path regex character producers

The shell-expanded deny-path converter previously captured the output of a
shell function for every character, and captured another function inside it
for that character's hex alternative. Pinning characters added more command
substitutions. These are repeated shell-process boundaries, even though the
helpers use only shell builtins.

The three private character helpers now return through `sx_hex`, `sx_char`,
and `sx_pin`. The outer regex converter still runs in its original
command-substitution shell. No policy file, compiled regex, verdict, scanner
result, or mutable fixture is cached or shared between invocations. Rule order,
ERE syntax, matching, error handling, scanner deadlines and process cleanup
are unchanged. CI partitions, OS coverage and runner topology are unchanged.

`tests/unit-deny-path.sh` adds 83 direct producer assertions: the full supported
ASCII hex table, unsupported-input reset/status behavior, literal character
and pin patterns, Unicode/newline/empty cases, no stdout/stderr and caller
variable preservation. `make test-unit` runs these alongside the existing
35 core and 18 framing assertions. Full CLI tests remain necessary: private
producer contracts do not prove path policy or OS behavior by themselves.

A cloud Linux microbenchmark alternated three runs of the parent and candidate
under the same `sh`, compiling every default shell-expanded deny-path regex.
All 169,122 output bytes matched. Parent times were 1.078/0.990/1.124 seconds;
candidate times were 0.096/0.111/0.075 seconds (medians 1.078 and 0.096).
This measures regex construction, not whole-hook or CI speedup. The combined
136 component assertions took 0.349 seconds in that cloud environment.
GitHub macOS/Linux CI and repeated whole-workflow measurements are required
before claiming the CI wall-time target is met. See the PR for exact-head
validation and independent differential/mutation evidence.

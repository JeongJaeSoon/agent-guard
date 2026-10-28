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

`tests/unit-deny-path.sh`는 83개 직접 producer assertion으로 지원하는 ASCII hex
전체 표, 미지원 입력의 초기화와 상태, literal 문자 및 pin 패턴, Unicode·줄바꿈·빈 값,
stdout/stderr 부재와 호출자 변수 보존을 검증한다. `make test-unit`의 전체 suite 목록과
assertion 수는 [직접 계약 테스트 목록](testing.md#direct-contract-inventory)에서 관리한다.
이 내부 producer 계약만으로 경로 정책이나 OS 동작을 입증할 수 없으므로 전체 CLI
테스트도 필요하다.

## Historical construction measurement

A cloud Linux microbenchmark alternated three runs of the parent and candidate
under the same `sh`, compiling every default shell-expanded deny-path regex.
All 169,122 output bytes matched. Parent times were 1.078/0.990/1.124 seconds;
candidate times were 0.096/0.111/0.075 seconds (medians 1.078 and 0.096).
This measures regex construction, not whole-hook or CI speedup. The combined
136 component assertions took 0.349 seconds in that cloud environment.
GitHub macOS/Linux CI and repeated whole-workflow measurements are required
before claiming the CI wall-time target is met. See the PR for exact-head
validation and independent differential/mutation evidence.

## Current validation scope

The historical 136 count above predates the four probe assertions and is retained
with its original measurement. Current entry points, costs and integration
regressions are listed in [testing.md](testing.md). The selected Bash observation
in [coverage-core.md](coverage-core.md) measures physical shell locations in the
three character helpers, not regex semantics, complete case-arm coverage or
filesystem policy enforcement. In particular, multiple hex cases share a
physical source line. Full deny-read-mask CLI/OS contracts remain necessary.

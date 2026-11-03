# Bounded exec framing failure regression

This regression is limited to the known invalid-UTF-8, non-printenv exec route
at **65536 captured bytes**. On parent `2c1fe9674711b228450c9ec132c50010e1a2c4d8`,
producer empty/partial failures each on benign, assignment and already-sanitized
output produced **6 failing cases**: injection occurred exactly once and the
original command's exit 7 survived, but the output was not conservatively masked.
The remaining 18 controls passed. A POSIX pipeline returned the detector's
success while hiding the framing producer's failure.

The caller now captures and checks framing before invoking the detector. A
failed producer never reaches the detector; any producer/detector failure
replaces the entire output with `[REDACTED]`. The command's separately captured
exit status remains unchanged. Successful framing terminates in RS, so its
command substitution does not remove embedded terminal LF bytes. The existing
captured-output bound and >65536-byte raw probe remain unchanged.

Run `sh tests/exec-framing-boundary.sh` for these **24 assertions**:

- Nine normal cases: benign, assignment and sanitized output at 65535, 65536 and
  65537 captured bytes. Small assignment output is selectively redacted; the
  larger assignment follows existing whole-output masking. Benign/sanitized
  bytes are preserved.
- Twelve exact-65536 cases: producer/detector × empty/partial failure × the
  three output kinds. Each injected failure returns 23 exactly once; output
  must be fully masked while exec returns the original command's 7.
- Three trailing-LF controls: each adjacent size plus two terminal LFs. Initial
  command substitution removes those LFs before measuring the capture, and exec
  appends its usual single output LF. Source size is checked independently.

The shim records stage names only and checks exact call order; it delegates all
non-target awk calls to the installed awk. Byte expectations use literal test
values, not the detector's result. No real user's data, installed plugin hook or
host session is used. Temporary fixtures/logs are deleted when the suite exits.

After the minimal fix, all 24 passed with the bundled mock and with installed
real gitleaks 8.30.1 on macOS. The suite is included once in partition 4 on both
existing CI platforms. The existing 7 raw exec cases and 34 prompt cases remain
separate; this is not a wider vulnerability search or a claim about every size,
encoding, detector, scanner error or authenticated host boundary.

# Experimental Rust literal redactor

The normal CLI continues to use the shell/jq implementation. The optional Rust
helper replaces only `redact_tool_response_json`: detection, scan limits, PII,
policy, binary handling and host envelopes stay in the CLI. This is a development
experiment, not a complete Rust rewrite or a supported binary release.

Build with Rust 1.85.1 or later:

```sh
cargo build --release --locked --manifest-path native/redaction-core/Cargo.toml
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust
export AGENT_GUARD_RUST_CORE_BIN="$PWD/native/redaction-core/target/release/agent-guard-redact"
```

The binary path must be absolute and executable. Without an override the CLI
looks in its plugin's `libexec/agent-guard-redact`. Missing helpers, nonzero exits
and unsupported requests return to the existing jq implementation. Partial
helper output is discarded. The executable is trusted code, like the configured
scanner; do not select an untrusted binary. No compilation or download occurs at
runtime. Running a prebuilt helper does not require Rust, but portable platform
artifacts and installer integration remain future work.

The one-shot `redact-v1` protocol reads one UTF-8 JSON object from stdin:
`{"protocol":1,"response":...,"secrets":[...]}`. It emits a complete JSON response
only after successful parsing and transformation. Input values never appear in
error diagnostics. The helper preserves object keys, protocol discriminators,
Unicode character lengths, contextual-first and reverse equal-length ordering,
and the existing 256-spec / 8,000,000-work conservative replacement limits.

The caller already canonicalizes JSON with jq and masks NUL-bearing leaves.
Raw-core differential tests use jq 1.7.1; jq 1.6 has different NUL-string behavior.
The helper rejects nesting over 1,024 levels and the reserved
`$serde_json::private::Number` object key (including escaped spellings), allowing
the CLI to use jq instead of changing their shape. This key is significant to
serde_json's arbitrary-precision parser. Arbitrary-precision numbers and object
insertion order are retained for ordinary inputs.

Verification:

```sh
sh scripts/devtools.sh native-redaction --core "$AGENT_GUARD_RUST_CORE_BIN"
sh tests/redaction-plan.sh
sh scripts/devtools.sh native-integration --core "$AGENT_GUARD_RUST_CORE_BIN" --scanner /absolute/path/to/gitleaks
AGENT_GUARD_TEST_SHARD=4 sh tests/native-suite.sh
sh tests/native-suite.sh audit
```

The suite wrapper forwards the existing precise-stage fault injection to the
helper, then lets the failing jq fallback exercise the original fail-closed
assertion. Other faults still target their original stages. It also requires
proof that the native helper was invoked. Performance goals and measurements
are recorded in [the internal experiment goal](rust-experiment-goal.ko.md).

## Before expanding the experiment

Keep the scanner and its rules fixed when moving another output stage. Rust's
regex syntax is not interchangeable with jq/Oniguruma or gitleaks' Go regex
syntax. Preserve the executable-boundary fixtures for numbers, duplicate keys,
Unicode, invalid bytes, limits and partial failures; shell source-extraction
tests alone do not exercise a native implementation.

Default activation needs Linux/macOS × x64/arm64 artifacts, checksums, payload
completeness, launcher/protocol compatibility and interrupted-update/rollback
checks. The shell launcher still owns version resolution. A persistent daemon
would add secret lifetime, IPC authentication and session-isolation concerns;
this experiment keeps one-shot execution.

## Native artifact qualification

`native-platforms.yml` builds with Rust 1.85.1 and the locked dependencies on
four native runners. It executes each uploaded binary against the existing
1,024 differential/invalid-input cases, real-scanner Claude/Codex fallback
contracts, and audit suite with Cargo and rustc absent from PATH. A build alone
does not satisfy this gate. The aggregate fails if any platform fails.

| Artifact target | Native runner | Binary requirements |
| --- | --- | --- |
| `x86_64-unknown-linux-musl` | Ubuntu 24.04 x64 | Static musl; no glibc dependency |
| `aarch64-unknown-linux-musl` | Ubuntu 24.04 ARM64 | Static musl; no glibc dependency |
| `x86_64-apple-darwin` | macOS 15 Intel | macOS 14+ deployment target; system libraries |
| `aarch64-apple-darwin` | macOS 15 ARM64 | macOS 14+ deployment target; system libraries |

The build record includes the source SHA, compiler, actual OS/architecture and
dynamic-library inspection. CI artifacts contain the executable, SHA-256 file,
and execution evidence. Verify in the artifact directory with
`shasum -a 256 -c agent-guard-redact-TARGET.sha256` (replace `TARGET`). These are
qualification artifacts, not a published v3.7.0 release. Linux kernel portability
beyond the tested runners is not established by static linking alone. Existing
shell support remains unchanged. Installer/update validation and performance
qualification must pass before default activation or a release.

## Packaged helper integration (qualification)

The archive builder accepts `AGENT_GUARD_NATIVE_ARTIFACT_DIR`, a directory with
all four `agent-guard-redact-TARGET` executables and their `.sha256` files. It
verifies every checksum before including `libexec/` in the existing universal
archive. Bootstrap verifies that complete native payload before staging an
installation. A source-only archive still works through shell/jq.

In opt-in Rust mode, absent an explicit developer binary override or legacy
`libexec/agent-guard-redact`, the CLI selects the packaged target using the
running OS and architecture, verifies its checksum, then executes it. A missing,
changed, non-executable or failing helper falls back to shell/jq. Empty,
truncated or multiple JSON outputs are discarded even if the helper exits zero.
`AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell` explicitly selects shell. No runtime
compilation or network request is introduced. Checksums detect corruption;
they do not authenticate a malicious replacement of both binary and checksum.

Bootstrap builds the update beside the current directory, preserving unrelated
files, then replaces the directory with same-filesystem renames. Extraction or
commit failures and handled INT/TERM restore the previous installation. SIGKILL,
power loss and filesystem failure cannot run a shell cleanup trap; a previous
copy remains in the sibling `.agent-guard-update.*/previous` directory if the
process stops during the commit window. Preserve that directory and restore it
to the original installation path before retrying. Do not delete it blindly.

`tests/native-install.sh` exercises a published v3.6.14 install followed by a
candidate update, a fresh candidate install, checksums and actual scanner smoke.
Only candidate downloads are substituted; the original release downloads and
all installers execute. `tests/native-packaged.sh` checks both host envelopes
and proves the selected helper was invoked. The native CI repeats installation
and failure contracts on all four platforms without Rust on PATH.

`bench/native/run-packaged.sh` refuses to measure unless Docker exposes enforced
2-CPU, 1-GiB and no-swap limits. It uses the qualified musl binary, including
platform selection and checksum cost, against the frozen v3.6.14 shell source.
Raw results go to a new directory and every measured output is verified. A
successful collection is not a performance verdict: review the 10% improvement
and 5% regression criteria before default activation.

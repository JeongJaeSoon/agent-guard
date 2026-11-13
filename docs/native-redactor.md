# Rust literal redactor

The v3.7 release archive includes a prebuilt Rust helper, selected by default
for `redact_tool_response_json`. Detection, scan limits, PII, policy, binary
handling and host envelopes stay in the shell CLI. This is not a complete Rust
rewrite. Users need no Rust compiler. Missing or failing helpers safely return
to shell/jq; `AGENT_GUARD_EXPERIMENTAL_REDACTOR=shell` explicitly selects shell.
The existing environment-variable name is retained for compatibility.

Developers can still build an explicit override with Rust 1.85.1 or later:

```sh
cargo build --release --locked --manifest-path native/redaction-core/Cargo.toml
export AGENT_GUARD_EXPERIMENTAL_REDACTOR=rust
export AGENT_GUARD_RUST_CORE_BIN="$PWD/native/redaction-core/target/release/agent-guard-redact"
```

The override must be absolute and executable. It retains the existing trusted
executable contract, as does a manually installed legacy `libexec/agent-guard-redact`.
Otherwise the CLI selects the packaged platform helper and verifies its sidecar
checksum before executing it. Missing helpers, nonzero exits and unsupported
requests return to jq. Empty, partial or multiple JSON outputs are discarded.
No compilation or download occurs during masking.

## Source-only host plugins

Git marketplace plugins and source archives contain no binaries. They retain
shell fallback by default. To use a prebuilt helper without changing a host's
plugin cache, install the standalone release of the same version, verify its
helper, then expose the existing override to the host's launch environment.
Choose the exact target from the platform table below; this example is Linux x64:

```sh
target=x86_64-unknown-linux-musl
native_root="$HOME/.agent-guard/libexec"
(cd "$native_root" && shasum -a 256 -c "agent-guard-redact-$target.sha256") &&
  export AGENT_GUARD_RUST_CORE_BIN="$native_root/agent-guard-redact-$target"
```

For Homebrew the helper directory is `$(brew --prefix agent-guard)/libexec/libexec`.
Restart the host with the verified environment; this does not register or replace
its hooks. Explicit overrides do not recheck the sidecar on every request, so
only point at a trusted installation. Unset the override to return to the
plugin-local selection, or select `shell` to disable native execution entirely.

The one-shot `redact-v1` protocol reads one UTF-8 JSON object from stdin:
`{"protocol":1,"response":...,"secrets":[...]}`. It emits a complete JSON response
only after successful parsing and transformation. Input values never appear in
error diagnostics. The helper preserves object keys, protocol discriminators,
Unicode character lengths, contextual-first and reverse equal-length ordering,
and the existing 256-spec / 8,000,000-work conservative replacement limits.

The v3.8 helper also supports the opt-in pipeline's `prepare-v1 PLAIN FRAMED`
command in the same executable. It reads one JSON value and writes string-leaf
bytes and RS/US framing to two files already created in the caller's private
directory. Only after both writes complete does it emit `prepared-v1`. The shell
requires successful exit and that exact acknowledgement; otherwise it overwrites
the stages through the original jq path. Detection and policy stay in shell.
See [installation](installation.md#optional-fused-output-preparation-v38) for
verified prebuilt selection and opt-out. No second installed helper is required.

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
proof that the native helper was invoked. Earlier performance goals and
measurements are kept in Git history and the release tags, not in the tree.

## Before expanding the experiment

Keep the scanner and its rules fixed when moving another output stage. Rust's
regex syntax is not interchangeable with jq/Oniguruma or gitleaks' Go regex
syntax. Preserve the executable-boundary fixtures for numbers, duplicate keys,
Unicode, invalid bytes, limits and partial failures; shell source-extraction
tests alone do not exercise a native implementation.

Release qualification requires Linux/macOS × x64/arm64 artifacts, checksums,
payload completeness, launcher/protocol compatibility and interrupted-update/
rollback checks. The shell launcher still owns version resolution. A persistent daemon
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
`shasum -a 256 -c agent-guard-redact-TARGET.sha256` (replace `TARGET`).
The release workflow only publishes artifacts built from its exact
reviewed main commit after successful native execution and installation checks.
The public release provides each binary and checksum as well as the universal
archive. Linux kernel portability beyond the tested runners and execution on
macOS 14 are not established by static linking or deployment-target settings.
Existing shell support and failure fallback remain unchanged.

## Packaged helper integration

The archive builder accepts `AGENT_GUARD_NATIVE_ARTIFACT_DIR`, a directory with
all four `agent-guard-redact-TARGET` executables and their `.sha256` files. It
verifies every checksum before including `libexec/` in the existing universal
archive. Bootstrap verifies that complete native payload before staging an
installation. A source-only archive still works through shell/jq.

In default Rust mode, absent an explicit developer binary override or legacy
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
2-CPU, 1-GiB and no-swap limits. It uses the musl binary built by
`scripts/build-native-artifact.sh`, including
platform selection and checksum cost, against shell source
`9a0ee9eb2eed1e60b78d4404f985b077149c675d` (v3.6.14 plus the subsequent
snapshot-token compatibility fix, also present in the candidate).
Raw results go to a new directory and every measured output is verified.
`assess-packaged.sh` checks the measured identities, enforced limits and the
10% target improvement / 5% general latency regression criteria. A case that
exceeds 5% in the 9-pair screening is measured again with 21 fresh pairs, and
counts as a regression only if the confirmation also exceeds 5%
(`bench/native/confirm.jq`); `assessment.json` keeps the screening verdict and
`legacy-confirmation.json` the confirmed one. Its result is separate from final
CI and public-release verification. CI runs this and the fused measurement in
`performance.yml` nightly, on manual dispatch, and on release pull requests,
not on every main push. A nightly run that does not pass opens one GitHub issue,
and later failures comment on it. The release workflow reports the release
pull request's result as a warning and does not block on it. The pre-default
qualification measurements are kept in the `v3.7.0` release tag, not in the
tree.

After publication, `public-native-release.yml` checks actual public assets,
compiler-free fresh installs and updates from v3.6.15 on all four native
platforms, plus public Homebrew formula upgrades and canonical tap installs on
Linux x64 and both macOS architectures. Those results must be inspected before claiming
release validation is complete. Its `previous_version` input also supports
v3.6.14, the baseline used by the candidate installation tests.

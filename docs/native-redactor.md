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

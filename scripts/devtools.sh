#!/bin/sh
# Developer commands only; the installed guard never invokes Cargo.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
cargo build --release --locked --manifest-path native/devtools/Cargo.toml >&2
exec native/devtools/target/release/agent-guard-devtools "$@"

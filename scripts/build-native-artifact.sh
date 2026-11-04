#!/bin/sh
# Build on the target architecture; cross-compilation is not execution evidence.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
target=${1:?Rust target required}
out=${2:?output directory required}
case "$(uname -s):$(uname -m):$target" in
  Linux:x86_64:x86_64-unknown-linux-musl|Linux:aarch64:aarch64-unknown-linux-musl) ;;
  Darwin:x86_64:x86_64-apple-darwin|Darwin:arm64:aarch64-apple-darwin)
    export MACOSX_DEPLOYMENT_TARGET=14.0 ;;
  *) echo 'build target must match the native runner' >&2; exit 2 ;;
esac
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd -P)
cargo +1.85.1 build --release --locked --target "$target" --manifest-path "$ROOT/native/redaction-core/Cargo.toml"
name="agent-guard-redact-$target"
cp "$ROOT/native/redaction-core/target/$target/release/agent-guard-redact" "$out/$name"
chmod 755 "$out/$name"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$out/THIRD_PARTY_NOTICES.md"
# Execute the very artifact that will be uploaded, including Unicode and shape.
actual=$(printf '%s\n' '{"protocol":1,"response":{"text":"가 secret secret","type":"text","ok":false},"secrets":["secret"]}' | "$out/$name" redact-v1)
[ "$actual" = '{"text":"가 [REDACTED] [REDACTED]","type":"text","ok":false}' ]
(cd "$out" && shasum -a 256 "$name" > "$name.sha256")
{
  git -C "$ROOT" rev-parse HEAD
  uname -srm
  rustc +1.85.1 -vV
  file "$out/$name"
  case "$target" in
    *linux-musl) ldd "$out/$name" 2>&1 || : ;;
    *apple-darwin) otool -L "$out/$name"; vtool -show-build "$out/$name" ;;
  esac
} > "$out/$name.build.txt"

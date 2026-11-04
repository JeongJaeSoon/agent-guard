#!/bin/sh
# Pinned real scanner and jq reference, for all four native CI runners.
set -eu
out=${1:?output directory required}
case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    platform=linux_x64; jq_asset=jq-linux-amd64
    scanner_sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    jq_sha=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5 ;;
  Linux:aarch64)
    platform=linux_arm64; jq_asset=jq-linux-arm64
    scanner_sha=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    jq_sha=4dd2d8a0661df0b22f1bb9a1f9830f06b6f3b8f7d91211a1ef5d7c4f06a8b4a5 ;;
  Darwin:x86_64)
    platform=darwin_x64; jq_asset=jq-macos-amd64
    scanner_sha=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
    jq_sha=4155822bbf5ea90f5c79cf254665975eb4274d426d0709770c21774de5407443 ;;
  Darwin:arm64)
    platform=darwin_arm64; jq_asset=jq-macos-arm64
    scanner_sha=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
    jq_sha=0bbe619e663e0de2c550be2fe0d240d076799d6f8a652b70fa04aea8a8362e8a ;;
  *) echo 'unsupported native test platform' >&2; exit 2 ;;
esac
mkdir -p "$out"
out=$(CDPATH= cd -- "$out" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_$platform.tar.gz" -o "$tmp/scanner.tar.gz"
printf '%s  %s\n' "$scanner_sha" "$tmp/scanner.tar.gz" | shasum -a 256 -c -
tar -xzf "$tmp/scanner.tar.gz" -C "$out" gitleaks
curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/$jq_asset" -o "$tmp/jq"
printf '%s  %s\n' "$jq_sha" "$tmp/jq" | shasum -a 256 -c -
cp "$tmp/jq" "$out/jq"
chmod 755 "$out/jq" "$out/gitleaks"

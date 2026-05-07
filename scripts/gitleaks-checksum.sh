#!/usr/bin/env sh
set -u

# Fetches the published gitleaks release sha256 for every supported
# OS/arch (darwin x64+arm64, linux x64+arm64) and prints them with
# paste-ready snippets for both GitHub Actions YAML and
# 'agent-guard setup --install'.
#
# Usage:
#   scripts/gitleaks-checksum.sh [VERSION]
#
# When VERSION is omitted, defaults to the value pinned in action.yml.
# Override the source URL via AGENT_GUARD_GITLEAKS_CHECKSUMS_URL (used by tests).

DEFAULT_VERSION=8.30.1

case "${1:-}" in
  -h|--help)
    cat <<EOF
Usage: gitleaks-checksum.sh [VERSION]

Fetches https://github.com/gitleaks/gitleaks/releases/download/v<VER>/gitleaks_<VER>_checksums.txt
and prints the sha256 for every supported OS/arch (darwin x64 + arm64,
linux x64 + arm64), with paste-ready snippets for GitHub Actions YAML
(typical CI runner is linux/x64) and 'agent-guard setup --install'
(uses this machine's OS/arch).

Default version: $DEFAULT_VERSION (matches action.yml).
EOF
    exit 0
    ;;
esac

VERSION=${1:-$DEFAULT_VERSION}

LOCAL_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
LOCAL_ARCH=$(uname -m)
case "$LOCAL_ARCH" in
  x86_64|amd64) LOCAL_ARCH=x64 ;;
  arm64|aarch64) LOCAL_ARCH=arm64 ;;
esac

URL=${AGENT_GUARD_GITLEAKS_CHECKSUMS_URL:-"https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}/gitleaks_${VERSION}_checksums.txt"}

command -v curl >/dev/null 2>&1 || {
  printf 'gitleaks-checksum: curl is required\n' >&2
  exit 2
}

printf 'gitleaks-checksum: fetching %s\n' "$URL" >&2

if ! checksums=$(curl -fsSL "$URL"); then
  printf 'gitleaks-checksum: failed to fetch (does v%s exist at https://github.com/gitleaks/gitleaks/releases ?)\n' "$VERSION" >&2
  exit 2
fi

lookup_sha() {
  archive="gitleaks_${VERSION}_$1_$2.tar.gz"
  printf '%s\n' "$checksums" | awk -v archive="$archive" '$2 == archive {print $1; exit}'
}

DARWIN_ARM64=$(lookup_sha darwin arm64)
DARWIN_X64=$(lookup_sha darwin x64)
LINUX_ARM64=$(lookup_sha linux arm64)
LINUX_X64=$(lookup_sha linux x64)

if [ -z "$DARWIN_ARM64" ] || [ -z "$DARWIN_X64" ] || [ -z "$LINUX_ARM64" ] || [ -z "$LINUX_X64" ]; then
  printf 'gitleaks-checksum: missing one or more required entries for v%s\n' "$VERSION" >&2
  printf 'available archives:\n' >&2
  printf '%s\n' "$checksums" | awk 'NF==2 {print "  " $2}' >&2
  exit 2
fi

local_sha=$(lookup_sha "$LOCAL_OS" "$LOCAL_ARCH")

mark_local() {
  if [ "$1/$2" = "$LOCAL_OS/$LOCAL_ARCH" ]; then
    printf '   <- this machine'
  fi
}

printf 'gitleaks v%s — sha256 by OS/arch\n' "$VERSION"
printf '\n'
printf '  darwin/arm64: %s%s\n' "$DARWIN_ARM64" "$(mark_local darwin arm64)"
printf '  darwin/x64:   %s%s\n' "$DARWIN_X64"   "$(mark_local darwin x64)"
printf '  linux/arm64:  %s%s\n' "$LINUX_ARM64"  "$(mark_local linux arm64)"
printf '  linux/x64:    %s%s\n' "$LINUX_X64"    "$(mark_local linux x64)"
printf '\n'
printf 'GitHub Actions workflow (CI runners are typically linux/x64):\n'
printf '  gitleaks-checksum: "%s"\n' "$LINUX_X64"
if [ -n "$local_sha" ]; then
  printf '\n'
  printf 'agent-guard setup CLI (this machine: %s/%s):\n' "$LOCAL_OS" "$LOCAL_ARCH"
  printf '  agent-guard setup --install --gitleaks-checksum %s --gitleaks-version %s\n' "$local_sha" "$VERSION"
fi

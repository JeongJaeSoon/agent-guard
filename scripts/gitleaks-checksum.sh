#!/usr/bin/env sh
set -u

# Fetches the published gitleaks release sha256 for a given version,
# auto-detects the caller's OS/arch, and prints the value formatted for
# direct paste into a GitHub Actions workflow or 'agent-guard setup --install'.
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
and prints the sha256 for your machine's OS/arch, formatted for direct paste
into a GitHub Actions workflow or 'agent-guard setup --install'.

Default version: $DEFAULT_VERSION (matches action.yml).
EOF
    exit 0
    ;;
esac

VERSION=${1:-$DEFAULT_VERSION}

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH=x64 ;;
  arm64|aarch64) ARCH=arm64 ;;
esac

case "$OS" in
  darwin|linux) ;;
  *)
    printf 'gitleaks-checksum: unsupported os: %s\n' "$OS" >&2
    exit 2
    ;;
esac

ARCHIVE="gitleaks_${VERSION}_${OS}_${ARCH}.tar.gz"
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

line=$(printf '%s\n' "$checksums" | awk -v archive="$ARCHIVE" '$2 == archive {print; exit}')

if [ -z "$line" ]; then
  printf 'gitleaks-checksum: no entry for %s in v%s\n' "$ARCHIVE" "$VERSION" >&2
  printf 'available archives:\n' >&2
  printf '%s\n' "$checksums" | awk 'NF==2 {print "  " $2}' >&2
  exit 1
fi

sha=$(printf '%s\n' "$line" | awk '{print $1}')

printf 'gitleaks v%s — %s/%s\n' "$VERSION" "$OS" "$ARCH"
printf '\n'
printf 'sha256: %s\n' "$sha"
printf '\n'
printf 'GitHub Actions workflow:\n'
printf '  gitleaks-checksum: "%s"\n' "$sha"
printf '\n'
printf 'agent-guard setup CLI:\n'
printf '  agent-guard setup --install --gitleaks-checksum %s --gitleaks-version %s\n' "$sha" "$VERSION"

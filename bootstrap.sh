#!/usr/bin/env sh
# Agent Guard bootstrap installer.
#
# Usage:
#   curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
#
# Environment overrides:
#   AGENT_GUARD_VERSION   pin a specific version (e.g. 1.2.0). Defaults to the
#                         latest release resolved via the GitHub redirect.
#   AGENT_GUARD_HOME      install destination (default: $HOME/.agent-guard).
#   AGENT_GUARD_BIN_DIR   directory the agent-guard symlink lives in (default:
#                         $HOME/.local/bin).
#   AGENT_GUARD_REPO      override the source repo (default: JeongJaeSoon/agent-guard).

set -eu

REPO=${AGENT_GUARD_REPO:-JeongJaeSoon/agent-guard}
HOME_DIR=${AGENT_GUARD_HOME:-$HOME/.agent-guard}
BIN_DIR=${AGENT_GUARD_BIN_DIR:-$HOME/.local/bin}
VERSION=${AGENT_GUARD_VERSION:-}

prog=agent-guard-bootstrap

info() { printf '%s\n' "$*" >&2; }
die()  { info "$prog: $*"; exit 2; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

resolve_latest_version() {
  # GitHub redirects releases/latest -> releases/tag/vX.Y.Z. We follow the
  # redirect (-L) and read the effective URL rather than parsing release
  # notes. Without -L curl stops at the 302 and url_effective stays at the
  # input URL, so the sed match fails and we die with "could not parse
  # version" -- previously broke v1.1.0 installs.
  url=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest") \
    || die "could not query latest release"
  v=$(printf '%s' "$url" | sed -n -E 's|.*/tag/v([0-9]+\.[0-9]+\.[0-9]+)$|\1|p')
  [ -n "$v" ] || die "could not parse version from $url"
  printf '%s' "$v"
}

main() {
  require curl
  require shasum
  require tar
  require ln

  if [ -z "$VERSION" ]; then
    VERSION=$(resolve_latest_version)
  fi
  info "$prog: target version v$VERSION"

  archive="agent-guard-${VERSION}.tar.gz"
  base="https://github.com/${REPO}/releases/download/v${VERSION}"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-bootstrap.XXXXXX") \
    || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT INT TERM

  info "$prog: downloading $archive"
  curl -fsSL "$base/$archive"        -o "$tmp/$archive" \
    || die "download failed: $base/$archive"
  curl -fsSL "$base/$archive.sha256" -o "$tmp/$archive.sha256" \
    || die "download failed: $base/$archive.sha256"

  info "$prog: verifying sha256"
  ( cd "$tmp" && shasum -a 256 -c "$archive.sha256" ) >&2 \
    || die "checksum verification failed for $archive"

  info "$prog: extracting to $HOME_DIR"
  mkdir -p "$HOME_DIR"
  tar -xzf "$tmp/$archive" -C "$HOME_DIR"

  bin_path="$HOME_DIR/bin/agent-guard"
  [ -x "$bin_path" ] || die "expected executable not found after extraction: $bin_path"

  mkdir -p "$BIN_DIR"
  ln -sf "$bin_path" "$BIN_DIR/agent-guard"
  info "$prog: linked $BIN_DIR/agent-guard -> $bin_path"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      info ""
      info "$prog: $BIN_DIR is not on PATH. Add this to your shell rc:"
      info "  export PATH=\"$BIN_DIR:\$PATH\""
      info ""
      ;;
  esac

  info "$prog: running 'agent-guard setup' to report dependency status"
  info ""
  # 'setup' may exit 1 if deps are missing; that's expected and not a bootstrap
  # failure -- the user just gets the install hints.
  "$bin_path" setup || true
  info ""
  info "$prog: done. v${VERSION} installed at $HOME_DIR."
}

main "$@"

#!/usr/bin/env sh
# Agent Guard bootstrap installer.
#
# Usage:
#   curl -fsSL https://github.com/JeongJaeSoon/agent-guard/releases/latest/download/bootstrap.sh | sh
#
# Environment overrides:
#   AGENT_GUARD_VERSION   pin a specific version (e.g. 2.0.0). Defaults to the
#                         latest release resolved via the GitHub redirect.
#   AGENT_GUARD_HOME      install destination (default: $HOME/.agent-guard).
#   AGENT_GUARD_BIN_DIR   directory the agent-guard symlink lives in (default:
#                         $HOME/.local/bin).
#   AGENT_GUARD_REPO      override the source repo (default: JeongJaeSoon/agent-guard).
#   AGENT_GUARD_COMMAND_WRAPPING
#                         command wrapping is installed on by default. Set to
#                         off, false, no, or 0 for a persistent opt-out.

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

# Build beside the installation so the final renames stay on one filesystem.
# On a handled interruption or commit failure, restore the previous directory.
cleanup() {
  if [ -n "${transaction:-}" ] && [ -d "$transaction/previous" ] \
      && [ "${install_committed:-0}" != 1 ]; then
    if [ -e "$HOME_DIR" ] && ! mv "$HOME_DIR" "$transaction/failed"; then
      info "$prog: rollback could not move failed install; previous install retained at $transaction/previous"
      return
    fi
    if ! mv "$transaction/previous" "$HOME_DIR"; then
      info "$prog: rollback could not restore install; previous install retained at $transaction/previous"
      return
    fi
  fi
  [ -z "${transaction:-}" ] || rm -rf "$transaction"
  [ -z "${link_stage:-}" ] || rm -rf "$link_stage"
  [ -z "${tmp:-}" ] || rm -rf "$tmp"
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

validate_payload_layout() {
  # The archive is extracted once into a private staging directory before it
  # reaches the installation. Do not allow special files or links to be carried
  # from a release asset into ~/.agent-guard: a link can turn a later update
  # into a write outside the owned payload directory.
  if find "$stage" -mindepth 1 ! -type f ! -type d -print | grep -q .; then
    die "archive contains a symlink or special file"
  fi

  # A release archive is the plugin payload plus the standalone installer and
  # deployment examples. Reject unexpected top-level entries rather than
  # extracting a checksum-valid but malformed asset into an existing install.
  for entry in "$stage"/.[!.]* "$stage"/..?* "$stage"/*; do
    [ -e "$entry" ] || continue
    case ${entry##*/} in
      .claude-plugin|.codex-plugin|CHANGELOG.md|LICENSE|PRIVACY.md|README.md|README.ko.md|README.ja.md|SECURITY.md|SUPPORT.md|THIRD_PARTY_NOTICES.md|assets|bin|codex-skills|commands|config|deployment|docs|hooks|hooks.json|install.sh|libexec|scripts|skills) ;;
      *) die "archive contains an unexpected top-level entry: ${entry##*/}" ;;
    esac
  done
  if [ -e "$stage/libexec" ]; then
    [ -d "$stage/libexec" ] || die "native payload is not a directory"
    for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl \
      x86_64-apple-darwin aarch64-apple-darwin; do
      name="agent-guard-redact-$target"
      [ -f "$stage/libexec/$name" ] && [ -x "$stage/libexec/$name" ] \
        && [ -f "$stage/libexec/$name.sha256" ] || die "incomplete native payload: $name"
      expected=$(cat "$stage/libexec/$name.sha256")
      actual=$(CDPATH= cd -- "$stage/libexec" && shasum -a 256 "$name") \
        || die "cannot verify native payload: $name"
      [ "$actual" = "$expected" ] || die "native checksum mismatch: $name"
    done
  fi
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
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  info "$prog: downloading $archive"
  curl -fsSL "$base/$archive"        -o "$tmp/$archive" \
    || die "download failed: $base/$archive"
  curl -fsSL "$base/$archive.sha256" -o "$tmp/$archive.sha256" \
    || die "download failed: $base/$archive.sha256"

  info "$prog: verifying sha256"
  ( cd "$tmp" && shasum -a 256 -c "$archive.sha256" ) >&2 \
    || die "checksum verification failed for $archive"

  # Validate the downloaded payload before touching a working installation.
  stage="$tmp/payload"
  mkdir "$stage"
  tar -xzf "$tmp/$archive" -C "$stage" || die "archive extraction failed"
  validate_payload_layout
  [ -f "$stage/bin/agent-guard" ] && [ ! -L "$stage/bin/agent-guard" ] \
    && [ -x "$stage/bin/agent-guard" ] || die "expected regular executable not found in archive"
  [ -f "$stage/install.sh" ] && [ ! -L "$stage/install.sh" ] \
    && [ -x "$stage/install.sh" ] || die "expected regular installer not found in archive"
  sh -n "$stage/bin/agent-guard" && sh -n "$stage/install.sh" \
    || die "archive contains invalid shell scripts"
  for policy in gitleaks.toml deny-read-paths.txt deny-bash-patterns.txt; do
    [ -f "$stage/config/$policy" ] && [ ! -L "$stage/config/$policy" ] \
      && [ -r "$stage/config/$policy" ] || die "archive has no regular policy file: $policy"
  done

  info "$prog: extracting to $HOME_DIR"
  mkdir -p "$HOME_DIR/bin"
  mkdir -p "$BIN_DIR"
  HOME_DIR=$(CDPATH= cd -- "$HOME_DIR" && pwd -P)
  BIN_DIR=$(CDPATH= cd -- "$BIN_DIR" && pwd -P)
  # Refuse directory targets rather than copying into them or deleting data.
  [ ! -d "$HOME_DIR/bin/agent-guard" ] || die "executable destination is a directory"
  [ ! -L "$HOME_DIR/bin/agent-guard" ] || die "executable destination must not be a symlink"
  [ ! -d "$BIN_DIR/agent-guard" ] || die "link destination is a directory"
  [ "$HOME_DIR" != / ] || die "installation destination must not be the filesystem root"
  transaction=$(mktemp -d "$(dirname "$HOME_DIR")/.agent-guard-update.XXXXXX") \
    || die "cannot create installation transaction"
  mkdir "$transaction/next"
  cp -R "$HOME_DIR/." "$transaction/next/" || die "cannot stage existing installation"
  # Retain tar's replacement semantics for old symlinks, but perform every
  # extraction write in the staged copy, never in the working installation.
  tar -xzf "$tmp/$archive" -C "$transaction/next" || die "installation extraction failed"
  "$transaction/next/bin/agent-guard" version >/dev/null \
    || die "staged executable failed validation"
  mv "$HOME_DIR" "$transaction/previous" || die "cannot preserve previous installation"
  mv "$transaction/next" "$HOME_DIR" || die "cannot commit staged installation"
  # tar may replace a pre-existing HOME_DIR/bin symlink with the archive's real
  # bin directory. Resolve it after extraction so a former alias of BIN_DIR does
  # not make us skip creation of the public executable link.
  payload_bin_dir=$(CDPATH= cd -- "$HOME_DIR/bin" && pwd -P)
  bin_path="$HOME_DIR/bin/agent-guard"
  if [ "$BIN_DIR" = "$payload_bin_dir" ]; then
    info "$prog: executable already lives in $BIN_DIR; no symlink needed"
  else
    # Prepare the symlink in the public directory's filesystem. A failed ln or
    # rename must not unlink the existing working public command.
    link_stage=$(mktemp -d "$BIN_DIR/.agent-guard-link.XXXXXX") \
      || die "cannot stage public executable link"
    ln -s "$bin_path" "$link_stage/agent-guard" || die "cannot stage public executable link"
    mv -f "$link_stage/agent-guard" "$BIN_DIR/agent-guard" || die "cannot update public executable link"
    info "$prog: linked $BIN_DIR/agent-guard -> $bin_path"
  fi
  install_committed=1

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

  case "${AGENT_GUARD_COMMAND_WRAPPING:-on}" in
    0|off|OFF|false|FALSE|no|NO)
      info "$prog: installing shell integration with command wrapping off"
      if ! "$bin_path" setup-shell --no-command-wrapping; then
        info "$prog: WARNING: shell integration was not installed; run:"
        info "  $bin_path setup-shell --no-command-wrapping"
      fi
      ;;
    *)
      info "$prog: installing shell integration with command wrapping on"
      if ! "$bin_path" setup-shell; then
        info "$prog: WARNING: shell integration was not installed; run:"
        info "  $bin_path setup-shell"
      fi
      ;;
  esac
  info ""
  info "$prog: done. v${VERSION} installed at $HOME_DIR."
}

main "$@"

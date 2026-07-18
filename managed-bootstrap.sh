#!/usr/bin/env sh
# Download and install a pinned Agent Guard release for managed endpoints.
#
# The bootstrap owns the generic runtime, dependencies, verification, and
# login-user shell phase. Product policy remains owned by the organization:
# this script does not edit Claude managed-settings.json or Codex TOML.

set -eu

PROGRAM=agent-guard-managed-bootstrap
REPO=${AGENT_GUARD_REPO:-JeongJaeSoon/agent-guard}
VERSION=${AGENT_GUARD_VERSION:-}
EXPECTED_ARCHIVE_SHA256=${AGENT_GUARD_ARCHIVE_SHA256:-}
PREFIX=${AGENT_GUARD_PREFIX:-/opt/agent-guard}
TARGET_USER=${AGENT_GUARD_TARGET_USER:-}
TARGET_HOME=${AGENT_GUARD_TARGET_HOME:-}
TARGET_SHELL=${AGENT_GUARD_TARGET_SHELL:-}
JQ_VERSION=1.8.1
GITLEAKS_VERSION=8.30.1

jq_bin=
gitleaks_bin=
skip_user=0
force=0

info() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }
die() { info "$*"; exit 2; }

usage() {
  cat >&2 <<'EOF'
Usage: managed-bootstrap.sh --version X.Y.Z [options]

Options:
  --version X.Y.Z          Reviewed Agent Guard release to install (required)
  --archive-sha256 SHA     Independently recorded release archive SHA-256
  --prefix DIR             Managed runtime prefix (default: /opt/agent-guard)
  --jq-bin FILE            Use an organization-provided jq binary
  --gitleaks-bin FILE      Use an organization-provided gitleaks binary
  --target-user USER       Login user that receives default-on shell wrapping
  --target-home DIR        Home directory for --target-user
  --target-shell bash|zsh  Shell rc to manage for --target-user
  --skip-user              Install the system phase only
  --force                  Re-download and reinstall the pinned runtime
  -h, --help               Show this help

The version must be explicit so privileged MDM jobs never follow "latest".
The release archive is verified against its published .sha256 file. Supplying
--archive-sha256 additionally requires that published value to match an
independently recorded digest.

This entrypoint installs runtime files and shell wrapping only. Distribute the
organization's Claude managed settings and composed Codex requirements through
the MDM/configuration system; they are not overwritten here.
EOF
}

# Jamf calls scripts as: script / computer-name username [parameter4...].
if [ "${1:-}" = / ]; then
  shift
  [ "$#" -eq 0 ] || shift
  [ "$#" -eq 0 ] || shift
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      shift; VERSION=${1:-}; [ -n "$VERSION" ] || die "--version requires X.Y.Z"
      ;;
    --archive-sha256)
      shift; EXPECTED_ARCHIVE_SHA256=${1:-}; [ -n "$EXPECTED_ARCHIVE_SHA256" ] || die "--archive-sha256 requires SHA"
      ;;
    --prefix)
      shift; PREFIX=${1:-}; [ -n "$PREFIX" ] || die "--prefix requires a directory"
      ;;
    --jq-bin)
      shift; jq_bin=${1:-}; [ -n "$jq_bin" ] || die "--jq-bin requires a file"
      ;;
    --gitleaks-bin)
      shift; gitleaks_bin=${1:-}; [ -n "$gitleaks_bin" ] || die "--gitleaks-bin requires a file"
      ;;
    --target-user)
      shift; TARGET_USER=${1:-}; [ -n "$TARGET_USER" ] || die "--target-user requires a user"
      ;;
    --target-home)
      shift; TARGET_HOME=${1:-}; [ -n "$TARGET_HOME" ] || die "--target-home requires a directory"
      ;;
    --target-shell)
      shift; TARGET_SHELL=${1:-}; [ -n "$TARGET_SHELL" ] || die "--target-shell requires bash or zsh"
      ;;
    --skip-user) skip_user=1 ;;
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ -n "$VERSION" ] || die "--version or AGENT_GUARD_VERSION is required for a managed install"
printf '%s\n' "$VERSION" \
  | awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { found = 1 } END { exit found ? 0 : 1 }' \
  || die "invalid version (expected X.Y.Z): $VERSION"
case "$PREFIX" in
  /|''|*[!A-Za-z0-9_./-]*) die "unsafe managed prefix: $PREFIX" ;;
  /*) ;;
  *) die "managed prefix must be absolute: $PREFIX" ;;
esac
if [ -n "$EXPECTED_ARCHIVE_SHA256" ]; then
  case "$EXPECTED_ARCHIVE_SHA256" in
    *[!0-9a-f]*|'') die "archive checksum must be lowercase hexadecimal" ;;
  esac
  [ "${#EXPECTED_ARCHIVE_SHA256}" -eq 64 ] || die "archive checksum must be a full SHA-256"
fi

require() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require curl
require tar
require awk
require mktemp
require uname

os=$(uname -s)
machine=$(uname -m)
case "$os/$machine" in
  Darwin/arm64)
    jq_asset=jq-macos-arm64
    jq_sha256=a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603
    gitleaks_asset=gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz
    gitleaks_sha256=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
    ;;
  Darwin/x86_64)
    jq_asset=jq-macos-amd64
    jq_sha256=e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f
    gitleaks_asset=gitleaks_${GITLEAKS_VERSION}_darwin_x64.tar.gz
    gitleaks_sha256=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
    ;;
  Linux/aarch64|Linux/arm64)
    jq_asset=jq-linux-arm64
    jq_sha256=6bc62f25981328edd3cfcfe6fe51b073f2d7e7710d7ef7fcdac28d4e384fc3d4
    gitleaks_asset=gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz
    gitleaks_sha256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
    ;;
  Linux/x86_64|Linux/amd64)
    jq_asset=jq-linux-amd64
    jq_sha256=020468de7539ce70ef1bceaf7cde2e8c4f2ca6c3afb84642aabc5c97d9fc2a0d
    gitleaks_asset=gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz
    gitleaks_sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  *) die "unsupported platform: $os/$machine" ;;
esac

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required"
  fi
}

verify_sha256() {
  file=$1
  expected=$2
  actual=$(sha256_file "$file")
  [ "$actual" = "$expected" ] \
    || die "checksum mismatch for $(basename "$file"): expected $expected, got $actual"
}

download() {
  url=$1
  output=$2
  info "downloading $url"
  curl --fail --location --silent --show-error \
    --connect-timeout 10 --max-time 120 \
    --retry 3 --retry-delay 2 --retry-max-time 300 --retry-connrefused \
    "$url" --output "$output" \
    || die "download failed: $url"
}

dependency_ready() {
  [ -x "$PREFIX/bin/jq" ] \
    && "$PREFIX/bin/jq" -n '.' >/dev/null 2>&1 \
    && [ -x "$PREFIX/bin/gitleaks" ] \
    && "$PREFIX/bin/gitleaks" version >/dev/null 2>&1
}

managed_system_ready() {
  [ -x "$PREFIX/bin/agent-guard" ] \
    && [ -x "$PREFIX/managed-install.sh" ] \
    && [ -x "$PREFIX/deployment/codex-hook" ] \
    && [ "$("$PREFIX/bin/agent-guard" version 2>/dev/null || true)" = "agent-guard $VERSION" ] \
    && [ -f "$PREFIX/.managed-release" ] \
    && [ "$(awk -F= '$1 == "version" {print $2; exit}' "$PREFIX/.managed-release")" = "$VERSION" ] \
    && dependency_ready \
    || return 1
  [ -z "$EXPECTED_ARCHIVE_SHA256" ] \
    || [ "$(awk -F= '$1 == "archive_sha256" {print $2; exit}' "$PREFIX/.managed-release")" = "$EXPECTED_ARCHIVE_SHA256" ]
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-managed-bootstrap.XXXXXX") \
  || die "failed to create temporary directory"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

archive=agent-guard-${VERSION}.tar.gz
release_base=${AGENT_GUARD_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download/v${VERSION}}
jq_base=${AGENT_GUARD_JQ_BASE_URL:-https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}}
gitleaks_base=${AGENT_GUARD_GITLEAKS_BASE_URL:-https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}}
metadata_archive_sha256=

if [ "$force" -eq 0 ] && managed_system_ready; then
  info "pinned managed runtime already matches; skipping downloads"
else
  download "$release_base/$archive" "$tmp/$archive"
  download "$release_base/$archive.sha256" "$tmp/$archive.sha256"

  published_sha256=$(awk -v archive="$archive" '$2 == archive || $2 == "*" archive {print $1; exit}' "$tmp/$archive.sha256")
  case "$published_sha256" in
    *[!0-9a-f]*|'') die "published checksum does not contain a valid digest for $archive" ;;
  esac
  [ "${#published_sha256}" -eq 64 ] || die "published checksum is not a full SHA-256"
  if [ -n "$EXPECTED_ARCHIVE_SHA256" ] && [ "$published_sha256" != "$EXPECTED_ARCHIVE_SHA256" ]; then
    die "published checksum for $archive does not match the independently recorded digest"
  fi
  verify_sha256 "$tmp/$archive" "$published_sha256"

  if [ -z "$jq_bin" ]; then
    download "$jq_base/$jq_asset" "$tmp/jq"
    verify_sha256 "$tmp/jq" "$jq_sha256"
    chmod 0755 "$tmp/jq"
    jq_bin=$tmp/jq
  fi
  if [ -z "$gitleaks_bin" ]; then
    download "$gitleaks_base/$gitleaks_asset" "$tmp/$gitleaks_asset"
    verify_sha256 "$tmp/$gitleaks_asset" "$gitleaks_sha256"
    mkdir -p "$tmp/gitleaks"
    tar -xzf "$tmp/$gitleaks_asset" -C "$tmp/gitleaks"
    gitleaks_bin=$tmp/gitleaks/gitleaks
  fi

  [ -x "$jq_bin" ] && "$jq_bin" -n '.' >/dev/null 2>&1 \
    || die "jq binary is missing or cannot run: $jq_bin"
  [ -x "$gitleaks_bin" ] && "$gitleaks_bin" version >/dev/null 2>&1 \
    || die "gitleaks binary is missing or cannot run: $gitleaks_bin"

  mkdir -p "$tmp/release"
  tar -xzf "$tmp/$archive" -C "$tmp/release"
  [ -x "$tmp/release/managed-install.sh" ] \
    || die "managed-install.sh is missing from Agent Guard v$VERSION"
  "$tmp/release/managed-install.sh" system \
    --prefix "$PREFIX" \
    --jq-bin "$jq_bin" \
    --gitleaks-bin "$gitleaks_bin"
  metadata_archive_sha256=$published_sha256
fi

"$PREFIX/managed-install.sh" verify --prefix "$PREFIX"

if [ -n "$metadata_archive_sha256" ]; then
  metadata_tmp=$PREFIX/.managed-release.tmp.$$
  umask 022
  {
    printf 'version=%s\n' "$VERSION"
    printf 'archive_sha256=%s\n' "$metadata_archive_sha256"
    printf 'jq_version=%s\n' "$JQ_VERSION"
    printf 'gitleaks_version=%s\n' "$GITLEAKS_VERSION"
  } >"$metadata_tmp"
  chmod 0644 "$metadata_tmp"
  mv "$metadata_tmp" "$PREFIX/.managed-release"
fi

detect_target_user() {
  [ -n "$TARGET_USER" ] && return 0
  if [ "$(id -u)" -ne 0 ]; then
    TARGET_USER=$(id -un)
    return 0
  fi
  case "$os" in
    Darwin)
      TARGET_USER=$(stat -f %Su /dev/console 2>/dev/null || true)
      case "$TARGET_USER" in
        ''|root|loginwindow|_mbsetupuser) TARGET_USER= ;;
      esac
      ;;
    Linux)
      TARGET_USER=${SUDO_USER:-}
      [ "$TARGET_USER" = root ] && TARGET_USER=
      ;;
  esac
}

resolve_target_identity() {
  [ -n "$TARGET_USER" ] || return 1
  id "$TARGET_USER" >/dev/null 2>&1 || die "target user does not exist: $TARGET_USER"
  [ "$TARGET_USER" != root ] || die "refusing to install user integration for root"

  if [ -z "$TARGET_HOME" ]; then
    case "$os" in
      Darwin)
        require dscl
        TARGET_HOME=$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        ;;
      Linux)
        require getent
        TARGET_HOME=$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')
        ;;
    esac
  fi
  case "$TARGET_HOME" in
    /*) ;;
    *) die "could not resolve an absolute home for $TARGET_USER" ;;
  esac

  if [ -z "$TARGET_SHELL" ]; then
    case "$os" in
      Darwin)
        TARGET_SHELL=$(dscl . -read "/Users/$TARGET_USER" UserShell 2>/dev/null | awk '{print $2}')
        ;;
      Linux)
        TARGET_SHELL=$(getent passwd "$TARGET_USER" | awk -F: '{print $7}')
        ;;
    esac
  fi
  TARGET_SHELL=$(basename "${TARGET_SHELL:-bash}")
  case "$TARGET_SHELL" in
    bash) shell_option=--bash; rc_file=$TARGET_HOME/.bashrc ;;
    zsh) shell_option=--zsh; rc_file=$TARGET_HOME/.zshrc ;;
    *) die "unsupported target shell for Agent Guard wrapping: $TARGET_SHELL" ;;
  esac
}

run_user_phase() {
  command=$PREFIX/managed-install.sh
  if [ "$(id -u)" -ne 0 ]; then
    HOME="$TARGET_HOME" SHELL="/bin/$TARGET_SHELL" \
      "$command" user --prefix "$PREFIX" "$shell_option" --rc "$rc_file"
    return
  fi

  case "$os" in
    Darwin)
      require launchctl
      require sudo
      target_uid=$(id -u "$TARGET_USER")
      launchctl asuser "$target_uid" \
        sudo -H -u "$TARGET_USER" env \
          HOME="$TARGET_HOME" SHELL="/bin/$TARGET_SHELL" \
          "$command" user --prefix "$PREFIX" "$shell_option" --rc "$rc_file"
      ;;
    Linux)
      require runuser
      runuser -u "$TARGET_USER" -- env \
        HOME="$TARGET_HOME" SHELL="/bin/$TARGET_SHELL" \
        "$command" user --prefix "$PREFIX" "$shell_option" --rc "$rc_file"
      ;;
  esac
}

if [ "$skip_user" -eq 0 ]; then
  detect_target_user
  if resolve_target_identity; then
    run_user_phase
    info "default-on shell wrapping installed for $TARGET_USER; it loads in the next shell/Claude session"
  else
    info "no login user is available; system phase is complete and the next MDM login run must retry the user phase"
  fi
fi

info "Agent Guard v$VERSION managed bootstrap completed"

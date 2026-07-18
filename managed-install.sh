#!/usr/bin/env sh
# Agent Guard managed deployment helper.
#
# This script deliberately separates the administrator-owned system install
# from the user-owned Claude shell-rc update. It never downloads dependencies,
# edits Codex requirements.toml, or edits Claude managed-settings.json.

set -eu

prog=agent-guard-managed-install
DEFAULT_PREFIX=/opt/agent-guard

info() { printf '%s\n' "$*" >&2; }
die() { info "$prog: $*"; exit 2; }

script_dir() {
  CDPATH= cd -- "$(dirname -- "$0")" && pwd -P
}

SELF_DIR=$(script_dir)
ASSET_DIR="$SELF_DIR/deployment"

payload_root() {
  if [ -x "$SELF_DIR/plugins/agent-guard/bin/agent-guard" ]; then
    CDPATH= cd -- "$SELF_DIR/plugins/agent-guard" && pwd -P
  elif [ -x "$SELF_DIR/bin/agent-guard" ]; then
    printf '%s\n' "$SELF_DIR"
  else
    die "cannot locate the Agent Guard payload beside $0"
  fi
}

validate_prefix() {
  case "$1" in
    /|''|*[!A-Za-z0-9_./-]*)
      die "unsafe prefix (use an absolute path containing only letters, digits, _, ., /, or -): $1"
      ;;
    /*) ;;
    *) die "prefix must be an absolute path: $1" ;;
  esac
}

copy_binary() {
  source_path=$1
  target_name=$2
  [ -f "$source_path" ] && [ -x "$source_path" ] \
    || die "$target_name binary is not executable: $source_path"
  cp "$source_path" "$prefix/bin/$target_name"
  chmod 0755 "$prefix/bin/$target_name"
  case "$target_name" in
    jq)
      "$prefix/bin/jq" -n '.' >/dev/null 2>&1 \
        || die "copied jq binary cannot run from the managed prefix: $source_path"
      ;;
    gitleaks)
      "$prefix/bin/gitleaks" version >/dev/null 2>&1 \
        || die "copied gitleaks binary cannot run from the managed prefix: $source_path"
      ;;
  esac
}

usage() {
  cat >&2 <<'EOF'
Usage:
  managed-install.sh system [--prefix DIR] [--jq-bin FILE] [--gitleaks-bin FILE]
  managed-install.sh user [--prefix DIR] [--bash|--zsh|--rc FILE]
  managed-install.sh render-codex [--prefix DIR] [--output FILE]
  managed-install.sh verify [--prefix DIR]

system        Install the versioned Agent Guard payload into a managed prefix.
              Optional approved jq/gitleaks binaries are copied into prefix/bin.
user          Install default-on Claude Code shell wrapping for the current user.
              This refuses to run as root so an MDM job cannot edit root's rc.
render-codex  Render, but never merge, the Codex requirements.toml fragment.
verify        Run dependency and smoke checks against the managed installation.
EOF
}

command_system() {
  prefix=$DEFAULT_PREFIX
  jq_bin=
  gitleaks_bin=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) shift; prefix=${1:-}; [ -n "$prefix" ] || die "--prefix requires a directory" ;;
      --jq-bin) shift; jq_bin=${1:-}; [ -n "$jq_bin" ] || die "--jq-bin requires a file" ;;
      --gitleaks-bin) shift; gitleaks_bin=${1:-}; [ -n "$gitleaks_bin" ] || die "--gitleaks-bin requires a file" ;;
      -h|--help) usage; return 0 ;;
      *) die "system: unknown option: $1" ;;
    esac
    shift
  done
  validate_prefix "$prefix"
  source_root=$(payload_root)

  mkdir -p "$prefix" "$prefix/bin" "$prefix/deployment"
  prefix_real=$(CDPATH= cd -- "$prefix" && pwd -P)
  if [ "$source_root" != "$prefix_real" ]; then
    cp -R "$source_root/." "$prefix/"
    cp "$SELF_DIR/managed-install.sh" "$prefix/managed-install.sh"
    cp "$ASSET_DIR/codex-hook" "$prefix/deployment/codex-hook"
    cp "$ASSET_DIR/codex-requirements.toml.template" \
      "$prefix/deployment/codex-requirements.toml.template"
    cp "$ASSET_DIR/claude-managed-settings.example.json" \
      "$prefix/deployment/claude-managed-settings.example.json"
  fi
  chmod 0755 "$prefix/bin/agent-guard" "$prefix/managed-install.sh" \
    "$prefix/deployment/codex-hook"

  [ -z "$jq_bin" ] || copy_binary "$jq_bin" jq
  [ -z "$gitleaks_bin" ] || copy_binary "$gitleaks_bin" gitleaks

  info "$prog: installed Agent Guard into $prefix"
  info "$prog: next: merge the output of '$prefix/managed-install.sh render-codex --prefix $prefix' into the managed Codex requirements.toml"
  info "$prog: next: run '$prefix/managed-install.sh user --prefix $prefix' as each Claude Code user"
}

command_user() {
  prefix=$DEFAULT_PREFIX
  shell_arg=
  rc_arg=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) shift; prefix=${1:-}; [ -n "$prefix" ] || die "--prefix requires a directory" ;;
      --bash|--zsh) shell_arg=$1 ;;
      --rc) shift; rc_arg=${1:-}; [ -n "$rc_arg" ] || die "--rc requires a file" ;;
      -h|--help) usage; return 0 ;;
      *) die "user: unknown option: $1" ;;
    esac
    shift
  done
  validate_prefix "$prefix"
  [ "$(id -u)" -ne 0 ] \
    || die "user setup must run as the target login user, not root"
  [ -x "$prefix/bin/agent-guard" ] \
    || die "managed Agent Guard binary not found: $prefix/bin/agent-guard"

  set -- --prepend-path "$prefix/bin"
  [ -z "$shell_arg" ] || set -- "$@" "$shell_arg"
  [ -z "$rc_arg" ] || set -- "$@" --rc "$rc_arg"
  "$prefix/bin/agent-guard" setup-shell "$@"
  info "$prog: Claude Code shell wrapping is installed for the current user"
  info "$prog: restart the shell and Claude Code to load it"
}

render_template() {
  template=$1
  awk -v prefix="$prefix" '{ gsub(/@@AGENT_GUARD_PREFIX@@/, prefix); print }' "$template"
}

command_render_codex() {
  prefix=$DEFAULT_PREFIX
  output=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) shift; prefix=${1:-}; [ -n "$prefix" ] || die "--prefix requires a directory" ;;
      --output) shift; output=${1:-}; [ -n "$output" ] || die "--output requires a file" ;;
      -h|--help) usage; return 0 ;;
      *) die "render-codex: unknown option: $1" ;;
    esac
    shift
  done
  validate_prefix "$prefix"
  template="$ASSET_DIR/codex-requirements.toml.template"
  [ -f "$template" ] || die "Codex requirements template not found: $template"
  if [ -z "$output" ]; then
    render_template "$template"
    return 0
  fi
  [ ! -e "$output" ] || die "refusing to overwrite existing file: $output"
  output_dir=$(dirname -- "$output")
  [ -d "$output_dir" ] || die "output directory does not exist: $output_dir"
  tmp=$(mktemp "$output_dir/.agent-guard-requirements.XXXXXX") \
    || die "failed to create temporary output"
  if render_template "$template" >"$tmp"; then
    chmod 0644 "$tmp"
    mv "$tmp" "$output"
  else
    rm -f "$tmp"
    die "failed to render Codex requirements"
  fi
  info "$prog: rendered Codex requirements fragment to $output"
  info "$prog: review and merge it; Codex reads one composed requirements.toml, not arbitrary fragment files"
}

command_verify() {
  prefix=$DEFAULT_PREFIX
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix) shift; prefix=${1:-}; [ -n "$prefix" ] || die "--prefix requires a directory" ;;
      -h|--help) usage; return 0 ;;
      *) die "verify: unknown option: $1" ;;
    esac
    shift
  done
  validate_prefix "$prefix"
  [ -x "$prefix/bin/agent-guard" ] \
    || die "managed Agent Guard binary not found: $prefix/bin/agent-guard"
  PATH="$prefix/bin:$PATH" \
    AGENT_GUARD_GITLEAKS_BIN_DIR="$prefix/bin" \
    "$prefix/bin/agent-guard" check
  PATH="$prefix/bin:$PATH" \
    AGENT_GUARD_GITLEAKS_BIN_DIR="$prefix/bin" \
    "$prefix/bin/agent-guard" smoke-test
  info "$prog: managed installation verification passed"
  info "$prog: restart each host and run its documented live hook probes before declaring rollout complete"
}

cmd=${1:-}
[ -n "$cmd" ] || { usage; exit 2; }
shift
case "$cmd" in
  system) command_system "$@" ;;
  user) command_user "$@" ;;
  render-codex) command_render_codex "$@" ;;
  verify) command_verify "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $cmd" ;;
esac

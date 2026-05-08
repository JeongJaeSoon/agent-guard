#!/usr/bin/env sh
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

usage() {
  cat >&2 <<'EOF'
Usage:
  ./install.sh check
  ./install.sh git-hooks
EOF
}

die() {
  printf '%s\n' "install.sh: $*" >&2
  exit 2
}

check() {
  "$SCRIPT_DIR/plugins/agent-guard/bin/agent-guard" check
}

install_git_hooks() {
  command -v git >/dev/null 2>&1 || die "git is required"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git work tree"

  existing=$(git config --get core.hooksPath || true)
  if [ -n "$existing" ] && [ "$existing" != "githooks" ]; then
    die "core.hooksPath is already set to '$existing'; refusing to overwrite"
  fi

  if [ -e ".git/hooks/pre-commit" ] && [ -z "$existing" ]; then
    die ".git/hooks/pre-commit already exists; refusing to overwrite"
  fi

  git config core.hooksPath githooks
  printf '%s\n' "install.sh: configured core.hooksPath=githooks"
}

cmd=${1:-}
case "$cmd" in
  check) check ;;
  git-hooks) install_git_hooks ;;
  ''|-h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

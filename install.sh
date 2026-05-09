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

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

check() {
  "$SCRIPT_DIR/plugins/agent-guard/bin/agent-guard" check
}

install_git_hooks() {
  command -v git >/dev/null 2>&1 || die "git is required"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git work tree"
  project_root=$(git rev-parse --show-toplevel) || die "cannot resolve git work tree root"

  existing=$(git config --get core.hooksPath || true)
  if [ -n "$existing" ] && [ "$existing" != "githooks" ]; then
    die "core.hooksPath is already set to '$existing'; refusing to overwrite"
  fi

  if [ -x "$SCRIPT_DIR/plugins/agent-guard/bin/agent-guard" ]; then
    agent_guard_bin="$SCRIPT_DIR/plugins/agent-guard/bin/agent-guard"
  elif [ -x "$SCRIPT_DIR/bin/agent-guard" ]; then
    agent_guard_bin="$SCRIPT_DIR/bin/agent-guard"
  else
    die "agent-guard binary not found under $SCRIPT_DIR"
  fi

  legacy_hook=""
  if [ -z "$existing" ]; then
    git_hook=$(git rev-parse --git-path hooks/pre-commit) || die "cannot resolve git hook path"
    case "$git_hook" in
      /*) legacy_candidate=$git_hook ;;
      *) legacy_candidate="$project_root/$git_hook" ;;
    esac
    if [ -e "$legacy_candidate" ]; then
      legacy_hook=$legacy_candidate
    fi
  fi

  mkdir -p "$project_root/githooks"
  hook_path="$project_root/githooks/pre-commit"
  if [ -e "$hook_path" ]; then
    if grep -q 'agent-guard.*scan-staged' "$hook_path"; then
      :
    else
      die "githooks/pre-commit already exists; refusing to overwrite"
    fi
  else
    {
      printf '%s\n' '#!/usr/bin/env sh'
      printf '%s\n' 'set -u'
      printf '\n'
      if [ -n "$legacy_hook" ]; then
        printf 'legacy_hook=%s\n' "$(shell_quote "$legacy_hook")"
        printf 'if [ -x "$legacy_hook" ]; then\n'
        printf '  "$legacy_hook" "$@" || exit $?\n'
        printf 'fi\n'
        printf '\n'
      fi
      printf 'exec "%s" scan-staged\n' "$agent_guard_bin"
    } >"$hook_path" || die "failed to write $hook_path"
    chmod +x "$hook_path" || die "failed to chmod $hook_path"
  fi

  git config core.hooksPath githooks
  printf '%s\n' "install.sh: configured core.hooksPath=githooks"
  printf '%s\n' "install.sh: installed githooks/pre-commit"
}

cmd=${1:-}
case "$cmd" in
  check) check ;;
  git-hooks) install_git_hooks ;;
  ''|-h|--help|help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

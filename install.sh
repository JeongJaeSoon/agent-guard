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

resolve_agent_guard_bin() {
  if [ -x "$SCRIPT_DIR/plugins/agent-guard/bin/agent-guard" ]; then
    printf '%s\n' "$SCRIPT_DIR/plugins/agent-guard/bin/agent-guard"
  elif [ -x "$SCRIPT_DIR/bin/agent-guard" ]; then
    printf '%s\n' "$SCRIPT_DIR/bin/agent-guard"
  else
    return 1
  fi
}

check() {
  agent_guard_bin=$(resolve_agent_guard_bin) \
    || die "agent-guard binary not found under $SCRIPT_DIR"
  "$agent_guard_bin" check
}

install_git_hooks() {
  command -v git >/dev/null 2>&1 || die "git is required"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git work tree"
  project_root=$(git rev-parse --show-toplevel) || die "cannot resolve git work tree root"

  existing=$(git config --get core.hooksPath || true)
  if [ -n "$existing" ] && [ "$existing" != "githooks" ]; then
    die "core.hooksPath is already set to '$existing'; refusing to overwrite"
  fi

  agent_guard_bin=$(resolve_agent_guard_bin) \
    || die "agent-guard binary not found under $SCRIPT_DIR"

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
  if [ -e "$hook_path" ] && ! grep -q 'agent-guard.*scan-staged' "$hook_path"; then
    die "githooks/pre-commit already exists; refusing to overwrite"
  fi

  if [ -e "$hook_path" ]; then
    # Refresh in place by rewriting ONLY the `exec ... scan-staged` line, so a
    # stale or broken embedded binary path is corrected while the rest of the
    # hook survives — notably the legacy-hook chain block written on the first
    # install, and any local edits made since.
    #
    # The chain block cannot simply be regenerated: `legacy_hook` is derived only
    # when core.hooksPath was unset, because `git rev-parse --git-path
    # hooks/pre-commit` HONORS core.hooksPath. Once we have pointed it at
    # githooks, re-deriving resolves to THIS hook, and chaining it would make the
    # hook exec itself. Preserving the existing block is the only safe refresh.
    # mktemp in the hook's own directory: a predictable name (…/pre-commit.tmp)
    # could be a pre-planted symlink that redirects the awk write onto an
    # attacker-chosen target. The atomic mv still lands it in place afterward.
    hook_tmp=$(mktemp "$project_root/githooks/.agent-guard-hook.XXXXXX") \
      || die "failed to create a temporary file for the hook refresh"
    # Rewrite ONLY a line that both invokes agent-guard AND runs scan-staged, and
    # require exactly one such line. The line-61 marker match accepts a mere
    # comment, so a hand-crafted hook could pair an `agent-guard` comment with an
    # unrelated `exec /other/scanner scan-staged`; matching on `agent-guard`
    # avoids silently rewriting that, and the count refuses an ambiguous hook.
    if awk -v newexec="exec $(shell_quote "$agent_guard_bin") scan-staged" '
          /^exec .*agent-guard.*scan-staged$/ { print newexec; seen++; next }
          { print }
          END { exit (seen == 1) ? 0 : 3 }
        ' "$hook_path" >"$hook_tmp"; then
      mv "$hook_tmp" "$hook_path" || die "failed to refresh $hook_path"
    else
      rm -f "$hook_tmp"
      die "githooks/pre-commit carries the agent-guard marker but has no unique 'exec … agent-guard … scan-staged' line; refusing to rewrite it"
    fi
  else
    # Fresh install: generate the whole body, chaining a pre-existing native hook
    # if one was found above.
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
      printf 'exec %s scan-staged\n' "$(shell_quote "$agent_guard_bin")"
    } >"$hook_path" || die "failed to write $hook_path"
  fi
  # Set 755 explicitly, not `chmod +x`: the refresh path creates the temp file
  # via mktemp (0600), so `+x` alone would land it at 711 and a hook needs READ
  # as well as execute to run — other users in a shared repo would get
  # "Permission denied". This also makes the fresh-install mode independent of
  # the caller's umask.
  chmod 755 "$hook_path" || die "failed to chmod $hook_path"

  git config core.hooksPath githooks || die "failed to set core.hooksPath"
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

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

HOOK_GUARD_BEGIN='# >>> agent-guard missing-executable check >>>'
HOOK_GUARD_END='# <<< agent-guard missing-executable check <<<'

# Print the block placed before the hook's exec line. When the executable is
# gone (agent-guard removed or moved) it explains why the commit failed and how
# to fix or remove the hook, then still exits 1: the staged-secret scan could
# not run, so the hook fails closed exactly as the bare exec did.
hook_missing_guard() {
  quoted_bin=$(shell_quote "$1")
  # Each message line is a fixed single-quoted word; only the path varies, and
  # shell_quote keeps it one literal word.
  printf '%s\n' \
    "$HOOK_GUARD_BEGIN" \
    "if [ ! -x $quoted_bin ]; then" \
    '  {' \
    "    printf '%s\\n' 'agent-guard pre-commit: commit blocked: the agent-guard executable is missing:'" \
    "    printf '  %s\\n' $quoted_bin" \
    "    printf '%s\\n' 'agent-guard pre-commit: the staged-secret scan cannot run, so this hook fails closed.'" \
    "    printf '%s\\n' 'agent-guard pre-commit: reinstall agent-guard and rerun its install.sh git-hooks here, or remove this hook from the repository root:'" \
    "    printf '%s\\n' '  git config --unset core.hooksPath && rm githooks/pre-commit'" \
    "    printf '%s\\n' 'agent-guard pre-commit: unsetting core.hooksPath makes git run .git/hooks again.'" \
    '  } >&2' \
    '  exit 1' \
    'fi' \
    "$HOOK_GUARD_END"
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
    # require exactly one such line. The marker grep above accepts a mere
    # comment, so a hand-crafted hook could pair an `agent-guard` comment with an
    # unrelated `exec /other/scanner scan-staged`; matching on `agent-guard`
    # avoids silently rewriting that, and the count refuses an ambiguous hook.
    # The missing-executable check names the same path, so drop any earlier
    # copy between its delimiters and write the current one just before that
    # line; a hook from before the check gains it here. Unbalanced delimiters
    # are refused rather than guessed at. The values travel through ENVIRON
    # because `awk -v` would interpret backslashes in a path.
    hook_guard=$(hook_missing_guard "$agent_guard_bin") \
      || die "failed to render the missing-executable check"
    hook_status=0
    AG_HOOK_EXEC="exec $(shell_quote "$agent_guard_bin") scan-staged" \
    AG_HOOK_GUARD=$hook_guard \
    AG_HOOK_GUARD_BEGIN=$HOOK_GUARD_BEGIN \
    AG_HOOK_GUARD_END=$HOOK_GUARD_END \
      awk '
          $0 == ENVIRON["AG_HOOK_GUARD_BEGIN"] { if (inguard) bad = 1; inguard = 1; next }
          $0 == ENVIRON["AG_HOOK_GUARD_END"] { if (!inguard) bad = 1; inguard = 0; next }
          inguard { next }
          /^exec .*agent-guard.*scan-staged$/ {
            print ENVIRON["AG_HOOK_GUARD"]; print ENVIRON["AG_HOOK_EXEC"]; seen++; next
          }
          { print }
          END { if (bad || inguard) exit 4; exit (seen == 1) ? 0 : 3 }
        ' "$hook_path" >"$hook_tmp" || hook_status=$?
    case "$hook_status" in
      0) mv "$hook_tmp" "$hook_path" || die "failed to refresh $hook_path" ;;
      4)
        rm -f "$hook_tmp"
        die "githooks/pre-commit has an unbalanced agent-guard missing-executable check; refusing to rewrite it"
        ;;
      *)
        rm -f "$hook_tmp"
        die "githooks/pre-commit carries the agent-guard marker but has no unique 'exec … agent-guard … scan-staged' line; refusing to rewrite it"
        ;;
    esac
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
      hook_missing_guard "$agent_guard_bin"
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

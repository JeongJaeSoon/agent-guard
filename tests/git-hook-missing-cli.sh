#!/usr/bin/env sh
# The native pre-commit hook written by `install.sh git-hooks` must keep
# blocking commits after the agent-guard executable it names is removed, and
# say why and how to fix or remove the hook. Every repository, installer copy
# and HOME is private to this run.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-hook-missing.XXXXXX") || exit 1
[ -n "$CASE_ROOT" ] || exit 1
CASE_ROOT=$(CDPATH= cd -- "$CASE_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail=0
ok() { printf 'ok - %s\n' "$*"; }
not_ok() { fail=1; printf 'not ok - %s\n' "$*"; }
export HOME="$CASE_ROOT/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
mkdir -p "$HOME"
BEGIN='# >>> agent-guard missing-executable check >>>'

# installer_copy DIR: a removable standalone-like payload (install.sh + bin).
installer_copy() {
  mkdir -p "$1"
  cp "$ROOT/install.sh" "$1/install.sh"
  cp -R "$ROOT/plugins/agent-guard/." "$1/"
}
new_repo() {
  rm -rf "$1"
  mkdir -p "$1"
  (cd "$1" && git init -q && git config user.email t@example.invalid && git config user.name t)
}
commit_one() {  # $1 = repo; leaves output in $CASE_ROOT/commit.err
  (cd "$1" && printf 'x\n' >>c.txt && git add c.txt && git commit -q -m x) \
    >"$CASE_ROOT/commit.out" 2>"$CASE_ROOT/commit.err"
}
guard_count() { grep -cxF "$BEGIN" "$1"; }

# 1. A quote, a backslash, a dollar sign and a space in the payload path must survive as one
# literal word in both the check and the message.
PAYLOAD="$CASE_ROOT/it's a \\dir \$x/agent-guard"
installer_copy "$PAYLOAD"
REPO="$CASE_ROOT/repo"
new_repo "$REPO"
(cd "$REPO" && sh "$PAYLOAD/install.sh" git-hooks) >"$CASE_ROOT/install.out" 2>&1
HOOK="$REPO/githooks/pre-commit"
if sh -n "$HOOK" && [ "$(guard_count "$HOOK")" = 1 ] \
   && [ "$(tail -n 1 "$HOOK")" = "exec '$CASE_ROOT/it'\\''s a \\dir \$x/agent-guard/bin/agent-guard' scan-staged" ]; then
  ok "fresh hook has one missing-executable check before its exec line"
else
  not_ok "fresh hook has one missing-executable check: $(cat "$CASE_ROOT/install.out"; cat "$HOOK")"
fi
if commit_one "$REPO"; then
  ok "hook with the executable present lets a clean commit through"
else
  not_ok "hook with the executable present lets a clean commit through: $(cat "$CASE_ROOT/commit.err")"
fi

# 2. Remove the payload, as the documented uninstall does. The commit stays
# blocked with exit 1 and the message names the cause and both remedies.
rm -rf "$CASE_ROOT/it's a \\dir \$x"
before=$(cd "$REPO" && git rev-list --count HEAD)
(cd "$REPO" && "$HOOK") >/dev/null 2>"$CASE_ROOT/hook.err"
hook_status=$?
commit_one "$REPO"
commit_status=$?
after=$(cd "$REPO" && git rev-list --count HEAD)
if [ "$hook_status" -eq 1 ] && [ "$commit_status" -ne 0 ] && [ "$before" = "$after" ]; then
  ok "missing executable still blocks the commit with exit 1"
else
  not_ok "missing executable still blocks the commit (hook $hook_status, commit $commit_status, commits $before -> $after)"
fi
if grep -Fxq "  $CASE_ROOT/it's a \\dir \$x/agent-guard/bin/agent-guard" "$CASE_ROOT/commit.err" \
   && grep -Fq 'commit blocked: the agent-guard executable is missing' "$CASE_ROOT/commit.err" \
   && grep -Fq 'fails closed' "$CASE_ROOT/commit.err" \
   && grep -Fq 'rerun its install.sh git-hooks' "$CASE_ROOT/commit.err" \
   && grep -Fxq '  git config --unset core.hooksPath && rm githooks/pre-commit' "$CASE_ROOT/commit.err" \
   && ! grep -q 'not found' "$CASE_ROOT/commit.err"; then
  ok "missing executable message names the path, the cause and the remedies"
else
  not_ok "missing executable message: $(cat "$CASE_ROOT/commit.err")"
fi
# A path that exists but cannot run is not a pass either.
mkdir -p "$CASE_ROOT/it's a \\dir \$x/agent-guard/bin"
printf '#!/bin/sh\nexit 0\n' >"$CASE_ROOT/it's a \\dir \$x/agent-guard/bin/agent-guard"
chmod 644 "$CASE_ROOT/it's a \\dir \$x/agent-guard/bin/agent-guard"
(cd "$REPO" && "$HOOK") >/dev/null 2>&1
status=$?
rm -rf "$CASE_ROOT/it's a \\dir \$x"
if [ "$status" -eq 1 ]; then
  ok "non-executable path blocks with exit 1"
else
  not_ok "non-executable path blocks with exit 1 (got $status)"
fi

# 3. The documented removal restores ordinary commits, and a legacy hook in
# .git/hooks runs again once core.hooksPath is unset.
printf '#!/bin/sh\n: >"%s/legacy-ran"\n' "$CASE_ROOT" >"$REPO/.git/hooks/pre-commit"
chmod +x "$REPO/.git/hooks/pre-commit"
(cd "$REPO" && git config --unset core.hooksPath && rm githooks/pre-commit)
if commit_one "$REPO" && [ -e "$CASE_ROOT/legacy-ran" ]; then
  ok "documented hook removal restores commits and the .git/hooks hook"
else
  not_ok "documented hook removal restores commits: $(cat "$CASE_ROOT/commit.err")"
fi

# 4. A hook written before the check gains it on reinstall, exactly once, and
# keeps its other lines (here a legacy chain and a local edit).
PAYLOAD2="$CASE_ROOT/payload two"
installer_copy "$PAYLOAD2"
REPO2="$CASE_ROOT/repo2"
new_repo "$REPO2"
mkdir -p "$REPO2/githooks"
{
  printf '%s\n' '#!/usr/bin/env sh' 'set -u' '' "legacy_hook='/nonexistent/legacy'" \
    'if [ -x "$legacy_hook" ]; then' '  "$legacy_hook" "$@" || exit $?' 'fi' '' \
    '# local edit kept' "exec '/old/place/agent-guard' scan-staged"
} >"$REPO2/githooks/pre-commit"
chmod 755 "$REPO2/githooks/pre-commit"
(cd "$REPO2" && git config core.hooksPath githooks)
(cd "$REPO2" && sh "$PAYLOAD2/install.sh" git-hooks) >"$CASE_ROOT/install.out" 2>&1
first=$(cat "$REPO2/githooks/pre-commit")
(cd "$REPO2" && sh "$PAYLOAD2/install.sh" git-hooks) >>"$CASE_ROOT/install.out" 2>&1
second=$(cat "$REPO2/githooks/pre-commit")
if [ "$(guard_count "$REPO2/githooks/pre-commit")" = 1 ] && [ "$first" = "$second" ] \
   && grep -Fq '# local edit kept' "$REPO2/githooks/pre-commit" \
   && grep -Fq "legacy_hook='/nonexistent/legacy'" "$REPO2/githooks/pre-commit" \
   && ! grep -Fq '/old/place' "$REPO2/githooks/pre-commit" \
   && [ "$(tail -n 1 "$REPO2/githooks/pre-commit")" = "exec '$PAYLOAD2/bin/agent-guard' scan-staged" ] \
   && sh -n "$REPO2/githooks/pre-commit"; then
  ok "reinstall adds the check to an older hook once and keeps its other lines"
else
  not_ok "reinstall adds the check to an older hook: $(cat "$CASE_ROOT/install.out"; cat "$REPO2/githooks/pre-commit")"
fi
rm -rf "$PAYLOAD2"
commit_one "$REPO2"
status=$?
if [ "$status" -ne 0 ] && grep -Fq "  $PAYLOAD2/bin/agent-guard" "$CASE_ROOT/commit.err"; then
  ok "refreshed hook explains a later removal"
else
  not_ok "refreshed hook explains a later removal (status $status): $(cat "$CASE_ROOT/commit.err")"
fi

# 5. An unbalanced check is refused rather than rewritten.
installer_copy "$PAYLOAD2"
printf '%s\n' '#!/usr/bin/env sh' "$BEGIN" "exec '/old/agent-guard' scan-staged" >"$REPO2/githooks/pre-commit"
cp "$REPO2/githooks/pre-commit" "$CASE_ROOT/unbalanced"
(cd "$REPO2" && sh "$PAYLOAD2/install.sh" git-hooks) >"$CASE_ROOT/install.out" 2>&1
status=$?
if [ "$status" -eq 2 ] && cmp -s "$CASE_ROOT/unbalanced" "$REPO2/githooks/pre-commit" \
   && grep -q 'unbalanced agent-guard missing-executable check' "$CASE_ROOT/install.out" \
   && [ -z "$(find "$REPO2/githooks" -name '.agent-guard-hook.*')" ]; then
  ok "an unbalanced missing-executable check is refused and left unchanged"
else
  not_ok "an unbalanced missing-executable check is refused (status $status): $(cat "$CASE_ROOT/install.out")"
fi

[ "$fail" -eq 0 ]

#!/usr/bin/env sh
# setup-shell writes a one-line rc block plus ~/.agent-guard/shell-init.sh.
# Every run uses a private HOME so the suite never rewrites the operator's
# real resolver file.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-setup-shell.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ERR="$CASE_ROOT/err"
SS_HOME="$CASE_ROOT/home"
mkdir -p "$SS_HOME"
INIT="$SS_HOME/.agent-guard/shell-init.sh"
BEGIN='# >>> agent-guard shell-init >>>'
END='# <<< agent-guard shell-init <<<'

fail=0
ok() { printf 'ok - %s\n' "$*"; }
not_ok() { fail=1; printf 'not ok - %s\n' "$*"; }
ag() { env HOME="$SS_HOME" "$PLUGIN_ROOT/bin/agent-guard" "$@"; }
# Source an rc in a clean shell and report whether agx was defined.
loads() {  # $1 = shell, $2 = PATH, $3 = rc
  env HOME="$SS_HOME" PATH="$2" AGENT_GUARD_BIN= AGENT_GUARD_SHELL_INIT_VERSION= \
    "$1" -c '. "$1"; command -v agx >/dev/null 2>&1 && echo INSTALLED || echo MISSING' \
    _ "$3" 2>/dev/null
}
block_of() {
  awk -v b="$BEGIN" -v e="$END" '$0==b{inb=1} inb{print} $0==e{inb=0}' "$1"
}

ss_rc="$CASE_ROOT/setup.rc"
ss_output=$(ag setup-shell --rc "$ss_rc" 2>&1)
if grep -q '>>> agent-guard shell-init >>>' "$ss_rc" 2>/dev/null; then
  ok "setup-shell writes a managed shell-init block into the rc"
else
  not_ok "setup-shell writes a managed shell-init block into the rc"
fi
if printf '%s' "$ss_output" | grep -Eq 'Claude Code|Codex'; then
  not_ok "setup-shell output stays host-neutral"
else
  ok "setup-shell output stays host-neutral"
fi

# The rc block is the two delimiters, the comment, and one source line.
ss_block=$(block_of "$ss_rc")
ss_block_lines=$(printf '%s\n' "$ss_block" | wc -l | tr -d ' ')
ss_source_line=$(printf '%s\n' "$ss_block" | sed -n 3p)
ss_init_word="'$INIT'"
if [ "$ss_block_lines" = 4 ] \
   && [ "$ss_source_line" = "if [ -r $ss_init_word ]; then . $ss_init_word; fi" ]; then
  ok "setup-shell rc block is one line that sources ~/.agent-guard/shell-init.sh"
else
  not_ok "setup-shell rc block is one source line (lines $ss_block_lines): $ss_block"
fi
if [ -f "$INIT" ] && [ ! -L "$INIT" ] \
   && [ "$(ls -l "$INIT" | cut -c1-10)" = '-rw-------' ]; then
  ok "setup-shell writes the resolver file as a private regular file"
else
  not_ok "setup-shell writes the resolver file as a private regular file"
fi
if grep -q '_agbin=' "$INIT" 2>/dev/null \
   && grep -Fq '_agi=$("$_agresolved" shell-init' "$INIT" 2>/dev/null \
   && grep -q 'command -v agent-guard' "$INIT" 2>/dev/null; then
  ok "setup-shell bakes the stable invocation with resolver fallbacks"
else
  not_ok "setup-shell bakes the stable invocation with resolver fallbacks"
fi
# The resolver file names the stable path, never a version directory.
case "$(cat "$INIT")" in
  */[0-9]*.[0-9]*.[0-9]*/bin/agent-guard*) not_ok "resolver file avoids version directories" ;;
  *) ok "resolver file avoids version directories" ;;
esac

ag setup-shell --rc "$ss_rc" >/dev/null 2>&1
ss_markers=$(grep -c '>>> agent-guard shell-init >>>' "$ss_rc" 2>/dev/null)
if [ "$ss_markers" = 1 ]; then
  ok "setup-shell is idempotent (one managed block after two runs)"
else
  not_ok "setup-shell idempotent (begin-marker count: $ss_markers)"
fi
printf 'export AG_TEST_KEEP=1\n' >>"$ss_rc"
ag setup-shell --rc "$ss_rc" >/dev/null 2>&1
if grep -q 'export AG_TEST_KEEP=1' "$ss_rc" 2>/dev/null; then
  ok "setup-shell preserves unrelated rc lines"
else
  not_ok "setup-shell preserves unrelated rc lines"
fi
if grep -q 'agent-guard shell-init' "$ss_rc" 2>/dev/null \
   && ! grep -q -- '--no-command-wrapping' "$ss_rc" "$INIT" 2>/dev/null; then
  ok "setup-shell enables command wrapping by default"
else
  not_ok "setup-shell enables command wrapping by default"
fi
ss_off="$CASE_ROOT/setup-off.rc"
ag setup-shell --rc "$ss_off" --no-command-wrapping >/dev/null 2>&1
ss_off_init="$SS_HOME/.agent-guard/shell-init-no-wrapping.sh"
if grep -Fq "$ss_off_init" "$ss_off" 2>/dev/null \
   && grep -q 'shell-init --no-command-wrapping' "$ss_off_init" 2>/dev/null \
   && ! grep -q -- '--no-command-wrapping' "$INIT" 2>/dev/null; then
  ok "setup-shell persists the command-wrapping opt-out in its own resolver file"
else
  not_ok "setup-shell persists the command-wrapping opt-out in its own resolver file"
fi

# An older inline block is replaced where it stands, so rc lines after it keep
# their order; a second run is byte-identical.
ss_old="$CASE_ROOT/old.rc"
{
  printf '%s\n' 'export AG_OLD_BEFORE=1' "$BEGIN"
  printf '%s\n' "# Managed by 'agent-guard setup-shell' — remove this block to disable."
  printf '%s\n' "case :\$PATH: in *:'/x/current/bin':*) ;; *) PATH='/x/current/bin'\${PATH:+:\$PATH} ;; esac; export PATH"
  printf '%s\n' 'eval "$(' "_agbin='/x/current/bin/agent-guard'" "_agbase='/x'" \
    '_agi=$("$_agbin" shell-init 2>/dev/null) || _agi=' \
    "[ -n \"\$_agi\" ] && printf '%s\\n' \"\$_agi\"" ')"' "$END"
  printf '%s\n' '# gitleaks PATH line that must stay after the block' 'export AG_OLD_AFTER=1'
} >"$ss_old"
ag setup-shell --rc "$ss_old" >/dev/null 2>&1
ss_old_shape=$(awk -v b="$BEGIN" '$0==b{print "BLOCK"; next} /^export AG_OLD_/{print}' "$ss_old" | tr '\n' ' ')
if [ "$ss_old_shape" = 'export AG_OLD_BEFORE=1 BLOCK export AG_OLD_AFTER=1 ' ] \
   && [ "$(block_of "$ss_old")" = "$ss_block" ] \
   && ! grep -q '_agbin=' "$ss_old"; then
  ok "setup-shell replaces an older inline block in place with the one-line block"
else
  not_ok "setup-shell replaces an older inline block in place (shape: $ss_old_shape)"
  sed 's/^/  rc: /' "$ss_old"
fi
cp "$ss_old" "$CASE_ROOT/old.first"
ag setup-shell --rc "$ss_old" >/dev/null 2>&1
if cmp -s "$CASE_ROOT/old.first" "$ss_old"; then
  ok "setup-shell rerun after migration is byte-identical"
else
  not_ok "setup-shell rerun after migration is byte-identical"
fi

# Regression for the exact leak found in live testing: with agent-guard NOT on
# $PATH, a bare-name invocation would fail command-not-found and install NOTHING.
for ss_shell in /bin/sh /bin/bash /bin/zsh; do
  [ -x "$ss_shell" ] || continue
  heal=$(loads "$ss_shell" /usr/bin:/bin "$ss_rc")
  if [ "$heal" = INSTALLED ]; then
    ok "${ss_shell##*/} setup-shell rc line installs the guard even with agent-guard off \$PATH"
  else
    not_ok "${ss_shell##*/} setup-shell rc line installs the guard off \$PATH (got: $heal)"
  fi
done
# Regression for CodeRabbit's P2: a STALE/STUB `agent-guard` earlier on $PATH whose
# `shell-init` emits nothing (or errors) must NOT shadow the baked fallback.
heal_stub_dir="$CASE_ROOT/heal-stub-bin"
mkdir -p "$heal_stub_dir"
printf '#!/bin/sh\nexit 3\n' >"$heal_stub_dir/agent-guard"
chmod +x "$heal_stub_dir/agent-guard"
heal_stub=$(loads /bin/sh "$heal_stub_dir:/usr/bin:/bin" "$ss_rc")
if [ "$heal_stub" = INSTALLED ]; then
  ok "setup-shell rc line falls back to the baked path when a stub agent-guard shadows \$PATH"
else
  not_ok "setup-shell rc line falls back past a stub agent-guard (got: $heal_stub)"
fi

# Without the resolver file the rc line loads nothing, prints nothing, and
# does not fail a `set -e` shell. Must-pass control: the same rc loads above.
mv "$INIT" "$CASE_ROOT/shell-init.moved"
for ss_shell in /bin/sh /bin/bash /bin/zsh; do
  [ -x "$ss_shell" ] || continue
  ss_missing=$(env HOME="$SS_HOME" PATH=/usr/bin:/bin AGENT_GUARD_BIN= \
    AGENT_GUARD_SHELL_INIT_VERSION= "$ss_shell" -ec \
    '. "$1"; command -v agx >/dev/null 2>&1 && echo INSTALLED || echo MISSING' \
    _ "$ss_rc" 2>"$ERR")
  ss_missing_status=$?
  if [ "$ss_missing_status" -eq 0 ] && [ "$ss_missing" = MISSING ] && [ ! -s "$ERR" ]; then
    ok "${ss_shell##*/} rc line is a silent no-op when the resolver file is missing"
  else
    not_ok "${ss_shell##*/} rc line with a missing resolver file (status $ss_missing_status, got: $ss_missing)"
    sed 's/^/  stderr: /' "$ERR"
  fi
done
mv "$CASE_ROOT/shell-init.moved" "$INIT"

# SessionStart follows the rc line into the resolver file: present and
# resolvable stays quiet, missing reports that the block can no longer load.
ss_start_home="$CASE_ROOT/sstart-home"
mkdir -p "$ss_start_home"
ss_start_path="$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
session_start_message() {
  env -u AGENT_GUARD_SHELL_INIT_VERSION HOME="$ss_start_home" SHELL=/bin/zsh \
    AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" \
    PATH="$ss_start_path" "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>/dev/null
}
if PATH="$ss_start_path" command -v agent-guard >/dev/null 2>&1; then
  printf 'skip - agent-guard is on the minimal PATH; skipped SessionStart resolver-file checks\n'
else
  env HOME="$ss_start_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell >/dev/null 2>&1
  case "$(session_start_message)" in
    *'can no longer load'*|*'is not loaded'*)
      not_ok "SessionStart stays quiet about wrapping when the resolver file loads" ;;
    *) ok "SessionStart stays quiet about wrapping when the resolver file loads" ;;
  esac
  mv "$ss_start_home/.agent-guard/shell-init.sh" "$CASE_ROOT/sstart-init.moved"
  case "$(session_start_message)" in
    *'can no longer load'*) ok "SessionStart reports a one-line block whose resolver file is missing" ;;
    *) not_ok "SessionStart reports a one-line block whose resolver file is missing" ;;
  esac
fi

# The 1.x flags were removed in v3.1.0 (#167): setup-shell must REJECT them and must not
# write an rc. must-fail control below: the supported opt-out flag still works.
for ss_v1_flag in --claude-bang-guard --experimental-bang-guard; do
  ss_v1="$CASE_ROOT/setup-v1-${ss_v1_flag#--}.rc"
  ag setup-shell --rc "$ss_v1" "$ss_v1_flag" >/dev/null 2>"$ERR"
  ss_v1_status=$?
  if [ "$ss_v1_status" -eq 2 ] && [ ! -e "$ss_v1" ] \
     && grep -q 'unknown option' "$ERR"; then
    ok "setup-shell rejects the removed 1.x flag $ss_v1_flag"
  else
    not_ok "setup-shell rejects the removed 1.x flag $ss_v1_flag (status $ss_v1_status)"
  fi
done
# --help must not short-circuit rejection: help is deferred until every
# argument has parsed, so a removed flag after --help still fails. must-pass
# control: --help alone stays exit 0.
ag setup-shell --help --claude-bang-guard >/dev/null 2>"$ERR"
ss_help_reject_status=$?
if [ "$ss_help_reject_status" -eq 2 ] && grep -q 'unknown option' "$ERR"; then
  ok "setup-shell rejects a removed flag even after --help"
else
  not_ok "setup-shell rejects a removed flag even after --help (status $ss_help_reject_status)"
fi
ag setup-shell --help >/dev/null 2>"$ERR"
if [ $? -eq 0 ] && grep -q 'Usage:' "$ERR"; then
  ok "setup-shell --help alone still prints usage with exit 0"
else
  not_ok "setup-shell --help alone still prints usage with exit 0"
fi
setup_shell_help=$(ag setup-shell --help 2>&1)
if printf '%s' "$setup_shell_help" | grep -q -- '--no-command-wrapping' \
   && ! printf '%s' "$setup_shell_help" | grep -q -- '--claude-bang-guard' \
   && ! printf '%s' "$setup_shell_help" | grep -q -- '--experimental-bang-guard' \
   && ! printf '%s' "$setup_shell_help" | grep -Eq 'Claude Code|Codex'; then
  ok "setup-shell help exposes only the 2.x command-wrapping option"
else
  not_ok "setup-shell help exposes only the 2.x command-wrapping option"
fi
if ag setup-shell --bogus >/dev/null 2>&1; then
  not_ok "setup-shell rejects an unknown option"
else
  ok "setup-shell rejects an unknown option"
fi
# An unbalanced managed block (begin marker, no matching end) must make
# setup-shell REFUSE and leave the rc untouched — never silently drop the
# user content that follows the orphaned marker.
ss_bad="$CASE_ROOT/setup-bad.rc"
printf '%s\n' 'export AG_BEFORE=1' "$BEGIN" 'export AG_ORPHAN_KEEP=1' >"$ss_bad"
ss_bad_before=$(cat "$ss_bad")
if ag setup-shell --rc "$ss_bad" >/dev/null 2>&1; then
  not_ok "setup-shell refuses an rc with an unbalanced managed-block marker"
else
  ok "setup-shell refuses an rc with an unbalanced managed-block marker"
fi
if [ "$(cat "$ss_bad")" = "$ss_bad_before" ]; then
  ok "setup-shell leaves the rc untouched when it refuses"
else
  not_ok "setup-shell leaves the rc untouched when it refuses"
fi
# A symlinked rc is written THROUGH to its target (dotfiles workflow): the link
# stays a link and the real file gets the managed block + keeps its content.
if ln -s "$CASE_ROOT/real-rc" "$CASE_ROOT/link-rc" 2>/dev/null; then
  printf 'export AG_DOTFILES=1\n' >"$CASE_ROOT/real-rc"
  ag setup-shell --rc "$CASE_ROOT/link-rc" >/dev/null 2>&1
  if [ -L "$CASE_ROOT/link-rc" ] && grep -q '>>> agent-guard shell-init >>>' "$CASE_ROOT/real-rc" 2>/dev/null; then
    ok "setup-shell writes through a symlinked rc (link preserved, target updated)"
  else
    not_ok "setup-shell writes through a symlinked rc (link preserved, target updated)"
  fi
  if grep -q 'export AG_DOTFILES=1' "$CASE_ROOT/real-rc" 2>/dev/null; then
    ok "setup-shell preserves target content when writing through a symlink"
  else
    not_ok "setup-shell preserves target content when writing through a symlink"
  fi
else
  printf 'skip - symlinks not supported here; skipped setup-shell symlink test\n'
fi

exit "$fail"

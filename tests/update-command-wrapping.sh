#!/usr/bin/env sh
# A persistent command-wrapping opt-out must survive `agent-guard update` and a
# bootstrap reinstall. Only curl downloads are substituted; bootstrap, payload
# validation, setup-shell and the rc write all run for real in a private HOME.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PLUGIN_ROOT="$ROOT/plugins/agent-guard"
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-update-wrapping.XXXXXX") || exit 1
[ -n "$CASE_ROOT" ] || exit 1
CASE_ROOT=$(CDPATH= cd -- "$CASE_ROOT" && pwd -P) || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail=0
ok() { printf 'ok - %s\n' "$*"; }
not_ok() { fail=1; printf 'not ok - %s\n' "$*"; }

DL="$CASE_ROOT/download"
mkdir -p "$DL/bin"
"$ROOT/scripts/build-release-tarball.sh" 2.0.0 "$DL/current.tar.gz" >/dev/null 2>&1 \
  || { echo 'cannot build the release tarball' >&2; exit 1; }
# A payload whose setup-shell predates --print-command-wrapping, as when the
# new bootstrap installs a pinned older release.
mkdir "$CASE_ROOT/older"
tar -xzf "$DL/current.tar.gz" -C "$CASE_ROOT/older"
sed '/--print-command-wrapping) print_wrapping=1 ;;/d' "$CASE_ROOT/older/bin/agent-guard" \
  >"$CASE_ROOT/older-cli" && cat "$CASE_ROOT/older-cli" >"$CASE_ROOT/older/bin/agent-guard"
tar -C "$CASE_ROOT/older" -czf "$DL/older.tar.gz" .
cat >"$DL/bin/curl" <<'STUB'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift; out=${1:-} ;; esac
  shift
done
case "$out" in
  */bootstrap.sh) cp "$QA_SOURCE/bootstrap.sh" "$out" ;;
  *.tar.gz) cp "$QA_DOWNLOAD/${QA_PAYLOAD:-current}.tar.gz" "$out" ;;
  *.tar.gz.sha256)
    cp "$QA_DOWNLOAD/${QA_PAYLOAD:-current}.tar.gz" "$QA_DOWNLOAD/agent-guard-2.0.0.tar.gz"
    (cd "$QA_DOWNLOAD" && shasum -a 256 agent-guard-2.0.0.tar.gz) >"$out" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$DL/bin/curl"
export QA_SOURCE="$ROOT" QA_DOWNLOAD="$DL" AGENT_GUARD_VERSION=2.0.0
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_LOG_MODE=off
unset AGENT_GUARD_COMMAND_WRAPPING QA_PAYLOAD

# fresh_home NAME SHELL [WRAPPING]: bootstrap a new HOME; leaves $H and $AGB.
fresh_home() {
  H="$CASE_ROOT/$1"
  mkdir -p "$H"
  AGB="$H/.local/bin/agent-guard"
  if [ -n "${3:-}" ]; then
    in_home "$2" env AGENT_GUARD_COMMAND_WRAPPING="$3" sh "$ROOT/bootstrap.sh" >"$H/install.log" 2>&1
  else
    in_home "$2" sh "$ROOT/bootstrap.sh" >"$H/install.log" 2>&1
  fi
}
in_home() {  # $1 = login shell for setup-shell's rc choice; rest = command
  ih_shell=$1
  shift
  env HOME="$H" SHELL="$ih_shell" PATH="$H/.local/bin:$DL/bin:/usr/bin:/bin" "$@"
}
block_line() { sed -n '/^# >>> agent-guard shell-init >>>$/{n;p;}' "$1" 2>/dev/null; }
OFF_LINE='[ ! -r ~/.agent-guard/shell-init-no-wrapping.sh ] || . ~/.agent-guard/shell-init-no-wrapping.sh'
ON_LINE='[ ! -r ~/.agent-guard/shell-init.sh ] || . ~/.agent-guard/shell-init.sh'

# 1. The reported case: bash, opt-out at install, then update.
fresh_home optout /bin/bash off
in_home /bin/bash "$AGB" update >"$H/update.log" 2>&1
status=$?
if [ "$status" -eq 0 ] && [ "$(block_line "$H/.bashrc")" = "$OFF_LINE" ] \
   && grep -q 'shell-init --no-command-wrapping' "$H/.agent-guard/shell-init-no-wrapping.sh" \
   && grep -q 'keeping command wrapping off, as recorded by setup-shell' "$H/update.log" \
   && grep -q 'installing shell integration with command wrapping off' "$H/update.log"; then
  ok "update keeps a recorded command-wrapping opt-out (bash)"
else
  not_ok "update keeps a recorded command-wrapping opt-out (status $status): $(block_line "$H/.bashrc")"
fi

# 2. Wrapping on stays on, with no new notice.
fresh_home default /bin/zsh
in_home /bin/zsh "$AGB" update >"$H/update.log" 2>&1
status=$?
if [ "$status" -eq 0 ] && [ "$(block_line "$H/.zshrc")" = "$ON_LINE" ] \
   && grep -q 'installing shell integration with command wrapping on' "$H/update.log" \
   && ! grep -q 'keeping command wrapping' "$H/update.log"; then
  ok "update leaves default command wrapping on and says nothing new"
else
  not_ok "update leaves default command wrapping on (status $status): $(block_line "$H/.zshrc")"
fi

# 3. An explicit environment value wins over the record.
fresh_home explicit /bin/zsh off
in_home /bin/zsh env AGENT_GUARD_COMMAND_WRAPPING=on "$AGB" update >"$H/update.log" 2>&1
if [ "$(block_line "$H/.zshrc")" = "$ON_LINE" ] && ! grep -q 'keeping command wrapping' "$H/update.log"; then
  ok "explicit AGENT_GUARD_COMMAND_WRAPPING=on re-enables wrapping on update"
else
  not_ok "explicit AGENT_GUARD_COMMAND_WRAPPING=on re-enables wrapping on update: $(block_line "$H/.zshrc")"
fi

# 4. A released CLI that passes no choice still keeps the opt-out, because the
# new bootstrap asks the newly installed CLI. This is the first update onto a
# fixed release.
fresh_home old-cli /bin/bash off
sed '/AGENT_GUARD_COMMAND_WRAPPING="\$update_wrapping" \\$/d; s/update_wrapping=\${AGENT_GUARD_COMMAND_WRAPPING:-}/update_wrapping=unused/' \
  "$H/.agent-guard/bin/agent-guard" >"$H/old-cli" && cat "$H/old-cli" >"$H/.agent-guard/bin/agent-guard"
if grep -q 'AGENT_GUARD_COMMAND_WRAPPING="$update_wrapping"' "$H/.agent-guard/bin/agent-guard"; then
  not_ok "old-CLI fixture still passes the wrapping choice"
else
  in_home /bin/bash "$AGB" update >"$H/update.log" 2>&1
  if [ "$(block_line "$H/.bashrc")" = "$OFF_LINE" ] \
     && grep -q 'agent-guard-bootstrap: keeping command wrapping off' "$H/update.log"; then
    ok "new bootstrap keeps the opt-out for an older CLI's update"
  else
    not_ok "new bootstrap keeps the opt-out for an older CLI's update: $(block_line "$H/.bashrc")"
  fi
fi

# 5. A payload without the query (pinned older release) keeps the old default.
fresh_home older-payload /bin/bash off
in_home /bin/bash env QA_PAYLOAD=older sh "$ROOT/bootstrap.sh" >"$H/reinstall.log" 2>&1
status=$?
if [ "$status" -eq 0 ] && [ "$(block_line "$H/.bashrc")" = "$ON_LINE" ] \
   && ! grep -q 'WARNING' "$H/reinstall.log"; then
  ok "a payload without the query installs with the previous default on"
else
  not_ok "a payload without the query installs with the previous default on (status $status): $(cat "$H/reinstall.log")"
fi

# The query reads the rc files a bare setup-shell would write.
SS_HOME="$CASE_ROOT/query"
mkdir -p "$SS_HOME"
q() { env HOME="$SS_HOME" "$@" "$PLUGIN_ROOT/bin/agent-guard" setup-shell --print-command-wrapping 2>"$CASE_ROOT/q.err"; }
reset_query_home() { rm -rf "$SS_HOME" && mkdir -p "$SS_HOME"; }
if [ "$(q SHELL=/bin/zsh)" = on ] && [ ! -e "$SS_HOME/.zshrc" ] && [ ! -e "$SS_HOME/.agent-guard" ]; then
  ok "query prints on without shell integration and writes nothing"
else
  not_ok "query prints on without shell integration and writes nothing"
fi
env HOME="$SS_HOME" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$SS_HOME/custom.rc" --no-command-wrapping >/dev/null 2>&1
if [ "$(q SHELL=/bin/zsh)" = off ] \
   && [ "$(env HOME="$SS_HOME" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$SS_HOME/custom.rc" --print-command-wrapping)" = off ]; then
  ok "an opt-out installed with --rc reads as off from the default rc and from --rc"
else
  not_ok "an opt-out installed with --rc reads as off"
fi
env HOME="$SS_HOME" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --zsh >/dev/null 2>&1
if [ "$(q SHELL=/bin/zsh)" = on ] && [ "$(q SHELL=/bin/bash)" = on ]; then
  ok "a managed block decides; without one, both resolver files read as default on"
else
  not_ok "a managed block decides (zsh $(q SHELL=/bin/zsh), bash $(q SHELL=/bin/bash))"
fi
env HOME="$SS_HOME" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --bash --no-command-wrapping >/dev/null 2>&1
if [ "$(q SHELL=/bin/bash)" = off ] && [ "$(q SHELL=/usr/bin/fish)" = on ]; then
  ok "fish reads both rc files: one opt-out and one default read as on"
else
  not_ok "fish reads both rc files (bash $(q SHELL=/bin/bash), fish $(q SHELL=/usr/bin/fish))"
fi
env HOME="$SS_HOME" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --zsh --no-command-wrapping >/dev/null 2>&1
if [ "$(q SHELL=/usr/bin/fish)" = off ]; then
  ok "fish with an opt-out in both rc files reads as off"
else
  not_ok "fish with an opt-out in both rc files reads as off"
fi
reset_query_home
{
  printf '%s\n' '# >>> agent-guard shell-init >>>' "_agbin='/x/agent-guard'" \
    '_agi=$("$_agresolved" shell-init --no-command-wrapping 2>/dev/null) || _agi=' \
    '# <<< agent-guard shell-init <<<'
} >"$SS_HOME/.zshrc"
if [ "$(q SHELL=/bin/zsh)" = off ]; then
  ok "a pre-v3.9 inline opt-out block reads as off"
else
  not_ok "a pre-v3.9 inline opt-out block reads as off"
fi
printf '%s\n' '# >>> agent-guard shell-init >>>' '. ~/.agent-guard/shell-init-no-wrapping.sh' >"$SS_HOME/.zshrc"
if [ "$(q SHELL=/bin/zsh)" = on ]; then
  ok "an unbalanced block is not a record"
else
  not_ok "an unbalanced block is not a record"
fi
env HOME="$SS_HOME" "$PLUGIN_ROOT/bin/agent-guard" setup-shell --print-command-wrapping --no-command-wrapping >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  ok "query refuses --no-command-wrapping"
else
  not_ok "query refuses --no-command-wrapping (status $status)"
fi

[ "$fail" -eq 0 ]

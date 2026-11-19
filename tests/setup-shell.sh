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
loads() {  # $1 = shell, $2 = PATH, $3 = rc, $4 = HOME (default: $SS_HOME)
  env HOME="${4:-$SS_HOME}" PATH="$2" AGENT_GUARD_BIN= AGENT_GUARD_SHELL_INIT_VERSION= \
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

# The rc block is the two delimiters around one source line.
ss_block=$(block_of "$ss_rc")
ss_block_lines=$(printf '%s\n' "$ss_block" | wc -l | tr -d ' ')
ss_source_line=$(printf '%s\n' "$ss_block" | sed -n 2p)
if [ "$ss_block_lines" = 3 ] \
   && [ "$ss_source_line" = '[ ! -r ~/.agent-guard/shell-init.sh ] || . ~/.agent-guard/shell-init.sh' ]; then
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
if [ "$(sed -n 2p "$INIT" 2>/dev/null)" = 'unset AGENT_GUARD_SHELL_INIT_VERSION' ]; then
  ok "resolver file clears an inherited marker before resolving"
else
  not_ok "resolver file clears an inherited marker before resolving"
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
if grep -Fq '~/.agent-guard/shell-init-no-wrapping.sh' "$ss_off" 2>/dev/null \
   && grep -q 'shell-init --no-command-wrapping' "$ss_off_init" 2>/dev/null \
   && ! grep -q -- '--no-command-wrapping' "$INIT" 2>/dev/null; then
  ok "setup-shell persists the command-wrapping opt-out in its own resolver file"
else
  not_ok "setup-shell persists the command-wrapping opt-out in its own resolver file"
fi
# The opt-out drops the command wrappers only: agx and the marker must still
# load. shell-init once ended on a false test for this target, and the
# bootstrap took that status as "nothing to load".
ss_off_status=0
ag shell-init --no-command-wrapping >"$CASE_ROOT/off-snippet" 2>"$ERR" || ss_off_status=$?
if [ "$ss_off_status" -eq 0 ] && grep -q '^agx() {' "$CASE_ROOT/off-snippet" \
   && ! grep -q '^__agentguard_wrap_command() {' "$CASE_ROOT/off-snippet"; then
  ok "shell-init --no-command-wrapping exits 0 with agx and without the wrappers"
else
  not_ok "shell-init --no-command-wrapping exits 0 with agx and without the wrappers (status $ss_off_status)"
fi
for ss_off_shell in sh bash; do
  command -v "$ss_off_shell" >/dev/null 2>&1 || continue
  ss_off_loaded=$(loads "$ss_off_shell" "$PLUGIN_ROOT/bin:$PATH" "$ss_off")
  if [ "$ss_off_loaded" = INSTALLED ]; then
    ok "the opt-out rc still defines agx in $ss_off_shell"
  else
    not_ok "the opt-out rc still defines agx in $ss_off_shell (got ${ss_off_loaded:-nothing})"
  fi
done

# The resolver file is a frozen copy, so its first line is a format stamp that
# doctor compares with the CLI. The pinned body checksums belong to
# SS_BOOTSTRAP_FORMAT: a change to the body (or to shell_init_resolver, which
# it embeds) without a bump of SHELL_INIT_BOOTSTRAP_FORMAT fails here, because
# doctor could not tell such a copy from a current one. Bump both together.
SS_BOOTSTRAP_FORMAT=1
SS_BOOTSTRAP_BODY_CKSUM='463095475 5953'
SS_BOOTSTRAP_OFF_BODY_CKSUM='3404244926 5997'
ss_stamp="# agent-guard shell-init bootstrap v$SS_BOOTSTRAP_FORMAT (managed by agent-guard setup-shell; rerun it to regenerate)"
bootstrap_body_cksum() {  # the body without its stamp and install-specific paths
  sed -e 1d -e "s/^_agbin=.*/_agbin=X/" -e "s/^_agbase=.*/_agbase=X/" \
    -e '/^case :\$PATH: in /d' "$1" | cksum
}
if [ "$(sed -n 1p "$INIT")" = "$ss_stamp" ] && [ "$(sed -n 1p "$ss_off_init")" = "$ss_stamp" ]; then
  ok "setup-shell stamps both resolver files with the bootstrap format"
else
  not_ok "setup-shell stamps both resolver files (got: $(sed -n 1p "$INIT"))"
fi
if [ "$(grep -c '^SHELL_INIT_BOOTSTRAP_FORMAT=' "$PLUGIN_ROOT/bin/agent-guard")" = 1 ] \
   && grep -q "^SHELL_INIT_BOOTSTRAP_FORMAT=$SS_BOOTSTRAP_FORMAT\$" "$PLUGIN_ROOT/bin/agent-guard" \
   && grep -Fq 'setup_shell_write_bootstrap "$bootstrap" "$SHELL_INIT_BOOTSTRAP_STAMP' "$PLUGIN_ROOT/bin/agent-guard" \
   && grep -Fq '"$SHELL_INIT_BOOTSTRAP_STAMP") return 0' "$PLUGIN_ROOT/bin/agent-guard"; then
  ok "the resolver-file writer and the doctor check share one format constant"
else
  not_ok "the resolver-file writer and the doctor check share one format constant"
fi
ss_body_cksum=$(bootstrap_body_cksum "$INIT")
ss_off_body_cksum=$(bootstrap_body_cksum "$ss_off_init")
if [ "$ss_body_cksum" = "$SS_BOOTSTRAP_BODY_CKSUM" ] \
   && [ "$ss_off_body_cksum" = "$SS_BOOTSTRAP_OFF_BODY_CKSUM" ]; then
  ok "resolver-file body matches the checksum pinned for format v$SS_BOOTSTRAP_FORMAT"
else
  not_ok "resolver-file body changed without a SHELL_INIT_BOOTSTRAP_FORMAT bump (got: $ss_body_cksum / $ss_off_body_cksum)"
fi

# doctor reports a pre-v3.9 inline rc block and a resolver file without the
# current stamp, prints nothing for current ones, never rewrites either file,
# and keeps its exit status.
ss_doc_home="$CASE_ROOT/doctor-home"
ss_doc_init="$ss_doc_home/.agent-guard/shell-init.sh"
ss_doc_off_init="$ss_doc_home/.agent-guard/shell-init-no-wrapping.sh"
mkdir -p "$ss_doc_home"
# The CLI is on PATH here, as for a standalone install, so the advice keeps the
# short name; tests/cli-guidance.sh covers the plugin-only path form.
mkdir -p "$CASE_ROOT/doctor-bin"
ln -s "$PLUGIN_ROOT/bin/agent-guard" "$CASE_ROOT/doctor-bin/agent-guard"
doctor_run() {  # leaves the shell-integration lines in $ss_doc_notes
  env HOME="$ss_doc_home" SHELL=/bin/zsh AGENT_GUARD_RELEASE_CHECK=off PATH="$CASE_ROOT/doctor-bin:$PATH" \
    "$PLUGIN_ROOT/bin/agent-guard" doctor >"$CASE_ROOT/doctor.out" 2>&1
  ss_doc_status=$?
  ss_doc_notes=$(grep 'shell integration:' "$CASE_ROOT/doctor.out")
}
restamp() {  # $1 = file, $2 = new first line
  { printf '%s\n' "$2"; sed 1d "$1"; } >"$1.new" && mv "$1.new" "$1"
}
doctor_run
ss_doc_base=$ss_doc_status
if [ -z "$ss_doc_notes" ]; then
  ok "doctor prints no shell-integration notice without shell integration"
else
  not_ok "doctor without shell integration: $ss_doc_notes"
fi
env HOME="$ss_doc_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --zsh >/dev/null 2>&1
env HOME="$ss_doc_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --bash --no-command-wrapping >/dev/null 2>&1
doctor_run
if [ -z "$ss_doc_notes" ] && [ "$ss_doc_status" -eq "$ss_doc_base" ]; then
  ok "doctor stays quiet for current rc blocks and resolver files"
else
  not_ok "doctor with current shell integration (status $ss_doc_status, base $ss_doc_base): $ss_doc_notes"
fi
# The pre-v3.9 rc block carried the resolver inline: the eval body that now
# lives in the resolver file, between the same markers. Must-pass control:
# the fixture still loads, so the notice is about size, not protection.
for ss_legacy in zsh:"$ss_doc_init" bash:"$ss_doc_off_init"; do
  {
    printf '%s\n' "export AG_LEGACY_KEEP=1" "$BEGIN" \
      "# Managed by 'agent-guard setup-shell' — remove this block to disable."
    sed -n '/^eval "\$($/,$p' "${ss_legacy#*:}"
    printf '%s\n' "$END"
  } >"$ss_doc_home/.${ss_legacy%%:*}rc"
done
cp "$ss_doc_home/.zshrc" "$CASE_ROOT/legacy.zshrc"
if grep -q "^_agbin='" "$ss_doc_home/.zshrc" && grep -q 'shell-init --no-command-wrapping' "$ss_doc_home/.bashrc" \
   && [ "$(loads /bin/sh /usr/bin:/bin "$ss_doc_home/.zshrc" "$ss_doc_home")" = INSTALLED ]; then
  ok "legacy inline rc fixture has the pre-v3.9 shape and still loads"
else
  not_ok "legacy inline rc fixture has the pre-v3.9 shape and still loads"
fi
doctor_run
case "$ss_doc_notes" in
  *"$ss_doc_home/.zshrc still has the pre-v3.9 inline agent-guard block; rerun agent-guard setup-shell --zsh (or /agent-guard:setup-shell) to replace it with one line"*)
    ok "doctor reports a pre-v3.9 inline block in .zshrc" ;;
  *) not_ok "doctor reports a pre-v3.9 inline block in .zshrc: $ss_doc_notes" ;;
esac
case "$ss_doc_notes" in
  *"$ss_doc_home/.bashrc still has the pre-v3.9 inline agent-guard block; rerun agent-guard setup-shell --bash --no-command-wrapping (or /agent-guard:setup-shell)"*)
    ok "doctor keeps the command-wrapping opt-out in the inline-block advice" ;;
  *) not_ok "doctor keeps the command-wrapping opt-out in the inline-block advice: $ss_doc_notes" ;;
esac
if [ "$ss_doc_status" -eq "$ss_doc_base" ] && cmp -s "$CASE_ROOT/legacy.zshrc" "$ss_doc_home/.zshrc"; then
  ok "doctor keeps its exit status and leaves a legacy rc untouched"
else
  not_ok "doctor with a legacy rc block (status $ss_doc_status, base $ss_doc_base)"
fi
env HOME="$ss_doc_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --zsh >/dev/null 2>&1
env HOME="$ss_doc_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --bash --no-command-wrapping >/dev/null 2>&1
doctor_run
if [ -z "$ss_doc_notes" ] && grep -q 'export AG_LEGACY_KEEP=1' "$ss_doc_home/.zshrc"; then
  ok "rerunning setup-shell clears the inline-block notice"
else
  not_ok "rerunning setup-shell clears the inline-block notice: $ss_doc_notes"
fi
# A resolver file from before the stamp starts with the old comment line.
restamp "$ss_doc_init" "# Managed by 'agent-guard setup-shell' and sourced from your shell rc. Rerun setup-shell to regenerate."
cp "$ss_doc_init" "$CASE_ROOT/unstamped.init"
doctor_run
case "$ss_doc_notes" in
  *"$ss_doc_init was written by an older agent-guard setup-shell; rerun agent-guard setup-shell (or /agent-guard:setup-shell) to regenerate it"*)
    if [ "$ss_doc_status" -eq "$ss_doc_base" ] && cmp -s "$CASE_ROOT/unstamped.init" "$ss_doc_init"; then
      ok "doctor reports a resolver file without a format stamp, status and file unchanged"
    else
      not_ok "doctor with an unstamped resolver file (status $ss_doc_status, base $ss_doc_base)"
    fi ;;
  *) not_ok "doctor reports a resolver file without a format stamp: $ss_doc_notes" ;;
esac
env HOME="$ss_doc_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --zsh >/dev/null 2>&1
restamp "$ss_doc_off_init" "# agent-guard shell-init bootstrap v0 (managed by agent-guard setup-shell; rerun it to regenerate)"
doctor_run
case "$ss_doc_notes" in
  *"$ss_doc_off_init was written by an older agent-guard setup-shell; rerun agent-guard setup-shell --no-command-wrapping (or /agent-guard:setup-shell) to regenerate it"*)
    case "$ss_doc_notes" in
      *"$ss_doc_init "*) not_ok "doctor reports only the resolver file with the older stamp: $ss_doc_notes" ;;
      *) if [ "$ss_doc_status" -eq "$ss_doc_base" ]; then
           ok "doctor reports an older format stamp on the opt-out resolver file"
         else
           not_ok "doctor with an older format stamp (status $ss_doc_status, base $ss_doc_base)"
         fi ;;
    esac ;;
  *) not_ok "doctor reports an older format stamp on the opt-out resolver file: $ss_doc_notes" ;;
esac
# A newer setup-shell wrote it; this older CLI must not advise a downgrade.
restamp "$ss_doc_off_init" "# agent-guard shell-init bootstrap v$((SS_BOOTSTRAP_FORMAT + 1)) (managed by agent-guard setup-shell; rerun it to regenerate)"
doctor_run
if [ -z "$ss_doc_notes" ] && [ "$ss_doc_status" -eq "$ss_doc_base" ]; then
  ok "doctor stays quiet for a resolver file with a newer format stamp"
else
  not_ok "doctor with a newer format stamp: $ss_doc_notes"
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
# The unreleased `if` form from main between v3.8.2 and v3.9.0 is replaced too.
ss_if="$CASE_ROOT/if.rc"
printf '%s\n' 'export AG_IF_BEFORE=1' "$BEGIN" \
  "# Managed by 'agent-guard setup-shell' — remove this block to disable." \
  "unset AGENT_GUARD_SHELL_INIT_VERSION; if [ -f '$INIT' ] && [ -r '$INIT' ]; then . '$INIT'; fi" \
  "$END" 'export AG_IF_AFTER=1' >"$ss_if"
ag setup-shell --rc "$ss_if" >/dev/null 2>&1
ss_if_shape=$(awk -v b="$BEGIN" '$0==b{print "BLOCK"; next} /^export AG_IF_/{print}' "$ss_if" | tr '\n' ' ')
if [ "$ss_if_shape" = 'export AG_IF_BEFORE=1 BLOCK export AG_IF_AFTER=1 ' ] \
   && [ "$(block_of "$ss_if")" = "$ss_block" ]; then
  ok "setup-shell replaces the earlier if-form block in place"
else
  not_ok "setup-shell replaces the earlier if-form block in place (shape: $ss_if_shape)"
  sed 's/^/  rc: /' "$ss_if"
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

# Without the resolver file the rc line loads nothing, prints nothing, and ends
# with status 0, even as the rc's last line: a `set -e` caller survives and the
# first prompt's $? stays 0. Must-pass control: the same rc loads above.
ss_last="$CASE_ROOT/last.rc"
ag setup-shell --rc "$ss_last" >/dev/null 2>&1
mv "$INIT" "$CASE_ROOT/shell-init.moved"
for ss_shell in /bin/sh /bin/bash /bin/zsh; do
  [ -x "$ss_shell" ] || continue
  ss_missing=$(env HOME="$SS_HOME" PATH=/usr/bin:/bin AGENT_GUARD_BIN= \
    AGENT_GUARD_SHELL_INIT_VERSION= "$ss_shell" -ec \
    '. "$1"; command -v agx >/dev/null 2>&1 && echo INSTALLED || echo MISSING' \
    _ "$ss_last" 2>"$ERR")
  ss_missing_status=$?
  ss_missing_rc=$(env HOME="$SS_HOME" PATH=/usr/bin:/bin "$ss_shell" -c '. "$1"; echo $?' _ "$ss_last" 2>/dev/null)
  if [ "$ss_missing_status" -eq 0 ] && [ "$ss_missing" = MISSING ] && [ ! -s "$ERR" ] \
     && [ "$ss_missing_rc" = 0 ]; then
    ok "${ss_shell##*/} rc line is a silent status-0 no-op when the resolver file is missing"
  else
    not_ok "${ss_shell##*/} rc line with a missing resolver file (status $ss_missing_status, got: $ss_missing, \$?: $ss_missing_rc)"
    sed 's/^/  stderr: /' "$ERR"
  fi
done
mv "$CASE_ROOT/shell-init.moved" "$INIT"
# The resolver file re-exports the marker only when it loads.
ss_reloaded=$(env HOME="$SS_HOME" PATH=/usr/bin:/bin AGENT_GUARD_BIN= \
  AGENT_GUARD_SHELL_INIT_VERSION=9.9.9 /bin/sh -c \
  '. "$1"; printf %s "${AGENT_GUARD_SHELL_INIT_VERSION:-UNSET}"' _ "$ss_rc" 2>/dev/null)
if [ "$ss_reloaded" != UNSET ] && [ "$ss_reloaded" != 9.9.9 ]; then
  ok "resolver file replaces an inherited marker with the version it loads"
else
  not_ok "resolver file replaces an inherited marker (got: $ss_reloaded)"
fi

# A directory at the resolver path is refused before the rc is touched.
ss_dir_home="$CASE_ROOT/dir-home"
mkdir -p "$ss_dir_home/.agent-guard/shell-init.sh"
printf 'export AG_DIR_KEEP=1\n' >"$CASE_ROOT/dir.rc"
if env HOME="$ss_dir_home" "$PLUGIN_ROOT/bin/agent-guard" setup-shell --rc "$CASE_ROOT/dir.rc" >/dev/null 2>"$ERR"; then
  not_ok "setup-shell refuses a directory at the resolver path"
elif grep -q 'is a directory' "$ERR" \
     && [ "$(cat "$CASE_ROOT/dir.rc")" = 'export AG_DIR_KEEP=1' ] \
     && [ -z "$(ls -A "$ss_dir_home/.agent-guard/shell-init.sh")" ]; then
  ok "setup-shell refuses a directory at the resolver path and leaves the rc untouched"
else
  not_ok "setup-shell directory refusal left changes behind"
  sed 's/^/  stderr: /' "$ERR"
fi

# SessionStart follows the rc line into the resolver file: present and
# resolvable stays quiet, missing reports that the block can no longer load.
ss_start_home="$CASE_ROOT/sstart-home"
mkdir -p "$ss_start_home"
ss_start_path="$(dirname "$(command -v jq)"):$(dirname "$(command -v git)"):/usr/bin:/bin"
session_start_message() {  # $1 = HOME (default: $ss_start_home), $2 = inherited marker
  env -u AGENT_GUARD_SHELL_INIT_VERSION ${2:+AGENT_GUARD_SHELL_INIT_VERSION=$2} \
    HOME="${1:-$ss_start_home}" SHELL=/bin/zsh \
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
  ss_version=$("$PLUGIN_ROOT/bin/agent-guard" version 2>/dev/null | awk '{print $NF}')
  [ -n "$ss_version" ] || not_ok "agent-guard version printed no version"
  case "$(session_start_message "" "$ss_version")" in
    '') ok "SessionStart stays quiet with a matching marker and a loadable block" ;;
    *) not_ok "SessionStart stays quiet with a matching marker and a loadable block" ;;
  esac
  mv "$ss_start_home/.agent-guard/shell-init.sh" "$CASE_ROOT/sstart-init.moved"
  case "$(session_start_message)" in
    *'can no longer load'*) ok "SessionStart reports a one-line block whose resolver file is missing" ;;
    *) not_ok "SessionStart reports a one-line block whose resolver file is missing" ;;
  esac
  # A marker inherited from a shell that loaded earlier must not hide that.
  case "$(session_start_message "" "$ss_version")" in
    *'can no longer load'*) ok "SessionStart reports a missing resolver file despite an inherited marker" ;;
    *) not_ok "SessionStart reports a missing resolver file despite an inherited marker" ;;
  esac
  # The rc line only checks -r; a directory put there by hand must still warn.
  mkdir "$ss_start_home/.agent-guard/shell-init.sh"
  case "$(session_start_message "" "$ss_version")" in
    *'can no longer load'*) ok "SessionStart reports a directory at the resolver path" ;;
    *) not_ok "SessionStart reports a directory at the resolver path" ;;
  esac
  rmdir "$ss_start_home/.agent-guard/shell-init.sh"
  # fish covers both rc files: one healthy, one missing is partial coverage,
  # and an inherited marker must not hide it either.
  ss_fish_home="$CASE_ROOT/fish-home"
  mkdir -p "$ss_fish_home"
  env HOME="$ss_fish_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell --zsh >/dev/null 2>&1
  env HOME="$ss_fish_home" SHELL=/bin/bash "$PLUGIN_ROOT/bin/agent-guard" setup-shell --bash --no-command-wrapping >/dev/null 2>&1
  mv "$ss_fish_home/.agent-guard/shell-init.sh" "$CASE_ROOT/fish-init.moved"
  case "$(env -u AGENT_GUARD_SHELL_INIT_VERSION AGENT_GUARD_SHELL_INIT_VERSION="$ss_version" \
      HOME="$ss_fish_home" SHELL=/usr/bin/fish AGENT_GUARD_HOOK_HOST=claude \
      AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" PATH="$ss_start_path" \
      "$PLUGIN_ROOT/bin/agent-guard" hook-session-start 2>/dev/null)" in
    *'does not cover both'*) ok "SessionStart reports partial fish coverage despite an inherited marker" ;;
    *) not_ok "SessionStart reports partial fish coverage despite an inherited marker" ;;
  esac
  # The earlier `if` form (main between v3.8.2 and v3.9.0) still reads as
  # loadable until setup-shell reruns; without its file it warns.
  ss_if_home="$CASE_ROOT/if-home"
  mkdir -p "$ss_if_home"
  env HOME="$ss_if_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell >/dev/null 2>&1
  ss_if_init="$ss_if_home/.agent-guard/shell-init.sh"
  printf '%s\n' "$BEGIN" \
    "unset AGENT_GUARD_SHELL_INIT_VERSION; if [ -f '$ss_if_init' ] && [ -r '$ss_if_init' ]; then . '$ss_if_init'; fi" \
    "$END" >"$ss_if_home/.zshrc"
  ss_if_quiet=$(session_start_message "$ss_if_home" "$ss_version")
  mv "$ss_if_init" "$CASE_ROOT/if-init.moved"
  case "$ss_if_quiet:$(session_start_message "$ss_if_home" "$ss_version")" in
    :*'can no longer load'*) ok "SessionStart reads the earlier if-form block (quiet with its file, warns without)" ;;
    *) not_ok "SessionStart reads the earlier if-form block (with file: $ss_if_quiet)" ;;
  esac
  # sh_squote escapes a quote in HOME; the probe must read the same path.
  ss_quote_home="$CASE_ROOT/home with ' quote"
  mkdir -p "$ss_quote_home"
  env HOME="$ss_quote_home" SHELL=/bin/zsh "$PLUGIN_ROOT/bin/agent-guard" setup-shell >/dev/null 2>&1
  ss_quote_loads=$(loads /bin/sh /usr/bin:/bin "$ss_quote_home/.zshrc" "$ss_quote_home")
  case "$(session_start_message "$ss_quote_home")" in
    *'can no longer load'*|*'is not loaded'*)
      not_ok "SessionStart reads a resolver path whose HOME contains a quote (loads: $ss_quote_loads)" ;;
    *) if [ "$ss_quote_loads" = INSTALLED ]; then
         ok "SessionStart reads a resolver path whose HOME contains a quote"
       else
         not_ok "rc with a quoted HOME did not load (got: $ss_quote_loads)"
       fi ;;
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

#!/usr/bin/env sh
# Offline integration: only curl downloads are substituted; checksum, payload
# validation, installation, CLI update, shell setup and version execute for real.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-update-test.XXXXXX")
CASE_ROOT=$(CDPATH= cd -- "$CASE_ROOT" && pwd -P)
trap 'rm -rf "$CASE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$CASE_ROOT/download/bin" "$CASE_ROOT/home"
"$ROOT/scripts/build-release-tarball.sh" 2.0.0 "$CASE_ROOT/download/agent-guard-2.0.0.tar.gz"
(cd "$CASE_ROOT/download" && shasum -a 256 agent-guard-2.0.0.tar.gz >agent-guard-2.0.0.tar.gz.sha256)
QA_REAL_GITLEAKS=$(command -v gitleaks 2>/dev/null || :)
cat >"$CASE_ROOT/download/bin/curl" <<'STUB'
#!/bin/sh
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift; out=${1:-} ;; esac
  shift
done
case "$out" in
  */bootstrap.sh) cp "$QA_SOURCE/bootstrap.sh" "$out" ;;
  *.tar.gz) cp "$QA_DOWNLOAD/agent-guard-2.0.0.tar.gz" "$out" ;;
  *.tar.gz.sha256) cp "$QA_DOWNLOAD/agent-guard-2.0.0.tar.gz.sha256" "$out" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$CASE_ROOT/download/bin/curl"
export QA_SOURCE="$ROOT" QA_DOWNLOAD="$CASE_ROOT/download"
# All install and shell state belongs to this one temporary test environment.
export HOME="$CASE_ROOT/home" SHELL=/bin/zsh AGENT_GUARD_VERSION=2.0.0
export PATH="$CASE_ROOT/download/bin:/usr/bin:/bin"
if [ -n "$QA_REAL_GITLEAKS" ]; then
  PATH="$CASE_ROOT/download/bin:$(dirname "$QA_REAL_GITLEAKS"):/usr/bin:/bin"
  export PATH
fi
export AGENT_GUARD_HOME="$CASE_ROOT/payload"
check() { printf 'ok - %s\n' "$1"; }
healthy() {
  [ ! -L "$AGENT_GUARD_HOME/bin/agent-guard" ]
  "$1" version >"$CASE_ROOT/version"
  grep -q agent-guard "$CASE_ROOT/version"
}
installed_state_unchanged() {
  [ "$payload_before" = "$(shasum -a 256 "$AGENT_GUARD_HOME/bin/agent-guard")" ]
  [ "$public_target_before" = "$(readlink "$CASE_ROOT/custom bin/agent-guard")" ]
  grep -q 'keep user data' "$AGENT_GUARD_HOME/local-note"
  healthy "$CASE_ROOT/custom bin/agent-guard"
}
real_runtime_qa() {
  [ -n "$QA_REAL_GITLEAKS" ] || return 0
  run "$1" version
  run "$1" doctor
  run "$1" check
  run "$1" smoke-test
}
run() { "$@" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || { cat "$CASE_ROOT/err" >&2; return 1; }; }
AGENT_GUARD_BIN_DIR="$CASE_ROOT/custom bin" run sh "$ROOT/bootstrap.sh"
healthy "$CASE_ROOT/custom bin/agent-guard"
real_runtime_qa "$CASE_ROOT/custom bin/agent-guard"
printf 'keep user data\n' >"$AGENT_GUARD_HOME/local-note"
run "$CASE_ROOT/custom bin/agent-guard" update
healthy "$CASE_ROOT/custom bin/agent-guard"
real_runtime_qa "$CASE_ROOT/custom bin/agent-guard"
[ "$(readlink "$CASE_ROOT/custom bin/agent-guard")" = "$AGENT_GUARD_HOME/bin/agent-guard" ]
grep -q 'keep user data' "$AGENT_GUARD_HOME/local-note"
check 'standalone update preserves custom public link and unrelated files'
if [ -n "$QA_REAL_GITLEAKS" ]; then
  check 'real gitleaks version, doctor, check and smoke pass before and after update'
else
  printf 'skip - real gitleaks unavailable; runtime update QA not run\n'
fi

(cd "$CASE_ROOT" && run './custom bin/agent-guard' update)
healthy "$CASE_ROOT/custom bin/agent-guard"
check 'relative symlink invocation updates without a self-link'

PATH="$CASE_ROOT/custom bin:$PATH" run agent-guard update
healthy "$CASE_ROOT/custom bin/agent-guard"
check 'PATH invocation updates without a self-link'

run "$AGENT_GUARD_HOME/bin/agent-guard" update
healthy "$AGENT_GUARD_HOME/bin/agent-guard"
healthy "$CASE_ROOT/custom bin/agent-guard"
check 'direct payload invocation skips a redundant symlink'

AGENT_GUARD_BIN_DIR="$CASE_ROOT/override" run "$CASE_ROOT/custom bin/agent-guard" update
healthy "$CASE_ROOT/override/agent-guard"
check 'explicit update link-directory override is honored'

ln -s "$AGENT_GUARD_HOME/bin" "$CASE_ROOT/bin-alias"
AGENT_GUARD_BIN_DIR="$CASE_ROOT/bin-alias" run sh "$ROOT/bootstrap.sh"
healthy "$CASE_ROOT/bin-alias/agent-guard"
check 'physical directory aliases cannot create executable self-links'

mv "$AGENT_GUARD_HOME/install.sh" "$CASE_ROOT/external-installer"
external_before=$(shasum -a 256 "$CASE_ROOT/external-installer")
ln -s "$CASE_ROOT/external-installer" "$AGENT_GUARD_HOME/install.sh"
run "$CASE_ROOT/custom bin/agent-guard" update
healthy "$CASE_ROOT/custom bin/agent-guard"
[ ! -L "$AGENT_GUARD_HOME/install.sh" ]
[ -x "$AGENT_GUARD_HOME/install.sh" ]
[ "$external_before" = "$(shasum -a 256 "$CASE_ROOT/external-installer")" ]
check 'update replaces an installer symlink without modifying its external target'

payload_before=$(shasum -a 256 "$AGENT_GUARD_HOME/bin/agent-guard")
public_target_before=$(readlink "$CASE_ROOT/custom bin/agent-guard")
mkdir -p "$CASE_ROOT/invalid/bin"
printf '#!/bin/sh\nexit 0\n' >"$CASE_ROOT/invalid/bin/agent-guard"
chmod +x "$CASE_ROOT/invalid/bin/agent-guard"
cp "$CASE_ROOT/download/agent-guard-2.0.0.tar.gz" "$CASE_ROOT/valid.tar.gz"
tar -C "$CASE_ROOT/invalid" -czf "$CASE_ROOT/download/agent-guard-2.0.0.tar.gz" .
(cd "$CASE_ROOT/download" && shasum -a 256 agent-guard-2.0.0.tar.gz >agent-guard-2.0.0.tar.gz.sha256)
if AGENT_GUARD_BIN_DIR="$CASE_ROOT/custom bin" sh "$ROOT/bootstrap.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then exit 1; fi
installed_state_unchanged
check 'checksum-valid incomplete archive leaves working executable untouched'

mkdir -p "$CASE_ROOT/invalid-policy"
tar -xzf "$CASE_ROOT/valid.tar.gz" -C "$CASE_ROOT/invalid-policy"
mv "$CASE_ROOT/invalid-policy/config/gitleaks.toml" "$CASE_ROOT/invalid-policy/config/gitleaks.toml.original"
mkdir "$CASE_ROOT/invalid-policy/config/gitleaks.toml"
tar -C "$CASE_ROOT/invalid-policy" -czf "$CASE_ROOT/download/agent-guard-2.0.0.tar.gz" .
(cd "$CASE_ROOT/download" && shasum -a 256 agent-guard-2.0.0.tar.gz >agent-guard-2.0.0.tar.gz.sha256)
if AGENT_GUARD_BIN_DIR="$CASE_ROOT/custom bin" sh "$ROOT/bootstrap.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then exit 1; fi
installed_state_unchanged
check 'checksum-valid non-regular policy leaves working installation untouched'

cp "$CASE_ROOT/valid.tar.gz" "$CASE_ROOT/download/agent-guard-2.0.0.tar.gz"
if AGENT_GUARD_BIN_DIR="$CASE_ROOT/custom bin" sh "$ROOT/bootstrap.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then exit 1; fi
installed_state_unchanged
check 'checksum failure preserves the installed executable'
(cd "$CASE_ROOT/download" && shasum -a 256 agent-guard-2.0.0.tar.gz >agent-guard-2.0.0.tar.gz.sha256)

mkdir -p "$CASE_ROOT/directory-target/agent-guard"
printf 'preserve\n' >"$CASE_ROOT/directory-target/agent-guard/note"
if AGENT_GUARD_BIN_DIR="$CASE_ROOT/directory-target" sh "$ROOT/bootstrap.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"; then exit 1; fi
grep -q preserve "$CASE_ROOT/directory-target/agent-guard/note"
installed_state_unchanged
check 'directory link target is rejected without changing existing data'

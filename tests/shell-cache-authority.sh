#!/usr/bin/env sh
# Actual generated rc + shell-init in a private synthetic plugin cache. No host
# registry, installed cache, or user's rc is modified.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-cache-test.XXXXXX")
QA_REAL_GITLEAKS=$(command -v gitleaks 2>/dev/null || :)
trap 'rm -rf "$CASE_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CACHE="$CASE_ROOT/cache with ' quote"
RC="$CASE_ROOT/test.rc"
mkdir -p "$CACHE" "$CASE_ROOT/home"
payload() {
  mkdir -p "$CACHE/$1/bin"
  sed "s/^VERSION=.*/VERSION=$1/" "$ROOT/plugins/agent-guard/bin/agent-guard" >"$CACHE/$1/bin/agent-guard"
  chmod +x "$CACHE/$1/bin/agent-guard"
  cp -R "$ROOT/plugins/agent-guard/config" "$CACHE/$1/config"
}
run_guard() {
  env HOME="$CASE_ROOT/home" "$CACHE/$1/bin/agent-guard" "$2" ${3+"$3"} ${4+"$4"} >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
}
assert_current() {
  [ "$(readlink "$CACHE/current")" = "$1" ] || {
    printf 'not ok - current should remain %s\n' "$1"; exit 1;
  }
}
snapshot_with_path() {
  env HOME="$CASE_ROOT/home" PATH="$2" AGENT_GUARD_BIN= \
    AGENT_GUARD_SHELL_INIT_VERSION= QA_CACHE_EXECUTED="$CASE_ROOT/partial-executed" \
    QA_VALID_GUARD="$ROOT/plugins/agent-guard/bin/agent-guard" \
    "$1" -c 'cd "$2"; . "$1"; printf "%s\n" "${AGENT_GUARD_SHELL_INIT_VERSION:-missing}"' \
    _ "$RC" "$CASE_ROOT" 2>"$CASE_ROOT/err"
}
snapshot() { snapshot_with_path "$1" /usr/bin:/bin; }
runtime_qa() {
  [ -n "$QA_REAL_GITLEAKS" ] || return 0
  env HOME="$CASE_ROOT/home" PATH="$(dirname "$QA_REAL_GITLEAKS"):/usr/bin:/bin" \
    AGENT_GUARD_BIN= AGENT_GUARD_SHELL_INIT_VERSION= \
    /bin/sh -c '
      cd "$2"
      . "$1"
      [ "${AGENT_GUARD_SHELL_INIT_VERSION:-missing}" = 3.1.1 ]
      selected=$(__agentguard_exe)
      "$selected" check >/dev/null 2>&1
      [ "$(agx printf %s runtime-ok)" = runtime-ok ]
    ' _ "$RC" "$CASE_ROOT"
}
check() { printf 'ok - %s\n' "$1"; }
payload 3.1.0
payload 3.1.1
payload 3.2.0
run_guard 3.1.1 setup-shell --rc "$RC"
assert_current 3.1.1
for shell in /bin/sh /bin/bash /bin/zsh; do
  [ -x "$shell" ] || continue
  [ "$(snapshot "$shell")" = 3.1.1 ]
  assert_current 3.1.1
  check "${shell##*/} rc keeps healthy selected current over a newer cached sibling"
done
runtime_qa
if [ -n "$QA_REAL_GITLEAKS" ]; then
  check 'real gitleaks check and agx run through the selected current payload'
else
  printf 'skip - real gitleaks unavailable; selected-current runtime QA not run\n'
fi

run_guard 3.2.0 version
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
check 'existing rc follows a newer version after that host-selected binary runs'
run_guard 3.1.0 version
assert_current 3.2.0
check 'a stale binary cannot move current backward'

payload 8.0.0
sed 's/^VERSION=.*/VERSION=7.0.0/' "$CACHE/8.0.0/bin/agent-guard" >"$CASE_ROOT/mismatch"
cp "$CASE_ROOT/mismatch" "$CACHE/8.0.0/bin/agent-guard"
mkdir -p "$CACHE/9.0.0/bin"
cat >"$CACHE/9.0.0/bin/agent-guard" <<'STUB'
#!/bin/sh
VERSION=9.0.0
printf 'partial payload executed\n' >>"$QA_CACHE_EXECUTED"
STUB
chmod +x "$CACHE/9.0.0/bin/agent-guard"
payload 10.0.0
mv "$CACHE/10.0.0/config/gitleaks.toml" "$CACHE/10.0.0/config/gitleaks.toml.original"
mkdir "$CACHE/10.0.0/config/gitleaks.toml"
payload 11.0.0
printf ' \r\n\t# interrupted policy extraction\r\n' \
  >"$CACHE/11.0.0/config/deny-read-paths.txt"
rm "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
check 'missing current recovers from the newest complete version, skipping partial, mismatched, non-regular and inactive-policy payloads'

rm "$CACHE/current"
ln -s 9.0.0 "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'invalid current recovers without executing a partial cache payload'

mkdir -p "$CASE_ROOT/outside/bin"
cp -R "$ROOT/plugins/agent-guard/config" "$CASE_ROOT/outside/config"
cat >"$CASE_ROOT/outside/bin/agent-guard" <<'STUB'
#!/bin/sh
VERSION=../outside
printf 'outside current executed\n' >>"$QA_CACHE_EXECUTED"
exec "$QA_VALID_GUARD" "$@"
STUB
chmod +x "$CASE_ROOT/outside/bin/agent-guard"
rm "$CACHE/current"
ln -s ../outside "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'current must name a direct semantic-version cache sibling and cannot escape the cache base'

mkdir -p "$CACHE/1.2.3:4/bin"
cp -R "$ROOT/plugins/agent-guard/config" "$CACHE/1.2.3:4/config"
cat >"$CACHE/1.2.3:4/bin/agent-guard" <<'STUB'
#!/bin/sh
VERSION=1.2.3:4
printf 'malformed current executed\n' >>"$QA_CACHE_EXECUTED"
exec "$QA_VALID_GUARD" "$@"
STUB
chmod +x "$CACHE/1.2.3:4/bin/agent-guard"
rm "$CACHE/current"
ln -s '1.2.3:4' "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'current target requires three numeric semantic-version components'

mkdir -p "$CASE_ROOT/symlink-outside/bin"
cp -R "$ROOT/plugins/agent-guard/config" "$CASE_ROOT/symlink-outside/config"
cat >"$CASE_ROOT/symlink-outside/bin/agent-guard" <<'STUB'
#!/bin/sh
VERSION=12.0.0
printf 'symlinked cache root executed\n' >>"$QA_CACHE_EXECUTED"
exec "$QA_VALID_GUARD" "$@"
STUB
chmod +x "$CASE_ROOT/symlink-outside/bin/agent-guard"
ln -s "$CASE_ROOT/symlink-outside" "$CACHE/12.0.0"
rm "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
[ ! -e "$CASE_ROOT/partial-executed" ]
ln -s 12.0.0 "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'fallback and current reject a semantic-version cache entry that is a directory symlink'

mkdir -p "$CACHE/13.0.0/bin"
sed 's/^VERSION=.*/VERSION=13.0.0/' \
  "$ROOT/plugins/agent-guard/bin/agent-guard" >"$CACHE/13.0.0/bin/agent-guard"
chmod +x "$CACHE/13.0.0/bin/agent-guard"
ln -s "$ROOT/plugins/agent-guard/config" "$CACHE/13.0.0/config"
rm "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
assert_current 3.2.0
check 'fallback rejects a payload whose required directory is a symlink'

rm "$CACHE/current"
mkdir "$CACHE/current"
[ "$(snapshot /bin/sh)" = 3.2.0 ]
[ -d "$CACHE/current" ] && [ ! -L "$CACHE/current" ]
check 'unreplaceable current directory is preserved while a complete fallback loads'

rmdir "$CACHE/current"
ln -s 9.0.0 "$CACHE/current"
rm -rf "$CACHE/3.1.0" "$CACHE/3.1.1" "$CACHE/3.2.0"
[ "$(snapshot /bin/sh)" = missing ]
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'no complete cache does not execute a rejected current through the stable or PATH fallback'

rm "$CACHE/current"
cache_relative=${CACHE#"$CASE_ROOT"/}
[ "$(snapshot_with_path /bin/sh "$cache_relative/9.0.0/bin:/usr/bin:/bin")" = missing ]
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'relative PATH cannot re-enter a rejected partial cache payload'

cat >"$CACHE/8.0.0/bin/agent-guard" <<'STUB'
#!/bin/sh
VERSION=7.0.0
printf 'mismatched payload executed\n' >>"$QA_CACHE_EXECUTED"
exec "$QA_VALID_GUARD" "$@"
STUB
chmod +x "$CACHE/8.0.0/bin/agent-guard"
mkdir "$CASE_ROOT/external-alias"
ln -s "$CACHE/8.0.0/bin/agent-guard" "$CASE_ROOT/external-alias/agent-guard"
[ "$(snapshot_with_path /bin/sh "$CASE_ROOT/external-alias:/usr/bin:/bin")" = missing ]
[ ! -e "$CASE_ROOT/partial-executed" ]
check 'external symlink alias cannot re-enter a rejected mismatched cache payload'

# Standalone installs retain the existing output-probed PATH recovery if their
# baked executable is still executable but can no longer emit shell-init.
mkdir -p "$CASE_ROOT/standalone/bin" "$CASE_ROOT/path-bin"
cp "$ROOT/plugins/agent-guard/bin/agent-guard" "$CASE_ROOT/standalone/bin/agent-guard"
cp -R "$ROOT/plugins/agent-guard/config" "$CASE_ROOT/standalone/config"
env HOME="$CASE_ROOT/home" "$CASE_ROOT/standalone/bin/agent-guard" \
  setup-shell --rc "$RC" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
printf '#!/bin/sh\nexit 3\n' >"$CASE_ROOT/standalone/bin/agent-guard"
ln -s "$ROOT/plugins/agent-guard/bin/agent-guard" "$CASE_ROOT/path-bin/agent-guard"
for shell in /bin/sh /bin/bash /bin/zsh; do
  [ -x "$shell" ] || continue
  recovered=$(env HOME="$CASE_ROOT/home" PATH="$CASE_ROOT/path-bin:/usr/bin:/bin" \
    AGENT_GUARD_BIN= AGENT_GUARD_SHELL_INIT_VERSION= \
    "$shell" -ec '. "$1"; printf "%s\n" "${AGENT_GUARD_SHELL_INIT_VERSION:-missing}"' \
    _ "$RC" 2>"$CASE_ROOT/err")
  [ "$recovered" != missing ]
  check "${shell##*/} set -e recovers a stale standalone shell-init through an independent PATH executable"
done

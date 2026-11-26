#!/bin/sh
# O-2: AGENT_GUARD_GITLEAKS_CHECKSUMS_URL (the checksum command's source) and
# AGENT_GUARD_REPO (the installer's source repository) are test seams. They are
# honored silently behind AG_PLUGIN_TEST_MODE=1; outside it they are still
# honored during the deprecation period, with a warning that names the setting
# and never its value. A stand-in curl records every URL it is asked for, so the
# source that was really used is observed.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d "${TMPDIR:-/tmp}/ag-testseam.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() {
  fail=$((fail + 1)); printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE/err" ] || sed 's/^/  stderr: /' "$CASE/err"
  [ ! -s "$CASE/urls" ] || sed 's/^/  url: /' "$CASE/urls"
}
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$CASE/bin"
cat >"$CASE/bin/curl" <<'STUB'
#!/bin/sh
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; out=$1 ;;
    -w) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$url" >>"$AG_TEST_URLS"
case "$url" in
  *checksums*) cat "$AG_TEST_CHECKSUMS" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$CASE/bin/curl"
export AG_TEST_URLS="$CASE/urls" AG_TEST_CHECKSUMS="$ROOT/tests/fixtures/gitleaks-checksums-mock.txt"
SEAM="https://checksums.example.invalid/sums-checksums.txt"
FORK=example-fork/agent-guard-fork

run() { # settings... then the command after --
  : >"$CASE/urls"
  env -u AGENT_GUARD_GITLEAKS_CHECKSUMS_URL -u AGENT_GUARD_REPO -u AG_PLUGIN_TEST_MODE \
    PATH="$CASE/bin:$PATH" HOME="$CASE/home" "$@" >"$CASE/out" 2>"$CASE/err" </dev/null
  echo "$?" >"$CASE/status"
}
warned() { grep -F "$1" "$CASE/err" | grep -qF deprecated; }
# The warning names the setting and never the value it was given.
warning_value_free() { ! grep -F "$1" "$CASE/err" | grep -F deprecated | grep -qF -e "$SEAM" -e "$FORK"; }
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"

# --- checksum ---------------------------------------------------------------
run AG_PLUGIN_TEST_MODE=1 AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="$SEAM" "$GUARD" checksum 8.30.1
expect "behind AG_PLUGIN_TEST_MODE=1 the checksum URL is used without a warning" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ "$(cat "$CASE/urls")" = "$SEAM" ] && grep -q "linux/x64:" "$CASE/out" \
   && ! warned AGENT_GUARD_GITLEAKS_CHECKSUMS_URL'
run AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="$SEAM" "$GUARD" checksum 8.30.1
expect "deprecated: outside tests the checksum URL is still used, with a warning" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ "$(cat "$CASE/urls")" = "$SEAM" ] \
   && warned AGENT_GUARD_GITLEAKS_CHECKSUMS_URL && warned AG_PLUGIN_TEST_MODE'
expect "and the warning does not repeat the URL" 'warning_value_free AGENT_GUARD_GITLEAKS_CHECKSUMS_URL'
run "$GUARD" checksum 8.30.1
expect "control: without it the published gitleaks checksums are fetched, without a warning" \
  '[ "$(cat "$CASE/status")" = 0 ] \
   && [ "$(cat "$CASE/urls")" = "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_checksums.txt" ] \
   && ! warned AGENT_GUARD_GITLEAKS_CHECKSUMS_URL'
run AG_PLUGIN_TEST_MODE=0 AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="$SEAM" "$GUARD" checksum 8.30.1
expect "AG_PLUGIN_TEST_MODE other than 1 is outside tests" 'warned AGENT_GUARD_GITLEAKS_CHECKSUMS_URL'

# --- bootstrap.sh -------------------------------------------------------------
# Every download fails, so the installer stops before it writes anything.
run AG_PLUGIN_TEST_MODE=1 AGENT_GUARD_REPO="$FORK" AGENT_GUARD_VERSION=9.9.9 sh "$ROOT/bootstrap.sh"
expect "behind AG_PLUGIN_TEST_MODE=1 the installer downloads from AGENT_GUARD_REPO without a warning" \
  '[ "$(cat "$CASE/status")" != 0 ] && grep -qF "https://github.com/$FORK/releases/download/v9.9.9/" "$CASE/urls" \
   && ! warned AGENT_GUARD_REPO'
run AGENT_GUARD_REPO="$FORK" AGENT_GUARD_VERSION=9.9.9 sh "$ROOT/bootstrap.sh"
expect "deprecated: outside tests the installer still uses AGENT_GUARD_REPO, with a warning" \
  'grep -qF "https://github.com/$FORK/releases/download/v9.9.9/" "$CASE/urls" \
   && warned AGENT_GUARD_REPO && warned AG_PLUGIN_TEST_MODE'
expect "and the warning does not repeat the repository" 'warning_value_free AGENT_GUARD_REPO'
run AGENT_GUARD_VERSION=9.9.9 sh "$ROOT/bootstrap.sh"
expect "control: without it the installer downloads from the project repository, without a warning" \
  'grep -qF "https://github.com/JeongJaeSoon/agent-guard/releases/download/v9.9.9/" "$CASE/urls" \
   && ! grep -qF "$FORK" "$CASE/urls" && ! warned AGENT_GUARD_REPO'
expect "the installer header marks AGENT_GUARD_REPO as a test seam" \
  'grep -A1 "AGENT_GUARD_REPO" "$ROOT/bootstrap.sh" | head -2 | grep -qF AG_PLUGIN_TEST_MODE'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

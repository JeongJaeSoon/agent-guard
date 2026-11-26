#!/bin/sh
# O-3: doctor is a diagnosis command. It passes its arguments to setup, so
# install arguments made it install. They are deprecated: during the period
# doctor still passes them on, with a warning that points to setup and never
# repeats an argument's value; --help and a bare doctor are unchanged.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/ag-doctor-args.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; [ ! -s "$CASE/err" ] || sed 's/^/  stderr: /' "$CASE/err"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$CASE/gl" "$CASE/home"
cat >"$CASE/gl/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in version) printf '%s\n' 8.30.1 ;; stdin) cat >/dev/null ;; esac
exit 0
STUB
chmod +x "$CASE/gl/gitleaks"
SUM=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
doctor() {
  env -u AGENT_GUARD_GITLEAKS_BIN_DIR -u AGENT_GUARD_BIN_DIR HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" \
    AGENT_GUARD_GITLEAKS_BIN="$CASE/gl/gitleaks" AGENT_GUARD_GITLEAKS_HELPER=off AGENT_GUARD_LOG_MODE=off \
    AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_CODEX_TRUST_CHECK=off \
    "$GUARD" doctor "$@" >"$CASE/out" 2>"$CASE/err" </dev/null
  echo "$?" >"$CASE/status"
}
status() { cat "$CASE/status"; }
warned() { grep -F 'doctor' "$CASE/err" | grep -F 'deprecated' | grep -qF 'setup'; }

doctor --install --gitleaks-checksum "$SUM"
expect "deprecated: doctor --install still runs setup's install path, with a warning that points to setup" \
  '[ "$(status)" = 0 ] && grep -qF "skipping --install" "$CASE/err" && warned'
expect "and the warning does not repeat the checksum" '! grep -F deprecated "$CASE/err" | grep -qF "$SUM"'
for arg in --install-gitleaks-helper "--gitleaks-version=8.30.1" "--gitleaks-checksum=$SUM"; do
  doctor "$arg" --help
  expect "doctor $(printf '%s' "$arg" | cut -c1-24) warns too" 'warned'
done
doctor
expect "control: a bare doctor has no warning" '[ "$(status)" = 0 ] && ! warned && grep -qF "setup ok" "$CASE/err"'
doctor --help
expect "control: doctor --help still prints usage, without a warning" \
  '[ "$(status)" = 0 ] && grep -qF "Usage:" "$CASE/err" && ! warned'
doctor --bogus
expect "control: an unknown argument is still refused with status 2" '[ "$(status)" = 2 ] && grep -qF "unknown argument" "$CASE/err"'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

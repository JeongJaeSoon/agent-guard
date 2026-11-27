#!/bin/sh
# P-4: doctor has a settings section. It reports what doctor itself reads in
# its own environment: an accepted enum, number or list value as is, a path or
# URL only as "set", and never an unrecognized value. Values that differ from
# the default, unrecognized values and deprecated names are marked, and one
# line says that hook environments may differ.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/ag-doctor-settings.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; grep -F 'setting' "$CASE/err" | sed 's/^/  stderr: /'; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$CASE/gl" "$CASE/home"
cat >"$CASE/gl/gitleaks" <<'STUB'
#!/bin/sh
case "${1:-}" in version) printf '%s\n' 8.30.1 ;; stdin) cat >/dev/null ;; esac
exit 0
STUB
chmod +x "$CASE/gl/gitleaks"
# Every name the section knows starts unset; each case sets its own.
NAMES='INFRA_FAILURE_MODE PROMPT_GUARD_MODE OUTPUT_REDACT DENY_READ_MODE PII_HOOK_MODE LOG_MODE SESSION_ROLE
COMMAND_WRAPPING KEY_NAME_REDACT TRACKED_FILE_EXCEPTION KNOWN_VALUE_REDACT SCAN_CACHE RELEASE_CHECK
CODEX_TRUST_CHECK EXPERIMENTAL_REDACTOR PII_PROVIDER PII_LANGUAGE PII_SKIP SCAN_INPUT_MAX_BYTES
PII_TIMEOUT_SECONDS GITLEAKS_HELPER_IDLE_SECONDS GITLEAKS_HELPER_MAX_RSS_MIB GITLEAKS_HELPER
DENY_READ_PATHS DENY_BASH_PATTERNS GITLEAKS_CONFIG MASK_DENY_VALUES GITLEAKS_BIN_DIR RUST_CORE_BIN
PII_REDACT_URL GITLEAKS_HELPER_TRACE BIN BIN_DIR GITLEAKS_CHECKSUMS_URL REPO PII_HOOK_REQUEST'
UNSET=
for n in $NAMES; do UNSET="$UNSET -u AGENT_GUARD_$n"; done
doctor() {
  env $UNSET HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_GITLEAKS_BIN="$CASE/gl/gitleaks" \
    "$@" "$GUARD" doctor >"$CASE/out" 2>"$CASE/err" </dev/null
  echo "$?" >"$CASE/status"
}
line() { grep -E "setting  AGENT_GUARD_$1( |$)" "$CASE/err"; }
# Release and Codex checks stay off in every case: they need the network.
OFFLINE="AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_CODEX_TRUST_CHECK=off"

doctor $OFFLINE
base_status=$(cat "$CASE/status")
expect "the section says hook environments may differ" 'grep -qF "hook environments" "$CASE/err"'
for mode in INFRA_FAILURE_MODE PROMPT_GUARD_MODE OUTPUT_REDACT DENY_READ_MODE PII_HOOK_MODE LOG_MODE; do
  expect "policy mode $mode is always listed, as the default when unset" 'line $mode | grep -qF "(default)"'
done
expect "an unset setting that is not a policy mode is not listed" '! line KEY_NAME_REDACT && ! line DENY_READ_PATHS'
expect "an explicit off is shown with its value" 'line RELEASE_CHECK | grep -qF " off" && line RELEASE_CHECK | grep -qF "differs from the default"'

doctor $OFFLINE AGENT_GUARD_OUTPUT_REDACT=off AGENT_GUARD_LOG_MODE=on AGENT_GUARD_SCAN_INPUT_MAX_BYTES=20971520 AGENT_GUARD_PII_SKIP=EMAIL,PHONE
expect "a weaker policy mode is shown and marked as differing" 'line OUTPUT_REDACT | grep -qF "off" && line OUTPUT_REDACT | grep -qF "differs from the default"'
expect "a value equal to the default is not marked" 'line LOG_MODE | grep -qF "on" && ! line LOG_MODE | grep -qF differs'
expect "a number is shown" 'line SCAN_INPUT_MAX_BYTES | grep -qF 20971520'
expect "a list of accepted words is shown" 'line PII_SKIP | grep -qF "EMAIL,PHONE"'
expect "doctor's status does not depend on the section" '[ "$(cat "$CASE/status")" = "$base_status" ]'

odd=zq9-unrecognized-Value
doctor $OFFLINE AGENT_GUARD_PROMPT_GUARD_MODE="$odd" AGENT_GUARD_KEY_NAME_REDACT="$odd" AGENT_GUARD_PII_SKIP="EMAIL,$odd" \
  AGENT_GUARD_SCAN_INPUT_MAX_BYTES="$odd" AGENT_GUARD_LOG_MODE=
expect "unrecognized values are marked" 'line PROMPT_GUARD_MODE | grep -qF unrecognized && line KEY_NAME_REDACT | grep -qF unrecognized \
  && line PII_SKIP | grep -qF unrecognized && line SCAN_INPUT_MAX_BYTES | grep -qF unrecognized'
expect "an empty value is shown as empty" 'line LOG_MODE | grep -qF empty'
expect "and an unrecognized value is never printed" '! grep -qF "$odd" "$CASE/err" && ! grep -qF "$odd" "$CASE/out"'

path_marker="$CASE/zq9-path-marker"
url_marker=https://zq9-url-marker.example.invalid/redact
doctor $OFFLINE AGENT_GUARD_DENY_READ_PATHS="$path_marker" AGENT_GUARD_PII_REDACT_URL="$url_marker" \
  AGENT_GUARD_GITLEAKS_HELPER="$path_marker" AGENT_GUARD_RUST_CORE_BIN="$path_marker" AGENT_GUARD_MASK_DENY_VALUES="$path_marker"
expect "a path or URL is shown only as set" 'line DENY_READ_PATHS | grep -qF " set" && line PII_REDACT_URL | grep -qF " set" \
  && line GITLEAKS_HELPER | grep -qF " set" && line RUST_CORE_BIN | grep -qF " set"'
expect "and never printed by the section" '! grep -F "setting  " "$CASE/err" | grep -qF -e zq9-path-marker -e zq9-url-marker'
doctor $OFFLINE AGENT_GUARD_GITLEAKS_HELPER=off
expect "a helper value that is not a path is shown as off" 'line GITLEAKS_HELPER | grep -qF " off"'

doctor $OFFLINE AGENT_GUARD_BIN_DIR="$CASE/links" AGENT_GUARD_GITLEAKS_CHECKSUMS_URL="$url_marker" AGENT_GUARD_REPO=zq9/fork \
  AGENT_GUARD_PII_HOOK_REQUEST=1
for name in BIN_DIR GITLEAKS_CHECKSUMS_URL REPO PII_HOOK_REQUEST; do
  expect "deprecated name $name is marked" 'line $name | grep -qF deprecated'
done
expect "and their values are not printed" '! grep -F "setting  " "$CASE/err" | grep -qF -e zq9 -e "$CASE/links"'

doctor $OFFLINE AGENT_GUARD_PROMPT_GUARD_MODE=block,warn AGENT_GUARD_SCAN_INPUT_MAX_BYTES=1 AGENT_GUARD_PII_TIMEOUT_SECONDS=0 \
  AGENT_GUARD_GITLEAKS_HELPER_MAX_RSS_MIB=5000
expect "two accepted words joined are not one accepted value" 'line PROMPT_GUARD_MODE | grep -qF unrecognized'
expect "numbers outside what the runtime accepts are marked" 'line SCAN_INPUT_MAX_BYTES | grep -qF unrecognized \
  && line PII_TIMEOUT_SECONDS | grep -qF unrecognized && line GITLEAKS_HELPER_MAX_RSS_MIB | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_PII_SKIP=EMAIL AGENT_GUARD_PII_PROVIDER=http
expect "a skip list that the provider does not use is marked" 'line PII_SKIP | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_PII_SKIP='EMAIL PHONE'
expect "a space-separated skip list is accepted, as at runtime" 'line PII_SKIP | grep -qF "EMAIL PHONE" && ! line PII_SKIP | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_PII_SKIP='*'
expect "a list value is not expanded as a pathname pattern" 'line PII_SKIP | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_KEY_NAME_REDACT=false
expect "an unrecognized value does not claim the default applies, since each setting treats one its own way" \
  'line KEY_NAME_REDACT | grep -qF unrecognized && ! line KEY_NAME_REDACT | grep -qF default && line KEY_NAME_REDACT | grep -qF docs/configuration.md'
doctor $OFFLINE AGENT_GUARD_LOG_MODE=off AGENT_GUARD_SCAN_CACHE=on
expect "with logging off the cache defaults to off, so an explicit on differs" 'line SCAN_CACHE | grep -qF "differs from the default: off"'
doctor $OFFLINE AGENT_GUARD_LOG_MODE=off AGENT_GUARD_SCAN_CACHE=off
expect "and an explicit off with logging off is the default" 'line SCAN_CACHE | grep -qF off && ! line SCAN_CACHE | grep -qF differs'
doctor $OFFLINE AGENT_GUARD_SCAN_INPUT_MAX_BYTES=000000000000000000000020971520 AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS=+120
expect "leading zeros are dropped, as at runtime" 'line SCAN_INPUT_MAX_BYTES | grep -qF " 20971520 " && ! line SCAN_INPUT_MAX_BYTES | grep -qF unrecognized'
expect "the helper reads a leading plus sign, as Go's Atoi does" 'line GITLEAKS_HELPER_IDLE_SECONDS | grep -qF " 120 " && ! line GITLEAKS_HELPER_IDLE_SECONDS | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_SCAN_INPUT_MAX_BYTES=+20971520
expect "but the shell parser of the scan limit does not" 'line SCAN_INPUT_MAX_BYTES | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_LOG_MODE=quiet AGENT_GUARD_SCAN_CACHE=off
expect "an unrecognized log mode turns the cache off whatever its setting, and the line says so" \
  'line SCAN_CACHE | grep -qF "no effect" && ! line SCAN_CACHE | grep -qF differs'
doctor $OFFLINE AGENT_GUARD_PII_PROVIDER=http AGENT_GUARD_PII_SKIP=' '
expect "a skip list with no words is accepted with any provider, as at runtime" 'line PII_SKIP >/dev/null && ! line PII_SKIP | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_PII_PROVIDER=zq9 AGENT_GUARD_PII_SKIP=EMAIL
expect "an unknown provider is left to the provider error, not blamed on the skip list" 'line PII_SKIP | grep -qF EMAIL && ! line PII_SKIP | grep -qF unrecognized'
doctor $OFFLINE AGENT_GUARD_PII_TIMEOUT_SECONDS=1000000000000000000
expect "the PII timeout takes any positive integer, without the scan limit's digit cap" 'line PII_TIMEOUT_SECONDS | grep -qF 1000000000000000000 && ! line PII_TIMEOUT_SECONDS | grep -qF unrecognized'
env $UNSET HOME="$CASE/home" AGENT_GUARD_GITLEAKS_BIN="$CASE/gl/gitleaks" $OFFLINE AGENT_GUARD_PROMPT_GUARD_MODE=warn \
  "$GUARD" doctor --help >"$CASE/out" 2>"$CASE/err" </dev/null
expect "doctor --help prints usage without the settings section" 'grep -qF "Usage:" "$CASE/err" && ! grep -qF "setting  " "$CASE/err"'
doctor $OFFLINE AGENT_GUARD_SESSION_ROLE=zq9-role-Value
expect "an unrecognized session role is listed only as unrecognized, and its value is never printed" \
  'line SESSION_ROLE | grep -qF unrecognized && ! grep -qF zq9-role "$CASE/err" && ! grep -qF zq9-role "$CASE/out"'
doctor $OFFLINE AGENT_GUARD_SESSION_ROLE=review
expect "the accepted review role is listed as is" 'line SESSION_ROLE | grep -qF " review"'

# P-5: the top-level usage lists every user-facing form, and no internal one.
"$GUARD" --help 2>"$CASE/usage"
expect "usage lists setup-shell --print-command-wrapping" 'grep -qF "setup-shell [--bash|--zsh|--rc FILE] --print-command-wrapping" "$CASE/usage"'
expect "usage does not list the internal filter-lockfile-hashes" '! grep -qF filter-lockfile-hashes "$CASE/usage"'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

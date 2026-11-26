#!/bin/sh
# O-4: hooks cap a remote PII request at 5 seconds. That flag is internal: the
# hook passes it to the adapter as an argument, not through the environment,
# so a caller of pii-filter cannot set it. During the deprecation period an
# outside AGENT_GUARD_PII_HOOK_REQUEST=1 still caps the request, with a warning
# that names the setting. A stand-in curl records the --max-time it was given.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/ag-pii-request.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; [ ! -s "$CASE/err" ] || sed 's/^/  stderr: /' "$CASE/err"; [ ! -s "$CASE/times" ] || sed 's/^/  max-time: /' "$CASE/times"; }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$CASE/bin" "$CASE/home"
cat >"$CASE/bin/curl" <<'STUB'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  [ "$1" = --max-time ] && { shift; printf '%s\n' "$1" >>"$AG_TEST_TIMES"; }
  shift
done
jq -c '{redacted_text: .text}'
STUB
chmod +x "$CASE/bin/curl"
export AG_TEST_TIMES="$CASE/times"
pii() { # settings... -> pii-filter on a fixed text
  : >"$CASE/times"
  printf 'plain text' | env -u AGENT_GUARD_PII_HOOK_REQUEST PATH="$CASE/bin:$PATH" HOME="$CASE/home" \
    AGENT_GUARD_LOG_MODE=off AGENT_GUARD_PII_PROVIDER=http AGENT_GUARD_PII_REDACT_URL=http://pii.example.invalid/redact \
    AGENT_GUARD_PII_TIMEOUT_SECONDS=30 "$@" "$GUARD" pii-filter >"$CASE/out" 2>"$CASE/err"
  echo "$?" >"$CASE/status"
}
warned() { grep -F AGENT_GUARD_PII_HOOK_REQUEST "$CASE/err" | grep -qF deprecated; }

pii
expect "control: pii-filter uses AGENT_GUARD_PII_TIMEOUT_SECONDS, without a warning" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ "$(cat "$CASE/out")" = "plain text" ] && [ "$(cat "$CASE/times")" = 30 ] && ! warned'
pii AGENT_GUARD_PII_HOOK_REQUEST=1
expect "deprecated: an outside AGENT_GUARD_PII_HOOK_REQUEST=1 still caps the request at 5 seconds, with a warning" \
  '[ "$(cat "$CASE/status")" = 0 ] && [ "$(cat "$CASE/times")" = 5 ] && warned'
pii AGENT_GUARD_PII_HOOK_REQUEST=0
expect "a value other than 1 changes nothing and is not warned about" '[ "$(cat "$CASE/times")" = 30 ] && ! warned'

# The hook caps its own request without any environment flag.
: >"$CASE/times"
jq -nc '{hook_event_name:"UserPromptSubmit",session_id:"pii-request-'"$$"'",prompt:"plain text"}' \
  | env -u AGENT_GUARD_PII_HOOK_REQUEST PATH="$CASE/bin:$PATH" HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" \
    AGENT_GUARD_LOG_MODE=off AGENT_GUARD_HOOK_HOST=claude AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" \
    AGENT_GUARD_PII_HOOK_MODE=block AGENT_GUARD_PII_PROVIDER=http AGENT_GUARD_PII_REDACT_URL=http://pii.example.invalid/redact \
    AGENT_GUARD_PII_TIMEOUT_SECONDS=30 AGENT_GUARD_WARNING_DIR="$CASE/warn" \
    "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
hook_status=$?
expect "a hook's PII request is capped at 5 seconds with no environment flag, and warns about nothing" \
  '[ "$hook_status" = 0 ] && [ -s "$CASE/times" ] && ! grep -qvx 5 "$CASE/times" && ! warned'
expect "the CLI no longer sets the flag through the environment" \
  '! grep -qF "AGENT_GUARD_PII_HOOK_REQUEST=1 pii_adapter_filter" "$GUARD"'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

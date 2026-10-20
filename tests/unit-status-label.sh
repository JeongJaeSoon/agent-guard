#!/bin/sh
# Pure status-label classification: literal expectations, production detector.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unit-status-label.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" secretish_env_values
. "$CASE/secretish_env_values.sh"
LABEL_SECRET=$(printf '%s%s' 'hunter2-' 'long-value')
DATED_SECRET=$(printf '2026-01-01-sk-live-%s' 'abc123XYZ')
pass=0 fail=0
while IFS='|' read -r id expected input; do
  case "$expected" in
    secret) input="$input $LABEL_SECRET"; printf '"%s"\n' "$LABEL_SECRET" >"$CASE/expected" ;;
    dated) input="$input $DATED_SECRET"; printf '"%s"\n' "$DATED_SECRET" >"$CASE/expected" ;;
    clean) : >"$CASE/expected" ;;
    *) exit 2 ;;
  esac
  # Literal RS/LF transport; these inputs contain neither RS nor US. Checking
  # all output bytes in json mode also rejects duplicate/truncated findings.
  printf '%s\036\n' "$input" >"$CASE/input"
  status=0
  secretish_env_values json <"$CASE/input" >"$CASE/actual" 2>"$CASE/error" || status=$?
  if [ "$status" -eq 0 ] && [ ! -s "$CASE/error" ] && cmp -s "$CASE/expected" "$CASE/actual"; then
    pass=$((pass+1)); printf 'ok - status-label %s\n' "$id"
  else
    fail=$((fail+1)); printf 'not ok - status-label %s (status %s)\n' "$id" "$status"
  fi
done <<'CASES'
error-password|secret|error: password:
warning-db|secret|warning: db_password:
uppercase-client|secret|WARNING: client_secret:
fatal-api|secret|fatal: api_key:
info-refresh|secret|info: refresh_token:
nested-error|secret|response: error: api_key:
log-prefix|secret|2026-08-02 10:00:00 ERROR: password:
not-found|clean|error: secret: not-found
path|clean|warning: private_key: /path/to/configured/key
timestamp-local|clean|error: token: 2026-08-30T10:00:00
clock|clean|fatal: password: 10:00:00
sentence-case|clean|warning: api_key: Missing
ordinary-word|clean|info: credential: unauthenticated
quoted-length|clean|error: password: "must be at least 8 characters"
quoted-expiry|clean|warning: token: "expires in 3600 seconds"
quoted-profile|clean|error: api_key: "not found in profile 2"
quoted-rotation|clean|fatal: secret: "rotate within 90 days"
quoted-title|clean|info: credential: "Check Your Settings Page"
date-prefix-secret|dated|error: api_key:
date|clean|error: token: 2026-08-30
timestamp-z|clean|error: token: 2026-08-30T10:00:00Z
timestamp-offset|clean|error: token: 2026-08-30T10:00:00.123+09:00
CASES
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

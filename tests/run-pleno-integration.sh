#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN="$ROOT/plugins/agent-guard/bin/agent-guard"

if [ "${AGENT_GUARD_PII_INTEGRATION_PLENO:-}" != 1 ]; then
  printf '%s\n' 'set AGENT_GUARD_PII_INTEGRATION_PLENO=1 to run real pleno endpoint tests' >&2
  exit 2
fi

if [ -z "${AGENT_GUARD_PII_REDACT_URL:-}" ]; then
  printf '%s\n' 'AGENT_GUARD_PII_REDACT_URL is required' >&2
  exit 2
fi

run_pleno() {
  language=$1
  text=$2
  printf '%s' "$text" \
    | AGENT_GUARD_PII_PROVIDER=pleno \
      AGENT_GUARD_PII_LANGUAGE="$language" \
      AGENT_GUARD_PII_TIMEOUT_SECONDS="${AGENT_GUARD_PII_TIMEOUT_SECONDS:-90}" \
      "$BIN" pii-filter
}

english='Contact Alice Smith at alice@example.com or +1 415-555-0199.'
english_out=$(run_pleno en "$english") || exit 1
case "$english_out" in
  *alice@example.com*|*415-555-0199*)
    printf '%s\n' 'English integration failed: identifiers remained in output' >&2
    exit 1
    ;;
esac
[ "$english_out" != "$english" ] || {
  printf '%s\n' 'English integration failed: response was unchanged' >&2
  exit 1
}

japanese='山田太郎のメールはtaro.yamada@example.jp、電話は090-1234-5678です。'
japanese_out=$(run_pleno ja "$japanese") || exit 1
case "$japanese_out" in
  *taro.yamada@example.jp*|*090-1234-5678*)
    printf '%s\n' 'Japanese integration failed: identifiers remained in output' >&2
    exit 1
    ;;
esac
[ "$japanese_out" != "$japanese" ] || {
  printf '%s\n' 'Japanese integration failed: response was unchanged' >&2
  exit 1
}

clean='The sky is blue.'
clean_out=$(run_pleno en "$clean") || exit 1
[ "$clean_out" = "$clean" ] || {
  printf '%s\n' 'Clean-text integration failed: response changed unexpectedly' >&2
  exit 1
}

AGENT_GUARD_PII_PROVIDER=pleno \
AGENT_GUARD_PII_LANGUAGE=en \
AGENT_GUARD_PII_TIMEOUT_SECONDS="${AGENT_GUARD_PII_TIMEOUT_SECONDS:-90}" \
  "$BIN" pii-filter --check >/dev/null || exit 1

printf '%s\n' 'pleno integration ok: English, Japanese, clean text, and provider check'

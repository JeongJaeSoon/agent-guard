#!/bin/sh
# Byte expectations are independent of the decoder and cover both span/escape paths.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
awk '
  /^redact_plaintext_framed\(\) \{$/ { active = 1; found++ }
  active && /^# Literal \(non-regex\) replacement/ { active = 0 }
  active { print }
  END { if (found != 1) exit 1 }
' "$ROOT/plugins/agent-guard/bin/agent-guard" >"$CASE/driver"
cat >>"$CASE/driver" <<'DRIVER'
text=$(cat "$1")
redact_plaintext_framed "$text" "$2"
DRIVER
count=0
check() {
  sh "$CASE/driver" "$CASE/input" "$CASE/secrets" >"$CASE/actual"
  cmp "$CASE/expected" "$CASE/actual"
  count=$((count + 1))
  printf 'ok - plaintext frame bytes: %s\n' "$1"
}
awk 'BEGIN { for (i=0;i<30000;i++) printf "a"; printf "\n"; for (i=0;i<30000;i++) printf "b" }' >"$CASE/long"
{ printf " API_KEY='"; cat "$CASE/long"; printf "'"; } >"$CASE/input"
{ printf S; cat "$CASE/long"; printf '\036\n'; } >"$CASE/secrets"
printf " API_KEY='[REDACTED]'" >"$CASE/expected"
check 'long multiline literal'

printf 'alpha beta visible' >"$CASE/input"
printf 'Salpha\036Sbeta\036\n' >"$CASE/secrets"
printf '[REDACTED] [REDACTED] visible' >"$CASE/expected"
check 'multiple records on one line'

printf 'head\036tail visible' >"$CASE/input"
printf 'Shead\037\036tail\036\n' >"$CASE/secrets"
printf '[REDACTED] visible' >"$CASE/expected"
check 'escaped record separator'

printf 'head\037tail visible' >"$CASE/input"
printf 'Shead\037\037tail\036\n' >"$CASE/secrets"
check 'escaped unit separator'

printf 'head\037\ntail visible' >"$CASE/input"
printf 'Shead\037\037\ntail\036\n' >"$CASE/secrets"
check 'escaped line followed by unescaped span'

printf 'key=valueZ key=value; key=value' >"$CASE/input"
printf 'Lkey=value\036Rkey=[REDACTED]\036\n' >"$CASE/secrets"
printf 'key=valueZ key=[REDACTED]; key=[REDACTED]' >"$CASE/expected"
check 'contextual suffix boundary'

printf 'abcd abc visible' >"$CASE/input"
printf 'Sabc\036Sabcd\036\n' >"$CASE/secrets"
printf '[REDACTED] [REDACTED] visible' >"$CASE/expected"
check 'longest literal first'

printf '\376 clean \377 secret' >"$CASE/input"
printf 'S\377\036\n' >"$CASE/secrets"
printf '\376 clean [REDACTED] secret' >"$CASE/expected"
check 'unrelated non-UTF-8 byte preserved'

printf 'foo visible' >"$CASE/input"
printf '\036\nSfoo\036\036\n\n' >"$CASE/secrets"
printf '[REDACTED] visible' >"$CASE/expected"
check 'empty and trailing records'

printf 'visible' >"$CASE/input"
printf '\n' >"$CASE/secrets"
printf 'visible' >"$CASE/expected"
check 'empty line creates no mapping'
printf 'passed: %s plaintext byte contracts\n' "$count"

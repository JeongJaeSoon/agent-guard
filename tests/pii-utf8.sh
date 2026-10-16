#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-pii-utf8.XXXXXX") || exit 1
trap 'rm -rf "$CASE_DIR"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$CASE_DIR/runtime" "$CASE_DIR/stub" || exit 1
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_PROVIDER=regex AGENT_GUARD_PII_HOOK_MODE=mask
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
export TMPDIR="$CASE_DIR/runtime"
AGENT_GUARD_PII_SKIP=
export AGENT_GUARD_PII_SKIP
ORIGINAL_PATH=$PATH
REAL_AWK=$(command -v awk) || exit 1
export REAL_AWK
passed=0
failed=0

check() {
  if "$@"; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf 'not ok - %s\n' "$case_name"
    cat "$CASE_DIR/err" >&2
  fi
}

# Exercise a real UTF-8 locale when available, without installing any locale.
utf8_locale=$(locale -a 2>/dev/null | LC_ALL=C grep -Ei '^(en_US[.]utf-?8|C[.]utf-?8|ko_KR[.]utf-?8)$' | head -n 1)
if [ -z "$utf8_locale" ]; then
  if [ "$(uname -s)" = Darwin ]; then
    printf '%s\n' 'not ok - macOS regression coverage requires a UTF-8 locale' >&2
    exit 1
  fi
  printf '%s\n' 'UTF-8 locale unavailable; UTF-8-specific PII tests skipped'
fi

for test_locale in C ${utf8_locale:+"$utf8_locale"}; do
  for kind in ascii latin japanese korean emoji mixed; do
    case "$kind" in
      ascii) glyph=a; width=1 ;;
      latin) glyph='é'; width=2 ;;
      japanese) glyph='あ'; width=3 ;;
      korean) glyph='한'; width=3 ;;
      emoji) glyph='🙂'; width=4 ;;
      mixed) glyph='éあ한🙂'; width=12 ;;
    esac
    for bytes in 447 448 449 510 511 512 513 514 1025; do
      LC_ALL=C awk -v n="$bytes" -v width="$width" -v glyph="$glyph" 'BEGIN {
        for (i = 0; i < n % width; i++) printf "a"
        for (i = 0; i < int(n / width); i++) printf "%s", glyph
      }' >"$CASE_DIR/input" || exit 1
      LC_ALL="$test_locale" "$GUARD" pii-filter <"$CASE_DIR/input" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
      status=$?
      case_name="clean $kind $bytes bytes in $test_locale"
      check test "$status" -eq 0
      check test ! -s "$CASE_DIR/err"
      check cmp -s "$CASE_DIR/input" "$CASE_DIR/out"
    done
  done

  # PII straddles the 512-byte boundary; unchanged CJK surrounds its marker.
  LC_ALL=C awk 'BEGIN { for (i = 0; i < 170; i++) printf "한" }' >"$CASE_DIR/prefix" || exit 1
  for sample in '4111111111111111:CREDIT_CARD' '378282246310005:CREDIT_CARD' \
      '4000000000000000006:CREDIT_CARD' '123-45-6789:SSN' \
      '900101-1234567:KR_RRN' '010-1234-5678:PHONE' '8.8.8.8:IP_ADDRESS'; do
    value=${sample%:*}; marker=${sample#*:}
    { cat "$CASE_DIR/prefix" || exit 1; printf ' %s あ🙂' "$value"; } >"$CASE_DIR/input" || exit 1
    { cat "$CASE_DIR/prefix" || exit 1; printf ' [PII:%s] あ🙂' "$marker"; } >"$CASE_DIR/expected" || exit 1
    LC_ALL="$test_locale" "$GUARD" pii-filter <"$CASE_DIR/input" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
    status=$?
    case_name="boundary $marker in $test_locale"
    check test "$status" -eq 0
    check test ! -s "$CASE_DIR/err"
    check cmp -s "$CASE_DIR/expected" "$CASE_DIR/out"
  done

  # Keep the caller's locale-sensitive email classification. awk variants
  # differ here, so the reference is a whole-record match with the same awk.
  printf 'é@example.com é01012345678@example.com\r\n\n' >"$CASE_DIR/input" || exit 1
  LC_ALL="$test_locale" "$REAL_AWK" '
    BEGIN { email = "[[:alnum:]_%+.-]+@[[:alnum:].-]+[.][[:alpha:]][[:alpha:]][[:alpha:]]*" }
    { if (NR > 1) printf "%s", ORS; gsub(email, "[PII:EMAIL]"); printf "%s", $0 }
  ' <"$CASE_DIR/input" >"$CASE_DIR/expected" || exit 1
  LC_ALL="$test_locale" "$GUARD" pii-filter <"$CASE_DIR/input" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
  status=$?
  case_name="caller-locale email and trailing empty record in $test_locale"
  check test "$status" -eq 0
  check cmp -s "$CASE_DIR/expected" "$CASE_DIR/out"

  for fixture in empty blank multiline; do
    case "$fixture" in
      empty) : >"$CASE_DIR/input"; : >"$CASE_DIR/expected" ;;
      blank) printf '\n' >"$CASE_DIR/input"; : >"$CASE_DIR/expected" ;;
      multiline) printf '한글\nあ🙂' >"$CASE_DIR/input"; cp "$CASE_DIR/input" "$CASE_DIR/expected" ;;
    esac || exit 1
    LC_ALL="$test_locale" "$GUARD" pii-filter <"$CASE_DIR/input" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
    status=$?
    case_name="record framing $fixture in $test_locale"
    check test "$status" -eq 0
    check cmp -s "$CASE_DIR/expected" "$CASE_DIR/out"
  done

  { cat "$CASE_DIR/prefix" || exit 1; printf ' 4111111111111112 14111111111111111 é@example.com'; } >"$CASE_DIR/input" || exit 1
  LC_ALL="$test_locale" AGENT_GUARD_PII_SKIP=EMAIL "$GUARD" pii-filter <"$CASE_DIR/input" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
  status=$?
  case_name="long CJK negative controls and EMAIL skip in $test_locale"
  check test "$status" -eq 0
  check cmp -s "$CASE_DIR/input" "$CASE_DIR/out"

  for host in claude codex; do
    for pii in clean ssn; do
      text=$(cat "$CASE_DIR/prefix") || exit 1
      text="${text}あ한"
      expected_status=0
      if [ "$pii" = ssn ]; then text="$text 123-45-6789"; expected_status=2; fi
      jq -nc --arg content "$text" '{tool_name:"mcp__fixture__create_file",tool_input:{content:$content}}' >"$CASE_DIR/event" || exit 1
      LC_ALL="$test_locale" AGENT_GUARD_HOOK_HOST="$host" "$GUARD" hook-pre-tool <"$CASE_DIR/event" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
      status=$?
      case_name="UTF-8 $host input gate $pii in $test_locale"
      check test "$status" -eq "$expected_status"
      if [ "$pii" = ssn ]; then check grep -q 'high-sensitivity PII' "$CASE_DIR/err"; fi
    done
  done
done

# Every intermediate failure must retain its status and expose no partial text.
cat >"$CASE_DIR/stub/awk" <<'EOF' || exit 1
#!/bin/sh
for arg do
  case "$PII_FAIL_STAGE:$arg" in
    first:STAGE=first|last:STAGE=last|email:*'email = '*)
      printf '%s' 'PARTIAL_SYNTHETIC_OUTPUT'
      exit 7
      ;;
  esac
done
exec "$REAL_AWK" "$@"
EOF
chmod +x "$CASE_DIR/stub/awk" || exit 1
for phase in first email last; do
  printf '%s' clean | PII_FAIL_STAGE="$phase" PATH="$CASE_DIR/stub:$ORIGINAL_PATH" \
    "$GUARD" pii-filter >"$CASE_DIR/out" 2>"$CASE_DIR/err"
  status=$?
  case_name="buffered $phase failure"
  check test "$status" -eq 7
  check test ! -s "$CASE_DIR/out"
done
case_name='PII temporary workspaces are removed'
leftovers=$(find "$CASE_DIR/runtime" -type d -name 'pii.*' -print) || exit 1
check test -z "$leftovers"
printf 'PII UTF-8 assertions: %s passed, %s failed\n' "$passed" "$failed"
test "$failed" -eq 0

#!/bin/sh
# Every assignment on a line is a candidate on every awk. The fixture holds
# lines where mawk 1.3.4 match() skipped the leftmost assignment, with the
# values and masked output that gawk and busybox awk already produced.
#
# AGENT_GUARD_TEST_REQUIRE_AWKS names implementations (mawk gawk busybox) that
# must be installed. A missing one fails instead of being skipped, so a run
# that could not compare them is not reported as a clean comparison.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
CLI=${AGENT_GUARD_TEST_CLI:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
FIXTURE_SOURCE="$ROOT/tests/fixtures/assignment-leftmost.json"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-assignment-leftmost.XXXXXX")
trap 'rm -rf "$CASE"' 0
sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE" secretish_env_values
. "$CASE/secretish_env_values.sh"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
BASE_PATH=$PATH
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

# %R% becomes a random letter-and-digit run each test, so the fixture holds no
# literal that reads as a quoted password.
rnd=$(od -An -N8 -tu1 /dev/urandom | awk '{ printf "q7"; for (i = 1; i <= NF; i++) printf "%c", 97 + $i % 26 }')
FIXTURE="$CASE/fixture.json"
jq --arg r "$rnd" 'map(.input |= gsub("%R%"; $r) | .values |= map(gsub("%R%"; $r)))' \
  "$FIXTURE_SOURCE" >"$FIXTURE"
count=$(jq 'length' "$FIXTURE")
[ "$count" -gt 0 ]
i=0
while [ "$i" -lt "$count" ]; do
  # Literal RS/LF transport; no fixture input contains RS, US, or a newline.
  jq -j --argjson i "$i" '.[$i].input, "\u001e\n"' "$FIXTURE" >"$CASE/framed.$i"
  jq -r --argjson i "$i" '.[$i].values[] | tojson' "$FIXTURE" >"$CASE/values.$i"
  jq -c --argjson i "$i" '.[$i] | {tool_name:"Bash",tool_input:{command:"run"},tool_response:{stdout:.input,stderr:""}}' \
    "$FIXTURE" >"$CASE/hook.$i"
  jq -c --argjson i "$i" '.[$i] | {hookSpecificOutput:{hookEventName:"PostToolUse",updatedToolOutput:{stdout:.masked,stderr:""}}}' \
    "$FIXTURE" >"$CASE/claude.$i"
  jq -c --argjson i "$i" '.[$i] | {decision:"block",reason:"Agent Guard blocked the original tool output because it contained sensitive values; use the sanitized replacement in additionalContext.",hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("Agent Guard sanitized tool output:\n" + ({stdout:.masked,stderr:""} | tojson))}}' \
    "$FIXTURE" >"$CASE/codex.$i"
  jq -r --argjson i "$i" '.[$i].id' "$FIXTURE" >"$CASE/id.$i"
  i=$((i + 1))
done

check_awk() {
  impl=$1
  PATH="$CASE/bin-$impl:$BASE_PATH"
  export PATH
  export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/private-$impl"
  mkdir "$CASE/private-$impl"
  i=0
  while [ "$i" -lt "$count" ]; do
    id=$(cat "$CASE/id.$i")
    status=0
    secretish_env_values json <"$CASE/framed.$i" >"$CASE/actual" 2>"$CASE/error" || status=$?
    if [ "$status" -eq 0 ] && [ ! -s "$CASE/error" ] && cmp -s "$CASE/values.$i" "$CASE/actual"; then
      ok "$impl values $id"
    else
      not_ok "$impl values $id (status $status)"
      # Fixture values are synthetic, so the difference is safe to print.
      sed 's/^/# expected: /' "$CASE/values.$i"
      sed 's/^/# actual: /' "$CASE/actual"
    fi
    for host in claude codex; do
      status=0
      AGENT_GUARD_HOOK_HOST="$host" "$CLI" hook-post-tool <"$CASE/hook.$i" >"$CASE/actual" 2>"$CASE/error" || status=$?
      if [ "$status" -eq 0 ] && cmp -s "$CASE/$host.$i" "$CASE/actual"; then
        ok "$impl $host hook $id"
      else
        not_ok "$impl $host hook $id (status $status)"
      fi
    done
    i=$((i + 1))
  done
  PATH=$BASE_PATH
  export PATH
}

# The awk already on PATH (BWK awk on macOS) is always compared.
mkdir "$CASE/bin-default"
cp "$ROOT/tests/fixtures/mock-gitleaks" "$CASE/bin-default/gitleaks"
chmod +x "$CASE/bin-default/gitleaks"
check_awk default

for impl in mawk gawk busybox; do
  if ! command -v "$impl" >/dev/null 2>&1; then
    case " ${AGENT_GUARD_TEST_REQUIRE_AWKS:-} " in
      *" $impl "*) not_ok "$impl is required but not installed" ;;
      *) printf 'ok - %s not installed # SKIP\n' "$impl" ;;
    esac
    continue
  fi
  mkdir "$CASE/bin-$impl"
  cp "$ROOT/tests/fixtures/mock-gitleaks" "$CASE/bin-$impl/gitleaks"
  case "$impl" in
    busybox) printf '#!/bin/sh\nexec busybox awk "$@"\n' >"$CASE/bin-$impl/awk" ;;
    *) printf '#!/bin/sh\nexec %s "$@"\n' "$impl" >"$CASE/bin-$impl/awk" ;;
  esac
  chmod +x "$CASE/bin-$impl/gitleaks" "$CASE/bin-$impl/awk"
  check_awk "$impl"
done
printf 'passed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

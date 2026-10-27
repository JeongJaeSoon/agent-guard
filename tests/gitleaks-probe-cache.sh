#!/bin/sh
# The gitleaks readiness verdict is reused across hook processes only for the
# same executable, only while fresh, and never in place of the scan itself.
# A counting wrapper records every gitleaks subcommand the real CLI starts.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-probe-cache.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/bin" "$CASE/home"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=on
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_PROMPT_GUARD_MODE=block AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks"
export MOCK_CALLS="$CASE/calls" MOCK_REAL="$ROOT/tests/fixtures/mock-gitleaks"
unset AI_AGENT
CACHE="$XDG_STATE_HOME/agent-guard/gitleaks-probe"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

# $1 is the version line; the same length keeps an in-place rewrite size-equal.
write_mock() {
  printf '#!/bin/sh\nprintf "%%s\\n" "${1:-}" >>"$MOCK_CALLS"\n[ "${1:-}" != version ] || { echo %s; exit 0; }\nexec "$MOCK_REAL" "$@"\n' \
    "$1" >"$CASE/bin/gitleaks.new"
  cat "$CASE/bin/gitleaks.new" >"$CASE/bin/gitleaks"
  rm -f "$CASE/bin/gitleaks.new"
  chmod +x "$CASE/bin/gitleaks"
}
calls() { grep -cx "$1" "$MOCK_CALLS" 2>/dev/null || :; }
reset() { rm -rf "$XDG_STATE_HOME" "$AGENT_GUARD_WARNING_DIR"; : >"$MOCK_CALLS"; }
run_seq=0
prompt() {
  run_seq=$((run_seq + 1))
  jq -nc --arg p "$1" --arg s "probe-cache-$run_seq" '{session_id:$s,prompt:$p}' \
    | AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
}
marker="AGENT_GUARD_TEST_""SECRET"
benign='please refactor the parser and add tests'

write_mock 8.30.1
reset
prompt "$benign"; s1=$?
prompt "$benign"; s2=$?
check 'benign prompts pass on a cold and a warm cache' test "$s1:$s2" = 0:0
check 'the second process reuses the ready verdict' test "$(calls version)" = 1
check 'every process still runs its own scan' test "$(calls stdin)" = 2
check 'the cache file is private' test -f "$CACHE" -a ! -L "$CACHE"
case "$(uname -s)" in
  Darwin) mode=$(stat -f '%Lp' "$CACHE") ;;
  *) mode=$(stat -c '%a' "$CACHE") ;;
esac
check 'the cache file mode is 600' test "$mode" = 600

prompt "please look at $marker"; s=$?
check 'a warm cache still blocks a secret prompt' test "$s" -eq 2
check 'the blocked prompt was scanned, not answered from the cache' test "$(calls stdin)" = 3
check 'the block did not reprobe' test "$(calls version)" = 1

write_mock 8.30.2
prompt "$benign"
check 'rewriting the binary in place forces a new probe' test "$(calls version)" = 2

reset
write_mock 8.29.0
prompt "$benign"; s1=$?
prompt "$benign"; s2=$?
check 'an unsupported gitleaks degrades open' test "$s1:$s2" = 0:0
check 'an unsupported gitleaks is probed by every process' test "$(calls version)" = 2
check 'an unsupported verdict is never cached' test ! -e "$CACHE"
check 'a degraded hook does not scan' test "$(calls stdin)" = 0

reset
write_mock 8.30.1
prompt "$benign"
{ IFS= read -r key && IFS= read -r stamp && IFS= read -r version; } <"$CACHE"
check 'the cache records the probed version' test "$version" = 8.30.1
printf '%s\n%s\n%s\n' "$key" 1 "$version" >"$CACHE"
prompt "$benign"
check 'an expired verdict forces a new probe' test "$(calls version)" = 2
printf '%s\n%s\n%s\n' "$key" "$stamp" 8.29.0 >"$CACHE"
prompt "$benign"
check 'a cached version below the minimum forces a new probe' test "$(calls version)" = 3
printf 'not a cache\n' >"$CACHE"
prompt "$benign"; s=$?
check 'a corrupt cache file forces a new probe' test "$s:$(calls version)" = 0:4
check 'a corrupt cache file is replaced by a valid one' test "$(sed -n 3p "$CACHE")" = 8.30.1

printf 'outside\n' >"$CASE/outside"
rm -f "$CACHE"
ln -s "$CASE/outside" "$CACHE"
before=$(calls version)
prompt "$benign"
check 'a symlinked cache file is not trusted' test "$(calls version)" -eq $((before + 1))
check 'a symlinked cache file target is left untouched' test "$(cat "$CASE/outside")" = outside

reset
AGENT_GUARD_LOG_MODE=off prompt "$benign"
AGENT_GUARD_LOG_MODE=off prompt "$benign"
check 'logging off probes in every process' test "$(calls version)" = 2
check 'logging off creates no state directory' test ! -e "$XDG_STATE_HOME"

reset
prompt "$benign"
"$GUARD" check >"$CASE/out" 2>"$CASE/err"
check 'the check command probes despite a warm cache' test "$(calls version)" = 2

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]

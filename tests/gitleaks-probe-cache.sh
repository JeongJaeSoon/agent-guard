#!/bin/sh
# The gitleaks readiness verdict is reused across hook processes only for the
# same native executable, only while fresh, and never in place of the scan.
# Script shims are never cached; a counting script proves that. Reuse itself
# needs a native gitleaks, observed through the cache stamp a reprobe rewrites.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
# run.sh puts its mock gitleaks first on PATH, so it passes the real one in.
REAL_GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || :)}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-probe-cache.XXXXXX")
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
mkdir -p "$CASE/bin" "$CASE/home" "$CASE/multi" "$CASE/real"
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

# $1 is the version a counting script shim reports.
write_shim() {
  printf '#!/bin/sh\nprintf "%%s\\n" "${1:-}" >>"$MOCK_CALLS"\n[ "${1:-}" != version ] || { echo %s; exit 0; }\nexec "$MOCK_REAL" "$@"\n' \
    "$1" >"$2"
  chmod +x "$2"
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

write_shim 8.30.1 "$CASE/bin/gitleaks"
reset
prompt "$benign"; s1=$?
prompt "$benign"; s2=$?
check 'benign prompts pass through a script shim' test "$s1:$s2" = 0:0
check 'a script shim is probed by every process' test "$(calls version)" = 2
check 'a script shim verdict is never cached' test ! -e "$CACHE"
check 'every process runs its own scan' test "$(calls stdin)" = 2
prompt "please look at $marker"; s=$?
check 'a script shim still blocks a secret prompt' test "$s" -eq 2

# A mise-style link resolves to a multiplexer that is not named gitleaks.
rm -f "$CASE/bin/gitleaks"
write_shim 8.30.1 "$CASE/multi/mise"
ln -s "$CASE/multi/mise" "$CASE/bin/gitleaks"
reset
prompt "$benign"
prompt "$benign"
check 'a link to a differently named multiplexer is never cached' \
  test "$(calls version):$(test -e "$CACHE" && echo cached)" = 2:

rm -f "$CASE/bin/gitleaks"
write_shim 8.29.0 "$CASE/bin/gitleaks"
reset
prompt "$benign"; s=$?
check 'an unsupported gitleaks degrades open without a scan' \
  test "$s:$(calls stdin):$(test -e "$CACHE" && echo cached)" = 0:0:

reset
# An assignment before a function call persists in POSIX sh; keep it local.
(export AGENT_GUARD_LOG_MODE=off; prompt "$benign")
check 'logging off creates no state directory' test ! -e "$XDG_STATE_HOME"

real_head=
[ -z "$REAL_GITLEAKS" ] || { IFS= read -r real_head <"$REAL_GITLEAKS"; } 2>/dev/null || :
if [ -z "$REAL_GITLEAKS" ] || ! "$REAL_GITLEAKS" version >/dev/null 2>&1 \
    || case "$real_head" in '#!'*) true ;; *) false ;; esac; then
  # Linux CI installs the real scanner; skipping there would hide every reuse check.
  if [ "${CI:-}" = true ] && [ "$(uname -s)" = Linux ]; then
    bad 'real gitleaks is required for native cache reuse checks on Linux CI'
  else
    printf '# real gitleaks not available; skipped native cache reuse checks\n'
  fi
else
  rm -f "$CASE/bin/gitleaks"
  cp "$REAL_GITLEAKS" "$CASE/real/gitleaks"
  ln -s ../real/gitleaks "$CASE/bin/gitleaks"
  token="gh""p_$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"
  # Age the stamp a little: a hit leaves it, a reprobe writes the current time.
  age_stamp() {
    { IFS= read -r key && IFS= read -r stamp && IFS= read -r version; } <"$CACHE"
    aged=$((stamp - 5))
    printf '%s\n%s\n%s\n' "$key" "$aged" "$version" >"$CACHE"
  }
  stamp_of() { sed -n 2p "$CACHE"; }
  reset
  prompt "$benign"; s=$?
  check 'a native gitleaks behind a link passes a benign prompt' test "$s" -eq 0
  check 'a native gitleaks verdict is cached' test -f "$CACHE" -a ! -L "$CACHE"
  case "$(uname -s)" in
    Darwin) mode=$(stat -f '%Lp' "$CACHE") ;;
    *) mode=$(stat -c '%a' "$CACHE") ;;
  esac
  check 'the cache file mode is 600' test "$mode" = 600
  check 'the cache records the probed version' \
    test "$(sed -n 3p "$CACHE")" = "$("$REAL_GITLEAKS" version | sed 's/^v//')"
  age_stamp
  prompt "$benign"
  check 'the next process reuses the verdict' test "$(stamp_of)" = "$aged"
  prompt "deploy with $token now"; s=$?
  check 'a warm cache still blocks a secret prompt' test "$s" -eq 2
  check 'the blocked prompt reused the verdict' test "$(stamp_of)" = "$aged"

  cp "$REAL_GITLEAKS" "$CASE/real/gitleaks"
  prompt "$benign"
  check 'rewriting the binary forces a new probe' test "$(stamp_of)" != "$aged"

  age_stamp
  printf '%s\n%s\n%s\n' "$key" "0$aged" "$version" >"$CACHE"
  prompt "deploy with $token now"; s=$?
  check 'a leading-zero stamp reprobes and still blocks' \
    test "$s:$(stamp_of)" != "2:0$aged" -a "$s" -eq 2
  age_stamp
  printf '%s\n%s\n%s\n' "$key" 1 "$version" >"$CACHE"
  prompt "$benign"
  check 'an expired verdict forces a new probe' test "$(stamp_of)" != 1
  age_stamp
  printf '%s\n%s\n%s\n' "$key" "$aged" 8.29.0 >"$CACHE"
  prompt "$benign"
  check 'a cached version below the minimum forces a new probe' test "$(stamp_of)" != "$aged"
  printf 'not a cache\n' >"$CACHE"
  prompt "$benign"; s=$?
  check 'a corrupt cache file is replaced after a new probe' \
    test "$s:$(sed -n 3p "$CACHE")" = "0:$version"

  printf 'outside\n' >"$CASE/outside"
  rm -f "$CACHE"
  ln -s "$CASE/outside" "$CACHE"
  prompt "$benign"
  check 'a symlinked cache file is replaced, not followed' \
    test ! -L "$CACHE" -a "$(cat "$CASE/outside")" = outside

  age_stamp
  printf '%s\n%s\n%s\n' "$key" "$aged" 8.99.9 >"$CACHE"
  "$GUARD" check >"$CASE/out" 2>"$CASE/err"
  check 'the check command probes instead of reading the cache' \
    test "$(grep -c 8.99.9 "$CASE/out" "$CASE/err" | awk -F: '{s+=$2} END{print s}')" = 0
fi

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]

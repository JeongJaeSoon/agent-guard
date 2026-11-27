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
# Exit before the cleanup trap exists: an empty CASE would make `cd -- ""`
# resolve to the current directory, which the trap then removes.
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-probe-cache.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
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

  # A machine-wide stall holds the version probe past its deadline, and a
  # retry lands in the same stall (#617). An expired verdict for this same
  # executable then stands in, because the scan that follows is its own proof.
  # The launcher stub stalls or fails on a flag, so the binary under test stays
  # the native one the cache identified.
  mkdir -p "$CASE/stall-bin"
  printf '#!/bin/sh\nprintf "probe\\n" >>"$PROBE_LOG"\n[ ! -e "$FAIL_FLAG" ] || exit 1\n[ ! -e "$STALL_FLAG" ] || exec sleep 6\nexec "$@"\n' \
    >"$CASE/stall-bin/setsid"
  chmod +x "$CASE/stall-bin/setsid"
  export PROBE_LOG="$CASE/probes" STALL_FLAG="$CASE/stall" FAIL_FLAG="$CASE/fail"
  # $1 is the prompt, $2 the infrastructure policy (open when omitted).
  stalled() {
    run_seq=$((run_seq + 1))
    : >"$PROBE_LOG"
    jq -nc --arg p "$1" --arg s "probe-cache-$run_seq" '{session_id:$s,prompt:$p}' \
      | PATH="$CASE/stall-bin:$PATH" AGENT_GUARD_HOOK_HOST=claude \
        AGENT_GUARD_INFRA_FAILURE_MODE="${2:-open}" \
        "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err"
  }
  probes() { grep -c probe "$PROBE_LOG" 2>/dev/null || :; }
  # $1 is how long ago the verdict was stored (just past the 600s TTL when
  # omitted), $2 the version it records.
  expire_stamp() {
    { IFS= read -r key && IFS= read -r stamp && IFS= read -r version; } <"$CACHE"
    expired=$(($(date +%s) - ${1:-700}))
    printf '%s\n%s\n%s\n' "$key" "$expired" "${2:-$version}" >"$CACHE"
  }
  noticed() { if cat "$CASE/out" "$CASE/err" | grep -q "$1"; then echo yes; else echo no; fi; }
  : >"$STALL_FLAG"
  stalled "deploy with $token now"; s=$?
  check 'a fresh verdict needs no probe while the machine stalls' \
    test "$s:$(probes)" = 2:0
  expire_stamp
  stalled "deploy with $token now"; s=$?
  check 'an expired verdict for the same executable stands in for a timed-out probe' \
    test "$s:$(noticed DEGRADED)" = 2:no
  check 'the stand-in costs one probe deadline, not a retry' test "$(probes)" = 1
  check 'the stand-in is not stored as a fresh verdict' test "$(stamp_of)" = "$expired"
  stalled "$benign"; s=$?
  check 'a benign prompt passes through the stand-in without a degraded notice' \
    test "$s:$(noticed DEGRADED)" = 0:no
  stalled "$benign" closed; s=$?
  check 'the closed policy does not block a scan the stand-in let run' \
    test "$s:$(noticed DEGRADED)" = 0:no
  # Controls: the stand-in is only for a timeout, the same file and a
  # supported version. Each of these must still report the scanner as down.
  expire_stamp 700 8.29.0
  stalled "deploy with $token now"; s=$?
  check 'an expired verdict below the minimum version does not stand in' \
    test "$s:$(probes):$(noticed 'Scanner readiness: timeout[.]')" = 0:2:yes
  # A gitleaks that hangs for good must be reported again, not stood in for.
  expire_stamp 1300 "$("$REAL_GITLEAKS" version | sed 's/^v//')"
  stalled "deploy with $token now"; s=$?
  check 'a verdict expired for more than one TTL does not stand in' \
    test "$s:$(noticed 'Scanner readiness: timeout[.]')" = 0:yes
  expire_stamp
  cp "$REAL_GITLEAKS" "$CASE/real/gitleaks"
  stalled "deploy with $token now"; s=$?
  check 'an expired verdict for a rewritten executable does not stand in' \
    test "$s:$(noticed 'Scanner readiness: timeout[.]')" = 0:yes
  rm -f "$STALL_FLAG"
  prompt "$benign"
  expire_stamp
  : >"$FAIL_FLAG"
  stalled "deploy with $token now"; s=$?
  check 'an expired verdict does not stand in for a probe that failed outright' \
    test "$s:$(noticed 'Scanner readiness: command-failed[.]')" = 0:yes
  rm -f "$FAIL_FLAG"
  stalled "deploy with $token now"; s=$?
  check 'once the stall ends the next process probes again and refreshes the verdict' \
    test "$s:$(probes):$(test "$(stamp_of)" != "$expired" && echo fresh)" = 2:1:fresh

  age_stamp
  printf '%s\n%s\n%s\n' "$key" "$aged" 8.99.9 >"$CACHE"
  "$GUARD" check >"$CASE/out" 2>"$CASE/err"
  check 'the check command probes instead of reading the cache' \
    test "$(grep -c 8.99.9 "$CASE/out" "$CASE/err" | awk -F: '{s+=$2} END{print s}')" = 0
fi

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]

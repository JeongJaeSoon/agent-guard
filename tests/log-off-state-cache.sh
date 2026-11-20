#!/bin/sh
# With AGENT_GUARD_LOG_MODE=off nothing reaches the private state directory,
# unless AGENT_GUARD_SCAN_CACHE=on is set explicitly (#510). Then the gitleaks
# readiness cache, the clean-scan cache and the protected-path regex cache use
# that directory, which must pass the same checks as with logging on, and no
# event log is written. A cache only changes speed: every verdict, stdout and
# stderr equals the uncached run, on both hosts and both infrastructure modes.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-log-off-cache.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'chmod -R u+rwx "$CASE" 2>/dev/null; rm -rf "$CASE"' 0 HUP INT TERM
mkdir -p "$CASE/bin" "$CASE/home" "$CASE/w" "$CASE/elsewhere" "$CASE/res"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_PROMPT_GUARD_MODE=block AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
export AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks"
export FAKE_GITLEAKS_CALLS="$CASE/calls"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT AGENT_GUARD_SCAN_CACHE GITLEAKS_CONFIG_TOML FAKE_GITLEAKS_STDIN_EXIT FAKE_GITLEAKS_STDIN_NOISE
STATE="$XDG_STATE_HOME/agent-guard"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

if ! command -v cc >/dev/null 2>&1 \
    || ! cc -O2 -o "$CASE/bin/gitleaks" "$ROOT/bench/process-count/fake-gitleaks.c" 2>/dev/null; then
  # The scan and probe caches only trust a native executable.
  if [ "${CI:-}" = true ] && [ "$(uname -s)" = Linux ]; then
    bad 'a C compiler is required for the logging-off cache checks on Linux CI'
  else
    printf '# no C compiler; skipped logging-off cache checks\n'
  fi
  printf '%s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi
(
  cd "$CASE/w" || exit 1
  git init -q && git config user.email t@example.invalid && git config user.name t \
    && printf '%s\n' ok >README.md && git add README.md && git commit -q -m init
) || exit 1

calls() { grep -cx "$1" "$FAKE_GITLEAKS_CALLS" 2>/dev/null || :; }
reset() {
  chmod -R u+rwx "$XDG_STATE_HOME" 2>/dev/null
  rm -rf "$XDG_STATE_HOME" "$AGENT_GUARD_WARNING_DIR" "$CASE/elsewhere"
  mkdir -p "$CASE/elsewhere"
  : >"$FAKE_GITLEAKS_CALLS"
}
# Every regular file or directory under $1, one per line, or nothing.
tree() { [ -e "$1" ] || [ -L "$1" ] || return 0; (cd "$1" && find . -mindepth 1 | LC_ALL=C sort); }
mode_of() {
  case "$(uname -s)" in
    Darwin|*BSD|DragonFly) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac 2>/dev/null
}

marker="AGENT_GUARD_TEST_""SECRET"
# One line per event: subcommand, then the hook input. The same events run
# under every setting; HOST and the session id are filled in per run.
cat >"$CASE/events" <<EOF
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"git status"}}
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"git status"}}
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"ls -la src"}}
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"echo $marker"}}
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"echo $marker"}}
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"cat .env"}}
hook-pre-tool	{"tool_name":"Bash","tool_input":{"command":"cat .e?v"}}
hook-pre-tool	{"tool_name":"Read","tool_input":{"file_path":".env.local"}}
hook-pre-tool	{"tool_name":"Write","tool_input":{"file_path":"a.txt","content":"hello"}}
hook-pre-tool	{"tool_name":"Write","tool_input":{"file_path":"a.txt","content":"$marker"}}
hook-pre-tool	{"tool_name":"FutureTool","tool_input":{"x":1}}
hook-user-prompt	{"prompt":"please refactor the parser"}
hook-user-prompt	{"prompt":"please use $marker"}
hook-post-tool	{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"README.md\n","stderr":"","interrupted":false}}
hook-post-tool	{"tool_name":"Bash","tool_input":{"command":"echo"},"tool_response":{"stdout":"token $marker here\n","stderr":"","interrupted":false}}
EOF
# The live post-tool probe sentinel, read from the binary so this file holds no
# copy: with logging off it must mask to the bare placeholder, cached or not.
probe=$(sed -n 's/^LIVE_POST_TOOL_PROBE=//p' "$GUARD" | head -n 1)
probe=${probe#\'}; probe=${probe%\'}
[ -n "$probe" ] || bad 'the live post-tool sentinel is readable from the binary'
jq -nc --arg m "$probe" \
  '{tool_name:"Bash",tool_input:{command:"cat probe.txt"},tool_response:{stdout:($m + "\n"),stderr:"",interrupted:false}}' \
  | sed 's/^/hook-post-tool	/' >>"$CASE/events"

# Runs "$@" with AGENT_GUARD_SCAN_CACHE=$1 in a subshell. A prefix assignment
# before a function call persists after it in some POSIX shells (macOS sh),
# which would leak the opt-in into the default runs that follow.
with_cache() { (AGENT_GUARD_SCAN_CACHE=$1; export AGENT_GUARD_SCAN_CACHE; shift; "$@"); }

# Runs every event under host $1 and writes "status", stdout and stderr of
# each to $2. The cache variable comes from the caller's environment.
run_events() {
  re_n=0
  : >"$2"
  while IFS='	' read -r re_cmd re_json; do
    re_n=$((re_n + 1))
    printf '%s' "$re_json" \
      | jq -c --arg s "log-off-$re_n" --arg d "$CASE/w" '. + {session_id:$s,cwd:$d}' \
      | (cd "$CASE/w" && AGENT_GUARD_HOOK_HOST=$1 "$GUARD" "$re_cmd" >"$CASE/out" 2>"$CASE/err")
    re_status=$?
    { printf '== %s %s status %s\n' "$re_n" "$re_cmd" "$re_status"
      cat "$CASE/out"; printf '\n-- stderr\n'; cat "$CASE/err"; printf '\n'; } >>"$2"
  done <"$CASE/events"
}

for infra in open closed; do
  export AGENT_GUARD_INFRA_FAILURE_MODE=$infra
  for host in claude codex; do
    tag="$host/$infra"

    # The default: logging off writes nothing, whatever else is set. The
    # other values are only told apart once, to bound the run time.
    values=unset
    [ "$tag" != claude/open ] || values='unset off 1 ON'
    for cache in $values; do
      reset
      if [ "$cache" = unset ]; then
        run_events "$host" "$CASE/res/$host-$infra-off-$cache"
      else
        with_cache $cache run_events "$host" "$CASE/res/$host-$infra-off-$cache"
      fi
      check "$tag: logging off with AGENT_GUARD_SCAN_CACHE=$cache creates no state file or directory" \
        test -z "$(tree "$XDG_STATE_HOME")"
    done
    check "$tag: logging off runs the readiness check in every gitleaks invocation" \
      test "$(calls version)" -ge 10
    if [ "$tag" = claude/open ]; then
      cmp -s "$CASE/res/$host-$infra-off-unset" "$CASE/res/$host-$infra-off-off" \
        && cmp -s "$CASE/res/$host-$infra-off-unset" "$CASE/res/$host-$infra-off-1" \
        && cmp -s "$CASE/res/$host-$infra-off-unset" "$CASE/res/$host-$infra-off-ON"
      check "$tag: the cache variable alone changes no verdict or output with logging off" test "$?" -eq 0
    fi

    # The explicit opt-in: caches only, no event log.
    reset
    with_cache on run_events "$host" "$CASE/res/$host-$infra-cold"
    cold_version=$(calls version) cold_scans=$(calls stdin)
    : >"$FAKE_GITLEAKS_CALLS"
    with_cache on run_events "$host" "$CASE/res/$host-$infra-warm"
    warm_version=$(calls version) warm_scans=$(calls stdin)
    check "$tag: a cold cache answers exactly as no cache" \
      cmp -s "$CASE/res/$host-$infra-off-unset" "$CASE/res/$host-$infra-cold"
    check "$tag: a warm cache answers exactly as no cache" \
      cmp -s "$CASE/res/$host-$infra-off-unset" "$CASE/res/$host-$infra-warm"
    if [ -n "$(tree "$STATE" | grep -E '^\./(event-|live-probe-)')" ]; then
      bad "$tag: the opt-in writes no event log or live-probe marker"
      tree "$STATE" | sed 's/^/#   /'
    else
      ok "$tag: the opt-in writes no event log or live-probe marker"
    fi
    check "$tag: the readiness check is reused (cold $cold_version, warm $warm_version)" \
      test "$cold_version" -eq 1 -a "$warm_version" -eq 0
    check "$tag: a repeated clean Bash command skips gitleaks (cold $cold_scans, warm $warm_scans scans)" \
      test "$warm_scans" -lt "$cold_scans"
    check "$tag: the state directory is 700" test "$(mode_of "$STATE")" = 700
    check "$tag: the readiness cache is a private file" \
      test -f "$STATE/gitleaks-probe" -a ! -L "$STATE/gitleaks-probe" -a "$(mode_of "$STATE/gitleaks-probe")" = 600
    check "$tag: the clean-scan cache directory is 700" test "$(mode_of "$STATE/gitleaks-clean")" = 700
    entry=$(ls "$STATE/gitleaks-clean" 2>/dev/null | grep -E '^[0-9a-f]{64}$' | head -n 1)
    check "$tag: a clean-scan entry is 600" \
      test -n "$entry" -a "$(mode_of "$STATE/gitleaks-clean/$entry")" = 600
    dp=$(ls "$STATE" 2>/dev/null | grep '^deny-path-regex-literal-' | head -n 1)
    check "$tag: the protected-path regex cache lives in the state directory" \
      test -n "$dp" -a "$(mode_of "$STATE/$dp")" = 600
    check "$tag: no cache entry holds the scanned text" \
      test -z "$(grep -rl -e 'git status' -e "$marker" "$STATE" 2>/dev/null)"
  done
done
export AGENT_GUARD_INFRA_FAILURE_MODE=open

check 'the live probe sentinel masks to the bare placeholder with the opt-in' \
  sh -c 'grep -Fq "[REDACTED]" "$1" && ! grep -Fq "live probe run_id=" "$1"' _ "$CASE/res/claude-open-warm"

# The opt-in runs no log retention: an expired event record stays as it was.
reset
mkdir -p "$STATE" && chmod 700 "$STATE"
old="$STATE/event-1000000000-old123"
(umask 077; printf '%s\n' '{"schema":1}' >"$old")
mkdir -m 700 "$STATE/live-probe-1000000000-old123"
with_cache on run_events claude "$CASE/res/retention"
check 'the opt-in leaves an expired event record and its sidecar alone' \
  test -f "$old" -a -d "$STATE/live-probe-1000000000-old123" -a "$(cat "$old")" = '{"schema":1}'
check 'the opt-in adds no event record beside it' \
  test "$(tree "$STATE" | grep -c '^\./event-')" = 1
check 'the opt-in still caches in a directory that holds old records' test -f "$STATE/gitleaks-probe"

# A state directory that fails the checks audit_directory makes is not used:
# every invocation probes and scans, nothing is written into it or through it,
# and every answer equals the uncached run.
refused() { # $1 label; the caller has prepared the state directory
  : >"$FAKE_GITLEAKS_CALLS"
  with_cache on run_events claude "$CASE/res/refused"
  check "$1: answers exactly as no cache" \
    cmp -s "$CASE/res/claude-open-off-unset" "$CASE/res/refused"
  check "$1: every gitleaks invocation runs its readiness check" \
    test "$(calls version)" -ge 10
}

reset
mkdir -p "$XDG_STATE_HOME" && (umask 022; mkdir "$STATE")
refused 'a 0755 state directory'
check 'a 0755 state directory is left empty and unchanged' \
  test -z "$(tree "$STATE")" -a "$(mode_of "$STATE")" = 755

reset
mkdir -p "$XDG_STATE_HOME" && ln -s "$CASE/elsewhere" "$STATE"
chmod 700 "$CASE/elsewhere"
refused 'a symlinked state directory'
check 'nothing is written through a symlinked state directory' \
  test -z "$(tree "$CASE/elsewhere")"

reset
mkdir -p "$CASE/elsewhere/agent-guard" && chmod 700 "$CASE/elsewhere/agent-guard"
ln -s "$CASE/elsewhere" "$XDG_STATE_HOME"
refused 'a symlinked parent of the state directory'
check 'nothing is written through a symlinked parent' \
  test -z "$(tree "$CASE/elsewhere/agent-guard")"
rm -f "$XDG_STATE_HOME"

reset
XDG_STATE_HOME=relative/state
export XDG_STATE_HOME
refused 'a relative state location'
check 'nothing is created under a relative state location' test ! -e "$CASE/w/relative"
XDG_STATE_HOME="$CASE/state"
export XDG_STATE_HOME

if [ "$(id -u)" = 0 ] && id nobody >/dev/null 2>&1; then
  reset
  mkdir -p "$STATE" && chmod 700 "$STATE" && chown nobody "$STATE"
  refused 'a state directory owned by another user'
  check 'a foreign state directory is left empty' test -z "$(tree "$STATE")"
else
  ok 'a state directory owned by another user # SKIP needs root and a nobody user'
fi

# Cache files inside a valid directory keep their own checks: a symlinked
# readiness cache or clean-scan directory is never followed.
reset
with_cache on run_events claude "$CASE/res/seed"
rm -f "$STATE/gitleaks-probe"
printf 'planted\n' >"$CASE/elsewhere/probe"
ln -s "$CASE/elsewhere/probe" "$STATE/gitleaks-probe"
rm -rf "$STATE/gitleaks-clean"
mkdir "$CASE/elsewhere/clean" && chmod 700 "$CASE/elsewhere/clean"
ln -s "$CASE/elsewhere/clean" "$STATE/gitleaks-clean"
: >"$FAKE_GITLEAKS_CALLS"
with_cache on run_events claude "$CASE/res/linked"
check 'symlinked cache files answer exactly as no cache' \
  cmp -s "$CASE/res/claude-open-off-unset" "$CASE/res/linked"
check 'a symlinked readiness cache is probed again and replaced, not followed' \
  test "$(calls version)" -ge 1 -a -f "$STATE/gitleaks-probe" -a ! -L "$STATE/gitleaks-probe"
check 'a symlinked clean-scan directory is left as it is' test -L "$STATE/gitleaks-clean"
check 'nothing is written through symlinked cache files' \
  test "$(cat "$CASE/elsewhere/probe")" = planted -a -z "$(tree "$CASE/elsewhere/clean")"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

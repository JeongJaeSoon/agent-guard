#!/bin/sh
# The Bash protected-path scan compiles one regex per deny-list entry. The
# combined regex file that skips that work may only ever rule a command out; it
# must never change a verdict. Every status below is compared with a run that
# has no cache at all (logging off), and the blocked shapes are asserted
# outright. A cache the scan cannot trust (a line matching everything, a
# directory in its place, a stale name) costs time, not protection.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-deny-cache.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0 HUP INT TERM
mkdir -p "$CASE/home" "$CASE/w"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state"
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AI_AGENT AGENT_GUARD_DENY_READ_PATHS
STATE="$XDG_STATE_HOME/agent-guard"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

# $1 command; the log mode in LOG is the only difference between two runs.
LOG=on
status_of() {
  jq -nc --arg c "$1" --arg d "$CASE/w" --arg s "deny-cache-$$" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' \
    | AGENT_GUARD_LOG_MODE=$LOG AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool \
      >/dev/null 2>"$CASE/err"
  echo $?
}
cache_files() { ls "$STATE" 2>/dev/null | grep -c '^deny-path-regex-'; }

CASES="$CASE/cases"
cat >"$CASES" <<'EOF'
ls -la
echo hello world
git status
cat README.md
cat .env
cat ./.env.production
cat .e?v
cat .en[v]
cat "$HOME/.ssh/id_rsa"
cat ~/.aws/credentials
cat '.env'
cat $'\x2eenv'
cat .e""nv
ls -la && cat server.pem
grep -r token .
echo .environment-notes
EOF

LOG=off
expected=$(while IFS= read -r c; do status_of "$c"; done <"$CASES")
LOG=on
rm -rf "$STATE"
cold=$(while IFS= read -r c; do status_of "$c"; done <"$CASES")
warm=$(while IFS= read -r c; do status_of "$c"; done <"$CASES")
check 'a cold cache gives the verdicts of a run without one' test "$cold" = "$expected"
check 'a warm cache gives the verdicts of a run without one' test "$warm" = "$expected"
check 'both modes are cached' test "$(cache_files)" -eq 2
check 'the plain listing passes' test "$(status_of 'ls -la')" = 0
check 'a protected file is still blocked with a warm cache' test "$(status_of 'cat ./.env')" = 2
check 'a wildcard spelling is still blocked with a warm cache' test "$(status_of 'cat .e?v')" = 2
check 'a quote-split spelling is still blocked with a warm cache' test "$(status_of 'cat .e""nv')" = 2

f=$(ls "$STATE" | grep '^deny-path-regex-literal-' | head -n 1)
case "$(uname -s)" in
  Darwin) fmode=$(stat -f '%Lp' "$STATE/$f") ;;
  *) fmode=$(stat -c '%a' "$STATE/$f") ;;
esac
check 'the cache file mode is 600' test "$fmode" = 600

# The point of the cache: a warm scan compiles no regex. Counted from a shell
# trace of one hook process.
compiles() {
  jq -nc --arg c "$1" --arg d "$CASE/w" --arg s "deny-cache-$$" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' \
    | AGENT_GUARD_LOG_MODE=on AGENT_GUARD_HOOK_HOST=claude sh -x "$GUARD" hook-pre-tool 2>&1 >/dev/null \
    | grep -c '^+* deny_path_regex_fragment '
}
check 'a warm scan of a plain command compiles no entry regex' test "$(compiles 'ls -la')" -eq 0
check 'a warm scan of a protected file still compiles the entry for its verdict' \
  test "$(compiles 'cat ./.env')" -gt 0

LOG=off
rm -rf "$STATE"
status_of 'ls -la' >/dev/null
check 'logging off writes no cache' test "$(cache_files)" -eq 0
LOG=on

# The regexes depend on the locale, so each locale gets its own file.
rm -rf "$STATE"
LC_ALL=C status_of 'ls -la' >/dev/null
check 'the C locale caches both modes' test "$(cache_files)" -eq 2
LC_ALL=en_US.UTF-8 status_of 'ls -la' >/dev/null
check 'another locale does not reuse the C locale files' test "$(cache_files)" -eq 4

# A write that fails part way must not publish the regexes written so far: the
# file would lack an entry and rule that entry's commands out. The store
# function runs alone with a printf that fails on the second regex.
rm -rf "$STATE"
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE" deny_path_cache_store deny_path_cache_complete
printf 'alpha\nbeta\n# end\n' >"$CASE/partial-list"
mkdir -p "$CASE/store"
partial_status=$(
  . "$CASE/deny_path_cache_store.sh"
  . "$CASE/deny_path_cache_complete.sh"
  DENY_READ_PATHS="$CASE/partial-list" AG_STATE_DIR="$CASE/store"
  dpc_file="$CASE/store/published"
  deny_path_command_regex() { echo "$1"; }
  printf() { [ "${2-}" != beta ] || return 1; command printf "$@"; }
  deny_path_cache_store literal
  echo $?
)
check 'a cache write that fails part way is refused' test "$partial_status" = 1
check 'a cache write that fails part way publishes no file' \
  test "$(ls "$CASE/store" | wc -l | tr -d ' ')" = 0
# The same when one entry's regex cannot be produced.
gen_status=$(
  . "$CASE/deny_path_cache_store.sh"
  . "$CASE/deny_path_cache_complete.sh"
  DENY_READ_PATHS="$CASE/partial-list" AG_STATE_DIR="$CASE/store"
  dpc_file="$CASE/store/published"
  deny_path_command_regex() { [ "$1" != beta ] || return 1; echo "$1"; }
  deny_path_cache_store literal
  echo $?
)
check 'a failed regex for one entry is refused' test "$gen_status" = 1
check 'a failed regex for one entry publishes no file' \
  test "$(ls "$CASE/store" | wc -l | tr -d ' ')" = 0
# A read error ends the loop like end of file; the entry count catches it. The
# first line starts with a space, so the loop treats it as an entry, not a
# comment, and the count has to agree.
printf ' # padding\nsecretfile.txt\n' >"$CASE/padded-list"
read_status=$(
  . "$CASE/deny_path_cache_store.sh"
  . "$CASE/deny_path_cache_complete.sh"
  DENY_READ_PATHS="$CASE/padded-list" AG_STATE_DIR="$CASE/store"
  dpc_file="$CASE/store/published"
  deny_path_command_regex() { echo "$1"; }
  reads=0
  read() { reads=$((reads + 1)); [ "$reads" -le 1 ] || { dpc_entry=; return 1; }; command read "$@"; }
  deny_path_cache_store literal
  echo $?
)
check 'a list read that stops early is refused' test "$read_status" = 1
check 'a list read that stops early publishes no file' \
  test "$(ls "$CASE/store" | wc -l | tr -d ' ')" = 0
# Control: the same stubs without the fault publish.
ok_status=$(
  . "$CASE/deny_path_cache_store.sh"
  . "$CASE/deny_path_cache_complete.sh"
  DENY_READ_PATHS="$CASE/partial-list" AG_STATE_DIR="$CASE/store"
  dpc_file="$CASE/store/published"
  deny_path_command_regex() { echo "$1"; }
  deny_path_cache_store literal
  echo $?
)
check 'a complete list is published' test "$ok_status:$(wc -l <"$CASE/store/published" | tr -d ' ')" = 0:2
rm -f "$CASE/store/published"

# A tampered line that matches every command only sends the scan down the
# per-entry loop, which gives its own verdict.
status_of 'ls -la' >/dev/null
f=$(ls "$STATE" | grep '^deny-path-regex-literal-' | head -n 1)
check 'the state directory holds the literal cache file' test -n "$f"
printf '.\n' >"$STATE/$f"
check 'a match-all cache line falls back to the per-entry verdict' test "$(status_of 'ls -la')" = 0
check 'a match-all cache line still blocks a protected file' test "$(status_of 'cat ./.env')" = 2

# A directory where the cache file belongs is never followed or replaced.
status_of 'ls -la' >/dev/null
f=$(ls "$STATE" | grep '^deny-path-regex-literal-' | head -n 1)
check 'the cache file exists before it is replaced' test -n "$f"
rm -f "$STATE/$f"
mkdir "$STATE/$f"
check 'a directory in place of the cache still passes a plain command' test "$(status_of 'ls -la')" = 0
check 'a directory in place of the cache still blocks a protected file' test "$(status_of 'cat ./.env')" = 2
rm -rf "$STATE/$f"

# An edited deny list is a new cache name; the old file is removed.
printf 'secretfile.txt\n' >"$CASE/deny1.txt"
export AGENT_GUARD_DENY_READ_PATHS="$CASE/deny1.txt"
rm -rf "$STATE"
check 'a custom list blocks its entry' test "$(status_of 'cat secretfile.txt')" = 2
check 'a custom list leaves other names alone' test "$(status_of 'cat other.key')" = 0
first=$(ls "$STATE" | grep '^deny-path-regex-literal-')
printf 'secretfile.txt\nother.key\n' >"$CASE/deny1.txt"
check 'an edited list blocks its new entry' test "$(status_of 'cat other.key')" = 2
check 'the edit got its own cache file' \
  test "$(ls "$STATE" | grep -c '^deny-path-regex-literal-')" -eq 2 \
  -a "$(ls "$STATE" | grep -c "^$first\$")" -eq 1
# Past six files for one mode, the next write keeps only its own.
n=0
while [ "$n" -lt 7 ]; do
  : >"$STATE/deny-path-regex-literal-old-$n"
  n=$((n + 1))
done
printf 'secretfile.txt\nother.key\nthird.key\n' >"$CASE/deny1.txt"
check 'a third list version is still enforced' test "$(status_of 'cat third.key')" = 2
check 'a pile of old cache files is pruned to the current one' \
  test "$(ls "$STATE" | grep -c '^deny-path-regex-literal-')" -eq 1

# An entry that is not a valid regex fails closed, cold and warm.
printf 'a\\\n' >"$CASE/deny2.txt"
export AGENT_GUARD_DENY_READ_PATHS="$CASE/deny2.txt"
rm -rf "$STATE"
LOG=off
bare=$(status_of 'ls -la')
LOG=on
check 'the broken entry is refused without a cache' test "$bare" = 2
check 'a broken entry gives the same verdict cold as without a cache' test "$(status_of 'ls -la')" = "$bare"
check 'a broken entry gives the same verdict warm as without a cache' test "$(status_of 'ls -la')" = "$bare"

printf '1..%s\n' "$((pass + fail))"
printf '# pass %s fail %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

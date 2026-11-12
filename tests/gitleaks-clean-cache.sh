#!/bin/sh
# A clean gitleaks verdict for the exact same scanned bytes is reused across
# hook processes only under the same scanner identity and configuration
# (#407). Findings, errors, signals and could-not-run states are never stored;
# every cache problem runs the scan. A counting native stand-in proves which
# events started gitleaks.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-clean-cache.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0 HUP INT TERM
mkdir -p "$CASE/bin" "$CASE/home" "$CASE/w" "$CASE/outside" "$CASE/shim"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_LOG_MODE=on
export AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_PROMPT_GUARD_MODE=block AGENT_GUARD_INFRA_FAILURE_MODE=open
export AGENT_GUARD_WARNING_DIR="$CASE/warnings"
cp "$ROOT/plugins/agent-guard/config/gitleaks.toml" "$CASE/gitleaks.toml"
export AGENT_GUARD_GITLEAKS_CONFIG="$CASE/gitleaks.toml"
export AGENT_GUARD_GITLEAKS_BIN="$CASE/bin/gitleaks"
export FAKE_GITLEAKS_CALLS="$CASE/calls"
unset AI_AGENT AGENT_GUARD_SCAN_CACHE GITLEAKS_CONFIG_TOML FAKE_GITLEAKS_STDIN_EXIT FAKE_GITLEAKS_STDIN_NOISE
STORE="$XDG_STATE_HOME/agent-guard/gitleaks-clean"
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
check() { label=$1; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

scans() { grep -cx stdin "$FAKE_GITLEAKS_CALLS" 2>/dev/null || :; }
entries() { ls "$STORE" 2>/dev/null | grep -c '' || :; }
reset() { rm -rf "$XDG_STATE_HOME" "$AGENT_GUARD_WARNING_DIR"; : >"$FAKE_GITLEAKS_CALLS"; }
mode_of() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}
seq_n=0
# $1 command; prints the hook status. Runs in $CASE/w unless CWD says otherwise.
bash_status() {
  seq_n=$((seq_n + 1))
  jq -nc --arg c "$1" --arg d "${CWD:-$CASE/w}" --arg s "clean-cache-$seq_n" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' \
    | (cd "${CWD:-$CASE/w}" && AGENT_GUARD_HOOK_HOST=${HOST:-claude} "$GUARD" hook-pre-tool \
        >"$CASE/out" 2>"$CASE/err")
  echo $?
}
# Runs $1 and prints "scans it started:hook status".
scan_and_status() {
  before=$(scans)
  s=$(bash_status "$1")
  echo "$(($(scans) - before)):$s"
}
scans_for() { r=$(scan_and_status "$1"); echo "${r%%:*}"; }
marker="AGENT_GUARD_TEST_""SECRET"

if ! command -v cc >/dev/null 2>&1 \
    || ! cc -O2 -o "$CASE/bin/gitleaks" "$ROOT/bench/process-count/fake-gitleaks.c" 2>/dev/null; then
  # The cache only trusts a native executable, so every reuse check needs one.
  if [ "${CI:-}" = true ] && [ "$(uname -s)" = Linux ]; then
    bad 'a C compiler is required for the clean-verdict cache checks on Linux CI'
  else
    printf '# no C compiler; skipped clean-verdict cache checks\n'
  fi
  printf '%s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi
cp "$CASE/bin/gitleaks" "$CASE/gitleaks.native"

reset
check 'a cold clean command scans once' test "$(scan_and_status 'ls -la')" = 1:0
check 'the identical command reuses the clean verdict' test "$(scan_and_status 'ls -la')" = 0:0
for i in 1 2 3 4 5 6 7 8; do bash_status 'ls -la' >/dev/null; done
check 'ten identical clean commands start gitleaks once' test "$(scans)" = 1
check 'a different text is scanned' test "$(scan_and_status 'git status')" = 1:0
check 'a one-byte difference is scanned' test "$(scans_for 'ls -la ')" = 1
check 'the cache directory mode is 700' test "$(mode_of "$STORE")" = 700
f=$(ls "$STORE" | head -n 1)
check 'an entry file mode is 600' test "$(mode_of "$STORE/$f")" = 600
check 'an entry is named by a SHA-256' \
  sh -c 'case "$1" in *[!0-9a-f]*) exit 1 ;; esac; [ "${#1}" -eq 64 ]' _ "$f"
check 'entries never contain the scanned text' \
  test -z "$(grep -rl -e 'ls -la' -e 'git status' "$STORE" 2>/dev/null)"
check 'an entry holds only a format, a hash and a time' \
  sh -c 'awk "NR==1 && \$0 != \"1\" {e=1} NR==2 && \$0 !~ /^[0-9a-f]{64}\$/ {e=1} NR==3 && \$0 !~ /^[1-9][0-9]*\$/ {e=1} END {exit e || NR != 3}" "$1"' _ "$STORE/$f"

n=$(entries)
check 'a secret is scanned and blocked' test "$(scan_and_status "echo $marker")" = 1:2
check 'the same secret is scanned and blocked again' test "$(scan_and_status "echo $marker")" = 1:2
check 'a finding is never cached' test "$(entries)" = "$n"
check 'a secret appended to a cached command is still blocked' \
  test "$(scan_and_status "ls -la $marker")" = 1:2

# Codex reaches the same boundary check and the same verdicts.
HOST=codex
check 'codex reuses the clean verdict' test "$(scan_and_status 'ls -la')" = 0:0
check 'codex still blocks a secret with a warm cache' test "$(scan_and_status "echo $marker")" = 1:2
HOST=

# Configuration and identity changes miss.
printf '\n# local edit\n' >>"$CASE/gitleaks.toml"
check 'an edited config is scanned again' test "$(scans_for 'ls -la')" = 1
check 'the edited config then reuses its own verdict' test "$(scans_for 'ls -la')" = 0
cp "$ROOT/plugins/agent-guard/config/gitleaks.toml" "$CASE/other.toml"
check 'another config file is scanned' \
  test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/other.toml" scans_for 'ls -la')" = 1
check 'GITLEAKS_CONFIG_TOML is part of the key' \
  test "$(GITLEAKS_CONFIG_TOML='title = "x"' scans_for 'ls -la')" = 1
check 'the original config still reuses its verdict' test "$(scans_for 'ls -la')" = 0
cp "$CASE/gitleaks.native" "$CASE/bin/gitleaks"
check 'a rewritten gitleaks binary is scanned again' test "$(scans_for 'ls -la')" = 1
rm -f "$CASE/bin/gitleaks"
cp "$CASE/gitleaks.native" "$CASE/bin/gitleaks"
check 'a replaced gitleaks binary is scanned again' test "$(scans_for 'ls -la')" = 1

# An ignore file in the scan directory can hide a finding: no reuse, no store.
mkdir -p "$CASE/ign"
: >"$CASE/ign/.gitleaksignore"
n=$(entries)
CWD="$CASE/ign"
check 'a scan beside .gitleaksignore is not served from the cache' test "$(scans_for 'ls -la')" = 1
check 'a new text beside .gitleaksignore is scanned' test "$(scans_for 'ls -lh')" = 1
check 'a repeated text beside .gitleaksignore is scanned again' test "$(scans_for 'ls -lh')" = 1
rm -f "$CASE/ign/.gitleaksignore"
ln -s "$CASE/outside/missing" "$CASE/ign/.gitleaksignore"
check 'a dangling .gitleaksignore link also disables the cache' test "$(scans_for 'ls -lh')" = 1
CWD=
check 'nothing is stored beside .gitleaksignore' test "$(entries)" = "$n"

# A scan that did not complete clean is never stored.
for how in 2 126 kill; do
  cmd="echo failed-$how"
  FAKE_GITLEAKS_STDIN_EXIT=$how bash_status "$cmd" >/dev/null
  check "a scanner status of $how is not cached" test "$(scans_for "$cmd")" = 1
done
cmd='echo noisy'
FAKE_GITLEAKS_STDIN_NOISE=1 bash_status "$cmd" >/dev/null
check 'a scanner error printed with status 0 is not cached' test "$(scans_for "$cmd")" = 1
check 'a scanner error under the closed policy blocks, not passes' \
  test "$(FAKE_GITLEAKS_STDIN_EXIT=2 AGENT_GUARD_INFRA_FAILURE_MODE=closed bash_status 'echo closed-fail')" = 2

# Every unusable entry falls back to the scan.
reset
bash_status 'ls -la' >/dev/null
f=$(ls "$STORE")
good=$(cat "$STORE/$f")
printf 'not a cache\n' >"$STORE/$f"
check 'a corrupt entry is scanned' test "$(scan_and_status 'ls -la')" = 1:0
check 'the corrupt entry is replaced by a clean one' test "$(scans_for 'ls -la')" = 0
{ sed -n 1,2p "$STORE/$f"; echo 1; } >"$CASE/expired"
mv "$CASE/expired" "$STORE/$f"
check 'an expired entry is scanned' test "$(scans_for 'ls -la')" = 1
{ sed -n 1,2p "$STORE/$f"; echo "0$(sed -n 3p "$STORE/$f")"; } >"$CASE/zero"
mv "$CASE/zero" "$STORE/$f"
check 'a leading-zero time is scanned' test "$(scan_and_status 'ls -la')" = 1:0
{ echo 1; echo 0000000000000000000000000000000000000000000000000000000000000000; sed -n 3p "$STORE/$f"; } >"$CASE/other"
mv "$CASE/other" "$STORE/$f"
check 'an entry of another config is scanned' test "$(scans_for 'ls -la')" = 1
good=$(cat "$STORE/$f")
printf '%s\n' "$good" >"$CASE/outside/entry"
rm -f "$STORE/$f"
ln -s "$CASE/outside/entry" "$STORE/$f"
check 'a symlinked entry is scanned, not trusted' test "$(scans_for 'ls -la')" = 1
check 'a symlinked entry is replaced, not followed' \
  test ! -L "$STORE/$f" -a "$(cat "$CASE/outside/entry")" = "$good"
rm -rf "$STORE"
mkdir "$CASE/outside/dir"
printf '%s\n' "$good" >"$CASE/outside/dir/$f"
ln -s "$CASE/outside/dir" "$STORE"
check 'a symlinked cache directory is scanned, not trusted' test "$(scans_for 'ls -la')" = 1
check 'nothing is written through a symlinked cache directory' \
  test "$(ls "$CASE/outside/dir")" = "$f"
rm -f "$STORE"
mkdir -p "$STORE/$f"
check 'a directory in place of an entry is scanned' test "$(scan_and_status 'ls -la')" = 1:0
rm -rf "$STORE"
mkdir -m 755 "$STORE"
check 'a cache directory with a wide mode stores nothing' \
  test "$(scans_for 'ls -la'):$(scans_for 'ls -la'):$(entries)" = 1:1:0
rm -rf "$STORE"

# An [extend] path loads a file the key does not hash, and TOML and viper
# offer many spellings of it. Each one, and anything unrecognized near it,
# is never cached; the plain useDefault forms still are.
o="$CASE/other.toml"
n=0
while IFS= read -r spelling; do
  n=$((n + 1))
  printf '%b\n' "$spelling" | sed "s#OTHER#$o#g" >"$CASE/extend-$n.toml"
  rm -rf "$STORE"
  check "never cached: $(printf '%b' "$spelling" | tr '\n' ' ')" \
    test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/extend-$n.toml" scans_for 'ls -la'):$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/extend-$n.toml" scans_for 'ls -la'):$(entries)" = 1:1:0
done <<'EOF'
[extend]\npath = "OTHER"
[extend]\nuseDefault = true\npath = "OTHER"
[extend]\n"path" = "OTHER"
[extend]\n'path' = "OTHER"
[extend]\nPATH = "OTHER"
[ "extend" ]\npath = "OTHER"
['extend']\npath = "OTHER"
[EXTEND]\npath = "OTHER"
extend = { path = "OTHER" }
extend.path = "OTHER"
"extend".path = "OTHER"
'extend'.path = "OTHER"
extend . path = "OTHER"
"\\u0065xtend".path = "OTHER"
["\\u0065xtend"]\npath = "OTHER"
[extend] # extend\nuseDefault = true
[extend]\nuseDefault = true\ndisabledRules = [\n"generic-api-key" ]
EOF
for spelling in '[extend]\nuseDefault = true' '[extend]\nuseDefault = true\ndisabledRules = ["generic-api-key"]' \
    'title = "x"\n[[rules]]\nid = "r"\nregex = '"'''x'''"; do
  n=$((n + 1))
  printf '%b\n' "$spelling" >"$CASE/extend-$n.toml"
  rm -rf "$STORE"
  check "still cached: $(printf '%b' "$spelling" | tr '\n' ' ')" \
    test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/extend-$n.toml" scans_for 'ls -la'):$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/extend-$n.toml" scans_for 'ls -la')" = 1:0
done
rm -rf "$STORE"

# A config edited while the scan runs is not the one the key hashed.
cp "$CASE/gitleaks.toml" "$CASE/moving.toml"
check 'a config edited during the scan is not cached' \
  test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/moving.toml" FAKE_GITLEAKS_STDIN_APPEND="$CASE/moving.toml" scans_for 'ls -la'):$(entries)" = 1:0
check 'the unchanged config afterwards is cached again' \
  test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/moving.toml" scans_for 'ls -la'):$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/moving.toml" scans_for 'ls -la')" = 1:0
rm -rf "$STORE"

# The hash tool comes from PATH. One that answers a constant, or ignores its
# input, must never turn a secret into a hit.
mkdir -p "$CASE/hashbin"
for constant in 1111111111111111111111111111111111111111111111111111111111111111 \
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855; do
  printf '#!/bin/sh\ncat >/dev/null\nfor f in "$@"; do printf "%%s  %%s\\n" %s "$f"; done\n' "$constant" >"$CASE/hashbin/sha256sum"
  chmod +x "$CASE/hashbin/sha256sum"
  reset
  PATH="$CASE/hashbin:$PATH" bash_status 'ls -la' >/dev/null
  check "a constant-hash tool ($constant) is not trusted for a clean text" \
    test "$(PATH="$CASE/hashbin:$PATH" scans_for 'ls -la'):$(entries)" = 1:0
  check "a constant-hash tool ($constant) still blocks a secret" \
    test "$(PATH="$CASE/hashbin:$PATH" scan_and_status "echo $marker")" = 1:2
done
# A tool that hashes only the known vector correctly still repeats itself.
printf '#!/bin/sh\ncat >/dev/null\nfor f in "$@"; do if [ "$f" = /dev/null ]; then s=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855; else s=2222222222222222222222222222222222222222222222222222222222222222; fi; printf "%%s  %%s\\n" "$s" "$f"; done\n' >"$CASE/hashbin/sha256sum"
reset
check 'a hash tool that ignores its input is not trusted' \
  test "$(PATH="$CASE/hashbin:$PATH" scans_for 'ls -la'):$(PATH="$CASE/hashbin:$PATH" scans_for 'ls -la'):$(entries)" = 1:1:0
check 'a hash tool that ignores its input still blocks a secret' \
  test "$(PATH="$CASE/hashbin:$PATH" scan_and_status "echo $marker")" = 1:2

# A hit needs the directory and entry exactly as the store leaves them.
reset
bash_status 'ls -la' >/dev/null
f=$(ls "$STORE")
chmod 777 "$STORE"
check 'a 0777 cache directory is not trusted on a hit' test "$(scans_for 'ls -la')" = 1
chmod 700 "$STORE"
check 'the restored directory is trusted again' test "$(scans_for 'ls -la')" = 0
chmod 620 "$STORE/$f"
check 'a group-writable entry is not trusted' test "$(scans_for 'ls -la')" = 1
chmod 602 "$STORE/$f" 2>/dev/null
check 'an other-writable entry is not trusted' test "$(scans_for 'ls -la')" = 1
chmod 600 "$STORE/$f"
check 'a private entry is trusted again' test "$(scans_for 'ls -la')" = 0

# The opt-out, an unknown value, and logging off all scan every time.
for v in off 1; do
  reset
  check "AGENT_GUARD_SCAN_CACHE=$v scans every time and stores nothing" \
    test "$(AGENT_GUARD_SCAN_CACHE=$v scans_for 'ls -la'):$(AGENT_GUARD_SCAN_CACHE=$v scans_for 'ls -la'):$(entries)" = 1:1:0
done
reset
check 'logging off scans every time and creates no state' \
  test "$(AGENT_GUARD_LOG_MODE=off scans_for 'ls -la'):$(AGENT_GUARD_LOG_MODE=off scans_for 'ls -la'):$(test -e "$XDG_STATE_HOME" && echo state)" = 1:1:
reset
check 'AGENT_GUARD_SCAN_CACHE=on is the default' \
  test "$(AGENT_GUARD_SCAN_CACHE=on scans_for 'ls -la'):$(scans_for 'ls -la')" = 1:0

# A #! shim has no stable identity, so it is never cached.
printf '#!/bin/sh\nexec "%s" "$@"\n' "$CASE/gitleaks.native" >"$CASE/shim/gitleaks"
chmod +x "$CASE/shim/gitleaks"
reset
check 'a script shim scans every time' \
  test "$(AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" scans_for 'ls -la'):$(AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" scans_for 'ls -la'):$(entries)" = 1:1:0

# The user prompt shares the scan and the cache.
reset
prompt_status() {
  jq -nc --arg p "$1" '{session_id:"clean-cache-prompt",prompt:$p}' \
    | (cd "$CASE/w" && AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-user-prompt >"$CASE/out" 2>"$CASE/err")
  echo $?
}
prompt_status 'please refactor the parser' >/dev/null
before=$(scans)
check 'a repeated clean prompt passes' test "$(prompt_status 'please refactor the parser')" = 0
check 'a repeated clean prompt reuses the verdict' test "$(scans)" = "$before"
check 'a secret prompt is still blocked' test "$(prompt_status "please use $marker")" = 2

# The directory stays bounded.
reset
bash_status 'ls -la' >/dev/null
f=$(ls "$STORE")
i=0
while [ "$i" -lt 300 ]; do
  printf '1\n%s\n1\n' "$f" >"$STORE/$(printf '%064x' "$i")"
  i=$((i + 1))
done
touch "$STORE/not-ours"
bash_status 'ls -l' >/dev/null
check 'a full cache is pruned to its bound' test "$(entries)" -le 256
check 'pruning keeps the newest entry' test "$(scans_for 'ls -l')" = 0
check 'pruning leaves files it did not write' test -e "$STORE/not-ours"

# The key names the scan flags; it must track the command that runs the scan.
flags=$(sed -n "s/^GITLEAKS_STDIN_SCAN_FLAGS='\(.*\)'\$/\1/p" "$GUARD")
run_flags=$(awk '/^run_gitleaks_stdin\(\) \{/ { f = 1 } f && /"\$GITLEAKS_BIN" stdin/ { l = $0; getline; print l " " $0; exit }' "$GUARD" \
  | sed -e 's/^ *"\$GITLEAKS_BIN" //' -e 's/ *\\ */ /' -e 's/ >"\$out" 2>&1$//' -e 's/"\$GITLEAKS_CONFIG"/CONFIG/')
check 'the keyed scan flags match the scan command' test -n "$flags" -a "$flags" = "$run_flags"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

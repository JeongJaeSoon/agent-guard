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
# Entries are named by a 64-digit SHA-256; config-<hash> markers are not entries.
entry_list() { ls "$STORE" 2>/dev/null | grep -E '^[0-9a-f]{64}$'; }
entries() { entry_list | grep -c '' || :; }
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

# The cache trusts only a root-owned hash tool at a fixed system path. Find the
# one it would pick; without one, caching must simply be off.
stat_line() {
  case "$(uname -s)" in
    Darwin|*BSD|DragonFly) stat -f '%u:%Lp' "$1" ;;
    *) stat -c '%u:%a' "$1" ;;
  esac 2>/dev/null
}
sys_hasher=
for c in /usr/bin/sha256sum /bin/sha256sum /usr/bin/shasum; do
  [ -f "$c" ] && [ ! -L "$c" ] && [ -x "$c" ] && [ -d "${c%/*}" ] && [ ! -L "${c%/*}" ] || continue
  sys_hasher=$c
  break
done
sys_ok=
if [ -n "$sys_hasher" ]; then
  case "$(stat_line "$sys_hasher"):$(stat_line "${sys_hasher%/*}")" in
    0:*[0145][0145]:0:*[0145][0145]) sys_ok=1 ;;
  esac
fi
# Linux normally has /usr/bin/sha256sum and macOS /usr/bin/shasum (a perl
# script); both are root's. The branch this run checks is printed.
if [ -n "$sys_ok" ]; then
  printf '# trusted hash tool: %s; caching is expected on\n' "$sys_hasher"
fi
if [ -z "$sys_ok" ]; then
  printf '# no root-owned system hash tool; checking that nothing is cached\n'
  reset
  check 'without a trusted hash tool every clean command is scanned' \
    test "$(scan_and_status 'ls -la'):$(scan_and_status 'ls -la'):$(entries)" = 1:0:1:0:0
  check 'without a trusted hash tool a secret is blocked' \
    test "$(scan_and_status "echo $marker")" = 1:2
  printf '%s passed, %s failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit
fi

reset
check 'a cold clean command scans once' test "$(scan_and_status 'ls -la')" = 1:0
check 'the identical command reuses the clean verdict' test "$(scan_and_status 'ls -la')" = 0:0
for i in 1 2 3 4 5 6 7 8; do bash_status 'ls -la' >/dev/null; done
check 'ten identical clean commands start gitleaks once' test "$(scans)" = 1
check 'a different text is scanned' test "$(scan_and_status 'git status')" = 1:0
check 'a one-byte difference is scanned' test "$(scans_for 'ls -la ')" = 1
check 'the cache directory mode is 700' test "$(mode_of "$STORE")" = 700
f=$(entry_list | head -n 1)
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
  (FAKE_GITLEAKS_STDIN_EXIT=$how bash_status "$cmd" >/dev/null)
  check "a scanner status of $how is not cached" test "$(scans_for "$cmd")" = 1
done
cmd='echo noisy'
(FAKE_GITLEAKS_STDIN_NOISE=1 bash_status "$cmd" >/dev/null)
check 'a scanner error printed with status 0 is not cached' test "$(scans_for "$cmd")" = 1
check 'a scanner error under the closed policy blocks, not passes' \
  test "$(FAKE_GITLEAKS_STDIN_EXIT=2 AGENT_GUARD_INFRA_FAILURE_MODE=closed bash_status 'echo closed-fail')" = 2
# A shell that keeps an assignment before a function call (bash 3.2 as sh on
# macOS) would carry a forced scanner failure into every later case, where the
# open infrastructure policy then passes a secret. Prove nothing leaked.
check 'forced scanner results stay inside their own case' \
  test -z "${FAKE_GITLEAKS_STDIN_EXIT-}${FAKE_GITLEAKS_STDIN_NOISE-}${FAKE_GITLEAKS_STDIN_APPEND-}"

# Every unusable entry falls back to the scan.
reset
bash_status 'ls -la' >/dev/null
f=$(entry_list)
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
[extend]\ndisabledRules = [''' ]\n[not_a_real_table]\n''']\npath = 'OTHER'
[extend]\ndisabledRules = [""" ]\n[not_a_real_table]\n"""]\npath = 'OTHER'
[extend]\nuseDefault = true # '''\n[x]\n'''\npath = 'OTHER'
title = '''\n'''\n[extend]\nuseDefault = true
title = '''\n[extend]\n'''\n[extend]\npath = "OTHER"
[extend]\nuseDefault = true\n[[rules]]\nid = "r"\nregex = 'x'\n[extend]\npath = "OTHER"
EOF
for spelling in '[extend]\nuseDefault = true' '[extend]\nuseDefault = true\ndisabledRules = ["generic-api-key"]' \
    'title = "x"\n[[rules]]\nid = "r"\nregex = '"'''x'''" \
    '[extend]\nuseDefault = true\n[[rules]]\nid = "r"\nregex = '"'''x'''"; do
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

# A link on the config path can be pointed at another, older file during the
# scan without touching that file's ctime: such a path is always hashed again,
# so gitleaks's verdict on B is never stored under A's key.
mkdir -p "$CASE/cfg/a" "$CASE/cfg/b"
cp "$CASE/gitleaks.toml" "$CASE/cfg/A.toml"
cp "$CASE/gitleaks.toml" "$CASE/cfg/B.toml"
printf '# B differs\n' >>"$CASE/cfg/B.toml"
cp "$CASE/cfg/A.toml" "$CASE/cfg/a/c.toml"
cp "$CASE/cfg/B.toml" "$CASE/cfg/b/c.toml"
ln -s "$CASE/cfg/A.toml" "$CASE/cfg/link.toml"
ln -s "$CASE/cfg/a" "$CASE/cfg/dirlink"
# Both targets must be older than the hook process for the ctime shortcut.
sleep 2
for shape in file dir; do
  case "$shape" in
    file) cfg="$CASE/cfg/link.toml" link="$CASE/cfg/link.toml" a="$CASE/cfg/A.toml" b="$CASE/cfg/B.toml" ;;
    dir) cfg="$CASE/cfg/dirlink/c.toml" link="$CASE/cfg/dirlink" a="$CASE/cfg/a" b="$CASE/cfg/b" ;;
  esac
  rm -rf "$STORE"
  check "a $shape link re-pointed at the same file during the scan still caches" \
    test "$(AGENT_GUARD_GITLEAKS_CONFIG="$cfg" FAKE_GITLEAKS_STDIN_RELINK_TARGET="$a" FAKE_GITLEAKS_STDIN_RELINK_LINK="$link" scans_for 'ls -la'):$(entries)" = 1:1
  rm -rf "$STORE"
  check "a $shape link moved from A to B during the scan stores nothing" \
    test "$(AGENT_GUARD_GITLEAKS_CONFIG="$cfg" FAKE_GITLEAKS_STDIN_RELINK_TARGET="$b" FAKE_GITLEAKS_STDIN_RELINK_LINK="$link" scans_for 'ls -la'):$(entries)" = 1:0
  rm -f "$link"
  ln -s "$a" "$link"
  check "an unchanged $shape link still caches" \
    test "$(AGENT_GUARD_GITLEAKS_CONFIG="$cfg" scans_for 'ls -la'):$(AGENT_GUARD_GITLEAKS_CONFIG="$cfg" scans_for 'ls -la')" = 1:0
done
rm -rf "$STORE"

# The hash tool is never taken from PATH. Shims that answer a constant, a
# constant only for stdin (hashing files honestly), or a replayed clean digest
# change nothing: the system tool still caches, and a secret is still blocked.
mkdir -p "$CASE/hashbin"
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
reset
bash_status 'ls -la' >/dev/null
clean_sum=$(entry_list | head -n 1)
for kind in constant stdin-constant replay; do
  case "$kind" in
    constant) body='cat >/dev/null; for f in "$@"; do echo "1111111111111111111111111111111111111111111111111111111111111111  $f"; done' ;;
    stdin-constant) body="for f in \"\$@\"; do if [ \"\$f\" = - ]; then cat >/dev/null; echo \"3333333333333333333333333333333333333333333333333333333333333333  -\"; else PATH=/usr/bin:/bin sha256sum \"\$f\"; fi; done" ;;
    replay) body="for f in \"\$@\"; do if [ \"\$f\" = - ]; then cat >/dev/null; echo \"$clean_sum  -\"; else PATH=/usr/bin:/bin sha256sum \"\$f\"; fi; done" ;;
  esac
  for tool in sha256sum shasum; do
    printf '#!/bin/sh\n: >"%s/ran"\n%s\n' "$CASE/hashbin" "$body" >"$CASE/hashbin/$tool"
    chmod +x "$CASE/hashbin/$tool"
  done
  reset
  (PATH="$CASE/hashbin:$PATH" bash_status 'ls -la' >/dev/null)
  check "a $kind hash shim on PATH still blocks a secret" \
    test "$(PATH="$CASE/hashbin:$PATH" scan_and_status "echo $marker")" = 1:2
  check "a $kind hash shim on PATH leaves the system tool caching" \
    test "$(PATH="$CASE/hashbin:$PATH" scans_for 'ls -la')" = 0
  check "a $kind hash shim on PATH is never run" test ! -e "$CASE/hashbin/ran"
done

# The tool must sit at a fixed path, not behind a link, and be root's and
# writable by nobody else. Checked through the functions themselves.
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE" \
  gitleaks_clean_cache_hasher gitleaks_clean_cache_modes_ok >/dev/null
mkdir -p "$CASE/fake-sys/bin" "$CASE/fake-sys/linkdir"
cp "$sys_hasher" "$CASE/fake-sys/bin/sha256sum"
ln -s "$CASE/fake-sys/bin/sha256sum" "$CASE/fake-sys/linkdir/sha256sum"
ln -s "$CASE/fake-sys/bin" "$CASE/fake-sys/bindir"
pick() (
  . "$CASE/gitleaks_clean_cache_hasher.sh"
  gitleaks_clean_cache_hasher "$@" && printf '%s\n' "$GITLEAKS_CLEAN_CACHE_HASHER"
)
modes() (
  . "$CASE/gitleaks_clean_cache_modes_ok.sh"
  gitleaks_clean_cache_modes_ok "$(printf '%b' "$1")" 1000 "${2:-hit}" \
    && echo "$ag_glc_i:$ag_glc_config_ctime"
)
check 'a symlinked tool is skipped' \
  test "$(pick "$CASE/fake-sys/linkdir/sha256sum" "$CASE/fake-sys/bin/sha256sum")" = "$CASE/fake-sys/bin/sha256sum"
check 'a tool in a symlinked directory is skipped' test -z "$(pick "$CASE/fake-sys/bindir/sha256sum")"
check 'a tool under another name is skipped' test -z "$(pick "$CASE/fake-sys/bin")"
check 'a relative tool path is skipped' test -z "$(cd "$CASE/fake-sys" && pick bin/sha256sum)"
check 'the default candidates never include a PATH lookup' \
  test "$(PATH="$CASE/hashbin" pick)" = "$sys_hasher"
ok4='0:755:1:5\n0:755:2:5\n1000:700:2:5'
check 'a root-owned private tool, a 700 cache dir and a private entry pass' \
  test "$(modes "$ok4\n1000:600:1:5")" = 4:
check 'the store check reports the config ctime' test "$(modes "$ok4\n0:666:3:42" store)" = 4:42
check 'the store check still needs four lines' test -z "$(modes "$ok4" store)"
check 'a tool not owned by root fails' test -z "$(modes '1000:755:1:5\n0:755:2:5\n1000:700:2:5\n1000:600:1:5')"
check 'a group-writable tool fails' test -z "$(modes '0:775:1:5\n0:755:2:5\n1000:700:2:5\n1000:600:1:5')"
check 'an other-writable tool directory fails' test -z "$(modes '0:755:1:5\n0:757:2:5\n1000:700:2:5\n1000:600:1:5')"
check 'a tool directory not owned by root fails' test -z "$(modes '0:755:1:5\n1000:755:2:5\n1000:700:2:5\n1000:600:1:5')"
check 'a setuid-style four-digit mode is read by its last digits' \
  test "$(modes '0:4755:1:5\n0:755:2:5\n1000:700:2:5\n1000:600:1:5')" = 4:
check 'a foreign cache directory fails' test -z "$(modes '0:755:1:5\n0:755:2:5\n0:700:2:5\n1000:600:1:5')"
check 'a hard-linked entry fails' test -z "$(modes "$ok4\n1000:600:2:5")"
check 'a foreign entry fails' test -z "$(modes "$ok4\n0:600:1:5")"
check 'a group-writable entry fails' test -z "$(modes "$ok4\n1000:620:1:5")"
check 'garbled stat output fails' test -z "$(modes '0:755:1\n0:755:2:5\n1000:700:2:5\n1000:600:1:5')"
check 'an extra field fails' test -z "$(modes "$ok4\n1000:600:1:5:9")"
check 'too few lines fail' test -z "$(modes '0:755:1:5\n0:755:2:5')"
check 'an unknown kind fails' test -z "$(modes "$ok4\n1000:600:1:5" other)"

# A hit needs the directory and entry exactly as the store leaves them.
reset
bash_status 'ls -la' >/dev/null
f=$(entry_list)
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
ln "$STORE/$f" "$CASE/outside/hardlink"
check 'a hard-linked entry is not trusted' test "$(scans_for 'ls -la')" = 1
check 'the replaced entry has one link and is trusted again' test "$(scans_for 'ls -la')" = 0

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
check 'a repeated clean prompt is scanned again: prompts never use the cache' \
  test "$(($(scans) - before)):$(entries)" = 1:0
check 'a secret prompt is still blocked' test "$(prompt_status "please use $marker")" = 2

# The config check runs once per config content: a marker named by its hash
# and holding this version remembers a pass. Nothing else in it is trusted.
reset
bash_status 'ls -la' >/dev/null
markers=$(ls "$STORE" | grep -c '^config-[0-9a-f]\{64\}$')
m=$(ls "$STORE" | grep '^config-' | head -n 1)
version=$(sed -n "s/^VERSION=//p" "$GUARD" | head -n 1)
checker=$(sed -n "s/^GITLEAKS_CLEAN_CACHE_CHECKER_FORMAT=//p" "$GUARD" | head -n 1)
check 'a passing config leaves one marker holding the version and checker format' \
  test -n "$checker" -a "$markers:$(cat "$STORE/$m")" = "1:$version:$checker"
check 'the marker file mode is 600' test "$(mode_of "$STORE/$m")" = 600
printf 'old\n' >"$STORE/$m"
check 'a marker of another version re-checks and still caches' \
  test "$(scans_for 'ls -lb'):$(scans_for 'ls -lb')" = 1:0
check 'a stale marker is rewritten after the check passes' \
  test "$(cat "$STORE/$m")" = "$version:$checker"
printf '[extend]\npath = "%s"\n' "$CASE/other.toml" >"$CASE/marked.toml"
sum=$(sha256sum "$CASE/marked.toml" | cut -d' ' -f1)
printf 'old\n' >"$STORE/config-$sum"
check 'a marker of another version does not pass an extending config' \
  test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/marked.toml" scans_for 'ls -la'):$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/marked.toml" scans_for 'ls -la'):$(cat "$STORE/config-$sum")" = 1:1:old
# A marker from an older checker within the same release is checked again.
for stale in "$version" "$version:0" "$version:$((checker + 1))"; do
  printf '%s\n' "$stale" >"$STORE/config-$sum"
  check "a marker of checker [$stale] does not pass an extending config" \
    test "$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/marked.toml" scans_for 'ls -lc'):$(AGENT_GUARD_GITLEAKS_CONFIG="$CASE/marked.toml" scans_for 'ls -lc'):$(cat "$STORE/config-$sum")" = "1:1:$stale"
done
rm -f "$STORE/config-$sum"

# Other PreToolUse scans are not cached either: an Edit fragment and an MCP
# input are scanned on every event and store nothing.
reset
tool_status() {
  jq -nc --arg t "$1" --argjson i "$2" --arg d "$CASE/w" \
    '{tool_name:$t,tool_input:$i,cwd:$d,session_id:"clean-cache-tool"}' \
    | (cd "$CASE/w" && AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err")
  echo $?
}
edit='{"file_path":"'"$CASE"'/w/notes.txt","old_string":"a","new_string":"plain words"}'
before=$(scans)
tool_status Edit "$edit" >/dev/null
check 'a repeated Edit fragment passes' test "$(tool_status Edit "$edit")" = 0
check 'a repeated Edit fragment is scanned each time and never cached' \
  test "$(($(scans) - before)):$(entries)" = 2:0
mcp='{"query":"plain words"}'
before=$(scans)
tool_status mcp__demo__search "$mcp" >/dev/null
check 'a repeated MCP input passes' test "$(tool_status mcp__demo__search "$mcp")" = 0
check 'a repeated MCP input is scanned each time and never cached' \
  test "$(($(scans) - before)):$(entries)" = 2:0

# The directory stays bounded.
reset
bash_status 'ls -la' >/dev/null
f=$(entry_list)
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

#!/usr/bin/env sh
# agent-guard hook process-spawn benchmark (issue #407).
#
# Feeds a fixed set of representative hook events to
# `agent-guard hook-pre-tool` / `hook-post-tool` and records, per event:
#   - execve count by program basename (sh, gitleaks, jq, awk, sed, ...),
#   - processes created (each `$(...)` and pipeline stage is a forked `sh`,
#     which is what `ps` sampling sees as an "sh" process even without execve),
#   - user+sys CPU seconds of the whole hook process tree (getrusage
#     RUSAGE_CHILDREN, averaged over BENCH_RUNS runs without strace),
#   - the hook exit status, so deny cases are shown to still deny.
#
# It is a measurement, not a gate: it exits 0 whenever the tools exist.
# Requirements: strace, python3, jq, git. gitleaks: the real binary when
# BENCH_REAL_GITLEAKS=1 and one is on PATH; otherwise fake-gitleaks.c built
# with cc (native, spawns nothing, so the probe cache behaves as with a
# release binary); otherwise tests/fixtures/mock-gitleaks, whose #! line
# defeats the probe cache and whose own sh/cat are counted. Invocations are
# counted either way; with a stand-in, CPU excludes real scanning cost.
#
# Usage: sh bench/process-count/run.sh [output.tsv]
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
BIN=${AGENT_GUARD_BIN:-"$ROOT/plugins/agent-guard/bin/agent-guard"}
RUNS=${BENCH_RUNS:-5}
OUT_TSV=${1:-}

for tool in strace python3 jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "bench: $tool is required" >&2; exit 3; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-proc-bench.XXXXXX") || exit 3
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/bin" "$WORK/home" "$WORK/repo" "$WORK/trace" "$WORK/tmp" || exit 3
if [ "${BENCH_REAL_GITLEAKS:-0}" = 1 ] && command -v gitleaks >/dev/null 2>&1; then
  scanner=real
elif command -v cc >/dev/null 2>&1 \
    && cc -O2 -o "$WORK/bin/gitleaks" "$ROOT/bench/process-count/fake-gitleaks.c" 2>/dev/null; then
  scanner=native-fake
else
  cp "$ROOT/tests/fixtures/mock-gitleaks" "$WORK/bin/gitleaks" || exit 3
  chmod 755 "$WORK/bin/gitleaks"
  scanner=shell-mock
fi

# A private TMPDIR keeps concurrent runs (other suites, other benches) out of
# this run's files; strace already counts only this hook's process tree.
TMPDIR="$WORK/tmp"
HOME="$WORK/home"
PATH="$WORK/bin:$PATH"
AGENT_GUARD_GITLEAKS_CONFIG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
# The default (on) keeps the private state directory, which holds the
# gitleaks probe and deny-path regex caches every real hook relies on.
AGENT_GUARD_LOG_MODE=${BENCH_LOG_MODE:-on}
AGENT_GUARD_RELEASE_CHECK=off
AGENT_GUARD_HOOK_HOST=claude
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export TMPDIR HOME PATH AGENT_GUARD_GITLEAKS_CONFIG AGENT_GUARD_LOG_MODE \
  AGENT_GUARD_RELEASE_CHECK AGENT_GUARD_HOOK_HOST GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset AI_AGENT 2>/dev/null || :

# An ordinary git checkout: agents run inside repositories, so the
# PostToolUse mutation backstop is exercised the way it is in practice.
(
  cd "$WORK/repo" || exit 3
  git init -q
  git config user.email bench@example.invalid
  git config user.name bench
  printf '%s\n' '# demo' 'plain text line' >README.md
  printf '%s\n' 'print("hello")' >app.py
  git add . && git commit -q -m init
) || exit 3

# name <TAB> subcommand <TAB> expected-status <TAB> json
cat >"$WORK/events.tsv" <<'EVENTS'
pre-bash-ls	hook-pre-tool	0	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"ls"}}
pre-bash-git-status	hook-pre-tool	0	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"git status"}}
pre-bash-rg	hook-pre-tool	0	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"rg foo src"}}
pre-read-file	hook-pre-tool	0	{"session_id":"bench","tool_name":"Read","tool_input":{"file_path":"README.md"}}
pre-grep	hook-pre-tool	0	{"session_id":"bench","tool_name":"Grep","tool_input":{"pattern":"hello","path":"."}}
pre-write-clean	hook-pre-tool	0	{"session_id":"bench","tool_name":"Write","tool_input":{"file_path":"notes.txt","content":"just some notes"}}
post-bash-output	hook-post-tool	0	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"README.md\napp.py\n","stderr":"","interrupted":false}}
post-bash-empty	hook-post-tool	0	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"true"},"tool_response":{"stdout":"","stderr":"","interrupted":false}}
post-read-file	hook-post-tool	0	{"session_id":"bench","tool_name":"Read","tool_input":{"file_path":"README.md"},"tool_response":{"type":"text","file":{"filePath":"README.md","content":"# demo\nplain text line\n"}}}
post-edit-clean	hook-post-tool	0	{"session_id":"bench","tool_name":"Edit","tool_input":{"file_path":"app.py","old_string":"hello","new_string":"hi"},"tool_response":{"filePath":"app.py"}}
deny-pre-read-env	hook-pre-tool	2	{"session_id":"bench","tool_name":"Read","tool_input":{"file_path":".env.local"}}
deny-pre-bash-cat-env	hook-pre-tool	2	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"cat .env"}}
deny-pre-write-secret	hook-pre-tool	2	{"session_id":"bench","tool_name":"Write","tool_input":{"file_path":"app.txt","content":"AGENT_GUARD_TEST_SECRET"}}
mask-post-bash-secret	hook-post-tool	0	{"session_id":"bench","tool_name":"Bash","tool_input":{"command":"echo x"},"tool_response":{"stdout":"token AGENT_GUARD_TEST_SECRET here\n","stderr":"","interrupted":false}}
EVENTS

cat >"$WORK/rusage.py" <<'PY'
import resource, subprocess, sys
runs, sub, payload_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
payload = open(payload_path, 'rb').read()
argv = sys.argv[4:] + [sub]
before = resource.getrusage(resource.RUSAGE_CHILDREN)
for _ in range(runs):
    subprocess.run(argv, input=payload, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
after = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
print("%.4f" % (cpu / runs))
PY

# Every event starts from a clean checkout; the Edit event then reports a
# real (secret-free) modification of app.py, as the host would after an edit.
reset_repo() {
  (cd "$WORK/repo" && git checkout -q -- . && git clean -qfd) >/dev/null 2>&1
  case "$1" in
    *-edit-*) printf '%s\n' 'print("hi")' >"$WORK/repo/app.py" ;;
  esac
}

progs='sh gitleaks jq awk sed grep git cat tr mktemp rm cksum od head wc'
tab=$(printf '\t')
{
  printf 'event\tstatus\texpected\texecve_total\tprocesses'
  for p in $progs; do printf '\t%s' "$p"; done
  printf '\tother\tcpu_s\n'
} >"$WORK/result.tsv"

while IFS="$tab" read -r name sub expected json; do
  [ -n "$name" ] || continue
  printf '%s' "$json" >"$WORK/payload.json"
  # Warm the per-user gitleaks probe cache once so steady-state cost is
  # measured (the probe runs once per binary identity in practice).
  reset_repo "$name"
  (cd "$WORK/repo" && "$BIN" "$sub" <"$WORK/payload.json" >/dev/null 2>&1)
  reset_repo "$name"
  trace="$WORK/trace/$name"
  rm -rf "$trace" && mkdir -p "$trace"
  # -ff writes one file per process, so every fork is one file and no
  # execve line is split into unfinished/resumed halves.
  (cd "$WORK/repo" && strace -ff -qq -s 160 -e trace=execve -o "$trace/p" \
      "$BIN" "$sub" <"$WORK/payload.json" >/dev/null 2>&1)
  status=$?
  reset_repo "$name"
  cpu=$(cd "$WORK/repo" && python3 "$WORK/rusage.py" "$RUNS" "$sub" "$WORK/payload.json" "$BIN")
  # Successful execve calls only, by program basename.
  cat "$trace"/p.* | sed -n 's/^execve("\([^"]*\)".*= 0$/\1/p' | sed 's#.*/##' >"$WORK/execs"
  total=$(wc -l <"$WORK/execs" | tr -d ' ')
  # Processes created, the hook itself excluded: forked subshells included.
  forks=$(($(find "$trace" -type f | wc -l) - 1))
  line="$name$tab$status$tab$expected$tab$total$tab$forks"
  known=0
  for p in $progs; do
    c=$(grep -cx "$p" "$WORK/execs")
    known=$((known + c))
    line="$line$tab$c"
  done
  line="$line$tab$((total - known))$tab$cpu"
  printf '%s\n' "$line" >>"$WORK/result.tsv"
  # BENCH_KEEP_TRACE=DIR keeps each event's per-process strace files.
  [ -z "${BENCH_KEEP_TRACE:-}" ] || cp -R "$trace" "$BENCH_KEEP_TRACE/$name"
done <"$WORK/events.tsv"

printf '# scanner=%s runs=%s log_mode=%s engine=%s\n' "$scanner" "$RUNS" "$AGENT_GUARD_LOG_MODE" "$BIN"
column -t -s "$tab" "$WORK/result.tsv" 2>/dev/null || cat "$WORK/result.tsv"
awk -F '\t' 'NR > 1 && $2 != $3 { printf "MISMATCH: %s exited %s, expected %s\n", $1, $2, $3 }' "$WORK/result.tsv"
[ -z "$OUT_TSV" ] || cp "$WORK/result.tsv" "$OUT_TSV"
exit 0

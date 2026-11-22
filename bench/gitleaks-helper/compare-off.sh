#!/bin/sh
# The hook must answer and start processes the same way whatever the state of
# the opt-in warm gitleaks helper (#537, #581). Runs each fixture under strace
# and compares exit code, stdout, stderr, the number of programs executed (a
# watchdog's sleep excluded: it may be killed before it execs) and the number
# of processes forked. Linux only (strace 5.2 or later).
#
# Always: this tree with AGENT_GUARD_GITLEAKS_HELPER unset against this tree
# with it pointing at a missing client. A change to the hook that has nothing
# to do with the helper changes both runs alike and passes.
#
# With a base checkout: also this tree against the base, both with the helper
# unset. The default path must cost what it did, so a change that adds work
# there fails. The caller passes a base only when the pull request touches the
# helper call sites (.github/scripts/helper-call-sites.sh).
#
#   sh bench/gitleaks-helper/compare-off.sh /abs/gitleaks [/abs/base-checkout]
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
REAL=${1:?gitleaks required}
BASE=
if [ -n "${2:-}" ]; then
  BASE=$(CDPATH= cd -- "$2" && pwd -P) || exit 1
fi
for tool in strace jq git; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'required tool missing: %s\n' "$tool" >&2; exit 1; }
done
CASE=$(mktemp -d /tmp/aghoff.XXXXXX) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$CASE/bin" "$CASE/empty" "$CASE/fx" "$CASE/work" || exit 1
cp "$REAL" "$CASE/bin/gitleaks" || exit 1
export PATH="$CASE/bin:$PATH" AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/empty" AGENT_GUARD_RELEASE_CHECK=off
unset AGENT_GUARD_GITLEAKS_HELPER AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_GITLEAKS_CONFIG
pat="gh""p_$(printf 'a1B2c3D4e5F6g7H8i9J0a1B2c3D4e5F6g7H8')"
i=0
fx() { i=$((i + 1)); printf '%s\t%s\n' "$1" "$2" >"$CASE/fx/$i"; }
fx hook-pre-tool "$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la src"}}')"
fx hook-pre-tool "$(jq -nc --arg c "echo $pat" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')"
fx hook-pre-tool "$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"cat .env"}}')"
fx hook-pre-tool "$(jq -nc --arg c "token=$pat" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:"a.txt",content:$c}}')"
fx hook-pre-tool "$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:"a.py",old_string:"x",new_string:"y = 1\n"}}')"
fx hook-pre-tool "$(jq -nc '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:"README.md"}}')"
fx hook-pre-tool "$(jq -nc '{hook_event_name:"SomethingNew",x:1}')"
fx hook-post-tool "$(jq -nc --arg o "out $pat" '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"env"},tool_response:{stdout:$o,stderr:"",interrupted:false}}')"
fx hook-post-tool "$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"ls"},tool_response:{stdout:"a\nb\n",stderr:"",interrupted:false}}')"
fx hook-post-tool "$(jq -nc '{hook_event_name:"PostToolUse",tool_name:"Read",tool_input:{file_path:"a"},tool_response:{type:"text",file:{filePath:"a",content:"hello\n"}}}')"
fx hook-user-prompt "$(jq -nc --arg p "use $pat" '{hook_event_name:"UserPromptSubmit",prompt:$p}')"
fx hook-user-prompt "$(jq -nc '{hook_event_name:"UserPromptSubmit",prompt:"summarize the README"}')"
fx hook-session-start "$(jq -nc '{hook_event_name:"SessionStart",source:"startup"}')"
fx hook-stop "$(jq -nc '{hook_event_name:"Stop"}')"
# The Git pre-commit and GitHub Action entry points: a staged change, and a
# directory scan (first word: the command, the rest: its arguments).
fx scan-staged '{}'
fx 'scan-path -- .' '{}'
git init -q "$CASE/work" && printf 'tracked\n' >"$CASE/work/t.txt" && git -C "$CASE/work" add t.txt \
  && git -C "$CASE/work" -c user.email=b@example.test -c user.name=b commit -qm base && printf 'changed\n' >>"$CASE/work/t.txt" \
  && printf 'token=%s\n' "$pat" >"$CASE/work/staged.txt" && git -C "$CASE/work" add staged.txt || exit 1
run() { # $1 cli, $2 fixture, $3 host, $4 log mode, $5 helper env, $6 out prefix
  cmd=$(cut -f1 "$2")
  set -f
  rm -rf "$CASE/home" "$CASE/xs"
  mkdir -p "$CASE/home" "$CASE/xs"
  cut -f2- "$2" | (cd "$CASE/work" && env HOME="$CASE/home" XDG_STATE_HOME="$CASE/xs" \
    AGENT_GUARD_HOOK_HOST="$3" AGENT_GUARD_LOG_MODE="$4" ${5:+AGENT_GUARD_GITLEAKS_HELPER="$5"} \
    strace -f -qq -e trace=execve,clone,clone3,fork,vfork -e status=successful -o "$6.trace" \
      "$1/plugins/agent-guard/bin/agent-guard" $cmd >"$6.out" 2>"$6.err")
  status=$?
  set +f
  echo "$status" >"$6.status"
  # Messages may name the CLI's own absolute path (setup hints); the base and
  # this tree live in different directories, so compare that path as one
  # placeholder. Files without the path stay byte for byte as written.
  for part in out err; do
    grep -qF -- "$1" "$6.$part" || continue
    CLI_ROOT=$1 LC_ALL=C awk 'BEGIN { root = ENVIRON["CLI_ROOT"] } {
      out = ""
      while ((at = index($0, root)) > 0) { out = out substr($0, 1, at - 1) "<cli-root>"; $0 = substr($0, at + length(root)) }
      print out $0
    }' "$6.$part" >"$6.$part.n" && mv "$6.$part.n" "$6.$part"
  done
  # A watchdog's sleep may be killed before it execs; count every other program.
  grep 'execve("' "$6.trace" | grep -vc 'execve("[^"]*/sleep"' >"$6.execs"
  [ "$(cat "$6.execs")" -gt 0 ] || { printf 'no programs traced: %s\n' "$6" >&2; exit 1; }
  # Threads (CLONE_THREAD, e.g. gitleaks's Go runtime) are not processes.
  grep -E '(clone3?|v?fork)\(' "$6.trace" | grep -vc CLONE_THREAD >"$6.forks"
}
programs() { grep 'execve("' "$1" | grep -v 'execve("[^"]*/sleep"' | sed 's/^[0-9]* *execve("\([^"]*\)".*/\1/' | sort | uniq -c | sed "s|$2|<cli-root>|"; }
# The first hook run in the fresh work tree also refreshes its Git index; run
# each CLI once first so every measured run starts from the same tree state.
run "$ROOT" "$CASE/fx/1" claude on "" "$CASE/warm"
[ -z "$BASE" ] || run "$BASE" "$CASE/fx/1" claude on "" "$CASE/warm"
# $1 titles the comparison; the other six name the two sides, each as a
# label, a CLI checkout and a helper variable. Returns 1 on any difference.
compare() {
  title=$1 a_name=$2 a_cli=$3 a_helper=$4 b_name=$5 b_cli=$6 b_helper=$7
  total=0 differ=0 a_execs=0 b_execs=0 a_forks=0 b_forks=0
  for f in "$CASE"/fx/*; do
    for host in claude codex; do
      for log in on off; do
        run "$a_cli" "$f" "$host" "$log" "$a_helper" "$CASE/a"
        run "$b_cli" "$f" "$host" "$log" "$b_helper" "$CASE/b"
        total=$((total + 1))
        a_execs=$((a_execs + $(cat "$CASE/a.execs")))
        b_execs=$((b_execs + $(cat "$CASE/b.execs")))
        a_forks=$((a_forks + $(cat "$CASE/a.forks")))
        b_forks=$((b_forks + $(cat "$CASE/b.forks")))
        for part in status out err execs forks; do
          if ! cmp -s "$CASE/a.$part" "$CASE/b.$part"; then
            differ=$((differ + 1))
            printf 'DIFFER %s fixture %s host %s log %s (%s / %s): %s / %s\n' "$part" "${f##*/}" "$host" "$log" "$a_name" "$b_name" \
              "$(head -c 200 "$CASE/a.$part")" "$(head -c 200 "$CASE/b.$part")"
            [ "$part" != execs ] || { programs "$CASE/a.trace" "$a_cli" >"$CASE/a.programs"; programs "$CASE/b.trace" "$b_cli" >"$CASE/b.programs"; diff "$CASE/a.programs" "$CASE/b.programs" | sed 's/^/  /'; }
            break
          fi
        done
      done
    done
  done
  printf '%s: comparisons: %s; differences: %s; programs executed: %s %s, %s %s; processes forked: %s %s, %s %s\n' \
    "$title" "$total" "$differ" "$a_name" "$a_execs" "$b_name" "$b_execs" "$a_name" "$a_forks" "$b_name" "$b_forks"
  [ "$differ" = 0 ]
}
rc=0
compare 'same tree' unset "$ROOT" '' unusable "$ROOT" "$CASE/missing-client" || rc=1
if [ -n "$BASE" ]; then
  compare 'base and this tree, helper unset' base "$BASE" '' 'this tree' "$ROOT" '' || rc=1
fi
exit "$rc"

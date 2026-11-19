#!/bin/sh
# #537: with the helper off, a hook must answer and start processes exactly as
# the given base checkout (main) does. Runs each fixture through both CLIs
# under strace and compares exit code, stdout, stderr and the number of
# programs executed (a watchdog's sleep excluded: it may be killed before it
# execs). Linux only (strace 5.2 or later).
#
#   sh bench/gitleaks-helper/compare-off.sh /abs/main-checkout /abs/gitleaks
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
BASE=${1:?base checkout required}
REAL=${2:?gitleaks required}
CASE=$(mktemp -d /tmp/aghoff.XXXXXX) || exit 1
trap 'rm -rf "$CASE"' 0 HUP INT TERM
mkdir -p "$CASE/bin" "$CASE/empty" "$CASE/fx" "$CASE/work"
cp "$REAL" "$CASE/bin/gitleaks"
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
git init -q "$CASE/work" && printf 'tracked\n' >"$CASE/work/t.txt" && git -C "$CASE/work" add t.txt \
  && git -C "$CASE/work" -c user.email=b@example.test -c user.name=b commit -qm base && printf 'changed\n' >>"$CASE/work/t.txt"
run() { # $1 cli, $2 fixture, $3 host, $4 log mode, $5 helper env, $6 out prefix
  cmd=$(cut -f1 "$2")
  rm -rf "$CASE/home" "$CASE/xs"
  mkdir -p "$CASE/home" "$CASE/xs"
  cut -f2- "$2" | (cd "$CASE/work" && env HOME="$CASE/home" XDG_STATE_HOME="$CASE/xs" \
    AGENT_GUARD_HOOK_HOST="$3" AGENT_GUARD_LOG_MODE="$4" ${5:+AGENT_GUARD_GITLEAKS_HELPER="$5"} \
    strace -f -qq -e trace=execve -e status=successful -o "$6.trace" \
      "$1/plugins/agent-guard/bin/agent-guard" "$cmd" >"$6.out" 2>"$6.err")
  echo "$?" >"$6.status"
  # A watchdog's sleep may be killed before it execs; count every other program.
  grep 'execve("' "$6.trace" | grep -vc 'execve("[^"]*/sleep"' >"$6.execs"
}
# The first hook run in the fresh work tree also refreshes its Git index; run
# each CLI once first so every measured run starts from the same tree state.
run "$BASE" "$CASE/fx/1" claude on "" "$CASE/warm"
run "$ROOT" "$CASE/fx/1" claude on "" "$CASE/warm"
programs() { grep 'execve("' "$1" | grep -v 'execve("[^"]*/sleep"' | sed 's/^[0-9]* *execve("\([^"]*\)".*/\1/' | sort | uniq -c; }
total=0 differ=0 base_execs=0 head_execs=0
for f in "$CASE"/fx/*; do
  for host in claude codex; do
    for log in on off; do
      for helper in '' "$CASE/missing-client"; do
        run "$BASE" "$f" "$host" "$log" "" "$CASE/b"
        run "$ROOT" "$f" "$host" "$log" "$helper" "$CASE/h"
        total=$((total + 1))
        base_execs=$((base_execs + $(cat "$CASE/b.execs")))
        head_execs=$((head_execs + $(cat "$CASE/h.execs")))
        for part in status out err execs; do
          if ! cmp -s "$CASE/b.$part" "$CASE/h.$part"; then
            differ=$((differ + 1))
            printf 'DIFFER %s fixture %s host %s log %s helper %s: %s\n' "$part" "${f##*/}" "$host" "$log" "${helper:-unset}" \
              "$(cat "$CASE/b.$part" | head -c 200) / $(cat "$CASE/h.$part" | head -c 200)"
            [ "$part" != execs ] || { programs "$CASE/b.trace" >"$CASE/b.programs"; programs "$CASE/h.trace" >"$CASE/h.programs"; diff "$CASE/b.programs" "$CASE/h.programs" | sed 's/^/  /'; }
            break
          fi
        done
      done
    done
  done
done
printf 'runs: %s; differences: %s; programs executed: base %s, this tree %s\n' "$total" "$differ" "$base_execs" "$head_execs"
[ "$differ" = 0 ]

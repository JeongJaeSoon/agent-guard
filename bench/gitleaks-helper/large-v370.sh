#!/bin/sh
# #537 criterion 5 without Docker: large (>256 KiB) hook inputs through the
# published v3.7.0 CLI, this branch with the helper off, and this branch with a
# warm helper, all with the same official gitleaks. Reports the median wall time
# of 7 runs, and from one strace run the bytes every process read and wrote
# (the copy cost) and the programs executed. Synthetic clean inputs only, under
# a temporary HOME.
# bench/fused-output/run-constrained.sh needs Docker with enforced cgroup limits;
# this runs the same public v3.7.0 release directly, Linux with strace.
#
#   sh bench/gitleaks-helper/large-v370.sh /abs/v3.7.0-tarball-root /abs/checkout \
#     /abs/gitleaks /abs/helper-build-dir
# The v3.7.0 root is the extracted agent-guard-3.7.0.tar.gz release asset
# (SHA-256 d6ff2d398643f789d0259c782f7760504836f4495471dba613e3abc46dc2bf3d).
set -eu
V370=$1 BRANCH=$2 GL=$3 HDIR=$4
CASE=$(mktemp -d /tmp/aglv.XXXXXX)
trap 'pkill -f "$CASE/lib/agent-guard-gitleaks-helper" 2>/dev/null || true; rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$CASE/bin" "$CASE/lib" "$CASE/empty" "$CASE/work"
cp "$GL" "$CASE/bin/gitleaks"
cp "$HDIR/agent-guard-scan" "$HDIR/agent-guard-gitleaks-helper" "$CASE/lib/"
git init -q "$CASE/work"
export PATH="$CASE/bin:$PATH" AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/empty" AGENT_GUARD_RELEASE_CHECK=off
unset AGENT_GUARD_GITLEAKS_HELPER AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_GITLEAKS_CONFIG AGENT_GUARD_LOG_MODE
# Clean synthetic text: words and numbers, no secret-shaped tokens.
python3 -I - "$CASE" <<'EOF'
import json, sys
case = sys.argv[1]
line = "the quick brown fox jumps over the lazy dog 0123456789 lorem ipsum dolor sit amet\n"
for size, tag in ((300 * 1024, "300k"), (1024 * 1024, "1m")):
    body = (line * (size // len(line) + 1))[:size]
    with open(f"{case}/pre-{tag}.json", "w") as f:
        json.dump({"hook_event_name": "PreToolUse", "tool_name": "Write",
                   "tool_input": {"file_path": "big.txt", "content": body}}, f)
    with open(f"{case}/post-{tag}.json", "w") as f:
        json.dump({"hook_event_name": "PostToolUse", "tool_name": "Bash",
                   "tool_input": {"command": "cat big.txt"},
                   "tool_response": {"stdout": body, "stderr": "", "interrupted": False}}, f)
EOF
hookcmd() { case "$1" in pre-*) echo hook-pre-tool ;; post-*) echo hook-post-tool ;; esac; }
run_one() { # $1 variant, $2 fixture, $3 home -> runs once
  helper=
  case "$1" in v370) cli=$V370/bin/agent-guard ;; off) cli=$BRANCH/plugins/agent-guard/bin/agent-guard ;;
    warm) cli=$BRANCH/plugins/agent-guard/bin/agent-guard helper=$CASE/lib/agent-guard-scan ;; esac
  (cd "$CASE/work" && env HOME="$3/home" XDG_STATE_HOME="$3/xs" AGENT_GUARD_HOOK_HOST=claude \
    ${helper:+AGENT_GUARD_GITLEAKS_HELPER="$helper"} "$cli" "$(hookcmd "$2")" <"$CASE/$2.json" >"$3/out" 2>"$3/err") \
    && echo 0 >"$3/status" || echo "$?" >"$3/status"
}
printf 'variant\tfixture\tstatus\tmedian_ms\tbytes_rw_MiB\tof_which_helper_MiB\tprograms\n'
for fx in pre-300k pre-1m post-300k post-1m; do
  for v in v370 off warm; do
    # One helper at a time: stop the previous case's before its state goes.
    pkill -f "$CASE/lib/agent-guard-gitleaks-helper" 2>/dev/null || true
    sleep 0.2
    H=$CASE/h-$v; rm -rf "$H"; mkdir -p "$H/home" "$H/xs"; chmod 700 "$H/xs"
    run_one "$v" "$fx" "$H"; run_one "$v" "$fx" "$H"   # warm caches (and the helper) first
    [ "$v" != warm ] || sleep 1
    times=
    for i in 1 2 3 4 5 6 7; do
      t0=$(date +%s%N); run_one "$v" "$fx" "$H"; t1=$(date +%s%N)
      times="$times $(( (t1 - t0) / 1000000 ))"
    done
    med=$(printf '%s\n' $times | sort -n | sed -n 4p)
    # The warm helper runs outside the hook's process tree (an earlier hook
    # started it), so trace it too while the counted hook runs.
    helper_pid=
    if [ "$v" = warm ]; then
      # Matched by its state directory. None runs when the hook calls no
      # gitleaks (an output over the scan cap takes the whole-output path).
      helper_pid=$(pgrep -f -- "--state-dir $H/xs/" | head -n 1 || true)
      if [ -n "$helper_pid" ]; then
        # -f: a Go program does its socket I/O on other threads than the main
        # one, which a plain -p attach would not see.
        strace -f -qq -p "$helper_pid" -e trace=read,write,pread64,pwrite64,readv,writev -e status=successful \
          -o "$H/trace.helper" 2>"$H/trace.helper.err" &
        tracer=$!
        sleep 0.5
        kill -0 "$tracer" 2>/dev/null || { echo "cannot trace the warm helper ($fx): $(cat "$H/trace.helper.err")" >&2; exit 1; }
      fi
    fi
    strace_run() {
      helper=
      case "$v" in v370) cli=$V370/bin/agent-guard ;; off) cli=$BRANCH/plugins/agent-guard/bin/agent-guard ;;
        warm) cli=$BRANCH/plugins/agent-guard/bin/agent-guard helper=$CASE/lib/agent-guard-scan ;; esac
      (cd "$CASE/work" && env HOME="$H/home" XDG_STATE_HOME="$H/xs" AGENT_GUARD_HOOK_HOST=claude \
        ${helper:+AGENT_GUARD_GITLEAKS_HELPER="$helper"} \
        strace -f -qq -e trace=read,write,pread64,pwrite64,readv,writev,execve -e status=successful -o "$H/trace" \
        "$cli" "$(hookcmd "$fx")" <"$CASE/$fx.json" >/dev/null 2>&1) && echo 0 >"$H/status" || echo "$?" >"$H/status"
    }
    strace_run
    : >"$H/trace.helper.done"
    if [ -n "$helper_pid" ]; then
      sleep 0.5
      kill "$tracer" 2>/dev/null || true
      wait "$tracer" 2>/dev/null || true
      cat "$H/trace.helper" >"$H/trace.helper.done" 2>/dev/null || true
    fi
    # Every process: the hook's tree plus, when warm, the helper. The status
    # column is the counted (traced) run's exit status.
    sum_io='/^([0-9]+ +)?(read|write|pread64|pwrite64|readv|writev)\(/ { n = $NF; if (n ~ /^[0-9]+$/) s += n } END { printf "%.2f", s / 1048576 }'
    bytes=$(cat "$H/trace" "$H/trace.helper.done" | awk "$sum_io")
    if [ -n "$helper_pid" ]; then
      [ -s "$H/trace.helper.done" ] || { echo "the warm helper trace is empty ($fx)" >&2; exit 1; }
      helper_bytes=$(awk "$sum_io" "$H/trace.helper.done")
    else
      helper_bytes=-   # no helper: this hook ran no gitleaks
    fi
    progs=$(grep -c 'execve("' "$H/trace" || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$v" "$fx" "$(cat "$H/status")" "$med" "$bytes" "$helper_bytes" "$progs"
  done
done

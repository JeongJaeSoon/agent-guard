#!/usr/bin/env sh
# agent-guard hook instruction count: base tree versus head tree.
#
# Runs a fixed set of synthetic hook events once per tree under callgrind and
# records the instructions executed by the shell itself: the top-level shell
# and the subshells it forks (--dump-before=fork), but not programs it execs
# (--trace-children=no), so jq, awk, git and gitleaks are not counted; a
# forked child that then execs may lose its few instructions before the exec.
# Measured run to run on one tree: `version` within a dozen instructions,
# hook events within a few thousand (timing-dependent waits), far below
# wall-clock noise on a shared runner.
#
# The shell parses the whole script for every hook, so a change adds parse
# cost even to hooks that never run the changed code. The `version` command
# runs almost nothing after the parse; its change estimates that script-size
# cost, and each event's change is split into that estimate and the rest.
#
# It is a measurement, not a gate: an increase never changes the exit status.
# Exit 0 when every event was measured in both trees; exit 3 when a tool is
# missing or a run produced no count, so "could not measure" is never
# reported as "no change".
#
# Requirements: valgrind, jq, git, awk, cc (for the process-free gitleaks
# stand-in, else the shell mock). /bin/sh should be dash, as on Ubuntu, so
# the counts describe the shell hooks run under there.
#
# Usage: sh bench/instruction-count/run.sh BASE_ROOT HEAD_ROOT OUT_TSV
#        sh bench/instruction-count/run.sh --render TSV
# BASE_ROOT and HEAD_ROOT are repository checkouts. --render prints the
# Markdown table for a TSV this script wrote (or a synthetic one in tests).
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)

# TSV columns: event, command, base count, head count, base status, head
# status, output (same|different). The row named `version` is the
# script-size reference and must come first.
render() {
  awk -F '\t' '
    function abs(v) { return v < 0 ? -v : v }
    function pct(d, b) { return b > 0 ? sprintf("%+.2f%%", 100 * d / b) : "n/a" }
    function num(v,   s, sign, out) {
      sign = v < 0 ? "-" : (v > 0 ? "+" : "")
      s = sprintf("%d", abs(v)); out = ""
      while (length(s) > 3) { out = "," substr(s, length(s) - 2) out; s = substr(s, 1, length(s) - 3) }
      return sign s out
    }
    function plain(v) { return substr(num(v), 1, 1) == "+" ? substr(num(v), 2) : num(v) }
    NR == 1 && $1 != "version" { print "render: the first row must be the version reference" > "/dev/stderr"; bad = 1; exit 3 }
    NR == 1 { ref = $4 - $3 }
    {
      name[NR] = $1; cmd[NR] = $2; b[NR] = $3; h[NR] = $4
      st[NR] = ($5 == $6 ? $5 : $5 " → " $6); out[NR] = ($7 == "same" ? "같음" : "**다름**")
      n = NR
    }
    END {
      if (bad) exit 3
      print "| 이벤트 | 명령 | base | head | 차이 | 스크립트 크기 몫(추정) | 나머지 | 분류 | 종료 코드 | 출력 |"
      print "|---|---|---:|---:|---:|---:|---:|---|---|---|"
      for (i = 1; i <= n; i++) {
        d = h[i] - b[i]
        if (i == 1) {
          share = d; rest = 0; kind = "스크립트 크기 기준"
        } else {
          share = ref; rest = d - ref
          # The allowance covers run-to-run noise (a few thousand) and path
          # work that scales with the parse. An unchanged script (version
          # within its own noise) is no change, not a script-size cost.
          tol = b[i] * 0.0005; if (tol < 20000) tol = 20000
          if (abs(rest) <= tol && abs(ref) <= 100) kind = "변화 없음"
          else if (abs(rest) <= tol) kind = "스크립트 크기만"
          else if (rest > 0) kind = "**실행 코드 증가**"
          else kind = "실행 코드 감소"
        }
        printf "| %s | %s | %s | %s | %s (%s) | %s | %s | %s | %s | %s |\n", \
          name[i], cmd[i], plain(b[i]), plain(h[i]), num(d), pct(d, b[i]), \
          num(share), num(rest), kind, st[i], out[i]
      }
    }
  ' "$1"
}

if [ "${1:-}" = --render ]; then
  [ "$#" -eq 2 ] && [ -f "$2" ] || { echo "usage: run.sh --render TSV" >&2; exit 2; }
  render "$2"
  exit $?
fi

[ "$#" -eq 3 ] || { echo "usage: run.sh BASE_ROOT HEAD_ROOT OUT_TSV" >&2; exit 2; }
for tool in valgrind jq git awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "bench: $tool is required" >&2; exit 3; }
done
for tree in "$1" "$2"; do
  [ -f "$tree/plugins/agent-guard/bin/agent-guard" ] \
    || { echo "bench: $tree has no plugins/agent-guard/bin/agent-guard" >&2; exit 3; }
done
OUT_TSV=$3

WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-ir-bench.XXXXXX") || exit 3
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK/bin" "$WORK/in" "$WORK/repo" "$WORK/t" || exit 3

# Path lengths reach the count (every expansion of a path is copied), so both
# plugins are copied to paths of the same length.
cp -R "$1/plugins/agent-guard" "$WORK/t/base" || exit 3
cp -R "$2/plugins/agent-guard" "$WORK/t/head" || exit 3

if command -v cc >/dev/null 2>&1 \
    && cc -O2 -o "$WORK/bin/gitleaks" "$ROOT/bench/process-count/fake-gitleaks.c" 2>/dev/null; then
  :
else
  cp "$ROOT/tests/fixtures/mock-gitleaks" "$WORK/bin/gitleaks" && chmod 755 "$WORK/bin/gitleaks" || exit 3
fi

(
  cd "$WORK/repo" || exit 3
  git init -q
  git config user.email bench@example.invalid
  git config user.name bench
  printf '%s\n' '# demo' 'plain text line' >README.md
  printf '%s\n' "const mode = 'old';" >app.js
  git add . && git commit -q -m init
) || exit 3

# Synthetic events only. dense-controls is the Performance evidence fixture of
# the same name (40,000 "a" + U+001F pairs and one literal assignment).
awk 'BEGIN {
  printf "{\"tool_name\":\"mcp__latency__read\",\"tool_response\":\""
  for (i = 0; i < 40000; i++) printf "a\\u001f"
  printf " API_KEY=perf-literal-tail\"}"
}' >"$WORK/in/dense-controls" || exit 3
printf '%s' '{"session_id":"bench","tool_name":"Edit","tool_input":{"file_path":"app.js","old_string":"const mode = '"'old'"';","new_string":"const mode = '"'new'"';"}}' \
  >"$WORK/in/pre-edit" || exit 3
# One command line of many short commands joined by control operators.
awk 'BEGIN {
  printf "{\"session_id\":\"bench\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\""
  for (i = 0; i < 40; i++) printf "printf %s | cat && test -f app.js; ", "step" i
  printf "true\"}}"
}' >"$WORK/in/pre-bash-repeated" || exit 3
awk 'BEGIN {
  printf "{\"session_id\":\"bench\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\"},\"tool_response\":{\"stdout\":\""
  for (i = 0; i < 200; i++) printf "ordinary status: build passed\\n"
  printf "\",\"stderr\":\"\",\"interrupted\":false,\"isImage\":false}}"
}' >"$WORK/in/post-bash" || exit 3
printf '%s' '{"session_id":"bench","prompt":"summarize the build log"}' >"$WORK/in/prompt" || exit 3
: >"$WORK/in/version"
for f in dense-controls pre-edit pre-bash-repeated post-bash prompt; do
  jq -e . "$WORK/in/$f" >/dev/null 2>&1 || { echo "bench: generated $f is not JSON" >&2; exit 3; }
done

# measure TREE COMMAND EVENT -> "count<TAB>status<TAB>output checksum"
measure() {
  run=$(mktemp -d "$WORK/run.XXXXXX") || return 3
  mkdir -p "$run/home" "$run/tmp" "$run/cg" || return 3
  (cd "$WORK/repo" && git checkout -q -- . && git clean -qfd) >/dev/null 2>&1 || return 3
  (
    cd "$WORK/repo" || exit 3
    env -i PATH="$WORK/bin:/usr/local/bin:/usr/bin:/bin" HOME="$run/home" TMPDIR="$run/tmp" \
      LANG=C LC_ALL=C GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_HOOK_HOST=claude \
      AGENT_GUARD_GITLEAKS_BIN="$WORK/bin/gitleaks" \
      AGENT_GUARD_GITLEAKS_CONFIG="$WORK/t/$1/config/gitleaks.toml" \
      valgrind --tool=callgrind --trace-children=no --dump-before=fork --dump-before=_Fork \
        --callgrind-out-file="$run/cg/out.%p" --log-file="$run/valgrind.log" \
        /bin/sh "$WORK/t/$1/bin/agent-guard" "$2" <"$WORK/in/$3" >"$run/stdout" 2>"$run/stderr"
  )
  status=$?
  count=$(cat "$run/cg"/out.* 2>/dev/null | awk '/^summary:/ { s += $2; n++ } END { if (n) printf "%d", s }')
  if [ -z "$count" ]; then
    echo "bench: $1 $3 produced no callgrind count (status $status)" >&2
    sed -n '1,20p' "$run/valgrind.log" >&2 2>/dev/null
    return 3
  fi
  sum=$(cat "$run/stdout" "$run/stderr" | cksum | awk '{ print $1 "-" $2 }')
  printf '%s\t%s\t%s\n' "$count" "$status" "$sum"
  rm -rf "$run"
}

tab=$(printf '\t')
: >"$OUT_TSV" || exit 3
for row in version:version dense-controls:hook-post-tool pre-edit:hook-pre-tool \
    pre-bash-repeated:hook-pre-tool post-bash:hook-post-tool prompt:hook-user-prompt; do
  event=${row%%:*} cmd=${row#*:}
  b=$(measure base "$cmd" "$event") || exit 3
  h=$(measure head "$cmd" "$event") || exit 3
  bc=${b%%"$tab"*} brest=${b#*"$tab"} bs=${brest%%"$tab"*} bsum=${brest#*"$tab"}
  hc=${h%%"$tab"*} hrest=${h#*"$tab"} hs=${hrest%%"$tab"*} hsum=${hrest#*"$tab"}
  same=different
  [ "$bsum" = "$hsum" ] && same=same
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$event" "$cmd" "$bc" "$hc" "$bs" "$hs" "$same" >>"$OUT_TSV" || exit 3
done
exit 0

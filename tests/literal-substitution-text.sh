#!/bin/sh
# 94S-1712: a backquote or `$(` inside a single-quoted word or a quoted-
# delimiter here-document is text to the shell that parses the command, so the
# deny patterns must not read it as a command substitution when only a command
# that treats the text as data (echo, cat, tee, a gh or git commit message)
# receives it. A double-quoted word or an unquoted delimiter still substitutes
# and stays blocked, and so does every body or argument that a shell, eval,
# ssh, xargs, trap, an interpreter or a pipe into one may run.
# Synthetic hook inputs only: none of the commands is executed. The cases live
# in tests/fixtures/literal-substitution-text.txt and are assembled at run
# time, so neither the repository's secret scan nor a live guard hook reads a
# deny-pattern match in either file. Each case runs for the Claude and the
# Codex payload shape.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
FIXTURE="$ROOT/tests/fixtures/literal-substitution-text.txt"
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-literal-subst.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0 HUP INT TERM
mkdir "$CASE/home" "$CASE/w"
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_OUTPUT_REDACT AI_AGENT
pass=0 fail=0 n=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$1"; }

BT=$(printf '\140')
DP=$(printf '%s(' '$')
E=$(printf '%s%s' en v)
PE=$(printf '%s%s' print "$E")
TAB=$(printf '\t')

expand() {
  printf '%s' "$1" | BT=$BT DP=$DP E=$E PE=$PE TAB=$TAB LC_ALL=C awk '
    { line = line (NR > 1 ? "\n" : "") $0 }
    END {
      n = split("BT DP PE E TAB", k, " ")
      for (i = 1; i <= n; i++) {
        tok = "{" k[i] "}"; val = ENVIRON[k[i]]; out = ""
        while ((p = index(line, tok)) > 0) {
          out = out substr(line, 1, p - 1) val; line = substr(line, p + length(tok))
        }
        line = out line
      }
      out = ""
      while ((p = index(line, "{DOT}")) > 0) { out = out substr(line, 1, p - 1) "."; line = substr(line, p + 5) }
      line = out line; out = ""
      while ((p = index(line, "{NL}")) > 0) { out = out substr(line, 1, p - 1) "\n"; line = substr(line, p + 4) }
      printf "%s", out line
    }'
}

run_case() { # $1 host, $2 expected, $3 label, $4 command
  case "$1" in
    codex) shape='{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c,workdir:$d}}' ;;
    *) shape='{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' ;;
  esac
  jq -nc --arg c "$4" --arg d "$CASE/w" "$shape" \
    | AGENT_GUARD_HOOK_HOST=$1 "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
  status=$?
  if [ "$status" -eq "$2" ]; then
    ok "[$1] literal substitution $n: $3"
  else
    bad "[$1] literal substitution $n: $3: expected $2 got $status"
    sed 's/^/  stderr: /' "$CASE/err"
  fi
}

[ -s "$FIXTURE" ] || { bad "fixture $FIXTURE is missing"; exit 1; }
cases=0
codex_kept=
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  expected=${line%%|*}
  rest=${line#*|}
  label=${rest%%|*}
  command=$(expand "${rest#*|}")
  n=$((n + 1)) cases=$((cases + 1))
  run_case claude "$expected" "$label" "$command"
  # The host changes the block message and the output envelope, never the
  # decision, and no case here depends on where the event carries the working
  # directory. Codex's event shape keeps the first case of each expected status.
  case "$codex_kept" in *":$expected:"*) continue ;; esac
  codex_kept="$codex_kept:$expected:"
  run_case codex "$expected" "$label" "$command"
done <"$FIXTURE"
if [ "$cases" -ge 60 ]; then ok "fixture holds $cases cases"; else bad "fixture holds only $cases cases"; fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

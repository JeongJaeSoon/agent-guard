#!/usr/bin/env sh
set -u

# A relative template token is checked from the event workdir and from the one
# static directory a cwd option moves the command to. Every cwd option form
# counts, whether its directory is the next word or held in the option, with or
# without a slash, so a template-named symlink to a protected file stays
# blocked there, while a genuine template stays readable. The protected file
# name is assembled at run time.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-cwd-option.XXXXXX") || exit 1
[ -n "$CASE" ] || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P) || exit 1
trap 'rm -rf "$CASE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
PROTECTED=$(printf '.%s%s' en v)
mkdir "$CASE/home" "$CASE/store" || exit 1
mkdir -p "$CASE/link/nested" "$CASE/link/sub" "$CASE/plain/nested" || exit 1
: >"$CASE/store/$PROTECTED" || exit 1
: >"$CASE/plain/nested/template.env" || exit 1
if ! ln -s "$CASE/store/$PROTECTED" "$CASE/link/nested/template.env" 2>/dev/null; then
  printf 'ok - skipped: filesystem does not support symlinks\n'
  exit 0
fi
export HOME="$CASE/home" AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
unset AGENT_GUARD_OUTPUT_REDACT AI_AGENT
L=$CASE/link
P=$CASE/plain
ENV_CMD=$(command -v env)

pass=0 fail=0
check() { # $1 expected status, $2 workdir, $3 command
  for host in claude codex; do
    case "$host" in
      codex) shape='{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c,workdir:$d}}' ;;
      *) shape='{tool_name:"Bash",hook_event_name:"PreToolUse",tool_input:{command:$c},cwd:$d}' ;;
    esac
    jq -nc --arg c "$3" --arg d "$2" "$shape" \
      | AGENT_GUARD_HOOK_HOST=$host "$GUARD" hook-pre-tool >"$CASE/out" 2>"$CASE/err"
    status=$?
    label=$(printf '%s' "$3" | sed "s|$CASE|<case>|g")
    if [ "$status" -eq "$1" ]; then
      pass=$((pass + 1))
      printf 'ok - [%s] %s: %s\n' "$host" "$1" "$label"
    else
      fail=$((fail + 1))
      printf 'not ok - [%s] %s: %s (got %s)\n' "$host" "$1" "$label" "$status"
      sed 's/^/  stderr: /' "$CASE/err"
    fi
  done
}

# Moved from tests/run.sh: a wrapper, also path-qualified, moves the cwd.
check 2 "$L" "env -C nested cat template.env"
check 2 "$L" "$ENV_CMD -C nested cat template.env"
check 2 "$L" "env --chdir nested cat template.env"
check 2 "$L" "env --chdir=nested cat template.env"
check 2 "$L" "env -Cnested cat template.env"
# The directory held in the option may hold a slash.
check 2 "$L" "env --chdir=$L/nested cat template.env"
check 2 "$L" "env --directory=$L/nested cat template.env"
check 2 "$L" "env -C$L/nested cat template.env"
check 2 "$L" "env --chdir=sub/../nested cat template.env"
check 2 "$L" "tar -C$L/nested -cf /dev/null template.env"
check 2 "$L" "make -C$L/nested -f template.env"
check 2 "$L" "sudo -D$L/nested cat template.env"
check 2 "$L" "git -C $L/nested add template.env"
check 2 "$P" "cd $L/nested && cat template.env"
# A change no static word names, or a word whose file name reads as a cwd
# option, stays conservative even for a genuine template.
check 2 "$L" "find $L/nested -execdir cat template.env ;"
check 2 "$P" "env x/--chdir cat nested/template.env"
check 2 "$P" "env -C nested -C nested cat template.env"
# A genuine template stays readable after one static cwd option.
check 0 "$P" "env -C nested cat template.env"
check 0 "$P" "env --chdir=nested cat template.env"
check 0 "$P" "env --chdir=$P/nested cat template.env"
check 0 "$P" "env -C$P/nested cat template.env"
check 0 "$P" "tar -C$P/nested -cf /dev/null template.env"
check 0 "$P" "git -C $P/nested add template.env"

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

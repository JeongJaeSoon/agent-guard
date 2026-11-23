#!/usr/bin/env sh
# Synthetic hook inputs only: none of the command strings below are executed.
# A file operand of a reading program, or an input redirect, that is built from
# a command substitution or a variable the guard cannot resolve may name a
# protected file, so it is blocked in both infrastructure-failure modes (#507).
# A literal assignment earlier in the same command is followed, and a dynamic
# directory before a literal /name tail is left to the raw-text scan.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unresolved.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
failed=0
checked=0
check() {
  expected=$1
  label=$2
  command=$3
  for check_mode in open closed; do
    checked=$((checked + 1))
    jq -nc --arg c "$command" --arg w "$CASE_ROOT" \
      '{session_id:"unresolved-operand",tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
      | AGENT_GUARD_HOOK_HOST=${HOST:-claude} AGENT_GUARD_INFRA_FAILURE_MODE=$check_mode \
        "$GUARD" hook-pre-tool > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
    status=$?
    if [ "$status" -eq "$expected" ]; then
      printf 'ok - unresolved operand %s: %s (%s)\n' "$checked" "$label" "$check_mode"
    else
      printf 'not ok - unresolved operand %s: %s (%s): expected %s got %s\n' "$checked" "$label" "$check_mode" "$expected" "$status"
      sed 's/^/#   /' "$CASE_ROOT/err"
      failed=$((failed + 1))
    fi
  done
}
# The last check's stderr must hold $2 as a fixed string.
says() {
  checked=$((checked + 1))
  if grep -Fq -- "$2" "$CASE_ROOT/err"; then
    printf 'ok - unresolved operand %s: %s\n' "$checked" "$1"
  else
    printf 'not ok - unresolved operand %s: %s\n' "$checked" "$1"
    sed 's/^/#   /' "$CASE_ROOT/err"
    failed=$((failed + 1))
  fi
}
NL='
'
# The name is assembled at run time in every blocked shape below.
S='"$(printf %s .e; printf nv)"'
R=unresolved_operand

check 2 "cat of a command substitution" "cat $S"
says "the block names its reason" "reason=bash_protected_path_$R;"
check 2 "cat of a backquoted substitution" 'cat `printf %s .e; printf nv`'
check 2 "cat of an unquoted substitution" 'cat $(printf %s .e; printf nv)'
check 2 "cat of an unset variable" 'cat "$F"'
check 2 "cat of an unquoted variable" 'cat $F'
check 2 "cat of a braced variable with a default" 'cat "${F:-x}"'
check 2 "cat of a positional parameter" 'cat "$1"'
check 2 "a variable joined to a literal suffix" 'cat "${F}nv"'
check 2 "head of a substitution" "head -n 1 $S"
check 2 "sed of a substitution after its script" "sed -n p $S"
check 2 "base64 of a substitution" "base64 $S"
check 2 "input redirect from a substitution" "cat < $S"
check 2 "input redirect without a blank" "wc -l <$S"
check 2 "input redirect of a loop" "while read -r l; do :; done < \"\$F\""
check 2 "cat behind command" 'command cat "$F"'
check 2 "cat by full path" '/bin/cat "$F"'
check 2 "cat behind env with an assignment" 'env A=1 cat "$F"'
check 2 "cat after a pipe" 'true | cat "$F"'
check 2 "cat after if then" 'if true; then cat "$F"; fi'
check 2 "cat inside a substitution" 'echo "$(cat "$F")"'
check 2 "cat inside a git commit message substitution" 'git commit -m "$(cat "$F")"'
check 2 "cat inside a process substitution" 'diff <(cat "$F") README.md'
check 2 "grep pattern file from a variable" 'grep -f "$F" README.md'
check 2 "grep file operand after its pattern" 'grep -n x "$F"'
check 2 "cp source from a variable" 'cp "$F" copy.txt'
check 2 "dot command of a variable" '. "$F"'
check 2 "a variable assigned from a substitution" 'f=$(printf %s .e; printf nv); cat "$f"'
check 2 "a literal assignment that names a protected file" 'f=.e; cat "${f}nv"'
check 2 "a literal assignment that names an ssh key" 'd=.ssh; cat ~/"$d/id_ed25519"'
check 2 "an assignment only on the command's environment" 'F=README.md cat "$F"'
check 2 "an assignment inside a branch" 'if true; then f=README.md; fi; cat "$f"'
check 2 "a dynamic name after a literal directory" 'cat "docs/$F"'
check 2 "a dynamic name after a dynamic directory" 'cat "$D/$F"'
check 2 "grep pattern attached to -e" 'grep -ex "$F"'
check 2 "sed script attached to -e in a cluster" 'sed -nep "$F"'
check 2 "grep pattern file attached to -f" 'grep -f"$F" README.md'
check 2 "grep pattern file as --file=" 'grep --file="$F" README.md'
check 2 "uniq input from a variable" 'uniq "$F"'
check 2 "a comment after the operand" 'cat "$F" # note'
check 2 "a command on the line after a comment" "# note${NL}cat \"\$F\""
check 2 "source script from a variable" 'source "$F" x'
check 2 "cp source after a long target directory" 'cp --target-directory "$DEST" "$F"'
check 2 "cp source after an attached long target directory" 'cp --target-directory="$DEST" "$F"'
check 2 "jq data argument that runs a substitution" "jq -n --args '\$ARGS.positional' \"\$(cat \"\$F\")\""
check 2 "rg search root from a substitution" 'rg -n x "$(git rev-parse --show-toplevel)"'
check 2 "the working directory before a protected name" 'cat "$(pwd)/.e""nv"'
check 2 "PWD before a protected name" 'cat "$PWD/.e""nv"'
check 2 "the working directory after a cd" 'cd docs; cat "$PWD"'
check 2 "a working directory joined to a dynamic name" 'cat "$(pwd)/$F"'
check 2 "pwd with an argument is not resolved" 'cat "$(pwd -P)x"'

check 0 "rg search root is the working directory" 'rg -n x "$(pwd)"'
check 0 "rg search root is PWD" 'rg -n x "$PWD"'
check 0 "a file under the working directory" 'cat "$(pwd)/src"'
check 0 "a file under a braced PWD" 'cat "${PWD}/README.md"'
check 0 "a variable inside a comment" 'cat README.md # "$F"'
check 0 "a substitution inside a comment" 'echo ok # $(cat "$F")'
check 0 "uniq output to a variable" 'uniq README.md "$OUT"'
check 0 "xxd output to a variable" 'xxd README.md "$OUT"'
check 0 "rg replacement from a variable" 'rg --replace "$REP" "$PAT" README.md'
check 0 "rg -r replacement from a variable" 'rg -r "$REP" "$PAT" README.md'
check 0 "jq --args data from a variable" "jq -n --args '\$ARGS.positional' \"\$VALUE\""
check 0 "jq --jsonargs data from a variable" "jq -n --jsonargs '\$ARGS.positional' \"\$VALUE\""
check 0 "source passes a variable to the script" 'source ./script.sh "$ARG"'
check 0 "dot command passes all arguments" '. ./script.sh "$@"'
check 0 "cp long target directory from a variable" 'cp --target-directory "$DEST" README.md'
check 0 "rg color from a variable" 'rg --color "$COLOR" "$PAT" README.md'
check 0 "rg depth from a variable" 'rg --max-depth "$D" "$PAT" docs'
check 0 "head count attached to -n" 'head -n"$N" README.md'
check 0 "a literal assignment of an ordinary file" 'f=README.md; cat "$f"'
check 0 "an exported literal assignment of an ordinary file" 'export f=README.md; cat "$f"'
check 0 "a repository root before a literal file" 'cat "$(git rev-parse --show-toplevel)/README.md"'
check 0 "a home directory before a literal file" 'cat "$HOME/notes.txt"'
check 0 "a quoted variable before a literal file" 'cat "$D"/notes.txt'
check 0 "a single-quoted dollar is literal" "cat '\$F'"
check 0 "grep pattern from a variable" 'grep -n "$PAT" README.md'
check 0 "grep -e pattern from a variable" 'grep -e "$PAT" README.md'
check 0 "rg pattern from a variable" 'rg "$PAT" docs'
check 0 "head count from a variable" 'head -n "$N" README.md'
check 0 "sed script from a variable" 'sed -n "$R" README.md'
check 0 "awk program and field separator from variables" 'awk -F "$SEP" "$PROG" README.md'
check 0 "jq argument from a variable" "jq --arg v \"\$V\" '.x' package.json"
check 0 "echo of a variable" 'echo "$F"'
check 0 "cd to a substitution" 'cd "$(git rev-parse --show-toplevel)"'
check 0 "cat of standard input after printf" 'printf "%s\n" "$F" | cat'
check 0 "output redirect to a variable" 'printf x > "$OUT"'
check 0 "heredoc body text with a variable" "cat <<'EOF'${NL}cat \$F${NL}EOF"
check 0 "a message substitution from a quoted heredoc" "printf '%s\\n' \"\$(cat <<'EOF'${NL}cat \$F here${NL}EOF${NL})\""
check 0 "cat of a literal ordinary file" 'cat README.md'

HOST=codex
check 2 "codex: cat of a command substitution" "cat $S"
says "codex: the block names its reason" "reason=bash_protected_path_$R;"
check 0 "codex: a literal assignment of an ordinary file" 'f=README.md; cat "$f"'
HOST=

printf '%s unresolved operand checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

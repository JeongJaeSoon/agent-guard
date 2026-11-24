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
  for check_mode in ${MODES:-open closed}; do
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
check 2 "an assignment inside a substitution stays inside" 'echo "$(f=README.md)"; cat "$f"'
check 2 "a protected value reaches a substitution" 'f=.e; echo "$(cat "${f}nv")"'
check 2 "sort file list from a variable" 'sort --files0-from "$F"'
check 2 "a quoted -- ends the options" 'cat "--" "$F"'
check 2 "local without a value resets a variable" 'f=README.md; local f; cat "$f"'
check 2 "an environment-only chain stays unresolved" 'f=README.md g=$f cat "$g"'
check 2 "a compound assignment changes the value" 'f=.e; f+=nv; cat "$f"'
check 2 "a subshell attached to the reader" "(cat $S)"
check 2 "a line continuation after the reader" "cat \\${NL} $S"
check 2 "nice with a priority value" "nice -n 5 cat $S"
check 2 "timeout with a signal and a duration" "timeout -s KILL 5 cat $S"
check 2 "sudo with a user" "sudo -u root cat $S"
check 2 "sh -c program text" "sh -c 'cat \"\$F\"'"
check 2 "bash -c program text after options" "bash -e -c 'cat \"\$F\"'"
check 2 "eval of a reader" "eval 'cat \"\$F\"'"
check 2 "sh -c program with a variable operand" 'sh -c "cat $F"'
check 2 "a reader right before a line continuation" "cat\\${NL} $S"
check 2 "awk file operand after an assignment operand" 'awk 1 v=1 "$F"'
check 2 "diff exclude list from a variable" 'diff -X "$F" a b'
check 2 "a redirect after a [[ ]] test" '[[ "$a" < "$b" ]] && cat < "$F"'
check 2 "a multi-line substitution in a heredoc body reads a variable" "cat <<EOF${NL}\$(${NL}cat \"\$F\"${NL})${NL}EOF"
check 2 "printf -v forgets only its target" 'f=README.md; printf -v f %s x; cat "$f"'
check 2 "env with an unset option before the reader" 'env -u OTHER cat "$F"'
check 2 "env -S code with a variable operand" "env -S 'cat \"\$F\"'"
check 2 "eval code assembled into a protected name" 'f=.e; eval "cat ${f}nv"'
check 2 "sh -c code assembled into a protected name" 'f=.e; sh -c "cat ${f}nv"'
check 2 "a resolved option names a protected pattern file" 'o=--file=.e; grep "${o}nv" README.md'
check 2 "env override reaches nested code" "f=README.md; env f=\"\$X\" sh -c 'cat \"\$f\"'"
check 2 "a prefix assignment reaches nested code" "f=README.md; f=\"\$X\" sh -c 'cat \"\$f\"'"
check 2 "an input redirect attached to the command" 'cat<"$F"'
check 2 "an input redirect attached to wc" 'wc<"$F"'
check 2 "printf -v into a variable named at run time" "f=README.md; v=f; printf -v \"\$v\" '%s%s' .e nv; cat \"\$f\""
check 2 "read into a variable named at run time" 'f=README.md; v=f; read "$v"; cat "$f"'
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
check 0 "an assignment reaches a substitution" 'f=README.md; echo "$(cat "$f")"'
check 0 "an assignment reaches a process substitution" 'f=README.md; diff <(cat "$f") README.md'
check 0 "sort parallel count from a variable" 'sort --parallel "$N" README.md'
check 0 "a quoted -e option" 'grep "-e" "$PAT" README.md'
check 0 "export without a value keeps the value" 'f=README.md; export f; cat "$f"'
check 0 "readonly without a value keeps the value" 'f=README.md; readonly f; cat "$f"'
check 0 "an assignment chain on one line" 'f=README.md g=$f; cat "$g"'
check 0 "a compound assignment of an ordinary name" 'f=READ; f+=ME.md; cat "$f"'
check 0 "a literal assignment reaches source" 'f=./script.sh; source "$f"'
check 0 "a literal assignment reaches the dot command" 'f=./script.sh; . "$f"'
check 0 "awk assignment operand from a variable" "awk '{print v}' v=\"\$VALUE\" README.md"
check 0 "sh -c program with a literal read" "sh -c 'cat README.md'"
check 0 "a string comparison in [[ ]]" '[[ "$a" < "$b" ]]'
check 0 "an arithmetic comparison" '(( count < $limit ))'
# Under the closed policy the git gate blocks shell code read from stdin.
MODES=open
check 0 "bash -s passes its arguments to the script" "bash -s -- \"\$ARG\" <<'EOF'${NL}printf '%s\\n' \"\$1\"${NL}EOF"
MODES=
check 0 "diff exclude pattern from a variable" 'diff -x "$PAT" dir1 dir2'
check 0 "diff ignored lines from a variable" 'diff -I "$PAT" a b'
check 0 "grep binary-files mode from a variable" 'grep --binary-files "$MODE" "$PAT" README.md'
check 0 "cmp skip count from a variable" 'cmp -i "$SKIP" README.md LICENSE'
check 0 "a multi-line substitution in a heredoc body" "cat <<EOF${NL}\$(${NL}printf hello${NL})${NL}EOF"
check 0 "printf -v data does not forget other names" 'f=README.md; printf -v out %s f; cat "$f"'
MODES=open
check 0 "eval code assembled into an ordinary name" 'f=READ; eval "cat ${f}ME.md"'
MODES=
check 0 "env with an unset option and a literal read" 'env -u OTHER cat README.md'
check 0 "a resolved name of an env template" 'f=.e; cat "${f}nv.example"'
check 0 "a resolved option" 'opt=-e; grep "$opt" "$PAT" README.md'
check 0 "input redirect from a process substitution" "cat < <(printf '%s' \"\$TEXT\")"
check 0 "BSD sed in-place edit with an empty suffix" "sed -i '' \"\$SCRIPT\" README.md"
check 0 "base64 wrap width from a variable" 'base64 --wrap "$WIDTH" README.md'
check 0 "BSD sed in-place edit with a suffix" "sed -i .bak \"\$SCRIPT\" README.md"
check 0 "an output redirect attached to the command" 'echo hi>"$OUT"'
check 0 "a descriptor duplication" 'cat README.md 2>&1'
check 0 "nice with a literal read" 'nice -n 5 cat README.md'
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
check 0 "a loop over literal ordinary files" 'for f in README.md notes.txt; do cat "$f"; done'
check 0 "a grep in a loop over literal files" 'for f in src/a.ts notes.txt; do grep -n x $f | head -3; done'
check 2 "a loop whose literal list names a protected file" 'for f in README.md .e"nv"; do cat "$f"; done'
check 2 "a loop whose later word resolves to a protected file" 'p=.e; for f in README.md "${p}nv"; do cat "$f"; done'
says "the later loop word is the resolved operand" "matched deny-read-paths entry"
check 0 "a loop over words resolved to ordinary files" 'p=notes; for f in README.md "${p}.txt"; do cat "$f"; done'
check 2 "a loop over a glob" 'for f in *; do cat "$f"; done'
check 2 "a loop over a brace expansion" 'for f in {a,b}; do cat "$f"; done'
check 2 "a loop over a substitution" 'for f in $(ls); do cat "$f"; done'
check 2 "a loop over the positional parameters" 'for f; do cat "$f"; done'
check 2 "a loop variable reassigned in the body" 'for f in README.md; do f=$(printf x); cat "$f"; done'
check 2 "a loop variable read back" 'for f in README.md; do read f; cat "$f"; done'
check 2 "a loop variable joined with a second one" 'for f in a; do for g in b; do cat "$f$g"; done; done'
check 2 "a loop value copied to another variable" 'for f in README.md; do g=$f; cat "$g"; done'
check 2 "a loop value after a loop that may not run" "f=$S; if false; then for f in README.md; do :; done; fi; cat \"\$f\""
check 2 "a loop value after a loop in a pipeline" "f=$S; for f in README.md; do :; done | true; cat \"\$f\""
check 2 "an empty loop word before an unresolved part" 'for f in ""; do cat "$F$f"; done'
check 2 "a loop over an unquoted expansion that splits" 'p=".e x"; for f in $p; do cat "${f}nv"; done'
check 0 "a loop variable inside its body after a nested loop" 'for f in README.md; do for g in a; do :; done; cat "$f"; done'

HOST=codex
check 2 "codex: cat of a command substitution" "cat $S"
says "codex: the block names its reason" "reason=bash_protected_path_$R;"
check 0 "codex: a literal assignment of an ordinary file" 'f=README.md; cat "$f"'
HOST=

printf '%s unresolved operand checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

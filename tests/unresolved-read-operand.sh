#!/usr/bin/env sh
# Synthetic hook inputs only: none of the command strings below are executed.
# A file operand of a reading program, or an input redirect, that is built from
# a command substitution or a variable the guard cannot resolve may name a
# protected file (#507). That check could not run, so it warns and passes by
# default and blocks under AGENT_GUARD_INFRA_FAILURE_MODE=closed. An operand
# resolved to a protected file blocks in every mode.
# A literal assignment earlier in the same command is followed, and a dynamic
# directory before a literal /name tail is left to the raw-text scan.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-unresolved.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_WARNING_DIR="$CASE_ROOT/warnings"
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
failed=0
checked=0
# Expected u: an operand that stays unknown warns and passes by default
# and blocks under the closed policy. 2 blocks and 0 passes in every mode.
check() {
  expected=$1
  label=$2
  command=$3
  for check_mode in ${MODES:-default closed}; do
    checked=$((checked + 1))
    want=$expected
    [ "$expected" != u ] || { [ "$check_mode" = closed ] && want=2 || want=0; }
    jq -nc --arg c "$command" --arg w "$CASE_ROOT" --arg s "unresolved-operand-$checked" \
      '{session_id:$s,tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
      | if [ "$check_mode" = default ]; then
          env -u AGENT_GUARD_INFRA_FAILURE_MODE AGENT_GUARD_HOOK_HOST=${HOST:-claude} "$GUARD" hook-pre-tool
        else
          AGENT_GUARD_HOOK_HOST=${HOST:-claude} AGENT_GUARD_INFRA_FAILURE_MODE=$check_mode "$GUARD" hook-pre-tool
        fi > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
    status=$?
    verdict=ok
    [ "$status" -eq "$want" ] || verdict="expected $want got $status"
    # The closed policy blocks before the other checks, with the same block.
    [ "$verdict:$expected:$want" != ok:u:2 ] \
      || grep -Fq "blocked shell command whose file operand is only known at run time" "$CASE_ROOT/err" \
      || verdict="not the unresolved-operand block"
    # A pass carries the warning exactly when the operand stayed unknown.
    if [ "$verdict" = ok ] && [ "$want" -eq 0 ]; then
      warned=0
      jq -e '.hookSpecificOutput.additionalContext | contains("reason=bash_protected_path_'"$R"';") and contains("continuing because AGENT_GUARD_INFRA_FAILURE_MODE=open")' \
        "$CASE_ROOT/out" >/dev/null 2>&1 && warned=1
      if [ "$expected" = u ] && [ "$warned" -ne 1 ]; then
        verdict="no unresolved-operand warning in additionalContext"
      elif [ "$expected" != u ] && grep -Fq "bash_protected_path_$R" "$CASE_ROOT/out" "$CASE_ROOT/err"; then
        verdict="an unexpected unresolved-operand warning"
      fi
    fi
    if [ "$verdict" = ok ]; then
      printf 'ok - unresolved operand %s: %s (%s)\n' "$checked" "$label" "$check_mode"
    else
      printf 'not ok - unresolved operand %s: %s (%s): %s\n' "$checked" "$label" "$check_mode" "$verdict"
      sed 's/^/#   /' "$CASE_ROOT/err" "$CASE_ROOT/out"
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

check u "cat of a command substitution" "cat $S"
says "the block names its reason" "reason=bash_protected_path_$R;"
check u "cat of a backquoted substitution" 'cat `printf %s .e; printf nv`'
check u "cat of an unquoted substitution" 'cat $(printf %s .e; printf nv)'
check u "cat of an unset variable" 'cat "$F"'
check u "cat of an unquoted variable" 'cat $F'
check u "cat of a braced variable with a default" 'cat "${F:-x}"'
check u "cat of a positional parameter" 'cat "$1"'
check u "a variable joined to a literal suffix" 'cat "${F}nv"'
check u "head of a substitution" "head -n 1 $S"
check u "sed of a substitution after its script" "sed -n p $S"
check u "base64 of a substitution" "base64 $S"
check u "input redirect from a substitution" "cat < $S"
check u "input redirect without a blank" "wc -l <$S"
check u "input redirect of a loop" "while read -r l; do :; done < \"\$F\""
check u "cat behind command" 'command cat "$F"'
check u "cat by full path" '/bin/cat "$F"'
check u "cat behind env with an assignment" 'env A=1 cat "$F"'
check u "cat after a pipe" 'true | cat "$F"'
check u "cat after if then" 'if true; then cat "$F"; fi'
check u "cat inside a substitution" 'echo "$(cat "$F")"'
check u "cat inside a git commit message substitution" 'git commit -m "$(cat "$F")"'
check u "cat inside a process substitution" 'diff <(cat "$F") README.md'
check u "grep pattern file from a variable" 'grep -f "$F" README.md'
check u "grep file operand after its pattern" 'grep -n x "$F"'
check u "cp source from a variable" 'cp "$F" copy.txt'
check u "dot command of a variable" '. "$F"'
check u "a variable assigned from a substitution" 'f=$(printf %s .e; printf nv); cat "$f"'
check 2 "a literal assignment that names a protected file" 'f=.e; cat "${f}nv"'
check 2 "a literal assignment that names an ssh key" 'd=.ssh; cat ~/"$d/id_ed25519"'
check u "an assignment only on the command's environment" 'F=README.md cat "$F"'
check u "an assignment inside a branch" 'if true; then f=README.md; fi; cat "$f"'
check u "a dynamic name after a literal directory" 'cat "docs/$F"'
check u "a dynamic name after a dynamic directory" 'cat "$D/$F"'
check u "grep pattern attached to -e" 'grep -ex "$F"'
check u "sed script attached to -e in a cluster" 'sed -nep "$F"'
check u "grep pattern file attached to -f" 'grep -f"$F" README.md'
check u "grep pattern file as --file=" 'grep --file="$F" README.md'
check u "uniq input from a variable" 'uniq "$F"'
check u "a comment after the operand" 'cat "$F" # note'
check u "a command on the line after a comment" "# note${NL}cat \"\$F\""
check u "source script from a variable" 'source "$F" x'
check u "cp source after a long target directory" 'cp --target-directory "$DEST" "$F"'
check u "cp source after an attached long target directory" 'cp --target-directory="$DEST" "$F"'
check u "jq data argument that runs a substitution" "jq -n --args '\$ARGS.positional' \"\$(cat \"\$F\")\""
check u "an assignment inside a substitution stays inside" 'echo "$(f=README.md)"; cat "$f"'
check 2 "a protected value reaches a substitution" 'f=.e; echo "$(cat "${f}nv")"'
check u "sort file list from a variable" 'sort --files0-from "$F"'
check u "a quoted -- ends the options" 'cat "--" "$F"'
check u "local without a value resets a variable" 'f=README.md; local f; cat "$f"'
check u "an environment-only chain stays unresolved" 'f=README.md g=$f cat "$g"'
check 2 "a compound assignment changes the value" 'f=.e; f+=nv; cat "$f"'
check u "a subshell attached to the reader" "(cat $S)"
check u "a line continuation after the reader" "cat \\${NL} $S"
check u "nice with a priority value" "nice -n 5 cat $S"
check u "timeout with a signal and a duration" "timeout -s KILL 5 cat $S"
check u "sudo with a user" "sudo -u root cat $S"
check u "sh -c program text" "sh -c 'cat \"\$F\"'"
check u "bash -c program text after options" "bash -e -c 'cat \"\$F\"'"
check u "eval of a reader" "eval 'cat \"\$F\"'"
check u "sh -c program with a variable operand" 'sh -c "cat $F"'
check u "a reader right before a line continuation" "cat\\${NL} $S"
check u "awk file operand after an assignment operand" 'awk 1 v=1 "$F"'
check u "diff exclude list from a variable" 'diff -X "$F" a b'
check u "a redirect after a [[ ]] test" '[[ "$a" < "$b" ]] && cat < "$F"'
check u "a multi-line substitution in a heredoc body reads a variable" "cat <<EOF${NL}\$(${NL}cat \"\$F\"${NL})${NL}EOF"
check u "printf -v forgets only its target" 'f=README.md; printf -v f %s x; cat "$f"'
check u "env with an unset option before the reader" 'env -u OTHER cat "$F"'
check u "env -S code with a variable operand" "env -S 'cat \"\$F\"'"
check 2 "eval code assembled into a protected name" 'f=.e; eval "cat ${f}nv"'
check 2 "sh -c code assembled into a protected name" 'f=.e; sh -c "cat ${f}nv"'
check 2 "a resolved option names a protected pattern file" 'o=--file=.e; grep "${o}nv" README.md'
check u "env override reaches nested code" "f=README.md; env f=\"\$X\" sh -c 'cat \"\$f\"'"
check u "a prefix assignment reaches nested code" "f=README.md; f=\"\$X\" sh -c 'cat \"\$f\"'"
check u "an input redirect attached to the command" 'cat<"$F"'
check u "an input redirect attached to wc" 'wc<"$F"'
check u "printf -v into a variable named at run time" "f=README.md; v=f; printf -v \"\$v\" '%s%s' .e nv; cat \"\$f\""
check u "read into a variable named at run time" 'f=README.md; v=f; read "$v"; cat "$f"'
check u "rg search root from a substitution" 'rg -n x "$(git rev-parse --show-toplevel)"'
check 2 "the working directory before a protected name" 'cat "$(pwd)/.e""nv"'
check 2 "PWD before a protected name" 'cat "$PWD/.e""nv"'
check u "the working directory after a cd" 'cd docs; cat "$PWD"'
check u "a working directory joined to a dynamic name" 'cat "$(pwd)/$F"'
check u "pwd with an argument is not resolved" 'cat "$(pwd -P)x"'

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
check 0 "a loop over a bare glob reads what the glob typed as an operand reads" 'for f in *; do cat "$f"; done'
check u "a loop over a brace expansion" 'for f in {a,b}; do cat "$f"; done'
check u "a loop over a substitution" 'for f in $(ls); do cat "$f"; done'
check u "a loop over the positional parameters" 'for f; do cat "$f"; done'
check u "a loop variable reassigned in the body" 'for f in README.md; do f=$(printf x); cat "$f"; done'
check u "a loop variable read back" 'for f in README.md; do read f; cat "$f"; done'
check u "a loop variable joined with a second one" 'for f in a; do for g in b; do cat "$f$g"; done; done'
check u "a loop value copied to another variable" 'for f in README.md; do g=$f; cat "$g"; done'
check u "a loop value after a loop that may not run" "f=$S; if false; then for f in README.md; do :; done; fi; cat \"\$f\""
check u "a loop value after a loop in a pipeline" "f=$S; for f in README.md; do :; done | true; cat \"\$f\""
check u "an empty loop word before an unresolved part" 'for f in ""; do cat "$F$f"; done'
check u "a loop over an unquoted expansion that splits" 'p=".e x"; for f in $p; do cat "${f}nv"; done'
check u "a loop value globbed at an unquoted use" 'p=".*"; for f in "$p"; do cat $f; done'
check u "a select variable may be empty" "F=$S; select f in /README.md; do cat \"\$F\$f\"; break; done"
check u "an indexed write to the loop variable" 'for f in README.md; do printf -v "f[0]" %s .e; cat "${f}nv"; done'
check u "an indexed write to an assigned variable" 'f=README.md; printf -v "f[0]" %s .e; cat "${f}nv"'
check u "an assigned value globbed at an unquoted use" 'p=".*"; cat $p'
check 0 "an assigned glob value quoted at its use" 'p="*.md"; cat "$p"'
check u "a literal marker byte in an operand" "F=$S; cat \"\$F$(printf '\005')\""
check 0 "a loop list that reads the old value of its variable" 'f=README.md; for f in "$f"; do cat "$f"; done'
check 2 "an assignment keeps a value with a space" 'p="some dir/.ssh"; q=$p; cat "$q/config"'
check u "a loop list split by a changed IFS" 'IFS=x; p=.exREADME.md; for f in $p; do cat "${f}nv"; done'
check u "an operand split by a changed IFS" 'IFS=x; p=READMEx.e; cat ${p}nv'
check u "an ANSI-C escape in a loop word" "for f in \$'\\056e'; do cat \"\${f}nv\"; done"
check u "an ANSI-C escape in an assignment" "p=\$'\\056e'; cat \"\${p}nv\""
check 0 "an ANSI-C word without escapes" "p=\$'README'; cat \"\${p}.md\""
check u "an unquoted loop use after IFS changed" 'IFS=x; p=id_; for f in "${p}rsaxREADME"; do cat ${f}; done'
check u "a loop over IFS itself" 'p=id_; for IFS in x; do for f in "${p}rsaxREADME"; do cat $f; done; done'
check u "a locale-quoted loop word" 'for f in .e$"nv"; do cat "$f"; done'
check u "a locale-quoted assignment" 'p=.e$"nv"; cat "$p"'
check u "a function that rewrites the loop variable" "g(){ f=$S; }; for f in README.md; do g; cat \"\$f\"; done"
check u "a function that rewrites an assigned variable" "g(){ f=$S; }; f=README.md; g; cat \"\$f\""
check u "a function keyword definition" "function g { f=$S; }; for f in README.md; do g; cat \"\$f\"; done"
check u "a trap that rewrites the loop variable" "trap 'f=$S' DEBUG; for f in README.md; do cat \"\$f\"; done"
check u "a default assignment on an empty loop word" 'p=.e; for f in ""; do : "${f:=${p}nv}"; cat "./$f"; done'
check u "a default assignment on an empty variable" 'p=.e; f=; : "${f:=${p}nv}"; cat "./$f"'
check 0 "a loop variable inside its body after a nested loop" 'for f in README.md; do for g in a; do :; done; cat "$f"; done'

# Narrowing (#638): a value the guard can follow is checked as that value, and
# only an operand that stays unknown blocks. Ordinary names pass.
check 0 "sed in a loop over literal files" 'for f in a.md b.md; do sed -n 1,5p "$f"; done'
check 0 "grep, head and base64 in a loop over literal files" 'for f in docs/a.md logs/b.log; do grep -c x "$f"; head -3 "$f"; base64 "$f"; done'
check 0 "a loop variable read inside a substitution" 'for f in a.md b.md; do echo "$f: $(grep -c x "$f")"; done'
check 0 "a loop variable as an input redirect inside a substitution" 'for f in a.md b.md; do n=$(wc -l < "$f"); echo "$n"; done'
check 0 "a loop variable read inside backquotes" 'for f in a.md b.md; do echo `head -1 "$f"`; done'
check 0 "a loop variable read inside a process substitution" 'for f in a.md b.md; do diff <(sort "$f") <(sort "old/$f"); done'
check 0 "grep in a loop over a glob" 'for f in docs/*.md; do grep x "$f"; done'
check 0 "tail in a loop over a log glob" 'for f in logs/*.log; do echo "$f"; tail -n 3 "$f"; done'
check 0 "a loop over a glob and a literal word" 'for f in docs/*.md README.md; do head -1 "$f"; done'
check 0 "a glob loop variable inside a larger word" 'for f in docs/*.md; do diff "$f" "old/$f"; cat "$f.bak"; done'
check 0 "a glob loop variable inside a substitution" 'for f in logs/*.log; do echo "$(tail -1 "$f")"; done'
check 0 "a loop over a glob under the home directory" 'for f in ~/notes/*.md; do head -1 "$f"; done'
check 0 "a loop over literal files under the home directory" 'for f in ~/notes/a.md ~/notes/b.md; do head -1 "$f"; done'
check 0 "a loop over a glob after a resolved directory" 'd=docs; for f in "$d"/*.md; do head -1 "$f"; done'
check 0 "a loop variable before a literal suffix" 'for f in build test; do cat "$f.log"; done'
check 0 "a loop variable after a literal directory" 'for f in a.md b.md; do cat "docs/$f"; done'
check 0 "a here-string of a variable" 'grep x <<<"$f"'
check 0 "a here-string into a reading program in a loop" 'for f in a b; do cat <<<"$f"; done'
check 0 "a here-string after a blank" 'jq . <<< "$json"'
check 0 "a here-string into a read loop" 'while read -r l; do echo "$l"; done <<<"$out"'
check 0 "a literal assignment read by two programs" 'p=logs/build.log; grep -c x "$p"; sed -n 1,5p "$p"'
check 0 "a literal assignment of a document" 'p=docs/a.md; cat "$p"'

check 2 "a loop word that completes a protected name" 'for f in nv; do cat ".e$f"; done'
check 2 "a loop word that completes a protected name inside a substitution" 'for f in nv; do echo "$(cat ".e$f")"; done'
check 2 "a loop word under a key directory" 'p=.s; for f in ~/"${p}sh"/config; do cat "$f"; done'
check 2 "a loop glob that can name a protected file" 'for f in e*; do cat ".$f"; done'
check 2 "a loop glob that can name a protected file inside a substitution" 'for f in e*; do echo "$(cat ".$f")"; done'
check 2 "a loop glob after a resolved protected prefix" 'p=.e; for f in "$p"*; do cat "$f"; done'
check 2 "a loop glob after a literal word, the glob protected" 'for f in README.md e*; do cat ".$f"; done'
check u "a glob loop value split at an unquoted use" 'for f in docs/*; do cat $f; done'
check u "a glob loop value split at an unquoted use inside a substitution" 'for f in docs/*; do echo "$(cat $f)"; done'
check u "a loop glob after an unknown directory" 'for f in "$D"*; do cat "$f"; done'
check u "a loop list with a variable" 'for f in a.md "$X"; do cat "$f"; done'
check u "a loop list with a substitution" 'for f in a.md $(ls); do cat "$f"; done'
check u "a loop word behind another tilde form" 'for f in ~+/a.md; do cat "$f"; done'
check u "a loop variable after its loop, inside a substitution" 'for f in a.md; do :; done; echo "$(cat "$f")"'
check u "a loop variable reassigned inside a substitution" 'for f in a.md; do echo "$(f=$X; cat "$f")"; done'
check u "an assignment inside a subshell" '(p=docs/a.md); cat "$p"'
check u "a variable reassigned from a substitution before the read" 'p=docs/a.md; p=$(ls | head -1); cat "$p"'
check u "a variable read back before the read" 'p=docs/a.md; read -r p; cat "$p"'
check u "a substitution inside a here-string" 'cat <<<"$(cat "$F")"'
check u "a file operand next to a here-string" 'grep x "$F" <<<"$f"'
check u "a function defined before a substitution that calls it" "g(){ f=$S; }; echo \"\$(f=README.md; g; cat \"\$f\")\""
check u "an IFS change before a substitution" 'IFS=x; p=id_; q="${p}rsaxREADME"; echo "$(cat ${q})"'
check u "a table separator byte in an assigned value" "p=\"a$(printf '\004')f$(printf '\003')README.md\"; echo \"\$(cat \"\$f\")\""
check u "a table separator byte in a loop word" "for g in \"a$(printf '\004')f$(printf '\003')README.md\"; do echo \"\$(cat \"\$f\")\"; done"
check u "a table separator byte in a loop variable name" "for \"x$(printf '\004')f$(printf '\003')README.md\" in a; do echo \"\$(cat \"\$f\")\"; done"
check u "a substitution in an assignment after a reassignment on the same line" 'f=README.md; f=$X g=$(cat "$f")'
check u "a loop variable reassigned on the same line as a substitution" 'for f in a.md; do f=$X g=$(cat "$f"); done'
check u "a quoted assignment word of export" 'f=README.md; export "f=$X"; cat "$f"'
check u "an export word that holds an assignment" 'f=README.md; kv="f=$X"; export $kv; cat "$f"'
check u "a quoted assignment word of declare" 'f=README.md; declare "f=.e"; cat "${f}nv"'
check 0 "a substitution in an assignment reads an earlier value" 'f=README.md; g=$(cat "$f"); echo "$g"'
check 0 "an export of another name keeps the value" 'f=README.md; export OTHER="$X"; cat "$f"'
check u "an env override of the loop variable reaches nested code" "for f in a.md; do env f=\"\$X\" sh -c 'cat \"\$f\"'; done"
check u "a prefix assignment of the loop variable reaches nested code" "for f in a.md; do f=\"\$X\" sh -c 'cat \"\$f\"'; done"
check u "a prefix assignment of the loop variable reaches eval code" "for f in a.md; do f=\"\$X\" eval 'cat \"\$f\"'; done"
check 0 "a loop variable reaches nested shell code" "for f in a.md b.md; do sh -c 'cat \"\$f\"'; done"
check u "a declaration word whose unquoted value may split into more assignments" 'g=README.md; declare "f"=$X; cat "$g"'
check 2 "an env override does not change the loop value the shell expands" 'for f in .ssh; do env f=safe cat "$f/config"; done'
check 2 "a prefix assignment does not change the loop value the shell expands" 'for f in .ssh; do f=safe cat "$f/config"; done'
check 2 "an env override does not change the assigned value the shell expands" 'd=.ssh; env d=safe cat "$d/config"'
check 2 "a prefix assignment does not change the assigned value the shell expands" 'd=.ssh; d=safe cat "$d/config"'
check 0 "an env override beside a loop over ordinary names" 'for f in docs; do env f=safe cat "$f/a.md"; done'
check 0 "a locale prefix before a reader in a loop" 'for f in a.md b.md; do LC_ALL=C sort "$f"; done'
check 2 "a prefix assignment does not change the value eval code is built from" 'd=.ssh; d=safe eval "cat $d/config"'
check 2 "a loop word that turns an operand into a file option" 'for o in --file=.e; do grep "${o}nv" README.md; done'
check u "a loop word that is a file option" 'for o in -f; do grep "$o" "$HOME/pats.txt" README.md; done'
check 0 "a loop over line counts after a count option" 'for n in 5 10; do head -n "$n" README.md; done'
check 0 "a loop over line counts attached to a count option" 'for n in 5 10; do head -n"$n" README.md; tail -$n README.md; done'
check 0 "a quoted assignment word of export leaves other names" 'g=README.md; export "f=$X"; cat "$g"'
check 0 "a single-quoted assignment word of declare leaves other names" "g=README.md; declare 'f=\$X'; cat \"\$g\""
check 0 "a loop over standard input and a file" 'for f in - README.md; do cat "$f"; done'
check u "a dash loop word after jq --args is still an option" "for a in -hello; do jq -n --args '\$ARGS.positional' \"\$a\"; done"
check u "a loop word that is a jq file option after --args" 'for o in --rawfile; do jq -n --args . "$o" x "$F"; done'
check u "a quoted declaration word with all positional parameters" 'g=README.md; export "f=$@"; cat "$g"'
check u "a quoted declaration word with all array elements" 'g=README.md; export "f=${a[@]}"; cat "$g"'
check u "a quoted declaration word with a splitting expansion flag" 'g=README.md; export "f=${=X}"; cat "$g"'
check 0 "a quoted declaration word with a substitution and a braced name" 'g=README.md; export "f=$(date) ${HOME}"; cat "$g"'
check 0 "a dash word as a script argument in a loop" 'for a in --verbose; do source ./script.sh "$a"; done'

# Codex review of the mode change (2026-11-25): a quoted file option keeps its
# option name, an assignment that runs in a pipeline or in the background does
# not change the parent shell, and a quoted <( is text.
check u "a quoted long file option with a variable value" 'grep "--file=$F" README.md'
check u "a quoted short file option with a variable value" 'grep "-f$F" README.md'
check 0 "a quoted value option with a variable value" 'grep "--color=$C" x README.md'
check 0 "a quoted pattern option with a variable value" 'grep "-e$P" README.md'
check u "an assignment on the left of a pipe" 'f=$X; f=README.md | true; cat "$f"'
check u "an assignment in the background" 'f=$X; f=README.md & wait; cat "$f"'
check u "an export on the left of a pipe" 'f=$X; export f=README.md | true; cat "$f"'
check 0 "an assignment before a pipeline" 'f=README.md; cat "$f" | head -1'
check 0 "a quoted process substitution is text" 'echo "<(cat $F)"'
check u "an array initialisation of a declared name" 'p=.e; declare -a f=($p); cat "${f}nv"'
check u "an array initialisation" 'p=.e; f=($p); cat "${f}nv"'
check 0 "an array initialisation beside a literal read" 'f=(a b); cat README.md'
check u "an indexed assignment leaves the name unknown" 'f=.e; f[1]=x; cat "${f}nv"'
check u "an indexed assignment of a protected name leaves the name unknown" 'f=README.md; f[1]=.e; cat "${f}nv"'

# The mode decides only for an operand that stays unknown: one resolved to a
# protected file blocks with the open policy too, also when an unknown operand
# comes first, and an explicit open warns like the default.
MODES="default open closed"
check 2 "a literal protected name in every mode" 'cat .e"nv"'
check 2 "a fixed-list loop word that names a protected file in every mode" 'for f in nv; do cat ".e$f"; done'
check 2 "a literal assignment that names a protected file in every mode" 'f=.e; cat "${f}nv"'
check 2 "a resolved protected operand after an unknown one" 'cat "$F"; f=.e; cat "${f}nv"'
check 2 "a resolved protected operand after an unknown one in a substitution" 'echo "$(cat "$F")"; f=.e; cat "${f}nv"'
check 2 "a loop option word that names a protected file" 'for o in --file=.e; do grep "${o}nv" README.md; done'
check u "an unknown operand" 'cat "$F"'
MODES=

HOST=codex
check u "codex: cat of a command substitution" "cat $S"
says "codex: the block names its reason" "reason=bash_protected_path_$R;"
check 0 "codex: a literal assignment of an ordinary file" 'f=README.md; cat "$f"'
HOST=

printf '%s unresolved operand checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

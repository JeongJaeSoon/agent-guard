#!/usr/bin/env sh
# Synthetic hook inputs only: none of the command strings below are executed.
# A here-document body that cat or tee only writes is data, not a path the
# command opens; the redirect target, a later command and a body another
# program may run stay in the protected-path text match.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-heredoc.XXXXXX") || exit 1
trap 'rm -rf "$CASE_ROOT"' EXIT HUP INT TERM
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks"
failed=0
checked=0
check() {
  expected=$1
  label=$2
  command=$3
  checked=$((checked + 1))
  jq -nc --arg c "$command" --arg w "${WORKDIR:-$CASE_ROOT}" \
    '{tool_name:"Bash",tool_input:{command:$c,workdir:$w}}' \
    | "$GUARD" hook-pre-tool > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    printf 'ok - heredoc body %s: %s\n' "$checked" "$label"
  else
    printf 'not ok - heredoc body %s: %s: expected %s got %s\n' "$checked" "$label" "$expected" "$status"
    failed=$((failed + 1))
  fi
}
NL='
'
D=$CASE_ROOT/skills

check 0 "skill prose written by cat with a quoted delimiter" \
  "mkdir -p $D/x && cat > $D/x/SKILL.md <<'EOF'${NL}never commit *.p8 keys${NL}EOF"
check 0 "unquoted delimiter, plain text body" \
  "cat > $D/SKILL.md <<EOF${NL}never commit *.p8 keys${NL}EOF"
check 0 "cat to stdout" \
  "cat <<'EOF'${NL}see key.p8${NL}EOF"
check 0 "dash form strips tabs from the terminator" \
  "cat > $D/SKILL.md <<-'EOF'${NL}	see key.p8${NL}	EOF"
check 0 "tee writes a new file" \
  "tee $D/notes.md <<'EOF'${NL}see key.p8${NL}EOF"
check 0 "two heredocs one after the other" \
  "cat > $D/a.md <<'A'${NL}key.p8${NL}A${NL}cat > $D/b.md <<'B'${NL}key.p8${NL}B"

check 2 "operand" "cat secrets.p8"
check 2 "cp operand" "cp x.p8 /tmp"
check 2 "redirect target of the heredoc" \
  "cat > foo.p8 <<'EOF'${NL}hi${NL}EOF"
check 2 "tee target of the heredoc" \
  "tee foo.p8 <<'EOF'${NL}hi${NL}EOF"
check 2 "operand next to a heredoc" \
  "cat ./key.p8 <<'EOF'${NL}x${NL}EOF"
check 2 "command after the body" \
  "cat <<'EOF'${NL}x${NL}EOF${NL}cat ./key.p8"
check 2 "command before the heredoc on the same line" \
  "cat ./key.p8; cat <<'EOF'${NL}x${NL}EOF"
check 2 "body piped to sh" \
  "cat <<'EOF' | sh${NL}cat ./key.p8${NL}EOF"
check 2 "bash reads the body" \
  "bash <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "sh reads the body" \
  "sh <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "python reads the body" \
  "python3 - <<'EOF'${NL}open('./key.p8')${NL}EOF"
check 2 "body written then run" \
  "cat > $D/x.sh <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}sh $D/x.sh"
check 2 "body written then sourced" \
  "cat > $D/x.sh <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}. $D/x.sh"
check 2 "body written then run by python" \
  "cat > $D/r.py <<'EOF'${NL}open('./key.p8').read()${NL}EOF${NL}python3 $D/r.py"
check 2 "body written then run by python through its base name" \
  "cat > $D/r.py <<'EOF'${NL}open('./key.p8').read()${NL}EOF${NL}cd $D && python3 r.py"
check 2 "body written then run by node" \
  "cat > $D/r.js <<'EOF'${NL}require('fs').readFileSync('./key.p8')${NL}EOF${NL}node $D/r.js"
check 2 "body written then run by path" \
  "cat > $D/r <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}chmod +x $D/r && $D/r"
check 2 "written file named again" \
  "cat > $D/r.md <<'EOF'${NL}see key.p8${NL}EOF${NL}ls $D/r.md"
check 2 "interpreter named after the body" \
  "cat > $D/r.md <<'EOF'${NL}see key.p8${NL}EOF${NL}python3 -c 'print(1)'"
check 2 "unquoted delimiter expands a substitution" \
  "cat <<EOF${NL}\$(cat ./key.p8)${NL}EOF"
check 2 "unquoted delimiter expands a backtick" \
  "cat <<EOF${NL}\`cat ./key.p8\`${NL}EOF"
check 2 "heredoc inside a substitution that eval runs" \
  "eval \"\$(cat <<'EOF'${NL}cat ./key.p8${NL}EOF${NL})\""
check 2 "unterminated heredoc" \
  "cat > $D/SKILL.md <<'EOF'${NL}see key.p8"
check 2 "unbalanced quote on the heredoc line" \
  "echo 'x; cat > $D/SKILL.md <<'EOF'${NL}see key.p8${NL}EOF"
check 2 "here-string is not a heredoc body" \
  "bash <<< 'cat ./key.p8'"

# #410/#412: a quoted-delimiter body that gh or git commit reads from stdin
# as a message (`--body-file -`, `-F -`) is data sent to GitHub or stored as
# the commit message, the same text message_value_records exempts as -m or
# --body. Only a first-line command with nothing that can run the stored
# message afterwards qualifies.
REPO=$CASE_ROOT/repo
git init -q "$REPO" || exit 1
check 0 "gh pr create reads its body from stdin" \
  "gh pr create --title 'fix: x' --body-file - <<'EOF'${NL}never commit .env or key.p8${NL}EOF"
check 0 "gh pr comment -F -" \
  "gh pr comment 5 -F - <<'EOF'${NL}see key.p8${NL}EOF"
check 0 "gh issue create --body-file=-" \
  "gh issue create --title t --body-file=- <<'EOF'${NL}see .env${NL}EOF"
check 0 "gh pr review --body-file -" \
  "gh pr review 5 --comment --body-file - <<'EOF'${NL}see key.p8${NL}EOF"
WORKDIR=$REPO check 0 "git commit -F - reads its message from stdin" \
  "git commit -F - <<'EOF'${NL}fix: never read .env or key.p8${NL}EOF"
WORKDIR=$REPO check 0 "git add before and git push after a stdin commit" \
  "git add a.txt && git commit -s -F - <<'EOF' && git push origin HEAD${NL}fix: mention key.p8${NL}EOF"
WORKDIR=$REPO check 0 "git commit --file=- with a dash delimiter" \
  "git commit --file=- <<-'EOF'${NL}	fix: mention key.p8${NL}	EOF"

check 2 "message body behind an unquoted delimiter" \
  "gh pr create --title t --body-file - <<EOF${NL}see key.p8${NL}EOF"
check 2 "message body expands a substitution" \
  "gh pr create --title t --body-file - <<EOF${NL}\$(cat ./key.p8)${NL}EOF"
check 2 "gh output piped to sh" \
  "gh pr create --title t --body-file - <<'EOF' | sh${NL}cat ./key.p8${NL}EOF"
check 2 "gh output piped to xargs cat" \
  "gh pr create --title t --body-file - <<'EOF' | xargs cat${NL}./key.p8${NL}EOF"
check 2 "gh without --body-file -" \
  "gh pr create --title t <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "gh --body-file names a protected file" \
  "gh pr create --title t --body-file ./key.p8 <<'EOF'${NL}x${NL}EOF"
check 2 "gh --editor reads the same stdin" \
  "gh pr create --title t --body-file - --editor <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "gh api -F is a field, not a body" \
  "gh api -F - <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "alias before the message command" \
  "alias gh=sh; gh pr create --body-file - <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "function before the message command" \
  "gh() { sh; }; gh pr create --body-file - <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "PATH assignment before the message command" \
  "PATH=.:\$PATH gh pr create --body-file - <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "eval runs the message command" \
  "eval gh pr create --body-file - <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "earlier line before the message command" \
  "echo hi${NL}gh pr create --body-file - <<'EOF'${NL}cat ./key.p8${NL}EOF"
check 2 "protected read after the message command" \
  "gh pr create --body-file - <<'EOF' && cat ./key.p8${NL}x${NL}EOF"
check 2 "protected read on a later line" \
  "gh pr create --body-file - <<'EOF'${NL}x${NL}EOF${NL}cat ./key.p8"
WORKDIR=$REPO check 2 "git commit pathspec operand next to a stdin message" \
  "git commit -F - ./key.p8 <<'EOF'${NL}msg${NL}EOF"
WORKDIR=$REPO check 2 "git commit -e opens an editor" \
  "git commit -e -F - <<'EOF'${NL}cat ./key.p8${NL}EOF"
WORKDIR=$REPO check 2 "stored commit message run on a later line" \
  "git commit -F - <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}git log -1 --format=%B | sh"
WORKDIR=$REPO check 2 "stored commit message run after the commit" \
  "git commit -F - <<'EOF' && git log -1 --format=%B | sh${NL}cat ./key.p8${NL}EOF"
check 2 "two heredocs with a message consumer" \
  "cat > $D/a.md <<'A'${NL}x${NL}A${NL}gh pr create --body-file - <<'EOF'${NL}cat ./key.p8${NL}EOF"

# A document written by cat or tee and then handed to a gh message command as
# its body file is still data: the command sends the text. The mention must
# be the value of a body-file option of a message command that nothing
# earlier on the line can rename; any other mention keeps the body in the
# scan, since a later command could run the file. A file option of any other
# CLI, the Orca CLI included, does not make the document data.
unset ORCA_CLI_COMMAND
SENT="cat > $D/r.md <<'EOF'${NL}never commit key.p8${NL}EOF${NL}"
RUN="cat > $D/r.md <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}"
check 0 "document sent with gh --body-file" "${SENT}gh pr comment 5 --body-file $D/r.md"
check 0 "document sent with gh -F" "${SENT}gh issue comment 5 -F $D/r.md"
check 0 "document sent with gh after a cd, with a tail" \
  "cd $D; ${SENT}gh pr comment 5 --body-file $D/r.md 2>&1 | tail -1"
check 2 "document handed to orca orchestration send" \
  "${SENT}orca orchestration send --to a --subject s --body-file $D/r.md"
check 2 "document handed to orca orchestration reply, with a tail" \
  "${SENT}orca orchestration reply --id m1 --body-file $D/r.md 2>&1 | tail -1"
check 2 "document handed to the Orca CLI word after a cd" \
  "cd $D; ${SENT}\"\${ORCA_CLI_COMMAND:-orca}\" orchestration reply --id m1 --body-file $D/r.md 2>&1 | tail -1"
check 2 "spec file for a worker" \
  "${SENT}orca orchestration worker-start --item 9 --agent claude --spec-file $D/r.md"
check 2 "item comment file" "${SENT}orca bot item set 9 --status needs-you --comment-file $D/r.md"
check 2 "item comment text file" "${SENT}orca bot item comment 9 --text-file $D/r.md"
check 2 "two documents handed to two orca commands" \
  "cat > $D/a.md <<'A'${NL}key.p8${NL}A${NL}cat > $D/b.md <<'B'${NL}key.p8${NL}B${NL}orca orchestration send --to a --subject s --body-file $D/a.md | tail -1${NL}orca orchestration send --to b --subject s --body-file $D/b.md | tail -1"
check 2 "sent file also run" "${RUN}gh pr comment 5 --body-file $D/r.md; sh $D/r.md"
check 2 "sent file also sourced" "${RUN}orca orchestration send --to a --subject s --body-file $D/r.md && . $D/r.md"
check 2 "sent file also an operand" "${RUN}gh pr comment 5 --body-file $D/r.md $D/r.md"
check 2 "writer with a second, numbered redirection" \
  "cat > $D/r.md 2>$D/err.log <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}gh pr comment 5 --body-file $D/r.md"
check 2 "writer whose output is duplicated to another descriptor" \
  "cat > $D/r.md >&2 <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}gh pr comment 5 --body-file $D/r.md"
check 2 "sent file handed on as the last argument of the message command" \
  "${RUN}gh pr comment 5 --body-file $D/r.md; make -f \$_"
check 2 "sent file handed on as the last argument, braced" \
  "${RUN}gh pr comment 5 --body-file $D/r.md; busybox sh \"\${_}\""
check 2 "sent file run under a quoted spelling" "${RUN}gh pr comment 5 --body-file $D/r.md; sh $D/r''.md"
check 2 "sent file run through a glob" "${RUN}gh pr comment 5 --body-file $D/r.md; bash $D/r.m?"
check 2 "sent file sourced through a glob" "${RUN}gh pr comment 5 --body-file $D/r.md${NL}. $D/r*"
check 2 "sent file made executable and run through a glob" \
  "${RUN}gh pr comment 5 --body-file $D/r.md; chmod +x $D/*; $D/r*"
check 2 "function renames the message command" \
  "orca() { sh \"\$8\"; }; ${RUN}orca orchestration send --to a --subject s --body-file $D/r.md"
check 2 "function defined after the document" \
  "${RUN}orca() { sh \"\$8\"; }; orca orchestration send --to a --subject s --body-file $D/r.md"
check 2 "alias renames the message command" "alias gh=sh; ${RUN}gh pr comment 5 --body-file $D/r.md"
check 2 "PATH assignment before the document" "PATH=.:\$PATH; ${RUN}gh pr comment 5 --body-file $D/r.md"
check 2 "PATH assignment on the message command" "${RUN}PATH=. gh pr comment 5 --body-file $D/r.md"
check 2 "assignment of the Orca CLI variable" \
  "ORCA_CLI_COMMAND=sh; ${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" orchestration send --to a --subject s --body-file $D/r.md"
check 2 "another variable as the command" \
  "O=sh; ${RUN}\$O orchestration send --to a --subject s --body-file $D/r.md"
check 2 "an assignment before the document keeps the scan" \
  "S=$D; cat > \$S/r.md <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}orca orchestration send --to a --subject s --body-file \$S/r.md"
check 2 "the document is the command file itself" \
  "cat > $D/orca <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}orca orchestration send --to a --subject s --body-file $D/orca"
check 2 "file given to an attachment option" "${RUN}orca orchestration send --to a --subject s --item 3 --file $D/r.md"
check 2 "file given to a command that is not a message command" \
  "${RUN}orca terminal send --terminal t --body-file $D/r.md"
check 2 "file given to a shell through the same option name" "${RUN}sh --body-file $D/r.md"
check 2 "message command run by sh -c" "${RUN}sh -c 'gh pr comment 5 --body-file $D/r.md'"
check 2 "message command after a command that is not inert" \
  "${RUN}docker ps; gh pr comment 5 --body-file $D/r.md"
check 2 "message command piped to a shell" "${RUN}gh pr comment 5 --body-file $D/r.md | sh"
check 2 "message command with a glob" "${RUN}gh pr comment 5 --body-file $D/r.md *"
check 2 "message command in the background" "${RUN}gh pr comment 5 --body-file $D/r.md & sh $D/r.md"
check 2 "body file names a protected file" \
  "cat > $D/r.md <<'EOF'${NL}x${NL}EOF${NL}gh pr comment 5 --body-file ./key.p8"
check 2 "document written to a protected path and sent" \
  "cat > $D/key.p8 <<'EOF'${NL}x${NL}EOF${NL}gh pr comment 5 --body-file $D/key.p8"
check 2 "unquoted delimiter runs a substitution in a sent document" \
  "cat > $D/r.md <<EOF${NL}\$(cat ./key.p8)${NL}EOF${NL}gh pr comment 5 --body-file $D/r.md"
check 2 "interpreter named next to a sent document" \
  "${SENT}gh pr comment 5 --body-file $D/r.md; python3 -c 'print(1)'"
check 2 "Orca CLI variable assigned under a quote-split name, file run through a glob" \
  "export ORCA_CLI_''COMMAND=sh${NL}${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" $D/r.m?"
check 2 "Orca CLI variable assigned under a built name, file run through a glob" \
  "x=ORCA_CLI; export \${x}_COMMAND=sh${NL}${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" $D/r.m?"
check 2 "Orca CLI word as a plain command after a document" \
  "${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" $D/r.m?"
check 2 "document sent, then the variable assigned and the file run through a glob" \
  "${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" orchestration send --to a --subject s --body-file $D/r.md${NL}export ORCA_CLI_''COMMAND=sh; \"\${ORCA_CLI_COMMAND:-orca}\" $D/r.m?"
check 2 "document sent, then the Orca CLI word under a wrapper" \
  "${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" orchestration send --to a --subject s --body-file $D/r.md; nohup \"\${ORCA_CLI_COMMAND:-orca}\" $D/r.m?"
check 2 "document sent, then the Orca CLI word in a substitution" \
  "${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" orchestration send --to a --subject s --body-file $D/r.md; echo \"\$( \"\${ORCA_CLI_COMMAND:-orca}\" $D/r.m? )\""
check 2 "document, then a command named by the Orca CLI word" \
  "${SENT}\"\${ORCA_CLI_COMMAND:-orca}\" bot item comment 9 --text 'wrote the notes'"
ORCA_CLI_COMMAND=/bin/sh check 2 "the hook's environment names another program for the Orca CLI word" \
  "${RUN}\"\${ORCA_CLI_COMMAND:-orca}\" orchestration send --to a --subject s --body-file $D/r.md"

# A file the command writes can be run without being named again: by a loop
# over a glob, in a condition, or by a shell that follows a reserved word.
SCRIPT="cat > $D/run.sh <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}"
NOTE="cat > $D/a.md <<'EOF'${NL}see ./key.p8${NL}EOF${NL}"
check 2 "script run by a loop over a glob" "${SCRIPT}for f in $D/*; do sh \"\$f\"; done"
check 2 "script sourced by a loop over a glob" "${SCRIPT}for f in $D/*; do . \"\$f\"; done"
check 2 "script run as the loop variable itself" "${SCRIPT}for f in $D/*; do \"\$f\"; done"
check 2 "script run by a shell in a condition" "${SCRIPT}if sh $D/r*; then echo ok; fi"
check 2 "script run by a shell after then" "${SCRIPT}if true; then sh $D/r*; fi"
check 2 "script run by a shell after else" "${SCRIPT}if false; then :; else sh $D/r*; fi"
check 2 "script run by a shell after elif" "${SCRIPT}if false; then :; elif sh $D/r*; then :; fi"
check 2 "script run by a shell in an until condition" "${SCRIPT}until sh $D/r*; do break; done"
check 2 "script run by a shell in a while loop" "${SCRIPT}while read f; do bash \"\$f\"; done < $D/list"
check 2 "script run by a negated shell" "${SCRIPT}! sh $D/r*"
check 0 "document, then a loop that only prints" "${NOTE}for f in a b; do echo \"\$f\"; done"
check 0 "document, then a condition that runs a script of another name" "${NOTE}if true; then ./build.sh; fi"
check 0 "document, then a loop over a glob that lists names" "${NOTE}for f in $D/*; do ls -l \"\$f\"; done"

# A redirection with a file descriptor number names a written file too.
BODY="<<'EOF'${NL}cat ./key.p8${NL}EOF${NL}"
check 2 "fd-numbered target is the command run next" "cat 1>$D/gh ${BODY}gh pr view 5"
check 2 "fd-numbered append target is the command run next" "cat 1>>$D/gh ${BODY}gh pr view 5"
check 2 "fd number, then a blank before the target" "cat 1> $D/gh ${BODY}gh pr view 5"
check 2 "second target behind an fd number" "cat > $D/r.md 1>$D/gh ${BODY}gh pr view 5"
check 2 "plain target is the command run next" "cat >$D/gh ${BODY}gh pr view 5"
check 2 "two targets in one word" "cat >$D/gh>$D/r.md ${BODY}gh pr view 5"
check 2 "target opened for reading and writing" "cat 1<>$D/gh ${BODY}gh pr view 5"
check 0 "fd-numbered target that is not named again" "cat 1>$D/a.md <<'EOF'${NL}see ./key.p8${NL}EOF"
check 0 "stderr sent to /dev/null beside the target and again later" \
  "cat > $D/a.md 2>/dev/null <<'EOF'${NL}see ./key.p8${NL}EOF${NL}ls $D 2>/dev/null"
check 0 "target glued to the here-document operator" "cat >$D/a.md<<'EOF'${NL}see ./key.p8${NL}EOF"

# Ground truth for the two shapes above: the command is judged by the hook,
# then run in a sandbox whose protected file holds a canary. A blocked
# command must print it when run, which proves the row is a real read; an
# allowed one must not.
SANDBOX=$CASE_ROOT/sandbox
mkdir -p "$SANDBOX/notes" "$SANDBOX/pbin"
canary=agcanary$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
printf 'VALUE=%s\n' "$canary" > "$SANDBOX/key.p8"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/pbin/tool"
chmod +x "$SANDBOX/pbin/tool"
truth() {
  WORKDIR=$SANDBOX
  check "$1" "$2" "$3"
  unset WORKDIR
  checked=$((checked + 1))
  (cd "$SANDBOX" && PATH="$SANDBOX/pbin:$PATH" sh -c "$3") < /dev/null > "$CASE_ROOT/run" 2>&1
  if grep -Fq "$canary" "$CASE_ROOT/run"; then leaked=2; else leaked=0; fi
  if [ "$leaked" -eq "$1" ]; then
    printf 'ok - heredoc body %s: run matches the verdict: %s\n' "$checked" "$2"
  else
    printf 'not ok - heredoc body %s: run does not match the verdict: %s\n' "$checked" "$2"
    failed=$((failed + 1))
  fi
}
truth 2 "script in a directory that a loop over a glob runs" \
  "cat > notes/run.sh <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}for f in notes/*; do sh \"\$f\"; done"
truth 2 "fd-numbered target on PATH that is run by its name" \
  "cat 1>pbin/tool <<'EOF'${NL}cat ./key.p8${NL}EOF${NL}tool"
truth 0 "document behind an fd-numbered target" \
  "cat 1>notes/a.md <<'EOF'${NL}see ./key.p8${NL}EOF"
truth 0 "document, then a loop over a glob that prints names" \
  "cat > notes/b.md <<'EOF'${NL}see ./key.p8${NL}EOF${NL}for f in notes/*.md; do echo \"\$f\"; done"

# A file the same command may run is no document. A here-document body is
# read as data only when the file it is written to is not there yet, or is a
# regular file with one name and no execute bit, at a path the hook can
# place: an absolute one, one under a plain home directory, or a relative one
# in a command with no cd, pushd or popd word, of an event that names its
# workdir. Written to a
# link, to a second name of a file or to an executable file, or to a word only
# run time knows, the body stays in the scan, since a later command name may
# run it. A file named again as a gh body file must also be written behind
# inert commands only: any other may change what the path names. A ran row is
# judged by the hook and then run in a fresh sandbox, as above; the gh, tool
# and helper on the run's PATH are stand-ins made here, and the run's home
# directory is the sandbox. A judged row has a verdict the run cannot show.
RUNBOX=$CASE_ROOT/runbox
runbox() {
  rm -rf "$RUNBOX"
  mkdir -p "$RUNBOX/pbin" "$RUNBOX/notes" || exit 1
  printf 'VALUE=%s\n' "$canary" > "$RUNBOX/key.p8"
  printf '#!/bin/sh\n:\n' > "$RUNBOX/pbin/gh"
  printf '#!/bin/sh\n:\n' > "$RUNBOX/pbin/helper"
  printf '#!/bin/sh\nhelper\n' > "$RUNBOX/pbin/tool"
  chmod +x "$RUNBOX/pbin/gh" "$RUNBOX/pbin/helper" "$RUNBOX/pbin/tool"
  ln -s pbin/gh "$RUNBOX/lnk"
  ln "$RUNBOX/pbin/gh" "$RUNBOX/hrd"
  ln -s ../pbin/gh "$RUNBOX/notes/nlk"
  ln -s nowhere "$RUNBOX/dangle"
  ln -s pbin/gh "$RUNBOX/-lnk"
  ln -s pbin/gh "$RUNBOX/ln''k"
  printf 'old\n' > "$RUNBOX/notes/old.md"
  printf 'old\n' > "$RUNBOX/notes/two.md"
  ln "$RUNBOX/notes/two.md" "$RUNBOX/notes/second"
  ln -s old.md "$RUNBOX/notes/alias.md"
}
judged() { # $1 expected status, $2 label, $3 command
  runbox
  WORKDIR=$RUNBOX
  judged_home=$HOME
  HOME=$RUNBOX
  check "$1" "$2" "$3"
  HOME=$judged_home
  unset WORKDIR
}
ran() { # $1 infrastructure-failure mode (default or closed), $2 expected status, $3 label, $4 command
  [ "$1" != closed ] || { AGENT_GUARD_INFRA_FAILURE_MODE=closed; export AGENT_GUARD_INFRA_FAILURE_MODE; }
  judged "$2" "$3" "$4"
  unset AGENT_GUARD_INFRA_FAILURE_MODE
  checked=$((checked + 1))
  (cd "$RUNBOX" && HOME="$RUNBOX" PATH="$RUNBOX/pbin:/usr/bin:/bin" /bin/sh -c "$4") < /dev/null > "$CASE_ROOT/run" 2>&1
  if grep -Fq "$canary" "$CASE_ROOT/run"; then leaked=2; else leaked=0; fi
  if [ "$leaked" -eq "$2" ]; then
    printf 'ok - heredoc body %s: run matches the verdict: %s\n' "$checked" "$3"
  else
    printf 'not ok - heredoc body %s: run does not match the verdict: %s\n' "$checked" "$3"
    failed=$((failed + 1))
  fi
}
READS="<<'EOF'${NL}#!/bin/sh${NL}cat ./key.p8${NL}EOF${NL}"
READS_UP="<<'EOF'${NL}#!/bin/sh${NL}cat ../key.p8${NL}EOF${NL}"
NAMES="<<'EOF'${NL}see ./key.p8${NL}EOF${NL}"
SENDS="gh pr comment 5 --body-file"
ran default 2 "link to the command, sent as its body file" "cat > lnk ${READS}$SENDS lnk"
ran closed 2 "link to the command, sent as its body file, closed" "cat > lnk ${READS}$SENDS lnk"
ran default 2 "tee writes the link" "tee lnk ${READS}$SENDS lnk"
ran default 2 "link appended to" "cat >> lnk ${READS}$SENDS lnk"
ran default 2 "tee appends to the link" "tee -a lnk ${READS}$SENDS lnk"
ran default 2 "second name of the command file" "cat > hrd ${READS}$SENDS hrd"
ran default 2 "link under an absolute path" "cat > $RUNBOX/lnk ${READS}$SENDS $RUNBOX/lnk"
ran default 2 "link under a quoted name" "cat > 'lnk' ${READS}$SENDS lnk"
ran default 2 "link in the directory the command changes to" "cd ./notes && cat > nlk ${READS_UP}$SENDS nlk"
ran default 2 "link written beside a new document" "tee notes/n.md lnk ${READS}$SENDS notes/n.md"
ran default 2 "link written, another file of that name sent" "cat > lnk ${READS}$SENDS notes/lnk"
ran default 2 "executable file that a later command starts itself" "cat > pbin/helper ${READS}$SENDS pbin/helper; tool"
ran default 2 "second name of a script a shell runs" "cat > notes/two.md ${READS}$SENDS notes/two.md; sh notes/second"
ran default 2 "link to a script a shell runs" "cat > notes/alias.md ${READS}$SENDS notes/alias.md; sh notes/old.md"
ran default 2 "the command file itself" "cat > pbin/gh ${READS}$SENDS pbin/gh"
judged 2 "link to a file that is not there" "cat > dangle ${NAMES}$SENDS dangle"
judged 2 "executable file that nothing in the command names again" "cat > pbin/helper ${NAMES}$SENDS pbin/helper"
judged 2 "relative document after a cd, which the hook does not follow" "cd ./notes && cat > n.md ${NAMES}$SENDS n.md"
judged 2 "document under a quoted tilde, which no shell expands" "cat > '~/n.md' ${NAMES}$SENDS '~/n.md'"
ran default 2 "link under the home directory" "cat > ~/lnk ${READS}$SENDS ~/lnk"
ran default 2 "link after a quoted cd, sent as its body file" "\"cd\" ./notes && cat > nlk ${READS_UP}$SENDS nlk"
judged 2 "relative document in a command that changes directory later" "cat > notes/n.md ${NAMES}cd notes && $SENDS n.md"
judged 2 "document written after the command that sends it" "$SENDS $RUNBOX/notes/n.md${NL}cat > $RUNBOX/notes/n.md ${NAMES}true"
ran default 0 "new document sent as a body file" "cat > notes/n.md ${NAMES}$SENDS notes/n.md"
ran closed 0 "new document sent as a body file, closed" "cat > notes/n.md ${NAMES}$SENDS notes/n.md"
ran default 0 "plain document written again and sent" "cat > notes/old.md ${NAMES}$SENDS notes/old.md"
ran default 0 "tee writes a new document that is sent" "tee notes/n.md ${NAMES}$SENDS notes/n.md"
ran default 0 "new document glued to the operator, sent with -F" "cat >notes/n.md<<'EOF'${NL}see ./key.p8${NL}EOF${NL}gh issue comment 5 -F notes/n.md"
ran default 0 "new document under an absolute path" "cat > $RUNBOX/notes/n.md ${NAMES}$SENDS $RUNBOX/notes/n.md"
ran default 0 "new document under an absolute path after a cd" "cd ./notes && cat > $RUNBOX/notes/n.md ${NAMES}$SENDS $RUNBOX/notes/n.md"
ran default 0 "new document under the home directory" "cat > ~/notes/n.md ${NAMES}$SENDS ~/notes/n.md"
ran default 0 "new document under a quoted name" "cat > \"notes/n.md\" ${NAMES}$SENDS 'notes/n.md'"
ran default 0 "new document after inert commands" "echo start${NL}true; cat > notes/n.md ${NAMES}$SENDS notes/n.md"
ran default 0 "two new documents, one sent" "cat > notes/a.md ${NAMES}cat > notes/b.md ${NAMES}$SENDS notes/a.md"
# The same holds for a file the command does not name again.
ran default 2 "link to the command, not named again" "cat > lnk ${READS}gh pr view 5"
ran closed 2 "link to the command, not named again, closed" "cat > lnk ${READS}gh pr view 5"
ran default 2 "link appended to, not named again" "cat >> lnk ${READS}gh pr view 5"
ran default 2 "tee appends to the link, not named again" "tee -a lnk ${READS}gh pr view 5"
ran default 2 "link under a quoted name, not named again" "cat > 'lnk' ${READS}gh pr view 5"
ran default 2 "link behind an fd number, not named again" "cat 1>lnk ${READS}gh pr view 5"
ran default 2 "second name of the command file, not named again" "cat > hrd ${READS}gh pr view 5"
ran default 2 "executable file a later command starts itself, not named again" "cat > pbin/helper ${READS}tool"
ran default 2 "dash-named link behind tee --" "tee -- -lnk ${READS}gh pr view 5"
ran default 2 "link behind tee --" "tee -- lnk ${READS}gh pr view 5"
judged 2 "tee word before -- that is no option tee knows" "tee -x notes/n.md ${NAMES}tool"
ran default 2 "link under a name that holds a quote character" "cat > \"ln''k\" ${READS}gh pr view 5"
ran default 2 "link after a cd in a condition" "if true; then cd ./notes; fi${NL}cat > nlk ${READS_UP}gh pr view 5"
ran default 2 "link after a cd behind an assignment" "X=1 cd ./notes${NL}cat > nlk ${READS_UP}gh pr view 5"
ran default 2 "target only known at run time" "L=lnk; cat > \$L ${READS}gh pr view 5"
ran default 2 "link after a cd spelled with quotes inside, not named again" "c''d ./notes && cat > nlk ${READS_UP}gh pr view 5"
judged 2 "relative document after pushd, not named again" "pushd ./notes; cat > n.md ${NAMES}tool"
judged 2 "relative document after a cd, not named again" "cd ./notes && cat > n.md ${NAMES}tool"
ran default 0 "new document, then a command that does not name it" "cat > notes/n.md ${NAMES}tool"
ran default 0 "new document after prose that mentions cd" "echo 'use cd to navigate'; cat > notes/n.md ${NAMES}tool"
ran default 0 "new document after a command that only prints cd" "echo pushd popd cd; cat > notes/n.md ${NAMES}tool"
ran default 0 "new document under a partly quoted name" "cat > notes/\"n\".md ${NAMES}tool"
ran default 0 "document printed to the standard error stream" "cat > /dev/stderr ${NAMES}true"
ran default 0 "new document behind tee --" "tee -a -- notes/n.md ${NAMES}tool"
ran default 0 "tee line that ends in another command" "tee notes/n.md <<'EOF'; ls -la${NL}see ./key.p8${NL}EOF"
ran default 0 "new document whose body mentions cd" "cat > notes/n.md <<'EOF'${NL}run cd first, then see ./key.p8${NL}EOF${NL}tool"
ran default 0 "new document in a directory made first" "mkdir -p notes/d && cat > notes/d/x.md ${NAMES}tool"
ran default 0 "plain document written again, then a command that does not name it" "cat > notes/old.md ${NAMES}tool"
ran default 0 "new document under an absolute path after a cd" "cd ./notes && cat > $RUNBOX/notes/n.md ${NAMES}tool"
# An event that names no workdir places no relative name; an absolute one
# needs none.
workdirless() { # $1 expected status, $2 label, $3 command
  runbox
  checked=$((checked + 1))
  jq -nc --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}' \
    | (cd "$RUNBOX" && "$GUARD" hook-pre-tool) > "$CASE_ROOT/out" 2> "$CASE_ROOT/err"
  status=$?
  if [ "$status" -eq "$1" ]; then
    printf 'ok - heredoc body %s: %s\n' "$checked" "$2"
  else
    printf 'not ok - heredoc body %s: %s: expected %s got %s\n' "$checked" "$2" "$1" "$status"
    failed=$((failed + 1))
  fi
}
workdirless 2 "relative document in an event with no workdir" "cat > notes/n.md ${NAMES}$SENDS notes/n.md"
workdirless 0 "absolute document in an event with no workdir" "cat > $RUNBOX/notes/n.md ${NAMES}$SENDS $RUNBOX/notes/n.md"

printf '%s heredoc body checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

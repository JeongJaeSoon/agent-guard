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

printf '%s heredoc body checks, %s failed\n' "$checked" "$failed"
[ "$failed" -eq 0 ]

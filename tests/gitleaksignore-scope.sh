#!/bin/sh
# Which scans apply a repository's .gitleaksignore.
#
# Hook input (shell command text, tool output, proposed file content, a file a
# tool wrote, a prompt) is not the repository's content, and its scan does not
# read that file. Scans of the repository's own content (scan-staged,
# scan-working-tree, scan-path as the GitHub Action runs it, and the commit
# check) keep applying it.
#
# Three parts: the function that names the private scan directory; a native
# stand-in for gitleaks that reports nothing beside an ignore file (needs a C
# compiler); and the official gitleaks with real fingerprints:
#
#   AGENT_GUARD_TEST_REAL_GITLEAKS=/abs/gitleaks sh tests/gitleaksignore-scope.sh
#
# Unset, the gitleaks on PATH is used; set but empty, that part is skipped.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
CFG="${GUARD%/bin/agent-guard}/config/gitleaks.toml"
REAL=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || :)}
# A stand-in on PATH is not the official release.
case "$([ -n "$REAL" ] && "$REAL" version 2>/dev/null)" in ''|*[!0-9.]*) REAL= ;; esac
pass=0 fail=0
ok() { pass=$((pass + 1)); printf 'ok - %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*"; }
# expect LABEL 'CONDITION': CONDITION is shell text, evaluated whole.
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-ignore-scope.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$CASE/bin" "$CASE/fake" "$CASE/lib" "$CASE/none" "$CASE/home" "$CASE/xs" "$CASE/plain" \
  "$CASE/fn" "$CASE/dirs" "$CASE/stub"
STATE="$CASE/xs/agent-guard"
IGNORE=.gitleaksignore
ORIGINAL_PATH=$PATH
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/xs"
export AGENT_GUARD_GITLEAKS_BIN_DIR="$CASE/none" AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_PII_HOOK_MODE=off AGENT_GUARD_PROMPT_GUARD_MODE=block
export AGENT_GUARD_WARNING_DIR="$CASE/warnings" AGENT_GUARD_CODEX_TRUST_CHECK=off
unset AGENT_GUARD_GITLEAKS_BIN AGENT_GUARD_GITLEAKS_CONFIG AGENT_GUARD_LOG_MODE \
  AGENT_GUARD_GITLEAKS_HELPER AGENT_GUARD_INFRA_FAILURE_MODE AGENT_GUARD_SCAN_CACHE \
  AGENT_GUARD_SHELL_INIT_VERSION AGENT_GUARD_DENY_READ_MODE AI_AGENT GITLEAKS_CONFIG_TOML \
  FAKE_GITLEAKS_CALLS FAKE_GITLEAKS_STDIN_EXIT FAKE_GITLEAKS_STDIN_NOISE FAKE_GITLEAKS_STDIN_IGNORE

# --- the private scan directory -----------------------------------------------
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE/fn" gitleaks_hook_scan_dir || exit 1
# shellcheck disable=SC1091
. "$CASE/fn/gitleaks_hook_scan_dir.sh"
# scan_dir RUNDIR CONFIG: "status directory config" as the CLI would take them
# in $CASE/plain.
scan_dir() {
  (cd "$CASE/plain" && AGENT_GUARD_RUNDIR=$1 && GITLEAKS_CONFIG=$2 \
    && { gitleaks_hook_scan_dir; echo "$? $GITLEAKS_HOOK_CWD $GITLEAKS_HOOK_CONFIG"; })
}
mkdir "$CASE/dirs/private" "$CASE/dirs/listed" "$CASE/dirs/linked"
: >"$CASE/dirs/listed/$IGNORE"
ln -s "$CASE/dirs/none" "$CASE/dirs/linked/$IGNORE"
ln -s "$CASE/dirs/private" "$CASE/dirs/link"
expect 'a private run directory is taken as it is, with an absolute config' \
  '[ "$(scan_dir "$CASE/dirs/private" "$CFG")" = "0 $CASE/dirs/private $CFG" ]'
expect 'a relative config is passed as it resolves from the current directory' \
  '[ "$(scan_dir "$CASE/dirs/private" custom.toml)" = "0 $CASE/dirs/private $CASE/plain/custom.toml" ]'
for spec in "holds an ignore file|$CASE/dirs/listed" "holds a dangling ignore link|$CASE/dirs/linked" \
    "is a symlink|$CASE/dirs/link" "is missing|$CASE/dirs/missing" 'is relative|../dirs/private' 'is unset|'; do
  r=$(scan_dir "${spec#*|}" "$CFG")
  expect "a run directory that ${spec%%|*} is refused" '[ "${r%% *}" = 1 ]'
done

# --- which configs may be scanned from another directory ------------------------
# gitleaks resolves a relative [extend] path against its working directory,
# so a config is scanned from the private one only when it, and each file it
# extends, provably extends no relative path.
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE/fn" gitleaks_config_extends_no_relative_path || exit 1
# shellcheck disable=SC1091
. "$CASE/fn/gitleaks_config_extends_no_relative_path.sh"
C="$CASE/configs"
mkdir "$C"
# config NAME LINE...: writes $C/NAME from the lines.
config() {
  ag_name=$1
  shift
  printf '%s\n' "$@" >"$C/$ag_name"
}
extends_ok() { (cd "$CASE/plain" && GITLEAKS_CONFIG=$1 && gitleaks_config_extends_no_relative_path); }
config plain.toml 'title = "rules"' '[[rules]]' 'id = "a"' "regex = '''x'''"
# The relative paths below resolve from the directory the check runs in.
cp "$C/plain.toml" "$CASE/plain/plain.toml"
config default.toml '[extend]' 'useDefault = true'
config double.toml '[extend]' "path = \"$C/plain.toml\""
config single.toml '[extend]' "path = '$C/plain.toml'"
config spaced.toml '  [ Extend ]  # the base' "  Path = \"$C/plain.toml\"   # absolute"
printf '[extend]\r\npath = "%s"\r\n' "$C/plain.toml" >"$C/crlf.toml"
config word.toml '[extend]' 'useDefault = true' '[[rules]]' 'id = "a"' 'description = "extend = the word in a value"' "regex = '''extend\\.path'''"
config chain.toml '[extend]' "path = \"$C/double.toml\""
mkdir "$C/with#hash"
cp "$C/plain.toml" "$C/with#hash/plain.toml"
config hash.toml '[extend]' "path = \"$C/with#hash/plain.toml\" # the # above is part of the path"
config allowlist.toml '[extend]' 'useDefault = true' '[[allowlists]]' 'regexes = [' '  "foo\\.bar",' "  'extend\\.path'," ']'
config quoted-rules.toml '[extend]' 'useDefault = true' '[["rules"]]' 'id = "a"' "regex = '''x'''"
config regex-equals.toml '[[allowlists]]' 'regexes = [' '  "(?i)key\\s*=\\s*extend",' "  '''path\\s*=\\s*extend'''," ']'
config multiline-regex.toml '[[rules]]' 'id = "a"' "regex = '''(?x)" '[\w-]+ = "extend"' '[extend]' 'path = "plain.toml"' "'''"
config empty-path.toml '[extend]' 'useDefault = true' 'path = ""  # none'
config triple.toml '[extend]' "disabledRules = ['''a''']" "path = '$C/plain.toml'"
config nested-word.toml '[[rules]]' 'id = "a"' 'keywords = [' '  ["extend"]' ']'
config quote-end.toml '[[rules]]' 'id = "a"' "regex = '''a''''" 'description = """b"""""' "path = '''c'''''"
config nested-array.toml '[extend]' 'disabledRules = [' '  [ "a" ]' ']' "path = \"$C/plain.toml\""
config bracket-in-string.toml '[extend]' 'disabledRules = [' '  "a[b",  # ]' ']' "path = '$C/plain.toml'"
config comment-delimiter.toml '[extend]' "useDefault = true # '''" 'disabledRules = ["a"] # """'
config array.toml '[extend]' 'useDefault = true' 'disabledRules = [' '  "generic-api-key",' "  'aws-access-token' ]"
config relative.toml '[extend]' 'path = "plain.toml"'
config parent.toml '[extend]' 'path = "../configs/plain.toml"'
config relative-single.toml '[extend]' "path = 'plain.toml'"
config escaped.toml '[extend]' "path = \"\\u002F${C#/}/plain.toml\""
config dotted.toml 'extend.path = "plain.toml"'
config inline.toml 'extend = { path = "plain.toml" }'
config quoted-table.toml '["extend"]' 'path = "plain.toml"'
config literal-table.toml "['extend']" 'path = "plain.toml"'
config escaped-key.toml '"\u0065xtend" = { path = "plain.toml" }'
config quoted-key.toml '[extend]' '"path" = "plain.toml"'
config dotted-path.toml '[extend]' 'path.x = "plain.toml"'
config multiline.toml '[extend]' 'note = """' '[other]' '"""' 'path = "plain.toml"'
config twice.toml '[extend]' "path = \"$C/plain.toml\"" '[extend]' 'path = "plain.toml"'
config two-paths.toml '[extend]' "path = \"$C/plain.toml\"" 'path = "plain.toml"'
config subtable.toml '[extend.more]' "path = \"$C/plain.toml\""
config quoted-dotted.toml '"extend.path" = "plain.toml"'
config nested-relative.toml '[extend]' 'disabledRules = [' '  [ "a" ]' ']' 'path = "plain.toml"'
config string-opens-nothing.toml "x = \"'''\"" '[extend]' 'path = "plain.toml"'
config comment-opens-nothing.toml "x = 1 # '''" '[extend]' 'path = "plain.toml"'
config escaped-quote.toml "x = \"a\\\"'''\"" '[extend]' 'path = "plain.toml"'
config after-string.toml "x = '''" '[extend]' "'''" '[extend]' 'path = "plain.toml"'
config quote-end-relative.toml "x = '''a''''" '[extend]' 'path = "plain.toml"'
config unbalanced.toml '[extend]' 'disabledRules = [ "a" ] ]' 'path = "plain.toml"'
config nested-path.toml '[extend]' '"more.path" = "plain.toml"'
config missing.toml '[extend]' "path = \"$C/none.toml\""
config chain-relative.toml '[extend]' "path = \"$C/relative.toml\""
config loop.toml '[extend]' "path = \"$C/loop.toml\""
# gitleaks opens the file a config extends and the file that one extends, and
# no further (pinned below with the official gitleaks): a path in the third
# file is not opened, so it is not checked.
config deep.toml '[extend]' "path = \"$C/deep2.toml\""
config deep2.toml '[extend]' "path = \"$C/deep3.toml\""
config deep3.toml '[extend]' "path = \"$C/deep4.toml\""
config deep4.toml '[extend]' "path = \"$C/plain.toml\""
config third-relative.toml '[extend]' "path = \"$C/third2.toml\""
config third2.toml '[extend]' "path = \"$C/relative.toml\""
config third-missing.toml '[extend]' "path = \"$C/third3.toml\""
config third3.toml '[extend]' "path = \"$C/missing.toml\""
config trailing.toml '[extend]' "path = \"$C/plain.toml\" plain.toml"
# awk reads an operand of this form as an assignment, not as a file.
config 'rules=1.toml' '[extend]' 'path = "plain.toml"'
expect 'the bundled config extends no relative path' 'extends_ok "$CFG"'
for name in plain default double single spaced crlf word chain hash allowlist quoted-rules regex-equals \
    nested-array bracket-in-string comment-delimiter multiline-regex empty-path triple nested-word quote-end array \
    loop deep third-relative third-missing; do
  expect "a config that extends no relative path may be scanned from another directory ($name)" \
    'extends_ok "$C/$name.toml"'
done
for name in relative parent relative-single escaped dotted inline quoted-table literal-table escaped-key \
    quoted-key dotted-path multiline twice two-paths subtable quoted-dotted nested-path nested-relative \
    string-opens-nothing comment-opens-nothing escaped-quote after-string quote-end-relative unbalanced missing \
    chain-relative trailing; do
  expect "a config that may extend a relative path is refused ($name)" '! extends_ok "$C/$name.toml"'
done
expect 'a config whose name reads as an awk assignment is still the file that is checked' \
  '! (cd "$C" && GITLEAKS_CONFIG="rules=1.toml" && gitleaks_config_extends_no_relative_path </dev/null)'
# The verdict kept in the run directory is for one file: a relative name is
# another file after a hook has changed directory.
mkdir "$C/good" "$C/bad" "$CASE/dirs/kept"
cp "$C/default.toml" "$C/good/rules.toml"
cp "$C/relative.toml" "$C/bad/rules.toml"
scan_twice() { # $1 first directory, $2 second, $3 config -> the two statuses
  (
    AGENT_GUARD_RUNDIR="$CASE/dirs/kept" GITLEAKS_CONFIG=$3 AGENT_GUARD_GITLEAKS_CONFIG=$3
    cd "$1" && gitleaks_hook_scan_dir
    first=$?
    cd "$2" && gitleaks_hook_scan_dir
    echo "$first $?"
  )
}
expect 'a relative config name is checked again in another directory' \
  '[ "$(scan_twice "$C/good" "$C/bad" rules.toml)" = "0 2" ] && [ "$(scan_twice "$C/bad" "$C/good" rules.toml)" = "2 0" ]'
expect 'an absolute config name is the same file wherever the hook goes' \
  '[ "$(scan_twice "$C/good" "$C/bad" "$C/good/rules.toml")" = "0 0" ] && [ "$(scan_twice "$C/good" "$C/bad" "$C/bad/rules.toml")" = "2 2" ]'
# No verdict is kept: a config that changes between two scans of one hook is
# read again.
changed=$(
  AGENT_GUARD_RUNDIR="$CASE/dirs/kept" GITLEAKS_CONFIG="$C/changing.toml" AGENT_GUARD_GITLEAKS_CONFIG="$C/changing.toml"
  cd "$CASE/plain" || exit 1
  cp "$C/default.toml" "$C/changing.toml" && gitleaks_hook_scan_dir
  first=$?
  cp "$C/relative.toml" "$C/changing.toml" && gitleaks_hook_scan_dir
  echo "$first $?"
)
expect 'a config that changes between two scans is checked again' '[ "$changed" = "0 2" ]'
expect 'a relative AGENT_GUARD_GITLEAKS_CONFIG is read from the current directory' \
  '(cd "$C" && GITLEAKS_CONFIG=double.toml && gitleaks_config_extends_no_relative_path) \
     && ! (cd "$C" && GITLEAKS_CONFIG=relative.toml && gitleaks_config_extends_no_relative_path)'

# --- where a scan of hook input starts -------------------------------------------
# The directory is checked once more where the scan starts: nothing is run in
# a directory that holds an ignore file.
sh "$ROOT/tests/helpers/extract-functions.sh" "$GUARD" "$CASE/fn" gitleaks_exec || exit 1
exec_in() { # $1 directory -> what a command started there printed, and the status
  (
    gitleaks_helper_selected() { return 1; }
    # shellcheck disable=SC1091
    . "$CASE/fn/gitleaks_exec.sh"
    cd "$CASE/plain" && gitleaks_exec "$1" /bin/echo started
    echo "$?"
  ) 2>/dev/null | tr '\n' ' '
}
expect 'a command is started in a private directory' '[ "$(exec_in "$CASE/dirs/private")" = "started 0 " ]'
expect 'nothing is started in a directory that holds an ignore file, or behind an ignore link' \
  '[ "$(exec_in "$CASE/dirs/listed")" = "2 " ] && [ "$(exec_in "$CASE/dirs/linked")" = "2 " ]'
expect 'a directory that cannot be entered is a failed scan, not a finding' '[ "$(exec_in "$CASE/dirs/missing")" = "2 " ]'
# / belongs to root; as root every directory passes the owner test.
expect 'nothing is started in a directory that another user owns' '[ "$(id -u)" = 0 ] || [ "$(exec_in /)" = "2 " ]'

# --- drivers shared by both scanners --------------------------------------------
new_repo() {
  git init -q "$1" && git -C "$1" config user.email t@example.test \
    && git -C "$1" config user.name test && git -C "$1" config commit.gpgsign false
}
# work_repo DIR: a repository to run hooks in, with one ignored file that
# holds the value.
work_repo() {
  WORK=$1
  new_repo "$WORK"
  mkdir "$WORK/kept"
  printf 'kept/\n' >"$WORK/.gitignore"
  printf 'note %s\n' "$pat" >"$WORK/kept/out.txt"
  git -C "$WORK" add .gitignore && git -C "$WORK" commit -q -m init
}
event() { # $1 name -> the hook event
  case "$1" in
    bash-secret) jq -nc --arg c "echo $pat" --arg d "$WORK" \
      '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"ignore-scope"}' ;;
    bash-clean) jq -nc --arg d "$WORK" \
      '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"ls -la src"},cwd:$d,session_id:"ignore-scope"}' ;;
    write-secret) jq -nc --arg c "note $pat" --arg d "$WORK" \
      '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:($d + "/notes.txt"),content:$c},cwd:$d,session_id:"ignore-scope"}' ;;
    edit-secret) jq -nc --arg c "note $pat" --arg d "$WORK" \
      '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:($d + "/notes.txt"),old_string:"a",new_string:$c},cwd:$d,session_id:"ignore-scope"}' ;;
    mcp-secret) jq -nc --arg c "note $pat" --arg d "$WORK" \
      '{hook_event_name:"PreToolUse",tool_name:"mcp__notes__save",tool_input:{text:$c},cwd:$d,session_id:"ignore-scope"}' ;;
    output-secret) jq -nc --arg o "note $pat" --arg d "$WORK" \
      '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"cat notes.txt"},tool_response:{stdout:$o,stderr:"",interrupted:false},cwd:$d,session_id:"ignore-scope"}' ;;
    output-clean) jq -nc --arg d "$WORK" \
      '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"ls"},tool_response:{stdout:"a\nb\n",stderr:"",interrupted:false},cwd:$d,session_id:"ignore-scope"}' ;;
    written-secret) jq -nc --arg d "$WORK" \
      '{hook_event_name:"PostToolUse",tool_name:"Write",tool_input:{file_path:($d + "/kept/out.txt"),content:"x"},tool_response:{type:"create",filePath:($d + "/kept/out.txt")},cwd:$d,session_id:"ignore-scope"}' ;;
    prompt-secret) jq -nc --arg p "please use $pat" --arg d "$WORK" \
      '{hook_event_name:"UserPromptSubmit",prompt:$p,cwd:$d,session_id:"ignore-scope"}' ;;
    prompt-clean) jq -nc --arg d "$WORK" \
      '{hook_event_name:"UserPromptSubmit",prompt:"summarize the README",cwd:$d,session_id:"ignore-scope"}' ;;
  esac
}
hook_of() {
  case "$1" in
    output-*|written-*) echo hook-post-tool ;;
    prompt-*) echo hook-user-prompt ;;
    *) echo hook-pre-tool ;;
  esac
}
# run HOST NAME [VAR=value...]: one hook call in $WORK, with no state left
# from an earlier one -> h.out h.err h.status
run() {
  ag_host=$1 ag_name=$2
  shift 2
  rm -rf "$STATE" "$AGENT_GUARD_WARNING_DIR"
  (cd "$WORK" && event "$ag_name" \
    | env AGENT_GUARD_HOOK_HOST="$ag_host" "$@" "$GUARD" "$(hook_of "$ag_name")" >"$CASE/h.out" 2>"$CASE/h.err")
  echo "$?" >"$CASE/h.status"
}
same_as() { cmp -s "$CASE/h.out" "$1.out" && cmp -s "$CASE/h.err" "$1.err" && cmp -s "$CASE/h.status" "$1.status"; }
refused() { # the call was refused, or its output came back without the value
  case "$1" in
    output-*) [ -s "$CASE/h.out" ] && ! grep -Fq "$pat" "$CASE/h.out" ;;
    *) [ "$(cat "$CASE/h.status")" = 2 ] ;;
  esac
}
SECRET_CASES='bash-secret write-secret edit-secret mcp-secret output-secret written-secret prompt-secret'
CLEAN_CASES='bash-clean output-clean prompt-clean'
# hook_plain TAG: the verdicts in $WORK before it holds an ignore file, which
# every later run is compared with.
hook_plain() {
  for host in claude codex; do
    for name in $SECRET_CASES $CLEAN_CASES; do
      run "$host" "$name"
      for part in out err status; do cp "$CASE/h.$part" "$CASE/$1-$host-$name.$part"; done
      case "$name" in
        *-secret) expect "$1 control: without an ignore file $host $name is refused" 'refused "$name"' ;;
        *) expect "$1 control: without an ignore file $host $name passes" '[ "$(cat "$CASE/h.status")" = 0 ]' ;;
      esac
    done
  done
}
# hook_beside TAG [client]: the same calls once $WORK holds the ignore file.
hook_beside() {
  tag=$1
  for host in claude codex; do
    for name in $SECRET_CASES $CLEAN_CASES; do
      run "$host" "$name"
      expect "$1: beside a matching ignore file $host $name answers as without one" \
        'same_as "$CASE/$tag-$host-$name"'
      case "$name" in
        *-secret) expect "$1: beside a matching ignore file $host $name is refused" 'refused "$name"' ;;
      esac
      run "$host" "$name" AGENT_GUARD_SCAN_CACHE=off
      expect "$1: beside a matching ignore file $host $name answers the same with the scan cache off" \
        'same_as "$CASE/$tag-$host-$name"'
      [ "${2:-}" = client ] || continue
      : >"$CALLS"
      run "$host" "$name" AGENT_GUARD_GITLEAKS_HELPER="$CLIENT"
      expect "$1: beside a matching ignore file $host $name answers the same through the scan client" \
        'same_as "$CASE/$tag-$host-$name"'
      expect "$1: the scan client for $host $name starts where no ignore file is" \
        '[ -s "$CALLS" ] && ! grep -Fvxq private "$CALLS"'
    done
  done
}
# status_in DIR COMMAND...: the exit status of an agent-guard command run in DIR.
status_in() {
  ag_dir=$1
  shift
  (cd "$ag_dir" && "$GUARD" "$@" >"$CASE/s.out" 2>"$CASE/s.err")
  echo $?
}
# keeps LABEL DIR COMMAND...: the scan finds the value, and no longer once the
# repository's ignore file lists the finding. $entries holds its lines, and
# $with_client says whether the scan client is tried too.
keeps() {
  ag_label=$1 ag_dir=$2
  shift 2
  rm -f "$ag_dir/$IGNORE"
  plain_status=$(status_in "$ag_dir" "$@")
  printf '%s\n' "$entries" >"$ag_dir/$IGNORE"
  ignore_status=$(status_in "$ag_dir" "$@")
  expect "$ag_label finds the value without an ignore file" '[ "$plain_status" = 1 ]'
  expect "$ag_label applies the repository's ignore file" '[ "$ignore_status" = 0 ]'
  [ -n "$with_client" ] || return 0
  : >"$CALLS"
  client_status=$(AGENT_GUARD_GITLEAKS_HELPER="$CLIENT" status_in "$ag_dir" "$@")
  expect "$ag_label applies it through the scan client too, which starts beside it" \
    '[ "$client_status" = 0 ] && ! grep -Fxq private "$CALLS"'
}
# repository_scans TAG: scan-staged, scan-working-tree and the commit check a
# hook runs before git commit, each over a repository of its own.
repository_scans() {
  new_repo "$CASE/$1-staged"
  printf 'note %s\n' "$pat" >"$CASE/$1-staged/notes.txt"
  git -C "$CASE/$1-staged" add notes.txt
  keeps "$1: scan-staged" "$CASE/$1-staged" scan-staged

  new_repo "$CASE/$1-tree"
  printf 'first line\n' >"$CASE/$1-tree/notes.txt"
  git -C "$CASE/$1-tree" add notes.txt && git -C "$CASE/$1-tree" commit -q -m init
  printf 'note %s\n' "$pat" >>"$CASE/$1-tree/notes.txt"
  keeps "$1: scan-working-tree (a tracked change)" "$CASE/$1-tree" scan-working-tree

  # The ignore file itself stays out of the scanned stream, so the value
  # keeps an early line.
  new_repo "$CASE/$1-untracked"
  printf '%s\n' "$IGNORE" >"$CASE/$1-untracked/.gitignore"
  git -C "$CASE/$1-untracked" add .gitignore && git -C "$CASE/$1-untracked" commit -q -m init
  printf 'note %s\n' "$pat" >"$CASE/$1-untracked/notes.txt"
  keeps "$1: scan-working-tree (the untracked-files pass)" "$CASE/$1-untracked" scan-working-tree

  # The commit check reads the same content as scan-staged, the repository's own.
  new_repo "$CASE/$1-commit"
  git -C "$CASE/$1-commit" commit -q --allow-empty -m init
  printf 'note %s\n' "$pat" >"$CASE/$1-commit/notes.txt"
  git -C "$CASE/$1-commit" add notes.txt
  plain_status=$(commit_status "$CASE/$1-commit")
  printf '%s\n' "$entries" >"$CASE/$1-commit/$IGNORE"
  ignore_status=$(commit_status "$CASE/$1-commit")
  expect "$1: the commit check finds the staged value without an ignore file" '[ "$plain_status" = 2 ]'
  expect "$1: the commit check applies the repository's ignore file" '[ "$ignore_status" = 0 ]'
}
commit_status() {
  rm -rf "$STATE" "$AGENT_GUARD_WARNING_DIR"
  (cd "$1" && jq -nc --arg d "$1" \
      '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"git commit -m notes"},cwd:$d,session_id:"ignore-scope"}' \
    | AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool >/dev/null 2>&1)
  echo $?
}
# One PreToolUse Bash call in $EDGE with extra settings -> its status; the
# hook's stderr stays in e.err.
EDGE="$CASE/edge"
mkdir -p "$EDGE/tmp" "$EDGE/real/sub"
ln -s "$EDGE/real/sub" "$EDGE/link"
cp "$CFG" "$EDGE/custom.toml"
printf '[extend]\npath = "%s"\n' "$EDGE/custom.toml" >"$EDGE/extend-absolute.toml"
printf '[extend]\npath = "custom.toml"\n' >"$EDGE/extend-relative.toml"
edge_n=0
edge() {
  ag_command=$1
  shift
  edge_n=$((edge_n + 1))
  rm -rf "$STATE" "$AGENT_GUARD_WARNING_DIR"
  (cd "$EDGE" && jq -nc --arg c "$ag_command" --arg d "$EDGE" --arg s "ignore-scope-$edge_n" \
      '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:$s}' \
    | env AGENT_GUARD_HOOK_HOST=claude "$@" "$GUARD" hook-pre-tool >"$CASE/e.out" 2>"$CASE/e.err")
  echo $?
}

# A version manager's shim: it runs SHIM_TARGET where a version is set (a
# .tool-versions file in its directory, or SHIM_GLOBAL), and elsewhere fails
# with SHIM_FAIL. SHIM_QUIET drops what the target prints for a scan, as the
# official gitleaks prints nothing for a finding.
mkdir "$CASE/shim"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' '[ -n "${SHIM_GLOBAL:-}" ] || [ -f ./.tool-versions ] || { echo "shim: no version is set here" >&2; exit "${SHIM_FAIL:-126}"; }'
  printf '%s\n' '[ -z "${SHIM_QUIET:-}" ] || [ "${1:-}" != stdin ] || exec "$SHIM_TARGET" "$@" >/dev/null 2>&1'
  printf '%s\n' 'exec "$SHIM_TARGET" "$@"'
} >"$CASE/shim/gitleaks"
chmod +x "$CASE/shim/gitleaks"

# --- a native stand-in that reports nothing beside an ignore file --------------
# It runs wherever a C compiler is, so every kind of hook input is covered
# without the official gitleaks: the stand-in drops each finding when an
# ignore file sits in its working directory, as the real gitleaks does for a
# listed one.
if command -v cc >/dev/null 2>&1 \
    && cc -O2 -o "$CASE/fake/gitleaks" "$ROOT/bench/process-count/fake-gitleaks.c" 2>/dev/null; then
  export AGENT_GUARD_GITLEAKS_BIN="$CASE/fake/gitleaks" FAKE_GITLEAKS_STDIN_IGNORE=1
  pat="AGENT_GUARD_TEST_""SECRET"
  entries='# any content'
  with_client=
  work_repo "$CASE/stand-in"
  hook_plain stand-in
  # Committed, as a cloned repository carries it; the work tree stays clean,
  # so the changed-file check after a tool call has nothing of its own to scan.
  printf '%s\n' "$entries" >"$WORK/$IGNORE"
  git -C "$WORK" add "$IGNORE" && git -C "$WORK" commit -q -m ignore
  (cd "$WORK" && printf 'echo %s\n' "$pat" | "$AGENT_GUARD_GITLEAKS_BIN" stdin >/dev/null 2>&1); silenced=$?
  (cd "$CASE/none" && printf 'echo %s\n' "$pat" | "$AGENT_GUARD_GITLEAKS_BIN" stdin >/dev/null 2>&1); found=$?
  expect 'stand-in control: run beside the ignore file it reports nothing, and elsewhere a finding' \
    '[ "$silenced" = 0 ] && [ "$found" = 1 ]'
  hook_beside stand-in
  repository_scans stand-in
  # No run directory: mktemp -d fails while mktemp for a file still works.
  printf '#!/bin/sh\n[ "$1" != -d ] || exit 1\nexec "%s" "$@"\n' "$(command -v mktemp)" >"$CASE/stub/mktemp"
  chmod +x "$CASE/stub/mktemp"
  r=$(edge 'ls -la src' PATH="$CASE/stub:$PATH")
  expect 'without a private run directory hook input is not scanned, and the call is refused rather than passed' \
    '[ "$r" = 2 ] && grep -Fq "no private directory to scan shell command from" "$CASE/e.err"'
  # A TMPDIR whose logical reading (a symlink before a .. part) names another
  # directory than the one mktemp made: the scan enters the real one.
  expect 'a TMPDIR with a symlink before a .. part still scans hook input' \
    '[ "$(edge "ls -la src" TMPDIR="$EDGE/link/..") $(edge "echo $pat" TMPDIR="$EDGE/link/..")" = "0 2" ]'
  run claude output-secret TMPDIR="$EDGE/link/.."
  expect 'with that TMPDIR tool output is masked as elsewhere' 'same_as "$CASE/stand-in-claude-output-secret"'
  # A custom config that extends a relative path would name another file from
  # the private directory: hook input is not scanned (the scanner is not even
  # started), and the infrastructure policy decides the call.
  : >"$CASE/fake-calls"
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-relative.toml" FAKE_GITLEAKS_CALLS="$CASE/fake-calls")
  expect 'a config that extends a relative path is a scan of hook input that did not run, and the hook says why' \
    '[ "$r" = 2 ] && grep -Fq "relative [extend] path" "$CASE/e.err" \
       && ! grep -Fq "secret-like value detected" "$CASE/e.err" && ! grep -Fxq stdin "$CASE/fake-calls"'
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-relative.toml" AGENT_GUARD_INFRA_FAILURE_MODE=open)
  expect 'the infrastructure policy, not a finding, decides that call: open passes it with the reason' \
    '[ "$r" = 0 ] && grep -Fq "relative [extend] path" "$CASE/e.err"'
  run claude output-clean AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-relative.toml"
  expect 'tool output that could not be scanned for that reason is not passed on as it is, and the hook says why' \
    'grep -Fq "relative [extend] path" "$CASE/h.err" && ! same_as "$CASE/stand-in-claude-output-clean"'
  # exec masks what it could not scan; the caller sees only the mask, so exec
  # says why too.
  (cd "$EDGE" && env AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-relative.toml" "$GUARD" exec -- echo harmless text \
    >"$CASE/x.out" 2>"$CASE/x.err")
  expect 'exec output that could not be scanned for that reason is masked, and exec says why' \
    '[ -s "$CASE/x.out" ] && ! grep -Fq "harmless text" "$CASE/x.out" && grep -Fq "relative [extend] path" "$CASE/x.err"'
  (cd "$EDGE" && env AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-absolute.toml" "$GUARD" exec -- echo harmless text \
    >"$CASE/x.out" 2>"$CASE/x.err")
  expect 'exec with a config that extends an absolute path prints its output and no such line' \
    'grep -Fxq "harmless text" "$CASE/x.out" && ! grep -Fq "[extend]" "$CASE/x.err"'
  expect 'a config that extends an absolute path scans hook input as before' \
    '[ "$(edge "ls -la src" AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-absolute.toml") $(edge "echo $pat" AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-absolute.toml")" = "0 2" ]'
  # A version manager's shim that takes its version from the project
  # directory finds none in the private one: the scan fails, and the message
  # names the setting that fixes it.
  : >"$EDGE/.tool-versions"
  SHIM_TARGET=$AGENT_GUARD_GITLEAKS_BIN
  export SHIM_TARGET
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks")
  expect 'a gitleaks shim that takes its version from the project directory fails the scan of hook input, and the hook names AGENT_GUARD_GITLEAKS_BIN' \
    '[ "$r" = 2 ] && grep -Fq "shim: no version is set here" "$CASE/e.err" && grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  # Some shims fail with 1, which is also how gitleaks reports a finding: the
  # call stays refused whatever the infrastructure policy, and the message
  # still names the setting.
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_FAIL=1)
  expect 'a shim that fails with the status of a finding is refused too, and the hook names AGENT_GUARD_GITLEAKS_BIN' \
    '[ "$r" = 2 ] && grep -Fq "shim: no version is set here" "$CASE/e.err" && grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_FAIL=1 AGENT_GUARD_INFRA_FAILURE_MODE=open)
  expect 'that status is never read as a scan that could not run: an open infrastructure policy does not pass the call' \
    '[ "$r" = 2 ] && grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  expect 'a shim that finds its version scans hook input as the executable does' \
    '[ "$(edge "ls -la src" AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_GLOBAL=1)" = 0 ]'
  r=$(edge "echo $pat" AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_GLOBAL=1)
  expect 'a finding through such a shim comes without that line' \
    '[ "$r" = 2 ] && grep -Fq "secret-like value detected" "$CASE/e.err" && ! grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  r=$(edge "echo $pat" AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_GLOBAL=1 SHIM_QUIET=1)
  expect 'a finding reported with no output, as the official gitleaks reports one, comes without that line' \
    '[ "$r" = 2 ] && grep -Fq "secret-like value detected" "$CASE/e.err" && ! grep -Fq "Finding:" "$CASE/e.err" \
       && ! grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  r=$(edge "echo $pat")
  expect 'a finding of the executable itself comes without that line' \
    '[ "$r" = 2 ] && ! grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  rm -f "$EDGE/.tool-versions"
  # The config check runs where the scan's input is the standard input; it
  # must leave that input to the scanner, whatever the config is named.
  cp "$C/plain.toml" "$EDGE/rules=1.toml"
  expect 'checking a config named like an awk assignment does not take the text from the scan' \
    '[ "$(edge "echo $pat" AGENT_GUARD_GITLEAKS_CONFIG=rules=1.toml AGENT_GUARD_SCAN_CACHE=off) $(edge "ls -la src" AGENT_GUARD_GITLEAKS_CONFIG=rules=1.toml AGENT_GUARD_SCAN_CACHE=off)" = "2 0" ]'
  unset AGENT_GUARD_GITLEAKS_BIN FAKE_GITLEAKS_STDIN_IGNORE
elif [ "${CI:-}" = true ] && [ "$(uname -s)" = Linux ]; then
  bad 'a C compiler is required for the stand-in ignore-file checks on Linux CI'
else
  printf '# no C compiler; skipped the stand-in ignore-file checks\n'
fi

# --- the official gitleaks -------------------------------------------------------
if [ -n "$REAL" ]; then
  cp "$REAL" "$CASE/bin/gitleaks"
  GL="$CASE/bin/gitleaks"
  PATH="$CASE/bin:$ORIGINAL_PATH"
  export PATH
  # A synthetic value in the shape of a GitHub token, assembled at run time so
  # no literal sits in the repository.
  fill() { printf '%s' "$2" | awk -v n="$1" '{ s = ""; while (length(s) < n) s = s $0; print substr(s, 1, n) }'; }
  pat="gh""p_$(fill 36 a1B2c3D4e5F6g7H8i9J0)"

  # gitleaks 8.30 names a finding <file>:<rule>:<line>, and a stdin finding
  # has no file: ":<rule>:<line>". Nothing of the value is in it, so an entry
  # can be written without knowing the value. Pinned here, from a real scan of
  # the text a hook scans, so the entries below are the ones such a scan is
  # matched against.
  printf 'echo %s\n' "$pat" >"$CASE/probe"
  (cd "$CASE/none" && "$GL" stdin --no-banner --log-level error --config "$CFG" \
    --report-format json --report-path "$CASE/probe.json" <"$CASE/probe" >/dev/null 2>&1)
  fingerprints=$(jq -r '.[].Fingerprint' "$CASE/probe.json" 2>/dev/null | sort)
  rules=$(jq -r '.[].RuleID' "$CASE/probe.json" 2>/dev/null | sort -u)
  expect 'gitleaks names a stdin finding :<rule>:<line>, with no file and no value' \
    '[ -n "$fingerprints" ] && ! printf "%s\n" "$fingerprints" | grep -Evq "^:[a-z0-9-]+:1$" \
       && printf "%s\n" "$fingerprints" | grep -Fxq ":github-pat:1" \
       && [ "$(jq -r "[.[] | select(.File != \"\" or .Commit != \"\")] | length" "$CASE/probe.json")" = 0 ]'
  # Every rule that matched, on each of the first lines of a scanned text.
  stdin_entries() {
    for rule in $rules; do
      n=1
      while [ "$n" -le 40 ]; do
        printf ':%s:%s\n' "$rule" "$n"
        n=$((n + 1))
      done
    done
  }
  SCAN_FLAGS="--redact --no-banner --no-color --log-level error --exit-code 1"
  mkdir "$CASE/direct"
  stdin_entries >"$CASE/direct/$IGNORE"
  (cd "$CASE/direct" && "$GL" stdin $SCAN_FLAGS --config "$CFG" <"$CASE/probe" >/dev/null 2>&1); silenced=$?
  (cd "$CASE/none" && "$GL" stdin $SCAN_FLAGS --config "$CFG" <"$CASE/probe" >/dev/null 2>&1); found=$?
  (cd "$CASE/direct" && "$GL" stdin $SCAN_FLAGS --config "$CFG" --gitleaks-ignore-path "$CASE/none" <"$CASE/probe" >/dev/null 2>&1); flagged=$?
  expect 'control: those entries silence gitleaks stdin run beside them, and only there' \
    '[ "$silenced" = 0 ] && [ "$found" = 1 ]'
  expect 'gitleaks stdin reads the ignore file of its directory whatever --gitleaks-ignore-path names' \
    '[ "$flagged" = 0 ]'
  # How deep gitleaks follows an extend path decides which files the config
  # check reads: each file of this chain has a rule of its own.
  mkdir "$CASE/depth"
  n=1
  while [ "$n" -le 4 ]; do
    {
      [ "$n" -ge 4 ] || printf '[extend]\npath = "%s/c%s.toml"\n' "$CASE/depth" "$((n + 1))"
      printf '[[rules]]\nid = "depth-%s"\nregex = %s\n' "$n" "'''file${n}word[a-z]{6}'''"
    } >"$CASE/depth/c$n.toml"
    n=$((n + 1))
  done
  printf 'file1wordabcdef file2wordabcdef file3wordabcdef file4wordabcdef\n' >"$CASE/depth/in"
  (cd "$CASE/none" && "$GL" stdin --no-banner --log-level error --config "$CASE/depth/c1.toml" \
    --report-format json --report-path "$CASE/depth/out.json" <"$CASE/depth/in" >/dev/null 2>&1)
  expect 'gitleaks reads a config and two files deep of what it extends, no further' \
    '[ "$(jq -r ".[].RuleID" "$CASE/depth/out.json" 2>/dev/null | sort | tr "\n" " ")" = "depth-1 depth-2 depth-3 " ]'

  # A recording stand-in for the scan client: it notes whether an ignore file
  # sits in the directory it was started in (where the real client hands the
  # scan to the real gitleaks, which applies it), then scans as the real
  # client does on a fallback.
  cat >"$CASE/lib/agent-guard-scan" <<'EOF'
#!/bin/sh
if [ -e .gitleaksignore ] || [ -L .gitleaksignore ]; then
  echo beside-ignore
else
  echo private
fi >>"$AG_SCOPE_CALLS"
gitleaks=$2
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$gitleaks" "$@"
EOF
  chmod +x "$CASE/lib/agent-guard-scan"
  CLIENT="$CASE/lib/agent-guard-scan"
  CALLS="$CASE/calls"
  export AG_SCOPE_CALLS="$CALLS"

  entries=$(stdin_entries)
  with_client=1
  work_repo "$CASE/official"
  hook_plain official
  printf '%s\n' "$entries" >"$WORK/$IGNORE"
  git -C "$WORK" add "$IGNORE" && git -C "$WORK" commit -q -m ignore
  (cd "$WORK" && "$GL" stdin $SCAN_FLAGS --config "$CFG" <"$CASE/probe" >/dev/null 2>&1)
  expect 'control: the ignore file in the working repository silences gitleaks stdin run there' '[ "$?" = 0 ]'
  hook_beside official client

  # The scan cache stays on beside an ignore file, and a remembered clean
  # verdict never stands in for a value: the same sequence in a directory
  # without one leaves as many entries.
  cache_entries() { ls "$STATE/gitleaks-clean" 2>/dev/null | grep -Ec '^[0-9a-f]{64}$' || :; }
  cached_run() { # $1 directory, $2 command -> the hook status
    (cd "$1" && jq -nc --arg c "$2" --arg d "$1" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d,session_id:"ignore-scope"}' \
      | AGENT_GUARD_HOOK_HOST=claude "$GUARD" hook-pre-tool >/dev/null 2>&1)
    echo $?
  }
  rm -rf "$STATE"
  seq_plain="$(cached_run "$CASE/plain" 'ls -la src') $(cached_run "$CASE/plain" 'ls -la src') $(cache_entries)"
  rm -rf "$STATE"
  seq_ignore="$(cached_run "$WORK" 'ls -la src') $(cached_run "$WORK" 'ls -la src') $(cache_entries)"
  expect "a clean command is remembered beside an ignore file as elsewhere ($seq_plain)" \
    '[ "$seq_ignore" = "$seq_plain" ] && [ "${seq_plain%% *}" = 0 ]'
  before=$(cache_entries)
  seq_value="$(cached_run "$WORK" "echo $pat") $(cached_run "$WORK" "echo $pat") $(cached_run "$WORK" "ls -la src; echo $pat")"
  expect 'with the scan cache warm a command with the value is refused each time, and none is remembered' \
    '[ "$seq_value" = "2 2 2" ] && [ "$(cache_entries)" = "$before" ]'

  repository_scans official

  # scan-path, as the GitHub Action runs it: gitleaks dir names a finding
  # <path as given>/<file>:<rule>:<line>.
  mkdir -p "$CASE/path/src"
  printf 'note %s\n' "$pat" >"$CASE/path/src/app.conf"
  (cd "$CASE/path" && "$GL" dir . --no-banner --log-level error --config "$CFG" \
    --report-format json --report-path "$CASE/dir.json" >/dev/null 2>&1)
  entries=$(jq -r '.[].Fingerprint' "$CASE/dir.json" 2>/dev/null | sort)
  expect 'gitleaks names a directory finding <file>:<rule>:<line>' \
    '[ -n "$entries" ] && ! printf "%s\n" "$entries" | grep -Evq "^src/app[.]conf:[a-z0-9-]+:1$"'
  keeps 'scan-path' "$CASE/path" scan-path -- .
  expect 'the GitHub Action scans with scan-path' \
    'grep -Fq "bin/agent-guard\" scan-path -- \$AGENT_GUARD_PATHS" "$ROOT/action.yml"'
  # A lockfile is skipped by the directory scan and scanned again through
  # gitleaks stdin, without its checksum fields.
  mkdir "$CASE/lock"
  printf '{\n  "name": "fixture",\n  "note": "%s"\n}\n' "$pat" >"$CASE/lock/package-lock.json"
  entries=$(stdin_entries)
  keeps 'scan-path (the lockfile pass)' "$CASE/lock" scan-path -- .

  # What else a scan started from another directory must still find.
  expect 'a relative TMPDIR still scans hook input: a clean command passes and the value is refused' \
    '[ "$(edge "ls -la src" TMPDIR=tmp) $(edge "echo $pat" TMPDIR=tmp)" = "0 2" ]'
  expect 'a relative AGENT_GUARD_GITLEAKS_CONFIG still resolves from the hook directory' \
    '[ "$(edge "ls -la src" AGENT_GUARD_GITLEAKS_CONFIG=custom.toml) $(edge "echo $pat" AGENT_GUARD_GITLEAKS_CONFIG=custom.toml)" = "0 2" ]'
  expect 'official: a config that extends an absolute path scans hook input as before' \
    '[ "$(edge "ls -la src" AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-absolute.toml") $(edge "echo $pat" AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-absolute.toml")" = "0 2" ]'
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_CONFIG="$EDGE/extend-relative.toml")
  expect 'official: a config that extends a relative path is a scan that did not run, not a finding' \
    '[ "$r" = 2 ] && grep -Fq "relative [extend] path" "$CASE/e.err" && ! grep -Fq "secret-like value detected" "$CASE/e.err"'
  # The official gitleaks reports a finding with status 1 and no output; a
  # shim's own failure with that status has output.
  r=$(edge "echo $pat" AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_TARGET="$GL" SHIM_GLOBAL=1)
  expect 'official: a finding through a shim that finds its version comes without the line about a shim' \
    '[ "$r" = 2 ] && grep -Fq "secret-like value detected" "$CASE/e.err" && ! grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  : >"$EDGE/.tool-versions"
  r=$(edge 'ls -la src' AGENT_GUARD_GITLEAKS_BIN="$CASE/shim/gitleaks" SHIM_TARGET="$GL" SHIM_FAIL=1)
  expect 'official: a shim that fails with status 1 where no version is set is refused, and the hook names AGENT_GUARD_GITLEAKS_BIN' \
    '[ "$r" = 2 ] && grep -Fq "shim: no version is set here" "$CASE/e.err" && grep -Fq "AGENT_GUARD_GITLEAKS_BIN" "$CASE/e.err"'
  rm -f "$EDGE/.tool-versions"
  PATH=$ORIGINAL_PATH
  export PATH
else
  printf '# no official gitleaks; skipped the fingerprint checks\n'
fi

# --- doctor ---------------------------------------------------------------------
: >"$CASE/dirs/listed/$IGNORE"
(cd "$CASE/dirs/listed" && "$GUARD" doctor >"$CASE/doctor.out" 2>&1)
(cd "$CASE/plain" && "$GUARD" doctor >"$CASE/doctor-plain.out" 2>&1)
expect 'doctor says an ignore file here applies to repository scans only' \
  'grep -Fq ".gitleaksignore" "$CASE/doctor.out" && grep -Fq "repository scans only" "$CASE/doctor.out"'
expect 'doctor says nothing about an ignore file where there is none' \
  '[ -s "$CASE/doctor-plain.out" ] && ! grep -Fq ".gitleaksignore" "$CASE/doctor-plain.out"'

printf '\npassed: %s\nfailed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

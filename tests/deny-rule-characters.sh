#!/bin/sh
# In a deny-read rule, a "?" and a bracket expression stand for one whole
# character of a name, whichever shell runs the CLI and whatever the locale
# is. Every row runs under dash, bash and bash started as sh, each with
# LC_ALL=C, a UTF-8 locale and no locale variable at all. A row a rule must
# block is followed by one the same rule must leave alone. Every name is
# synthetic and no file content is read.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD=${AGENT_GUARD_TEST_BINARY:-$ROOT/plugins/agent-guard/bin/agent-guard}
SOURCE=${AGENT_GUARD_UNIT_SOURCE:-$GUARD}
FUNCTIONS='text_is_printable_ascii deny_match_counts_characters deny_rules_by_character
  deny_wildcard_rules_match candidate_matches_deny deny_entry_chars deny_entry_next_char
  deny_entry_char_is_alnum bash_shell_expanded_match_is_pinned'

ok() { printf 'ok - %s\n' "$*"; }
bad() { printf 'not ok - %s\n' "$*"; : >"$CASE/failed"; }

# --- Function rows, in the shell and locale this file was started with -------
if [ "${1-}" = --unit ]; then
  CASE=$2 label=$3
  for function in $FUNCTIONS; do
    . "$CASE/fn/$function.sh"
  done
  DENY_READ_PATHS=$CASE/unit-rules DENY_READ_PATHS_CUSTOM=1

  # expectation|rule|name. m: the rule matches the name; n: it does not. A
  # backslash and three digits stand for one byte that is not UTF-8 text.
  while IFS='|' read -r expected rule raw; do
    case "$expected" in ''|\#*) continue ;; esac
    name=$(printf "$raw")
    printf '%s\n' "$rule" >"$DENY_READ_PATHS"
    case "$expected:$(deny_rules_by_character path "$name" 2>/dev/null)" in
      m:match|n:clear) ok "$label: $rule $expected $raw" ;;
      *) bad "$label: $rule $expected $raw" ;;
    esac
  done <<'ROWS'
# "?" is one character of two, three or four bytes
m|notes-?.txt|notes-é.txt
m|notes-?.txt|notes-한.txt
m|notes-?.txt|notes-😀.txt
n|notes-?.txt|notes-éé.txt
n|notes-?.txt|notes-한글.txt
n|notes-?.txt|notes-😀😀.txt
m|notes-??.txt|notes-é한.txt
n|notes-??.txt|notes-é.txt
m|notes-?.txt|notes-a.txt
n|notes-?.txt|notes-ab.txt
# a range and a set
m|memo-[가-힣].md|memo-한.md
n|memo-[가-힣].md|memo-あ.md
n|memo-[가-힣].md|memo-x.md
m|memo-[à-ÿ].md|memo-é.md
n|memo-[à-ÿ].md|memo-한.md
m|memo-[a-f].md|dir-한/memo-c.md
n|memo-[a-f].md|dir-한/memo-g.md
m|key-[é한😀].seal|key-😀.seal
n|key-[é한😀].seal|key-힣.seal
# a negated bracket expression
m|log-[!a-z].txt|log-é.txt
m|log-[!a-z].txt|log-😀.txt
n|log-[!a-z].txt|log-b.txt
m|log-[^가-힣].txt|log-é.txt
n|log-[!가-힣].txt|log-한.txt
# a class: exact for ASCII, and always a match for any other character
m|rep-[[:digit:]].txt|dir-한/rep-7.txt
n|rep-[[:digit:]].txt|dir-한/rep-x.txt
m|rep-[[:alpha:]].txt|rep-한.txt
m|rep-[![:alpha:]].txt|rep-한.txt
m|rep-[[=a=]].txt|rep-한.txt
# an equivalence class is whatever the locale says: every character matches
m|rep-[[=a=]].txt|rep-A.txt
m|rep-[![=a=]].txt|rep-a.txt
# also where one ends a range, and a class there
m|rep-[a-[=c=]].txt|rep-z.txt
m|rep-[a-[:digit:]].txt|rep-z.txt
n|rep-[a-[.c.]].txt|rep-z.txt
# a class that only bash has, and a name no shell has: every character matches
m|rep-[[:ascii:]].txt|rep-a.txt
n|rep-[![:ascii:]].txt|rep-a.txt
m|rep-[[:word:]].txt|rep-_.txt
m|rep-[[:nosuch:]].txt|rep-a.txt
m|rep-[![:nosuch:]].txt|rep-a.txt
# a collating symbol is the character it names
m|rep-[[.a.]].txt|dir-한/rep-a.txt
n|rep-[[.a.]].txt|rep-한.txt
# one with a name stands for a character only the shell knows: every
# character matches
m|rep-[[.hyphen.]].txt|rep--.txt
m|rep-[[.hyphen.]].txt|rep-a.txt
m|rep-[a-[.hyphen.]].txt|rep-한.txt
# "*" beside them
m|*-?.md|한글-가.md
n|*-?.md|한글-가나.md
# a protected directory above the name, and a rule matched below a slash
m|memo-?|top/memo-한/inner/file.txt
m|memo-?|/abs/dir/memo-한
n|memo-?|/abs/dir/memo-한글
# bytes that are not UTF-8: each one, or a run of them, or every byte of
# the name counts as a character
m|notes-?.txt|notes-\351.txt
m|notes-?.txt|notes-\343\201.txt
m|notes-?.txt|notes-\377\376.txt
m|notes-??.txt|notes-\377\376.txt
m|notes-???.txt|notes-é\377.txt
n|notes-?.txt|notes-\351x.txt
m|log-[!a-z].txt|log-\351.txt
m|memo-[가-힣].md|memo-\355\225.md
n|key-[ab].seal|key-\351.seal
# a backslash quotes the next character, and one at the end matches nothing
m|memo-\??.md|memo-?한.md
n|memo-\??.md|memo-가한.md
n|memo-?\|memo-한\\
# a bracket that is never closed is a literal
m|a[b|dir-한/a[b
n|a[b|dir-한/ab
ROWS

  # A rule holding a slash, against the resolved path and the path as written.
  while IFS='|' read -r expected rule real written; do
    printf '%s\n' "$rule" >"$DENY_READ_PATHS"
    case "$expected:$(deny_rules_by_character tree "$real" "$written" 2>/dev/null)" in
      m:match|n:clear) ok "$label: tree $rule $expected $real $written" ;;
      *) bad "$label: tree $rule $expected $real $written" ;;
    esac
  done <<'ROWS'
m|box-?/list.txt|/r/box-é/list.txt|/list.txt
n|box-?/list.txt|/r/box-éé/list.txt|/list.txt
m|box-?/list.txt|/r/other/list.txt|/box-한/list.txt
n|box-?|/r/box-é/list.txt|/r/list.txt
n|box-?.txt|/r/box-é.txt|/box-é.txt
n|notes/?.txt|/r/notes-é.txt|/notes-é.txt
ROWS

  # The same verdict as the shell's own matching for these ASCII names. No
  # row sets a letter range against a letter of the other case, which bash
  # 3.2 decides by the collation of the locale.
  parity=0
  for rule in 'a?c' 'a[bc]d' 'a[!bc]d' 'a[b-d]e' 'a[]b]c' 'a[!]b]c' 'a\*[b]' '[a-]x' \
    '*[.]t?t' 'a[[:digit:]]b' 'a[[:upper:][:digit:]]' '?' '*?' 'a**[b]' 'a\?c' '[!a]*'; do
    printf '%s\n' "$rule" >"$DENY_READ_PATHS"
    for name in abc ac abbc abd aed 'a]c' 'a*b' axb 'a[b' -x ax n.txt n.tat a5b aQ a 'a?c' b; do
      want=clear
      case "$name" in
        $rule) want=match ;;
      esac
      [ "$(deny_rules_by_character path "$name" 2>/dev/null)" = "$want" ] \
        || { parity=1; bad "$label: $rule on $name differs from the shell"; }
    done
  done
  [ "$parity" -eq 1 ] || ok "$label: ASCII names get the shell's own verdict"

  # Printable ASCII is the only text the shell matches the same way everywhere.
  IFS= read -r printable <<'ROWS'
 !"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~
ROWS
  plain=0
  text_is_printable_ascii "$printable" && text_is_printable_ascii '' || plain=1
  for name in 'é' 'a한' "$(printf 'a\tb')" "$(printf 'a\351')"; do
    ! text_is_printable_ascii "$name" || plain=1
  done
  [ "$plain" -eq 0 ] && ok "$label: only printable ASCII is plain" || bad "$label: only printable ASCII is plain"

  # The character match is taken under a rule with "[", and under one with
  # "?" when the name is not plain ASCII.
  gate=0
  printf '%s\n' '# a comment with [ and ?' '*.md' '메모-*' >"$DENY_READ_PATHS"
  ! deny_match_counts_characters 'memo-한.md' || gate=1
  printf '%s\n' '*.md' 'notes-?.txt' >"$DENY_READ_PATHS"
  deny_match_counts_characters 'memo-한.md' || gate=1
  ! deny_match_counts_characters 'memo-x.md' || gate=1
  printf '%s\n' '*.md' 'memo-[a-f].md' >"$DENY_READ_PATHS"
  deny_match_counts_characters 'memo-x.md' || gate=1
  # The bundled list is read only for a name that is not plain ASCII.
  DENY_READ_PATHS_CUSTOM=0
  ! deny_match_counts_characters 'memo-x.md' || gate=1
  deny_match_counts_characters 'memo-한.md' || gate=1
  DENY_READ_PATHS_CUSTOM=1
  [ "$gate" -eq 0 ] && ok "$label: the character match is taken only when it can matter" \
    || bad "$label: the character match is taken only when it can matter"

  # An entry is read one whole character at a time, and any non-ASCII
  # character counts as a letter.
  joined=
  deny_entry_chars 'a한😀é*'
  while deny_entry_next_char; do joined="$joined<$dec_char:$dec_bytes>"; done
  [ "$joined" = '<a:1><한:3><😀:4><é:2><*:1>' ] && ok "$label: an entry is read character by character" \
    || bad "$label: an entry is read character by character ($joined)"
  # A long entry is taken apart in pieces, and no character is cut in two.
  many=$(LC_ALL=C awk 'BEGIN { while (i++ < 400) printf "한" }')
  pieces=0
  for pad in '' a aa aaa; do
    count=0
    deny_entry_chars "$pad$many"
    while deny_entry_next_char; do count=$((count + 1)); done
    [ "$count" -eq $((${#pad} + 400)) ] || pieces=1
  done
  [ "$pieces" -eq 0 ] && ok "$label: a long entry keeps its characters whole" \
    || bad "$label: a long entry keeps its characters whole"
  alnum=0
  for ch in a Z 5 한 é 😀; do deny_entry_char_is_alnum "$ch" || alnum=1; done
  for ch in - . '*' /; do ! deny_entry_char_is_alnum "$ch" || alnum=1; done
  [ "$alnum" -eq 0 ] && ok "$label: letters and digits of an entry" || bad "$label: letters and digits of an entry"

  # Only a rule with "?" or "[" is matched by character; the shell's own
  # matching keeps every other rule.
  printf '%s\n' '*.md' 'dir-한' >"$DENY_READ_PATHS"
  ! deny_wildcard_rules_match 'dir-한/memo.md' \
    && ok "$label: the other rules stay with the shell" || bad "$label: the other rules stay with the shell"

  # A rule that is not UTF-8 text does not change how the other rules read a
  # name that is.
  printf 'pair-?\351.txt\npair-??.txt\n' >"$DENY_READ_PATHS"
  ! deny_wildcard_rules_match 'pair-é.txt' && deny_wildcard_rules_match 'pair-é한.txt' \
    && ok "$label: one odd rule leaves the others alone" || bad "$label: one odd rule leaves the others alone"

  # A text far longer than a path is matched like a short one.
  printf '%s\n' 'notes-?.txt' >"$DENY_READ_PATHS"
  long=$(LC_ALL=C awk 'BEGIN { while (i++ < 20000) printf "0123456789" }')
  ! deny_wildcard_rules_match "$long-한" && deny_wildcard_rules_match "${long%${long#????????????????????}}/notes-한.txt" \
    && ok "$label: a long text is matched" || bad "$label: a long text is matched"

  # The list is read whatever its file is called.
  DENY_READ_PATHS=$CASE/unit=rules
  printf '%s\n' 'notes-?.txt' >"$DENY_READ_PATHS"
  deny_wildcard_rules_match 'notes-한.txt' && ! deny_wildcard_rules_match 'dir-한/readme.txt' \
    && ok "$label: a list file named with an equals sign is read" || bad "$label: a list file named with an equals sign is read"

  # A match that cannot run says so, also when awk leaves the status of a
  # clean run behind.
  failed=0
  not_run() { deny_wildcard_rules_match "$1" 2>/dev/null; [ "$?" -eq 2 ]; }
  awk() { return 1; }
  not_run 'dir-한/readme.txt' || failed=1
  awk() { cat >/dev/null; echo clear; return 3; }
  not_run 'dir-한/readme.txt' || failed=1
  awk() { cat >/dev/null; }
  not_run 'dir-한/readme.txt' || failed=1
  unset -f awk
  deny_wildcard_rules_match 'notes-한.txt' || failed=1
  # It then counts as a match, and the caller is told that it did not run.
  for status in 2 7; do
    candidate_deny_verdict() { return "$status"; }
    DENY_SCAN_FAILED=0
    candidate_matches_deny 'dir-한/readme.txt' && [ "$DENY_SCAN_FAILED" -eq 1 ] || failed=1
  done
  for status in 0 1; do
    candidate_deny_verdict() { return "$status"; }
    DENY_SCAN_FAILED=0
    candidate_matches_deny 'notes-한.txt'
    [ "$?:$DENY_SCAN_FAILED" = "$status:0" ] || failed=1
  done
  # An entry that could not be split says so.
  awk() { return 3; }
  deny_entry_chars '메모'
  [ "$dec_failed" -eq 1 ] || failed=1
  unset -f awk
  deny_entry_chars '메모'
  [ "$dec_failed" -eq 0 ] || failed=1
  DENY_READ_PATHS=$CASE/no-such-list
  not_run 'dir-한/readme.txt' || failed=1
  [ "$failed" -eq 0 ] && ok "$label: a failed match protects the path" || bad "$label: a failed match protects the path"
  # Nor is a word that matched an entry called pinned by a check that could
  # not split the entry: that is a failed scan (status 2).
  failed=0
  deny_path_command_regex() { return 2; }
  bash_shell_expanded_match_is_pinned 'cat x' '메모' 'x'
  [ "$?" -eq 2 ] || failed=1
  deny_path_command_regex() { return 1; }
  bash_shell_expanded_match_is_pinned 'cat x' '메모' 'x' || failed=1
  deny_path_command_regex() { printf 'zz'; }
  deny_path_entry_pin_regex() { dec_failed=1; }
  bash_shell_expanded_match_is_pinned 'cat x' '메모' 'x'
  [ "$?" -eq 2 ] || failed=1
  [ "$failed" -eq 0 ] && ok "$label: a pin check that cannot split the entry is a failed scan" \
    || bad "$label: a pin check that cannot split the entry is a failed scan"
  exit 0
fi

# No bundled rule holds a bracket expression: the CLI relies on that to leave
# a plain path under the bundled list to the shell's own matching.
if LC_ALL=C grep -v '^#' "$ROOT/plugins/agent-guard/config/deny-read-paths.txt" | LC_ALL=C grep -q '\['; then
  printf 'not ok - a bundled deny-read rule holds a bracket expression\n'
  exit 1
fi
printf 'ok - no bundled deny-read rule holds a bracket expression\n'

# --- Hook rows ---------------------------------------------------------------
CASE=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-deny-characters.XXXXXX") || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
trap 'rm -rf "$CASE"' 0 HUP INT TERM
REPO=$CASE/repo BOX=$CASE/box-é
mkdir -p "$CASE/home" "$CASE/fn" "$REPO" "$BOX"
export HOME="$CASE/home" XDG_STATE_HOME="$CASE/state" AGENT_GUARD_WARNING_DIR="$CASE/warnings"
export AGENT_GUARD_LOG_MODE=off AGENT_GUARD_RELEASE_CHECK=off AGENT_GUARD_PII_HOOK_MODE=off
export AGENT_GUARD_GITLEAKS_BIN="$ROOT/tests/fixtures/mock-gitleaks" AGENT_GUARD_HOOK_HOST=claude
unset AI_AGENT AGENT_GUARD_DENY_READ_MODE AGENT_GUARD_TRACKED_FILE_EXCEPTION

# The shells: each directory holds an sh for the CLI's "#!/usr/bin/env sh".
shells=
for shell in dash bash; do
  shell_bin=$(command -v "$shell" 2>/dev/null) || continue
  mkdir -p "$CASE/sh-$shell"
  case "$shell" in
    dash) ln -s "$shell_bin" "$CASE/sh-dash/sh" ;;
    bash)
      printf '#!%s\nexec %s "$@"\n' "$shell_bin" "$shell_bin" >"$CASE/sh-bash/sh"
      chmod +x "$CASE/sh-bash/sh"
      mkdir -p "$CASE/sh-bash-as-sh"
      ln -s "$shell_bin" "$CASE/sh-bash-as-sh/sh"
      shells="$shells bash-as-sh"
      ;;
  esac
  shells="$shells $shell"
done
[ -n "$shells" ] || { printf 'not ok - neither dash nor bash is installed\n'; exit 1; }
# Every UTF-8 locale of these two that is installed: bash reads a bracket
# expression by the collation of the locale, and the two differ.
utf8=
for locale in C.UTF-8 en_US.UTF-8; do
  [ "$(LC_ALL=$locale locale charmap 2>/dev/null)" != UTF-8 ] || utf8="$utf8 $locale"
done
# Failing those two, any UTF-8 locale that is installed.
if [ -z "$utf8" ]; then
  for locale in $(locale -a 2>/dev/null | grep -i 'utf-*8$'); do
    [ "$(LC_ALL=$locale locale charmap 2>/dev/null)" != UTF-8 ] || { utf8=" $locale"; break; }
  done
fi
[ -n "$utf8" ] || printf '# no UTF-8 locale is installed: only the C and no-locale rows run\n'

cat >"$CASE/deny" <<'RULES'
notes-?.txt
pair-??.txt
memo-[가-힣].md
log-[!a-z].txt
메모-*.md
ledger-한.md
vault-한
seal-[한].txt
span-[é-힣].txt
kind-[a-z].txt
tag-[a-é].txt
box-?/list.txt
초안draft.log
trio-éé.txt
.page.한x
q한.cfg
mén.rc
crate.json
*.seal
RULES
export AGENT_GUARD_DENY_READ_PATHS="$CASE/deny"
# A repository whose own directory has a two-byte character in its name,
# with two committed files.
printf 'placeholder\n' >"$BOX/list.txt"
printf 'placeholder\n' >"$BOX/stamp.seal"
(
  cd "$BOX" && git init -q . >/dev/null 2>&1 && git add . >/dev/null 2>&1 \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
      -c core.hooksPath=/dev/null commit -q -m fixture >/dev/null 2>&1
) || { printf 'not ok - could not build the fixture repository\n'; exit 1; }
# A name with a byte that is not UTF-8, behind plain links, where the
# filesystem takes one.
raw_names=0
mkdir "$REPO/raw"
if (cd "$REPO/raw" && : >"$(printf 'notes-\351.txt')" && : >"$(printf 'notes-\351x.txt')") 2>/dev/null; then
  ln -s "$(printf 'raw/notes-\351.txt')" "$REPO/first-link"
  ln -s "$(printf 'raw/notes-\351x.txt')" "$REPO/second-link"
  raw_names=1
fi

# $1 shell, $2 locale (none: no locale variable), $3 expected status,
# $4 tool, $5 path or command, $6 working directory.
row() {
  case "$4" in
    Bash) jq -nc --arg v "$5" --arg d "$6" \
      '{hook_event_name:"PreToolUse",session_id:"rows",cwd:$d,tool_name:"Bash",tool_input:{command:$v}}' ;;
    *) jq -nc --arg t "$4" --arg v "$5" --arg d "$6" \
      '{hook_event_name:"PreToolUse",session_id:"rows",cwd:$d,tool_name:$t,tool_input:{file_path:$v}}' ;;
  esac >"$CASE/input"
  (
    unset LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LANG LANGUAGE
    [ "$2" = none ] || { LC_ALL=$2; export LC_ALL; }
    cd "$6" && PATH="$CASE/sh-$1:$PATH" "$GUARD" hook-pre-tool <"$CASE/input" >/dev/null 2>"$CASE/err"
  )
  got=$?
  if [ "$got" -eq "$3" ]; then
    ok "$1 $2: $4 $5 exits $3"
  else
    bad "$1 $2: $4 $5 exits $got, expected $3"
  fi
}

for shell in $shells; do
  for locale in C $utf8 none; do
    while IFS='|' read -r expected tool value dir; do
      case "$expected" in ''|\#*) continue ;; esac
      case "$dir" in
        box) dir=$BOX ;;
        *) dir=$REPO; [ "$tool" = Bash ] || value=$REPO/$value ;;
      esac
      row "$shell" "$locale" "$expected" "$tool" "$value" "$dir"
    done <<'ROWS'
# a file tool: "?", a range and a negated bracket expression
2|Read|notes-é.txt
0|Read|notes-éé.txt
2|Read|memo-한.md
0|Read|memo-x.md
2|Read|log-😀.txt
0|Read|log-b.txt
2|Read|notes-a.txt
0|Read|notes-ab.txt
# two characters are two of them, not the bytes of one
2|Read|pair-é한.txt
0|Read|pair-é.txt
# a set and a range go by code point in every locale
2|Read|seal-한.txt
0|Read|seal-힣.txt
2|Read|span-한.txt
0|Read|span-a.txt
2|Read|kind-q.txt
0|Read|kind-é.txt
# also between ASCII letters of the two cases
0|Read|kind-Q.txt
2|Read|log-Q.txt
# and so does a plain name under a rule that has such a character
2|Read|tag-z.txt
0|Read|tag-B.txt
# a protected directory above the name
2|Read|memo-한.md/inner.txt
0|Read|memo-한글.md/inner.txt
# the rules without "?" or "[" decide as before
2|Read|인증-한.seal
2|Read|vault-한/list.txt
0|Read|인증-한.txt
# a shell command: a "?" in a word, where an entry has a three-byte character
2|Bash|cat 메?-1.md
2|Bash|cat 메모-1.md
0|Bash|cat 가나-1.md
# and as many "?" as that character has bytes, for a shell that expands a
# glob byte by byte
2|Bash|cat ledger-?.md
2|Bash|cat ledger-???.md
2|Bash|cat ledger-??*.md
2|Bash|cat m*?n.rc
0|Bash|cat ledger-??.md
# a character that is not ASCII before the first ASCII letter of an entry:
# that letter still holds a word to the entry
2|Bash|cat ??????d*.log
2|Bash|cat ??d*.log
2|Bash|cat 초안*.log
0|Bash|cat ??????x*.log
# a word is read one way throughout: as many "?" as the entry has
# characters, or as it has bytes, and no count between the two
2|Bash|cat trio-??.txt
2|Bash|cat trio-????.txt
0|Bash|cat trio-???.txt
# where the shell expands byte by byte a star may take over in the middle of
# a character: the bytes before it, or after it, are one-byte wildcards
2|Bash|cat ledger-??*d
2|Bash|cat .*??x
2|Bash|cat q??*
0|Bash|cat ledger-??.m*
# a committed file, by a relative path: a rule that holds a slash still
# decides, and a rule that is only a name does not
2|Read|list.txt|box
0|Read|stamp.seal|box
ROWS
    if [ "$raw_names" -eq 1 ]; then
      row "$shell" "$locale" 2 Read "$REPO/first-link" "$REPO"
      row "$shell" "$locale" 0 Read "$REPO/second-link" "$REPO"
    fi
  done
done

# While an entry cannot be split into characters the command is refused, and
# no regex built in that state is stored: the next command is read afresh.
mkdir "$CASE/awk-shim"
real_awk=$(command -v awk)
cat >"$CASE/awk-shim/awk" <<SHIM
#!/bin/sh
case " \$* " in
  *" mode=chars "*) [ ! -e "$CASE/no-split" ] || exit 3 ;;
  *" mode=path "*) [ ! -e "$CASE/no-match" ] || exit 3 ;;
esac
exec "$real_awk" "\$@"
SHIM
chmod +x "$CASE/awk-shim/awk"
set -- $shells
for split in no-split split; do
  [ "$split" = split ] || : >"$CASE/no-split"
  (
    PATH="$CASE/awk-shim:$PATH" AGENT_GUARD_LOG_MODE=on
    export PATH AGENT_GUARD_LOG_MODE
    row "$1" C 2 Bash 'cat 메?-1.md' "$REPO"
  )
  rm -f "$CASE/no-split"
done
# With the regex file stored, an operand put together from a variable is
# read afresh, also inside a command substitution, and a split that fails
# there refuses the command as well.
for split in split no-split; do
  [ "$split" = split ] || : >"$CASE/no-split"
  (
    PATH="$CASE/awk-shim:$PATH" AGENT_GUARD_LOG_MODE=on
    export PATH AGENT_GUARD_LOG_MODE
    row "$1" C 2 Bash 'd=메; cat "$d"?-1.md' "$REPO"
    row "$1" C 2 Bash 'echo "$(d=메; cat "$d"?-1.md)"' "$REPO"
  )
  rm -f "$CASE/no-split"
done
# A match that cannot run refuses the read as a failed scan, not as a
# protected file.
: >"$CASE/no-match"
(
  PATH="$CASE/awk-shim:$PATH"
  export PATH
  row "$1" C 2 Read "$REPO/인증-한.txt" "$REPO"
)
if grep -q 'deny-read-paths scan failed' "$CASE/err" && ! grep -q 'blocked sensitive file access' "$CASE/err"; then
  ok "a match that cannot run is reported as a failed scan"
else
  bad "a match that cannot run is reported as a failed scan"
fi
# Nor does a committed file pass on the strength of such a scan.
(
  PATH="$CASE/awk-shim:$PATH"
  export PATH
  row "$1" C 2 Read stamp.seal "$BOX"
)
rm -f "$CASE/no-match"
# Nor does it earn a masked view. A protected file gets one; a file no rule
# names gets none from a match that cannot run.
printf '{"label":"placeholder"}\n' >"$REPO/crate.json"
printf '{"label":"placeholder"}\n' >"$REPO/list+crate.json"
(
  AGENT_GUARD_DENY_READ_MODE=mask
  export AGENT_GUARD_DENY_READ_MODE
  row "$1" C 2 Bash 'cat crate.json' "$REPO"
)
if grep -q 'masked view follows' "$CASE/err"; then
  ok "a protected file is shown as a masked view"
else
  bad "a protected file is shown as a masked view"
fi
: >"$CASE/no-match"
(
  PATH="$CASE/awk-shim:$PATH" AGENT_GUARD_DENY_READ_MODE=mask
  export PATH AGENT_GUARD_DENY_READ_MODE
  row "$1" C 2 Bash 'cat list+crate.json' "$REPO"
)
if grep -q 'masked view follows' "$CASE/err"; then
  bad "a match that cannot run earns no masked view"
else
  ok "a match that cannot run earns no masked view"
fi
rm -f "$CASE/no-match"
# The values of a listed file are masked in output. A match that cannot run
# does not say which files are listed: no file is opened, and the whole
# output is masked. The two file names and the two values are put together
# here.
listed=$(printf '%s%s' .en v.listed) other=$(printf '%s%s' .en v.other)
first=$(printf '%s%s' first-fake -Kd52mQ) second=$(printf '%s%s' second-fake -Wp81nT)
mkdir "$CASE/values"
printf 'ONE=%s\n' "$first" >"$CASE/values/$listed"
printf 'TWO=%s\n' "$second" >"$CASE/values/$other"
{ cat "$CASE/deny"; printf '%s\n' "$listed"; } >"$CASE/deny-values"
for match in match no-match; do
  [ "$match" = match ] || : >"$CASE/no-match"
  shown=$(
    PATH="$CASE/awk-shim:$PATH" AGENT_GUARD_DENY_READ_MODE=mask AGENT_GUARD_DENY_READ_PATHS="$CASE/deny-values"
    export PATH AGENT_GUARD_DENY_READ_MODE AGENT_GUARD_DENY_READ_PATHS
    cd "$CASE/values" && printf 'plain-text %s %s\n' "$first" "$second" | "$GUARD" exec -- cat 2>/dev/null
  )
  rm -f "$CASE/no-match"
  case "$match:$shown" in
    *"$first"*|no-match:*plain-text*) verdict=bad ;;
    match:plain-text*"$second"*|no-match:*) verdict=ok ;;
    *) verdict=bad ;;
  esac
  case "$match" in
    match) "$verdict" "the values of a listed file are masked in output, and no others" ;;
    *) "$verdict" "a match that cannot run masks the whole output" ;;
  esac
done
if ls "$XDG_STATE_HOME/agent-guard" 2>/dev/null | grep -q '^deny-path-regex-'; then
  ok "the regex file of the list is stored once the entries can be split"
else
  bad "the regex file of the list is stored once the entries can be split"
fi

if sh "$ROOT/tests/helpers/extract-functions.sh" "$SOURCE" "$CASE/fn" $FUNCTIONS 2>"$CASE/err"; then
  for shell in $shells; do
    for locale in C $utf8 none; do
      (
        unset LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LANG LANGUAGE
        [ "$locale" = none ] || { LC_ALL=$locale; export LC_ALL; }
        "$CASE/sh-$shell/sh" "$0" --unit "$CASE" "$shell $locale"
      ) || bad "$shell $locale: the function rows did not finish"
    done
  done
else
  bad "the character-match functions are in the CLI"
fi

if [ -e "$CASE/failed" ]; then
  printf 'FAIL deny-rule-characters\n'
  exit 1
fi
printf 'PASS deny-rule-characters\n'

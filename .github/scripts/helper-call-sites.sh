#!/usr/bin/env sh
# How far a change reaches into the code that routes scans through the opt-in
# warm gitleaks helper (#537, #581), as a job output.
#
#   sh .github/scripts/helper-call-sites.sh BASE_REV HEAD_REV >> "$GITHUB_OUTPUT"
#
# Prints scope=full, scope=cost or scope=none for the diff of plugins/agent-guard.
# The off-state job then compares the default (helper unset) path with the base:
# helper code that adds work there must fail even though it adds the same work
# to the unusable-helper state, which a same-tree comparison cannot see.
#   full  a changed line sits outside any function or in a helper function
#         (gitleaks_helper*, gitleaks_exec), or a changed line sources a file
#         (at the start of a command: after ;, &, |, (, {, then, do or else),
#         which this check cannot read: compare exit code, output, programs
#         and forks.
#   cost  only functions that call the wrapper changed (a hunk in one, or a
#         changed line naming the helper inside one): compare programs and forks
#         only, so an intended output change there still passes.
#   none  nothing that names the helper changed: no base comparison, so a
#         hook change unrelated to the helper is free.
# The match errs toward the larger scope: a function spans from its definition
# to the next one, as in git's hunk header, so the code between two functions
# counts with the first. Anything that stops the check from running fails the
# script, so a missing answer never reads as none.
set -eu
export LC_ALL=C
from=${1:?base revision required}
to=${2:?head revision required}
names='GITLEAKS_HELPER|gitleaks_helper|gitleaks_exec'
helper_functions='^gitleaks_(helper|exec)'
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' 0
trap 'exit 1' HUP INT TERM
# Git's default hunk header takes any line that starts with a letter, so an
# `esac` or `fi` in column 0 would hide the function a hunk sits in. Name the
# function definitions instead.
printf '* diff=agfunc\n' >"$tmp/attributes"
gitdiff() {
  git -c core.attributesFile="$tmp/attributes" -c core.quotePath=false -c 'diff.agfunc.xfuncname=^[A-Za-z_][A-Za-z0-9_]*\(\)' \
    diff --no-renames "$@" "$from" "$to" -- plugins/agent-guard
}
gitdiff -U0 >"$tmp/diff"
gitdiff --name-only >"$tmp/paths"
# The functions that name the helper, in either revision of every changed file.
: >"$tmp/callers"
while IFS= read -r path; do
  case "$path" in
    '"'*) printf 'unreadable path in the diff: %s\n' "$path" >&2; printf 'scope=full\n'; exit 0 ;;
  esac
  for rev in "$from" "$to"; do
    git cat-file -e "$rev:$path" 2>/dev/null || continue
    git show "$rev:$path" | awk -v names="$names" '
      /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { name = $0; sub(/\(\).*/, "", name) }
      name != "" && $0 ~ names { hit[name] = 1 }
      END { for (n in hit) print n }' >>"$tmp/callers"
  done
done <"$tmp/paths"
awk -v names="$names" -v helper_functions="$helper_functions" -v helper_definition="^[-+](gitleaks_helper|gitleaks_exec)[A-Za-z0-9_]*[(]" -v hits="$tmp/hits" -v callers_file="$tmp/callers" '
  FILENAME == callers_file { caller[$0] = 1; next }
  function raise(level, why) {
    if (level == "full" || scope == "none") scope = level
    print level ": " why > hits
  }
  function defname(line,   d) {
    d = line; sub(/^[-+]/, "", d)
    if (d !~ /^[A-Za-z_][A-Za-z0-9_]*\(\)/) return ""
    sub(/\(\).*/, "", d)
    return d
  }
  /^diff --git / { inhunk = 0; next }
  /^@@ / {
    inhunk = 1; fn = ""; head = $0
    if (sub(/^@@ [^@]*@@ /, "", head) && head ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)/) { fn = head; sub(/\(\).*/, "", fn) }
    if (fn ~ helper_functions && fn != "") raise("full", "hunk in " fn)
    else if (fn in caller) raise("cost", "hunk in " fn)
    next
  }
  inhunk && /^[-+]/ {
    if ($0 ~ /(^[-+][ \t]*|[;&|({][ \t]*|[ \t](then|do|else)[ \t]+)(\.|source)[ \t]+[^ \t]/) raise("full", "sourcing line: " $0)
    else if ($0 ~ helper_definition) raise("full", "helper function definition: " $0)
    else if (defname($0) in caller) raise("cost", "caller function definition: " $0)
    else if ($0 ~ names) {
      if (fn == "" || fn ~ helper_functions) raise("full", "outside the callers: " $0)
      else raise("cost", "in " fn ": " $0)
    }
  }
  BEGIN { scope = "none"; printf "" > hits }
  END { print "scope=" scope }' "$tmp/callers" "$tmp/diff" >"$tmp/scope"
cat "$tmp/scope"
if [ -s "$tmp/hits" ]; then
  printf 'helper call sites changed:\n' >&2
  sort -u "$tmp/hits" | head -n 20 | sed 's/^/  /' >&2
fi

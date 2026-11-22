#!/usr/bin/env sh
# Whether a change touches the code that routes scans through the opt-in warm
# gitleaks helper (#537, #581), as a job output.
#
#   sh .github/scripts/helper-call-sites.sh BASE_REV HEAD_REV >> "$GITHUB_OUTPUT"
#
# Prints touched=true when the diff of plugins/agent-guard
#   - changes a line that names the helper variable or the helper wrappers,
#   - changes a function that names them (before or after the change), or
#   - adds or removes a line that sources another file, which this check
#     cannot read.
# The off-state job then also compares the default (helper unset) path with the
# base: helper code that adds work there must fail even though it adds the same
# work to the unusable-helper state, which a same-tree comparison cannot see.
# A change elsewhere (touched=false) is free to change hook behavior. The match
# errs toward true: a function spans from its definition to the next one, as
# in git's hunk header, so the code between two functions counts with the
# first. Anything that stops the check from running fails the script, so a
# missing answer never reads as "not touched".
set -eu
export LC_ALL=C
from=${1:?base revision required}
to=${2:?head revision required}
names='GITLEAKS_HELPER|gitleaks_helper|gitleaks_exec'
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
: >"$tmp/functions"
while IFS= read -r path; do
  case "$path" in
    '"'*) printf 'unreadable path in the diff: %s\n' "$path" >&2; printf 'touched=true\n'; exit 0 ;;
  esac
  for rev in "$from" "$to"; do
    git cat-file -e "$rev:$path" 2>/dev/null || continue
    git show "$rev:$path" | awk -v names="$names" '
      /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { name = $0; sub(/\(\).*/, "", name) }
      name != "" && $0 ~ names { hit[name] = 1 }
      END { for (n in hit) print n }' >>"$tmp/functions"
  done
done <"$tmp/paths"
sed -n 's/^@@ [^@]*@@ \([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' "$tmp/diff" | sort -u >"$tmp/hunk-functions"
{
  grep -E "^@@ [^@]*@@.*($names)|^[-+].*($names)|^[-+][[:space:]]*(\.|source)[[:space:]]" "$tmp/diff" || [ "$?" = 1 ]
  grep -Fxf "$tmp/functions" "$tmp/hunk-functions" | sed 's/^/changed function naming the helper: /' || [ "$?" = 1 ]
} >"$tmp/hits"
if [ -s "$tmp/hits" ]; then
  printf 'touched=true\n'
  printf 'helper call sites changed:\n' >&2
  head -n 20 "$tmp/hits" | sed 's/^/  /' >&2
else
  printf 'touched=false\n'
fi

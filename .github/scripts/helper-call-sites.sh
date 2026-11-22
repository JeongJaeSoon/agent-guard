#!/usr/bin/env sh
# Whether a change touches the code that routes scans through the opt-in warm
# gitleaks helper (#537, #581), as a job output.
#
#   sh .github/scripts/helper-call-sites.sh BASE_REV HEAD_REV >> "$GITHUB_OUTPUT"
#
# Prints touched=true when a changed line, or the function a changed hunk sits
# in, names the helper variable or the helper wrappers. The off-state job then
# also compares the default (helper unset) path with the base: helper code
# that adds work there must fail even though it adds the same work to the
# unusable-helper state, which a same-tree comparison cannot see. A change
# elsewhere (touched=false) is free to change hook behavior. The match errs
# toward true: a hunk right after those functions reports the last function
# before it. Anything that stops the diff from running fails the script, so a
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
git -c core.attributesFile="$tmp/attributes" -c 'diff.agfunc.xfuncname=^[A-Za-z_][A-Za-z0-9_]*\(\)' \
  diff --no-renames -U0 "$from" "$to" -- plugins/agent-guard >"$tmp/diff"
found=0
grep -E "^@@ [^@]*@@.*($names)|^[-+].*($names)" "$tmp/diff" >"$tmp/hits" || found=$?
case "$found" in
  0) printf 'touched=true\n'; printf 'helper call sites changed:\n' >&2; head -n 20 "$tmp/hits" | sed 's/^/  /' >&2 ;;
  1) printf 'touched=false\n' ;;
  *) exit "$found" ;;
esac

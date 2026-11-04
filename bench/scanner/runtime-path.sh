#!/bin/sh
# Runtime-only PATH for compiler-free execution on Linux and macOS runners.
set -eu
out=${1:?new absolute directory required}
case "$out" in /*) ;; *) exit 2 ;; esac
[ ! -e "$out" ] || exit 2
mkdir -p "$out"
for tool in sh bash awk gawk basename cat chmod cksum cmp cp curl cut date dd df \
  dirname du env expr file find getent git grep head hostname id install kill \
  ln ls mkdir mktemp mv od perl pgrep pkill printf ps pwd readlink realpath rm \
  rmdir sed seq setsid shasum sha256sum sleep sort stat tail tar tee test timeout \
  touch tr uname uniq wc xargs; do
  resolved=$(command -v "$tool" 2>/dev/null || :)
  case "$resolved" in /*) ln -s "$resolved" "$out/$tool" ;; esac
done

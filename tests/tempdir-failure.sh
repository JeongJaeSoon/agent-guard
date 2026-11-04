#!/bin/sh
# A failed mktemp must not turn a cleanup target into the caller's worktree.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' 0
mkdir "$case_dir/bin" "$case_dir/work"
printf '#!/bin/sh\nexit 1\n' > "$case_dir/bin/mktemp"
chmod 755 "$case_dir/bin/mktemp"
printf 'preserve caller\n' > "$case_dir/work/sentinel"
if (cd "$case_dir/work" && PATH="$case_dir/bin:$PATH" sh "$ROOT/tests/deny-read-mask-allow.sh"); then
  echo 'mktemp failure was ignored' >&2; exit 1
fi
test "$(cat "$case_dir/work/sentinel")" = 'preserve caller'
printf 'ok - temporary-directory failure preserves the caller directory\n'

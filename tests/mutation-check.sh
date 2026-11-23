#!/usr/bin/env sh
# Hand-written mutation check for the core detection rules (#590 item 5).
#
# Each entry of tests/mutations.json is one literal edit that loosens a rule in
# plugins/agent-guard/bin/agent-guard: "old" must occur exactly once in the bin
# and is replaced by "new". The edit goes to a temporary copy of the tree,
# never to the checkout, and at least one of the entry's "tests" must then
# fail. Before any edit, the same tests must pass on an unmutated copy, so a
# test that fails for an unrelated reason cannot make a mutation look caught.
#
# Usage: sh tests/mutation-check.sh [--lint] [ID...]
#   --lint  only validate the list and the workflow that runs it, run no test.
#   ID      check only these mutations.
# AGENT_GUARD_MUTATION_JOBS (default 2) sets how many tree copies run side by
# side. A test stops at its first "not ok" line once it has caught a mutation.
#
# Exit 0: every mutation was caught. 1: a mutation survived. 2: the check could
# not run (an invalid list, an edit that does not apply, a failing baseline).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
LIST=${AGENT_GUARD_MUTATION_LIST:-$ROOT/tests/mutations.json}
WORKFLOW=$ROOT/.github/workflows/mutation-check.yml
BIN_REL=plugins/agent-guard/bin/agent-guard
JOBS=${AGENT_GUARD_MUTATION_JOBS:-2}
# The mutants loosen awk and shell rules, not the scanner. Tests that honor
# this variable use the bundled stub, as the CI runner (no gitleaks on PATH)
# does; a real gitleaks under load can let a must-fail row through (#617).
: "${AGENT_GUARD_TEST_REAL_GITLEAKS=}"
export AGENT_GUARD_TEST_REAL_GITLEAKS

die() {
  printf 'mutation-check: %s\n' "$*" >&2
  exit 2
}

case $JOBS in ''|*[!0-9]*|0) die "AGENT_GUARD_MUTATION_JOBS must be a positive integer, got: $JOBS" ;; esac
lint=0
if [ "${1-}" = --lint ]; then
  lint=1
  shift
fi

jq -e '
  type == "array" and length > 0
  and all(.[];
    type == "object"
    and (.id | type == "string" and test("^[a-z0-9-]+$"))
    and (.rule | type == "string" and length > 0)
    and (.old | type == "string" and length > 0)
    and (.new | type == "string")
    and .old != .new
    and (.tests | type == "array" and length > 0
         and all(.[]; type == "string" and test("^tests/[A-Za-z0-9_.-]+[.]sh$"))))
  and ((map(.id) | unique | length) == length)
' "$LIST" >/dev/null || die "invalid mutation list: $LIST"

for test_path in $(jq -r '[.[].tests[]] | unique | .[]' "$LIST"); do
  [ -f "$ROOT/$test_path" ] || die "listed test does not exist: $test_path"
  # The workflow runs only when a listed test changes, so it must list each.
  grep -qxF "      - $test_path" "$WORKFLOW" || die "$test_path is missing from the paths of $WORKFLOW"
done

if [ "$lint" -eq 1 ]; then
  for id in "$@"; do die "--lint takes no mutation id: $id"; done
  printf 'mutation-check: list and workflow paths are valid (%s mutations)\n' "$(jq length "$LIST")"
  exit 0
fi

ORIG=$ROOT/$BIN_REL
# jq carries the bin as a string; it must come back byte for byte.
jq -j -Rs . "$ORIG" | cmp -s - "$ORIG" || die "jq does not reproduce $BIN_REL byte for byte"

if [ "$#" -gt 0 ]; then
  indexes=
  for id in "$@"; do
    i=$(jq --arg id "$id" 'map(.id) | index($id) // empty' "$LIST")
    [ -n "$i" ] || die "unknown mutation id: $id"
    indexes="$indexes $i"
  done
else
  indexes=$(jq -r 'keys[]' "$LIST")
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-mutation.XXXXXX") || die "cannot create a work directory"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 2' HUP INT TERM

# The tree as the checkout has it, edits and new files included.
mkdir "$WORK/src" || die "cannot create $WORK/src"
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard | tar -cf - --null -T -) \
  | (cd "$WORK/src" && tar -xf -) || die "cannot copy the tree"
cmp -s "$ORIG" "$WORK/src/$BIN_REL" || die "the copied bin differs from the checkout"

# run_test TREE TEST LOG: 0 when TEST passes in TREE, 1 when it fails. The
# test stops at its first "not ok" line; its temporary files live under TREE.
# shellcheck disable=SC2329 # the workers below call these through run_workers
run_test() {
  rm -rf "$1.tmp" && mkdir "$1.tmp" || return 2
  rm -f "$3.status"
  { TMPDIR="$1.tmp" sh "$1/$2" 2>&1; echo "$?" >"$3.status"; } \
    | awk -v out="$3" '{ print >out } /^not ok/ { exit 1 }'
  rt_caught=$?
  rm -rf "$1.tmp"
  [ "$rt_caught" -eq 0 ] || return 1
  [ -s "$3.status" ] || return 2
  [ "$(cat "$3.status")" = 0 ] || return 1
  return 0
}

# Spread the given lines over JOBS lists, one per worker.
spread() {
  rm -f "$WORK"/list.*
  sp_n=0
  for sp_item in $1; do
    printf '%s\n' "$sp_item" >>"$WORK/list.$((sp_n % JOBS))"
    sp_n=$((sp_n + 1))
  done
}

# shellcheck disable=SC2329
baseline_worker() {
  bw_tree=$WORK/tree.$1
  if ! { rm -rf "$bw_tree" && cp -R "$WORK/src" "$bw_tree"; }; then echo "error copy" >"$WORK/result.$1"; return; fi
  : >"$WORK/result.$1"
  while IFS= read -r bw_test; do
    bw_log=$WORK/log.base.$(printf '%s' "$bw_test" | tr '/' '_')
    run_test "$bw_tree" "$bw_test" "$bw_log"
    case $? in
      0) printf 'pass %s\n' "$bw_test" >>"$WORK/result.$1" ;;
      1) printf 'fail %s %s\n' "$bw_test" "$bw_log" >>"$WORK/result.$1" ;;
      *) printf 'error %s %s\n' "$bw_test" "$bw_log" >>"$WORK/result.$1" ;;
    esac
  done <"$WORK/list.$1"
}

# shellcheck disable=SC2329
mutation_worker() {
  mw_tree=$WORK/tree.$1
  if ! { rm -rf "$mw_tree" && cp -R "$WORK/src" "$mw_tree"; }; then echo "error copy" >"$WORK/result.$1"; return; fi
  : >"$WORK/result.$1"
  while IFS= read -r mw_i; do
    mw_id=$(jq -r --argjson i "$mw_i" '.[$i].id' "$LIST")
    if ! jq -j -Rs --slurpfile m "$LIST" --argjson i "$mw_i" '
        $m[0][$i] as $x | split($x.old) as $p
        | if ($p | length) == 2 then $p | join($x.new)
          else error("the old text occurs \(($p | length) - 1) times, not once") end
      ' "$ORIG" >"$mw_tree/$BIN_REL" 2>"$WORK/apply.$1"; then
      printf 'error %s %s\n' "$mw_id" "$(tr '\n' ' ' <"$WORK/apply.$1")" >>"$WORK/result.$1"
      cp "$ORIG" "$mw_tree/$BIN_REL"
      continue
    fi
    mw_verdict="survived $mw_id"
    for mw_test in $(jq -r --argjson i "$mw_i" '.[$i].tests[]' "$LIST"); do
      mw_log=$WORK/log.$mw_id
      run_test "$mw_tree" "$mw_test" "$mw_log"
      case $? in
        0) ;;
        1)
          mw_check=$(grep -m 1 '^not ok' "$mw_log" 2>/dev/null || echo "exit status $(cat "$mw_log.status" 2>/dev/null)")
          mw_verdict="caught $mw_id $mw_test: $mw_check"
          break
          ;;
        *) mw_verdict="error $mw_id $mw_test did not report a status"; break ;;
      esac
    done
    printf '%s\n' "$mw_verdict" >>"$WORK/result.$1"
    cp "$ORIG" "$mw_tree/$BIN_REL"
  done <"$WORK/list.$1"
}

run_workers() {
  rw_pids=
  rw_w=0
  while [ "$rw_w" -lt "$JOBS" ]; do
    if [ -f "$WORK/list.$rw_w" ]; then
      "$1" "$rw_w" &
      rw_pids="$rw_pids $!"
    fi
    rw_w=$((rw_w + 1))
  done
  for rw_pid in $rw_pids; do wait "$rw_pid"; done
  cat "$WORK"/result.* 2>/dev/null
  rm -f "$WORK"/result.*
}

tests=$(for i in $indexes; do jq -r --argjson i "$i" '.[$i].tests[]' "$LIST"; done | sort -u)
printf 'mutation-check: baseline of %s test files on an unmutated copy\n' "$(printf '%s\n' "$tests" | wc -l | tr -d ' ')"
spread "$tests"
baseline=$(run_workers baseline_worker)
printf '%s\n' "$baseline" | grep '^pass ' | sed 's/^/  /'
if printf '%s\n' "$baseline" | grep -q '^\(fail\|error\) '; then
  printf '%s\n' "$baseline" | grep -E '^(fail|error) ' | while read -r verdict test_path test_log; do
    printf 'mutation-check: baseline %s: %s\n' "$verdict" "$test_path" >&2
    [ -f "$test_log" ] && grep '^not ok' "$test_log" | head -n 5 | sed 's/^/  /' >&2
  done
  die "the unmutated tree fails a listed test; no mutation was judged"
fi

# indexes is a blank-separated list of numbers; split it on purpose.
# shellcheck disable=SC2086
printf 'mutation-check: %s mutations\n' "$(printf '%s\n' $indexes | wc -l | tr -d ' ')"
spread "$indexes"
results=$(run_workers mutation_worker)
printf '%s\n' "$results" | grep '^caught ' | sed 's/^/  /'
status=0
if printf '%s\n' "$results" | grep -q '^error '; then
  printf '%s\n' "$results" | grep '^error ' | sed 's/^/mutation-check: /' >&2
  status=2
fi
survivors=$(printf '%s\n' "$results" | sed -n 's/^survived //p')
for id in $survivors; do
  rule=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .rule' "$LIST")
  printf 'mutation-check: SURVIVED %s (%s)\n' "$id" "$rule" >&2
  [ "$status" -eq 2 ] || status=1
done
# shellcheck disable=SC2086
expected=$(printf '%s\n' $indexes | wc -l | tr -d ' ')
judged=$(printf '%s\n' "$results" | grep -cE '^(caught|survived|error) ')
[ "$judged" -eq "$expected" ] || die "judged $judged of $expected mutations"
[ "$status" -ne 0 ] || printf 'mutation-check: all %s mutations were caught\n' "$expected"
exit "$status"

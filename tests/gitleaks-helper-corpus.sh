#!/bin/sh
# #537 differential: every input is scanned by the official gitleaks and by
# the warm helper (through agent-guard-scan) in both invocation shapes the
# CLI uses, and must give the same exit code, stdout, stderr and findings.
#
#   AGENT_GUARD_TEST_HELPER_DIR=/abs/build AGENT_GUARD_TEST_REAL_GITLEAKS=/abs/gitleaks \
#     sh tests/gitleaks-helper-corpus.sh [--capture-suite] [CORPUS_DIR...]
#
# Inputs: the repository's test fixtures, the upstream gitleaks testdata at
# the pinned release (fetched when the network allows), every CORPUS_DIR,
# and with --capture-suite every input tests/run.sh hands to its mock
# gitleaks (AGENT_GUARD_TEST_SCAN_CAPTURE). Identical inputs are scanned once.
# Capturing changes nothing else, except that the few suite cases that run the
# scanner under a 64 KiB file-size limit fail (their large copy cannot be
# written) and those inputs are missing from the capture.
#
# The real gitleaks reports findings in rule-map order and logs a clock time
# and a duration, which differ between any two of its own runs; findings are
# compared as a sorted set and log lines without those two values.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
HELPER_DIR=${AGENT_GUARD_TEST_HELPER_DIR:?built helper directory required}
REAL=${AGENT_GUARD_TEST_REAL_GITLEAKS:?official gitleaks required}
CFG="$ROOT/plugins/agent-guard/config/gitleaks.toml"
JOBS=${AGENT_GUARD_TEST_JOBS:-4}
CASE=$(mktemp -d /tmp/aghc.XXXXXX) || exit 1
CASE=$(CDPATH= cd -- "$CASE" && pwd -P)
STATE="$CASE/xs/agent-guard"
cleanup() {
  for pid in $(pgrep -f "agent-guard-gitleaks-helper serve --state-dir $STATE" 2>/dev/null); do kill "$pid" 2>/dev/null; done
  rm -rf "$CASE"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
mkdir -p "$STATE" "$CASE/corpus" "$CASE/results" && chmod 700 "$CASE/xs" "$STATE"
capture=
for arg do
  case "$arg" in
    --capture-suite) capture=1 ;;
    *) [ -d "$arg" ] || { echo "not a directory: $arg" >&2; exit 2; } ;;
  esac
done

add_tree() { # copy every regular file under $1 into the corpus, named by content hash
  find "$1" -type f -size -2048k 2>/dev/null | while IFS= read -r f; do
    sum=$(shasum -a 256 <"$f" | cut -c1-16)
    [ -e "$CASE/corpus/$sum" ] || cp "$f" "$CASE/corpus/$sum"
  done
}
add_tree "$ROOT/tests/fixtures"
if git init -q "$CASE/upstream" 2>/dev/null \
    && git -C "$CASE/upstream" remote add origin https://github.com/gitleaks/gitleaks.git \
    && git -C "$CASE/upstream" fetch -q --depth=1 origin 83d9cd684c87d95d656c1458ef04895a7f1cbd8e 2>/dev/null \
    && git -C "$CASE/upstream" checkout -q FETCH_HEAD -- testdata 2>/dev/null; then
  add_tree "$CASE/upstream/testdata"
  upstream=yes
else
  upstream=no
fi
for arg do
  [ "$arg" = --capture-suite ] || add_tree "$arg"
done
if [ -n "$capture" ]; then
  mkdir -p "$CASE/capture"
  AGENT_GUARD_TEST_SCAN_CAPTURE="$CASE/capture" sh "$ROOT/tests/run.sh" >"$CASE/suite.log" 2>&1 || :
  echo "captured $(find "$CASE/capture" -type f | wc -l | tr -d ' ') scan inputs from tests/run.sh"
  add_tree "$CASE/capture"
fi

mkdir -p "$CASE/lib" "$CASE/bin"
cp "$HELPER_DIR/agent-guard-scan" "$HELPER_DIR/agent-guard-gitleaks-helper" "$CASE/lib/"
cp "$REAL" "$CASE/bin/gitleaks"
export AGENT_GUARD_GITLEAKS_HELPER_IDLE_SECONDS=600
# Warm one helper first so every comparison below is a warm answer.
printf 'ls\n' | "$CASE/lib/agent-guard-scan" --gitleaks "$CASE/bin/gitleaks" --gitleaks-version 8.30.1 \
  --state-dir "$STATE" -- stdin --no-banner --config "$CFG" >/dev/null 2>&1
n=0
until ls "$STATE"/gitleaks-helper/*.sock >/dev/null 2>&1 || [ "$n" -ge 100 ]; do sleep 0.1; n=$((n + 1)); done

cat >"$CASE/compare.sh" <<'EOF'
# $1 input; environment: CASE CFG. Prints one result line.
input=$1
name=${input##*/}
w="$CASE/work.$name"
mkdir -p "$w"
gl="$CASE/bin/gitleaks"
client() { "$CASE/lib/agent-guard-scan" --gitleaks "$gl" --gitleaks-version 8.30.1 --state-dir "$CASE/xs/agent-guard" -- "$@"; }
normal_log() { sed -e 's/^[^ ]* //' -e 's/ in [^ ]*$/ in -/' "$1"; }
normal_report() { jq -S 'sort_by(.RuleID, .StartLine, .StartColumn, .Secret)' "$1" 2>/dev/null || echo invalid; }
result=same
A="stdin --redact --no-banner --no-color --log-level error --config $CFG --exit-code 1"
"$gl" $A <"$input" >"$w/ra.out" 2>"$w/ra.err"; ra=$?
AGENT_GUARD_GITLEAKS_HELPER_TRACE="$w/ta" client $A <"$input" >"$w/ca.out" 2>"$w/ca.err"; ca=$?
[ "$ra" = "$ca" ] && cmp -s "$w/ra.out" "$w/ca.out" && cmp -s "$w/ra.err" "$w/ca.err" || result="differ-A($ra/$ca)"
size=$(wc -c <"$input" | tr -d ' ')
if [ "$size" -le 65536 ]; then
  # Both read the same bytes from a pipe.
  cat "$input" | "$gl" $A >"$w/rp.out" 2>"$w/rp.err"; rp=$?
  cat "$input" | AGENT_GUARD_GITLEAKS_HELPER_TRACE="$w/tp" client $A >"$w/cp.out" 2>"$w/cp.err"; cp=$?
  [ "$rp" = "$cp" ] && cmp -s "$w/rp.out" "$w/cp.out" && cmp -s "$w/rp.err" "$w/cp.err" || result="differ-pipe($rp/$cp)"
else
  printf 'real:large\n' >"$w/tp"
fi
"$gl" stdin --report-format json --report-path "$w/rb.json" --no-banner --config "$CFG" <"$input" >"$w/rb.out" 2>"$w/rb.err"; rb=$?
AGENT_GUARD_GITLEAKS_HELPER_TRACE="$w/tb" client stdin --report-format json --report-path "$w/cb.json" --no-banner --config "$CFG" <"$input" >"$w/cb.out" 2>"$w/cb.err"; cb=$?
[ "$rb" = "$cb" ] && cmp -s "$w/rb.out" "$w/cb.out" \
  && [ "$(normal_log "$w/rb.err")" = "$(normal_log "$w/cb.err")" ] \
  && [ "$(normal_report "$w/rb.json")" = "$(normal_report "$w/cb.json")" ] || result="differ-B($rb/$cb)"
findings=$(jq 'length' "$w/rb.json" 2>/dev/null || echo 0)
printf '%s %s %s %s %s %s\n' "$name" "$result" "$findings" "$(cat "$w/ta")" "$(cat "$w/tp")" "$(cat "$w/tb")"
rm -rf "$w"
EOF
total=$(find "$CASE/corpus" -type f | wc -l | tr -d ' ')
echo "comparing $total unique inputs (upstream testdata: $upstream) with $JOBS jobs"
cd "$CASE" || exit 1
find "$CASE/corpus" -type f -print | CASE="$CASE" CFG="$CFG" xargs -P "$JOBS" -n 1 sh "$CASE/compare.sh" >"$CASE/results.txt"
answered=$(awk '$4 == "helper" && $6 == "helper"' "$CASE/results.txt" | wc -l | tr -d ' ')
differ=$(awk '$2 != "same"' "$CASE/results.txt" | wc -l | tr -d ' ')
findings=$(awk '{ s += $3 } END { print s + 0 }' "$CASE/results.txt")
with_findings=$(awk '$3 > 0' "$CASE/results.txt" | wc -l | tr -d ' ')
awk '{ print $4 " " $6 }' "$CASE/results.txt" | sort | uniq -c | sed 's/^/  paths (file A, file B): /'
awk '$2 != "same"' "$CASE/results.txt" | sed 's/^/  DIFFER: /'
echo "inputs: $(wc -l <"$CASE/results.txt" | tr -d ' ') of $total; with findings: $with_findings; findings: $findings; warm answers: $answered; differences: $differ"
# Every input the helper takes (not over the size limits) must be answered
# warm; a few fallbacks under load (send/answer timeouts) are allowed, and
# they were still compared above.
eligible=$(awk '$4 != "real:large"' "$CASE/results.txt" | wc -l | tr -d ' ')
echo "eligible for the helper: $eligible"
[ "$(wc -l <"$CASE/results.txt" | tr -d ' ')" = "$total" ] && [ "$differ" = 0 ] \
  && [ "$((answered * 100))" -ge "$((eligible * 98))" ]

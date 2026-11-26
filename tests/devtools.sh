#!/bin/sh
# Developer tool option, resource and failure-gate contracts; no interpreter is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
TOOLS=${1:?absolute devtools binary required}
# Optional: an official gitleaks, for the contracts a mock cannot show.
SCANNER=${2:-}
CASE=$(mktemp -d)
trap 'rm -rf "$CASE"' 0
"$TOOLS" --help >"$CASE/help"
"$TOOLS" measure-selected-bash --help >"$CASE/command-help"
if "$TOOLS" measure-selected-bash --unknown-option >"$CASE/unknown-output" 2>"$CASE/unknown-error"; then
  echo 'unknown option was silently accepted' >&2; exit 1
fi
grep -q 'unknown option' "$CASE/unknown-error"
status=0
"$TOOLS" resource-sample "$CASE/resources.json" sh -c 'exit 7' || status=$?
test "$status" = 7
jq -e '.wall_seconds >= 0 and .user_cpu_seconds >= 0 and .system_cpu_seconds >= 0 and .max_child_peak_rss_kib > 0' "$CASE/resources.json" >/dev/null
"$TOOLS" measure-selected-bash >"$CASE/locations.json"
jq -e '.denominator > 0 and .observed > 0 and .definition_only_observed == 0' "$CASE/locations.json" >/dev/null
# Refresh only a disposable repository, never the checked-in pin during tests.
mkdir -p "$CASE/pins/plugins/agent-guard/bin" "$CASE/pins/tests/helpers"
cp tests/helpers/extract-functions.sh "$CASE/pins/tests/helpers/"
printf 'sample() {\n  :\n}\n' >"$CASE/pins/plugins/agent-guard/bin/agent-guard"
printf '{"sample":{"relative_lines":[2],"body_sha256":"stale","note":"keep"}}\n' >"$CASE/pins/tests/selected-bash-locations.json"
cp "$CASE/pins/tests/selected-bash-locations.json" "$CASE/before.json"
if (cd "$CASE/pins" && "$TOOLS" measure-selected-bash) >"$CASE/stale-output" 2>"$CASE/stale-error"; then
  echo 'measurement accepted a stale pin' >&2; exit 1
fi
grep -F 'sh scripts/devtools.sh refresh-selected-bash' "$CASE/stale-error"
cmp "$CASE/before.json" "$CASE/pins/tests/selected-bash-locations.json"
if (cd "$CASE/pins" && CI=true "$TOOLS" refresh-selected-bash) >"$CASE/ci-output" 2>"$CASE/ci-error"; then
  echo 'refresh was allowed in CI' >&2; exit 1
fi
cmp "$CASE/before.json" "$CASE/pins/tests/selected-bash-locations.json"
(unset CI; cd "$CASE/pins" && "$TOOLS" refresh-selected-bash)
sh tests/helpers/extract-functions.sh "$CASE/pins/plugins/agent-guard/bin/agent-guard" "$CASE" sample
expected=$(shasum -a 256 "$CASE/sample.sh" | awk '{ print $1 }')
jq -e --arg expected "$expected" '.sample.body_sha256 == $expected and .sample.relative_lines == [2] and .sample.note == "keep"' "$CASE/pins/tests/selected-bash-locations.json" >/dev/null
cp "$CASE/pins/tests/selected-bash-locations.json" "$CASE/refreshed.json"
(unset CI; cd "$CASE/pins" && "$TOOLS" refresh-selected-bash)
cmp "$CASE/refreshed.json" "$CASE/pins/tests/selected-bash-locations.json"
# Extraction failure leaves every original pin intact.
printf 'missing() {\n  :\n}\n' >"$CASE/pins/plugins/agent-guard/bin/agent-guard"
if (unset CI; cd "$CASE/pins" && "$TOOLS" refresh-selected-bash) >"$CASE/missing-output" 2>"$CASE/missing-error"; then
  echo 'refresh accepted a missing selected function' >&2; exit 1
fi
cmp "$CASE/refreshed.json" "$CASE/pins/tests/selected-bash-locations.json"
# A failing partition must keep both logs and a failed machine-readable report.
mkdir -p "$CASE/failure/plugins/agent-guard/bin" "$CASE/failure/tests"
printf 'frozen source\n' >"$CASE/failure/plugins/agent-guard/bin/agent-guard"
printf 'printf "passed: 0\\nfailed: 1\\n"; exit 7\n' >"$CASE/failure/tests/run.sh"
printf 'printf "passed: 1\\nfailed: 0\\n"\n' >"$CASE/failure/tests/native-suite.sh"
if (cd "$CASE/failure" && "$TOOLS" verify --out "$CASE/ignored-out" "--out=$CASE/failed-partitions" --native-core /bin/sh --shards 1) >"$CASE/failed-report" 2>/dev/null; then
  echo 'verification accepted a failing partition' >&2; exit 1
fi
jq -e '.stable and .results[0].status == 7 and .results[1].status == 0' "$CASE/failed-partitions/verification.json" >/dev/null
grep -q 'failed: 1' "$CASE/failed-partitions/shell-1.log"
grep -q 'passed: 1' "$CASE/failed-partitions/native-4.log"
# Hook latency: every arm that needs no helper runs with the mock scanner, each
# run is stored as a sample, and the summary on standard output holds none.
"$TOOLS" hook-latency --unverified --scanner "$ROOT/tests/fixtures/mock-gitleaks" --runs 2 --out "$CASE/latency.json" >"$CASE/latency-summary.json"
jq -e '.arms == ["helper-off", "repeat-input"] and (.samples | length) == 20 and (.problems | length) == 0 and (.verified | not) and .complete
  and ([.samples[] | select(.status != 0 or .seconds <= 0 or .max_child_peak_rss_kib <= 0)] | length) == 0
  and ([.samples[] | [.case, .arm]] | unique | length) == 10
  and ([.samples[] | select((.scanner | type) != "string" or (.cache | type) != "string" or (.probe | type) != "string" or (.client | type) != "array")] | length) == 0
  and ([.controls[] | select(.status != 2)] | length) == 0 and (.controls | length) == 1
  and (.cells | length) == 10 and ([.cells[] | select(.n != 2 or .median_ms <= 0 or .p95_ms < .median_ms)] | length) == 0' "$CASE/latency.json" >/dev/null
jq -e 'has("samples") | not' "$CASE/latency-summary.json" >/dev/null
jq -e '(.cells | length) == 10' "$CASE/latency-summary.json" >/dev/null
"$TOOLS" hook-latency --unverified --scanner "$ROOT/tests/fixtures/mock-gitleaks" --runs 1 --case pre-read --arm helper-off --entry manifest --out "$CASE/latency-manifest.json" >/dev/null
jq -e '.entry == "manifest" and (.samples | length) == 1 and .samples[0].status == 0' "$CASE/latency-manifest.json" >/dev/null
# With the real scanner the samples say which scanner ran and what the
# clean-scan cache did: a scan without the helper is gitleaks, a hook with no
# scan is none, and only a repeated Bash command is a cache hit.
if [ -n "$SCANNER" ]; then
  "$TOOLS" hook-latency --scanner "$SCANNER" --runs 2 --out "$CASE/latency-real.json" >/dev/null
  jq -e '.scanner_evidence.threshold_kib > 0 and (.problems | length) == 0 and .verified
    and ([.cells[] | select(.probe_runs_left_out != 0)] | length) == 0 and ([.samples[].scanner] | index("unknown") == null)
    and ([.cells[] | select(.arm == "helper-off" and .case != "pre-read") | .scanner == {"gitleaks": 2}] | all)
    and ([.cells[] | select(.case == "pre-read") | .scanner == {"none": 2} and .cache == {"none": 2}] | all)
    and ([.cells[] | select(.arm == "helper-off" and .case == "pre-bash") | .cache == {"stored": 2}] | all)
    and ([.cells[] | select(.arm == "repeat-input") | .cache == (if .case == "pre-bash" then {"hit": 2} else {"none": 2} end)] | all)
    and ([.cells[] | select(.arm == "repeat-input" and .case == "pre-bash") | .scanner == {"none": 2}] | all)
    and .cache_controls == [{"arm": "repeat-input", "case": "pre-bash", "scanner_with_cache_off": "gitleaks"}]
    and ([.samples[] | select(.aggregated | not)] | length) == 0
    and (.cells | length) == 10' "$CASE/latency-real.json" >/dev/null
fi
# What the samples claim must have evidence. A scanner that fails on the
# control input blocks it too, with exit 2: that is not a detected secret.
mkdir "$CASE/failing" "$CASE/unpinned"
printf '%s\n' '#!/bin/sh' 'case "${1:-}" in version) echo 8.30.1; exit 0 ;; esac' \
  'case "$(cat)" in *"PRIVATE KEY"*) exit 2 ;; esac' 'exit 0' >"$CASE/failing/gitleaks"
chmod 755 "$CASE/failing/gitleaks"
if "$TOOLS" hook-latency --unverified --scanner "$CASE/failing/gitleaks" --runs 1 --case pre-read --arm helper-off --out "$CASE/latency-failing.json" >/dev/null 2>&1; then
  echo 'hook-latency took a scanner failure for a detected control' >&2; exit 1
fi
jq -e '.controls[0].status == 2 and .controls[0].outcome == "degraded" and (.problems | length) == 1' "$CASE/latency-failing.json" >/dev/null
# A scanner that fails on the measured input: the samples are kept, none is
# summarized, and they are stored even when nobody reads the summary.
printf '%s\n' '#!/bin/sh' 'case "${1:-}" in version) echo 8.30.1; exit 0 ;; esac' \
  'case "$(cat)" in *"note line"*) exit 2 ;; esac' 'exit 0' >"$CASE/failing/gitleaks"
if "$TOOLS" hook-latency --unverified --scanner "$CASE/failing/gitleaks" --runs 2 --case pre-write --arm helper-off --out "$CASE/latency-degraded.json" 2>/dev/null | true; then
  :
fi
jq -e '(.samples | length) == 2 and ([.samples[] | select(.aggregated)] | length) == 0 and (.cells | length) == 0
  and ([.samples[].outcome] | unique) == ["degraded"] and (.problems | length) > 0' "$CASE/latency-degraded.json" >/dev/null
# A hook that outlives the timeout ends the run; the samples before it are
# stored with the one that failed.
printf '%s\n' '#!/bin/sh' 'case "${1:-}" in version) echo 8.30.1; exit 0 ;; esac' \
  'case "$(cat)" in *"summary helper-off-1"*) sleep 30 ;; esac' 'exit 0' >"$CASE/failing/gitleaks"
if "$TOOLS" hook-latency --unverified --scanner "$CASE/failing/gitleaks" --runs 3 --timeout 5 --case pre-write --arm helper-off --out "$CASE/latency-timeout.json" >/dev/null 2>&1; then
  echo 'hook-latency passed a run that timed out' >&2; exit 1
fi
jq -e '(.complete | not) and (.samples | length) == 2 and .samples[0].aggregated and .samples[0].status == 0
  and (.samples[1].aggregated | not) and (.samples[1].error | type) == "string"
  and (.cells | length) == 1 and .cells[0].n == 1 and .cells[0].left_out == 1 and .cells[0].probe_runs_left_out == 0' "$CASE/latency-timeout.json" >/dev/null
# Helper binaries the CLI does not pin are never run: the helper arms would
# time gitleaks itself, so the run fails instead of naming it warm.
for name in agent-guard-scan agent-guard-gitleaks-helper; do
  printf '%s\n' '#!/bin/sh' 'exit 2' >"$CASE/unpinned/$name"
  chmod 755 "$CASE/unpinned/$name"
done
if "$TOOLS" hook-latency --unverified --scanner "$ROOT/tests/fixtures/mock-gitleaks" --helper "$CASE/unpinned" --runs 1 --case pre-write --arm warm-helper --out "$CASE/latency-unpinned.json" >/dev/null 2>&1; then
  echo 'hook-latency named a run without the scan client warm' >&2; exit 1
fi
jq -e '(.problems | length) > 0 and .controls[0].client == []' "$CASE/latency-unpinned.json" >/dev/null
# A scanner whose runs cannot be told from a hook without a scan is refused
# unless the caller says the run is unverified.
if "$TOOLS" hook-latency --scanner "$ROOT/tests/fixtures/mock-gitleaks" --runs 1 --case pre-read --arm helper-off --out "$CASE/latency-unmarked.json" >/dev/null 2>"$CASE/latency-unmarked-error"; then
  echo 'hook-latency took a test double for a verified scanner' >&2; exit 1
fi
grep -qF -- '--unverified' "$CASE/latency-unmarked-error"
test ! -e "$CASE/latency-unmarked.json"
# A manifest command runs bin/agent-guard of its root: another file named as
# the binary would be reported and never run.
mkdir "$CASE/renamed"
cp -R plugins/agent-guard "$CASE/renamed/agent-guard"
cp "$CASE/renamed/agent-guard/bin/agent-guard" "$CASE/renamed/agent-guard/bin/candidate"
if "$TOOLS" hook-latency --unverified --binary "$CASE/renamed/agent-guard/bin/candidate" --scanner "$ROOT/tests/fixtures/mock-gitleaks" --entry manifest \
    --runs 1 --case pre-read --arm helper-off --out "$CASE/latency-renamed.json" >/dev/null 2>"$CASE/latency-renamed-error"; then
  echo 'hook-latency reported a binary the manifest command does not run' >&2; exit 1
fi
grep -qF 'must be that file' "$CASE/latency-renamed-error"
# A script scanner has no probe cache record: its probe result is unknown.
jq -e '[.samples[].probe] | unique == ["unknown"]' "$CASE/latency.json" >/dev/null
jq -e '[.samples[].outcome] | unique == ["pass"]' "$CASE/latency.json" >/dev/null
# An interrupted run removes its own temporary directory.
"$TOOLS" hook-latency --unverified --scanner "$ROOT/tests/fixtures/mock-gitleaks" --runs 50 --out "$CASE/latency-interrupted.json" >/dev/null 2>"$CASE/latency-interrupted-error" &
latency_pid=$!
tries=0
until sandbox=$(sed -n 's/^sandbox //p' "$CASE/latency-interrupted-error") && [ -n "$sandbox" ]; do
  tries=$((tries + 1))
  [ "$tries" -lt 100 ] || { echo 'hook-latency named no sandbox' >&2; exit 1; }
  sleep 0.1
done
test -d "$sandbox"
sleep 1
kill -TERM "$latency_pid"
status=0
wait "$latency_pid" || status=$?
test "$status" = 143
test ! -e "$sandbox"
# The sample file's directory is made before anything is measured, and the
# command runs from outside a checkout when it is given the CLI.
(cd "$CASE" && "$TOOLS" hook-latency --unverified --binary "$ROOT/plugins/agent-guard/bin/agent-guard" --scanner "$ROOT/tests/fixtures/mock-gitleaks" \
  --runs 1 --case pre-read --arm helper-off --out "$CASE/new/directory/latency.json" >/dev/null 2>&1)
jq -e '(.samples | length) == 1 and .scanner_version == "8.30.1-mock"' "$CASE/new/directory/latency.json" >/dev/null
# A helper arm without helper binaries, an unknown arm and a missing sample
# file are refused before anything is measured.
while IFS='|' read -r bad diagnostic; do
  # shellcheck disable=SC2086 # each row is a list of options
  if (cd "$CASE" && "$TOOLS" hook-latency --unverified --binary "$ROOT/plugins/agent-guard/bin/agent-guard" --scanner "$ROOT/tests/fixtures/mock-gitleaks" $bad) >"$CASE/latency-bad-output" 2>"$CASE/latency-bad-error"; then
    echo "hook-latency accepted: $bad" >&2; exit 1
  fi
  grep -qF -- "$diagnostic" "$CASE/latency-bad-error"
  test ! -e "$CASE/latency-bad.json"
done <<'EOF'
--arm warm-helper --out latency-bad.json|arm warm-helper requires --helper
--arm no-such-arm --out latency-bad.json|unknown arm: no-such-arm
--case no-such-case --out latency-bad.json|unknown case: no-such-case
--runs 1|required option: --out
EOF
# CLI differential: a build compared with itself has no difference. A build
# whose message changed differs in output only, one whose deny list lost entries
# differs in decision, exit code and audit state, and no report holds the
# text of an input or an output.
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
MOCK="$ROOT/tests/fixtures/mock-gitleaks"
"$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --out "$CASE/parity-same.json" >"$CASE/parity-same-summary.json"
jq -e --slurpfile corpus tests/fixtures/cli-differential.json '.differences == 0 and (.cases | length) == ($corpus[0] | length)
  and ([.cases[] | select(.equal | not)] | length) == 0
  and ([.cases[].steps[] | select(.status[0] != .status[1] or .decision[0] != .decision[1] or (.state.equal | not))] | length) == 0
  and ([.cases[].steps[].decision[0]] | unique | (index("block") != null and index("allow") != null))' "$CASE/parity-same.json" >/dev/null
jq -e '.differences == 0 and (has("cases") | not)' "$CASE/parity-same-summary.json" >/dev/null
"$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --candidate-shell /bin/sh --scanner "$MOCK" \
  --case pre-bash-protected-path --case post-bash-key-block --entry direct --out "$CASE/parity-shell.json" >/dev/null
jq -e '.differences == 0 and (.cases | length) == 2' "$CASE/parity-shell.json" >/dev/null
"$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --entry manifest \
  --case pre-bash-protected-path --case codex-post-bash-key-block --case cli-version --out "$CASE/parity-manifest.json" >/dev/null
jq -e '.differences == 0 and .entry == "manifest" and (.cases | length) == 3' "$CASE/parity-manifest.json" >/dev/null
mkdir "$CASE/message" "$CASE/decision"
cp -R plugins/agent-guard "$CASE/message/agent-guard"
cp -R plugins/agent-guard "$CASE/decision/agent-guard"
sed 's/blocked shell command referencing a deny-listed path/blocked shell command naming a deny-listed path/' "$GUARD" >"$CASE/message/agent-guard/bin/agent-guard"
if cmp -s "$GUARD" "$CASE/message/agent-guard/bin/agent-guard"; then
  echo 'the message mutation changed nothing' >&2; exit 1
fi
# The two deny-list entries that cover the case's file are gone. An empty
# list would fail closed instead.
grep -vxF -e '.env*' -e '*.env' plugins/agent-guard/config/deny-read-paths.txt >"$CASE/decision/agent-guard/config/deny-read-paths.txt"
if cmp -s plugins/agent-guard/config/deny-read-paths.txt "$CASE/decision/agent-guard/config/deny-read-paths.txt"; then
  echo 'the decision mutation changed nothing' >&2; exit 1
fi
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$CASE/message/agent-guard/bin/agent-guard" --scanner "$MOCK" \
    --case pre-bash-protected-path --case pre-bash-clean --out "$CASE/parity-message.json" >"$CASE/parity-message-summary.json" 2>/dev/null; then
  echo 'cli-differential accepted a changed message' >&2; exit 1
fi
jq -e '.differences == 1 and ([.cases[] | select(.equal | not) | .name] == ["pre-bash-protected-path"])
  and (.cases[] | select(.name == "pre-bash-protected-path") | .steps[0]
    | (.stderr.equal | not) and .stderr.first_difference > 0 and .stdout.equal and .state.equal
      and .status == [2, 2] and .decision == ["block", "block"])' "$CASE/parity-message.json" >/dev/null
if grep -q 'deny-listed' "$CASE/parity-message.json" "$CASE/parity-message-summary.json"; then
  echo 'a differential report holds output text' >&2; exit 1
fi
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$CASE/decision/agent-guard/bin/agent-guard" --scanner "$MOCK" \
    --case pre-bash-protected-path --case pre-read-protected-path --case pre-bash-clean --out "$CASE/parity-decision.json" >/dev/null 2>&1; then
  echo 'cli-differential accepted a changed decision' >&2; exit 1
fi
jq -e '.differences == 2 and (.cases[] | select(.name == "pre-bash-protected-path") | .steps[0]
    | .status == [2, 0] and .decision == ["block", "allow"] and (.state.equal | not))
  and (.cases[] | select(.name == "pre-bash-clean") | .equal)' "$CASE/parity-decision.json" >/dev/null
# The report names no state file: a file name can hold the session identifier
# of an input.
jq -c '[.[] | select(.name == "scanner-missing-open") | .steps[0].input.session_id = "sample-customer-session"]' \
  tests/fixtures/cli-differential.json >"$CASE/session-corpus.json"
"$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --corpus "$CASE/session-corpus.json" \
  --out "$CASE/parity-session.json" >"$CASE/parity-session-summary.json" 2>/dev/null
jq -e '.differences == 0 and (.cases[0].steps[0].state.changes.baseline | length) > 0' "$CASE/parity-session.json" >/dev/null
if grep -q 'sample-customer-session' "$CASE/parity-session.json" "$CASE/parity-session-summary.json"; then
  echo 'a differential report holds a session identifier' >&2; exit 1
fi
# A build that leaves a file in the home directory and an empty directory
# differs although every output is the same.
mkdir "$CASE/litter"
cp -R plugins/agent-guard "$CASE/litter/agent-guard"
awk 'NR == 2 { print; print ": >\"$HOME/left-behind\"; mkdir -p \"${TMPDIR:-/tmp}/left-empty\""; next } { print }' \
  "$GUARD" >"$CASE/litter/agent-guard/bin/agent-guard"
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$CASE/litter/agent-guard/bin/agent-guard" --scanner "$MOCK" \
    --case pre-read-clean --out "$CASE/parity-litter.json" >/dev/null 2>&1; then
  echo 'cli-differential missed files outside the state directory' >&2; exit 1
fi
jq -e '.differences == 1 and (.cases[0].steps[0] | .stdout.equal and .stderr.equal and .status == [0, 0] and (.state.equal | not)
  and .state.changes.candidate["home-file"] == 1 and .state.changes.candidate["temporary-directory"] == 1)' "$CASE/parity-litter.json" >/dev/null
# A manifest whose matcher changed dispatches other tools, whatever the
# command does.
mkdir "$CASE/matcher"
cp -R plugins/agent-guard "$CASE/matcher/agent-guard"
jq '.hooks.PreToolUse[0].matcher = "apply_patch"' plugins/agent-guard/hooks.json >"$CASE/matcher/agent-guard/hooks.json"
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$CASE/matcher/agent-guard/bin/agent-guard" --scanner "$MOCK" --entry manifest \
    --case codex-pre-bash-clean --out "$CASE/parity-matcher.json" >/dev/null 2>&1; then
  echo 'cli-differential missed a changed manifest matcher' >&2; exit 1
fi
jq -e '.different_cases == ["manifest-dispatch-codex"]' "$CASE/parity-matcher.json" >/dev/null
# A comparison that cannot finish replaces an earlier report and says so.
printf '%s\n' '#!/bin/sh' 'case "${1:-}" in version) echo 8.30.1; exit 0 ;; esac' 'cat >/dev/null' 'sleep 30' >"$CASE/failing/gitleaks"
cp "$CASE/parity-same.json" "$CASE/parity-stale.json"
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$CASE/failing/gitleaks" --timeout 5 \
    --case pre-read-clean --case prompt-clean --out "$CASE/parity-stale.json" >/dev/null 2>&1; then
  echo 'cli-differential passed a comparison that timed out' >&2; exit 1
fi
jq -e '(.complete | not) and .aborted.case == "prompt-clean" and ([.cases[].name] == ["pre-read-clean"])' "$CASE/parity-stale.json" >/dev/null
# State that cannot be read is not state that is absent (root reads anything).
if [ "$(id -u)" != 0 ]; then
  mkdir "$CASE/locked"
  cp -R plugins/agent-guard "$CASE/locked/agent-guard"
  awk 'NR == 2 { print; print "mkdir -p \"${TMPDIR:-/tmp}/locked\" && chmod 000 \"${TMPDIR:-/tmp}/locked\""; next } { print }' \
    "$GUARD" >"$CASE/locked/agent-guard/bin/agent-guard"
  if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$CASE/locked/agent-guard/bin/agent-guard" --scanner "$MOCK" \
      --case pre-read-clean --out "$CASE/parity-locked.json" >/dev/null 2>"$CASE/locked.err"; then
    echo 'cli-differential passed state it could not read' >&2; exit 1
  fi
  jq -e '(.complete | not)' "$CASE/parity-locked.json" >/dev/null
  # The run still removes its own sandbox, unreadable directory included.
  locked=$(sed -n 's/^sandbox //p' "$CASE/locked.err")
  if [ -z "$locked" ] || [ -e "$locked" ]; then
    echo 'cli-differential left its sandbox behind' >&2; exit 1
  fi
fi
# A corpus with an unknown placeholder or without steps is refused.
printf '%s\n' '[{"name":"bad","steps":[{"args":["version"],"stdin":"{{NO_SUCH}}"}]}]' >"$CASE/bad-corpus.json"
printf '%s\n' '[{"name":"empty","steps":[]}]' >"$CASE/empty-corpus.json"
for bad in bad-corpus.json empty-corpus.json; do
  if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --corpus "$CASE/$bad" --out "$CASE/parity-bad.json" >/dev/null 2>&1; then
    echo "cli-differential accepted $bad" >&2; exit 1
  fi
  jq -e '(.complete | not) and (.aborted.error | type) == "string" and (has("cases") | not)' "$CASE/parity-bad.json" >/dev/null
done
# A request that fails before anything runs still replaces an earlier report.
cp "$CASE/parity-same.json" "$CASE/parity-replaced.json"
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --case no-such-case --out "$CASE/parity-replaced.json" >/dev/null 2>&1; then
  echo 'cli-differential accepted an unknown case' >&2; exit 1
fi
jq -e '(.complete | not)' "$CASE/parity-replaced.json" >/dev/null
# The report names only commands it knows, and a corpus cannot point the CLI's
# writes outside the sandbox both sides are rebuilt from.
printf '%s\n' '[{"name":"odd","steps":[{"args":["customer-file-name.txt"],"stdin":""}]}]' >"$CASE/odd-corpus.json"
"$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --corpus "$CASE/odd-corpus.json" --out "$CASE/parity-odd.json" >/dev/null 2>&1
jq -e '.differences == 0 and .cases[0].steps[0].command == "other"' "$CASE/parity-odd.json" >/dev/null
if grep -q 'customer-file-name' "$CASE/parity-odd.json"; then
  echo 'a differential report holds a corpus argument' >&2; exit 1
fi
for dir in "$CASE/outside" '/nonexistent/../tmp/outside' 'relative/outside'; do
  jq -c --arg dir "$dir" '[.[] | select(.name == "scanner-missing-open") | .env.AGENT_GUARD_WARNING_DIR = $dir]' \
    tests/fixtures/cli-differential.json >"$CASE/outside-corpus.json"
  if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --corpus "$CASE/outside-corpus.json" --out "$CASE/parity-outside.json" >/dev/null 2>&1; then
    echo "cli-differential let a corpus name the path $dir" >&2; exit 1
  fi
  jq -e '(.complete | not)' "$CASE/parity-outside.json" >/dev/null
done
test ! -e "$CASE/outside"
# Two builds that leave the same files with other permission bits differ.
mkdir "$CASE/modes"
cp -R plugins/agent-guard "$CASE/modes/agent-guard"
awk 'NR == 2 { print; print ": >\"$HOME/mode-probe\"; chmod 644 \"$HOME/mode-probe\""; next } { print }' "$GUARD" >"$CASE/modes/agent-guard/bin/agent-guard"
awk 'NR == 2 { print; print ": >\"$HOME/mode-probe\"; chmod 600 \"$HOME/mode-probe\""; next } { print }' "$GUARD" >"$CASE/litter/agent-guard/bin/agent-guard"
if "$TOOLS" cli-differential --baseline "$CASE/litter/agent-guard/bin/agent-guard" --candidate "$CASE/modes/agent-guard/bin/agent-guard" --scanner "$MOCK" \
    --case pre-read-clean --out "$CASE/parity-modes.json" >/dev/null 2>&1; then
  echo 'cli-differential missed a permission change' >&2; exit 1
fi
jq -e '.differences == 1 and (.cases[0].steps[0] | .stdout.equal and .stderr.equal and (.state.equal | not)
  and .state.changes.baseline == .state.changes.candidate)' "$CASE/parity-modes.json" >/dev/null
# A manifest command no step ran is compared as text.
mkdir "$CASE/unrun"
cp -R plugins/agent-guard "$CASE/unrun/agent-guard"
jq '.hooks.SessionStart[0].hooks[0].command += " # changed"' plugins/agent-guard/hooks.json >"$CASE/unrun/agent-guard/hooks.json"
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$CASE/unrun/agent-guard/bin/agent-guard" --scanner "$MOCK" --entry manifest \
    --case codex-pre-bash-clean --out "$CASE/parity-unrun.json" >/dev/null 2>&1; then
  echo 'cli-differential missed a manifest command it did not run' >&2; exit 1
fi
jq -e '.different_cases == ["manifest-dispatch-codex"] and .manifest_commands_run == ["codex PreToolUse"]' "$CASE/parity-unrun.json" >/dev/null
# A copy of the CLI that runs one more line first.
mutant() {
  mkdir "$CASE/$1"
  cp -R plugins/agent-guard "$CASE/$1/agent-guard"
  awk -v line="$2" 'NR == 2 { print; print line; next } { print }' "$GUARD" >"$CASE/$1/agent-guard/bin/agent-guard"
}
differs() {
  if "$TOOLS" cli-differential --baseline "$CASE/$1/agent-guard/bin/agent-guard" --candidate "$CASE/$2/agent-guard/bin/agent-guard" --scanner "$MOCK" \
      --case pre-read-clean --out "$CASE/parity-$2.json" >/dev/null 2>&1; then
    echo "cli-differential missed the $2 change" >&2; exit 1
  fi
}
# The scanner both sides share is not a place a build may write.
mutant plain ':'
mutant shared ': >"$AGENT_GUARD_GITLEAKS_BIN_DIR/litter"'
differs plain shared
jq -e '(.complete | not)' "$CASE/parity-shared.json" >/dev/null
# The directories a reset rebuilds are compared themselves.
mutant top 'chmod 700 "$HOME"'
differs plain top
jq -e '.differences == 1 and (.cases[0].steps[0].state.equal | not)' "$CASE/parity-top.json" >/dev/null
# Only what is declared unstable is left out: a number in any other file counts.
mutant stamp-one 'echo 1 >"$TMPDIR/stamp"'
mutant stamp-two 'echo 2 >"$TMPDIR/stamp"'
differs stamp-one stamp-two
jq -e '.differences == 1 and (.cases[0].steps[0].state | (.equal | not) and .changes.baseline == .changes.candidate)' "$CASE/parity-stamp-two.json" >/dev/null
# The report cannot replace a file the comparison reads.
cp tests/fixtures/cli-differential.json "$CASE/aliased.json"
if "$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --corpus "$CASE/aliased.json" \
    --case pre-read-clean --out "$CASE/aliased.json" >/dev/null 2>&1; then
  echo 'cli-differential wrote its report over its corpus' >&2; exit 1
fi
cmp -s tests/fixtures/cli-differential.json "$CASE/aliased.json"
# Whatever a step leaves in the sandbox counts, beside the four directories too.
mutant beside ': >"$HOME/../left-behind"'
differs plain beside
jq -e '.complete and .differences == 1' "$CASE/parity-beside.json" >/dev/null
# The staged mode and the flags of an index entry are state.
mutant staged-mode 'git update-index --chmod=+x README.md'
mutant staged-flag 'git update-index --assume-unchanged README.md'
differs staged-mode staged-flag
jq -e '.complete and .differences == 1 and (.cases[0].steps[0].state.equal | not)' "$CASE/parity-staged-flag.json" >/dev/null
# A side that removes the repository is a difference, not a run that failed.
mutant no-repo 'rm -rf "$HOME/../repo"'
differs plain no-repo
jq -e '.complete and .differences == 1' "$CASE/parity-no-repo.json" >/dev/null
# The corpus holds no value that is already masked: the default mode rewrites
# the output of this case, and with redaction off the same output passes.
if grep -qF 'REDACTED' tests/fixtures/cli-differential.json; then
  echo 'the differential corpus holds a masked value' >&2; exit 1
fi
"$TOOLS" cli-differential --baseline "$GUARD" --candidate "$GUARD" --scanner "$MOCK" --case post-bash-assignment --case output-redact-off \
  --out "$CASE/parity-redact.json" >/dev/null 2>&1
jq -e '.differences == 0 and ([.cases[].steps[0].stdout.bytes[0]] | .[0] > 0 and .[0] != .[1])' "$CASE/parity-redact.json" >/dev/null
# A repeated option keeps its last value.
test ! -e "$CASE/ignored-out"
printf 'Developer tools: option parsing, resource status, source-location and failed-partition contracts passed\n'

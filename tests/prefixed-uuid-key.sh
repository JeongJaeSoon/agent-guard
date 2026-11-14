#!/usr/bin/env sh
set -u

# A prefixed-UUID key (`sdk-` and a lowercase UUID) is found by the shape rule
# under a key-like name and on its own, while `sdk-` followed by an ordinary
# word (a package name) stays clean.
# Kept out of tests/run.sh: the monolith is already near ShellCheck's memory
# limit in CI, so each added line there risks the Lint job.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GUARD="$ROOT/plugins/agent-guard/bin/agent-guard"
# Exit before the cleanup trap exists: an empty CASE_ROOT would make
# `cd -- ""` resolve to the current directory, which the trap then removes.
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-guard-prefixed-uuid.XXXXXX") || exit 1
[ -n "$CASE_ROOT" ] || exit 1
CASE_ROOT=$(CDPATH= cd -- "$CASE_ROOT" && pwd -P) || exit 1
ORIGINAL_PATH=$PATH
# A host that passes the variable empty means "no real gitleaks": PATH then holds
# only run.sh's mock, which would turn every must-fail case into a false failure.
GITLEAKS=${AGENT_GUARD_TEST_REAL_GITLEAKS-$(command -v gitleaks 2>/dev/null || true)}
pass=0
fail=0

cleanup() {
  rm -rf "$CASE_ROOT"
}
trap cleanup EXIT INT TERM
# Scanned directory holds only the fixture; stdout/stderr captures stay outside.
mkdir -p "$CASE_ROOT/scan"

if [ -z "$GITLEAKS" ]; then
  printf 'skip - real gitleaks is not installed\n'
  exit 0
fi

export AGENT_GUARD_LOG_MODE=off
export AGENT_GUARD_RELEASE_CHECK=off
export AGENT_GUARD_GITLEAKS_CONFIG=${PREFIXED_UUID_TEST_CONFIG:-$ROOT/plugins/agent-guard/config/gitleaks.toml}
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
unset AI_AGENT
SCAN_PATH="$(dirname "$GITLEAKS"):$ORIGINAL_PATH"
SHAPE_RULE=agent-guard-vendor-token-shape

ok() {
  pass=$((pass + 1))
  printf 'ok - %s\n' "$1"
}

not_ok() {
  fail=$((fail + 1))
  printf 'not ok - %s\n' "$1"
  [ ! -s "$CASE_ROOT/err" ] || sed 's/^/  stderr: /' "$CASE_ROOT/err"
}

# $1 expected status, $2 label, $3 file content.
scan_case() {
  rm -f "$CASE_ROOT/scan/"*
  printf '%s\n' "$3" >"$CASE_ROOT/scan/fixture.env"
  PATH="$SCAN_PATH" "$GUARD" scan-path "$CASE_ROOT/scan" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  scan_status=$?
  if [ "$scan_status" -eq "$1" ]; then
    ok "scan-path: $2"
  else
    not_ok "scan-path: $2 (expected $1, got $scan_status)"
  fi
}

# $1 expected rule id, $2 label, $3 text. Names the detector, not only the verdict.
rule_case() {
  rm -f "$CASE_ROOT/report.json"
  printf '%s\n' "$3" | "$GITLEAKS" stdin --no-banner --no-color --log-level error \
    --config "$AGENT_GUARD_GITLEAKS_CONFIG" --exit-code 1 \
    --report-format json --report-path "$CASE_ROOT/report.json" \
    >"$CASE_ROOT/out" 2>"$CASE_ROOT/err"
  rule_status=$?
  rule_ids=$(jq -r '[.[].RuleID] | unique | join(",")' "$CASE_ROOT/report.json" 2>/dev/null)
  if [ "$rule_status" -eq 1 ] && [ "$rule_ids" = "$1" ]; then
    ok "rule $1: $2"
  else
    not_ok "rule $1: $2 (status $rule_status, rules '${rule_ids}')"
  fi
}

# Built at run time so this file holds no literal finding. The shape rule has
# no entropy floor, so a fixed UUID is as good as a random one.
SDK=$(printf '%s%s' sd k-)
KEY_UUID=$(printf '%s-%s-%s-%s-%s' 3f9c2b71 8e4d 4a06 b5c1 92d7e0a4f638)
SDK_KEY="$SDK$KEY_UUID"

# Must fail: the key is found whatever name holds it.
rule_case "$SHAPE_RULE" "a prefixed UUID under a generic key name" \
  "LD_SDK_KEY=$SDK_KEY"
rule_case "$SHAPE_RULE" "a prefixed UUID on its own" "$SDK_KEY"
rule_case "$SHAPE_RULE" "a quoted prefixed UUID in a JSON field" \
  "  \"sdkKey\": \"$SDK_KEY\","
scan_case 1 "a prefixed UUID under a generic key name is found end to end" \
  "LD_SDK_KEY=$SDK_KEY"

# Must pass: `sdk-` before an ordinary word is a package or module name.
scan_case 0 "sdk- followed by an ordinary word stays clean" \
  "$(printf '%s\n' \
    "LD_SDK_KEY=${SDK}python" \
    "pip install anthropic-${SDK}python" \
    "npm install @anthropic-ai/claude-agent-${SDK}typescript" \
    "import \"github.com/aws/aws-${SDK}go\"")"

printf '1..%s\n' "$((pass + fail))"
[ "$fail" -eq 0 ]
